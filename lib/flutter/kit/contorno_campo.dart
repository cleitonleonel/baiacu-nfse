import 'dart:math' as math;
import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';

import '../estilo.dart' show Letra;

/// Estilo comum a campos, listas, caixas de marcar e separadores.
abstract final class PadraoControles {
  static const borda = Color(0xFF8D8995);
  static const separador = Color(0xFFD0CCD6);
  static const rotulo = TextStyle(
    fontSize: Letra.rotulo,
    height: 1.25,
    fontWeight: FontWeight.normal,
    letterSpacing: 0.15,
    color: Color(0xFF625E6A),
  );
  // O InputDecorator reduz o rotulo flutuante a 75%.
  static final rotuloFlutuante = rotulo.copyWith(fontSize: Letra.rotulo / 0.75);
  static InputDecorationThemeData decoracao(
    InputDecorationThemeData base, {
    double densidade = 1,
  }) {
    final contorno = ContornoCampo(densidade: densidade);
    return base.copyWith(
      border: contorno,
      enabledBorder: contorno,
      disabledBorder: contorno,
      focusedBorder: contorno,
      errorBorder: contorno,
      focusedErrorBorder: contorno,
      labelStyle: rotulo,
      floatingLabelStyle: rotuloFlutuante,
    );
  }
}

/// Hairline = um pixel fisico, independente da escala e da posicao na janela.
/// Antialias nas retas distribuia o traco por dois pixels, aparentando espessuras diferentes.
void pintarLinhaFina(Canvas canvas, Offset inicio, Offset fim, Color cor) {
  if (inicio == fim) return;
  canvas.drawLine(
    inicio,
    fim,
    Paint()
      ..color = cor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0
      ..isAntiAlias = false,
  );
}

void pintarContornoFino(
  Canvas canvas,
  Rect rect,
  BorderRadius raio,
  Color cor, {
  double densidade = 1,
  double? aberturaInicio,
  double aberturaFim = 0,
}) {
  final centro = raio.toRRect(rect.deflate(0.5 / densidade)).scaleRadii();
  // Os cantos sao suaves; somente as retas recebem pintura sem antialias.
  final cantos = Path();
  void canto(double x, double y, Radius r) {
    if (r.x > 0 && r.y > 0)
      cantos.addRect(
        Rect.fromLTWH(x, y, r.x + 1 / densidade, r.y + 1 / densidade),
      );
  }

  canto(rect.left, rect.top, centro.tlRadius);
  canto(centro.right - centro.trRadiusX, rect.top, centro.trRadius);
  canto(
    centro.right - centro.brRadiusX,
    centro.bottom - centro.brRadiusY,
    centro.brRadius,
  );
  canto(rect.left, centro.bottom - centro.blRadiusY, centro.blRadius);
  canvas.save();
  canvas.clipPath(cantos);
  if (aberturaInicio != null) {
    canvas.clipRect(
      Rect.fromLTRB(
        aberturaInicio,
        rect.top - 1,
        aberturaFim,
        rect.top + math.max(centro.tlRadiusY, centro.trRadiusY) + 1,
      ),
      clipOp: ClipOp.difference,
    );
  }
  canvas.drawRRect(
    centro,
    Paint()
      ..color = cor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0,
  );
  canvas.restore();
  final esquerda = centro.left + centro.tlRadiusX;
  final direita = centro.right - centro.trRadiusX;
  if (aberturaInicio == null) {
    pintarLinhaFina(
      canvas,
      Offset(esquerda, centro.top),
      Offset(direita, centro.top),
      cor,
    );
  } else {
    if (aberturaInicio > esquerda)
      pintarLinhaFina(
        canvas,
        Offset(esquerda, centro.top),
        Offset(math.min(direita, aberturaInicio), centro.top),
        cor,
      );
    if (aberturaFim < direita)
      pintarLinhaFina(
        canvas,
        Offset(math.max(esquerda, aberturaFim), centro.top),
        Offset(direita, centro.top),
        cor,
      );
  }
  pintarLinhaFina(
    canvas,
    Offset(centro.right, centro.top + centro.trRadiusY),
    Offset(centro.right, centro.bottom - centro.brRadiusY),
    cor,
  );
  pintarLinhaFina(
    canvas,
    Offset(centro.left + centro.blRadiusX, centro.bottom),
    Offset(centro.right - centro.brRadiusX, centro.bottom),
    cor,
  );
  pintarLinhaFina(
    canvas,
    Offset(centro.left, centro.top + centro.tlRadiusY),
    Offset(centro.left, centro.bottom - centro.blRadiusY),
    cor,
  );
}

