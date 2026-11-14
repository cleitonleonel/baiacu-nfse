/// Tela CONFIGURAÇÕES: cada aba é uma coluna rolável de cartões. O que é do prestador em uso
/// (dados, tributos, certificado, ambiente, e-mail) e o que é do programa inteiro
/// (personalização, leitor de PDF, backup, sincronização do Cofre).
///
/// A tela é guardada POR PRESTADOR: só é remontada na 1ª vez, na troca de prestador ou quando
/// invalidada (ex.: depois de importar um certificado).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app.dart';
import '../app/atualizacao.dart';
import '../app/doacao.dart' show BotaoContribuir;
import '../app/prestador_novo.dart' show tiposDocumento;
import '../acesso/acesso.dart' show metaAnimacaoLogin;
import '../app/sistema.dart' show abrirEndereco;
import '../editor/editor_rico.dart';
import '../kit/arquivos.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import '../kit/tamanhos_arquivo.dart';
import '../tema.dart';
import 'cofre.dart' show intervaloTexto;

const _emailFontes = [
  'Arial',
  'Verdana',
  'Tahoma',
  'Georgia',
  'Times New Roman',
  'Courier New',
];
const _emailTamanhos = ['10', '11', '12', '14', '16', '18', '24'];

/// Largura da mensagem (barra + texto do editor, código HTML): a barra do editor cabe numa
/// linha só e alinha com "E-mail remetente | Nome do remetente" (320+10+320).
const _emailLargura = 650.0;
const _emailVariaveis = [
  '{numero}',
  '{chave}',
  '{tomador}',
  '{prestador}',
  '{valor}',
  '{url_consulta}',
  '{url_consulta_full}',
];

const _textoSenhaMestra =
    'Com ela e o arquivo dados.db abre-se o banco inteiro em qualquer '
    'computador e redefine-se o usuário master. Sem ela, se as senhas dos '
    'usuários forem esquecidas, os dados do banco não podem ser recuperados.';

const _metaPdfNativo =
    'ui.pdf_nativo'; // "0" = abrir PDF no leitor padrão do Windows
const _nivelMaster = 4;

/// (chave, rótulo) dos percentuais de tributos do prestador.
const _tributosPrestador = [
  ('pAliqPis', 'PIS'),
  ('pAliqCofins', 'COFINS'),
  ('irrf', 'IRRF'),
  ('csll', 'CSLL'),
  ('pTotTribFed', 'Federal'),
  ('pTotTribEst', 'Estadual'),
  ('pTotTribMun', 'Municipal'),
];

const _opcoesAmbiente = [
  Opcao(ambProducao, 'Produção'),
  Opcao(ambHomologacao, 'Homologação'),
];

/// Como o registro escreve um valor (o mesmo jeito de sempre: 'texto', True/False, {…}).
String _repr(Object? v) => switch (v) {
  null => 'None',
  true => 'True',
  false => 'False',
  String s => "'$s'",
  Map m =>
    '{${m.entries.map((e) => '${_repr(e.key)}: ${_repr(e.value)}').join(', ')}}',
  Iterable l => '[${l.map(_repr).join(', ')}]',
  _ => '$v',
};

String _mb(num bytes) => tamanhoArquivo(bytes);

/// Arredondamento "do banco" (meio vai para o par), como o dos rótulos de sempre.
double _arredPar(double x) {
  final f = x.floorToDouble();
  final d = x - f;
  if (d > 0.5) return f + 1;
  if (d < 0.5) return f;
  return f % 2 == 0 ? f : f + 1;
}

Widget _moldura(List<Widget> filhos) => SizedBox(
  width: 900,
  child: cartao(
    Ct(
      padding: const EdgeInsets.all(20),
      child: col(
        filhos,
        espaco: 12,
        idLayout: 'Grupo.config.cartao.${(filhos.first as Tx).valor}',
      ),
    ),
  ),
);

Widget _tituloCartao(String t) => Tx(
  t,
  tam: Letra.subtitulo,
  peso: FontWeight.bold,
  largura: TamanhosConfiguracoes.rotuloT.largura,
  altura: TamanhosConfiguracoes.rotuloT.altura,
  idLayout: 'TamanhosConfiguracoes.rotuloT:$t',
);

Widget _nota(String t) => Tx(
  t,
  tam: Letra.apoio,
  cor: Colors.grey.shade700,
  largura: TamanhosConfiguracoes.rotuloT2.largura,
  altura: TamanhosConfiguracoes.rotuloT2.altura,
  idLayout: 'TamanhosConfiguracoes.rotuloT2:$t',
);

class TelaConfig extends StatefulWidget {
  const TelaConfig({super.key, required this.app});
  final App app;

  @override
  State<TelaConfig> createState() => ConfigState();
}

class ConfigState extends State<TelaConfig> {
  App get app => widget.app;

  bool _montada = false;
  String? _montadaPara;
  bool _temPrestador = false;
  int _geracao = 0;
  List<_Cartao> _cartoes = const [];

  /// Os cartões registram aqui as suas "travas": cada uma re-trava o cartão descartando o
  /// que não foi salvo e devolve true se havia edição aberta.
  final List<bool Function()> travas = [];

  /// Arquivo .pfx escolhido em cada cartão de certificado (sobrevive à remontagem da tela).
  final Map<String, String> certCaminhos = {};

  _CartaoPrestador? _prestador;
  _CartaoTributos? _tributos;
  List<_Cartao> _certificados = const [];
  _CartaoAmbiente? _ambiente;
  _CartaoEmail? _email;
  late _CartaoPersonalizacao _personalizacao;
  late _CartaoPdf _pdf;
  late _CartaoBanco _banco;
  late _CartaoProtecao _protecao;
  late _CartaoSenhaMestra _senhaMestra;
  late _CartaoSincronizacao _sincronizacao;
  late _CartaoAtualizacao _atualizacao;
  late _CartaoApoio _apoio;

  @override
  void initState() {
    super.initState();
    app.aoEntrar[3] = _entrar;
    app.retravarConfig = retravar;
    // Quando é a primeira tela do programa (sem prestador ativo) ninguém "entra" nela: monta-se
    // sozinha, depois do primeiro quadro.
    if (app.navAtual == 3) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entrar();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _cartoes) {
      c.descartar();
    }
    super.dispose();
  }

  void _entrar() {
    if (_montada && _montadaPara == app.prestador) return;
    _montar();
    if (mounted) setState(() {});
  }

  /// A próxima entrada na tela a monta de novo (ex.: o certificado mudou).
  void invalidar() => _montadaPara = null;

  void _montar() {
    final velhos = _cartoes;
    travas.clear();
    final tem = app.prestador.isNotEmpty;
    _temPrestador = tem;
    // Avançado reúne, em sub-abas, o que não é do dia a dia.
    _email = tem ? _CartaoEmail(this) : null;
    _pdf = _CartaoPdf(this);
    _banco = _CartaoBanco(this);
    _protecao = _CartaoProtecao(this);
    _senhaMestra = _CartaoSenhaMestra(this);
    _sincronizacao = _CartaoSincronizacao(this);
    _prestador = tem ? _CartaoPrestador(this) : null;
    _tributos = tem ? _CartaoTributos(this) : null;
    _certificados = tem ? _cartoesDeCertificado() : const [];
    _ambiente = tem ? _CartaoAmbiente(this) : null;
    _personalizacao = _CartaoPersonalizacao(this);
    _atualizacao = _CartaoAtualizacao(this);
    _apoio = _CartaoApoio(this);
    _cartoes = [
      ?_email,
      _pdf,
      _banco,
      _protecao,
      _senhaMestra,
      _sincronizacao,
      ?_prestador,
      ?_tributos,
      ..._certificados,
      ?_ambiente,
      _personalizacao,
      _atualizacao,
      _apoio,
    ];
    _geracao++;
    _montada = true;
    _montadaPara = app.prestador;
    // Os de antes ainda estão na tela até o próximo quadro.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in velhos) {
        c.descartar();
      }
    });
  }

  /// Certificado próprio, um cartão por procurador e o de adicionar procurador.
  List<_Cartao> _cartoesDeCertificado() {
    final procuradores = ja<List>('cadastro.list_procuradores', {
      'prestador': app.prestador,
    }).cast<String>();
    return [
      _CartaoCertificado(this),
      for (final (i, p) in procuradores.indexed)
        _CartaoCertificado(
          this,
          tipo: _TipoCert.procurador,
          procurador: p,
          numero: i + 1,
        ),
      _CartaoCertificado(
        this,
        tipo: _TipoCert.novoProcurador,
        numero: procuradores.length + 1,
      ),
    ];
  }

  /// Remonta só os cartões de certificado (um procurador entrou ou saiu), sem tirar o usuário
  /// da aba em que está.
  void recarregarCertificados() {
    if (!_temPrestador || !mounted) return;
    final velhos = _certificados;
    _certificados = _cartoesDeCertificado();
    _cartoes = [
      for (final c in _cartoes)
        if (!velhos.contains(c)) c,
      ..._certificados,
    ];
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in velhos) {
        c.descartar();
      }
    });
  }

  /// Re-trava TODOS os cartões, descartando o que não foi salvo (ao trocar de aba interna,
  /// de tela no painel lateral e pelo Esc). Travar um cartão já travado é inofensivo.
  /// Devolve true se havia alguma edição aberta.
  bool retravar() {
    var havia = false;
    for (final trava in List.of(travas)) {
      try {
        havia = trava() || havia;
      } catch (_) {
        // cartão fora da página não pode travar a navegação
      }
    }
    return havia;
  }

  // ---- deletar o prestador em uso ------------------------------------------------------------ //
  void confirmarDeletarPrestador() {
    final doc = app.prestador;
    if (doc.isEmpty) return;
    late final Dialogo d1, d2;
    late final TextEditingController campo;
    var apagando = false;
    final vermelho = Colors.red.shade700;

    void travar(bool sim) {
      apagando = sim;
      d1.atualizar();
      d2.atualizar();
    }

    void feito() {
      app.cofreApagando.remove(doc); // já saiu da lista de prestadores
      registrar(
        'Prestador DELETADO: ${formatarDocumento(doc)}',
        nivel: 'warning',
      );
      app.fecharEsta(d2); // os dois avisos (o de cima primeiro)
      app.fecharEsta(d1);
      app.recarregarPrestadores();
      final resto = app.ddPrestador.opcoes;
      final novo = resto.isEmpty ? '' : resto.first.chave;
      app.ddPrestador.por(novo);
      app.trocarPrestador(novo);
      _entrar();
      app.atualizar();
      app.toast('Prestador ${formatarDocumento(doc)} deletado.');
    }

    void falhou(String msg) {
      app.cofreApagando.remove(doc);
      travar(false);
      app.toast(msg, erro: true);
    }

    void deletar() {
      if (apagando) return;
      if (soDoc(campo.text) != soDoc(doc)) {
        app.toast(
          'Documento não confere. Digite exatamente para confirmar.',
          erro: true,
        );
        return;
      }
      // Documento conferido: ainda falta dizer que SIM num segundo aviso — é dele o botão
      // que apaga de fato.
      app.mostrarDialogo(d2);
    }

    void deletarMesmo() {
      if (apagando) return;
      // Para o que estiver rodando em nome dele (sincronização do Cofre, reenvio da fila) e
      // apaga em segundo plano: com muitas notas e arquivos leva alguns segundos, e a tela
      // não pode ficar congelada nesse meio-tempo.
      app.cofreApagando.add(
        doc,
      ); // antes do cancelamento: a sincronização vê ao parar
      app.cofreCancelarSinc?.call();
      app.pararFila?.call();
      travar(true);
      app.emSegundoPlano(() async {
        try {
          await chamar<Object?>('cadastro.delete_prestador', {
            'documento': doc,
          });
        } catch (e) {
          registrar(
            'Falha ao deletar o prestador ${formatarDocumento(doc)}: $e',
            nivel: 'error',
          );
          falhou('$e');
          return;
        }
        feito();
        // Depois, sem prender a tela: as DANFSe temporárias do Cofre saem, o arquivo do
        // banco de notas devolve o espaço das notas apagadas e a cópia de segurança é
        // refeita a partir dele.
        try {
          await chamar<Object?>('cofre.limpar_temporarios', {
            'mais_velhos_que_s': 0,
          });
          await chamar<Object?>('cofre.compactar_arquivo');
        } catch (e) {
          // o prestador já foi apagado; isto é faxina
          registrar(
            'Falha ao compactar o banco de notas depois da exclusão: $e',
            nivel: 'error',
          );
        }
      });
    }

    d2 = Dialogo(
      titulo: (_) => LinhaTitulo([
        Icon(Icons.warning_amber, color: vermelho),
        textoTitulo('Tem certeza?'),
      ], espaco: 10),
      largura: 520,
      conteudo: (_) => col(
        [
          Tx(
            'O prestador ${formatarDocumento(doc)} e TUDO o que é dele vão ser '
            'apagados agora, de vez: cadastro, clientes, certificado, numeração '
            'e todas as notas dele guardadas no Cofre, emitidas e recebidas.',
            largura: TamanhosConfiguracoes
                .rotuloOPrestadorFormatarDocumentoDocETUDOOQue
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloOPrestadorFormatarDocumentoDocETUDOOQue
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloOPrestadorFormatarDocumentoDocETUDOOQue',
          ),
          Tx(
            'Isto não pode ser desfeito.',
            peso: FontWeight.bold,
            cor: vermelho,
            largura: TamanhosConfiguracoes.rotuloIstoNaoPodeSerDesfeito.largura,
            altura: TamanhosConfiguracoes.rotuloIstoNaoPodeSerDesfeito.altura,
            idLayout: 'TamanhosConfiguracoes.rotuloIstoNaoPodeSerDesfeito',
          ),
        ],
        justa: true,
        espaco: 10,
        idLayout: 'Grupo.config.col.2',
      ),
      acoes: (_) => [
        Botao.texto(
          'Não, voltar',
          aoClicar: app.fecharDialogo,
          desabilitado: apagando,
          largura: TamanhosConfiguracoes.botaoNaoVoltar.largura,
          altura: TamanhosConfiguracoes.botaoNaoVoltar.altura,
          idLayout: 'TamanhosConfiguracoes.botaoNaoVoltar',
        ),
        Botao(
          apagando ? 'Apagando…' : 'Sim, deletar tudo',
          icone: Icons.delete_forever,
          fundo: vermelho,
          cor: Colors.white,
          desabilitado: apagando,
          aoClicar: deletarMesmo,
          largura:
              TamanhosConfiguracoes.botaoApagandoApagandoSimDeletarTudo.largura,
          altura:
              TamanhosConfiguracoes.botaoApagandoApagandoSimDeletarTudo.altura,
          idLayout: 'TamanhosConfiguracoes.botaoApagandoApagandoSimDeletarTudo',
        ),
      ],
      idLayout: 'Janela.config.Dialogo.1',
    );
    d1 = Dialogo(
      titulo: (_) => LinhaTitulo([
        Icon(Icons.warning_amber, color: vermelho),
        textoTitulo('Deletar prestador'),
      ], espaco: 10),
      largura: 560,
      conteudo: (_) => col(
        [
          Tx(
            'Você vai apagar PERMANENTEMENTE o prestador ${formatarDocumento(doc)} '
            'e todos os seus dados: clientes, grupos, certificado, numeração e '
            'todas as notas dele guardadas no Cofre, emitidas e recebidas. Não há '
            'como desfazer.',
            largura: TamanhosConfiguracoes
                .rotuloVoceVaiApagarPERMANENTEMENTEOPrestadorFormatarDocumentoDoc
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloVoceVaiApagarPERMANENTEMENTEOPrestadorFormatarDocumentoDoc
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloVoceVaiApagarPERMANENTEMENTEOPrestadorFormatarDocumentoDoc',
          ),
          CampoTexto(
            controle: campo,
            rotulo: 'Digite o documento para confirmar',
            largura: TamanhosConfiguracoes
                .campoDigiteODocumentoParaConfirmar
                .largura,
            dica: formatarDocumento(doc),
            desabilitado: apagando,
            altura:
                TamanhosConfiguracoes.campoDigiteODocumentoParaConfirmar.altura,
            idLayout:
                'TamanhosConfiguracoes.campoDigiteODocumentoParaConfirmar',
          ),
        ],
        justa: true,
        espaco: 12,
        idLayout: 'Grupo.config.col.3',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          desabilitado: apagando,
          largura: TamanhosConfiguracoes.botaoCancelar.largura,
          altura: TamanhosConfiguracoes.botaoCancelar.altura,
          idLayout: 'TamanhosConfiguracoes.botaoCancelar',
        ),
        Botao(
          'Deletar definitivamente',
          icone: Icons.delete_forever,
          fundo: vermelho,
          cor: Colors.white,
          desabilitado: apagando,
          aoClicar: deletar,
          largura: TamanhosConfiguracoes.botaoDeletarDefinitivamente.largura,
          altura: TamanhosConfiguracoes.botaoDeletarDefinitivamente.altura,
          idLayout: 'TamanhosConfiguracoes.botaoDeletarDefinitivamente',
        ),
      ],
      idLayout: 'Janela.config.Dialogo.2',
    );
    campo = d1.texto();
    app.mostrarDialogo(d1);
  }

  // ---- desenho ----------------------------------------------------------------------------------- //
  @override
  Widget build(BuildContext context) {
    if (!_montada) return const SizedBox.expand();
    final tem = _temPrestador;
    // Cada aba é uma coluna rolável com os cartões correspondentes.
    Widget painel(List<_Cartao> cartoes) => Ct(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 0),
      child: col(
        [for (final c in cartoes) _Quadro(c)],
        espaco: 18,
        rolar: true,
        idLayout:
            'Grupo.config.painel.${cartoes.map((c) => c.runtimeType.toString()).join('.')}',
      ),
    );
    // Trocar de aba (ou de sub-aba) com uma edição aberta re-trava o cartão (segurança).
    void aoMudar(int _) => retravar();

    final avancado = Ct(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 0),
      child: Abas(
        key: ValueKey('avancado-$_geracao'),
        secundaria: true,
        inicial: tem ? 0 : 2,
        // Sem prestador, do Avançado só o Backup (é onde se restaura um backup numa instalação nova).
        desabilitadas: tem ? const {} : const {0, 1, 3},
        aoMudar: aoMudar,
        rotulos: const [
          ('E-mail', Icons.email_outlined),
          ('PDF', Icons.picture_as_pdf_outlined),
          ('Backup', Icons.backup_outlined),
          ('Cofre', Icons.lock_outlined),
          ('Atualizações', Icons.system_update_alt),
        ],
        paineis: [
          tem ? painel([_email!]) : const Ct(),
          painel([_pdf]),
          painel([_banco, _protecao, _senhaMestra]),
          painel([_sincronizacao]),
          painel([_atualizacao]),
        ],
      ),
    );
    return col(
      [
        Tx(
          'Configurações',
          tam: Letra.titulo,
          peso: FontWeight.bold,
          largura: TamanhosConfiguracoes.rotuloConfiguracoes.largura,
          altura: TamanhosConfiguracoes.rotuloConfiguracoes.altura,
          idLayout: 'TamanhosConfiguracoes.rotuloConfiguracoes',
        ),
        Expanded(
          // Sem prestador só valem Personalização e Avançado — e a tela abre em Avançado ›
          // Backup, que é onde se restaura um backup numa instalação nova.
          child: Abas(
            key: ValueKey('config-$_geracao'),
            inicial: tem ? 0 : 4,
            desabilitadas: tem ? const {} : const {0, 1, 2},
            aoMudar: aoMudar,
            rotulos: const [
              ('Prestador', Icons.badge),
              ('Certificado', Icons.verified_user),
              ('Ambiente', Icons.tune),
              ('Personalização', Icons.palette_outlined),
              ('Avançado', Icons.settings_suggest_outlined),
              ('Apoie este projeto', Icons.favorite_border),
            ],
            paineis: [
              tem ? painel([_prestador!, _tributos!]) : const Ct(),
              tem ? painel(_certificados) : const Ct(),
              tem ? painel([_ambiente!]) : const Ct(),
              painel([_personalizacao]),
              avancado,
              painel([_apoio]),
            ],
          ),
        ),
      ],
      espaco: 12,
      idLayout: 'Grupo.config.col.5',
    );
  }
}

