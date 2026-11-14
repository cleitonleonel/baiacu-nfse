import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../estilo.dart';
import 'realce.dart';

// Barra de formatação do editor rico — numa linha só, sempre na mesma ordem e largura.
//
// Por que não o QuillSimpleToolbar: os seletores de fonte/tamanho dele mudam de largura com o
// rótulo ("Fonte", "Tamanho da fonte", "Times New Roman"...) e empurravam botões para uma
// segunda linha; a opção `width` deles não resolve (o rótulo vai dentro de um IconButton sem
// largura máxima). Aqui os seletores têm largura fixa, mostram a fonte/tamanho PADRÃO quando o
// texto não tem formatação própria e não têm a opção "Padrão": escolher a própria fonte ou
// tamanho padrão tira o atributo do trecho. Os demais botões são os do flutter_quill.

/// Larguras fixas dos seletores (cabem "Times New Roman" e "24" com a seta).
const double larguraSeletorFonte = 150;
const double larguraSeletorTamanho = 64;

/// "16", "16px", 16 -> 16.0; o resto -> null.
double? numeroTamanho(Object? valor) {
  if (valor is num) return valor > 0 ? valor.toDouble() : null;
  if (valor == null) return null;
  final texto = valor.toString().trim().toLowerCase().replaceFirst(RegExp(r"px$"), "");
  final n = double.tryParse(texto);
  return n != null && n > 0 ? n : null;
}

String _textoTamanho(double px) =>
    px == px.roundToDouble() ? px.toInt().toString() : px.toString();

/// Seletor de fonte ([Attribute.font]) ou de tamanho ([Attribute.size]) com largura fixa.
class SeletorFormato extends StatefulWidget {
  const SeletorFormato({
    super.key,
    required this.controller,
    required this.atributo,
    required this.opcoes,
    required this.padrao,
    required this.largura,
    required this.dica,
    this.aoEscolher,
  });

  final QuillController controller;

  /// `Attribute.font.key` ou `Attribute.size.key`.
  final String atributo;
  final List<String> opcoes;

  /// Mostrado quando o texto não tem o atributo; escolhê-lo tira o atributo do trecho.
  final String? padrao;
  final double largura;
  final String dica;

  /// Chamado depois de aplicar (o editor devolve o foco ao texto).
  final VoidCallback? aoEscolher;

  @override
  State<SeletorFormato> createState() => _SeletorFormatoState();
}