class ContornoCampo extends OutlineInputBorder {
  const ContornoCampo({
    this.densidade = 1,
    super.borderSide = const BorderSide(color: PadraoControles.borda),
    super.borderRadius = const BorderRadius.all(Radius.circular(4)),
    super.gapPadding = 4,
  });
  final double densidade;
  @override
  ContornoCampo copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) => ContornoCampo(
    densidade: densidade,
    borderSide: borderSide ?? this.borderSide,
    borderRadius: borderRadius ?? this.borderRadius,
    gapPadding: gapPadding ?? this.gapPadding,
  );
  @override
  ContornoCampo scale(double t) => copyWith(borderSide: borderSide.scale(t));
  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is OutlineInputBorder
      ? copyWith(
          borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
          borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t),
          gapPadding: a.gapPadding + (gapPadding - a.gapPadding) * t,
        )
      : super.lerpFrom(a, t);
  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is OutlineInputBorder
      ? copyWith(
          borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
          borderRadius: BorderRadius.lerp(borderRadius, b.borderRadius, t),
          gapPadding: gapPadding + (b.gapPadding - gapPadding) * t,
        )
      : super.lerpTo(b, t);
  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0,
    double gapPercentage = 0,
    TextDirection? textDirection,
  }) {
    if (borderSide.style == BorderStyle.none) return;
    final extent = (gapExtent + gapPadding * 2) * gapPercentage;
    final temAbertura = gapStart != null && gapExtent > 0 && gapPercentage > 0;
    final inicio = !temAbertura
        ? null
        : rect.left +
              (textDirection == TextDirection.rtl
                  ? gapStart + gapPadding - extent
                  : gapStart - gapPadding);
    pintarContornoFino(
      canvas,
      rect,
      borderRadius,
      borderSide.color,
      densidade: densidade,
      aberturaInicio: inicio,
      aberturaFim: (inicio ?? 0) + extent,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContornoCampo && other.densidade == densidade && super == other;
  @override
  int get hashCode => Object.hash(super.hashCode, densidade);
}

/// Mesma pintura para a borda do checkbox e dos botoes.
class FormaControle extends RoundedRectangleBorder {
  const FormaControle({
    super.side = const BorderSide(color: PadraoControles.borda),
    super.borderRadius = const BorderRadius.all(Radius.circular(2)),
    this.densidade = 1,
  });
  final double densidade;
  @override
  FormaControle scale(double t) => copyWith(
    side: side.scale(t),
    borderRadius: BorderRadiusGeometry.lerp(BorderRadius.zero, borderRadius, t),
  );
  @override
  FormaControle copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
  }) => FormaControle(
    side: side ?? this.side,
    borderRadius: borderRadius ?? this.borderRadius,
    densidade: densidade,
  );
  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is RoundedRectangleBorder
      ? copyWith(
          side: BorderSide.lerp(a.side, side, t),
          borderRadius: BorderRadiusGeometry.lerp(
            a.borderRadius,
            borderRadius,
            t,
          ),
        )
      : super.lerpFrom(a, t);
  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is RoundedRectangleBorder
      ? copyWith(
          side: BorderSide.lerp(side, b.side, t),
          borderRadius: BorderRadiusGeometry.lerp(
            borderRadius,
            b.borderRadius,
            t,
          ),
        )
      : super.lerpTo(b, t);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style != BorderStyle.none)
      pintarContornoFino(
        canvas,
        rect,
        borderRadius.resolve(textDirection),
        side.color,
        densidade: densidade,
      );
  }
}