// ------------------------------------------------------------------------------------------- //
// Base dos cartões
// ------------------------------------------------------------------------------------------- //
/// Um cartão das Configurações: guarda os campos e o que eles têm AGORA (lidos uma vez, quando
/// a tela é montada) e se redesenha sozinho.
abstract class _Cartao extends ChangeNotifier {
  _Cartao(this.pai);
  final ConfigState pai;
  App get app => pai.app;
  bool _vivo = true;

  void redesenhar() {
    if (_vivo) notifyListeners();
  }

  Widget construir(BuildContext context);

  @mustCallSuper
  void descartar() {
    if (!_vivo) return;
    _vivo = false;
    dispose();
  }
}

class _Quadro extends StatelessWidget {
  const _Quadro(this.cartao);
  final _Cartao cartao;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: cartao,
    builder: (context, _) => cartao.construir(context),
  );
}

/// Um valor editável do cartão: como ler e como pôr de volta.
class _Valor {
  const _Valor(this.ler, this.por);
  final Object? Function() ler;
  final void Function(Object?) por;
}

_Valor _texto(TextEditingController c) =>
    _Valor(() => c.text, (v) => c.text = v as String);

_Valor _lista(Suspensa s) => _Valor(() => s.valor, (v) {
  s.por(v as String?);
  s.avisar();
});

/// Par de botões Editar/Salvar de um cartão.
///
/// Começa TRAVADO. "Editar" pede a senha do nível e libera; "Salvar" chama `salvar` (que
/// devolve true em sucesso) e re-trava. Sair da aba/tela SEM salvar volta aos valores de
/// quando a edição foi aberta.
class _Edicao {
  _Edicao(
    this.dono, {
    required this.nivel,
    required this.titulo,
    required this.salvar,
    required this.valores,
    this.rotuloSalvar = 'Salvar',
    this.rotuloEditar = 'Editar',
    this.focar,
  }) {
    dono.pai.travas.add(retravarDescartando);
  }

  final _Cartao dono;
  final int nivel;
  final String titulo;
  final bool Function() salvar;
  final String rotuloSalvar;
  final String rotuloEditar;
  final List<_Valor> valores;

  /// O primeiro controle do cartão. O programa sempre PEDIU o foco para ele ao liberar, mas o
  /// pedido chegava antes de o campo deixar de estar desabilitado e não tinha efeito: liberar
  /// a edição nunca moveu o foco, e continua assim.
  final FocusNode? focar;

  bool aberto = false;
  List<Object?> _guardados = const [];

  bool get travado => !aberto;

  void _destravar() {
    _guardados = [for (final v in valores) v.ler()];
    aberto = true;
    dono.redesenhar();
  }

  void _aoSalvar() {
    if (salvar()) {
      aberto = false;
      dono.redesenhar();
    }
  }

  bool retravarDescartando() {
    if (!aberto) return false;
    for (var i = 0; i < valores.length; i++) {
      try {
        valores[i].por(_guardados[i]);
      } catch (_) {}
    }
    aberto = false;
    dono.redesenhar();
    return true;
  }

  List<Widget> botoes() => [
    if (travado)
      Botao.contorno(
        rotuloEditar,
        icone: Icons.edit,
        aoClicar: () => dono.app.exigirNivel(nivel, _destravar, titulo: titulo),
        largura: TamanhosConfiguracoes.botaoEditar.largura,
        altura: TamanhosConfiguracoes.botaoEditar.altura,
        idLayout: 'TamanhosConfiguracoes.botaoEditar',
      )
    else
      Botao(
        rotuloSalvar,
        icone: Icons.save,
        aoClicar: _aoSalvar,
        largura: TamanhosConfiguracoes.botaoRotuloSalvar.largura,
        altura: TamanhosConfiguracoes.botaoRotuloSalvar.altura,
        idLayout: 'TamanhosConfiguracoes.botaoRotuloSalvar',
      ),
  ];
}

// ------------------------------------------------------------------------------------------- //
// Prestador
// ------------------------------------------------------------------------------------------- //
class _CartaoPrestador extends _Cartao {
  _CartaoPrestador(super.pai) {
    final pf = jaMapa('cadastro.get_prestador_form', {
      'prestador': app.prestador,
    });
    String s(String k) => (pf[k] as String?) ?? '';
    // Tipo e documento são a IDENTIDADE do prestador (é com ela que o cadastro, o
    // certificado, a numeração e as notas estão guardados): ficam SEMPRE travados, mostrando
    // o documento do prestador em uso. Para outro documento, cria-se outro prestador.
    final doc = soDoc(app.prestador);
    _tipo = Suspensa(opcoes: tiposDocumento)
      ..por(doc.length == 11 ? 'CPF' : 'CNPJ');
    _doc.text = doc;
    _nomeExib.text = s('nome_exib');
    _im.text = s('IM');
    _nome.text = s('xNome');
    _fone.text = s('fone');
    _email.text = s('email');
    _locEmi.text = s('cLocEmi');
    _simp = Suspensa(
      opcoes: const [
        Opcao('1', '1 - Não optante'),
        Opcao('2', '2 - MEI'),
        Opcao('3', '3 - ME/EPP'),
      ],
    )..por(s('opSimpNac'));
    _regAp.text = s('regApTribSN');
    _regEsp.text = s('regEspTrib');
    _edicao = _Edicao(
      this,
      nivel: 3,
      titulo: 'Editar prestador',
      salvar: _salvar,
      rotuloSalvar: 'Salvar dados do prestador',
      // tipo e documento: fora (travados)
      valores: [
        _texto(_nomeExib),
        _texto(_im),
        _texto(_nome),
        _texto(_fone),
        _texto(_email),
        _texto(_locEmi),
        _lista(_simp),
        _texto(_regAp),
        _texto(_regEsp),
      ],
      focar: _focoNomeExib,
    );
  }

  late final Suspensa _tipo, _simp;
  late final _Edicao _edicao;
  final _doc = TextEditingController();
  final _nomeExib = TextEditingController();
  final _focoNomeExib = FocusNode();
  final _im = TextEditingController();
  final _nome = TextEditingController();
  final _fone = TextEditingController();
  final _email = TextEditingController();
  final _locEmi = TextEditingController();
  final _regAp = TextEditingController();
  final _regEsp = TextEditingController();

  @override
  void descartar() {
    for (final c in [
      _doc,
      _nomeExib,
      _im,
      _nome,
      _fone,
      _email,
      _locEmi,
      _regAp,
      _regEsp,
    ]) {
      c.dispose();
    }
    _focoNomeExib.dispose();
    _tipo.dispose();
    _simp.dispose();
    super.descartar();
  }

  void _preencherDoCertificado() {
    final sujeito =
        ja<String?>('cadastro.cert_subject', {
          'prestador': app.prestador,
          'cert':
              app.prestador, // o certificado PRÓPRIO, nunca o de um procurador
        }) ??
        '';
    if (sujeito.isEmpty) {
      app.toast(
        'Não foi possível ler o certificado (configure-o abaixo).',
        erro: true,
      );
      return;
    }
    var cn = '';
    for (final parte in sujeito.split(',')) {
      final p = parte.trim();
      if (p.toUpperCase().startsWith('CN=')) {
        cn = p.substring(3);
        break;
      }
    }
    final nome = cn.isEmpty ? '' : cn.split(':').first.trim();
    if (nome.isNotEmpty) {
      _nome.text = nome;
      redesenhar();
      app.toast('Nome preenchido a partir do certificado.');
    }
  }

