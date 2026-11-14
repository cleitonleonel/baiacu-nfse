/// Peças pequenas usadas em todas as telas.
library;

import 'package:flutter/material.dart';
import '../editor_layout.dart';
export '../editor_layout.dart' show ElementoLayoutGenerico;

/// Texto simples. Tudo o que não é dito fica por conta do tema.
Widget texto(
  String valor, {
  double? tamanho,
  FontWeight? peso,
  Color? cor,
  bool italico = false,
  TextAlign alinhamento = TextAlign.start,
  int? maxLinhas,
  TextOverflow? corte,
  bool semQuebra = false,
  String? fonte,
  String? idLayout,
}) {
  return TextoLayoutWidget(
    idLayout: idLayout,
    child: Builder(
      builder: (context) {
        final ajuste = ajusteLayout(context, idLayout);
        final child = Text(
          ajuste.exibir(valor),
          maxLines: maxLinhas,
          softWrap: !semQuebra,
          textAlign: ajuste.alinhamento ?? alinhamento,
          style: ajuste.estilo(
            TextStyle(
              overflow: corte,
              fontSize: tamanho,
              fontWeight: peso,
              fontStyle: italico ? FontStyle.italic : null,
              fontFamily: fonte,
              fontVariations: const [],
              color: cor,
            ),
          ),
        );
        return alvoLayout(
          context,
          SizedBox(width: ajuste.largura, height: ajuste.altura, child: child),
          id: idLayout,
          nome: valor,
          propriedades: propriedadesTexto(
            context,
            ajuste.exibir(valor),
            estilo: child.style,
            alinhamento: ajuste.alinhamento ?? alinhamento,
          ),
        );
      },
    ),
  );
}

/// Botão principal das telas de acesso: cresce de leve enquanto o mouse está em cima.
class BotaoInflavel extends StatefulWidget {
  const BotaoInflavel({
    super.key,
    this.idLayout,
    required this.rotulo,
    required this.icone,
    required this.aoApertar,
    this.largura,
    this.altura,
  });

  final String rotulo;
  final IconData icone;
  final VoidCallback? aoApertar;
  final double? largura;
  final double? altura;

  final String? idLayout;

  @override
  State<BotaoInflavel> createState() => _BotaoInflavelState();
}

class _BotaoInflavelState extends State<BotaoInflavel> {
  bool _dentro = false;

  @override
  Widget build(BuildContext context) {
    final ajuste = ajusteLayout(context, widget.idLayout);
    Widget botao = FilledButton.icon(
      style: ButtonStyle(
        alignment: ajuste.alinhamentoBotao,
        foregroundColor: ajuste.cor == null
            ? null
            : WidgetStatePropertyAll(ajuste.cor),
      ),
      onPressed: widget.aoApertar,
      onLongPress: widget.aoApertar == null ? null : () {},
      onHover: widget.aoApertar == null
          ? null
          : (dentro) => setState(() => _dentro = dentro),
      clipBehavior: Clip.none,
      icon: Icon(widget.icone),
      label: Text(
        ajuste.exibir(widget.rotulo),
        textAlign: ajuste.alinhamento ?? TextAlign.center,
        style: ajuste.estilo(const TextStyle()),
      ),
    );
    if (ajuste.largura != null ||
        ajuste.altura != null ||
        widget.largura != null ||
        widget.altura != null) {
      botao = SizedBox(
        width: ajuste.largura ?? widget.largura,
        height: ajuste.altura ?? widget.altura,
        child: alvoLayout(
          context,
          botao,
          id: widget.idLayout,
          nome: widget.rotulo,
          tipo: 'botao',
          propriedades: propriedadesTexto(
            context,
            ajuste.exibir(widget.rotulo),
            alinhamento: ajuste.alinhamento ?? TextAlign.center,
            estilo: ajuste.estilo(
              FilledButtonTheme.of(context).style?.textStyle?.resolve({}) ??
                  const TextStyle(),
            ),
          ),
        ),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _dentro ? 1.05 : 1.0),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      builder: (context, valor, filho) => Transform.scale(
        scale: valor,
        alignment: Alignment.center,
        child: filho,
      ),
      child: alvoLayout(
        context,
        botao,
        id: widget.idLayout,
        nome: widget.rotulo,
        tipo: 'botao',
        propriedades: propriedadesTexto(
          context,
          ajuste.exibir(widget.rotulo),
          alinhamento: ajuste.alinhamento ?? TextAlign.center,
          estilo: ajuste.estilo(
            FilledButtonTheme.of(context).style?.textStyle?.resolve({}) ??
                const TextStyle(),
          ),
        ),
      ),
    );
  }
}
