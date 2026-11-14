import 'package:flutter/material.dart';
import '../kit/contorno_campo.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'realce.dart';

/// Paleta própria de "cor do texto" e "marca-texto" do editor.
///
/// Por que existe: o diálogo de cor do flutter_quill (ColorPickerDialog) busca as traduções com
/// `context.loc`, que LANÇA `MissingFlutterQuillLocalizationException` quando não as encontra.
/// Diálogos são desenhados no Navigator do app, ACIMA do `Localizations.override` que o editor
/// usa, e o Flet não registra o delegate do flutter_quill no MaterialApp — clicar em "cor do
/// fundo" derrubava a tela. Esta paleta não depende das traduções do quill e oferece só cores
/// que funcionam bem num e-mail.
const List<(String, String?)> coresTexto = [
  ("Automática", null),
  ("Preto", "#000000"),
  ("Cinza escuro", "#424242"),
  ("Cinza", "#757575"),
  ("Vermelho", "#c62828"),
  ("Laranja", "#ef6c00"),
  ("Amarelo escuro", "#f9a825"),
  ("Verde", "#2e7d32"),
  ("Azul-petróleo", "#00838f"),
  ("Azul", "#1565c0"),
  ("Azul-marinho", "#0d47a1"),
  ("Roxo", "#6a1b9a"),
  ("Rosa", "#ad1457"),
  ("Marrom", "#5d4037"),
];

const List<(String, String?)> coresFundo = [
  ("Sem marca-texto", null),
  ("Amarelo", "#ffff00"),
  ("Amarelo claro", "#fff59d"),
  ("Verde claro", "#c8e6c9"),
  ("Azul claro", "#bbdefb"),
  ("Rosa claro", "#f8bbd0"),
  ("Laranja claro", "#ffe0b2"),
  ("Lilás", "#e1bee7"),
  ("Cinza claro", "#eeeeee"),
];

class _Escolha {
  final String? hex;
  const _Escolha(this.hex);
}

Color _corDe(String hex) =>
    Color(int.parse("ff${hex.substring(1)}", radix: 16));

/// Amostra clicável de uma cor: mãozinha, realce de hover igual ao dos botões do app e contorno
/// na cor principal enquanto o mouse está em cima (o realce escuro some nas cores escuras).
class _Amostra extends StatefulWidget {
  const _Amostra({
    required this.nome,
    required this.hex,
    required this.aoEscolher,
  });

  final String nome;
  final String? hex;
  final VoidCallback aoEscolher;

  @override
  State<_Amostra> createState() => _AmostraState();
}

class _AmostraState extends State<_Amostra> {
  bool _sobre = false;

  @override
  Widget build(BuildContext context) {
    final hex = widget.hex;
    final forma = FormaControle(
      borderRadius: BorderRadius.circular(6),
      side: _sobre
          ? BorderSide(color: Theme.of(context).colorScheme.primary)
          : const BorderSide(color: PadraoControles.borda),
    );
    return Tooltip(
      message: widget.nome,
      // A cor vai no próprio Material: o realce do InkWell é pintado POR CIMA dela. Num
      // Container colorido (como antes) a tinta ficava escondida atrás da cor.
      child: Material(
        color: hex == null ? Colors.white : _corDe(hex),
        shape: forma,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey("cor_${hex ?? 'nenhuma'}"),
          mouseCursor: SystemMouseCursors.click,
          customBorder: forma,
          hoverColor: corHover(context),
          highlightColor: corPressionado(context),
          splashColor: corPressionado(context),
          onHover: (sobre) => setState(() => _sobre = sobre),
          onTap: widget.aoEscolher,
          child: SizedBox(
            width: 36,
            height: 36,
            child: hex == null
                ? const Icon(
                    Icons.format_color_reset,
                    size: 20,
                    color: Color(0xFF757575),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// Abre a paleta e aplica a cor escolhida na seleção (ou no que for digitado a seguir, se
/// não houver seleção). A opção sem cor REMOVE o atributo. Cancelar não muda nada.
///
/// Assinatura compatível com `QuillToolbarColorButtonOptions.customOnPressedCallback`
/// quando fechada sobre um [context] que esteja abaixo do Navigator.
Future<void> escolherCor(
  BuildContext context,
  QuillController controller,
  bool fundo,
) async {
  final itens = fundo ? coresFundo : coresTexto;
  final escolhida = await showDialog<_Escolha>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(fundo ? "Marca-texto" : "Cor do texto"),
      content: SizedBox(
        width: 300,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (nome, hex) in itens)
              _Amostra(
                nome: nome,
                hex: hex,
                aoEscolher: () => Navigator.of(ctx).pop(_Escolha(hex)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey("cor_cancelar"),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text("Cancelar"),
        ),
      ],
    ),
  );
  if (escolhida == null) return;
  controller.formatSelection(
    fundo ? BackgroundAttribute(escolhida.hex) : ColorAttribute(escolhida.hex),
  );
}
