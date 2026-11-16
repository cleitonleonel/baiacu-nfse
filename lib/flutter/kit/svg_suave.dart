import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Mantém o SVG original e suaviza detalhes pequenos com superamostragem.
/// A redução usa mipmaps (medium): o filtro cúbico (high) não cobre os muitos
/// pixels de origem por pixel de destino e produz serrilhado nos traços finos.
class IconeSvgSuave extends StatelessWidget {
  const IconeSvgSuave(this.asset, {super.key, this.tamanho = 28});
  final String asset;
  final double tamanho;
  static final _imagens = <(String, int), Future<ui.Image>>{};

  static Future<ui.Image> _renderizar(
    String asset,
    int pixels,
    BuildContext context,
  ) async {
    final info = await vg.loadPicture(SvgAssetLoader(asset), context);
    final gravador = ui.PictureRecorder();
    final canvas = Canvas(gravador);
    final escala = pixels / info.size.longestSide;
    canvas.translate(
      (pixels - info.size.width * escala) / 2,
      (pixels - info.size.height * escala) / 2,
    );
    canvas.scale(escala);
    canvas.drawPicture(info.picture);
    final desenho = gravador.endRecording();
    try {
      return await desenho.toImage(pixels, pixels);
    } finally {
      desenho.dispose();
      info.picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pixels = (tamanho * MediaQuery.devicePixelRatioOf(context) * 8)
        .ceil();
    final imagem = _imagens.putIfAbsent((
      asset,
      pixels,
    ), () => _renderizar(asset, pixels, context));
    return SizedBox.square(
      dimension: tamanho,
      child: FutureBuilder<ui.Image>(
        future: imagem,
        builder: (context, estado) => estado.hasData
            ? RawImage(
                image: estado.data,
                isAntiAlias: true,
                filterQuality: FilterQuality.medium,
              )
            : SvgPicture.asset(asset, width: tamanho, height: tamanho),
      ),
    );
  }
}