class LinhaControle extends StatelessWidget {
  const LinhaControle({
    super.key,
    this.vertical = false,
    this.espaco = 16,
    this.cor = PadraoControles.separador,
  });
  final bool vertical;
  final double espaco;
  final Color cor;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: vertical ? espaco : double.infinity,
    height: vertical ? double.infinity : espaco,
    child: CustomPaint(painter: _PintorLinha(vertical, cor)),
  );
}

class _PintorLinha extends CustomPainter {
  const _PintorLinha(this.vertical, this.cor);
  final bool vertical;
  final Color cor;
  @override
  void paint(Canvas canvas, Size size) => pintarLinhaFina(
    canvas,
    vertical ? Offset(size.width / 2, 0) : Offset(0, size.height / 2),
    vertical
        ? Offset(size.width / 2, size.height)
        : Offset(size.width, size.height / 2),
    cor,
  );
  @override
  bool shouldRepaint(_PintorLinha old) =>
      vertical != old.vertical || cor != old.cor;
}

class SeparadoresTabela extends TableBorder {
  const SeparadoresTabela({
    this.ignorarInicio = false,
    this.grade = false,
    this.densidade = 1,
    this.inicioGrade = 0,
  });
  final bool ignorarInicio;
  final bool grade;
  final double densidade;
  final double inicioGrade;
  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    required Iterable<double> rows,
    required Iterable<double> columns,
  }) {
    for (final y in rows.where((y) => !ignorarInicio || y > 0))
      pintarLinhaFina(
        canvas,
        Offset(rect.left + (grade ? inicioGrade : 0), rect.top + y),
        Offset(rect.right, rect.top + y),
        PadraoControles.separador,
      );
    if (grade) {
      for (final x in columns.where((x) => x > inicioGrade)) {
        pintarLinhaFina(
          canvas,
          Offset(rect.left + x, rect.top),
          Offset(rect.left + x, rect.bottom),
          PadraoControles.separador,
        );
      }
      pintarContornoFino(
        canvas,
        Rect.fromLTRB(
          rect.left + inicioGrade,
          rect.top,
          rect.right,
          rect.bottom,
        ),
        BorderRadius.zero,
        PadraoControles.separador,
        densidade: densidade,
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SeparadoresTabela &&
      other.ignorarInicio == ignorarInicio &&
      other.grade == grade &&
      other.densidade == densidade &&
      other.inicioGrade == inicioGrade;
  @override
  int get hashCode => Object.hash(ignorarInicio, grade, densidade, inicioGrade);
}

/// Contornos de painéis usam o mesmo traço; cores de avisos são preservadas.
class BordaFina extends BoxBorder {
  const BordaFina(this.original);
  final BoxBorder original;
  @override
  BorderSide get top => original.top;
  @override
  BorderSide get bottom => original.bottom;
  @override
  EdgeInsetsGeometry get dimensions => original.dimensions;
  @override
  bool get isUniform => original.isUniform;
  @override
  BoxBorder scale(double t) => BordaFina(original.scale(t) as BoxBorder);
  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    TextDirection? textDirection,
    BoxShape shape = BoxShape.rectangle,
    BorderRadius? borderRadius,
  }) {
    if (isUniform) {
      if (top.style == BorderStyle.none) return;
      if (shape == BoxShape.circle) {
        canvas.drawOval(
          rect.deflate(0.5),
          Paint()
            ..color = top.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0,
        );
      } else {
        pintarContornoFino(
          canvas,
          rect,
          borderRadius ?? BorderRadius.zero,
          top.color,
        );
      }
    } else if (original is Border) {
      final b = original as Border;
      void linha(BorderSide lado, Offset de, Offset ate) {
        if (lado.style != BorderStyle.none)
          pintarLinhaFina(canvas, de, ate, lado.color);
      }

      linha(b.top, rect.topLeft, rect.topRight);
      linha(b.bottom, rect.bottomLeft, rect.bottomRight);
      linha(b.left, rect.topLeft, rect.bottomLeft);
      linha(b.right, rect.topRight, rect.bottomRight);
    } else {
      original.paint(
        canvas,
        rect,
        textDirection: textDirection,
        shape: shape,
        borderRadius: borderRadius,
      );
    }
  }
}