  bool _salvar() {
    final novo = <String, Object?>{
      'tipo_doc': _tipo.valor ?? 'CNPJ',
      'documento': _doc.text,
      'nome_exib': _nomeExib.text,
      'IM': _im.text,
      'xNome': _nome.text,
      'fone': _fone.text,
      'email': _email.text,
      'cLocEmi': _locEmi.text,
      'opSimpNac': _simp.valor ?? '1',
      'regApTribSN': _regAp.text,
      'regEspTrib': _regEsp.text.isEmpty ? '0' : _regEsp.text,
    };
    try {
      final erros = ja<List>('cadastro.prestador_validate', {
        'form': novo,
      }).cast<String>();
      if (erros.isNotEmpty) {
        app.toast('Corrija: ${erros.join('; ')}', erro: true);
        return false;
      }
      ja<Object?>('cadastro.save_prestador_form', {
        'prestador': app.prestador,
        'form': novo,
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return false;
    }
    registrar('Dados do prestador salvos (prestador=${app.prestador})');
    app.toast('Dados do prestador salvos.');
    // o nome de exibição pode ter mudado: a lista de prestadores é refeita
    app.recarregarPrestadores();
    app.ddPrestador.por(app.prestador);
    app.ddPrestador.avisar();
    app.atualizar();
    return true;
  }

  @override
  Widget construir(BuildContext context) {
    final t = _edicao.travado;
    return _moldura([
      _tituloCartao('Prestador'),
      // PRIMEIRO campo: nome de exibição
      lin(
        [
          CampoTexto(
            controle: _nomeExib,
            foco: _focoNomeExib,
            rotulo: 'Nome de exibição (lista de prestadores)',
            largura: TamanhosConfiguracoes
                .campoNomeDeExibicaoListaDePrestadores
                .largura,
            maximo: 40,
            dica: 'Ex.: Matriz SP, Loja Centro…',
            desabilitado: t,
            altura: TamanhosConfiguracoes
                .campoNomeDeExibicaoListaDePrestadores
                .altura,
            idLayout:
                'TamanhosConfiguracoes.campoNomeDeExibicaoListaDePrestadores',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.1',
      ),
      divisor(),
      lin(
        [
          ListaSuspensa(
            estado: _tipo,
            rotulo: 'Tipo',
            largura: TamanhosConfiguracoes.campoTipo.largura!,
            desabilitado: true,
            altura: TamanhosConfiguracoes.campoTipo.altura,
            idLayout: 'TamanhosConfiguracoes.campoTipo',
          ),
          CampoTexto(
            controle: _doc,
            rotulo: 'Documento',
            largura: TamanhosConfiguracoes.campoDocumento.largura,
            desabilitado: true,
            altura: TamanhosConfiguracoes.campoDocumento.altura,
            idLayout: 'TamanhosConfiguracoes.campoDocumento',
          ),
          CampoTexto(
            controle: _im,
            rotulo: 'Inscrição municipal',
            largura: TamanhosConfiguracoes.campoInscricaoMunicipal.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoInscricaoMunicipal.altura,
            idLayout: 'TamanhosConfiguracoes.campoInscricaoMunicipal',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.2',
      ),
      lin(
        [
          CampoTexto(
            controle: _nome,
            rotulo: 'Razão social / Nome',
            largura: TamanhosConfiguracoes.campoRazaoSocialNome.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoRazaoSocialNome.altura,
            idLayout: 'TamanhosConfiguracoes.campoRazaoSocialNome',
          ),
          Botao.contorno(
            'Preencher do certificado',
            icone: Icons.badge,
            desabilitado: t,
            aoClicar: _preencherDoCertificado,
            largura: TamanhosConfiguracoes.botaoPreencherDoCertificado.largura,
            altura: TamanhosConfiguracoes.botaoPreencherDoCertificado.altura,
            idLayout: 'TamanhosConfiguracoes.botaoPreencherDoCertificado',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.3',
      ),
      lin(
        [
          CampoTexto(
            controle: _fone,
            rotulo: 'Telefone',
            largura: TamanhosConfiguracoes.campoTelefone.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoTelefone.altura,
            idLayout: 'TamanhosConfiguracoes.campoTelefone',
          ),
          CampoTexto(
            controle: _email,
            rotulo: 'E-mail',
            largura: TamanhosConfiguracoes.campoEMail.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoEMail.altura,
            idLayout: 'TamanhosConfiguracoes.campoEMail',
          ),
          CampoTexto(
            controle: _locEmi,
            rotulo: 'cLocEmi (município, IBGE)',
            largura: TamanhosConfiguracoes.campoCLocEmiMunicipioIBGE.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoCLocEmiMunicipioIBGE.altura,
            idLayout: 'TamanhosConfiguracoes.campoCLocEmiMunicipioIBGE',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.4',
      ),
      lin(
        [
          ListaSuspensa(
            estado: _simp,
            rotulo: 'opSimpNac',
            largura: TamanhosConfiguracoes.campoOpSimpNac.largura!,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoOpSimpNac.altura,
            idLayout: 'TamanhosConfiguracoes.campoOpSimpNac',
          ),
          CampoTexto(
            controle: _regAp,
            rotulo: 'regApTribSN',
            largura: TamanhosConfiguracoes.campoRegApTribSN.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoRegApTribSN.altura,
            idLayout: 'TamanhosConfiguracoes.campoRegApTribSN',
          ),
          CampoTexto(
            controle: _regEsp,
            rotulo: 'regEspTrib',
            largura: TamanhosConfiguracoes.campoRegEspTrib.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoRegEspTrib.altura,
            idLayout: 'TamanhosConfiguracoes.campoRegEspTrib',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.5',
      ),
      // "Deletar prestador" fica na MESMA linha do Editar, encostado à direita. Sempre
      // ativo, com a senha de nível 4.
      lin([
        ..._edicao.botoes(),
        const Expanded(child: SizedBox()),
        Botao.contorno(
          'Deletar prestador',
          icone: Icons.delete_forever,
          cor: Colors.red.shade700,
          dica:
              'Remove TODOS os dados deste prestador (clientes, grupos, certificado, '
              'numeração e NFS-e emitidas). Irreversível.',
          aoClicar: () => app.exigirNivel(
            4,
            pai.confirmarDeletarPrestador,
            titulo: 'Deletar prestador',
          ),
          largura: TamanhosConfiguracoes.botaoDeletarPrestador.largura,
          altura: TamanhosConfiguracoes.botaoDeletarPrestador.altura,
          idLayout: 'TamanhosConfiguracoes.botaoDeletarPrestador',
        ),
      ], idLayout: 'Grupo.config.lin.6'),
    ]);
  }
}

// ------------------------------------------------------------------------------------------- //
// Tributos do prestador
// ------------------------------------------------------------------------------------------- //
/// Os percentuais de tributos DESTE prestador. Valem para todos os clientes e serviços dele;
/// o cadastro de cada serviço (e a tela Emitir) pode usar outro percentual só naquele
/// serviço. Um prestador novo nasce com eles em branco.
class _CartaoTributos extends _Cartao {
  _CartaoTributos(super.pai) {
    final trib = {
      for (final (k, v) in jaPares('cadastro.read_tributos', {
        'prestador': app.prestador,
      }))
        k: v,
    };
    for (final (chave, _) in _tributosPrestador) {
      _campos[chave] = TextEditingController(
        text: pctVirgula(trib[chave] ?? ''),
      );
    }
    _edicao = _Edicao(
      this,
      nivel: 3,
      titulo: 'Editar tributos do prestador',
      salvar: _salvar,
      rotuloSalvar: 'Salvar tributos',
      valores: [for (final c in _campos.values) _texto(c)],
      focar: _foco,
    );
    _situacao();
  }

  final Map<String, TextEditingController> _campos = {};
  final _foco = FocusNode();
  late final _Edicao _edicao;
  String _aviso = '';

  @override
  void descartar() {
    for (final c in _campos.values) {
      c.dispose();
    }
    _foco.dispose();
    super.descartar();
  }

  void _situacao() {
    final falta = ja<List>('cadastro.tributos_faltando', {
      'prestador': app.prestador,
    }).cast<String>();
    _aviso = falta.isEmpty
        ? ''
        : 'Falta preencher: ${falta.join(', ')}. Sem eles, a emissão só '
              'sai dos serviços que informam o próprio percentual. Se o tributo '
              'não se aplica, preencha 0.';
  }

  bool _salvar() {
    Map<String, String> novo;
    try {
      novo = {
        for (final (k, v) in jaPares('cadastro.save_tributos', {
          'prestador': app.prestador,
          'valores': {for (final e in _campos.entries) e.key: e.value.text},
        }))
          k: v,
      };
    } on ErroNucleo catch (e) {
      if (e.eValor) {
        app.toast('$e', erro: true);
      } else {
        registrar(
          'Falha ao salvar os tributos do prestador: $e',
          nivel: 'error',
        );
        app.toast('Não foi possível salvar os tributos: $e', erro: true);
      }
      return false;
    } catch (e) {
      registrar('Falha ao salvar os tributos do prestador: $e', nivel: 'error');
      app.toast('Não foi possível salvar os tributos: $e', erro: true);
      return false;
    }
    for (final e in _campos.entries) {
      e.value.text = pctVirgula(novo[e.key] ?? '');
    }
    _situacao();
    redesenhar();
    registrar(
      'Tributos do prestador salvos (prestador=${app.prestador}): ${_repr(novo)}',
    );
    app.toast('Tributos do prestador salvos.');
    // O serviço que estiver aberto na Emitir mostra os percentuais HERDADOS de quando foi
    // carregado: recarrega (sem perder a descrição e o valor já digitados lá).
    app.tributosDoPrestadorMudaram?.call();
    return true;
  }

  @override
  Widget construir(BuildContext context) {
    final t = _edicao.travado;
    var primeiro = true;
    Widget campo(String chave) {
      final rotulo = _tributosPrestador.firstWhere((e) => e.$1 == chave).$2;
      final foco = primeiro ? _foco : null;
      primeiro = false;
      return CampoTexto(
        controle: _campos[chave]!,
        foco: foco,
        rotulo: rotulo,
        largura: TamanhosConfiguracoes.campoRotulo.largura,
        textoSufixo: const Text('%'),
        mascara: pctVirgula,
        desabilitado: t,
        altura: TamanhosConfiguracoes.campoRotulo.altura,
        idLayout: 'TamanhosConfiguracoes.campoRotulo:$chave',
      );
    }

    Widget titulo(String s) => Tx(
      s,
      tam: Letra.texto,
      peso: FontWeight.w600,
      largura: TamanhosConfiguracoes.rotuloS.largura,
      altura: TamanhosConfiguracoes.rotuloS.altura,
      idLayout: 'TamanhosConfiguracoes.rotuloS:$s',
    );
    return _moldura([
      _tituloCartao('Tributos'),
      _nota(
        'Percentuais deste prestador: valem para todos os clientes e serviços dele. '
        'No cadastro de cada serviço (Clientes) e na tela Emitir dá para usar outro '
        'percentual só naquele serviço.',
      ),
      titulo('Percentuais de PIS/COFINS'),
      lin(
        [campo('pAliqPis'), campo('pAliqCofins')],
        quebra: true,
        idLayout: 'Grupo.config.lin.7',
      ),
      titulo('Retenções (IRRF / Contribuições Sociais)'),
      lin(
        [campo('irrf'), campo('csll')],
        quebra: true,
        idLayout: 'Grupo.config.lin.8',
      ),
      titulo('Totais aproximados dos tributos (Lei 12.741)'),
      lin(
        [campo('pTotTribFed'), campo('pTotTribEst'), campo('pTotTribMun')],
        quebra: true,
        idLayout: 'Grupo.config.lin.9',
      ),
      if (_aviso.isNotEmpty)
        Tx(
          _aviso,
          tam: Letra.apoio,
          cor: Colors.orange.shade800,
          largura: TamanhosConfiguracoes.rotuloAviso.largura,
          altura: TamanhosConfiguracoes.rotuloAviso.altura,
          idLayout: 'TamanhosConfiguracoes.rotuloAviso',
        ),
      lin(_edicao.botoes(), idLayout: 'Grupo.config.lin.10'),
    ]);
  }
}

// ------------------------------------------------------------------------------------------- //
// Certificados: o próprio do prestador, um cartão por procurador e o de adicionar procurador
// ------------------------------------------------------------------------------------------- //
enum _TipoCert { proprio, procurador, novoProcurador }

class _CartaoCertificado extends _Cartao {
  _CartaoCertificado(
    super.pai, {
    this.tipo = _TipoCert.proprio,
    this.procurador = '',
    this.numero = 0,
  }) {
    _info = tipo == _TipoCert.novoProcurador
        ? const <String, dynamic>{}
        : jaMapa('cadastro.cert_info', {
            'prestador': app.prestador,
            'cert': tipo == _TipoCert.proprio ? app.prestador : procurador,
          });
    _certNome = (_info['cert_name'] as String?) ?? '';
    _edicao = _Edicao(
      this,
      nivel: 2,
      titulo: tipo == _TipoCert.novoProcurador
          ? 'Adicionar procurador'
          : 'Atualizar certificado',
      salvar: _salvar,
      rotuloEditar: tipo == _TipoCert.novoProcurador
          ? 'Adicionar procurador…'
          : 'Editar',
      rotuloSalvar: tipo == _TipoCert.proprio
          ? 'Salvar certificado'
          : 'Salvar certificado do procurador',
      valores: [_texto(_senha)],
      focar: _focoEscolher,
    );
  }

  final _TipoCert tipo;

  /// Nome do certificado do procurador (no cartão dele).
  final String procurador;

  /// Posição do procurador no título (Procurador 1, 2, 3…); no cartão de adicionar, a próxima.
  final int numero;
  late final Map<String, dynamic> _info;
  late final String _certNome;
  late final _Edicao _edicao;
  final _senha = TextEditingController();
  final _focoEscolher = FocusNode();

  /// Cada cartão guarda o seu .pfx escolhido (sobrevive à remontagem da tela).
  String get _chave => tipo == _TipoCert.procurador ? procurador : tipo.name;
  String get _caminho => pai.certCaminhos[_chave] ?? '';

  String get _quem {
    final titular = (_info['titular'] as String?) ?? '';
    final doc = formatarDocumento((_info['documento'] as String?) ?? '');
    return titular.isEmpty ? doc : '$titular ($doc)';
  }

  @override
  void descartar() {
    _senha.dispose();
    _focoEscolher.dispose();
    super.descartar();
  }

  Future<void> _escolher() async {
    String? arquivo;
    try {
      arquivo = await escolherArquivo(
        titulo: tipo == _TipoCert.proprio
            ? 'Selecionar certificado (.pfx)'
            : 'Selecionar certificado do procurador (.pfx)',
        extensoes: const ['pfx'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (arquivo != null && arquivo.isNotEmpty) {
      pai.certCaminhos[_chave] = arquivo;
      redesenhar();
    }
  }

  bool _salvar() {
    if (_caminho.isEmpty) {
      app.toast('Selecione o arquivo .pfx primeiro.', erro: true);
      return false;
    }
    if (_senha.text.trim().isEmpty) {
      app.toast('Informe a senha do certificado.', erro: true);
      return false;
    }
    final proprio = tipo == _TipoCert.proprio;
    String nome;
    try {
      nome = ja<String>(
        proprio
            ? 'cadastro.import_certificate'
            : 'cadastro.import_certificate_procurador',
        {
          'prestador': app.prestador,
          'caminho': _caminho,
          'senha': _senha.text.trim(),
        },
      );
    } catch (e) {
      app.toast('$e', erro: true);
      return false;
    }
    pai.certCaminhos.remove(_chave);
    _senha.text = '';
    app.certificadosMudaram();
    registrar(
      proprio
          ? 'Certificado importado/atualizado para prestador=${app.prestador}'
          : 'Certificado de procurador importado/atualizado: $nome',
    );
    app.toast(
      proprio
          ? 'Certificado atualizado.'
          : 'Certificado do procurador salvo. A SEFIN confere a procuração '
                'eletrônica no envio de cada nota.',
    );
    // Um procurador novo ganha o seu cartão; os demais mostram os dados novos.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => pai.recarregarCertificados(),
    );
    app.atualizar();
    return true;
  }

  void _excluir() =>
      app.exigirNivel(2, _confirmarExclusao, titulo: 'Excluir certificado');

  void _confirmarExclusao() {
    late final Dialogo d;
    final vermelho = Colors.red.shade700;
    final proprio = tipo == _TipoCert.proprio;

    void excluir() {
      try {
        ja<Object?>('cadastro.delete_certificate', {
          'prestador': app.prestador,
          'cert': _certNome,
        });
      } catch (e) {
        app.toast('$e', erro: true);
        return;
      }
      app.fecharEsta(d);
      registrar(
        'Certificado EXCLUÍDO do prestador=${app.prestador}: $_certNome',
        nivel: 'warning',
      );
      app.certificadosMudaram();
      pai.certCaminhos.remove(_chave);
      pai.recarregarCertificados();
      app.atualizar();
      app.toast('Certificado excluído.');
    }

    d = Dialogo(
      titulo: (_) => LinhaTitulo([
        Icon(Icons.warning_amber, color: vermelho),
        textoTitulo('Excluir certificado'),
      ], espaco: 10),
      largura: 520,
      conteudo: (_) => col(
        [
          Tx(
            proprio
                ? 'O certificado próprio do prestador ($_quem) será apagado deste '
                      'programa. As emissões e o Cofre passam a usar o certificado de '
                      'um procurador, se houver; sem nenhum, não será possível emitir.'
                : 'O certificado do procurador $_quem será apagado deste prestador. '
                      'Os serviços marcados para assinar com ele vão pedir outra escolha '
                      'na tela Emitir.',
            largura: TamanhosConfiguracoes.rotuloExcluirCertificado.largura,
            altura: TamanhosConfiguracoes.rotuloExcluirCertificado.altura,
            idLayout: 'TamanhosConfiguracoes.rotuloExcluirCertificado',
          ),
          Tx(
            'As notas já emitidas não mudam. Para voltar a usar este certificado, '
            'será preciso importar o .pfx de novo.',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura: TamanhosConfiguracoes.rotuloExcluirCertificadoNota.largura,
            altura: TamanhosConfiguracoes.rotuloExcluirCertificadoNota.altura,
            idLayout: 'TamanhosConfiguracoes.rotuloExcluirCertificadoNota',
          ),
        ],
        justa: true,
        espaco: 10,
        idLayout: 'Grupo.config.col.excluirCertificado',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosConfiguracoes.botaoCancelar.largura,
          altura: TamanhosConfiguracoes.botaoCancelar.altura,
          idLayout: 'TamanhosConfiguracoes.botaoCancelar',
        ),
        Botao(
          'Excluir certificado',
          icone: Icons.delete_outline,
          fundo: vermelho,
          cor: Colors.white,
          aoClicar: excluir,
          largura:
              TamanhosConfiguracoes.botaoConfirmarExcluirCertificado.largura,
          altura: TamanhosConfiguracoes.botaoConfirmarExcluirCertificado.altura,
          idLayout: 'TamanhosConfiguracoes.botaoConfirmarExcluirCertificado',
        ),
      ],
      idLayout: 'Janela.config.Dialogo.excluirCertificado',
    );
    app.mostrarDialogo(d);
  }

  /// Bloco com os dados do certificado atual (titular, documento, validade, dias restantes).
  Widget _dados() {
    if (_info['ok'] == true) {
      final ate = (_info['not_after'] as String?) ?? '';
      final venc = ate.length >= 10
          ? '${ate.substring(8, 10)}/${ate.substring(5, 7)}/${ate.substring(0, 4)}'
          : '—';
      final dias = (_info['dias_restantes'] as num?)?.toInt();
      Color cor;
      String texto;
      if (dias == null) {
        (cor, texto) = (Colors.grey.shade700, venc);
      } else if (dias < 0) {
        (cor, texto) = (
          Colors.red.shade700,
          '$venc — VENCIDO há ${dias.abs()} dia(s)',
        );
      } else if (dias <= 30) {
        (cor, texto) = (Colors.red.shade700, '$venc — vence em $dias dia(s)');
      } else if (dias <= 60) {
        (cor, texto) = (
          Colors.orange.shade800,
          '$venc — vence em $dias dia(s)',
        );
      } else {
        (cor, texto) = (
          Colors.green.shade700,
          '$venc — $dias dia(s) restantes',
        );
      }
      final titular = (_info['titular'] as String?) ?? '';
      return col(
        [
          lin(
            [
              Icon(Icons.verified, color: Colors.green.shade600, size: 18),
              Tx(
                titular.isEmpty ? '—' : titular,
                peso: FontWeight.bold,
                selecionavel: true,
                largura:
                    TamanhosConfiguracoes.rotuloTitularIsEmptyTitular.largura,
                altura:
                    TamanhosConfiguracoes.rotuloTitularIsEmptyTitular.altura,
                idLayout: 'TamanhosConfiguracoes.rotuloTitularIsEmptyTitular',
              ),
            ],
            espaco: 8,
            idLayout: 'Grupo.config.lin.11',
          ),
          Tx(
            'Documento: ${formatarDocumento((_info['documento'] as String?) ?? '')}',
            tam: Letra.apoio,
            cor: Colors.grey.shade800,
            selecionavel: true,
            largura: TamanhosConfiguracoes
                .rotuloDocumentoFormatarDocumentoInfoDocumentoAsString
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloDocumentoFormatarDocumentoInfoDocumentoAsString
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloDocumentoFormatarDocumentoInfoDocumentoAsString',
          ),
          lin(
            [
              Icon(Icons.event_busy, color: cor, size: 16),
              Tx(
                'Validade: $texto',
                tam: Letra.apoio,
                cor: cor,
                peso: FontWeight.w600,
                largura: TamanhosConfiguracoes.rotuloValidadeTexto.largura,
                altura: TamanhosConfiguracoes.rotuloValidadeTexto.altura,
                idLayout: 'TamanhosConfiguracoes.rotuloValidadeTexto',
              ),
            ],
            espaco: 6,
            idLayout: 'Grupo.config.lin.12',
          ),
          if (tipo == _TipoCert.proprio)
            Tx(
              'Arquivo: $_certNome.pfx',
              tam: Letra.apoio,
              cor: Colors.grey.shade600,
              selecionavel: true,
              largura: TamanhosConfiguracoes.rotuloArquivoCertNomePfx.largura,
              altura: TamanhosConfiguracoes.rotuloArquivoCertNomePfx.altura,
              idLayout: 'TamanhosConfiguracoes.rotuloArquivoCertNomePfx',
            ),
        ],
        espaco: 4,
        idLayout: 'Grupo.config.col.6',
      );
    }
    if (_certNome.isNotEmpty) {
      return Tx(
        'Certificado presente, mas a senha não está validada no cofre. '
        'Reimporte abaixo.',
        tam: Letra.apoio,
        cor: Colors.orange.shade800,
        largura: TamanhosConfiguracoes
            .rotuloCertificadoCertNomePfxPresenteMasASenhaNao
            .largura,
        altura: TamanhosConfiguracoes
            .rotuloCertificadoCertNomePfxPresenteMasASenhaNao
            .altura,
        idLayout: 'TamanhosConfiguracoes.rotuloCertificadoCertNomePfxPresenteMasASenhaNao',
      );
    }
    return Tx(
      'Nenhum certificado configurado.',
      tam: Letra.apoio,
      cor: Colors.grey.shade700,
      largura: TamanhosConfiguracoes.rotuloNenhumCertificadoConfigurado.largura,
      altura: TamanhosConfiguracoes.rotuloNenhumCertificadoConfigurado.altura,
      idLayout: 'TamanhosConfiguracoes.rotuloNenhumCertificadoConfigurado',
    );
  }

  @override
  Widget construir(BuildContext context) {
    final t = _edicao.travado;
    final novo = tipo == _TipoCert.novoProcurador;
    final titulo = tipo == _TipoCert.proprio
        ? 'Certificado digital A1 - Prestador'
        : 'Certificado digital A1 - Procurador $numero';
    return _moldura([
      _tituloCartao(titulo),
      if (novo)
        _nota(
          'Certificado de quem tem procuração eletrônica deste prestador na Receita '
          '(imobiliária, contador…) ou do responsável legal (e-CPF). A nota sai com os '
          'dados do prestador; o certificado só assina e transmite, e a SEFIN confere a '
          'procuração no envio. Cada procurador ganha um cartão próprio, e a escolha de '
          'quem assina fica na tela Emitir, por serviço.',
        )
      else
        _dados(),
      if (tipo == _TipoCert.procurador)
        _nota(
          'A nota sai com os dados do prestador; este certificado só assina e transmite. '
          'A SEFIN confere a procuração eletrônica no envio.',
        ),
      if (_certNome.isNotEmpty)
        lin(
          [
            Botao.contorno(
              'Excluir certificado',
              icone: Icons.delete_outline,
              cor: Colors.red.shade700,
              desabilitado: !t,
              aoClicar: _excluir,
              largura: TamanhosConfiguracoes.botaoExcluirCertificado.largura,
              altura: TamanhosConfiguracoes.botaoExcluirCertificado.altura,
              idLayout: 'TamanhosConfiguracoes.botaoExcluirCertificado',
            ),
          ],
          principal: MainAxisAlignment.end,
          idLayout: 'Grupo.config.lin.excluirCertificado',
        ),
      if (!novo || !t) ...[
        divisor(),
        Tx(
          novo
              ? 'Importar certificado do procurador'
              : 'Importar / atualizar certificado',
          peso: FontWeight.w600,
          tam: Letra.texto,
          largura:
              TamanhosConfiguracoes.rotuloImportarAtualizarCertificado.largura,
          altura:
              TamanhosConfiguracoes.rotuloImportarAtualizarCertificado.altura,
          idLayout: 'TamanhosConfiguracoes.rotuloImportarAtualizarCertificado',
        ),
        lin(
          [
            Botao.contorno(
              'Selecionar .pfx',
              icone: Icons.folder_open,
              foco: _focoEscolher,
              desabilitado: t,
              aoClicar: _escolher,
              largura: TamanhosConfiguracoes.botaoSelecionarPfx.largura,
              altura: TamanhosConfiguracoes.botaoSelecionarPfx.altura,
              idLayout: 'TamanhosConfiguracoes.botaoSelecionarPfx',
            ),
            _nota(_caminho.isEmpty ? 'Nenhum arquivo selecionado.' : _caminho),
          ],
          quebra: true,
          idLayout: 'Grupo.config.lin.13',
        ),
      ],
      lin(
        [
          if (!novo || !t)
            CampoTexto(
              controle: _senha,
              rotulo: 'Senha do certificado (.pfx)',
              largura: TamanhosConfiguracoes.campoSenhaDoCertificadoPfx.largura,
              senha: true,
              revelarSenha: true,
              desabilitado: t,
              altura: TamanhosConfiguracoes.campoSenhaDoCertificadoPfx.altura,
              idLayout: 'TamanhosConfiguracoes.campoSenhaDoCertificadoPfx',
            ),
          ..._edicao.botoes(),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.14',
      ),
    ]);
  }
}

// ------------------------------------------------------------------------------------------- //
// E-mail
// ------------------------------------------------------------------------------------------- //
class _CartaoEmail extends _Cartao {
  _CartaoEmail(super.pai) {
    final cfg = jaMapa('correio.get_settings', {'prestador': app.prestador});
    final padroes = jaMapa('correio.padroes');
    String s(String k) => (cfg[k] as String?) ?? '';
    String ou(String v, String padrao) => v.isEmpty ? padrao : v;
    _assuntoPadrao = padroes['assunto'] as String;
    _mensagemPadrao = padroes['mensagem'] as String;
    _fontePadrao = padroes['fonte_padrao'] as String;
    _tamanhoPadrao = '${padroes['tamanho_padrao']}';

    Suspensa escopo(String valor) =>
        Suspensa(
          opcoes: const [
            Opcao(ambProducao, 'Produção'),
            Opcao(ambHomologacao, 'Homologação'),
            Opcao('ambos', 'Ambos'),
          ],
        )..por(
          const {ambProducao, ambHomologacao, 'ambos'}.contains(valor)
              ? valor
              : 'ambos',
        );

    _ativo = cfg['ativo'] == true;
    _ddAtivoAmb = escopo(s('ativo_ambientes'));
    _auto = cfg['auto_enviar'] == true;
    _ddAutoAmb = escopo(s('auto_ambientes'));
    _host.text = s('smtp_host');
    _porta.text = ou(s('smtp_port'), '587');
    _ddSeg = Suspensa(
      opcoes: const [
        Opcao('starttls', 'STARTTLS'),
        Opcao('ssl', 'SSL'),
        Opcao('none', 'Nenhuma'),
      ],
    )..por(ou(s('seguranca'), 'starttls'));
    _usuario.text = s('usuario');
    _senhaConfigurada = cfg['senha_configurada'] == true;
    _dicaSenha = _senhaConfigurada
        ? 'Senha já configurada; deixe em branco para manter'
        : 'Informe a senha do SMTP';
    _remetente.text = s('remetente');
    _nome.text = s('nome_remetente');
    _assunto.text = s('assunto');
    _mensagemInicial = ou(s('mensagem'), _mensagemPadrao);
    _msg.text = _mensagemInicial;
    // Delta do HTML salvo. Enquanto o editor tiver o MESMO documento, a mensagem não foi
    // editada e o Salvar/Testar usam o HTML original sem reconverter — converter perderia o
    // que o editor não representa (links, listas, imagens...) mesmo sem o usuário mexer.
    _deltaInicial = ja<String>('email_delta.delta_inicial', {
      'html': _mensagemInicial,
    });
    _delta = _deltaInicial;
    final perdas = ja<List>('email_delta.elementos_nao_suportados', {
      'html': _mensagemInicial,
    }).cast<String>();
    _ajuda =
        'Selecione o texto na mensagem e use a barra para formatar (fonte, '
        'tamanho, negrito, cores). O ícone { } insere variáveis.';
    if (perdas.isNotEmpty) {
      _ajuda +=
          ' Atenção: a mensagem salva tem ${perdas.join(', ')}'
          ', que o editor visual não mantém — ao editar a mensagem, '
          'esses elementos serão removidos.';
    }
    _teste.text = ou(s('remetente'), s('usuario'));
    _edicao = _Edicao(
      this,
      nivel: 3,
      titulo: 'Editar e-mail',
      salvar: _salvar,
      valores: [
        _Valor(() => _ativo, (v) => _ativo = v as bool),
        _lista(_ddAtivoAmb),
        _Valor(() => _auto, (v) => _auto = v as bool),
        _lista(_ddAutoAmb),
        _texto(_host),
        _texto(_porta),
        _lista(_ddSeg),
        _texto(_usuario),
        _texto(_senha),
        _texto(_remetente),
        _texto(_nome),
        _texto(_assunto),
        _texto(_msg),
        _Valor(() => _delta, (v) => _delta = v as String),
        _texto(_teste),
      ],
    );
  }

  late final _Edicao _edicao;
  late final String _assuntoPadrao,
      _mensagemPadrao,
      _fontePadrao,
      _tamanhoPadrao;
  late final String _mensagemInicial, _deltaInicial;
  late String _ajuda;
  late bool _ativo, _auto, _senhaConfigurada;
  late String _dicaSenha;
  late String _delta;
  late final Suspensa _ddAtivoAmb, _ddAutoAmb, _ddSeg;
  bool _htmlVisivel = false;
  bool _testando = false;
  final _host = TextEditingController();
  final _porta = TextEditingController();
  final _usuario = TextEditingController();
  final _senha = TextEditingController();
  final _remetente = TextEditingController();
  final _nome = TextEditingController();
  final _assunto = TextEditingController();
  final _msg = TextEditingController();
  final _teste = TextEditingController();

  @override
  void descartar() {
    for (final c in [
      _host,
      _porta,
      _usuario,
      _senha,
      _remetente,
      _nome,
      _assunto,
      _msg,
      _teste,
    ]) {
      c.dispose();
    }
    _ddAtivoAmb.dispose();
    _ddAutoAmb.dispose();
    _ddSeg.dispose();
    super.descartar();
  }

  String _mensagemAtual() {
    if (_delta.isEmpty ||
        ja<bool>('email_delta.mesmo_documento', {
          'a': _delta,
          'b': _deltaInicial,
        })) {
      return _mensagemInicial; // não editada: HTML original intacto
    }
    final html = ja<String>('email_delta.delta_para_html', {'delta': _delta});
    return html.isEmpty ? _mensagemPadrao : html;
  }

  void _editorMudou(String delta) {
    if (!_vivo) return;
    _delta = delta;
    _msg.text = _mensagemAtual();
  }

  Map<String, Object?> _daTela() => {
    'ativo': _ativo,
    'ativo_ambientes': _ddAtivoAmb.valor ?? 'ambos',
    'auto_enviar': _auto,
    'auto_ambientes': _ddAutoAmb.valor ?? 'ambos',
    'smtp_host': _host.text,
    'smtp_port': _porta.text.isEmpty ? '587' : _porta.text,
    'seguranca': _ddSeg.valor ?? 'starttls',
    'usuario': _usuario.text,
    'remetente': _remetente.text,
    'nome_remetente': _nome.text,
    'assunto': _assunto.text.isEmpty ? _assuntoPadrao : _assunto.text,
    'mensagem': _mensagemAtual(),
    'senha_configurada': _senhaConfigurada,
  };

  String? get _senhaDigitada {
    final s = _senha.text.trim();
    return s.isEmpty ? null : s;
  }

  bool _salvar() {
    final settings = _daTela();
    final senha = _senhaDigitada;
    try {
      ja<Object?>('correio.save_settings', {
        'prestador': app.prestador,
        'settings': settings,
        'senha': senha,
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return false;
    }
    _senhaConfigurada = _senhaConfigurada || senha != null;
    _senha.text = '';
    _dicaSenha = 'Senha já configurada; deixe em branco para manter';
    // Invalida o que a Consulta guarda (ícone/menu de e-mail por linha) e refaz a página
    // aberta para refletir a mudança na hora.
    app.emailCfg = null;
    if (app.prestador.isNotEmpty) app.recarregarConsulta?.call();
    registrar(
      'Configuração de e-mail salva (prestador=${app.prestador} '
      'ativo=${_repr(settings['ativo'])} [${settings['ativo_ambientes']}] '
      'auto=${_repr(settings['auto_enviar'])} [${settings['auto_ambientes']}])',
    );
    app.toast('Configurações de e-mail salvas.');
    app.atualizar();
    return true;
  }

  void _testar() {
    final settings = _daTela();
    final senha = _senhaDigitada;
    var destino = _teste.text.trim();
    if (destino.isEmpty) destino = settings['remetente'] as String;
    if (destino.isEmpty) destino = settings['usuario'] as String;
    final prestador = app.prestador;
    _testando = true;
    redesenhar();
    final h = app.toastProgresso('Testando envio de e-mail…');
    app.emSegundoPlano(() async {
      try {
        final r = await chamar<Map>('correio.testar', {
          'prestador': prestador,
          'settings': settings,
          'senha': senha,
          'destinatario': destino,
        });
        registrar(
          'Teste de e-mail enviado (prestador=$prestador destino=${r['to']})',
        );
        app.toastFim(h, 'E-mail de teste enviado para ${r['to']}.');
      } catch (e) {
        registrar(
          'Falha no teste de e-mail (prestador=$prestador): $e',
          nivel: 'warning',
        );
        app.toastFim(h, 'Falha no teste de e-mail: $e', erro: true);
      } finally {
        _testando = false;
        redesenhar();
      }
    });
  }

  @override
  Widget construir(BuildContext context) {
    final t = _edicao.travado;
    Widget campo(
      TextEditingController c,
      String rotulo,
      Tamanho tamanho, {
      bool senha = false,
      String? dica,
    }) => CampoTexto(
      controle: c,
      rotulo: rotulo,
      largura: tamanho.largura!,
      altura: tamanho.altura,
      senha: senha,
      revelarSenha: senha,
      dica: dica,
      desabilitado: t,
      idLayout: tamanho.id,
    );
    Widget escopo(Suspensa s) => ListaSuspensa(
      estado: s,
      rotulo: 'Ambiente',
      largura: TamanhosConfiguracoes.campoAmbiente.largura!,
      desabilitado: t,
      altura: TamanhosConfiguracoes.campoAmbiente.altura,
      idLayout: 'TamanhosConfiguracoes.campoAmbiente',
    );

    return _moldura([
      _tituloCartao('E-mail'),
      _nota(
        'Configure o SMTP do prestador para enviar XML e DANFSe ao tomador. ',
      ),
      lin(
        [
          Marcar(
            idLayout: 'Checkbox.config.1',
            valor: _ativo,
            rotulo: 'Habilitar envio por e-mail',
            desabilitado: t,
            aoMudar: (v) {
              _ativo = v ?? false;
              redesenhar();
            },
          ),
          escopo(_ddAtivoAmb),
          const Ct(largura: 18),
          Marcar(
            idLayout: 'Checkbox.config.2',
            valor: _auto,
            rotulo: 'Enviar automaticamente após emitir',
            desabilitado: t,
            aoMudar: (v) {
              _auto = v ?? false;
              redesenhar();
            },
          ),
          escopo(_ddAutoAmb),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.15',
      ),
      divisor(),
      lin(
        [
          campo(
            _host,
            'Servidor SMTP',
            TamanhosConfiguracoes.campoServidorSMTP,
          ),
          campo(_porta, 'Porta', TamanhosConfiguracoes.campoPorta),
          ListaSuspensa(
            estado: _ddSeg,
            rotulo: 'Segurança',
            largura: TamanhosConfiguracoes.campoSeguranca.largura!,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoSeguranca.altura,
            idLayout: 'TamanhosConfiguracoes.campoSeguranca',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.16',
      ),
      lin(
        [
          campo(
            _usuario,
            'Usuário SMTP',
            TamanhosConfiguracoes.campoUsuarioSMTP,
          ),
          campo(
            _senha,
            'Senha/app password',
            TamanhosConfiguracoes.campoSenhaAppPassword,
            senha: true,
            dica: _dicaSenha,
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.17',
      ),
      lin(
        [
          campo(
            _remetente,
            'E-mail remetente',
            TamanhosConfiguracoes.campoEMailRemetente,
          ),
          campo(
            _nome,
            'Nome do remetente',
            TamanhosConfiguracoes.campoNomeDoRemetente,
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.18',
      ),
      lin(
        [campo(_assunto, 'Assunto', TamanhosConfiguracoes.campoAssunto)],
        quebra: true,
        idLayout: 'Grupo.config.lin.19',
      ),
      _nota(
        'Variáveis disponíveis: {numero}, {chave}, {tomador}, {prestador}, {valor}, '
        '{url_consulta}, {url_consulta_full}.',
      ),
      _nota(_ajuda),
      // Editor rico EMBUTIDO: ele é a fonte da verdade; o código HTML só é exibido.
      col(
        [
          EditorRico(
            valor: _delta,
            aoMudar: _editorMudou,
            bloqueado: t || travado(context),
            placeholder: 'Escreva a mensagem do e-mail…',
            fontes: _emailFontes,
            tamanhos: _emailTamanhos,
            fontePadrao: _fontePadrao,
            tamanhoPadrao: _tamanhoPadrao,
            variaveis: _emailVariaveis,
            largura: _emailLargura,
            altura: 320,
          ),
          Botao.texto(
            _htmlVisivel ? 'Ocultar código HTML' : 'Mostrar código HTML',
            icone: Icons.code,
            cor: Colors.grey.shade700,
            aoClicar: () {
              _htmlVisivel = !_htmlVisivel;
              redesenhar();
            },
            largura: TamanhosConfiguracoes
                .botaoHtmlVisivelOcultarCodigoHTMLMostrarCodigoHTML
                .largura,
            altura: TamanhosConfiguracoes
                .botaoHtmlVisivelOcultarCodigoHTMLMostrarCodigoHTML
                .altura,
            idLayout: 'TamanhosConfiguracoes.botaoHtmlVisivelOcultarCodigoHTMLMostrarCodigoHTML',
          ),
          if (_htmlVisivel)
            Ct(
              child: CampoTexto(
                controle: _msg,
                rotulo: 'Código HTML (gerado pelo editor)',
                largura:
                    TamanhosConfiguracoes
                        .campoCodigoHTMLGeradoPeloEditor
                        .largura ??
                    (_emailLargura),
                variasLinhas: true,
                minLinhas: 3,
                maxLinhas: 8,
                tamanhoTexto: Letra.campo,
                somenteLeitura: true,
                desabilitado: t,
                altura: TamanhosConfiguracoes
                    .campoCodigoHTMLGeradoPeloEditor
                    .altura,
                idLayout:
                    'TamanhosConfiguracoes.campoCodigoHTMLGeradoPeloEditor',
              ),
            ),
        ],
        espaco: 8,
        justa: true,
        idLayout: 'Grupo.config.col.7',
      ),
      divisor(),
      lin(
        [
          campo(
            _teste,
            'E-mail para teste',
            TamanhosConfiguracoes.campoEMailParaTeste,
          ),
          // o teste também nasce travado; libera junto no Editar
          Botao.contorno(
            _testando ? 'Testando...' : 'Testar',
            icone: Icons.send,
            desabilitado: t || _testando,
            aoClicar: _testar,
            largura: TamanhosConfiguracoes.botaoTestandoTestandoTestar.largura,
            altura: TamanhosConfiguracoes.botaoTestandoTestandoTestar.altura,
            idLayout: 'TamanhosConfiguracoes.botaoTestandoTestandoTestar',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.20',
      ),
      lin(_edicao.botoes(), idLayout: 'Grupo.config.lin.21'),
    ]);
  }
}

// ------------------------------------------------------------------------------------------- //
// Ambiente e numeração
// ------------------------------------------------------------------------------------------- //
class _CartaoAmbiente extends _Cartao {
  _CartaoAmbiente(super.pai) {
    final atual = _gravado();
    _amb = Suspensa(opcoes: _opcoesAmbiente)..por(atual);
    _carregar(atual);
    pai.travas.add(_desistir);
  }

  late final Suspensa _amb;
  final _serie = TextEditingController();
  final _focoSerie = FocusNode();
  final _prox = TextEditingController();

  // Os campos começam TRAVADOS; o botão Editar (senha nível 3) libera a edição.
  bool _travado = true;

  @override
  void descartar() {
    _serie.dispose();
    _prox.dispose();
    _focoSerie.dispose();
    _amb.dispose();
    super.descartar();
  }

  String? _gravado() => app.prestador.isEmpty
      ? null
      : ja<String>('cadastro.get_ambiente', {'prestador': app.prestador});

  /// Puxa a série/numeração do ambiente selecionado (antes de salvar).
  void _carregar(String? ambiente) {
    if (app.prestador.isEmpty) {
      _serie.text = '';
      _prox.text = '';
      return;
    }
    _serie.text = ja<String>('cadastro.get_serie', {
      'prestador': app.prestador,
      'ambiente': ambiente,
    });
    _prox.text =
        '${ja<num>('cadastro.get_proximo_dps', {'prestador': app.prestador, 'ambiente': ambiente})}';
  }

  void _destravar() {
    if (app.prestador.isEmpty) return;
    registrar(
      'Edição de ambiente/numeração liberada (prestador=${app.prestador})',
    );
    _travado = false;
    redesenhar(); // o foco fica onde estava (ver _Edicao.focar)
  }

  void _salvar() {
    if (app.prestador.isEmpty) return;
    final ambiente = _amb.valor ?? ambProducao;
    try {
      // O número é conferido ANTES de gravar a série: com ele inválido, a série já teria
      // sido salva quando o erro aparecesse (salvamento pela metade).
      final digitos = soDigitos(_prox.text);
      final prox = digitos.isEmpty ? BigInt.zero : BigInt.parse(digitos);
      if (prox < BigInt.one) {
        app.toast('O próximo nº de DPS deve ser >= 1.', erro: true);
        return;
      }
      ja<Object?>('cadastro.set_serie', {
        'prestador': app.prestador,
        'ambiente': ambiente,
        'serie': _serie.text,
      });
      ja<Object?>('cadastro.set_proximo_dps', {
        'prestador': app.prestador,
        'ambiente': ambiente,
        'proximo': prox.isValidInt ? prox.toInt() : double.parse('$prox'),
      });
      ja<Object?>('cadastro.set_ambiente', {
        'prestador': app.prestador,
        'ambiente': ambiente,
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    app.ambiente = ja<String>('cadastro.get_ambiente', {
      'prestador': app.prestador,
    });
    registrar(
      'Ambiente/numeração salvos (prestador=${app.prestador} ambiente=$ambiente '
      'série=${_serie.text} próx=${_prox.text})',
    );
    app.toast('Ambiente (${ambRotulos[ambiente]}), série e numeração salvos.');
    _travado = true; // volta a travar após salvar
    redesenhar();
    app.atualizar(); // a faixa do ambiente fica fora deste cartão
  }

  /// Sai da edição SEM salvar (troca de aba/tela ou Esc): os campos voltam ao que está
  /// gravado e travam. True se havia edição aberta.
  bool _desistir() {
    if (_travado) return false;
    final gravado = _gravado();
    _amb.por(gravado);
    _amb.avisar();
    _carregar(gravado);
    _travado = true;
    redesenhar();
    return true;
  }

  @override
  Widget construir(BuildContext context) {
    final t = _travado;
    return _moldura([
      _tituloCartao('Ambiente e numeração'),
      _nota(
        'Cada ambiente tem a própria série e numeração. Para alterar, clique em Editar. '
        'Trocar o ambiente carrega os valores correspondentes.',
      ),
      lin(
        [
          ListaSuspensa(
            estado: _amb,
            rotulo: 'Ambiente',
            largura: TamanhosConfiguracoes.campoAmbiente2.largura!,
            desabilitado: t,
            aoSelecionar: (v) {
              _carregar(v ?? ambProducao);
              redesenhar();
            },
            altura: TamanhosConfiguracoes.campoAmbiente2.altura,
            idLayout: 'TamanhosConfiguracoes.campoAmbiente2',
          ),
          CampoTexto(
            controle: _serie,
            foco: _focoSerie,
            rotulo: 'Série',
            largura: TamanhosConfiguracoes.campoSerie.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoSerie.altura,
            idLayout: 'TamanhosConfiguracoes.campoSerie',
          ),
          CampoTexto(
            controle: _prox,
            rotulo: 'Próximo nº DPS',
            largura: TamanhosConfiguracoes.campoProximoNoDPS.largura,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoProximoNoDPS.altura,
            idLayout: 'TamanhosConfiguracoes.campoProximoNoDPS',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.22',
      ),
      Tx(
        'Alterar a numeração pode causar rejeição por duplicidade na SEFIN. Use com cuidado.',
        tam: Letra.apoio,
        cor: Colors.orange.shade800,
        largura: TamanhosConfiguracoes
            .rotuloAlterarANumeracaoPodeCausarRejeicaoPorDuplicidade
            .largura,
        altura: TamanhosConfiguracoes
            .rotuloAlterarANumeracaoPodeCausarRejeicaoPorDuplicidade
            .altura,
        idLayout: 'TamanhosConfiguracoes.rotuloAlterarANumeracaoPodeCausarRejeicaoPorDuplicidade',
      ),
      lin([
        if (t)
          Botao.contorno(
            'Editar',
            icone: Icons.edit,
            desabilitado: app.prestador.isEmpty,
            aoClicar: () => app.exigirNivel(
              3,
              _destravar,
              titulo: 'Editar ambiente / numeração',
            ),
            largura: TamanhosConfiguracoes.botaoEditar2.largura,
            altura: TamanhosConfiguracoes.botaoEditar2.altura,
            idLayout: 'TamanhosConfiguracoes.botaoEditar2',
          )
        else
          Botao(
            'Salvar ambiente e numeração',
            icone: Icons.save,
            aoClicar: _salvar,
            largura:
                TamanhosConfiguracoes.botaoSalvarAmbienteENumeracao.largura,
            altura: TamanhosConfiguracoes.botaoSalvarAmbienteENumeracao.altura,
            idLayout: 'TamanhosConfiguracoes.botaoSalvarAmbienteENumeracao',
          ),
      ], idLayout: 'Grupo.config.lin.23'),
    ]);
  }
}

// ------------------------------------------------------------------------------------------- //
// Avançado › Cofre: sincronização
// ------------------------------------------------------------------------------------------- //
class _CartaoSincronizacao extends _Cartao {
  _CartaoSincronizacao(super.pai) {
    final cfg = jaMapa('cofre.config');
    _ddAmb = Suspensa(
      opcoes: const [
        Opcao('atual', 'Somente o ambiente em uso'),
        Opcao('ambos', 'Produção e homologação'),
      ],
    )..por(cfg['ambientes'] as String?);
    _auto = cfg['automatica'] == true;
    _ddPrest = Suspensa(
      opcoes: const [
        Opcao('todos', 'Todos existentes'),
        Opcao('atual', 'Prestador atual'),
        Opcao('usuario', 'Prestadores do usuário'),
      ],
    )..por(cfg['prestadores'] as String?);
    _ddInt = Suspensa(
      opcoes: [
        for (final m in ja<List>('cofre.intervalos').cast<num>())
          Opcao('${m.toInt()}', intervaloTexto(m.toInt())),
      ],
    )..por('${cfg['intervalo']}');
    _edicao = _Edicao(
      this,
      nivel: 3,
      titulo: 'Sincronização do Cofre',
      salvar: _salvar,
      valores: [
        _lista(_ddAmb),
        _Valor(() => _auto, (v) => _auto = v as bool),
        _lista(_ddPrest),
        _lista(_ddInt),
      ],
    );
    _situacao();
  }

  late final Suspensa _ddAmb, _ddPrest, _ddInt;
  late final _Edicao _edicao;
  late bool _auto;
  String _texto = '';

  @override
  void descartar() {
    _ddAmb.dispose();
    _ddPrest.dispose();
    _ddInt.dispose();
    super.descartar();
  }

  void _situacao() {
    final atual = app.autoCfg.isNotEmpty ? app.autoCfg : jaMapa('cofre.config');
    final est = app.autoEstado;
    if (atual['automatica'] != true) {
      _texto = 'Sincronização automática desligada.';
      return;
    }
    final partes = [
      'Automática ligada, a cada ${intervaloTexto((atual['intervalo'] as num).toInt())}.',
    ];
    final ultima = (est['texto'] as String?) ?? '';
    if (ultima.isNotEmpty) partes.add('Última rodada — $ultima');
    try {
      final agora = DateTime.now().millisecondsSinceEpoch / 1000;
      final prox = DateTime.fromMillisecondsSinceEpoch(
        (math.max(app.cofreProxima!(), agora) * 1000).toInt(),
      );
      String z(int x) => x.toString().padLeft(2, '0');
      partes.add('Próxima: por volta de ${z(prox.hour)}:${z(prox.minute)}.');
    } catch (_) {}
    _texto = partes.join(' ');
  }

  bool _salvar() {
    Map<String, dynamic> novo;
    try {
      novo = jaMapa('cofre.salvar_config', {
        'cfg': {
          'ambientes': _ddAmb.valor ?? 'atual',
          'automatica': _auto,
          'prestadores': _ddPrest.valor ?? 'atual',
          'intervalo': int.tryParse(_ddInt.valor ?? '') ?? 60,
        },
      });
    } catch (e) {
      app.toast('Não foi possível gravar: $e', erro: true);
      return false;
    }
    final ligou =
        novo['automatica'] == true && app.autoCfg['automatica'] != true;
    app.autoCfg = novo;
    final est = app.autoEstado;
    est['falhas'] = 0;
    est['tentar_em'] = 0.0;
    if (ligou) {
      // acabou de ligar: 1ª rodada já
      est['tentar_em'] = DateTime.now().millisecondsSinceEpoch / 1000 + 5;
    }
    registrar('Sincronização do Cofre: ${_repr(novo)}');
    app.toast(
      'Sincronização do Cofre salva.'
      '${ligou ? ' A primeira rodada automática começa em instantes.' : ''}',
    );
    _situacao();
    redesenhar();
    app.cofreAtualizarSituacao?.call();
    return true;
  }

  @override
  Widget construir(BuildContext context) {
    final t = _edicao.travado;
    return _moldura([
      _tituloCartao('Sincronização do Cofre'),
      _nota(
        'Quais ambientes o Cofre consulta no ADN — vale para o botão Sincronizar e '
        'para a sincronização automática.',
      ),
      lin(
        [
          ListaSuspensa(
            estado: _ddAmb,
            rotulo: 'Ambientes',
            largura: TamanhosConfiguracoes.campoAmbientes.largura!,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoAmbientes.altura,
            idLayout: 'TamanhosConfiguracoes.campoAmbientes',
          ),
          ListaSuspensa(
            estado: _ddPrest,
            rotulo: 'Prestadores',
            largura: TamanhosConfiguracoes.campoPrestadores.largura!,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoPrestadores.altura,
            idLayout: 'TamanhosConfiguracoes.campoPrestadores',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.24',
      ),
      divisor(),
      lin(
        [
          Marcar(
            idLayout: 'Checkbox.config.3',
            compacto: true,
            valor: _auto,
            rotulo: 'Sincronizar o Cofre automaticamente',
            desabilitado: t,
            aoMudar: (v) {
              _auto = v ?? false;
              redesenhar();
            },
          ),
          ListaSuspensa(
            estado: _ddInt,
            rotulo: 'Intervalo',
            largura: TamanhosConfiguracoes.campoIntervalo.largura!,
            desabilitado: t,
            altura: TamanhosConfiguracoes.campoIntervalo.altura,
            idLayout: 'TamanhosConfiguracoes.campoIntervalo',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.config.lin.25',
      ),
      _nota(
        'Com o programa aberto, o Cofre busca sozinho as notas novas, sem anel nem '
        'janela: só avisa quando chega alguma. Sem internet, tenta de novo em 5, 10, '
        '20 e 40 minutos e nada fica gravado pela metade.',
      ),
      _nota(
        '"Todos os prestadores" = todos os que o usuário logado enxerga e que têm '
        'certificado. Cada um é consultado no ambiente em uso DELE (ou nos dois).',
      ),
      _nota(_texto),
      lin(_edicao.botoes(), idLayout: 'Grupo.config.lin.26'),
    ]);
  }
}

// ------------------------------------------------------------------------------------------- //
// Avançado › Backup: proteção do banco de notas
// ------------------------------------------------------------------------------------------- //
class _CartaoProtecao extends _Cartao {
  _CartaoProtecao(super.pai) {
    _situacao();
  }

  String _texto = '';
  bool _ocupado = false;

  void _situacao() {
    final sp = jaMapa('cofre.situacao_protecao');
    final banco = (sp['banco_mb'] as num?) ?? 0;
    if (banco == 0) {
      _texto =
          'O banco de notas ainda não foi criado (abra o Cofre e sincronize).';
      return;
    }
    final copiaEm = (sp['copia_em'] as String?) ?? '';
    final copia = (sp['copia_mb'] as num?) ?? 0;
    _texto =
        'Banco de notas: ${tamanhoArquivo(banco * 1048576)}. '
        '${copiaEm.isNotEmpty ? 'Cópia de segurança de ${dataHora(copiaEm)} (${tamanhoArquivo(copia * 1048576)}).' : 'Ainda sem cópia de segurança.'}';
  }

  void _conferir() {
    _ocupado = true;
    redesenhar();
    final h = app.toastProgresso('Conferindo o banco de notas…');
    app.emSegundoPlano(() async {
      try {
        final estado = await chamar<String>('cofre.verificar');
        if (estado == 'ok') {
          await chamar<Object?>('cofre.copiar_seguranca', {'forcar': true});
          app.toastFim(
            h,
            'Banco de notas conferido (sem problemas) e cópia de segurança refeita.',
          );
        } else if (estado.startsWith('indisponível: ')) {
          app.toastFim(
            h,
            'O banco de notas está em uso agora; tente de novo em instantes.',
            erro: true,
          );
        } else {
          app.toastFim(
            h,
            'O banco de notas tem um problema; iniciando a recuperação.',
            erro: true,
          );
          await app.cofreCuidar?.call();
        }
      } catch (e) {
        registrar('Falha ao conferir o banco de notas: $e', nivel: 'error');
        app.toastFim(
          h,
          'Não foi possível conferir o banco de notas: $e',
          erro: true,
        );
      }
      _ocupado = false;
      if (_vivo) _situacao();
      redesenhar();
    });
  }

  @override
  Widget construir(BuildContext context) => _moldura([
    _tituloCartao('Proteção do banco de notas'),
    _nota(
      'O Cofre grava cada lote por inteiro ou não grava nada: queda de internet, '
      'travamento ou falta de luz no meio não estragam o banco. Uma vez por sessão '
      'o arquivo é conferido e, no máximo uma vez por dia, uma cópia de segurança '
      'é refeita ao lado dele (database/notas.db.bak). Se o banco sumir ou estragar, a '
      'cópia volta sozinha e a sincronização seguinte traz o que faltar.',
    ),
    _nota(_texto),
    lin([
      Botao.contorno(
        'Conferir e copiar agora',
        icone: Icons.verified_outlined,
        desabilitado: _ocupado,
        aoClicar: () =>
            app.exigirNivel(2, _conferir, titulo: 'Conferir o banco de notas'),
        largura: TamanhosConfiguracoes.botaoConferirECopiarAgora.largura,
        altura: TamanhosConfiguracoes.botaoConferirECopiarAgora.altura,
        idLayout: 'TamanhosConfiguracoes.botaoConferirECopiarAgora',
      ),
    ], idLayout: 'Grupo.config.lin.27'),
  ]);
}

// ------------------------------------------------------------------------------------------- //
// Avançado › PDF: preferência que vale na hora
// ------------------------------------------------------------------------------------------- //
class _CartaoPdf extends _Cartao {
  _CartaoPdf(super.pai) : _marcado = pai.app.pdfNativo;

  bool _marcado;

  void _mudou(bool? v) {
    final marcado = v ?? false;
    _marcado = marcado;
    try {
      ja<Object?>('banco.set_meta', {
        'chave': _metaPdfNativo,
        'valor': marcado ? '1' : '0',
      });
    } catch (e) {
      _marcado = app.pdfNativo; // não gravou: volta ao que vale
      redesenhar();
      app.toast('Não foi possível gravar a preferência: $e', erro: true);
      return;
    }
    app.pdfNativo = marcado;
    redesenhar();
    app.toast(
      marcado
          ? 'As DANFSe passam a abrir no leitor que vem com o programa.'
          : 'As DANFSe passam a abrir no leitor de PDF padrão do Windows.',
    );
  }

  @override
  Widget construir(BuildContext context) => _moldura([
    _tituloCartao('Leitor de PDF'),
    Marcar(
      idLayout: 'Checkbox.config.4',
      valor: _marcado,
      rotulo: 'Usar leitor PDF nativo',
      aoMudar: _mudou,
    ),
    _nota(
      'Marcado: a DANFSe abre no leitor que vem com o programa (tela cheia, sem '
      'instalar nada). Desmarcado: abre no leitor de PDF padrão do Windows. '
      'Vale na hora, para todos os usuários.',
    ),
  ]);
}

// ------------------------------------------------------------------------------------------- //
// Personalização: cores do fundo e dos cartões, com prévia ao vivo
// ------------------------------------------------------------------------------------------- //
/// Um seletor de cor: amostra, três barras (matiz, intensidade, claridade) e o código.
class _Seletor {
  _Seletor(this.dono, this.chave, this.titulo, this.dica) {
    arco = [
      for (var h = 0; h <= 360; h += 30)
        corHex(
          ja<String>('aparencia.de_hsv', {
            'matiz': h.toDouble(),
            'intensidade': 0.45,
            'claridade': 1.0,
          }),
        ),
    ];
    definir(dono.cor[chave]!);
  }

  final _CartaoPersonalizacao dono;
  final String chave;
  final String titulo;
  final String dica;
  late final List<Color> arco;
  double matiz = 0, intensidade = 0, claridade = 100;
  String tMatiz = '', tInt = '', tCla = '';
  final hex = TextEditingController();

  void descartar() => hex.dispose();

  (double, double, double) _hsv(String c) {
    final l = ja<List>('aparencia.hsv', {'cor': c}).cast<num>();
    return (l[0].toDouble(), l[1].toDouble(), l[2].toDouble());
  }

  void _rotulos() {
    final (_, s, v) = _hsv(dono.cor[chave]!);
    tMatiz = '${_arredPar(matiz).toStringAsFixed(0)}°';
    tInt = '${(s * 100).toStringAsFixed(1)}%'.replaceAll('.', ',');
    tCla = '${(v * 100).toStringAsFixed(0)}%';
  }

  void _paraControles(String c) {
    final (h, s, v) = _hsv(c);
    // branco/cinza não têm matiz: o controle fica onde estava
    if (s > 0.004) matiz = _arredPar(h);
    // Intensidade em escala quadrática: mais curso na faixa dos tons suaves.
    intensidade = math.min(
      100.0,
      100 * math.sqrt(math.min(s, dono.sMax) / dono.sMax),
    );
    claridade = (100 * (v - dono.vMin) / (1 - dono.vMin)).clamp(0.0, 100.0);
  }

  void definir(String c, {bool mexerControles = true}) {
    dono.cor[chave] = c;
    hex.text = c;
    if (mexerControles) _paraControles(c);
    _rotulos();
  }

  void _arrastou() {
    definir(
      ja<String>('aparencia.de_hsv', {
        'matiz': matiz,
        'intensidade': dono.sMax * math.pow(intensidade / 100, 2),
        'claridade': dono.vMin + (1 - dono.vMin) * claridade / 100,
      }),
      mexerControles: false,
    );
    dono.pintarLeve(chave);
    dono.erro = '';
    dono.redesenhar(); // só o que é leve: o arrasto não espera por nada
  }

  void _digitou() {
    if (hex.text.trim().toUpperCase() == dono.cor[chave]) return;
    String c;
    try {
      c = ja<String>('aparencia.validar', {'cor': hex.text});
    } catch (e) {
      // O campo volta à cor em uso: texto inválido parado ali seria tomado por valor salvo
      // (e reclamado de novo a cada perda de foco).
      dono.erro = '$e';
      hex.text = dono.cor[chave]!;
      dono.redesenhar();
      return;
    }
    dono.erro = '';
    definir(c);
    dono.pintarLeve(chave);
    dono.redesenhar();
    dono.aplicarTema();
  }

  Widget construir(BuildContext context) {
    final t = !dono.aberto || travado(context);
    final esquema = Theme.of(context).colorScheme;

    Widget barra(
      double valor,
      double maximo,
      ValueChanged<double> aoMudar, {
      bool transparente = false,
    }) => Slider(
      autofocus: false,
      value: valor.clamp(0, maximo),
      min: 0,
      max: maximo,
      // Trilha transparente: quem aparece é a barra de trás (arco-íris).
      activeColor: transparente ? Colors.transparent : null,
      inactiveColor: transparente ? Colors.transparent : null,
      thumbColor: transparente ? esquema.primary : null,
      onChanged: t
          ? null
          : (v) {
              aoMudar(v);
              _arrastou();
            },
      onChangeStart: t ? null : (_) {},
      // soltou: o tema acompanha
      onChangeEnd: t ? null : (_) => dono.aplicarTema(),
    );

    Widget linha(String rotulo, Widget controle, String valor) => lin(
      [
        Tx(
          rotulo,
          tam: Letra.apoio,
          largura: TamanhosConfiguracoes.rotuloRotulo.largura,
          altura: TamanhosConfiguracoes.rotuloRotulo.altura,
          idLayout: 'TamanhosConfiguracoes.rotuloRotulo:$chave:$rotulo',
        ),
        Expanded(child: controle),
        Tx(
          valor,
          tam: Letra.apoio,
          largura: TamanhosConfiguracoes.rotuloValor.largura,
          alinhar: TextAlign.right,
          altura: TamanhosConfiguracoes.rotuloValor.altura,
          idLayout: 'TamanhosConfiguracoes.rotuloValor:$chave:$rotulo',
        ),
      ],
      espaco: 0,
      altura: 36,
      idLayout: 'Grupo.config.lin.28:$chave:$rotulo',
    );

    // Travada, a barra da matiz perde o arco-íris: tudo cinza = nada editável.
    final travada = !dono.aberto;
    final barraMatiz = Ct(
      altura: 6,
      raio: BorderRadius.circular(3),
      cor: travada ? Colors.grey.shade400 : null,
      gradiente: travada ? null : LinearGradient(colors: arco),
    );

    // expand: os dois seletores dividem a largura do cartão — barras o mais longas possível
    // (ajuste fino), sempre lado a lado.
    return Expanded(
      child: Ct(
        padding: const EdgeInsets.all(14),
        raio: BorderRadius.circular(12),
        borda: Border.all(color: esquema.outlineVariant, width: 1),
        child: col(
          [
            lin(
              [
                Ct(
                  largura: 34,
                  altura: 34,
                  raio: BorderRadius.circular(8),
                  cor: corHex(dono.cor[chave]!),
                  borda: Border.all(color: Colors.grey.shade500, width: 1),
                ),
                col(
                  [
                    Tx(
                      titulo,
                      peso: FontWeight.w600,
                      largura: TamanhosConfiguracoes.rotuloTitulo.largura,
                      altura: TamanhosConfiguracoes.rotuloTitulo.altura,
                      idLayout: 'TamanhosConfiguracoes.rotuloTitulo:$chave',
                    ),
                    Tx(
                      dica,
                      tam: Letra.apoio,
                      cor: Colors.grey.shade700,
                      largura: TamanhosConfiguracoes.rotuloDica.largura,
                      altura: TamanhosConfiguracoes.rotuloDica.altura,
                      idLayout: 'TamanhosConfiguracoes.rotuloDica:$chave',
                    ),
                  ],
                  espaco: 0,
                  justa: true,
                  idLayout: 'Grupo.config.col.9:$chave',
                ),
              ],
              espaco: 12,
              idLayout: 'Grupo.config.lin.29:$chave',
            ),
            linha(
              'Matiz',
              Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    left: 24,
                    right: 24,
                    top: 0,
                    bottom: 0,
                    child: Ct(alinhar: Alignment.center, child: barraMatiz),
                  ),
                  barra(matiz, 360, (v) => matiz = v, transparente: true),
                ],
              ),
              tMatiz,
            ),
            linha(
              'Intensidade',
              barra(intensidade, 100, (v) => intensidade = v),
              tInt,
            ),
            linha(
              'Claridade',
              barra(claridade, 100, (v) => claridade = v),
              tCla,
            ),
            CampoTexto(
              controle: hex,
              rotulo: 'Código',
              largura: TamanhosConfiguracoes.campoCodigo.largura,
              denso: true,
              desabilitado: !dono.aberto,
              aoEnviar: (_) => _digitou(),
              aoDesfocar: _digitou,
              altura: TamanhosConfiguracoes.campoCodigo.altura,
              idLayout: 'TamanhosConfiguracoes.campoCodigo:$chave',
            ),
          ],
          espaco: 6,
          justa: true,
          idLayout: 'Grupo.config.col.8:$chave',
        ),
      ),
    );
  }
}

class _CartaoPersonalizacao extends _Cartao {
  _CartaoPersonalizacao(super.pai) {
    // o que está gravado — é para onde se volta ao desistir
    salvo = {'fundo': aparenciaAtual.fundo, 'cartoes': aparenciaAtual.cartoes};
    cor = Map.of(salvo); // o que está na tela agora
    // Curso dos controles: mais estreito que o limite aceito no campo Código — a barra
    // inteira cobre só a faixa dos tons suaves, e por isso responde com calma.
    final limites = jaMapa('aparencia.limites');
    sMax = (limites['controle_intensidade_max'] as num).toDouble();
    vMin = (limites['controle_claridade_min'] as num).toDouble();
    _temas = [
      for (final t in ja<List>('aparencia.temas'))
        ((t as List)[0] as String, t[1] as String, t[2] as String),
    ];
    _fundo = _Seletor(
      this,
      'fundo',
      'Fundo geral',
      'Atrás de tudo: página, menu lateral e topo.',
    );
    _cartoesSel = _Seletor(
      this,
      'cartoes',
      'Cartões e janelas',
      'Painéis como este; janelas e menus saem um tom abaixo.',
    );
    pai.travas.add(_descartar); // sair da aba/tela sem salvar descarta
  }

  late final Map<String, String> salvo;
  late final Map<String, String> cor;

  /// Os espinhos do baiacu saem e voltam ao entrar. Como as cores: muda só com o cartão em
  /// edição e fica valendo ao Salvar (Cancelar volta ao gravado). Vale para o computador.
  bool _animacaoSalva = _lerAnimacaoLogin();
  late bool _animacaoLogin = _animacaoSalva;

  static bool _lerAnimacaoLogin() {
    try {
      return ja<String>('banco.get_meta', {'chave': metaAnimacaoLogin}) != '0';
    } catch (_) {
      return true;
    }
  }
  late final double sMax, vMin;
  late final List<(String, String, String)> _temas;
  late final _Seletor _fundo, _cartoesSel;
  bool aberto = false;
  String erro = '';

  /// Cor dos cartões em PRÉVIA, só neste cartão. Nulo = a do tema.
  String? _previaCartao;

  static const _opacoTravado = 0.38;

  @override
  void descartar() {
    _fundo.descartar();
    _cartoesSel.descartar();
    super.descartar();
  }

  // PRÉVIA EM DOIS TEMPOS. Enquanto uma barra é ARRASTADA só mudam elementos leves — o fundo
  // da página, o fundo DESTE cartão e os números: dezenas de eventos por segundo passam sem
  // engasgo. Trocar o TEMA (o que pinta janelas, menus e os outros cartões) redesenha o
  // programa inteiro; isso só é feito ao SOLTAR a barra (e na hora, em tema pronto ou código
  // digitado).
  void pintarLeve(String chave) {
    if (chave == 'fundo') {
      app.fundoPrevia.value = cor['fundo'];
    } else {
      _previaCartao = cor['cartoes'];
    }
  }

  void aplicarTema() {
    if (cor['fundo'] != aparenciaAtual.fundo ||
        cor['cartoes'] != aparenciaAtual.cartoes) {
      app.aplicarAparencia(cor['fundo']!, cor['cartoes']!);
    }
  }

  void _usar(String fundo, String cartoes) {
    erro = '';
    _fundo.definir(fundo);
    _cartoesSel.definir(cartoes);
    pintarLeve('fundo');
    pintarLeve('cartoes');
    redesenhar();
    aplicarTema();
  }

  void _destravar() {
    registrar('Edição da personalização (cores) liberada');
    aberto = true;
    redesenhar();
  }

  /// Fecha a edição SEM salvar: a tela volta às cores gravadas. True se havia edição aberta
  /// (é o que o Esc quer saber).
  bool _descartar() {
    if (!aberto) return false;
    erro = '';
    _fundo.definir(salvo['fundo']!);
    _cartoesSel.definir(salvo['cartoes']!);
    pintarLeve('fundo');
    _previaCartao = null; // de volta à cor do tema
    _animacaoLogin = _animacaoSalva;
    aberto = false;
    redesenhar();
    aplicarTema();
    return true;
  }

  void _salvar() {
    try {
      final gravado = jaMapa('aparencia.salvar', {
        'fundo': cor['fundo'],
        'cartoes': cor['cartoes'],
      });
      salvo['fundo'] = gravado['fundo'] as String;
      salvo['cartoes'] = gravado['cartoes'] as String;
      ja<Object?>('banco.set_meta', {
        'chave': metaAnimacaoLogin,
        'valor': _animacaoLogin ? '1' : '0',
      });
      _animacaoSalva = _animacaoLogin;
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    registrar(
      'Personalização salva (fundo=${salvo['fundo']} cartões=${salvo['cartoes']} '
      'animação do login=${_animacaoSalva ? 'ligada' : 'desligada'})',
    );
    app.toast('Personalização salva.');
    erro = '';
    aplicarTema();
    _previaCartao = null; // o tema já está com a cor: o reforço local sai
    aberto = false;
    redesenhar();
  }

  Widget _chip(String nome, String fundo, String cartoes) => Ct(
    padding: const EdgeInsets.fromLTRB(8, 5, 12, 5),
    raio: BorderRadius.circular(20),
    cor: corHex(fundo),
    borda: Border.all(color: Colors.grey.shade400, width: 1),
    dica: '$fundo / $cartoes',
    aoClicar: () => _usar(fundo, cartoes),
    child: lin(
      [
        Ct(
          largura: 16,
          altura: 16,
          raio: BorderRadius.circular(8),
          cor: corHex(cartoes),
          borda: Border.all(color: Colors.grey.shade500, width: 1),
        ),
        Tx(
          nome,
          tam: Letra.apoio,
          largura: TamanhosConfiguracoes.rotuloNome.largura,
          altura: TamanhosConfiguracoes.rotuloNome.altura,
          idLayout: 'TamanhosConfiguracoes.rotuloNome',
        ),
      ],
      espaco: 6,
      justa: true,
      idLayout: 'Grupo.config.lin.30',
    ),
  );

  @override
  Widget construir(BuildContext context) {
    final t = !aberto;
    // Tudo o que se edita mora neste bloco: fora do modo de edição ele fica INTEIRO
    // acinzentado e inerte — de relance se vê que é preciso clicar em Editar.
    final corpo = AnimatedOpacity(
      opacity: t ? _opacoTravado : 1.0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.linear,
      child: Travar(
        se: t,
        child: col(
          [
            Tx(
              'Temas prontos',
              tam: Letra.apoio,
              peso: FontWeight.w600,
              largura: TamanhosConfiguracoes.rotuloTemasProntos.largura,
              altura: TamanhosConfiguracoes.rotuloTemasProntos.altura,
              idLayout: 'TamanhosConfiguracoes.rotuloTemasProntos',
            ),
            lin(
              [
                for (final (nome, fundo, cartoes) in _temas)
                  _chip(nome, fundo, cartoes),
              ],
              quebra: true,
              espaco: 8,
              espacoLinhas: 8,
              idLayout: 'Grupo.config.lin.31',
            ),
            Builder(
              builder: (context) => lin(
                [_fundo.construir(context), _cartoesSel.construir(context)],
                espaco: 18,
                cruzado: CrossAxisAlignment.start,
                idLayout: 'Grupo.config.lin.32',
              ),
            ),
          ],
          espaco: 12,
          idLayout: 'Grupo.config.col.10',
        ),
      ),
    );
    final previa = _previaCartao;
    return cartao(
      recorte: Clip.antiAlias,
      Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
            child: Ct(
              cor: previa == null ? null : corHex(previa),
            ), // sem cor = a do tema
          ),
          Ct(
            padding: const EdgeInsets.all(20),
            child: col(
              [
                // Botões no TOPO (nos outros cartões ficam embaixo): este é comprido, e
                // Salvar tem de estar à vista enquanto se mexe nas cores.
                lin([
                  _tituloCartao('Personalização'),
                  const Expanded(child: SizedBox()),
                  if (!t)
                    Botao.texto(
                      'Cancelar',
                      aoClicar: _descartar,
                      largura: TamanhosConfiguracoes.botaoCancelar2.largura,
                      altura: TamanhosConfiguracoes.botaoCancelar2.altura,
                      idLayout: 'TamanhosConfiguracoes.botaoCancelar2',
                    ),
                  if (t)
                    Botao.contorno(
                      'Editar',
                      icone: Icons.edit,
                      aoClicar: () => app.exigirNivel(
                        3,
                        _destravar,
                        titulo: 'Personalizar cores',
                      ),
                      largura: TamanhosConfiguracoes.botaoEditar3.largura,
                      altura: TamanhosConfiguracoes.botaoEditar3.altura,
                      idLayout: 'TamanhosConfiguracoes.botaoEditar3',
                    )
                  else
                    Botao(
                      'Salvar',
                      icone: Icons.save,
                      aoClicar: _salvar,
                      largura: TamanhosConfiguracoes.botaoSalvarCores.largura,
                      altura: TamanhosConfiguracoes.botaoSalvarCores.altura,
                      idLayout: 'TamanhosConfiguracoes.botaoSalvarCores',
                    ),
                ], idLayout: 'Grupo.config.lin.33'),
                Marcar(
                  valor: _animacaoLogin,
                  rotulo: 'Animação do baiacu na tela de login',
                  rente: true,
                  desabilitado: t,
                  aoMudar: (v) {
                    _animacaoLogin = v ?? false;
                    redesenhar();
                  },
                  idLayout: 'Checkbox.config.animacaoLogin',
                ),
                _nota(
                  'Cores do fundo e dos cartões, para o sistema inteiro. Clique em Editar '
                  'para mexer: a tela acompanha na hora, e a mudança (cores e animação) só '
                  'fica valendo depois de Salvar.',
                ),
                corpo,
                if (erro.isNotEmpty)
                  Tx(
                    erro,
                    tam: Letra.apoio,
                    cor: Colors.red.shade700,
                    largura: TamanhosConfiguracoes.rotuloErro.largura,
                    altura: TamanhosConfiguracoes.rotuloErro.altura,
                    idLayout: 'TamanhosConfiguracoes.rotuloErro',
                  ),
              ],
              espaco: 12,
              idLayout: 'Grupo.config.col.11',
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------- //
// Avançado › Backup: backup e restauração em .zip e a troca da senha mestra
// ------------------------------------------------------------------------------------------- //
class _CartaoBanco extends _Cartao {
  _CartaoBanco(super.pai) {
    final raiz = ja<String>('nucleo.raiz').replaceAll('/', r'\');
    _pasta =
        '${raiz.endsWith(r'\') ? raiz.substring(0, raiz.length - 1) : raiz}\\database';
  }

  late final String _pasta;
  static const _rotulo = {'dados': 'dados', 'notas': 'notas'};

  // ---- fazer backup -------------------------------------------------------------------------- //
  void _abrirBackup() {
    if (app.backupEmAndamento) return;
    final tam = jaMapa('backup.tamanhos');
    final dados = (tam['dados'] as num?) ?? 0;
    final notas = (tam['notas'] as num?) ?? 0;
    final soDados = Opcao('dados', 'Só os dados (${_mb(dados)})');
    // sem banco de notas ainda, só há os dados para guardar
    final opcoes = notas == 0
        ? [soDados]
        : [
            Opcao('tudo', 'Dados e notas (${_mb(dados + notas)})'),
            soDados,
            Opcao('notas', 'Só as notas (${_mb(notas)})'),
          ];
    late final Dialogo d;
    late final Suspensa dd;

    void continuar() {
      final partes = const {
        'tudo': ['dados', 'notas'],
        'dados': ['dados'],
        'notas': ['notas'],
      }[dd.valor ?? opcoes.first.chave]!;
      app.fecharDialogo();
      _salvarBackup(partes);
    }

    d = Dialogo(
      titulo: (_) => app.tituloComX('Fazer backup'),
      largura: 470,
      conteudo: (_) => col(
        [
          ListaSuspensa(
            estado: dd,
            rotulo: 'O que guardar',
            largura: TamanhosConfiguracoes.campoOQueGuardar.largura!,
            altura: TamanhosConfiguracoes.campoOQueGuardar.altura,
            idLayout: 'TamanhosConfiguracoes.campoOQueGuardar',
          ),
          _nota(
            'Dados: prestadores, clientes, serviços, certificados, usuários, '
            'séries e numerações (dados.db). Notas: todos os XMLs do Cofre, '
            'emitidos e recebidos (notas.db).',
          ),
          _nota(
            'O backup sai num arquivo .zip e só abre com a SENHA MESTRA. Não é '
            'comprimido — os bancos já são criptografados e não encolheriam —, '
            'então fica pronto no tempo de copiar os arquivos.',
          ),
        ],
        justa: true,
        espaco: 12,
        idLayout: 'Grupo.config.col.12',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosConfiguracoes.botaoCancelar3.largura,
          altura: TamanhosConfiguracoes.botaoCancelar3.altura,
          idLayout: 'TamanhosConfiguracoes.botaoCancelar3',
        ),
        Botao(
          'Continuar',
          icone: Icons.save_alt,
          aoClicar: continuar,
          largura: TamanhosConfiguracoes.botaoContinuar.largura,
          altura: TamanhosConfiguracoes.botaoContinuar.altura,
          idLayout: 'TamanhosConfiguracoes.botaoContinuar',
        ),
      ],
      idLayout: 'Janela.config.Dialogo.3',
    );
    dd = d.suspensa(valor: opcoes.first.chave, opcoes: opcoes)
      ..por(opcoes.first.chave);
    app.mostrarDialogo(d);
  }

  Future<void> _salvarBackup(List<String> partes) async {
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Salvar backup (.zip)',
        nome: ja<String>('backup.nome_sugerido', {'partes': partes}),
        extensoes: const ['zip'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    if (!destino.toLowerCase().endsWith('.zip')) destino += '.zip';
    final dest = destino;
    if (app.backupEmAndamento) return;
    app.backupEmAndamento = true;
    redesenhar();
    final h = app.toastProgresso('Gravando backup — 0%');
    app.emSegundoPlano(() async {
      Map r;
      try {
        r = await chamar<Map>(
          'backup.fazer',
          {'destino': dest, 'partes': partes},
          (aviso) {
            if (aviso is Map) {
              app.toastAndamento(
                h,
                '${aviso['etapa']} — ${aviso['percentual']}%',
              );
            }
          },
        );
      } catch (e) {
        registrar('Falha no backup: $e', nivel: 'error');
        app.toastFim(h, 'Falha no backup: $e', erro: true);
        return;
      } finally {
        app.backupEmAndamento = false;
        redesenhar();
      }
      final oQue = [for (final p in r['partes'] as List) _rotulo[p] ?? '$p']
          .join(' e ');
      final extra = r['sem_notas'] == true
          ? ' O banco de notas ainda não existe: saíram só os dados.'
          : '';
      app.toastFim(
        h,
        'Backup ($oQue, ${_mb(r['bytes'] as num)}) salvo em: $dest.$extra',
      );
    });
  }

  // ---- restaurar backup ---------------------------------------------------------------------- //
  Future<void> _escolherRestauracao() async {
    String? arquivo;
    try {
      arquivo = await escolherArquivo(
        titulo: 'Escolher backup (.zip)',
        extensoes: const ['zip'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (arquivo != null && arquivo.isNotEmpty) _conferirBackup(arquivo, '');
  }

  void _conferirBackup(String origem, String senhaMestra) {
    Map<String, dynamic> info;
    try {
      info = jaMapa('backup.examinar', {
        'origem': origem,
        'senha_mestra': senhaMestra,
      });
    } on ErroNucleo catch (e) {
      if (e.tipo == 'SenhaMestraNecessaria') {
        _pedirSenhaDoBackup(origem, senhaMestra.isEmpty ? '' : '$e');
      } else {
        app.toast('$e', erro: true);
      }
      return;
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    _confirmarRestauracao(origem, senhaMestra, info);
  }

  void _pedirSenhaDoBackup(String origem, String erro) {
    late final Dialogo d;
    late final TextEditingController senha;

    void continuar() {
      final digitada = senha.text;
      app.fecharDialogo();
      _conferirBackup(origem, digitada);
    }

    d = Dialogo(
      titulo: (_) => app.tituloComX('Backup de outro banco'),
      largura: 520,
      conteudo: (_) => col(
        [
          Tx(
            'Este backup foi cifrado com outra chave (outra instalação, ou '
            'anterior a uma troca de senha mestra). Digite a SENHA MESTRA '
            'dele, só para abri-lo — a desta instalação não muda:',
            tam: Letra.texto,
            largura: TamanhosConfiguracoes
                .rotuloEsteBackupFoiCifradoComOutraChaveOutra
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloEsteBackupFoiCifradoComOutraChaveOutra
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloEsteBackupFoiCifradoComOutraChaveOutra',
          ),
          CampoTexto(
            controle: senha,
            rotulo: 'Senha mestra do backup',
            largura: TamanhosConfiguracoes.campoSenhaMestraDoBackup.largura,
            focoInicial: true,
            senha: true,
            revelarSenha: true,
            aoEnviar: (_) => continuar(),
            altura: TamanhosConfiguracoes.campoSenhaMestraDoBackup.altura,
            idLayout: 'TamanhosConfiguracoes.campoSenhaMestraDoBackup',
          ),
          Tx(
            erro,
            cor: Colors.red.shade600,
            tam: Letra.apoio,
            largura: TamanhosConfiguracoes.rotuloErro2.largura,
            altura: TamanhosConfiguracoes.rotuloErro2.altura,
            idLayout: 'TamanhosConfiguracoes.rotuloErro2',
          ),
        ],
        justa: true,
        espaco: 10,
        idLayout: 'Grupo.config.col.13',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosConfiguracoes.botaoCancelar4.largura,
          altura: TamanhosConfiguracoes.botaoCancelar4.altura,
          idLayout: 'TamanhosConfiguracoes.botaoCancelar4',
        ),
        Botao(
          'Continuar',
          aoClicar: continuar,
          largura: TamanhosConfiguracoes.botaoContinuar2.largura,
          altura: TamanhosConfiguracoes.botaoContinuar2.altura,
          idLayout: 'TamanhosConfiguracoes.botaoContinuar2',
        ),
      ],
      idLayout: 'Janela.config.Dialogo.4',
    );
    senha = d.texto();
    app.mostrarDialogo(d);
  }

  /// O que está em memória (usuário logado, prestador, telas) é dos bancos ANTIGOS: o
  /// programa fecha e reabre sozinho, já na tela de login.
  Future<void> _reiniciar() async {
    app.mostrarDialogo(
      Dialogo(
        titulo: (_) => textoTitulo('Backup restaurado'),
        conteudo: (_) => lin(
          [
            anel(tamanho: 20),
            Tx(
              'Reiniciando o aplicativo…',
              largura:
                  TamanhosConfiguracoes.rotuloReiniciandoOAplicativo.largura,
              altura: TamanhosConfiguracoes.rotuloReiniciandoOAplicativo.altura,
              idLayout: 'TamanhosConfiguracoes.rotuloReiniciandoOAplicativo',
            ),
          ],
          espaco: 14,
          idLayout: 'Grupo.config.lin.34',
        ),
        idLayout: 'Janela.config.Dialogo.5',
      ),
    );
    await Future<void>.delayed(
      const Duration(milliseconds: 600),
    ); // deixa o aviso aparecer
    // até 10 s para um trabalho em segundo plano terminar
    for (var i = 0; i < 100 && app.trabalhos > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await app.fechar(reabrir: true)) return;
    app.fecharDialogo();
    app.toast(
      'Backup restaurado. FECHE e reabra o aplicativo para recarregar tudo.',
    );
  }

  void _confirmarRestauracao(
    String origem,
    String senhaMestra,
    Map<String, dynamic> info,
  ) {
    final tem = (info['partes'] as List).cast<String>();
    const textos = {
      'dados': 'Dados — cadastros, certificados, usuários, séries e numerações',
      'notas': 'Notas — todos os XMLs do Cofre, de todos os prestadores',
    };
    // Backup com os dois bancos: dá para restaurar só um. Com um só, não há escolha.
    final marcado = {for (final p in tem) p: true};
    late final Dialogo d;

    void confirmar() {
      final partes = [
        for (final p in tem)
          if (marcado[p] == true) p,
      ];
      if (partes.isEmpty) {
        app.toast('Marque o que deve ser restaurado.', erro: true);
        return;
      }
      app.fecharDialogo();
      // Conferir, recifrar as notas e trocar os bancos leva alguns segundos num banco
      // grande: vai para segundo plano, com a tela travada por este aviso.
      final espera = Dialogo(
        titulo: (_) => textoTitulo('Restaurando o backup'),
        largura: 380,
        conteudo: (_) => lin(
          [
            anel(tamanho: 20),
            Flexible(
              child: Tx(
                'Conferindo e trocando os bancos…',
                largura: TamanhosConfiguracoes
                    .rotuloConferindoETrocandoOsBancos
                    .largura,
                altura: TamanhosConfiguracoes
                    .rotuloConferindoETrocandoOsBancos
                    .altura,
                idLayout:
                    'TamanhosConfiguracoes.rotuloConferindoETrocandoOsBancos',
              ),
            ),
          ],
          espaco: 14,
          justa: true,
          idLayout: 'Grupo.config.lin.35',
        ),
        idLayout: 'Janela.config.Dialogo.6',
      );
      app.mostrarDialogo(espera);
      app.emSegundoPlano(() async {
        List feito;
        try {
          feito = await chamar<List>('backup.restaurar', {
            'origem': origem,
            'partes': partes,
            'senha_mestra': senhaMestra,
          });
        } catch (e) {
          registrar('Falha ao restaurar o backup: $e', nivel: 'error');
          app.fecharEsta(espera);
          app.toast('Falha na restauração: $e', erro: true);
          return;
        }
        registrar('Backup restaurado (${feito.join('+')}) a partir de $origem');
        app.fecharEsta(espera);
        pai.invalidar(); // invalida as telas guardadas
        unawaited(_reiniciar());
      });
    }

    final avisos = [
      if (tem.contains('dados'))
        'Dados: o usuário MASTER e a SENHA MESTRA continuam sendo os atuais; '
            'os demais usuários passam a ser os do backup, com as senhas deles.',
      if (tem.contains('notas'))
        'Notas: as do backup entram no lugar de TODAS as que estão no Cofre; '
            'o que tiver chegado depois dele volta ao sincronizar.',
    ];
    final feitoEm = (info['feito_em'] as String?) ?? '';
    final quando = feitoEm.isEmpty ? '' : dataHora(feitoEm);
    d = Dialogo(
      titulo: (_) => app.tituloComX('Restaurar backup'),
      largura: 540,
      conteudo: (_) => col(
        [
          Tx(
            'Isto SUBSTITUI o que está nesta instalação pelo conteúdo do backup'
            '${quando.isEmpty ? '' : ' (feito em $quando)'}:',
            tam: Letra.texto,
            largura: TamanhosConfiguracoes
                .rotuloIstoSUBSTITUIOQueEstaNestaInstalacaoPelo
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloIstoSUBSTITUIOQueEstaNestaInstalacaoPelo
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloIstoSUBSTITUIOQueEstaNestaInstalacaoPelo',
          ),
          Tx(
            origem,
            tam: Letra.codigo,
            fonte: 'Consolas',
            selecionavel: true,
            largura: TamanhosConfiguracoes.rotuloOrigem.largura,
            altura: TamanhosConfiguracoes.rotuloOrigem.altura,
            idLayout: 'TamanhosConfiguracoes.rotuloOrigem',
          ),
          col(
            [
              for (final p in tem)
                Marcar(
                  idLayout: 'Checkbox.config.5',
                  valor: marcado[p],
                  rotulo: textos[p] ?? p,
                  desabilitado: tem.length == 1,
                  aoMudar: (v) {
                    marcado[p] = v ?? false;
                    d.atualizar();
                  },
                ),
            ],
            espaco: 0,
            justa: true,
            idLayout: 'Grupo.config.col.15',
          ),
          for (final t in avisos)
            Tx(
              t,
              tam: Letra.apoio,
              cor: Colors.orange.shade800,
              largura: TamanhosConfiguracoes.rotuloT3.largura,
              altura: TamanhosConfiguracoes.rotuloT3.altura,
              idLayout: 'TamanhosConfiguracoes.rotuloT3',
            ),
          Tx(
            'Em seguida o aplicativo reinicia sozinho.',
            tam: Letra.apoio,
            peso: FontWeight.bold,
            largura: TamanhosConfiguracoes
                .rotuloEmSeguidaOAplicativoReiniciaSozinho
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloEmSeguidaOAplicativoReiniciaSozinho
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloEmSeguidaOAplicativoReiniciaSozinho',
          ),
        ],
        justa: true,
        espaco: 10,
        idLayout: 'Grupo.config.col.14',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosConfiguracoes.botaoCancelar5.largura,
          altura: TamanhosConfiguracoes.botaoCancelar5.altura,
          idLayout: 'TamanhosConfiguracoes.botaoCancelar5',
        ),
        Botao(
          'Restaurar',
          icone: Icons.settings_backup_restore,
          fundo: Colors.red.shade700,
          cor: Colors.white,
          aoClicar: confirmar,
          largura: TamanhosConfiguracoes.botaoRestaurar.largura,
          altura: TamanhosConfiguracoes.botaoRestaurar.altura,
          idLayout: 'TamanhosConfiguracoes.botaoRestaurar',
        ),
      ],
      idLayout: 'Janela.config.Dialogo.7',
    );
    app.mostrarDialogo(d);
  }

  // ---- nova senha mestra ----------------------------------------------------------------------- //
  /// Gera uma senha mestra NOVA. Ela é mostrada ANTES de valer e só é aplicada no "Anotei":
  /// se o programa fechar antes, a antiga continua abrindo o banco.
  void _novaSenhaMestra() {
    final nova = ja<String>('chaves.nova_senha_mestra');
    late final Dialogo d;
    late final TextEditingController campo;

    void copiarSenha() {
      Clipboard.setData(ClipboardData(text: nova)).then(
        (_) =>
            app.toast('Senha copiada. Cole em local seguro e apague depois.'),
        onError: (Object e) {
          registrar(
            'Falha ao copiar para a área de transferência: $e',
            nivel: 'error',
          );
          app.toast(
            'Não consegui copiar — selecione o texto no campo e use Ctrl+C.',
            erro: true,
          );
        },
      );
    }

    void aplicar() {
      app.fecharDialogo();
      try {
        ja<Object?>('chaves.trocar_senha_mestra', {'nova': nova});
      } catch (e) {
        registrar('Erro ao trocar a senha mestra: $e', nivel: 'error');
        app.toast('A senha mestra NÃO foi trocada: $e', erro: true);
        return;
      }
      app.toast('Senha mestra trocada. A anterior não abre mais este banco.');
    }

    d = Dialogo(
      titulo: (_) => textoTitulo('Senha mestra de recuperação'),
      largura: 520,
      conteudo: (_) => col(
        [
          Tx(
            'Anote esta senha e guarde FORA do computador (papel). '
            'Ela NÃO será mostrada novamente:',
            largura: TamanhosConfiguracoes
                .rotuloAnoteEstaSenhaEGuardeFORADoComputador
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloAnoteEstaSenhaEGuardeFORADoComputador
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloAnoteEstaSenhaEGuardeFORADoComputador',
          ),
          lin(
            [
              Expanded(
                child: CampoTexto(
                  controle: campo,
                  rotulo: 'Senha mestra de recuperação',
                  somenteLeitura: true,
                  expandir: true,
                  alinhamento: TextAlign.center,
                  estilo: const TextStyle(
                    fontSize: Letra.senhaMestra,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Consolas',
                  ),
                  largura: TamanhosConfiguracoes
                      .campoSenhaMestraDeRecuperacao
                      .largura,
                  altura: TamanhosConfiguracoes
                      .campoSenhaMestraDeRecuperacao
                      .altura,
                  idLayout:
                      'TamanhosConfiguracoes.campoSenhaMestraDeRecuperacao',
                ),
              ),
              BotaoIcone(
                Icons.content_copy,
                dica: 'Copiar',
                aoClicar: copiarSenha,
                largura: TamanhosConfiguracoes.botaoCopiar.largura,
                altura: TamanhosConfiguracoes.botaoCopiar.altura,
                idLayout: 'TamanhosConfiguracoes.botaoCopiar',
              ),
            ],
            espaco: 4,
            idLayout: 'Grupo.config.lin.36',
          ),
          _nota(_textoSenhaMestra),
          Tx(
            'Ao confirmar, a senha mestra atual deixa de valer para este banco. '
            'Os backups feitos até agora continuam abrindo só com a antiga.',
            tam: Letra.apoio,
            cor: Colors.orange.shade800,
            largura: TamanhosConfiguracoes
                .rotuloAoConfirmarASenhaMestraAtualDeixaDe
                .largura,
            altura: TamanhosConfiguracoes
                .rotuloAoConfirmarASenhaMestraAtualDeixaDe
                .altura,
            idLayout: 'TamanhosConfiguracoes.rotuloAoConfirmarASenhaMestraAtualDeixaDe',
          ),
        ],
        justa: true,
        espaco: 12,
        idLayout: 'Grupo.config.col.16',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosConfiguracoes.botaoCancelar6.largura,
          altura: TamanhosConfiguracoes.botaoCancelar6.altura,
          idLayout: 'TamanhosConfiguracoes.botaoCancelar6',
        ),
        Botao(
          'Anotei, trocar agora',
          icone: Icons.check,
          aoClicar: aplicar,
          largura: TamanhosConfiguracoes.botaoAnoteiTrocarAgora.largura,
          altura: TamanhosConfiguracoes.botaoAnoteiTrocarAgora.altura,
          idLayout: 'TamanhosConfiguracoes.botaoAnoteiTrocarAgora',
        ),
      ],
      idLayout: 'Janela.config.Dialogo.8',
    );
    campo = d.texto(nova);
    app.mostrarDialogo(d);
  }

  @override
  Widget construir(BuildContext context) => _moldura([
    _tituloCartao('Backup'),
    _nota(
      'Tudo o que o programa guarda está em dois bancos, na pasta abaixo: dados.db '
      '(cadastros, certificados, usuários, séries e numerações) e notas.db (os '
      'XMLs do Cofre). Os dois são criptografados por inteiro e só abrem com a '
      'senha de um usuário ou com a SENHA MESTRA. O backup é um arquivo .zip com '
      'os dados, com as notas ou com os dois. O dados.key, ao lado deles, não '
      'precisa de backup: é refeito a partir do banco sempre que faltar.',
    ),
    Tx(
      _pasta,
      tam: Letra.codigo,
      fonte: 'Consolas',
      selecionavel: true,
      cor: Colors.grey.shade800,
      largura: TamanhosConfiguracoes.rotuloPasta.largura,
      altura: TamanhosConfiguracoes.rotuloPasta.altura,
      idLayout: 'TamanhosConfiguracoes.rotuloPasta',
    ),
    lin(
      [
        Botao(
          'Fazer backup…',
          icone: Icons.save_alt,
          desabilitado: app.backupEmAndamento,
          aoClicar: _abrirBackup,
          largura: TamanhosConfiguracoes.botaoFazerBackup.largura,
          altura: TamanhosConfiguracoes.botaoFazerBackup.altura,
          idLayout: 'TamanhosConfiguracoes.botaoFazerBackup',
        ),
        // Restauração é destrutiva: exige senha de nível 3 antes do seletor de arquivo.
        Botao.contorno(
          'Restaurar backup…',
          icone: Icons.settings_backup_restore,
          aoClicar: () => app.exigirNivel(
            3,
            () => unawaited(_escolherRestauracao()),
            titulo: 'Restaurar backup',
          ),
          largura: TamanhosConfiguracoes.botaoRestaurarBackup.largura,
          altura: TamanhosConfiguracoes.botaoRestaurarBackup.altura,
          idLayout: 'TamanhosConfiguracoes.botaoRestaurarBackup',
        ),
      ],
      quebra: true,
      idLayout: 'Grupo.config.lin.37',
    ),
  ]);
}

class _CartaoSenhaMestra extends _Cartao {
  _CartaoSenhaMestra(super.pai);
  @override
  Widget construir(BuildContext context) => _moldura([
    _tituloCartao('Senha mestra'),
    _nota(
      'Troque a senha mestra de recuperação. É necessária a senha de um usuário de nível 4.',
    ),
    Botao.contorno(
      'Nova senha mestra…',
      icone: Icons.key,
      aoClicar: () => app.exigirNivel(
        _nivelMaster,
        () => pai._banco._novaSenhaMestra(),
        titulo: 'Nova senha mestra',
        semprePedirSenha: true,
      ),
      largura: TamanhosConfiguracoes.botaoNovaSenhaMestra.largura,
      altura: TamanhosConfiguracoes.botaoNovaSenhaMestra.altura,
      idLayout: 'TamanhosConfiguracoes.botaoNovaSenhaMestra',
    ),
  ]);
}

// ------------------------------------------------------------------------------------------- //
// Atualizações
// ------------------------------------------------------------------------------------------- //
class _CartaoAtualizacao extends _Cartao {
  _CartaoAtualizacao(super.pai) {
    _ler();
  }

  Map<String, dynamic> _e = const {};

  void _ler() {
    try {
      _e = jaMapa('atualizacao.estado');
    } catch (_) {
      _e = const {};
    }
  }

  void _automatica(bool v) {
    try {
      _e = jaMapa('atualizacao.configurar', {'automatica': v});
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    redesenhar();
  }

  static String _quando(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (d == null) return 'nunca';
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)}/${d.year} às ${dois(d.hour)}:${dois(d.minute)}';
  }

  @override
  Widget construir(BuildContext context) {
    final pulada = '${_e['pular'] ?? ''}';
    return _moldura([
      _tituloCartao('Atualizações'),
      _nota(
        'Versão instalada: ${_e['versao'] ?? '—'}  ·  Última procura: ${_quando(_e['ultima'])}'
        '${pulada.isEmpty ? '' : '  ·  Versão pulada: $pulada'}',
      ),
      _nota(
        'As versões novas saem na página do projeto no GitHub. A atualização baixa a versão '
        'nova, confere se o arquivo chegou inteiro e reinicia o programa. Cadastros, notas, '
        'certificados e configurações continuam como estão.',
      ),
      Marcar(
        valor: _e['automatica'] != false,
        rotulo: 'Procurar versão nova sozinho ao abrir o programa (uma vez por dia)',
        rente: true,
        aoMudar: (v) => _automatica(v == true),
        idLayout: 'TamanhosConfiguracoes.marcarAtualizacaoAutomatica',
      ),
      if (_e['instalavel'] == false)
        _nota(
          'Esta cópia está em modo de desenvolvimento: ela avisa da versão nova, mas não se '
          'instala sozinha.',
        ),
      divisor(),
      lin([
        Botao(
          'Procurar atualizações agora',
          icone: Icons.system_update_alt,
          aoClicar: () async {
            await procurarAtualizacao(app);
            _ler();
            redesenhar();
          },
          largura: TamanhosConfiguracoes.botaoProcurarAtualizacao.largura,
          altura: TamanhosConfiguracoes.botaoProcurarAtualizacao.altura,
          idLayout: 'TamanhosConfiguracoes.botaoProcurarAtualizacao',
        ),
        Botao.contorno(
          'Acessar página GitHub',
          icone: Icons.open_in_new,
          aoClicar: () => abrirEndereco(
            '${_e['pagina_projeto'] ?? 'https://github.com/williamlala/baiacu-nfse'}',
          ),
          largura: TamanhosConfiguracoes.botaoPaginaGithub.largura,
          altura: TamanhosConfiguracoes.botaoPaginaGithub.altura,
          idLayout: 'TamanhosConfiguracoes.botaoPaginaGithub',
        ),
      ], idLayout: 'Grupo.config.lin.atualizacao'),
    ]);
  }
}

/// Configurações › Apoie este projeto: o convite e o botão que abre a janela de doação.
class _CartaoApoio extends _Cartao {
  _CartaoApoio(super.pai);

  @override
  Widget construir(BuildContext context) => _moldura([
    _tituloCartao('Apoie este projeto'),
    Tx(
      'O Baiacu NFS-e é feito com carinho e distribuído de graça, sem anúncios e sem '
      'mensalidade. Se ele economiza o seu tempo, considere uma doação em criptomoeda.',
      largura: TamanhosConfiguracoes.rotuloApoio.largura,
      altura: TamanhosConfiguracoes.rotuloApoio.altura,
      idLayout: 'TamanhosConfiguracoes.rotuloApoio',
    ),
    lin([BotaoContribuir(app: app)], idLayout: 'Grupo.config.lin.apoio'),
  ]);
}
