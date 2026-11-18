/// O programa depois do acesso: quem está logado, o prestador em uso, as janelas abertas,
/// os avisos do rodapé e os registros da sessão. As telas falam com o núcleo e entre si por
/// aqui.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../acesso/acesso.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../nucleo.dart';
import '../tema.dart';
import '../permissoes.dart';
import 'dialogo.dart';

export '../acesso/acesso.dart' show Usuario;
export '../nucleo.dart' show ErroNucleo, Nucleo;
export 'dialogo.dart';

const ambProducao = '1';
const ambHomologacao = '2';
const ambRotulos = {ambProducao: 'Produção', ambHomologacao: 'Homologação'};

/// Cores do cabeçalho da autorização por senha, por nível exigido.
const corSenhaNivel = <int, Color>{
  1: Color(0xFFB8860B),
  2: Color(0xFFE8730C),
  3: Color(0xFFB22222),
  4: Color(0xFF7B1FA2),
};

Color corDoNivel(int nivel) => corSenhaNivel[nivel] ?? Colors.indigo.shade700;

/// Termina o processo depois de a saída ter sido confirmada e arrumada: o núcleo para de
/// responder, a janela some na hora e o runner desmonta o motor do Flutter fora de qualquer
/// callback do Windows (antes, sair travava alguns segundos e terminava com c000041d).
Future<void> encerrarProcesso() async {
  Nucleo.encerrar();
  try {
    if (await const MethodChannel('baiacu/janela').invokeMethod<bool>('encerrar') == true) {
      return;
    }
  } catch (_) {
    // Runner sem "encerrar" (modo de teste): sai direto.
  }
  exit(0);
}

// --------------------------------------------------------------------------- //
// Núcleo: atalhos
// --------------------------------------------------------------------------- //
/// Chamada que responde na hora (leituras e gravações locais, sem rede).
T ja<T>(String metodo, [Map<String, Object?> args = const {}]) =>
    Nucleo.ja<T>(metodo, args);

Map<String, dynamic> jaMapa(
  String metodo, [
  Map<String, Object?> args = const {},
]) => Map<String, dynamic>.from(Nucleo.ja<Map>(metodo, args));

List<Map<String, dynamic>> jaLista(
  String metodo, [
  Map<String, Object?> args = const {},
]) => [
  for (final v in Nucleo.ja<List>(metodo, args))
    Map<String, dynamic>.from(v as Map),
];

List<(String, String)> jaPares(
  String metodo, [
  Map<String, Object?> args = const {},
]) => [
  for (final v in Nucleo.ja<List>(metodo, args))
    ((v as List)[0] as String, v[1] as String),
];

/// Chamada demorada (rede, certificado, arquivos grandes): roda fora da tela.
Future<T> chamar<T>(
  String metodo, [
  Map<String, Object?> args = const {},
  void Function(Object?)? aoAvisar,
]) => Nucleo.chamarAcompanhando<T>(metodo, args, aoAvisar: aoAvisar);

Future<void> _registrosPendentes = Future<void>.value();
Future<void> registrar(
  String msg, {
  String nivel = 'info',
  String nome = 'gui',
}) {
  return _registrosPendentes = _registrosPendentes.then((_) async {
    try {
      await Nucleo.chamar<Object?>('registro.registrar', {
        'nome': nome,
        'nivel': nivel,
        'msg': msg,
      });
    } catch (e) {
      debugPrint('Falha ao registrar evento: $e');
    }
  });
}

/// Rótulo do campo de busca das telas de notas (o núcleo é quem sabe por onde a busca procura).
final String rotuloDaBusca = ja<String>('busca.rotulo');

String formatarDocumento(String doc) =>
    ja<String>('texto.format_documento', {'valor': doc});
