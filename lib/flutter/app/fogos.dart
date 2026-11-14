// Fogos de artifício por cima da tela inteira (comemoração da primeira NFS-e). Não bloqueiam
// cliques, duram uns 4 segundos e se removem sozinhos. Só desenho: nenhum pacote externo.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Solta os fogos na camada mais alta do aplicativo.
void soltarFogos(OverlayState camada) {
  late final OverlayEntry entrada;
  entrada = OverlayEntry(
    builder: (_) => IgnorePointer(
      child: _Fogos(
        aoTerminar: () {
          if (entrada.mounted) entrada.remove();
        },
      ),
    ),
  );
  camada.insert(entrada);
}

const _cores = [
  Color(0xFFE5486F), // rosa
  Color(0xFF7A5AF8), // violeta
  Color(0xFFFFC233), // dourado
  Color(0xFF22C3E6), // ciano
  Color(0xFF2BD47D), // verde
  Color(0xFFFF7A33), // laranja
  Color(0xFFFF5AC8), // magenta
];

/// Um foguete: sobe de baixo e estoura em faíscas. Posições relativas à tela (0..1).
class _Foguete {
  _Foguete(math.Random r, double inicio)
    : saida = inicio,
      x0 = 0.12 + r.nextDouble() * 0.76,
      xEstouro = 0,
      yEstouro = 0.12 + r.nextDouble() * 0.33,
      subida = 0.75 + r.nextDouble() * 0.35,
      cor = _cores[r.nextInt(_cores.length)],
      cor2 = _cores[r.nextInt(_cores.length)],
      faiscas = List.generate(64 + r.nextInt(36), (i) {
        final angulo = r.nextDouble() * math.pi * 2;
        // Velocidade em "telas por segundo" (anel mais forte + miolo mais lento).
        final v = (i.isEven ? 0.28 : 0.16) + r.nextDouble() * 0.10;
        return _Faisca(
          math.cos(angulo) * v,
          math.sin(angulo) * v,
          1.15 + r.nextDouble() * 0.7,
          r.nextBool(),
          r.nextDouble() * math.pi * 2,
        );
      }) {
    xEstouro = x0 + (r.nextDouble() - 0.5) * 0.12;
  }

  final double saida;
  final double x0;
  double xEstouro;
  final double yEstouro;
  final double subida;
  final Color cor;
  final Color cor2;
  final List<_Faisca> faiscas;
}

class _Faisca {
  const _Faisca(this.vx, this.vy, this.vida, this.segundaCor, this.fase);
  final double vx;
  final double vy;
  final double vida;
  final bool segundaCor;
  final double fase;
}

class _Fogos extends StatefulWidget {
  const _Fogos({required this.aoTerminar});
  final VoidCallback aoTerminar;

  @override
  State<_Fogos> createState() => _FogosState();
}

class _FogosState extends State<_Fogos> with SingleTickerProviderStateMixin {
  static const _duracao = 4.4;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_duracao * 1000).round()),
  );
  late final List<_Foguete> _foguetes;

  @override
  void initState() {
    super.initState();
    final r = math.Random();
    // Uma salva logo de cara e mais alguns em sequência.
    _foguetes = [
      for (var i = 0; i < 3; i++) _Foguete(r, i * 0.12),
      for (var i = 0; i < 7; i++)
        _Foguete(r, 0.5 + i * 0.28 + r.nextDouble() * 0.2),
    ];
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.aoTerminar();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: CustomPaint(painter: _PintorFogos(_c, _foguetes, _duracao)),
  );
}

class _PintorFogos extends CustomPainter {
  _PintorFogos(this.anim, this.foguetes, this.duracao) : super(repaint: anim);

  final Animation<double> anim;
  final List<_Foguete> foguetes;
  final double duracao;

  static const _gravidade = 0.16; // telas/s²
  static const _arrasto = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final s = anim.value * duracao;
    final escala = size.shortestSide;
    final tinta = Paint()..strokeCap = StrokeCap.round;
    for (final f in foguetes) {
      final t = s - f.saida;
      if (t < 0) continue;
      final cx = f.xEstouro * size.width;
      final cy = f.yEstouro * size.height;
      if (t < f.subida) {
        // Subindo: desacelera perto do topo, com um rastro curto.
        final p = Curves.easeOutCubic.transform(t / f.subida);
        final x = (f.x0 + (f.xEstouro - f.x0) * p) * size.width;
        final y = size.height + (cy - size.height) * p;
        final p2 = Curves.easeOutCubic.transform(
          ((t - 0.07) / f.subida).clamp(0.0, 1.0),
        );
        final x2 = (f.x0 + (f.xEstouro - f.x0) * p2) * size.width;
        final y2 = size.height + (cy - size.height) * p2;
        tinta
          ..color = f.cor.withValues(alpha: 0.55)
          ..strokeWidth = 2.2;
        canvas.drawLine(Offset(x2, y2), Offset(x, y), tinta);
        tinta.color = Colors.white;
        canvas.drawCircle(Offset(x, y), 2.4, tinta);
        continue;
      }
      final e = t - f.subida;
      // Clarão do estouro.
      if (e < 0.22) {
        final a = 1 - e / 0.22;
        tinta.color = f.cor.withValues(alpha: 0.35 * a);
        canvas.drawCircle(Offset(cx, cy), escala * (0.02 + 0.10 * e), tinta);
        tinta.color = Colors.white.withValues(alpha: 0.8 * a);
        canvas.drawCircle(Offset(cx, cy), escala * 0.012, tinta);
      }
      for (final q in f.faiscas) {
        if (e >= q.vida) continue;
        Offset ponto(double tempo) {
          final d = (1 - math.exp(-_arrasto * tempo)) / _arrasto;
          return Offset(
            cx + q.vx * d * escala,
            cy + (q.vy * d + 0.5 * _gravidade * tempo * tempo) * escala,
          );
        }

        final vida = e / q.vida;
        // Some no fim, com um leve cintilar.
        final brilho =
            math.pow(1 - vida, 1.3).toDouble() *
            (0.75 + 0.25 * math.sin(e * 22 + q.fase));
        final cor = q.segundaCor ? f.cor2 : f.cor;
        final agora = ponto(e);
        final antes = ponto(math.max(0, e - 0.09));
        tinta
          ..color = cor.withValues(alpha: (brilho * 0.6).clamp(0.0, 1.0))
          ..strokeWidth = 2.0;
        canvas.drawLine(antes, agora, tinta);
        tinta.color = cor.withValues(alpha: brilho.clamp(0.0, 1.0));
        canvas.drawCircle(agora, 2.3 * (1 - vida * 0.5), tinta);
      }
    }
  }

  @override
  bool shouldRepaint(_PintorFogos old) => false;
}