class _SeletorFormatoState extends State<SeletorFormato> {
  bool get _ehTamanho => widget.atributo == Attribute.size.key;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_mudou);
  }

  @override
  void didUpdateWidget(covariant SeletorFormato antigo) {
    super.didUpdateWidget(antigo);
    if (!identical(antigo.controller, widget.controller)) {
      antigo.controller.removeListener(_mudou);
      widget.controller.addListener(_mudou);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_mudou);
    super.dispose();
  }

  void _mudou() {
    if (mounted) setState(() {});
  }

  /// Fonte: mesmo nome sem diferenciar maiúsculas. Tamanho: mesmo número de px.
  bool _iguais(Object? a, Object? b) {
    if (a == null || b == null) return false;
    if (_ehTamanho) {
      final na = numeroTamanho(a);
      return na != null && na == numeroTamanho(b);
    }
    return a.toString().trim().toLowerCase() == b.toString().trim().toLowerCase();
  }

  /// Valor do atributo no trecho selecionado (ou sob o cursor).
  Object? get _valorAtual =>
      widget.controller.getSelectionStyle().attributes[widget.atributo]?.value;

  String? _opcaoDe(Object? valor) {
    for (final o in widget.opcoes) {
      if (_iguais(o, valor)) return o;
    }
    return null;
  }

  String _rotulo(Object? valor) {
    if (valor == null) return widget.padrao ?? "";
    final opcao = _opcaoDe(valor);
    if (opcao != null) return opcao;
    if (_ehTamanho) {
      final px = numeroTamanho(valor);
      return px == null ? valor.toString() : _textoTamanho(px);
    }
    // Fonte fora da lista (HTML antigo escrito à mão): mostra a verdadeira, não o padrão.
    return valor.toString();
  }

  void _escolher(String opcao) {
    Object? novo;
    if (!_iguais(opcao, widget.padrao)) {
      if (_ehTamanho) {
        // Tamanho em TEXTO ("24"), como o núcleo grava (rust/src/email_delta.rs). Com 24.0 num
        // trecho e "24" no vizinho, o flutter_quill não vê o mesmo tamanho numa seleção que
        // pega os dois (Line.collectStyle compara os valores) e o seletor mostraria o padrão.
        final px = numeroTamanho(opcao);
        novo = px == null ? null : _textoTamanho(px);
      } else {
        novo = opcao;
      }
    }
    widget.controller.formatSelection(Attribute.fromKeyValue(widget.atributo, novo));
    widget.aoEscolher?.call();
  }

  @override
  Widget build(BuildContext context) {
    final valor = _valorAtual;
    return Theme(
      data: temaDeMenu(context),
      // Material transparente: o realce do hover é pintado nele, POR CIMA do fundo cinza da
      // barra. Sem ele a tinta ia para o Material de trás e ficava escondida pelo fundo.
      child: Material(
        type: MaterialType.transparency,
        child: PopupMenuButton<String>(
          tooltip: widget.dica,
          initialValue: _opcaoDe(valor ?? widget.padrao),
          onSelected: _escolher,
          borderRadius: BorderRadius.circular(8),
          itemBuilder: (context) => [
            for (final o in widget.opcoes)
              PopupMenuItem<String>(
                key: ValueKey("opcao_${widget.atributo}_$o"),
                value: o,
                height: 36,
                mouseCursor: SystemMouseCursors.click,
                child: Text(o, style: _ehTamanho ? null : TextStyle(fontFamily: o)),
              ),
          ],
          // O InkWell do PopupMenuButton não aceita cursor: a mãozinha vem deste MouseRegion.
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SizedBox(
              width: widget.largura,
              height: 40,
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _rotulo(valor),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: Letra.texto),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Monta a barra: desfazer/refazer · fonte · tamanho · N I S · cor · marca-texto · limpar e,
/// à direita, o menu de variáveis.
Widget construirBarra({
  required QuillController controller,
  required List<String> fontes,
  required List<String> tamanhos,
  required String? fontePadrao,
  required String? tamanhoPadrao,
  required List<String> variaveis,
  required ValueChanged<String> aoInserirVariavel,
  required Future<void> Function(QuillController controller, bool fundo) aoEscolherCor,
  VoidCallback? aoFormatar,
}) {
  final opcoesCor = QuillToolbarColorButtonOptions(customOnPressedCallback: aoEscolherCor);
  final botoes = <Widget>[
    // Chave no DOCUMENTO: desfazer/refazer assinam as mudanças do Document só no initState.
    // Quando o editor troca o documento (valor vindo do Python, restauração do card travado),
    // os dois são recriados — senão ficariam presos ao documento antigo (habilitados à toa).
    KeyedSubtree(
      key: ObjectKey(controller.document),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          QuillToolbarHistoryButton(controller: controller, isUndo: true),
          QuillToolbarHistoryButton(controller: controller, isUndo: false),
        ],
      ),
    ),
    if (fontes.isNotEmpty)
      SeletorFormato(
        key: const ValueKey("seletor_fonte"),
        controller: controller,
        atributo: Attribute.font.key,
        opcoes: fontes,
        padrao: fontePadrao,
        largura: larguraSeletorFonte,
        dica: "Fonte",
        aoEscolher: aoFormatar,
      ),
    if (tamanhos.isNotEmpty)
      SeletorFormato(
        key: const ValueKey("seletor_tamanho"),
        controller: controller,
        atributo: Attribute.size.key,
        opcoes: tamanhos,
        padrao: tamanhoPadrao,
        largura: larguraSeletorTamanho,
        dica: "Tamanho da fonte",
        aoEscolher: aoFormatar,
      ),
    QuillToolbarToggleStyleButton(controller: controller, attribute: Attribute.bold),
    QuillToolbarToggleStyleButton(controller: controller, attribute: Attribute.italic),
    QuillToolbarToggleStyleButton(controller: controller, attribute: Attribute.underline),
    QuillToolbarColorButton(controller: controller, isBackground: false, options: opcoesCor),
    QuillToolbarColorButton(controller: controller, isBackground: true, options: opcoesCor),
    QuillToolbarClearFormatButton(controller: controller),
  ];
  return Row(
    children: [
      Expanded(
        // Rolagem só por segurança (janela estreitíssima): na largura do card tudo cabe.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: botoes),
        ),
      ),
      if (variaveis.isNotEmpty)
        Builder(
          // O botão { } já é um IconButton (mãozinha e hover pelo tema do app); o tema aqui é
          // para os ITENS do menu.
          builder: (context) => Theme(
            data: temaDeMenu(context),
            child: PopupMenuButton<String>(
              key: const ValueKey("menu_variaveis"),
              tooltip: "Inserir variável",
              icon: const Icon(Icons.data_object, size: 20),
              onSelected: aoInserirVariavel,
              itemBuilder: (context) => [
                for (final v in variaveis)
                  PopupMenuItem<String>(
                    value: v,
                    mouseCursor: SystemMouseCursors.click,
                    child: Text(v),
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}

/// Estilo do texto SEM fonte/tamanho próprios no editor: o mesmo padrão que o seletor mostra e
/// que o e-mail aplica (rust/src/email_delta.rs). Altura de linha e espaçamentos iguais aos do
/// flutter_quill (DefaultStyles.getInstance).
DefaultStyles estilosPadraoEditor(BuildContext context, {String? fonte, String? tamanho}) {
  final base = DefaultTextStyle.of(context).style;
  return DefaultStyles(
    paragraph: DefaultTextBlockStyle(
      base.copyWith(
        fontFamily: fonte,
        fontSize: numeroTamanho(tamanho) ?? 16,
        height: 1.15,
        decoration: TextDecoration.none,
      ),
      HorizontalSpacing.zero,
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    ),
  );
}
