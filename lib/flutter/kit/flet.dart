/// Os controles do programa, montados como o cliente de referência os montava: mesmos
/// widgets do Material, mesmos parâmetros e mesmos padrões (espaço de 10 entre filhos de
/// linha e coluna, linha centrada na vertical, coluna alinhada à esquerda, dica do mouse com
/// 0,8 s de espera…). As telas descrevem o que querem; a aparência sai daqui.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../editor_layout.dart';

import 'package:flutter/rendering.dart';

import '../estilo.dart';
import 'menu_suspenso.dart';
import 'contorno_campo.dart';

// Quem usa o kit enxerga os tamanhos (Letra, Medida).
export '../estilo.dart';
export '../editor_layout.dart' show ElementoLayoutGenerico, editorLayoutAtivo;

// --------------------------------------------------------------------------- //
// Trava: uma região desabilitada desabilita tudo o que está dentro dela.
// --------------------------------------------------------------------------- //
class _Trava extends InheritedWidget {
  const _Trava({required this.travado, required super.child});
  final bool travado;

  @override
  bool updateShouldNotify(_Trava antigo) => antigo.travado != travado;
}

/// Desabilita os controles de [child] quando [se] é verdadeiro (ou quando já está dentro
/// de uma região travada).
class Travar extends StatelessWidget {
  const Travar({super.key, required this.se, required this.child});
  final bool se;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _Trava(travado: se || travado(context), child: child);
}