String soDoc(String s) => ja<String>('texto.only_doc', {'valor': s});
String soDigitos(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

// --------------------------------------------------------------------------- //
// Avisos do rodapé e registros da sessão
// --------------------------------------------------------------------------- //
class Registro {
  Registro(this.msg, this.erro, this.progresso, this.lido)
    : ts = DateTime.now();
  String msg;
  bool erro;

  /// Informação que pede atenção (amarelo), não é erro.
  bool aviso = false;
  bool progresso;
  bool lido;
  DateTime ts;
}

/// Cor das informações que pedem atenção mas não são erro (a mesma dos avisos em amarelo
/// das telas): o erro é vermelho e o aviso comum, cinza-escuro.
final corAviso = Colors.orange.shade800;
const metaMinimizarAoFechar = 'ui.minimizar_ao_fechar';

class AcessoRestrito extends StatelessWidget {
  const AcessoRestrito({super.key, required this.aoAutorizar});
  final VoidCallback aoAutorizar;

  @override
  Widget build(BuildContext context) => Center(
    child: Botao.contorno(
      'Autorizar acesso',
      icone: Icons.lock_outline,
      aoClicar: aoAutorizar,
      idLayout: 'AcessoRestrito.botaoAutorizar',
    ),
  );
}

class Aviso {
  Aviso(this.msg, {this.erro = false, this.progresso = false});
  String msg;
  bool erro;

  /// Informação que pede atenção (amarelo), não é erro.
  bool aviso = false;
  bool progresso;
  bool feito = false;
  Registro? registro;
}

/// Uma das telas do programa. Todas ficam montadas o tempo todo e só uma está à vista:
/// redesenhar uma tela guardada é trabalho que ninguém vê, então o pedido fica anotado e é
/// atendido quando ela volta a ser a da vez (entrar numa tela sempre a redesenha).
mixin TelaGuardada<T extends StatefulWidget> on State<T> {
  App get app;

  /// Índice de navegação desta tela.
  int get indiceDaTela;

  void redesenhar() {
    if (!mounted || app.navAtual != indiceDaTela) return;
    setState(() {});
  }
}

class App {
  App(this.usuario, {required this.aoSair, required this.aoMudarAparencia}) {
    _iniciar();
  }

  Usuario usuario;

  /// Volta para as telas de acesso.
  final VoidCallback aoSair;

  /// As cores de superfície mudaram: o tema do programa inteiro é refeito.
  final VoidCallback aoMudarAparencia;

  // ---- estado ------------------------------------------------------------------ //
  String prestador = '';
  String cert = '';
  String ambiente = ambProducao;
  bool semPrestador = false;
  bool pdfNativo = true;
  bool minimizarAoFechar = false;
  int navAtual = 0;
  bool encerrada = false;

  /// Trabalhos em segundo plano em curso (emissão, e-mail, sincronização, exportação…).
  int trabalhos = 0;

  /// Config de e-mail do prestador em uso, em cache (a Consulta consulta por LINHA).
  Map<String, dynamic>? emailCfg;
  String? emailCfgPrest;

  // ---- Cofre: sincronização automática (o cartão das Configurações lê e muda) --------- //
  /// Preferências de sincronização em uso (ambientes, automática, prestadores, intervalo).
  Map<String, dynamic> autoCfg = {};

  /// Resultado da última rodada automática e quando é a próxima.
  final Map<String, dynamic> autoEstado = {
    'texto': '',
    'falhas': 0,
    'tentar_em': 0.0,
    'rodando': false,
  };

  /// Prestadores em exclusão (a sincronização em curso deles não anuncia resultado).
  final Set<String> cofreApagando = {};

  /// Época (segundos) da próxima sincronização automática.
  double Function()? cofreProxima;

  /// Refaz o texto de situação ao lado do botão Sincronizar.
  VoidCallback? cofreAtualizarSituacao;

  /// Confere o banco de notas e o recupera da cópia de segurança se preciso.
  Future<void> Function()? cofreCuidar;

  /// A Emitir recarrega o serviço aberto (os percentuais herdados do prestador mudaram).
  VoidCallback? tributosDoPrestadorMudaram;

  /// Cor de fundo em PRÉVIA (Personalização, enquanto a barra é arrastada): só o fundo
  /// geral muda, sem trocar o tema. Nulo = a cor do tema.
  final ValueNotifier<String?> fundoPrevia = ValueNotifier(null);

  /// Há uma sincronização do Cofre em curso (manual ou automática)?
  bool Function()? cofreSincronizando;

  /// Para a sincronização em curso do Cofre.
  VoidCallback? cofreCancelarSinc;

  /// Documentos dos prestadores que o usuário logado enxerga (o master, todos).
  List<String> prestadoresVisiveis() {
    var docs = [
      for (final p in jaLista('cadastro.list_prestadores'))
        p['documento'] as String,
    ];
    if (!usuario.master) {
      final permitidos = ja<List>('usuarios.prestadores_permitidos', {
        'usuario': usuario.paraJson(),
      }).cast<String>().toSet();
      docs = [
        for (final d in docs)
          if (permitidos.contains(d)) d,
      ];
    }
    return docs;
  }

  List paresCofre() => ja<List>('cofre.alvos', {
    'prestador_em_uso': prestador,
    'prestadores': prestadoresVisiveis(),
    'usuario': usuario.paraJson(),
  });

  /// O cadastro de clientes mudou: caches caem e as listas das telas são refeitas.
  final List<VoidCallback> aoInvalidarClientes = [];
  void clientesMudaram() {
    for (final f in List.of(aoInvalidarClientes)) {
      f();
    }
    for (final f in List.of(recarregarTelas)) {
      f();
    }
  }

  /// Os grupos mudaram (nomes/associações): filtros e caches que dependem deles caem.
  final List<VoidCallback> aoMudarGrupos = [];
  void gruposMudaram() {
    for (final f in List.of(aoMudarGrupos)) {
      f();
    }
    atualizar();
  }

  /// Um certificado do prestador entrou ou saiu (o próprio ou o de um procurador): o ativo é
  /// relido e as telas que mostram quem assina conferem de novo.
  final List<VoidCallback> aoMudarCertificados = [];
  void certificadosMudaram() {
    cert = prestador.isEmpty
        ? ''
        : ja<String>('cadastro.active_cert', {'prestador': prestador});
    for (final f in List.of(aoMudarCertificados)) {
      f();
    }
  }

  /// Recarrega a página da Consulta (quando ela é a tela à vista).
  VoidCallback? recarregarConsulta;

  /// Uma nota nova entrou/mudou: Consulta e Cofre recarregam ao abrir.
  final List<VoidCallback> aoMudarNotas = [];
  void notasMudaram() {
    for (final f in List.of(aoMudarNotas)) {
      f();
    }
  }

  final Suspensa ddPrestador = Suspensa();
  bool ddPrestadorTravado = false;
  Uint8List? foto;

  // ---- redesenho --------------------------------------------------------------- //
  final ValueNotifier<int> tiqueCasca = ValueNotifier(0);
  final ValueNotifier<int> tiqueDialogos = ValueNotifier(0);
  final ValueNotifier<int> tiqueAvisos = ValueNotifier(0);
  final ValueNotifier<int> tiqueRegistros = ValueNotifier(0);

  /// Redesenha a casca (topo, faixa do ambiente, trilho) e a tela à vista. As telas
  /// guardadas só anotam que mudaram: são redesenhadas quando voltam a ser a da vez.
  void atualizar() {
    if (encerrada) return;
    tiqueCasca.value++;
    for (final f in List.of(_ouvintesTela)) {
      f();
    }
  }

  final List<VoidCallback> _ouvintesTela = [];
  void aoAtualizar(VoidCallback f) => _ouvintesTela.add(f);
  void semAtualizar(VoidCallback f) => _ouvintesTela.remove(f);

  // ---- ganchos das telas ------------------------------------------------------- //
  /// Ao trocar de prestador: cada tela zera o que era do anterior.
  final List<VoidCallback> aoTrocarPrestador = [];

  /// Ao entrar numa tela (índice de navegação).
  final Map<int, VoidCallback> aoEntrar = {};

  /// Recarregam as listas que dependem dos cadastros (Emitir, Clientes, Consultar).
  final List<VoidCallback> recarregarTelas = [];

  /// Esc sem janela aberta: a tela à vista cancela a edição em curso (true = cancelou).
  final Map<int, bool Function()> escDaTela = {};

  /// Saiu das Configurações com um cartão em edição: volta tudo a travado.
  bool Function()? retravarConfig;

  /// Fila de contingência: para o ciclo de reenvio / refaz o aviso.
  VoidCallback? pararFila;
  VoidCallback? refazerAvisoFila;

  /// Cofre: sincronização em curso (manual ou automática) para de vez.
  final List<VoidCallback> aoPararTimers = [];

  final List<Timer> _timers = [];

  void _iniciar() {
    Permissoes.carregar(jaMapa('permissoes.carregar'));
    HardwareKeyboard.instance.addHandler(_tecla);
    final cores = jaMapa('aparencia.carregar');
    aparenciaAtual = Aparencia(
      cores['fundo'] as String,
      cores['cartoes'] as String,
    );
    try {
      pdfNativo =
          ja<String>('banco.get_meta', {'chave': 'ui.pdf_nativo'}) != '0';
    } catch (_) {
      pdfNativo = true;
    }
    try {
      minimizarAoFechar =
          ja<String>('banco.get_meta', {'chave': metaMinimizarAoFechar}) == '1';
    } catch (_) {
      minimizarAoFechar = false;
    }
    ja<Object?>('registro.definir_usuario', {'operador_id': usuario.id});

    var lista = jaLista('cadastro.list_prestadores');
    final preferido = ja<String>('cadastro.ultimo_prestador', {
      'usuario_id': usuario.id,
    });
    if (!usuario.master) {
      final existentes = {for (final p in lista) p['documento'] as String};
      final permitidos = [
        for (final d in ja<List>('usuarios.prestadores_permitidos', {
          'usuario': usuario.paraJson(),
        }))
          if (existentes.contains(d)) d as String,
      ];
      prestador = ja<String>('cadastro.escolher_prestador_inicial', {
        'disponiveis': permitidos,
        'preferido': preferido,
      });
      semPrestador = permitidos.isEmpty;
      lista = [
        for (final p in lista)
          if (permitidos.contains(p['documento'])) p,
      ];
    } else {
      prestador = ja<String>('cadastro.escolher_prestador_inicial', {
        'disponiveis': [for (final p in lista) p['documento']],
        'preferido': preferido,
      });
    }
    cert = prestador.isEmpty
        ? ''
        : ja<String>('cadastro.active_cert', {'prestador': prestador});
    ambiente = prestador.isEmpty
        ? ambProducao
        : ja<String>('cadastro.get_ambiente', {'prestador': prestador});
    // Não-master pode alternar entre os prestadores liberados; trava só se tiver 1.
    ddPrestadorTravado = !usuario.master && lista.length <= 1;
    ddPrestador.opcoes = [
      for (final p in lista)
        Opcao(p['documento'] as String, p['display'] as String),
    ];
    ddPrestador.por(prestador);
    // Sem prestador ativo (instalação nova, ou usuário sem prestador liberado) as outras telas
    // não têm o que mostrar: o programa abre nas Configurações.
    if (prestador.isEmpty) navAtual = 3;
    carregarFoto();
  }

  void recarregarPrestadores() {
    var lista = jaLista('cadastro.list_prestadores');
    if (!usuario.master) {
      final permitidos = ja<List>('usuarios.prestadores_permitidos', {
        'usuario': usuario.paraJson(),
      }).cast<String>().toSet();
      lista = [
        for (final p in lista)
          if (permitidos.contains(p['documento'])) p,
      ];
    }
    ddPrestador.opcoes = [
      for (final p in lista)
        Opcao(p['documento'] as String, p['display'] as String),
    ];
  }

  void carregarFoto() {
    try {
      final b = ja<String?>('usuarios.get_foto', {'usuario_id': usuario.id});
      foto = (b == null || b.isEmpty) ? null : base64Decode(b);
    } catch (_) {
      foto = null;
    }
  }

  // ---- permissões -------------------------------------------------------------- //
  int get nivel => usuario.nivel;
  bool get master => usuario.master;
  bool pode(int n) => nivel >= n;
  bool temPermissao(String chave, {bool somenteLogado = false}) {
    if (pode(Permissoes.efetivo(chave))) return true;
    return !somenteLogado && ja<bool>('permissoes.pode', {'chave': chave});
  }

  Usuario? autorizadorDaAcao(String chave) {
    final dados = ja<Map?>('permissoes.autorizador', {'chave': chave});
    return dados == null
        ? null
        : Usuario.deJson(Map<String, dynamic>.from(dados));
  }

  Future<bool> autorizarAcao(String chave) {
    final resultado = Completer<bool>();
    exigirPermissao(
      chave,
      () => resultado.complete(true),
      aoCancelar: () => resultado.complete(false),
    );
    return resultado.future;
  }

  /// Em vez de BLOQUEAR uma ação restrita, pede a SENHA de um usuário com nível suficiente.
  /// Se o operador logado já tem o nível, libera direto.
  void exigirPermissao(
    String chave,
    VoidCallback aoOk, {
    String? titulo,
    VoidCallback? aoCancelar,
    bool semprePedirSenha = false,
  }) {
    titulo ??= Permissoes.regras.firstWhere((r) => r.id == chave).titulo;
    final n = Permissoes.efetivo(chave);
    if (temPermissao(chave) && !semprePedirSenha) {
      aoOk();
      return;
    }
    late final Dialogo d;
    var erro = '';
    var processando = false;
    var concedida = false;
    late final TextEditingController senha;
    late final FocusNode focoSenha;

    void ok() {
      if (processando) return;
      processando = true;
      Map<String, dynamic> r;
      try {
        r = jaMapa('usuarios.autenticar_por_senha', {
          'senha': senha.text,
          'permissao': chave,
        });
      } catch (e) {
        processando = false;
        erro = '$e';
        d.atualizar();
        return;
      }
      final dado = r['usuario'];
      if (dado != null) {
        final u = Usuario.deJson(Map<String, dynamic>.from(dado as Map));
        if (r['ambiguo'] == true) {
          ja<Object?>('registro.definir_usuario', {'operador_id': usuario.id});
          registrar(
            'Autorizado por senha de nível ${u.nivel} (exigido $n) — usuário '
            'INDETERMINADO: há mais de uma senha igual',
            nivel: 'warning',
          );
        } else {
          ja<Object?>('registro.definir_usuario', {
            'operador_id': usuario.id,
            'autorizador_id': u.id,
          });
          registrar(
            'Autorizado por senha de nível ${u.nivel} do usuário #${u.id} ${u.login} '
            '(exigido $n) — $titulo',
          );
        }
        concedida = true;
        fecharEsta(d);
        agendar(const Duration(minutes: 5), atualizar);
        aoOk();
      } else {
        processando = false;
        erro = 'Senha não confere com nenhum usuário de nível $n ou superior.';
        senha.clear();
        d.atualizar();
        focar(focoSenha);
      }
    }

    void cancelar() {
      registrar('Autorização de nível $n cancelada ($titulo)');
      fecharEsta(d);
    }

    d = Dialogo(
      titulo: (_) => textoTitulo(
        'Autorização',
        peso: FontWeight.bold,
        cor: Colors.indigo.shade700,
      ),
      largura: 420,
      conteudo: (_) => col(
        [
          Tx(
            'Senha de nível $n',
            cor: corDoNivel(n),
            peso: FontWeight.bold,
            tam: Letra.texto,
            largura: TamanhosDialogos.rotuloSenhaDeNivelN.largura,
            altura: TamanhosDialogos.rotuloSenhaDeNivelN.altura,
            idLayout: 'TamanhosDialogos.rotuloSenhaDeNivelN',
          ),
          CampoTexto(
            controle: senha,
            rotulo: 'Senha',
            largura: TamanhosDialogos.campoSenha.largura,
            senha: true,
            revelarSenha: true,
            focoInicial: true,
            foco: focoSenha,
            aoEnviar: (_) => ok(),
            altura: TamanhosDialogos.campoSenha.altura,
            idLayout: 'TamanhosDialogos.campoSenha',
          ),
          Tx(
            erro,
            cor: Colors.red.shade600,
            tam: Letra.apoio,
            largura: TamanhosDialogos.rotuloErro.largura,
            altura: TamanhosDialogos.rotuloErro.altura,
            idLayout: 'TamanhosDialogos.rotuloErro',
          ),
        ],
        justa: true,
        espaco: 8,
        idLayout: 'Grupo.app.col.1',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: cancelar,
          largura: TamanhosDialogos.botaoCancelar.largura,
          altura: TamanhosDialogos.botaoCancelar.altura,
          idLayout: 'TamanhosDialogos.botaoCancelar',
        ),
        Botao(
          'OK',
          aoClicar: ok,
          largura: TamanhosDialogos.botaoOK.largura,
          altura: TamanhosDialogos.botaoOK.altura,
          idLayout: 'TamanhosDialogos.botaoOK',
        ),
      ],
      // Esc/"X" fecham sem passar por `cancelar`: quem depende do aoCancelar para
      // destravar estado (a trava do botão Emitir) não pode ficar preso.
      aoFechar: () {
        if (!concedida) aoCancelar?.call();
      },
      idLayout: 'Janela.app.Dialogo.1',
    );
    senha = d.texto();
    focoSenha = d.foco();
    mostrarDialogo(d);
  }

  // ---- janelas ----------------------------------------------------------------- //
  final List<Dialogo> dialogos = [];

  /// Marcadores de janela que só podem existir UMA vez na pilha.
  static const _unicos = {
    'confirmar_emissao',
    '_modal_obrigatorio_',
    'novo_usuario',
  };

  void mostrarDialogo(Dialogo d) {
    final m = d.marcador;
    if (m != null &&
        _unicos.contains(m) &&
        dialogos.any((x) => x.marcador == m)) {
      return;
    }
    d.aberto = true;
    dialogos.add(d);
    tiqueDialogos.value++;
  }

  /// Fecha a janela do TOPO.
  void fecharDialogo() {
    if (dialogos.isEmpty) return;
    final d = dialogos.removeLast();
    tiqueDialogos.value++;
    _aoFechou(d);
  }

  /// Fecha UMA janela específica, esteja ela no topo ou não.
  void fecharEsta(Dialogo d) {
    if (!dialogos.remove(d)) return;
    tiqueDialogos.value++;
    _aoFechou(d);
  }

  bool dialogoAberto(Dialogo? d) => d != null && dialogos.contains(d);

  void _aoFechou(Dialogo d) {
    final cb = d.aoFechar;
    d.aoFechar = null;
    d.descartar();
    if (cb == null) return;
    try {
      cb();
    } catch (e) {
      registrar('Falha no gancho de fechamento do diálogo: $e', nivel: 'error');
    }
  }

  bool get decisaoObrigatoria =>
      dialogos.any((d) => d.marcador == '_modal_obrigatorio_');

  bool _escCancelouEdicao() {
    try {
      if (dialogos.isNotEmpty) {
        final gancho = dialogos.last.escCancelaEdicao;
        return gancho != null ? gancho() : false;
      }
      if (navAtual == 3) return retravarConfig?.call() ?? false;
      return escDaTela[navAtual]?.call() ?? false;
    } catch (e) {
      registrar('Falha ao cancelar a edição pelo Esc: $e', nivel: 'error');
    }
    return false;
  }

  /// Rotas nativas abertas por cima (calendário, seletor): fecham antes de tudo.
  int rotasNativas = 0;

  bool _tecla(KeyEvent e) {
    if (editorLayoutAtivo) return false;
    if (encerrada || e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      // Decisão OBRIGATÓRIA (falha de transmissão com a DPS já assinada): Esc não fecha.
      if (dialogos.isNotEmpty &&
          dialogos.last.marcador == '_modal_obrigatorio_') {
        return false;
      }
      if (rotasNativas > 0) return false;
      if (_escCancelouEdicao()) return false;
      fecharDialogo();
    } else if ((e.logicalKey == LogicalKeyboardKey.enter ||
            e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        dialogos.isNotEmpty) {
      if (dialogos.last.marcador == '_enter_fecha_') fecharDialogo();
    }
    return false;
  }

  /// Título de janela com "X" no canto direito (Esc também fecha).
  LinhaTitulo tituloComX(Object titulo) => LinhaTitulo([
    titulo is Widget ? titulo : textoTitulo(titulo as String),
    const Expanded(child: SizedBox()),
    BotaoIcone(
      Icons.close,
      dica: 'Fechar (Esc)',
      aoClicar: fecharDialogo,
      largura: TamanhosDialogos.botaoFecharEsc.largura,
      altura: TamanhosDialogos.botaoFecharEsc.altura,
      idLayout: 'TamanhosDialogos.botaoFecharEsc',
    ),
  ]);

  /// Devolve o foco a um campo (depois do quadro em curso).
  void focar(FocusNode? foco) {
    if (foco == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (foco.canRequestFocus) foco.requestFocus();
      } catch (_) {}
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  // ---- avisos do rodapé -------------------------------------------------------- //
  static const duracaoAviso = Duration(seconds: 3);
  static const duracaoAvisoErro = Duration(seconds: 5);

  final List<Aviso> avisos = [];

  void _redesenharAvisos() {
    if (!encerrada) tiqueAvisos.value++;
  }

  void expirarAviso(Aviso a) {
    if (avisos.remove(a)) _redesenharAvisos();
  }

  void _agendarSumico(Aviso a, bool erro) {
    agendar(erro ? duracaoAvisoErro : duracaoAviso, () => expirarAviso(a));
  }

  /// Aviso informativo: empilha sobre os existentes e some sozinho.
  void toast(String msg, {bool erro = false}) {
    if (encerrada) return;
    final a = Aviso(msg, erro: erro);
    avisos.add(a);
    _redesenharAvisos();
    _agendarSumico(a, erro);
    _registroNovo(msg, erro);
  }

  /// Aviso de PROGRESSO (anel girando): fica até [toastFim].
  Aviso toastProgresso(String msg) {
    final a = Aviso(msg, progresso: true);
    avisos.add(a);
    _redesenharAvisos();
    a.registro = _registroNovo(msg, false, progresso: true);
    return a;
  }

  /// Converte um aviso de progresso no resultado e agenda o sumiço.
  bool backupEmAndamento = false;

  void toastAndamento(Aviso a, String msg) {
    if (encerrada) return;
    a.msg = msg;
    _redesenharAvisos();
    final r = a.registro;
    if (r != null) {
      r.msg = msg;
      r.ts = DateTime.now();
      _registrosMudaram();
    }
  }

  void toastFim(Aviso a, String msg, {bool erro = false, bool aviso = false}) {
    if (encerrada) return;
    if (!avisos.contains(a)) avisos.add(a);
    a
      ..msg = msg
      ..erro = erro
      ..aviso = aviso && !erro
      ..progresso = false
      ..feito = true;
    _redesenharAvisos();
    _agendarSumico(a, erro);
    final r = a.registro;
    if (r != null) {
      _registroMudou(r, msg, erro);
      r.aviso = a.aviso;
    } else {
      _registroNovo(msg, erro).aviso = a.aviso;
    }
  }

  // ---- registros da sessão ------------------------------------------------------ //
  static const maxRegistros = 100;
  final List<Registro> registros = [];
  int naoLidos = 0;
  Dialogo? dialogoRegistros;

  bool get _registrosAbertos => dialogoAberto(dialogoRegistros);

  Registro _registroNovo(String msg, bool erro, {bool progresso = false}) {
    final r = Registro(msg, erro, progresso, _registrosAbertos);
    if (!progresso) _gravarRegistro(msg, erro);
    registros.add(r);
    while (registros.length > maxRegistros) {
      final antigo = registros.indexWhere((r) => !r.progresso);
      if (antigo < 0) break;
      registros.removeAt(antigo);
    }
    _registrosMudaram();
    return r;
  }

  void _registroMudou(Registro r, String msg, bool erro) {
    r
      ..msg = msg
      ..erro = erro
      ..progresso = false
      ..ts = DateTime.now();
    _gravarRegistro(msg, erro);
    if (!_registrosAbertos) r.lido = false;
    _registrosMudaram();
  }

  /// Todo registro da sessão vai também para o registro em disco (é de lá que o
  /// "Consultar" lê). Processo em andamento grava só o desfecho.
  void _gravarRegistro(String msg, bool erro) {
    registrar(
      msg.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).join(' '),
      nivel: erro ? 'error' : 'info',
      nome: 'registro',
    );
  }

  void _registrosMudaram() {
    naoLidos = registros.where((r) => !r.lido).length;
    if (!encerrada) tiqueRegistros.value++;
  }

  void marcarRegistrosLidos() {
    for (final r in registros) {
      r.lido = true;
    }
    naoLidos = 0;
    tiqueRegistros.value++;
  }

  // ---- tempo e trabalho em segundo plano ---------------------------------------- //
  bool get viva => !encerrada;

  Timer agendar(Duration espera, VoidCallback fn) {
    late final Timer t;
    t = Timer(espera, () {
      _timers.remove(t);
      if (viva) fn();
    });
    _timers.add(t);
    return t;
  }

  /// Conta o trabalho enquanto ele corre: fechar a janela e sair esperam por ele.
  Future<void> emSegundoPlano(Future<void> Function() fn) async {
    trabalhos++;
    try {
      await fn();
    } catch (e, pilha) {
      registrar(
        'Erro no trabalho em segundo plano: $e\n$pilha',
        nivel: 'error',
        nome: 'app',
      );
    } finally {
      trabalhos--;
    }
  }

  int lotesPendentes = 0;
  Future<void> atualizarLotesPendentes() async {
    final p = prestador;
    if (p.isEmpty || !temPermissao('lotes')) {
      lotesPendentes = 0;
      return;
    }
    try {
      final lista = await chamar<List>('lotes.execucoes', {'prestador': p});
      if (!viva || prestador != p) return;
      lotesPendentes = lista.where((e) => (e['pendentes'] as int) > 0).length;
      tiqueCasca.value++;
    } catch (e) {
      debugPrint('Não foi possível atualizar pendências dos lotes: $e');
    }
  }

  bool get ocupado => trabalhos > 0 || decisaoObrigatoria;

  void pararTimers({bool encerrarRede = true}) {
    pararFila?.call();
    if (encerrarRede) {
      try {
        ja<Object?>('correio.encerrar_smtp');
      } catch (_) {}
    }
    for (final f in List.of(aoPararTimers)) {
      try {
        f();
      } catch (_) {}
    }
    for (final t in List.of(_timers)) {
      t.cancel();
    }
    _timers.clear();
  }

  bool _saindo = false;
  Future<void> sair() async {
    if (_saindo) return;
    if (ocupado) {
      toast(
        'Conclua a operação ou a decisão de transmissão pendente antes de sair.',
        erro: true,
      );
      return;
    }
    _saindo = true;
    trabalhos++;
    pararTimers(encerrarRede: false);
    try {
      try {
        await _registrosPendentes.timeout(const Duration(seconds: 1));
        await chamar<Object?>('registro.registrar', {
          'nome': 'gui',
          'nivel': 'info',
          'msg': 'Logout do usuário ${usuario.login}',
        }).timeout(const Duration(seconds: 1));
        await chamar<Object?>(
          'registro.definir_usuario',
          {},
        ).timeout(const Duration(seconds: 1));
        await chamar<Object?>('correio.encerrar_smtp', {
          'aguardar': false,
        }).timeout(const Duration(seconds: 1));
      } catch (e) {
        debugPrint('Falha na preparação do logout: $e');
      }
      await chamar<Object?>(
        'banco.trancar',
      ).timeout(const Duration(seconds: 3));
      encerrar();
      aoSair();
    } catch (e) {
      // O serviço pode estar sem resposta: este aviso não faz outra chamada síncrona a ele.
      debugPrint('Falha ao concluir logout: $e');
      final aviso = Aviso(
        'Não foi possível concluir a saída do usuário. Tente novamente ou feche o programa.',
        erro: true,
      );
      avisos.add(aviso);
      _redesenharAvisos();
      _agendarSumico(aviso, true);
    } finally {
      trabalhos--;
      _saindo = false;
    }
  }

  /// Arrumação de quem vai fechar o processo: o SMTP é solto, o dados.key sai igual à cópia
  /// guardada dentro do banco e o registro vai para o disco. Roda uma vez só.
  static bool _arrumado = false;
  static Future<void> arrumarParaFechar() async {
    if (_arrumado) {
      try {
        await chamar<Object?>('registro.sincronizar');
      } catch (_) {}
      return;
    }
    _arrumado = true;
    try {
      await _registrosPendentes;
    } catch (_) {}
    try {
      await chamar<Object?>('correio.encerrar_smtp', {'aguardar': false});
    } catch (_) {}
    try {
      if (await chamar<bool>('banco.destrancado')) {
        await chamar<Object?>('chaves.conferir', {'motivo': 'fechamento'});
      }
    } catch (e) {
      debugPrint('Falha ao conferir o dados.key no fechamento: $e');
    }
    try {
      await chamar<Object?>('registro.registrar', {
        'nome': 'app',
        'nivel': 'info',
        'msg': 'Aplicativo encerrando.',
      });
    } catch (_) {}
    try {
      await chamar<Object?>('registro.sincronizar');
    } catch (_) {}
  }

  /// Fecha o programa — e o reabre, se [reabrir] (depois de restaurar um backup: o que está
  /// em memória é dos bancos antigos). Recusa enquanto houver trabalho em segundo plano ou
  /// uma decisão de transmissão pendente. Devolve false se recusou.
  Future<bool> fechar({bool reabrir = false}) async {
    if (ocupado) {
      toast(
        'Conclua a operação ou a decisão de transmissão pendente antes de fechar.',
        erro: true,
      );
      return false;
    }
    if (_fechando) return false;
    _fechando = true;
    pararTimers(encerrarRede: false);
    await arrumarParaFechar().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    if (reabrir) {
      // Só depois da arrumação: este processo já não segura o banco nem o registro.
      try {
        await Process.start(
          Platform.resolvedExecutable,
          const [],
          mode: ProcessStartMode.detached,
          // A cópia nova espera esta fechar (um aberto por computador).
          environment: const {'NFSE_REABRIR': '1'},
        );
      } catch (e) {
        registrar(
          'Nao foi possivel reabrir o aplicativo: $e',
          nivel: 'error',
          nome: 'app',
        );
      }
    }
    await encerrarProcesso();
    return true;
  }

  bool _fechando = false;

  void encerrar() {
    if (encerrada) return;
    encerrada = true;
    HardwareKeyboard.instance.removeHandler(_tecla);
    for (final t in List.of(_timers)) {
      t.cancel();
    }
    _timers.clear();
    for (final d in List.of(dialogos)) {
      d.descartar();
    }
    dialogos.clear();
  }

  // ---- navegação ---------------------------------------------------------------- //
  /// Telas (índice de navegação): 0 Emitir, 1 Clientes, 2 Consultar, 3 Configurações,
  /// 4 Cofre. No trilho a ordem é outra — o Cofre entra no grupo de cima e Configurações é
  /// o botão de baixo, fora dos destinos.
  static const trilhoNav = [0, 5, 1, 2, 4];
  static const modulosNavegacao = [
    'emitir',
    'clientes',
    'consultar',
    'config',
    'cofre',
    'lotes',
  ];
  static const navTrilho = {0: 0, 5: 1, 1: 2, 2: 3, 4: 4};

  void irPara(int indice) {
    final chave = modulosNavegacao[indice];
    if (!temPermissao(chave)) {
      exigirPermissao(chave, () => irPara(indice));
      return;
    }
    final anterior = navAtual;
    if (anterior == 3 && indice != 3) retravarConfig?.call();
    navAtual = indice;
    aoEntrar[indice]?.call();
    atualizar();
  }

  // ---- prestador ----------------------------------------------------------------- //
  void aoEscolherPrestador(String? escolha) {
    final novo = escolha ?? '';
    if (novo.isEmpty || novo == prestador) return;
    // Confirmação antes de trocar. A lista é REVERTIDA já — Esc/Cancelar deixam tudo
    // consistente; só o Confirmar efetiva a troca.
    final antigo = prestador;
    final rotulo =
        ddPrestador.opcoes
            .where((o) => o.chave == novo)
            .map((o) => o.texto)
            .firstOrNull ??
        formatarDocumento(novo);
    ddPrestador.por(antigo);
    ddPrestador.avisar();
    mostrarDialogo(
      Dialogo(
        titulo: (_) => textoTitulo('Trocar de prestador'),
        largura: 440,
        conteudo: (_) => col(
          [
            Tx(
              'Trocar o prestador ativo para:\n$rotulo?',
              largura: TamanhosDialogos
                  .rotuloTrocarOPrestadorAtivoParaNRotulo
                  .largura,
              altura: TamanhosDialogos
                  .rotuloTrocarOPrestadorAtivoParaNRotulo
                  .altura,
              idLayout:
                  'TamanhosDialogos.rotuloTrocarOPrestadorAtivoParaNRotulo',
            ),
            Tx(
              'As telas (emissão, clientes, consultas) passam a mostrar os dados '
              'do prestador escolhido.',
              tam: Letra.apoio,
              cor: Colors.grey.shade700,
              largura: TamanhosDialogos
                  .rotuloAsTelasEmissaoClientesConsultasPassamAMostrar
                  .largura,
              altura: TamanhosDialogos
                  .rotuloAsTelasEmissaoClientesConsultasPassamAMostrar
                  .altura,
              idLayout:
                  'TamanhosDialogos.rotuloAsTelasEmissaoClientesConsultasPassamAMostrar',
            ),
          ],
          justa: true,
          espaco: 8,
          idLayout: 'Grupo.app.col.2',
        ),
        acoes: (_) => [
          Botao.texto(
            'Cancelar',
            aoClicar: fecharDialogo,
            largura: TamanhosDialogos.botaoCancelar2.largura,
            altura: TamanhosDialogos.botaoCancelar2.altura,
            idLayout: 'TamanhosDialogos.botaoCancelar2',
          ),
          Botao(
            'Trocar',
            icone: Icons.swap_horiz,
            aoClicar: () {
              fecharDialogo();
              ddPrestador.por(novo);
              trocarPrestador(novo);
            },
            largura: TamanhosDialogos.botaoTrocar.largura,
            altura: TamanhosDialogos.botaoTrocar.altura,
            idLayout: 'TamanhosDialogos.botaoTrocar',
          ),
        ],
        idLayout: 'Janela.app.Dialogo.2',
      ),
    );
  }

  void trocarPrestador(String documento) {
    final novo = documento;
    if (novo.isNotEmpty && novo != prestador) {
      registrar('Prestador selecionado: ${formatarDocumento(novo)}');
    }
    prestador = novo;
    semPrestador = novo.isEmpty && !usuario.master;
    if (novo.isNotEmpty) {
      try {
        ja<Object?>('cadastro.guardar_ultimo_prestador', {
          'usuario_id': usuario.id,
          'documento': novo,
        });
      } catch (e) {
        registrar(
          'Falha ao guardar o último prestador selecionado: $e',
          nivel: 'error',
        );
        toast('Não foi possível lembrar o prestador selecionado.', erro: true);
      }
    }
    cert = prestador.isEmpty
        ? ''
        : ja<String>('cadastro.active_cert', {'prestador': prestador});
    ambiente = prestador.isEmpty
        ? ambProducao
        : ja<String>('cadastro.get_ambiente', {'prestador': prestador});
    lotesPendentes = 0;
    unawaited(atualizarLotesPendentes());
    // Zera TODO estado preso ao prestador anterior.
    emailCfg = null; // config de e-mail é POR prestador
    for (final f in List.of(aoTrocarPrestador)) {
      f();
    }
    ddPrestador.por(prestador);
    ddPrestador.avisar();
    // Fila de contingência é POR prestador: reinicia o ciclo/aviso para o novo.
    pararFila?.call();
    refazerAvisoFila?.call();
    for (final f in List.of(recarregarTelas)) {
      f();
    }
    // Re-renderiza a ABA ATUAL já com os dados do novo prestador (ficou sem prestador: vai
    // para as Configurações, a única tela que funciona assim).
    irPara(prestador.isEmpty ? 3 : navAtual);
  }

  // ---- aparência ------------------------------------------------------------------ //
  /// Troca as cores de superfície do programa INTEIRO, na hora (não grava nada).
  void aplicarAparencia(String fundo, String cartoes) {
    aparenciaAtual = Aparencia(fundo, cartoes);
    fundoPrevia.value = null;
    aoMudarAparencia();
  }
}
