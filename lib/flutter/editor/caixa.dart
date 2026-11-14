import 'package:flutter/material.dart';
import '../kit/contorno_campo.dart';

/// Caixa do editor: barra de formatação em cima, área de texto embaixo, contorno arredondado.
///
/// [bloqueado] = card travado (antes do "Editar"): a caixa inteira fica acinzentada e NÃO recebe
/// mouse — nem clique, nem seleção de texto, nem cursor de texto, nem dicas dos botões. O foco de
/// teclado é tirado pelo editor (editor_rico.dart), que também desfaz atalhos que alterem o
/// documento.
class CaixaEditor extends StatelessWidget {
  const CaixaEditor({
    super.key,
    required this.bloqueado,
    required this.barra,
    required this.texto,
    this.alturaSemLimite = 260,
  });

  final bool bloqueado;
  final Widget barra;
  final Widget texto;

  /// Altura da área de texto quando o pai não limita a altura.
  final double alturaSemLimite;

  /// Opacidade da caixa travada — acinzentada como os campos desativados do card.
  static const double opacidadeBloqueado = 0.5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final limitado = constraints.maxHeight.isFinite;
        final Widget areaTexto = Container(
          color: Colors.white,
          height: limitado ? null : alturaSemLimite,
          child: texto,
        );
        return DecoratedBox(
          // Contorno POR CIMA do conteúdo: por baixo, os fundos opacos da barra e da área de
          // texto o escondiam e a caixa da mensagem ficava sem borda.
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: const BordaFina(
              Border.fromBorderSide(BorderSide(color: PadraoControles.borda)),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: IgnorePointer(
              ignoring: bloqueado,
              child: Opacity(
                opacity: bloqueado ? opacidadeBloqueado : 1,
                child: Column(
                  mainAxisSize: limitado ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFFF5F6F8),
                        border: BordaFina(
                          Border(
                            bottom: BorderSide(
                              color: PadraoControles.separador,
                            ),
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: barra,
                    ),
                    if (limitado) Expanded(child: areaTexto) else areaTexto,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