bool travado(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_Trava>()?.travado ?? false;

/// A trava de uma região que nem sempre está à vista (uma tela guardada): escondida, ela
/// fica com a trava que tinha quando saiu de cena — abrir e fechar janelas não redesenha o
/// que ninguém está vendo; ao voltar, passa a valer a trava de agora.
class TravaDaVez extends StatefulWidget {
  const TravaDaVez({super.key, required this.aVista, required this.child});
  final bool aVista;
  final Widget child;

  @override
  State<TravaDaVez> createState() => _TravaDaVezState();
}

class _TravaDaVezState extends State<TravaDaVez> {
  bool _trava = false;

  @override
  Widget build(BuildContext context) {
    final agora = travado(context);
    if (widget.aVista) _trava = agora;
    return _Trava(travado: _trava, child: widget.child);
  }
}

// --------------------------------------------------------------------------- //
// Peças de moldura
// --------------------------------------------------------------------------- //
Widget comDica(String? mensagem, Widget filho) =>
    (mensagem == null || mensagem.isEmpty)
    ? filho
    : Tooltip(
        message: mensagem,
        waitDuration: const Duration(milliseconds: 800),
        child: filho,
      );

Widget comTamanho(Widget filho, {double? largura, double? altura}) =>
    (largura == null && altura == null)
    ? filho
    : SizedBox(width: largura, height: altura, child: filho);

/// Camada própria de pintura: animar o que está dentro não redesenha o que está fora.
Widget fronteira(Widget filho) => RepaintBoundary(child: filho);

/// Anel de progresso giratório em camada própria.
Widget anel({double tamanho = 20, double? traco, Color? cor}) => fronteira(
  SizedBox(
    width: tamanho,
    height: tamanho,
    child: CircularProgressIndicator(strokeWidth: traco, color: cor),
  ),
);

// --------------------------------------------------------------------------- //
// Texto
// --------------------------------------------------------------------------- //
class Tx extends StatelessWidget implements TextoLayout {
  const Tx(
    this.valor, {
    super.key,
    this.idLayout,
    this.tam,
    this.peso,
    this.cor,
    this.fundo,
    this.italico = false,
    this.alinhar = TextAlign.start,
    this.linhas,
    this.corte,
    this.semQuebra = false,
    this.fonte,
    this.largura,
    this.dica,
    this.selecionavel = false,
    this.altura,
    this.tema,
    this.trechos = const [],
  });

  final String valor;
  final double? tam;
  final FontWeight? peso;
  final Color? cor;
  final Color? fundo;
  final bool italico;
  final TextAlign alinhar;
  final int? linhas;
  final TextOverflow? corte;
  final bool semQuebra;
  final String? fonte;
  final double? largura;
  final String? dica;
  final bool selecionavel;
  final double? altura;
  final TextStyle? Function(TextTheme)? tema;
  final List<TextSpan> trechos;

  final String? idLayout;

  @override
  Widget build(BuildContext context) {
    final ajuste = ajusteLayout(context, idLayout);
    final p = ajuste.negrito == null
        ? peso
        : ajuste.negrito!
        ? FontWeight.bold
        : FontWeight.normal;
    final variacoes = <FontVariation>[
      if (p != null && p != FontWeight.bold && p != FontWeight.normal)
        FontVariation('wght', p.value.toDouble()),
    ];
    final estilo = ajuste.estilo(
      (tema?.call(Theme.of(context).textTheme) ?? const TextStyle()).copyWith(
        overflow: corte,
        fontSize: ajuste.tamanhoFonte ?? tam,
        fontWeight: p,
        fontStyle: italico ? FontStyle.italic : null,
        fontFamily: ajuste.fonte ?? fonte,
        fontVariations: variacoes,
        color:
            cor ??
            (trechos.isNotEmpty
                ? DefaultTextStyle.of(context).style.color
                : null),
        backgroundColor: fundo,
      ),
    );
    final exibido = ajuste.exibir(valor);
    final usarTrechos =
        trechos.isNotEmpty && ajuste.texto == null && !ajuste.oculto;
    Widget w;
    if (selecionavel) {
      w = usarTrechos
          ? SelectableText.rich(
              TextSpan(text: exibido, style: estilo, children: trechos),
              maxLines: linhas,
              textAlign: ajuste.alinhamento ?? alinhar,
              cursorWidth: 2.0,
              showCursor: false,
              enableInteractiveSelection: true,
              onTap: () {},
            )
          : SelectableText(
              exibido,
              maxLines: linhas,
              style: estilo,
              textAlign: ajuste.alinhamento ?? alinhar,
              cursorWidth: 2.0,
              showCursor: false,
              enableInteractiveSelection: true,
              onTap: () {},
            );
    } else {
      w = usarTrechos
          ? Text.rich(
              TextSpan(text: exibido, style: estilo, children: trechos),
              maxLines: linhas,
              softWrap: !semQuebra,
              textAlign: ajuste.alinhamento ?? alinhar,
            )
          : Text(
              exibido,
              maxLines: linhas,
              softWrap: !semQuebra,
              style: estilo,
              textAlign: ajuste.alinhamento ?? alinhar,
            );
    }
    return alvoLayout(
      context,
      comTamanho(
        comDica(dica, w),
        largura: ajuste.largura ?? largura,
        altura: ajuste.altura ?? altura,
      ),
      id: idLayout,
      nome: valor,
      propriedades: propriedadesTexto(
        context,
        exibido,
        estilo: estilo,
        alinhamento: ajuste.alinhamento ?? alinhar,
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// Linha e coluna
// --------------------------------------------------------------------------- //
WrapAlignment _quebraDe(MainAxisAlignment a) => switch (a) {
  MainAxisAlignment.start => WrapAlignment.start,
  MainAxisAlignment.end => WrapAlignment.end,
  MainAxisAlignment.center => WrapAlignment.center,
  MainAxisAlignment.spaceBetween => WrapAlignment.spaceBetween,
  MainAxisAlignment.spaceAround => WrapAlignment.spaceAround,
  MainAxisAlignment.spaceEvenly => WrapAlignment.spaceEvenly,
};

WrapCrossAlignment _cruzadoDe(CrossAxisAlignment a) => switch (a) {
  CrossAxisAlignment.start => WrapCrossAlignment.start,
  CrossAxisAlignment.end => WrapCrossAlignment.end,
  _ => WrapCrossAlignment.center,
};

/// Linha: espaço 10, centrada na vertical, ocupa toda a largura (a menos de [justa]).
Widget lin(
  List<Widget> filhos, {
  String? idLayout,
  double espaco = Medida.espacoEntreCampos,
  MainAxisAlignment principal = MainAxisAlignment.start,
  CrossAxisAlignment cruzado = CrossAxisAlignment.center,
  bool justa = false,
  bool quebra = false,
  double espacoLinhas = Medida.espacoEntreCampos,
  double? largura,
  double? altura,
  bool rolar = false,
}) {
  return Builder(
    key: idLayout == null ? null : ValueKey(idLayout),
    builder: (context) {
      final ajuste = ajusteLayout(context, idLayout);
      Widget w = quebra
          ? Wrap(
              direction: Axis.horizontal,
              spacing: ajuste.espaco ?? espaco,
              runSpacing: ajuste.espacoLinhas ?? espacoLinhas,
              alignment: _quebraDe(principal),
              runAlignment: WrapAlignment.start,
              crossAxisAlignment: _cruzadoDe(cruzado),
              children: idLayout == null
                  ? itensVisiveisLayout(context, filhos)
                  : comEspacosLayout(
                      context,
                      filhos,
                      id: idLayout,
                      eixo: Axis.horizontal,
                      espaco: ajuste.espaco ?? espaco,
                      separadores: false,
                    ),
            )
          : Row(
              spacing: idLayout == null ? ajuste.espaco ?? espaco : 0,
              mainAxisSize: justa ? MainAxisSize.min : MainAxisSize.max,
              mainAxisAlignment: principal,
              crossAxisAlignment: cruzado,
              children: idLayout == null
                  ? itensVisiveisLayout(context, filhos)
                  : comEspacosLayout(
                      context,
                      filhos,
                      id: idLayout,
                      eixo: Axis.horizontal,
                      espaco: ajuste.espaco ?? espaco,
                    ),
            );
      if (rolar) {
        w = Rolagem(
          direcao: quebra ? Axis.vertical : Axis.horizontal,
          child: w,
        );
      }
      final sized = comTamanho(
        w,
        largura: ajuste.largura ?? largura,
        altura: ajuste.altura ?? altura,
      );
      if (idLayout == null) return sized;
      return GrupoLayoutScope(
        id: idLayout,
        child: alvoLayout(
          context,
          sized,
          id: idLayout,
          nome: 'Linha',
          tipo: 'grupo',
          grupo: true,
          propriedades: {
            'espaco': ajuste.espaco ?? espaco,
            'espacoLinhas': ajuste.espacoLinhas ?? espacoLinhas,
          },
        ),
      );
    },
  );
}

/// Coluna: espaço 10, alinhada à esquerda, ocupa toda a altura (a menos de [justa]).
Widget col(
  List<Widget> filhos, {
  String? idLayout,
  double espaco = Medida.espacoEntreCampos,
  MainAxisAlignment principal = MainAxisAlignment.start,
  CrossAxisAlignment cruzado = CrossAxisAlignment.start,
  bool justa = false,
  double? largura,
  double? altura,
  bool rolar = false,
  ScrollController? controle,
}) {
  return Builder(
    key: idLayout == null ? null : ValueKey(idLayout),
    builder: (context) {
      final ajuste = ajusteLayout(context, idLayout);
      Widget w = Column(
        mainAxisAlignment: principal,
        spacing: idLayout == null ? ajuste.espaco ?? espaco : 0,
        mainAxisSize: justa ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: cruzado,
        children: idLayout == null
            ? itensVisiveisLayout(context, filhos)
            : comEspacosLayout(
                context,
                filhos,
                id: idLayout,
                eixo: Axis.vertical,
                espaco: ajuste.espaco ?? espaco,
              ),
      );
      if (rolar) {
        w = Rolagem(direcao: Axis.vertical, controle: controle, child: w);
      }
      final sized = comTamanho(
        w,
        largura: ajuste.largura ?? largura,
        altura: ajuste.altura ?? altura,
      );
      if (idLayout == null) return sized;
      return GrupoLayoutScope(
        id: idLayout,
        child: alvoLayout(
          context,
          sized,
          id: idLayout,
          nome: 'Coluna',
          tipo: 'grupo',
          grupo: true,
          propriedades: {'espaco': ajuste.espaco ?? espaco},
        ),
      );
    },
  );
}

/// Rolagem com barra, em que o conteúdo ocupa pelo menos a área visível (o alinhamento do
/// que está dentro continua valendo quando sobra espaço). A barra fica à vista sempre que há
/// o que rolar: é ela que avisa que a tela não coube inteira.
class Rolagem extends StatefulWidget {
  const Rolagem({
    super.key,
    required this.child,
    this.direcao = Axis.vertical,
    this.justa = false,
    this.controle,
  });
  final Widget child;
  final Axis direcao;

  /// O conteúdo fica do tamanho que tem (não estica até a área visível).
  final bool justa;
  final ScrollController? controle;

  @override
  State<Rolagem> createState() => _RolagemState();
}

class _RolagemState extends State<Rolagem> {
  ScrollController? _proprio;
  final _medidas = _Medidas();

  ScrollController get _c =>
      widget.controle ?? (_proprio ??= ScrollController());

  @override
  void dispose() {
    _proprio?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rolavel = Scrollbar(
      thumbVisibility: true,
      controller: _c,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _c,
          scrollDirection: widget.direcao,
          child: widget.justa
              ? widget.child
              : _MinimoDeDentro(
                  medidas: _medidas,
                  direcao: widget.direcao,
                  child: widget.child,
                ),
        ),
      ),
    );
    return widget.justa
        ? rolavel
        : _LeitorDeFora(medidas: _medidas, child: rolavel);
  }
}

class _Medidas {
  BoxConstraints? valor;
  RenderObject? ouvinte;
}

class _LeitorDeFora extends SingleChildRenderObjectWidget {
  const _LeitorDeFora({required this.medidas, super.child});
  final _Medidas medidas;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLeitorDeFora(medidas);

  @override
  void updateRenderObject(BuildContext context, _RenderLeitorDeFora r) {
    r.medidas = medidas;
  }
}

class _RenderLeitorDeFora extends RenderProxyBox {
  _RenderLeitorDeFora(this.medidas);
  _Medidas medidas;

  @override
  void performLayout() {
    final mudou = medidas.valor != constraints;
    medidas.valor = constraints;
    if (mudou && medidas.ouvinte != null) {
      invokeLayoutCallback<BoxConstraints>((_) {
        medidas.ouvinte?.markNeedsLayout();
      });
    }
    super.performLayout();
  }
}

class _MinimoDeDentro extends SingleChildRenderObjectWidget {
  const _MinimoDeDentro({
    required this.medidas,
    required this.direcao,
    super.child,
  });
  final _Medidas medidas;
  final Axis direcao;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMinimoDeDentro(medidas, direcao);

  @override
  void updateRenderObject(BuildContext context, _RenderMinimoDeDentro r) {
    r
      ..medidas = medidas
      ..direcao = direcao;
  }
}

class _RenderMinimoDeDentro extends RenderProxyBox {
  _RenderMinimoDeDentro(this.medidas, this.direcao);
  _Medidas medidas;
  Axis direcao;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    medidas.ouvinte = this;
  }

  @override
  void detach() {
    if (medidas.ouvinte == this) medidas.ouvinte = null;
    super.detach();
  }

  @override
  void performLayout() {
    if (child == null) {
      size = computeSizeForNoChild(constraints);
      return;
    }
    var limites = constraints;
    final fora = medidas.valor;
    if (fora != null) {
      if (direcao == Axis.vertical && fora.hasBoundedHeight) {
        limites = limites.copyWith(minHeight: fora.maxHeight);
      } else if (direcao == Axis.horizontal && fora.hasBoundedWidth) {
        limites = limites.copyWith(minWidth: fora.maxWidth);
      }
    }
    child!.layout(limites, parentUsesSize: true);
    size = child!.size;
  }
}

// --------------------------------------------------------------------------- //
// Caixa
// --------------------------------------------------------------------------- //
class Ct extends StatelessWidget {
  const Ct({
    super.key,
    this.child,
    this.largura,
    this.altura,
    this.padding,
    this.margem,
    this.alinhar,
    this.cor,
    this.raio,
    this.borda,
    this.sombra,
    this.forma,
    this.gradiente,
    this.imagem,
    this.recorte,
    this.aoClicar,
    this.aoPairar,
    this.dica,
    this.animar,
    this.curva = Curves.linear,
    this.desabilitado = false,
    this.opacidade,
  });

  final Widget? child;
  final double? largura;
  final double? altura;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margem;
  final AlignmentGeometry? alinhar;
  final Color? cor;
  final BorderRadius? raio;
  final BoxBorder? borda;
  final List<BoxShadow>? sombra;
  final BoxShape? forma;
  final Gradient? gradiente;
  final DecorationImage? imagem;
  final Clip? recorte;
  final VoidCallback? aoClicar;
  final ValueChanged<bool>? aoPairar;
  final String? dica;
  final Duration? animar;
  final Curve curva;
  final bool desabilitado;
  final double? opacidade;

  @override
  Widget build(BuildContext context) {
    final decorado =
        cor != null ||
        borda != null ||
        raio != null ||
        gradiente != null ||
        forma != null ||
        sombra != null ||
        imagem != null;
    final decoracao = decorado
        ? BoxDecoration(
            color: cor,
            border: borda == null ? null : BordaFina(borda!),
            borderRadius: forma == BoxShape.circle ? null : raio,
            gradient: gradiente,
            shape: forma ?? BoxShape.rectangle,
            boxShadow: sombra,
            image: imagem,
          )
        : null;
    final clip = recorte ?? (raio != null ? Clip.antiAlias : Clip.none);
    Widget w = animar == null
        ? Container(
            width: largura,
            height: altura,
            margin: margem,
            padding: padding,
            alignment: alinhar,
            decoration: decoracao,
            clipBehavior: clip,
            child: child,
          )
        : AnimatedContainer(
            duration: animar!,
            curve: curva,
            width: largura,
            height: altura,
            margin: margem,
            padding: padding,
            alignment: alinhar,
            decoration: decoracao,
            clipBehavior: clip,
            child: child,
          );
    final inerte = desabilitado || travado(context);
    if ((aoClicar != null || aoPairar != null) && !inerte) {
      w = MouseRegion(
        cursor: inerte
            ? SystemMouseCursors.basic
            : aoClicar != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onEnter: aoPairar != null ? (_) => aoPairar!(true) : null,
        onExit: aoPairar != null ? (_) => aoPairar!(false) : null,
        child: GestureDetector(onTap: aoClicar, child: w),
      );
    }
    if (opacidade != null) w = Opacity(opacity: opacidade!, child: w);
    return comTamanho(comDica(dica, w), largura: largura, altura: altura);
  }
}

/// Área sensível ao mouse (cursor, toque, entrada/saída, arrasto) em volta de um conteúdo.
class Gesto extends StatelessWidget {
  const Gesto({
    super.key,
    required this.child,
    this.cursor,
    this.aoTocar,
    this.aoTocarEm,
    this.aoEntrar,
    this.aoSair,
    this.aoArrastarInicio,
    this.aoArrastar,
    this.aoArrastarFim,
    this.aoDuploToque,
  });
  final Widget child;
  final MouseCursor? cursor;
  final VoidCallback? aoTocar;
  final void Function(TapDownDetails)? aoTocarEm;
  final VoidCallback? aoEntrar;
  final VoidCallback? aoSair;
  final void Function(DragStartDetails)? aoArrastarInicio;
  final void Function(DragUpdateDetails)? aoArrastar;
  final void Function(DragEndDetails)? aoArrastarFim;
  final VoidCallback? aoDuploToque;

  @override
  Widget build(BuildContext context) {
    final inerte = travado(context);
    Widget w = child;
    final temGesto =
        aoTocar != null ||
        aoTocarEm != null ||
        aoArrastarInicio != null ||
        aoArrastar != null ||
        aoArrastarFim != null ||
        aoDuploToque != null;
    if (temGesto) {
      w = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: inerte ? null : aoTocar,
        onTapDown: inerte ? null : aoTocarEm,
        onDoubleTap: inerte ? null : aoDuploToque,
        onPanStart: inerte ? null : aoArrastarInicio,
        onPanUpdate: inerte ? null : aoArrastar,
        onPanEnd: inerte ? null : aoArrastarFim,
        child: w,
      );
    }
    if (cursor != null || aoEntrar != null || aoSair != null) {
      w = MouseRegion(
        cursor: cursor ?? MouseCursor.defer,
        onEnter: aoEntrar != null ? (_) => aoEntrar!() : null,
        onExit: aoSair != null ? (_) => aoSair!() : null,
        child: w,
      );
    }
    return w;
  }
}

/// Deixa o ponteiro atravessar: quem está por baixo recebe os cliques e o hover.
class PonteiroTransparente extends SingleChildRenderObjectWidget {
  const PonteiroTransparente({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPonteiroTransparente();
}

class _RenderPonteiroTransparente extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    super.hitTest(result, position: position);
    return false;
  }
}

// --------------------------------------------------------------------------- //
// Botões
// --------------------------------------------------------------------------- //
/// Estilo próprio de um botão: só o que é dito muda (cor do texto, do fundo, cursor por
/// estado); o resto continua vindo do tema. A elevação passa a 1 em todos os estados — é o
/// que distingue, no desenho, um botão "com estilo" dos que só seguem o tema.
ButtonStyle estiloProprio({
  Color? cor,
  Color? fundo,
  WidgetStateProperty<MouseCursor?>? cursor,
}) => ButtonStyle(
  foregroundColor: cor == null ? null : WidgetStatePropertyAll(cor),
  backgroundColor: fundo == null ? null : WidgetStatePropertyAll(fundo),
  elevation: const WidgetStatePropertyAll(1.0),
  mouseCursor: cursor,
);

/// Cursor comum: mãozinha quando ativo, seta quando desabilitado.
final WidgetStateProperty<MouseCursor?> cursorTrava =
    WidgetStateProperty.resolveWith(
      (estados) => estados.contains(WidgetState.disabled)
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
    );

enum TipoBotao { cheio, contorno, texto }

class Botao extends StatelessWidget {
  const Botao(
    this.rotulo, {
    super.key,
    this.idLayout,
    this.tipo = TipoBotao.cheio,
    this.icone,
    this.corIcone,
    this.filho,
    this.aoClicar,
    this.desabilitado = false,
    this.dica,
    this.largura,
    this.altura,
    this.cor,
    this.fundo,
    this.cursorTravado = false,
    this.foco,
    this.focoInicial = false,
  });

  const Botao.contorno(
    this.rotulo, {
    super.key,
    this.idLayout,
    this.icone,
    this.corIcone,
    this.filho,
    this.aoClicar,
    this.desabilitado = false,
    this.dica,
    this.largura,
    this.altura,
    this.cor,
    this.fundo,
    this.cursorTravado = false,
    this.foco,
    this.focoInicial = false,
  }) : tipo = TipoBotao.contorno;

  const Botao.texto(
    this.rotulo, {
    super.key,
    this.idLayout,
    this.icone,
    this.corIcone,
    this.filho,
    this.aoClicar,
    this.desabilitado = false,
    this.dica,
    this.largura,
    this.altura,
    this.cor,
    this.fundo,
    this.cursorTravado = false,
    this.foco,
    this.focoInicial = false,
  }) : tipo = TipoBotao.texto;

  final String? rotulo;
  final TipoBotao tipo;
  final IconData? icone;
  final Color? corIcone;

  /// Conteúdo no lugar do rótulo.
  final Widget? filho;
  final VoidCallback? aoClicar;
  final bool desabilitado;
  final String? dica;
  final double? largura;
  final double? altura;

  /// Cor do texto e do fundo: como um estilo próprio só com essas cores.
  final Color? cor;
  final Color? fundo;

  /// Desabilitado mostra a seta normal em vez da mãozinha.
  final bool cursorTravado;
  final FocusNode? foco;
  final bool focoInicial;

  final String? idLayout;

  @override
  Widget build(BuildContext context) {
    final ajuste = ajusteLayout(context, idLayout);
    final ativo = !desabilitado && !travado(context);
    final aperta = ativo ? (aoClicar ?? () {}) : null;
    final longo = ativo ? () {} : null;
    final void Function(bool)? paira = ativo ? (_) {} : null;
    final base = cor != null || fundo != null
        ? estiloProprio(cor: cor, fundo: fundo, cursor: cursorTrava)
        : ButtonStyle(mouseCursor: cursorTrava);
    final estiloTema = switch (tipo) {
      TipoBotao.cheio => FilledButtonTheme.of(context).style,
      TipoBotao.contorno => OutlinedButtonTheme.of(context).style,
      TipoBotao.texto => TextButtonTheme.of(context).style,
    };
    final st = ajuste.temFonte || ajuste.alinhamento != null
        ? base.copyWith(
            alignment: ajuste.alinhamentoBotao,
            foregroundColor: ajuste.cor == null
                ? null
                : WidgetStatePropertyAll(ajuste.cor),
            textStyle: WidgetStatePropertyAll(
              ajuste.estilo(
                estiloTema?.textStyle?.resolve({}) ??
                    Theme.of(context).textTheme.labelLarge ??
                    const TextStyle(),
              ),
            ),
          )
        : base;
    final textoOriginal =
        rotulo ??
        (filho is Text
            ? (filho as Text).data ?? ''
            : filho is Tx
            ? (filho as Tx).valor
            : '');
    final conteudo = ajuste.texto != null || ajuste.oculto
        ? Text(
            ajuste.exibir(textoOriginal),
            textAlign: ajuste.alinhamento ?? TextAlign.center,
          )
        : filho ??
              (rotulo == null
                  ? null
                  : Text(
                      ajuste.exibir(rotulo!),
                      textAlign: ajuste.alinhamento ?? TextAlign.center,
                    ));
    final ic = icone == null ? null : Icon(icone, color: corIcone);
    Widget b;
    switch (tipo) {
      case TipoBotao.cheio:
        b = ic != null
            ? FilledButton.icon(
                style: st,
                autofocus: focoInicial,
                focusNode: foco,
                onPressed: aperta,
                onLongPress: longo,
                onHover: paira,
                clipBehavior: Clip.none,
                icon: ic,
                label: conteudo ?? const SizedBox.shrink(),
              )
            : FilledButton(
                style: st,
                autofocus: focoInicial,
                focusNode: foco,
                onPressed: aperta,
                onLongPress: longo,
                onHover: paira,
                clipBehavior: Clip.none,
                child: conteudo,
              );
      case TipoBotao.contorno:
        b = ic != null
            ? OutlinedButton.icon(
                autofocus: focoInicial,
                focusNode: foco,
                onPressed: aperta,
                onLongPress: longo,
                clipBehavior: Clip.none,
                style: st,
                icon: ic,
                label: conteudo ?? const SizedBox.shrink(),
              )
            : OutlinedButton(
                autofocus: focoInicial,
                focusNode: foco,
                onPressed: aperta,
                onLongPress: longo,
                clipBehavior: Clip.none,
                onHover: paira,
                style: st,
                child: conteudo,
              );
      case TipoBotao.texto:
        b = ic != null
            ? TextButton.icon(
                autofocus: focoInicial,
                focusNode: foco,
                onPressed: aperta,
                onLongPress: longo,
                onHover: paira,
                style: st,
                clipBehavior: Clip.none,
                icon: ic,
                label: conteudo ?? const SizedBox.shrink(),
              )
            : TextButton(
                autofocus: focoInicial,
                focusNode: foco,
                style: st,
                onPressed: aperta,
                onLongPress: longo,
                onHover: paira,
                clipBehavior: Clip.none,
                child: conteudo ?? const Text(''),
              );
    }
    return alvoLayout(
      context,
      comTamanho(
        comDica(dica, b),
        largura: ajuste.largura ?? largura,
        altura: ajuste.altura ?? altura,
      ),
      id: idLayout,
      nome: rotulo ?? dica ?? 'Botão',
      tipo: 'botao',
      propriedades: propriedadesTexto(
        context,
        ajuste.exibir(textoOriginal),
        alinhamento: ajuste.alinhamento ?? TextAlign.center,
        cor:
            st.foregroundColor?.resolve({}) ??
            estiloTema?.foregroundColor?.resolve({}) ??
            (tipo == TipoBotao.cheio
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.primary),
        estilo: st.textStyle?.resolve({}) ?? estiloTema?.textStyle?.resolve({}),
      ),
    );
  }
}

class BotaoIcone extends StatelessWidget {
  const BotaoIcone(
    this.icone, {
    super.key,
    this.idLayout,
    this.aoClicar,
    this.dica,
    this.cor,
    this.tamanho,
    this.desabilitado = false,
    this.padding,
    this.largura,
    this.altura,
    this.filho,
    this.estilo,
    this.restricoes,
    this.cursorTravado = false,
  });
  final IconData? icone;
  final VoidCallback? aoClicar;
  final String? dica;
  final Color? cor;
  final double? tamanho;
  final bool desabilitado;
  final EdgeInsetsGeometry? padding;
  final double? largura;
  final double? altura;
  final Widget? filho;
  final ButtonStyle? estilo;
  final BoxConstraints? restricoes;
  final bool cursorTravado;

  final String? idLayout;

  @override
  Widget build(BuildContext context) {
    final ajuste = ajusteLayout(context, idLayout);
    final ativo = !desabilitado && !travado(context);
    final b = IconButton(
      autofocus: false,
      enableFeedback: true,
      padding: padding,
      icon: filho ?? Icon(icone, color: cor),
      iconSize: ajuste.tamanhoFonte ?? tamanho,
      style: (estilo ?? const ButtonStyle()).copyWith(mouseCursor: cursorTrava),
      constraints: restricoes,
      onLongPress: ativo ? () {} : null,
      onHover: ativo ? (_) {} : null,
      onPressed: ativo ? (aoClicar ?? () {}) : null,
    );
    return alvoLayout(
      context,
      comTamanho(
        comDica(dica, b),
        largura: ajuste.largura ?? largura,
        altura: ajuste.altura ?? altura,
      ),
      id: idLayout,
      nome: dica ?? 'Botão de ícone',
      tipo: 'icone',
      propriedades: {'tamanhoFonte': ajuste.tamanhoFonte ?? tamanho ?? 24},
    );
  }
}

// --------------------------------------------------------------------------- //
// Caixa de marcar
// --------------------------------------------------------------------------- //
class Marcar extends StatelessWidget {
  const Marcar({
    super.key,
    this.idLayout,
    required this.valor,
    this.rotulo,
    this.filhoRotulo,
    this.aoMudar,
    this.desabilitado = false,
    this.dica,
    this.tresEstados = false,
    this.compacto = false,
    this.estiloRotulo,
    this.sobreposicao,
    this.raioRespingo,
    this.rente = false,
  });
  final bool? valor;
  final String? idLayout;
  final String? rotulo;

  /// Rótulo como controle (no lugar do texto).
  final Widget? filhoRotulo;
  final ValueChanged<bool?>? aoMudar;
  final bool desabilitado;
  final String? dica;
  final bool tresEstados;
  final bool compacto;
  final TextStyle? estiloRotulo;
  final Color? sobreposicao;
  final double? raioRespingo;

  /// Encosta a caixa na margem esquerda: desconta a folga que o Checkbox deixa em volta do
  /// quadradinho, para alinhar com os títulos e campos de cima.
  final bool rente;

  /// Folga, de cada lado, entre a área de toque do Checkbox e o quadradinho desenhado.
  static double folga(BuildContext context) {
    final tema = Theme.of(context);
    final alvo =
        (tema.checkboxTheme.materialTapTargetSize ??
                tema.materialTapTargetSize) ==
            MaterialTapTargetSize.padded
        ? kMinInteractiveDimension
        : kMinInteractiveDimension - 8;
    final densidade = tema.checkboxTheme.visualDensity ?? tema.visualDensity;
    final lado = alvo + densidade.baseSizeAdjustment.dx;
    return ((lado - Checkbox.width) / 2).clamp(0, double.infinity).toDouble();
  }

  void _alternar() {
    if (!tresEstados) {
      aoMudar?.call(!(valor ?? false));
    } else if (valor == null) {
      aoMudar?.call(false);
    } else if (valor == false) {
      aoMudar?.call(true);
    } else {
      aoMudar?.call(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id =
        idLayout ??
        context.dependOnInheritedWidgetOfExactType<ItemLayoutScope>()?.chave;
    final ajuste = ajusteLayout(context, id);
    final ativo = !desabilitado && !travado(context);
    final caixa = Checkbox(
      mouseCursor: ativo ? SystemMouseCursors.click : SystemMouseCursors.basic,
      side: const WidgetStateBorderSide.fromMap({
        WidgetState.any: BorderSide(color: PadraoControles.borda),
      }),
      shape: FormaControle(densidade: MediaQuery.devicePixelRatioOf(context)),
      autofocus: false,
      value: tresEstados ? valor : (valor ?? false),
      isError: false,
      splashRadius: raioRespingo,
      overlayColor: sobreposicao == null
          ? null
          : WidgetStatePropertyAll(sobreposicao),
      tristate: tresEstados,
      onChanged: ativo ? (v) => aoMudar?.call(v) : null,
    );
    Widget w = caixa;
    if (rotulo != null || filhoRotulo != null) {
      final Widget r =
          filhoRotulo ??
          Text(
            ajuste.exibir(rotulo!),
            style: PadraoControles.rotulo,
            textAlign: ajuste.alinhamento,
          );
      w = MergeSemantics(
        child: MouseRegion(
          cursor: ativo ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: ativo ? _alternar : null,
            child: Row(
              mainAxisSize: compacto ? MainAxisSize.min : MainAxisSize.max,
              children: [caixa, r],
            ),
          ),
        ),
      );
    }
    if (rente) {
      w = Transform.translate(offset: Offset(-folga(context), 0), child: w);
    }
    return alvoLayout(
      context,
      comTamanho(
        comDica(dica, w),
        largura: ajuste.largura,
        altura: ajuste.altura,
      ),
      id: id,
      nome: rotulo ?? 'Checkbox',
      tipo: 'checkbox',
      propriedades: propriedadesTexto(
        context,
        ajuste.exibir(rotulo ?? ''),
        estilo: PadraoControles.rotulo,
        alinhamento: ajuste.alinhamento ?? TextAlign.start,
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// Divisórias, cartão, ícone
// --------------------------------------------------------------------------- //
Widget divisor({double? altura, double? espessura, Color? cor}) =>
    LinhaControle(espaco: altura ?? 16, cor: cor ?? PadraoControles.separador);

Widget divisorVertical({double? largura, double? espessura, Color? cor}) =>
    LinhaControle(
      vertical: true,
      espaco: largura ?? 16,
      cor: cor ?? PadraoControles.separador,
    );

Widget cartao(
  Widget conteudo, {
  double? elevacao,
  Color? cor,
  EdgeInsetsGeometry? margem,
  Clip? recorte,
}) => Card(
  elevation: elevacao,
  margin: margem,
  semanticContainer: true,
  borderOnForeground: true,
  color: cor,
  clipBehavior: recorte,
  child: conteudo,
);

/// Ícone que GIRA enquanto um trabalho corre. Parado, custa zero; ao parar, segue até a
/// próxima posição de repouso (meia volta para ícones simétricos, uma volta para os demais).
class Giro extends ChangeNotifier {
  Giro({this.meiaVolta = false});
  final bool meiaVolta;

  static const _voltaS = 1.1;
  static const _folgaS = 0.08;

  bool girando = false;
  double angulo = 0;
  Duration duracao = Duration.zero;
  DateTime _fim = DateTime.now();
  int _serie = 0;
  bool _descartado = false;

  double get _passo => meiaVolta ? math.pi : 2 * math.pi;

  double _falta() {
    final f = _fim.difference(DateTime.now()).inMicroseconds / 1e6;
    return f < 0 ? 0 : f;
  }

  void _mandar(double duracaoS) {
    _fim = DateTime.now().add(Duration(microseconds: (duracaoS * 1e6).round()));
    final ms = (duracaoS * 1000).round();
    duracao = Duration(milliseconds: ms < 1 ? 1 : ms);
    if (!_descartado) notifyListeners();
  }

  void _maisUmaVolta() {
    final falta = _falta();
    angulo += 2 * math.pi;
    _mandar(_voltaS + falta);
  }

  Future<void> _manter(int serie) async {
    while (true) {
      final espera = _falta() - _folgaS;
      await Future<void>.delayed(
        Duration(microseconds: ((espera < 0.05 ? 0.05 : espera) * 1e6).round()),
      );
      if (serie != _serie || _descartado) return;
      _maisUmaVolta();
    }
  }

  void girar() {
    if (girando) return;
    girando = true;
    _serie++;
    _maisUmaVolta();
    unawaited(_manter(_serie));
  }

  void parar() {
    if (!girando) return;
    girando = false;
    _serie++;
    const w = 2 * math.pi / _voltaS;
    final onde = angulo - w * _falta();
    angulo = ((onde / _passo + 1e-6).floor() + 1) * _passo;
    _mandar((angulo - onde) / w);
  }

  @override
  void dispose() {
    _descartado = true;
    _serie++;
    super.dispose();
  }
}

class IconeGiratorio extends StatelessWidget {
  const IconeGiratorio(
    this.giro,
    this.icone, {
    super.key,
    this.tamanho,
    this.cor,
  });
  final Giro giro;
  final IconData icone;
  final double? tamanho;
  final Color? cor;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ListenableBuilder(
      listenable: giro,
      builder: (context, filho) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: giro.angulo),
        duration: giro.duracao,
        curve: Curves.linear,
        builder: (context, valor, filho) => Transform.rotate(
          angle: valor,
          alignment: Alignment.center,
          child: filho,
        ),
        child: filho,
      ),
      child: Icon(icone, size: tamanho, color: cor),
    ),
  );
}

// --------------------------------------------------------------------------- //
// Lista suspensa
// --------------------------------------------------------------------------- //
class Opcao {
  const Opcao(
    this.chave,
    this.texto, {
    this.legado = false,
    this.desabilitada = false,
    this.naLista,
  });
  final String chave;

  /// O que o campo mostra com esta opção escolhida.
  final String texto;

  /// Valor guardado que já não faz parte da lista atual.
  final bool legado;
  final bool desabilitada;

  /// O que a lista aberta mostra, quando difere do texto do campo.
  final String? naLista;

  @override
  bool operator ==(Object other) =>
      other is Opcao &&
      other.chave == chave &&
      other.texto == texto &&
      other.legado == legado &&
      other.desabilitada == desabilitada &&
      other.naLista == naLista;

  @override
  int get hashCode => Object.hash(chave, texto, legado, desabilitada, naLista);
}

List<Opcao> opcoesDe(Iterable<(String, String)> pares) => [
  for (final (c, t) in pares) Opcao(c, t),
];

/// Estado de uma lista suspensa que a tela muda por conta própria (valor, texto digitado,
/// opções): a lista se redesenha a cada [avisar].
class Suspensa extends ChangeNotifier {
  Suspensa({String? valor, List<Opcao> opcoes = const [], String? texto})
    : _valor = (valor == null || valor.isEmpty) ? null : valor,
      _opcoes = opcoes,
      texto = texto;

  String? _valor;
  List<Opcao> _opcoes;

  /// Texto mostrado no campo; nulo = o da opção escolhida.
  String? texto;
  String? dica;

  /// Valor de quando o campo ganhou o foco (para devolver se nada for escolhido).
  String? anterior;
  bool temAnterior = false;
  int ciclo = 0;
  final FocusNode foco = FocusNode();

  String? get valor => _valor;
  List<Opcao> get opcoes => _opcoes;

  set opcoes(List<Opcao> o) {
    _opcoes = o;
  }

  String textoDe(String? chave) {
    for (final o in _opcoes) {
      if (o.chave == chave) return o.texto;
    }
    return '';
  }

  /// Troca o valor e o texto mostrado (como quem escolhe um item).
  void por(String? valor) {
    _valor = (valor == null || valor.isEmpty) ? null : valor;
    anterior = _valor;
    temAnterior = true;
    texto = textoDe(_valor);
  }

  /// Só o valor, sem mexer no texto digitado.
  void porValorCru(String? valor) {
    _valor = (valor == null || valor.isEmpty) ? null : valor;
  }

  void avisar() => notifyListeners();

  @override
  void dispose() {
    foco.dispose();
    super.dispose();
  }
}

class ListaSuspensa extends StatefulWidget {
  const ListaSuspensa({
    super.key,
    this.idLayout,
    required this.estado,
    this.rotulo,
    required this.largura,
    this.editavel = false,
    this.emTabela = false,
    this.altura,
    this.filtrar = false,
    this.buscar = true,
    this.desabilitado = false,
    this.alturaMenu = 200,
    this.larguraMenu,
    this.tamanhoTexto,
    this.estiloRotulo,
    this.denso = false,
    this.substituirAoFocar = false,
    this.aoSelecionar,
    this.aoTexto,
    this.aoFocar,
    this.aoDesfocar,
    this.dicaCampo,
    this.padding,
    this.rotuloSemResultados,
    this.aoSemResultados,
  });

  final String? rotuloSemResultados;
  final VoidCallback? aoSemResultados;
  final Suspensa estado;
  final String? rotulo;
  final double largura;
  final bool editavel;
  final bool emTabela;
  final double? altura;
  final bool filtrar;
  final bool buscar;
  final bool desabilitado;
  final double? alturaMenu;
  final double? larguraMenu;
  final double? tamanhoTexto;
  final TextStyle? estiloRotulo;
  final bool denso;

  /// Ao ganhar o foco o campo esvazia (para digitar a busca); saindo sem escolher, volta o
  /// valor anterior.
  final bool substituirAoFocar;
  final ValueChanged<String?>? aoSelecionar;
  final ValueChanged<String>? aoTexto;
  final VoidCallback? aoFocar;
  final VoidCallback? aoDesfocar;
  final String? dicaCampo;
  final EdgeInsetsGeometry? padding;

  final String? idLayout;

  @override
  State<ListaSuspensa> createState() => _ListaSuspensaState();
}

class _ListaSuspensaState extends State<ListaSuspensa> {
  late final TextEditingController _texto;
  String? _valor;
  bool _calado = false;

  // Os itens do menu, refeitos só quando as opções (ou a trava) mudam.
  List<Opcao>? _itensDe;
  bool _itensInertes = false;
  List<ItemSuspenso> _itens = const [];
  int _chaveDosItens = 0;

  Suspensa get e => widget.estado;

  @override
  void initState() {
    super.initState();
    _valor = e.valor;
    _texto = TextEditingController(text: e.texto ?? _valor ?? '');
    _texto.addListener(_textoMudou);
    e.foco.addListener(_focoMudou);
    e.addListener(_estadoMudou);
  }

  @override
  void didUpdateWidget(covariant ListaSuspensa antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.estado != widget.estado) {
      antigo.estado.foco.removeListener(_focoMudou);
      antigo.estado.removeListener(_estadoMudou);
      e.foco.addListener(_focoMudou);
      e.addListener(_estadoMudou);
    }
  }

  @override
  void dispose() {
    e.foco.removeListener(_focoMudou);
    e.removeListener(_estadoMudou);
    _texto.dispose();
    super.dispose();
  }

  void _estadoMudou() {
    if (mounted) setState(() {});
  }

  void _textoMudou() {
    if (_calado) return;
    if (_texto.text != e.texto) {
      e.texto = _texto.text;
      widget.aoTexto?.call(_texto.text);
    }
  }

  void _porTexto(String t) {
    _calado = true;
    _texto.value = TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: t.length),
    );
    _calado = false;
    e.texto = t;
  }

  void _focoMudou() {
    if (e.foco.hasFocus) {
      if (widget.substituirAoFocar) {
        e.ciclo++;
        if (e.valor != null || !e.temAnterior) {
          e.anterior = e.valor;
          e.temAnterior = true;
        }
        if (e.valor != null) {
          e.porValorCru(null);
          e.texto = '';
          e.avisar();
        }
      }
      widget.aoFocar?.call();
    } else {
      if (widget.substituirAoFocar) {
        final anterior = e.anterior;
        final ciclo = e.ciclo;
        // Uma escolha no menu pode chegar depois da perda do foco; um foco novo cancela.
        Timer(const Duration(milliseconds: 350), () {
          if (!mounted || e.ciclo != ciclo) return;
          var escolhido = e.valor ?? anterior;
          final rotulo = e.textoDe(escolhido);
          if (escolhido != null && rotulo.isEmpty) escolhido = null;
          if (e.valor != escolhido || (e.texto ?? '') != rotulo) {
            e.por(escolhido);
            e.avisar();
          }
        });
      }
      widget.aoDesfocar?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final ajuste = ajusteLayout(context, widget.idLayout);
    final InputBorder contorno = widget.emTabela
        ? InputBorder.none
        : ContornoCampo(densidade: MediaQuery.devicePixelRatioOf(context));
    final inerte = widget.desabilitado || travado(context);
    if (!identical(_itensDe, e.opcoes) || _itensInertes != inerte) {
      _itensDe = e.opcoes;
      _itensInertes = inerte;
      _itens = [
        for (final o in e.opcoes)
          ItemSuspenso(
            enabled: !(inerte || o.desabilitada),
            value: o.chave,
            label: o.texto,
            naLista: o.naLista,
          ),
      ];
      // Opções diferentes (valor ou texto) = lista suspensa nova, com o menu fechado.
      _chaveDosItens = Object.hashAll(
        _itens.map((o) => Object.hash(o.value, o.label)),
      );
    }
    final opcoes = _itens;
    String? valor = e.valor;
    ItemSuspenso? escolhida;
    for (final o in opcoes) {
      if (o.value == valor) {
        escolhida = o;
        break;
      }
    }
    valor = escolhida?.value;

    if (_valor != valor) {
      if (valor == null) {
        if (_valor != null && _texto.text.isNotEmpty) _porTexto('');
      } else {
        final rotulo = escolhida?.label ?? e.texto ?? valor;
        if (_texto.text != rotulo) _porTexto(rotulo);
      }
      _valor = valor;
    }

    // O texto também pode ser limpo sem mudar a seleção (ela já era nula
    // quando o usuário digitou algo que não existe na lista).
    final textoExterno = e.texto;
    if (textoExterno != null && _texto.text != textoExterno) {
      _porTexto(textoExterno);
    }

    TextStyle? estiloTexto;
    if (widget.tamanhoTexto != null) {
      estiloTexto = (tema.dropdownMenuTheme.textStyle ?? const TextStyle())
          .copyWith(
            fontSize: widget.tamanhoTexto,
            color: tema.colorScheme.onSurface,
          );
    }
    estiloTexto = ajuste.estilo(estiloTexto ?? const TextStyle());
    e.foco.canRequestFocus = widget.editavel;

    final menu = MenuSuspenso(
      emptyActionLabel: widget.rotuloSemResultados,
      onEmptyAction: widget.aoSemResultados,
      key: ValueKey<int>(_chaveDosItens),
      enabled: !inerte,
      focusNode: e.foco,
      controller: _texto,
      initialSelection: valor,
      enableFilter: widget.filtrar,
      enableSearch: widget.buscar,
      menuHeight: widget.alturaMenu,
      label: widget.emTabela || ajuste.oculto || widget.rotulo == null
          ? null
          : Tooltip(
              message: ajuste.exibir(widget.rotulo!),
              child: Text(
                ajuste.exibir(widget.rotulo!),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
      textStyle: estiloTexto,
      textAlign: ajuste.alinhamento ?? TextAlign.start,
      width: ajuste.largura ?? widget.largura,
      hintText: widget.dicaCampo,
      menuWidth: widget.larguraMenu,
      // (a lista não herda a decoração do tema: altura e rótulo na borda são repassados aqui)
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        border: contorno,
        enabledBorder: contorno,
        focusedBorder: contorno,
        disabledBorder: contorno,
        errorBorder: contorno,
        focusedErrorBorder: contorno,
        labelStyle: PadraoControles.rotulo,
        isDense: widget.denso || tema.inputDecorationTheme.isDense,
        contentPadding:
            widget.padding ??
            (widget.emTabela
                ? const EdgeInsets.symmetric(horizontal: 6, vertical: 8)
                : tema.inputDecorationTheme.contentPadding),
        floatingLabelStyle: PadraoControles.rotuloFlutuante,
      ).data,
      onSelected: inerte
          ? null
          : (String? escolha) {
              _valor = escolha;
              e.porValorCru(escolha);
              widget.aoSelecionar?.call(escolha);
            },
      entries: opcoes,
    );
    // O botão da setinha ocupa a altura do campo menos a folga de 4 em volta: sem isto ele (40,
    // mais a folga) é que mandaria na altura da lista.
    final setinha = IconButtonTheme(
      data: IconButtonThemeData(
        style: (IconButtonTheme.of(context).style ?? const ButtonStyle()).merge(
          _setinhaDaLista,
        ),
      ),
      child: menu,
    );
    return alvoLayout(
      context,
      comTamanho(
        comDica(e.dica, setinha),
        largura: ajuste.largura ?? widget.largura,
        altura: Medida.campo,
      ),
      id: widget.idLayout,
      nome: widget.rotulo ?? 'Lista',
      tipo: 'campo',
      propriedades: {
        ...propriedadesTexto(
          context,
          ajuste.exibir(widget.rotulo ?? ''),
          estilo: tema.textTheme.bodyLarge?.merge(estiloTexto),
          alinhamento: ajuste.alinhamento ?? TextAlign.start,
        ),
        'alturaUniforme': true,
      },
    );
  }
}

const _setinhaDaLista = ButtonStyle(
  fixedSize: WidgetStatePropertyAll<Size?>(Size.square(Medida.campo - 8)),
  minimumSize: WidgetStatePropertyAll<Size?>(Size.zero),
  padding: WidgetStatePropertyAll<EdgeInsetsGeometry?>(EdgeInsets.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
);

// --------------------------------------------------------------------------- //
// Abas
// --------------------------------------------------------------------------- //
/// Barra de abas (rolável, alinhada à esquerda) com os painéis embaixo, ocupando o resto.
class Abas extends StatefulWidget {
  const Abas({
    super.key,
    required this.rotulos,
    required this.paineis,
    this.inicial = 0,
    this.aoMudar,
    this.aoCriar,
    this.secundaria = false,
    this.desabilitadas = const {},
  });

  /// (rótulo, ícone opcional) de cada aba.
  final List<(String, IconData?)> rotulos;
  final List<Widget> paineis;
  final int inicial;
  final ValueChanged<int>? aoMudar;

  /// Barra de sub-abas (as de dentro de uma aba).
  final bool secundaria;

  /// Abas que não se deixam escolher: o clique volta para a que estava.
  final Set<int> desabilitadas;

  /// Entrega o controlador (para quem precisa trocar de aba por conta própria).
  final ValueChanged<TabController>? aoCriar;

  @override
  State<Abas> createState() => _AbasState();
}

class _AbasState extends State<Abas> with TickerProviderStateMixin {
  late final TabController _c = TabController(
    length: widget.rotulos.length,
    initialIndex: widget.inicial.clamp(0, widget.rotulos.length - 1),
    vsync: this,
    animationDuration: const Duration(milliseconds: 100),
  );

  @override
  void initState() {
    super.initState();
    _c.addListener(_mudou);
    widget.aoCriar?.call(_c);
  }

  void _mudou() {
    if (!_c.indexIsChanging) widget.aoMudar?.call(_c.index);
  }

  @override
  void dispose() {
    _c.removeListener(_mudou);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inerte = travado(context);
    // Aba desabilitada: apagada (ícone e rótulo) e sem mãozinha — além de não abrir.
    final apagado = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.38);
    final abas = [
      for (final (i, (rotulo, icone)) in widget.rotulos.indexed)
        if (widget.desabilitadas.contains(i))
          Tab(
            icon: icone == null ? null : Icon(icone, color: apagado),
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: Text(rotulo, style: TextStyle(color: apagado)),
            ),
          )
        else
          Tab(icon: icone == null ? null : Icon(icone), child: Text(rotulo)),
    ];
    void aoTocar(int i) {
      if (!widget.desabilitadas.contains(i)) return;
      final volta = _c.previousIndex.clamp(0, _c.length - 1);
      if (volta != _c.index) _c.index = volta;
    }

    return col([
      IgnorePointer(
        ignoring: false,
        child: widget.secundaria
            ? TabBar.secondary(
                controller: _c,
                dividerHeight: 0,
                tabAlignment: TabAlignment.start,
                isScrollable: true,
                indicatorWeight: 2.0,
                indicatorPadding: EdgeInsets.zero,
                onTap: aoTocar,
                onHover: (_, _) {},
                tabs: abas,
              )
            : TabBar(
                controller: _c,
                dividerHeight: 0,
                tabAlignment: TabAlignment.start,
                isScrollable: true,
                indicatorWeight: 2.0,
                indicatorPadding: EdgeInsets.zero,
                onTap: aoTocar,
                onHover: (_, _) {},
                tabs: abas,
              ),
      ),
      divisor(altura: 1),
      Expanded(
        child: TabBarView(
          controller: _c,
          clipBehavior: Clip.hardEdge,
          viewportFraction: 1.0,
          physics: inerte ? const NeverScrollableScrollPhysics() : null,
          children: widget.paineis,
        ),
      ),
    ], espaco: 0);
  }
}

// --------------------------------------------------------------------------- //
// Texto de uma linha com dica quando cortado
// --------------------------------------------------------------------------- //
/// Texto de UMA linha que vira "…" quando não cabe em [largura]. Cortado, a dica do mouse
/// traz o valor inteiro; [propria] é o que a célula tem a dizer além do valor (cortada, a
/// dica traz os dois).
class TxCorte extends StatelessWidget {
  const TxCorte(
    this.valor, {
    super.key,
    required this.largura,
    this.tam,
    this.peso,
    this.cor,
    this.propria,
    this.alinhar = TextAlign.start,
    this.fonte,
    this.solto = false,
  });
  final String valor;

  /// Em [solto], a largura só serve para saber se o texto foi cortado (quem limita é a
  /// caixa em volta).
  final bool solto;
  final double largura;
  final double? tam;
  final FontWeight? peso;
  final Color? cor;
  final String? propria;
  final TextAlign alinhar;
  final String? fonte;

  @override
  Widget build(BuildContext context) {
    var cortado = false;
    if (valor.isNotEmpty) {
      final estilo = DefaultTextStyle.of(context).style
          .merge(TextStyle(fontSize: tam, fontWeight: peso, fontFamily: fonte));
      cortado =
          _LargurasMedidas.de(
            estilo,
            Directionality.of(context),
            MediaQuery.textScalerOf(context),
          ).largura(valor) >
          largura;
    }
    final p = propria;
    final String? dica = (p != null && p.isNotEmpty && cortado)
        ? '$valor\n$p'
        : ((p != null && p.isNotEmpty) ? p : (cortado ? valor : null));
    return Tx(
      valor,
      largura: solto ? null : largura,
      linhas: 1,
      corte: TextOverflow.ellipsis,
      tam: tam,
      peso: peso,
      cor: cor,
      alinhar: alinhar,
      fonte: fonte,
      dica: dica,
    );
  }
}

/// Largura (numa linha só) dos textos já medidos com um estilo: uma célula de tabela é
/// redesenhada muitas vezes com o mesmo texto, e medir de novo a cada vez dobrava o custo
/// de cada célula.
class _LargurasMedidas {
  _LargurasMedidas._(this.estilo, this.direcao, this.escala);
  final TextStyle estilo;
  final TextDirection direcao;
  final TextScaler escala;
  final Map<String, double> _larguras = {};

  static final List<_LargurasMedidas> _todas = [];

  static _LargurasMedidas de(
    TextStyle estilo,
    TextDirection direcao,
    TextScaler escala,
  ) {
    for (var i = _todas.length - 1; i >= 0; i--) {
      final m = _todas[i];
      if (m.direcao == direcao &&
          m.escala == escala &&
          (identical(m.estilo, estilo) || m.estilo == estilo)) {
        return m;
      }
    }
    if (_todas.length >= 12) _todas.removeAt(0);
    final nova = _LargurasMedidas._(estilo, direcao, escala);
    _todas.add(nova);
    return nova;
  }

  double largura(String valor) {
    final ja = _larguras[valor];
    if (ja != null) return ja;
    final medidor = TextPainter(
      text: TextSpan(text: valor, style: estilo),
      maxLines: 1,
      textDirection: direcao,
      textScaler: escala,
    )..layout();
    final l = medidor.width;
    medidor.dispose();
    if (_larguras.length >= 4000) _larguras.clear();
    return _larguras[valor] = l;
  }
}

// --------------------------------------------------------------------------- //
// Margem negativa à esquerda
// --------------------------------------------------------------------------- //
/// Puxa o conteúdo [recuo] pontos para a esquerda (e encolhe a própria largura na mesma
/// medida), como uma margem esquerda negativa.
class PuxarEsquerda extends SingleChildRenderObjectWidget {
  const PuxarEsquerda({super.key, required this.recuo, super.child});
  final double recuo;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPuxar(recuo);

  @override
  void updateRenderObject(BuildContext context, _RenderPuxar r) {
    r.recuo = recuo;
  }
}

class _RenderPuxar extends RenderShiftedBox {
  _RenderPuxar(this._recuo) : super(null);
  double _recuo;
  set recuo(double v) {
    if (v == _recuo) return;
    _recuo = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    final largo = constraints.hasBoundedWidth
        ? constraints.copyWith(
            maxWidth: constraints.maxWidth + _recuo,
            minWidth:
                constraints.minWidth + _recuo > constraints.maxWidth + _recuo
                ? constraints.maxWidth + _recuo
                : constraints.minWidth,
          )
        : constraints;
    c.layout(largo, parentUsesSize: true);
    (c.parentData! as BoxParentData).offset = Offset(-_recuo, 0);
    final w = c.size.width - _recuo;
    size = constraints.constrain(Size(w < 0 ? 0 : w, c.size.height));
  }
}
