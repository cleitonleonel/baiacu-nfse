/// Código de autorização: 2 letras ou números escolhidos para cada conta. Para autorizar uma
/// ação, a pessoa digita o código seguido da senha, num campo só (código AD + senha → AD...).
/// O código não diferencia maiúsculas de minúsculas; a senha continua diferenciando.
library;

import 'package:flutter/material.dart';

import '../kit/campo.dart';
import '../kit/flet.dart';
import 'app.dart';

const tamanhoCodigo = 2;

/// Só letras sem acento e algarismos, em maiúsculas.
String mascaraCodigo(String s) =>
    s.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

const explicacaoCodigo =
    'Para autorizar uma ação, digite o código seguido da senha, sem espaço. Exemplo: código AD e senha Baiacu@26 viram ADBaiacu@26.';

/// Confere o código enquanto ele é digitado e oferece até 3 parecidos quando já está em uso.
class ConferenciaCodigo {
  ConferenciaCodigo({
    required this.controle,
    required this.aoMudar,
    this.proprio = false,
  });

  final TextEditingController controle;

  /// Redesenha quem mostra o campo (normalmente `d.atualizar`).
  final VoidCallback aoMudar;

  /// Troca do código da conta em uso: o código atual dela conta como disponível.
  final bool proprio;

  /// O código que a conta já tem (só para a troca do próprio).
  String? atual;

  String _conferido = '';
  int _pedido = 0;
  bool conferindo = false;
  bool disponivel = false;
  String erro = '';
  List<String> sugestoes = const [];

  String get codigo => mascaraCodigo(controle.text);
  bool get completo => codigo.length == tamanhoCodigo;

  /// Código completo, conferido e livre.
  bool get pronto =>
      completo && !conferindo && _conferido == codigo && disponivel;

  void mudou([String _ = '']) {
    final c = codigo;
    erro = '';
    if (!completo) {
      _pedido++;
      _conferido = '';
      conferindo = false;
      disponivel = false;
      sugestoes = const [];
      aoMudar();
      return;
    }
    if (c == _conferido && !conferindo) return;
    _conferir(c);
  }

  Future<void> _conferir(String c) async {
    final pedido = ++_pedido;
    conferindo = true;
    aoMudar();
    try {
      final r = await chamar<Map>('usuarios.conferir_codigo', {
        'codigo': c,
        'proprio': proprio,
      });
      if (pedido != _pedido) return;
      _conferido = c;
      disponivel = r['disponivel'] == true;
      sugestoes = [for (final s in (r['sugestoes'] as List? ?? const [])) '$s'];
    } catch (e) {
      if (pedido != _pedido) return;
      _conferido = '';
      disponivel = false;
      sugestoes = const [];
      erro = 'Não foi possível conferir o código: $e';
    } finally {
      if (pedido == _pedido) {
        conferindo = false;
        aoMudar();
      }
    }
  }

  /// Um código sugerido foi escolhido.
  void usar(String s) {
    controle.value = TextEditingValue(
      text: s,
      selection: TextSelection.collapsed(offset: s.length),
    );
    mudou();
  }

  /// O erro do núcleo ao gravar (ex.: o código foi ocupado por outra conta agora há pouco).
  void recusado() {
    _conferido = '';
    mudou();
  }

  Widget campo({
    required String idLayout,
    double? largura,
    bool focoInicial = false,
    bool desabilitado = false,
    FocusNode? foco,
    ValueChanged<String>? aoEnviar,
  }) => CampoTexto(
    controle: controle,
    rotulo: 'Código de autorização',
    largura: largura,
    maximo: tamanhoCodigo,
    ocultarContador: true,
    mascara: mascaraCodigo,
    focoInicial: focoInicial,
    desabilitado: desabilitado,
    foco: foco,
    aoMudar: mudou,
    aoEnviar: aoEnviar,
    dicaMouse: '2 letras ou números, escolhidos por você.',
    idLayout: idLayout,
  );

