import 'package:flutter_quill/quill_delta.dart';

/// Atributos que a barra oferece e que a conversão para o e-mail (rust/src/email_delta.rs) lê de
/// volta ao reabrir o editor.
const Set<String> _inlinePermitidos = {
  "bold",
  "italic",
  "underline",
  "font",
  "size",
  "color",
  "background",
};

/// Tamanhos nomeados do flutter_quill em px — os mesmos de rust/src/email_delta.rs.
const Map<String, double> _tamanhosNomeados = {"small": 10, "large": 18, "huge": 22};

String _primeiraFamilia(Object? valor) =>
    valor.toString().split(",").first.replaceAll(RegExp(r'''["'<>;]'''), "").trim();

/// Tamanho colado -> valor que o flutter_quill aceita (número; "24px" derrubaria o editor no
/// getFontSize). pt vira px; valor inválido some.
Object? _tamanho(Object? valor) {
  if (valor is num) return valor > 0 ? valor.toDouble() : null;
  final s = valor.toString().trim().toLowerCase();
  if (const {"small", "large", "huge"}.contains(s)) return s;
  final emPt = s.endsWith("pt");
  final n = double.tryParse(s.replaceAll(RegExp(r"(px|pt)$"), ""));
  if (n == null || n <= 0) return null;
  return emPt ? (n * 4 / 3).roundToDouble() : n;
}

/// Fonte colada -> como a barra a oferece. Com a lista da barra: só as famílias dela (com a
/// grafia dela), e a fonte padrão vira "sem fonte" — senão o seletor mostraria "Arial" sobre um
/// texto em Calibri, e o e-mail sairia numa fonte que a barra nem oferece.
String? _fonteDaBarra(Object? valor, List<String> fontes, String? padrao) {
  final familia = _primeiraFamilia(valor);
  if (familia.isEmpty) return null;
  if (fontes.isEmpty) return familia;
  final chave = familia.toLowerCase();
  if (padrao != null && padrao.trim().toLowerCase() == chave) return null;
  for (final f in fontes) {
    if (f.trim().toLowerCase() == chave) return f;
  }
  return null;
}

/// Tamanho colado -> como a barra o oferece (mesma regra da fonte, comparando os px), na
/// grafia da lista ("24", em texto, como o seletor e o núcleo gravam).
///
/// O conversor de HTML do flutter_quill (flutter_quill_delta_from_html) passa pt para px
/// CORTANDO as casas — 18pt chega "23", 13,5pt "17", 12pt "15" —, então, sem igualdade exata,
/// vale a opção (ou o padrão) até 1 px acima.
Object? _tamanhoDaBarra(Object? valor, List<String> tamanhos, String? padrao) {
  final t = _tamanho(valor);
  if (t == null || tamanhos.isEmpty) return t;
  final px = t is num ? t.toDouble() : _tamanhosNomeados[t];
  if (px == null) return null;
  final padraoPx = padrao == null ? null : double.tryParse(padrao.trim());
  for (final exato in const [true, false]) {
    bool casa(double v) => exato ? v == px : (v > px && v - px <= 1);
    if (padraoPx != null && casa(padraoPx)) return null; // o padrão: sem tamanho próprio
    for (final opcao in tamanhos) {
      final v = double.tryParse(opcao.trim());
      if (v != null && casa(v)) return opcao.trim();
    }
  }
  return null;
}

/// Filtra o que vem colado de OUTRO programa (HTML/Markdown da área de transferência — é só
/// aí que o flutter_quill chama `onRichTextPaste`; copiar e colar dentro do próprio editor
/// leva apenas a formatação que o documento já tinha).
///
/// Mantém o texto, as quebras de linha e só a formatação que a barra oferece. Lista,
/// alinhamento, título, link, tachado, código e imagens saem: o e-mail os perdia ao reabrir o
/// editor (itens de lista ficavam grudados numa linha só) — melhor o editor mostrar desde já só
/// o que vai ficar salvo. A fonte fica só com a primeira família da pilha CSS colada.
///
/// Com [fontes]/[tamanhos] (as listas da barra), fonte e tamanho fora delas — ou iguais ao
/// padrão — viram texto sem fonte/tamanho, que o editor e o e-mail mostram no padrão.
Delta filtrarColado(
  Delta colado, {
  List<String> fontes = const [],
  List<String> tamanhos = const [],
  String? fontePadrao,
  String? tamanhoPadrao,
}) {
  final textos = <String>[];
  final atributos = <Map<String, dynamic>?>[];
  for (final op in colado.toList()) {
    if (!op.isInsert) continue;
    final dado = op.data;
    if (dado is! String) continue; // imagens e outros embeds
    final permitidos = <String, dynamic>{};
    op.attributes?.forEach((chave, valor) {
      if (valor == null || !_inlinePermitidos.contains(chave)) return;
      if (chave == "font") {
        final familia = _fonteDaBarra(valor, fontes, fontePadrao);
        if (familia != null) permitidos[chave] = familia;
      } else if (chave == "size") {
        final tamanho = _tamanhoDaBarra(valor, tamanhos, tamanhoPadrao);
        if (tamanho != null) permitidos[chave] = tamanho;
      } else {
        permitidos[chave] = valor;
      }
    });
    final partes = dado.split("\n");
    for (var i = 0; i < partes.length; i++) {
      if (partes[i].isNotEmpty) {
        textos.add(partes[i]);
        atributos.add(permitidos.isEmpty ? null : Map<String, dynamic>.from(permitidos));
      }
      if (i < partes.length - 1) {
        textos.add("\n");
        atributos.add(null);
      }
    }
  }
  // O conversor de HTML do flutter_quill (HtmlToDelta.convert) SEMPRE termina com "\n": sem
  // tirar, colar uma palavra copiada do navegador ou do Word quebrava a linha no meio.
  if (textos.isNotEmpty && textos.last == "\n") {
    textos.removeLast();
    atributos.removeLast();
  }
  final saida = Delta();
  for (var i = 0; i < textos.length; i++) {
    saida.insert(textos[i], atributos[i]);
  }
  return saida;
}

/// `onReplaceText` do controller: ignora a colagem que o filtro esvaziou (ex.: só uma imagem).
/// Com a lista de operações vazia o flutter_quill quebra em `Document.compose` (assert
/// `delta.isNotEmpty`); devolver `null` no `onRichTextPaste` não serve — aí ele cola o conteúdo
/// original, sem filtro.
bool aceitarSubstituicao(int indice, int tamanho, Object? dado) =>
    !(dado is Delta && dado.isEmpty);
