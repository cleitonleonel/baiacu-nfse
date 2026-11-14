import 'package:flutter/material.dart';

/// Roda do mouse avança uma linha; o arraste da barra termina no limite da linha.
class RolagemPorLinhas extends StatefulWidget {
  const RolagemPorLinhas({
    super.key,
    required this.alturaLinha,
    required this.child,
  });
  final double alturaLinha;
  final Widget child;
  @override
  State<RolagemPorLinhas> createState() => _RolagemPorLinhasState();
}

class _RolagemPorLinhasState extends State<RolagemPorLinhas> {
  late final _controle = _ControleLinhas(widget.alturaLinha);
  @override
  void dispose() {
    _controle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, limites) {
      final inteira =
          (limites.maxHeight / widget.alturaLinha).floor() * widget.alturaLinha;
      return Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: limites.maxWidth,
          height: inteira > 0 ? inteira : limites.maxHeight,
          child: SingleChildScrollView(
            controller: _controle,
            physics: _FisicaLinhas(widget.alturaLinha),
            child: widget.child,
          ),
        ),
      );
    },
  );
}

class _ControleLinhas extends ScrollController {
  _ControleLinhas(this.linha);
  final double linha;
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _PosicaoLinhas(
    linha,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
  );
}

class _PosicaoLinhas extends ScrollPositionWithSingleContext {
  _PosicaoLinhas(
    this.linha, {
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
  });
  final double linha;
  @override
  void pointerScroll(double delta) {
    if (delta == 0) return;
    final destino = ((pixels / linha).round() + (delta > 0 ? 1 : -1)) * linha;
    super.pointerScroll(
      destino.clamp(minScrollExtent, maxScrollExtent) - pixels,
    );
  }
}

class _FisicaLinhas extends ClampingScrollPhysics {
  const _FisicaLinhas(this.linha, {super.parent});
  final double linha;
  @override
  _FisicaLinhas applyTo(ScrollPhysics? ancestor) =>
      _FisicaLinhas(linha, parent: buildParent(ancestor));
  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) => ((newPosition.pixels / linha).round() * linha)
      .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
      .toDouble();
  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (velocity.abs() > toleranceFor(position).velocity)
      return super.createBallisticSimulation(position, velocity);
    final destino = ((position.pixels / linha).round() * linha)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((destino - position.pixels).abs() < 0.01) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      destino,
      velocity,
      tolerance: toleranceFor(position),
    );
  }
}