  /// A linha embaixo do campo: disponível, em uso (com as sugestões clicáveis) ou erro.
  Widget situacao({required String idLayout}) {
    Widget texto(String t, {Color? cor, FontWeight? peso}) => Tx(
      t,
      tam: Letra.apoio,
      cor: cor,
      peso: peso,
      idLayout: '$idLayout.texto',
    );
    final Widget conteudo;
    if (erro.isNotEmpty) {
      conteudo = texto(erro, cor: Colors.red.shade600);
    } else if (!completo) {
      conteudo = texto(
        '2 letras ou números. Maiúsculas e minúsculas valem o mesmo.',
        cor: Colors.grey.shade700,
      );
    } else if (conferindo || _conferido != codigo) {
      conteudo = texto('Conferindo o código…', cor: Colors.grey.shade700);
    } else if (disponivel) {
      conteudo = texto(
        proprio && codigo == atual
            ? 'Este é o seu código atual.'
            : 'Disponível.',
        cor: Colors.green.shade700,
        peso: FontWeight.w600,
      );
    } else {
      conteudo = lin(
        [
          texto(
            sugestoes.isEmpty
                ? 'Este código já está em uso. Escolha outro.'
                : 'Em uso. Disponíveis:',
            cor: Colors.red.shade600,
          ),
          for (final s in sugestoes)
            Botao.texto(
              s,
              compacto: true,
              dica: 'Usar o código $s',
              aoClicar: () => usar(s),
              idLayout: '$idLayout.sugestao.$s',
            ),
        ],
        espaco: 4,
        idLayout: '$idLayout.linha',
      );
    }
    // Altura mínima fixa: a janela não pula enquanto o código é conferido.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Align(alignment: Alignment.centerLeft, child: conteudo),
    );
  }
}

/// Depois do login: a conta sem código de autorização é convidada a escolher o dela. Fica para
/// depois se a pessoa quiser; o convite volta no próximo acesso.
Future<void> pedirCodigoSeFaltar(App app) async {
  String? atual;
  try {
    atual = await chamar<String?>('usuarios.codigo_proprio');
  } catch (e) {
    registrar(
      'Não foi possível ler o código de autorização: $e',
      nivel: 'error',
    );
    return;
  }
  if (!app.viva || (atual != null && atual.isNotEmpty)) return;
  abrirDefinirCodigo(app, convite: true);
}

/// Janela para definir ou trocar o código da conta em uso.
void abrirDefinirCodigo(
  App app, {
  bool convite = false,
  String? atual,
  Usuario? alvo,
  ValueChanged<String>? aoSalvar,
}) {
  late final Dialogo d;
  late final ConferenciaCodigo c;
  var salvando = false;

  Future<void> salvar() async {
    if (salvando || !c.pronto) {
      if (!c.completo) c.erro = 'Informe 2 letras ou números.';
      d.atualizar();
      return;
    }
    salvando = true;
    d.atualizar();
    try {
      final gravado = await chamar<String>(
        alvo == null
            ? 'usuarios.definir_codigo_proprio'
            : 'usuarios.redefinir_codigo',
        {'codigo': c.codigo, if (alvo != null) 'usuario_id': alvo.id},
      );
      aoSalvar?.call(gravado);
      if (!d.aberto) return;
      app.fecharEsta(d);
      // O aviso também vai para o log: o código fica fora do texto.
      app.toast('Código de autorização salvo.');
    } catch (e) {
      if (!d.aberto) return;
      c.recusado();
      c.erro = '$e';
    } finally {
      salvando = false;
      d.atualizar();
    }
  }

  d = Dialogo(
    titulo: (_) => app.tituloComX(
      alvo == null ? 'Código de autorização' : 'Redefinir código',
    ),
    largura: 440,
    conteudo: (_) => col(
      [
        Tx(
          alvo != null
              ? 'Escolha um novo código de autorização para ${alvo.login.toUpperCase()}.'
              : convite
              ? 'Escolha o código de autorização desta conta. Ele identifica quem autoriza uma ação.'
              : 'Troque o código de autorização desta conta.',
          tam: Letra.texto,
          idLayout: 'CodigoAutorizacao.rotuloConvite',
        ),
        Tx(
          explicacaoCodigo,
          tam: Letra.apoio,
          cor: Colors.grey.shade700,
          idLayout: 'CodigoAutorizacao.rotuloExplicacao',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: c.campo(
            idLayout: 'TamanhosMenuUsuario.campoCodigo',
            largura: TamanhosMenuUsuario.campoCodigo.largura,
            focoInicial: true,
            desabilitado: salvando,
            aoEnviar: (_) => salvar(),
          ),
        ),
        c.situacao(idLayout: 'CodigoAutorizacao.situacao'),
      ],
      justa: true,
      espaco: 8,
      idLayout: 'Grupo.codigo_autorizacao.col.1',
    ),
    acoes: (_) => [
      Botao.texto(
        convite ? 'Depois' : 'Cancelar',
        aoClicar: () => app.fecharEsta(d),
        idLayout: 'CodigoAutorizacao.botaoDepois',
      ),
      Botao(
        'Salvar',
        icone: Icons.save,
        aoClicar: salvando || !c.pronto ? null : salvar,
        idLayout: 'CodigoAutorizacao.botaoSalvar',
      ),
    ],
    idLayout: 'Janela.codigo_autorizacao.Dialogo.1',
  );
  c = ConferenciaCodigo(
    controle: d.texto(atual ?? ''),
    aoMudar: d.atualizar,
    proprio: alvo == null,
  )..atual = atual;
  app.mostrarDialogo(d);
  if (c.completo) c.mudou();
}
