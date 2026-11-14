/// Janela menor que o tamanho de referência: o programa INTEIRO encolhe por igual (textos,
/// botões, janelas, menus) para caber, até [escalaMinima]; daí para baixo quem resolve são as
/// barras de rolagem. Do tamanho de referência para cima nada muda.
///
/// É a mesma engrenagem da escala do monitor (125%, 150%…): a tela é montada como se a janela
/// fosse maior e desenhada reduzida. Como o Flutter desenha por vetor, o texto continua nítido
/// e não há custo a mais por quadro.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Área útil da janela (em pontos) a partir da qual a tela é desenhada no tamanho natural: um
/// pouco menos que a janela maximizada num monitor de 1920 × 1080 a 125%.
const larguraDeReferencia = 1500.0;
const alturaDeReferencia = 780.0;

/// Até onde a tela encolhe.
const escalaMinima = 0.75;

/// O fator de redução para uma janela de [janela] pontos (1 = tamanho natural). Anda de centésimo
/// em centésimo: arrastar a borda da janela não cria uma escala nova a cada pixel.
double escalaPara(Size janela) {
  if (janela.isEmpty || !janela.isFinite) return 1;
  final cabe = math.min(janela.width / larguraDeReferencia, janela.height / alturaDeReferencia);
  return ((cabe * 100).floorToDouble() / 100).clamp(escalaMinima, 1.0);
}

/// A ligação do Flutter com a janela, com a redução embutida: a tela é montada e desenhada na
/// densidade do monitor vezes o fator, e o ponteiro (que chega na escala da janela) é trazido
/// para a da tela. Tudo o que está dentro — cliques, menus, janelas — vive numa escala só.
class LigacaoComEscala extends WidgetsFlutterBinding {
  /// O fator em vigor (1 = tamanho natural).
  static double escala = 1;

  /// No lugar de `WidgetsFlutterBinding.ensureInitialized()`, antes de qualquer outra coisa.
  static void iniciar() {
    LigacaoComEscala();
  }

  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) {
    final real = super.createViewConfigurationFor(renderView);
    final janela = real.logicalConstraints;
    final fator = janela.isTight ? escalaPara(janela.biggest) : 1.0;
    escala = fator;
    if (fator == 1) return real;
    final densidade = real.devicePixelRatio * fator;
    return ViewConfiguration(
      physicalConstraints: real.physicalConstraints,
      logicalConstraints: real.physicalConstraints / densidade,
      devicePixelRatio: densidade,
    );
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    final fator = escala;
    super.handlePointerEvent(
      fator == 1 ? event : event.copyWith(position: event.position / fator, delta: event.delta / fator),
    );
  }
}

/// Informa ao que está dentro o tamanho e a densidade em que a tela está de fato desenhada (sem
/// isto valeriam os da janela, e uma janela do programa se acharia sem espaço).
class NaEscala extends StatelessWidget {
  const NaEscala({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final real = MediaQuery.of(context);
    final fator = escalaPara(real.size);
    return MediaQuery(
      data: fator == 1
          ? real
          : real.copyWith(size: real.size / fator, devicePixelRatio: real.devicePixelRatio * fator),
      child: child,
    );
  }
}
