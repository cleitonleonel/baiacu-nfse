/// Editor visual das telas reais. As mudanças ficam separadas dos dados fiscais.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'estilo.dart' show revisaoDoEstilo, Medida;
import 'kit/contorno_campo.dart';
import 'arquivo_elemento.dart';

bool editorLayoutAtivo = false;

/// Apenas textos independentes somem do grupo; ocultar um rotulo preserva o campo.
abstract interface class TextoLayout {
  String? get idLayout;
}

class TextoLayoutWidget extends StatelessWidget implements TextoLayout {
  const TextoLayoutWidget({
    super.key,
    required this.idLayout,
    required this.child,
  });
  @override
  final String? idLayout;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

List<Widget> itensVisiveisLayout(BuildContext context, List<Widget> itens) {
  if (kDebugMode && editorLayoutAtivo) return itens;
  bool visivel(Widget item) {
    if (item is TextoLayout)
      return !ajusteLayout(context, (item as TextoLayout).idLayout).oculto;
    final Widget? filho = switch (item) {
      Flexible v => v.child,
      Padding v => v.child,
      Align v => v.child,
      SizedBox v => v.child,
      Container v => v.child,
      ConstrainedBox v => v.child,
      KeyedSubtree v => v.child,
      Tooltip v => v.child,
      _ => null,
    };
    return filho == null || visivel(filho);
  }

  return itens.where(visivel).toList();
}

class AjusteLayout {
  const AjusteLayout([this.valores = const {}]);
  final Map<String, dynamic> valores;
  double? get largura => (valores['largura'] as num?)?.toDouble();
  double? get altura => (valores['altura'] as num?)?.toDouble();
  double? get tamanhoFonte => (valores['tamanhoFonte'] as num?)?.toDouble();
  String? get fonte => valores['fonte'] as String?;
  bool? get negrito => valores['negrito'] as bool?;
  bool? get italico => valores['italico'] as bool?;
  bool? get sublinhado => valores['sublinhado'] as bool?;
  Color? get cor => valores['cor'] is int ? Color(valores['cor']) : null;
  String? get texto => valores['texto'] as String?;
  bool get oculto => valores['oculto'] == true;
  double? get espaco => (valores['espaco'] as num?)?.toDouble();
  double? get espacoLinhas => (valores['espacoLinhas'] as num?)?.toDouble();
  TextAlign? get alinhamento {
    final nome = valores['alinhamento'];
    for (final valor in TextAlign.values) {
      if (valor.name == nome) return valor;
    }
    return null;
  }

  AlignmentGeometry? get alinhamentoBotao => switch (alinhamento) {
    TextAlign.left || TextAlign.justify => Alignment.centerLeft,
    TextAlign.right => Alignment.centerRight,
    TextAlign.start => AlignmentDirectional.centerStart,
    TextAlign.end => AlignmentDirectional.centerEnd,
    TextAlign.center => Alignment.center,
    null => null,
  };
  String exibir(String original) => oculto ? '' : texto ?? original;
  bool get temFonte =>
      tamanhoFonte != null ||
      fonte != null ||
      negrito != null ||
      italico != null ||
      sublinhado != null ||
      cor != null;
  TextStyle estilo(TextStyle original) => original.copyWith(
    fontSize: tamanhoFonte,
    fontFamily: fonte,
    color: cor,
    fontStyle: italico == null
        ? null
        : italico!
        ? FontStyle.italic
        : FontStyle.normal,
    decoration: sublinhado == null
        ? null
        : sublinhado!
        ? TextDecoration.underline
        : TextDecoration.none,
    fontWeight: negrito == null
        ? null
        : negrito!
        ? FontWeight.bold
        : FontWeight.normal,
  );
}

class ControleLayout extends ChangeNotifier {
  bool ativo = false;
  String? selecionado;
  String nome = '';
  int restauracoes = 0;
  int selecoes = 0;
  Map<String, dynamic> propriedades = {};
  List<String> pais = [];
  final Map<String, RegistroLayout> registros = {};
  final Map<String, List<Widget>> grupos = {};
  final Map<String, List<String>> chavesGrupos = {};
  final Map<String, Widget> itens = {};
  final Map<String, Axis> eixos = {};
  bool registroPendente = false;
  String? arrastando;
  void notificarGrupos() {
    if (!encerrado) notifyListeners();
  }

  Widget? item(String chave) {
    return itens[chave];
  }

  List<String> ordem(String grupo) {
    final salvas = ajustes[grupo]?['ordem'];
    final ordem = salvas is List ? List<String>.from(salvas) : <String>[];
    // Novos campos/cabeçalhos continuam aparecendo depois de uma atualização.
    for (final chave in chavesGrupos[grupo] ?? <String>[]) {
      final transferida = ajustes.entries.any(
        (e) =>
            e.key != grupo &&
            e.value['ordem'] is List &&
            (e.value['ordem'] as List).contains(chave),
      );
      if (!transferida && !ordem.contains(chave)) ordem.add(chave);
    }
    return ordem;
  }

  bool podeMover(String chave, String destino) {
    if (item(chave) == null) return false;
    // Não permitir levar um grupo para dentro de um dos seus descendentes.
    final paisDestino = registros[destino]?.pais ?? [];
    String? cartao(String grupo) {
      final pais = [grupo, ...?registros[grupo]?.pais];
      for (final id in pais) {
        if (id.startsWith('Grupo.config.cartao.')) return id;
      }
      return null;
    }

    final origem = cartao(grupoDoItem(chave));
    final chegada = cartao(destino);
    if ((origem != null || chegada != null) && origem != chegada) return false;
    return !paisDestino.any((p) => p == grupoDoItem(chave));
  }

  String grupoDoItem(String chave) =>
      chave.substring(0, chave.lastIndexOf('.item.'));
  void moverItem(String chave, String destino, int indice) {
    if (!podeMover(chave, destino)) return;
    final origem = grupos.keys.firstWhere(
      (g) => ordem(g).contains(chave),
      orElse: () => grupoDoItem(chave),
    );
    final antes = ordem(origem);
    final pos = antes.indexOf(chave);
    final depois = origem == destino ? antes : ordem(destino);
    antes.remove(chave);
    if (origem == destino && pos >= 0 && pos < indice) indice--;
    depois.remove(chave);
    depois.insert(indice.clamp(0, depois.length), chave);
    ajustes.putIfAbsent(origem, () => {})['ordem'] = antes;
    ajustes.putIfAbsent(destino, () => {})['ordem'] = depois;
    arrastando = null;
    revisaoDoEstilo++;
    notifyListeners();
  }

  bool encerrado = false;
  @override
  void dispose() {
    editorLayoutAtivo = false;
    encerrado = true;
    super.dispose();
  }

  Map<String, Map<String, dynamic>> ajustes = {};
  File? arquivo;
  IndiceFontes? fontes;
  OrigemElemento? origem;
  String? erroInicial;
  void iniciar(String raiz) {
    final projeto = kDebugMode
        ? Platform.environment['NFSE_LAYOUT_PROJETO']
        : null;
    arquivo = File(
      '${projeto ?? raiz}${Platform.pathSeparator}configs${Platform.pathSeparator}layout_visual.json',
    );
    fontes = IndiceFontes(
      Directory(Platform.environment['NFSE_FONTE_PROJETO'] ?? projeto ?? raiz),
    );
    try {
      if (!arquivo!.existsSync()) return;
      final dados =
          jsonDecode(arquivo!.readAsStringSync()) as Map<String, dynamic>;
      if (dados['versao'] != 1)
        throw const FormatException('Versão de layout desconhecida');
      final itens = dados['elementos'] as Map<String, dynamic>;
      for (final entrada in itens.entries) {
        final item = Map<String, dynamic>.from(entrada.value as Map);
        for (final chave in [
          'largura',
          'altura',
          'tamanhoFonte',
          'espaco',
          'espacoLinhas',
        ]) {
          final n = item[chave];
          if (n != null &&
              (n is! num ||
                  !n.isFinite ||
                  (chave.startsWith('espaco') ? n < 0 : n <= 0) ||
                  n > 4000)) {
            throw FormatException('Medida inválida em ${entrada.key}');
          }
        }
        if (item['fonte'] != null && item['fonte'] is! String)
          throw const FormatException('Fonte inválida');
        if (item['negrito'] != null && item['negrito'] is! bool)
          throw const FormatException('Peso inválido');
        for (final chave in ['italico', 'sublinhado']) {
          if (item[chave] != null && item[chave] is! bool)
            throw const FormatException('Estilo inválido');
        }
        final cor = item['cor'];
        if (cor != null && (cor is! int || cor < 0 || cor > 0xFFFFFFFF))
          throw const FormatException('Cor inválida');
        final ordem = item['ordem'];
        if (ordem != null &&
            (ordem is! List ||
                ordem.length > 500 ||
                ordem.any((v) => v is! String || !v.contains('.item.')) ||
                ordem.toSet().length != ordem.length))
          throw const FormatException('Ordem de elementos inválida');
        if (item['texto'] != null && item['texto'] is! String)
          throw const FormatException('Texto inválido');
        if (item['oculto'] != null && item['oculto'] is! bool)
          throw const FormatException('Visibilidade inválida');
        if (item['alinhamento'] != null &&
            !TextAlign.values.any((v) => v.name == item['alinhamento']))
          throw const FormatException('Alinhamento inválido');
        ajustes[entrada.key] = item;
      }
    } catch (e) {
      ajustes.clear();
      erroInicial = 'Não foi possível ler os ajustes: $e';
    }
  }

  AjusteLayout de(String id) => AjusteLayout(ajustes[id] ?? const {});
  void selecionar(String id, String rotulo) {
    selecionado = id;
    nome = rotulo;
    selecoes++;
    final r = registros[id];
    propriedades = r?.capturar() ?? {};
    try {
      origem = fontes?.localizar(id, rotulo);
    } on FileSystemException {
      origem = null;
    }
    pais = r?.pais ?? [];
    notifyListeners();
  }

  void atualizarCaptura(String id) {
    if (encerrado || id != selecionado || !ativo) return;
    final novos = registros[id]?.capturar() ?? {};
    if (!mapEquals(propriedades, novos)) {
      propriedades = novos;
      notifyListeners();
    }
  }

  dynamic atual(String chave) =>
      propriedades[chave] ?? ajustes[selecionado]?[chave];

  void selecionarPai(String id) {
    final r = registros[id];
    if (r != null) selecionar(id, r.nome);
  }

  void alternar() {
    ativo = !ativo;
    editorLayoutAtivo = ativo;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (selecionado != null) atualizarCaptura(selecionado!);
    });
  }

  void mudar(String chave, dynamic valor) {
    final id = selecionado;
    if (id == null) return;
    final item = ajustes.putIfAbsent(id, () => {});
    if (valor == null) {
      item.remove(chave);
    } else {
      item[chave] = valor;
    }
    if (item.isEmpty) ajustes.remove(id);
    revisaoDoEstilo++;
    notifyListeners();
  }

  void restaurar() {
    if (ajustes[selecionado]?.containsKey('ordem') ?? false) {
      for (final item in ajustes.values) {
        item.remove('ordem');
      }
    }
    ajustes.remove(selecionado);
    restauracoes++;
    revisaoDoEstilo++;
    notifyListeners();
  }

  void restaurarPosicoes() {
    for (final item in ajustes.values) {
      item.remove('ordem');
    }
    revisaoDoEstilo++;
    notifyListeners();
  }

  Future<void> salvar() async {
    final f = arquivo!;
    await f.parent.create(recursive: true);
    final temp = File('${f.path}.novo');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert({'versao': 1, 'elementos': ajustes}),
      flush: true,
    );
    await temp.rename(f.path);
  }
}

class _EscopoLayout extends InheritedNotifier<ControleLayout> {
  const _EscopoLayout({required ControleLayout controle, required super.child})
    : super(notifier: controle);
}

class RegistroLayout {
  RegistroLayout(this.nome, this.capturar, this.pais);
  final String nome;
  final Map<String, dynamic> Function() capturar;
  final List<String> pais;
  bool Function(Offset)? contemPonto;
}

/// Separadores reais: o espaço de um par pode substituir o padrão do grupo.
String? identidadeWidget(Widget w) {
  try {
    final id = (w as dynamic).idLayout;
    if (id is String) return id;
  } on NoSuchMethodError {
    /* Widget nativo sem identificador de layout. */
  }
  if (w.key is ValueKey) return (w.key as ValueKey).value.toString();
  final Widget? filho = switch (w) {
    Flexible v => v.child,
    Padding v => v.child,
    Align v => v.child,
    SizedBox v => v.child,
    Container v => v.child,
    ConstrainedBox v => v.child,
    KeyedSubtree v => v.child,
    Visibility v => v.child,
    Tooltip v => v.child,
    _ => null,
  };
  return filho == null ? null : identidadeWidget(filho);
}

List<Widget> comEspacosLayout(
  BuildContext context,
  List<Widget> filhos, {
  required String id,
  required Axis eixo,
  required double espaco,
  bool separadores = true,
}) {
  final controle = context
      .dependOnInheritedWidgetOfExactType<_EscopoLayout>()
      ?.notifier;
  if (controle == null) return filhos;
  final novo = !controle.grupos.containsKey(id);
  final mudou = !listEquals(controle.grupos[id], filhos);
  if (mudou) {
    controle.grupos[id] = filhos;
    for (final chave in controle.chavesGrupos[id] ?? <String>[]) {
      controle.itens.remove(chave);
    }
    final chaves = <String>[];
    for (var i = 0; i < filhos.length; i++) {
      final identidade = identidadeWidget(filhos[i]);
      var chave =
          '$id.item.${identidade == null ? i : Uri.encodeComponent(identidade)}';
      if (chaves.contains(chave)) chave = '$chave.$i';
      chaves.add(chave);
      controle.itens[chave] = filhos[i];
    }
    controle.chavesGrupos[id] = chaves;
  }
  controle.eixos[id] = eixo;
  // Só resolver referências na primeira montagem. Notificar a cada build
  // realimenta a reconstrução dos filhos e mantém a tela atualizando sem parar.
  if (novo && !controle.registroPendente) {
    controle.registroPendente = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controle.registroPendente = false;
      if (!controle.encerrado) controle.notificarGrupos();
    });
  }
  final ordem = controle.ordem(id).where((chave) {
    final item = controle.item(chave);
    return item != null && itensVisiveisLayout(context, [item]).isNotEmpty;
  }).toList();
  if (ordem.isEmpty && kDebugMode && controle.ativo) {
    return [
      DestinoLayout(
        grupo: id,
        indice: 0,
        eixo: eixo,
        child: const SizedBox(
          width: 96,
          height: 32,
          child: Center(
            child: Text(
              'Solte aqui',
              style: TextStyle(color: Colors.blue, fontSize: 12),
            ),
          ),
        ),
      ),
    ];
  }
  Widget elemento(int i) {
    final chave = ordem[i];
    Widget original = controle.item(chave)!;
    if (original is Spacer)
      original = Expanded(flex: original.flex, child: const SizedBox.shrink());
    final transferido = controle.grupoDoItem(chave) != id;
    if (original is Flexible &&
        transferido &&
        controle.eixos[controle.grupoDoItem(chave)] != eixo)
      original = original.child;
    Widget escopo(Widget w) => ItemLayoutScope(
      chave: chave,
      child: DestinoLayout(grupo: id, indice: i, eixo: eixo, child: w),
    );
    return KeyedSubtree(
      key: ValueKey(chave),
      child: original is Expanded
          ? Expanded(flex: original.flex, child: escopo(original.child))
          : original is Flexible
          ? Flexible(
              flex: original.flex,
              fit: original.fit,
              child: escopo(original.child),
            )
          : escopo(original),
    );
  }

  // Flexible precisa ser filho direto do Flex, inclusive através de um widget sem RenderObject.
  return [
    for (var i = 0; i < ordem.length; i++) ...[
      if (i > 0 && separadores)
        EspacoLayout(
          id: '$id.espaco.$i',
          grupo: id,
          indice: i,
          eixo: eixo,
          padrao: espaco,
        ),
      elemento(i),
    ],
  ];
}

class ItemLayoutScope extends InheritedWidget {
  const ItemLayoutScope({required this.chave, required super.child});
  final String chave;
  @override
  bool updateShouldNotify(ItemLayoutScope oldWidget) =>
      chave != oldWidget.chave;
}

class DestinoLayout extends StatelessWidget {
  const DestinoLayout({
    super.key,
    required this.grupo,
    required this.indice,
    required this.eixo,
    required this.child,
  });
  final String grupo;
  final int indice;
  final Axis eixo;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final controle = context
        .dependOnInheritedWidgetOfExactType<_EscopoLayout>()
        ?.notifier;
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) =>
          controle?.ativo == true && controle!.podeMover(d.data, grupo),
      onAcceptWithDetails: (d) {
        final box = context.findRenderObject() as RenderBox;
        final p = box.globalToLocal(d.offset);
        final apos = eixo == Axis.horizontal
            ? p.dx > box.size.width / 2
            : p.dy > box.size.height / 2;
        controle!.moverItem(d.data, grupo, indice + (apos ? 1 : 0));
      },
      builder: (c, candidatos, rejeitados) => Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          if (candidatos.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.orange, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class EspacoLayout extends StatelessWidget {
  const EspacoLayout({
    super.key,
    required this.id,
    required this.grupo,
    required this.indice,
    required this.eixo,
    required this.padrao,
  });
  final String id, grupo;
  final int indice;
  final Axis eixo;
  final double padrao;
  @override
  Widget build(BuildContext context) {
    final controle = context
        .dependOnInheritedWidgetOfExactType<_EscopoLayout>()
        ?.notifier;
    final espaco = ajusteLayout(context, id).espaco ?? padrao;
    return Builder(
      builder: (c) {
        if (controle != null && controle.ativo && kDebugMode) {
          final registro = RegistroLayout(
            'Espaço entre itens $indice e ${indice + 1}',
            () => {'tipo': 'espaco', 'espaco': espaco},
            [grupo],
          );
          registro.contemPonto = (ponto) {
            final box = c.mounted ? c.findRenderObject() : null;
            if (box is! RenderBox || !box.hasSize || espaco == 0) return false;
            final p = box.globalToLocal(ponto);
            return eixo == Axis.horizontal
                ? p.dx >= 0 && p.dx < espaco
                : p.dy >= 0 && p.dy < espaco;
          };
          controle.registros[id] = registro;
          if (controle.selecionado == id)
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => controle.atualizarCaptura(id),
            );
        }
        return SizedBox(
          width: eixo == Axis.horizontal ? espaco : 0,
          height: eixo == Axis.vertical ? espaco : 0,
        );
      },
    );
  }
}

Map<String, dynamic> propriedadesTexto(
  BuildContext context,
  String texto, {
  TextStyle? estilo,
  Color? cor,
  TextAlign alinhamento = TextAlign.start,
}) {
  final s = DefaultTextStyle.of(context).style.merge(estilo);
  return {
    'texto': texto,
    'tamanhoFonte':
        s.fontSize ?? Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14,
    'fonte':
        s.fontFamily ??
        Theme.of(context).textTheme.bodyMedium?.fontFamily ??
        'Roboto',
    'negrito': (s.fontWeight?.value ?? 400) >= 600,
    'italico': s.fontStyle == FontStyle.italic,
    'sublinhado': s.decoration?.contains(TextDecoration.underline) ?? false,
    'cor':
        cor?.toARGB32() ??
        s.color?.toARGB32() ??
        Theme.of(context).colorScheme.onSurface.toARGB32(),
    'alinhamento': alinhamento.name,
  };
}

class EntradaLayout extends StatefulWidget {
  const EntradaLayout({
    super.key,
    required this.valor,
    required this.rotulo,
    required this.onChanged,
    this.numerico = false,
    this.variasLinhas = false,
  });
  final String valor;
  final String rotulo;
  final ValueChanged<String> onChanged;
  final bool numerico;
  final bool variasLinhas;
  @override
  State<EntradaLayout> createState() => _EntradaLayoutState();
}

class _EntradaLayoutState extends State<EntradaLayout> {
  late final c = TextEditingController(text: widget.valor);
  final f = FocusNode();
  @override
  void initState() {
    super.initState();
    f.addListener(_foco);
  }

  void _foco() {
    if (!f.hasFocus && c.text != widget.valor) c.text = widget.valor;
  }

  @override
  void didUpdateWidget(EntradaLayout old) {
    super.didUpdateWidget(old);
    if (!f.hasFocus && c.text != widget.valor) c.text = widget.valor;
  }

  @override
  void dispose() {
    f.removeListener(_foco);
    f.dispose();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: c,
    focusNode: f,
    keyboardType: widget.numerico
        ? const TextInputType.numberWithOptions(decimal: true)
        : widget.variasLinhas
        ? TextInputType.multiline
        : TextInputType.text,
    minLines: 1,
    maxLines: widget.variasLinhas ? 4 : 1,
    decoration: InputDecoration(
      labelText: widget.rotulo,
      hintText: 'Padrão da tela',
      border: const ContornoCampo(),
    ),
    onChanged: widget.onChanged,
  );
}

class GrupoLayoutScope extends InheritedWidget {
  const GrupoLayoutScope({super.key, required this.id, required super.child});
  final String id;
  @override
  bool updateShouldNotify(GrupoLayoutScope old) => old.id != id;
}

AjusteLayout ajusteLayout(BuildContext context, String? id) {
  if (id == null) return const AjusteLayout();
  return context
          .dependOnInheritedWidgetOfExactType<_EscopoLayout>()
          ?.notifier
          ?.de(id) ??
      const AjusteLayout();
}

Widget alvoLayout(
  BuildContext context,
  Widget child, {
  required String? id,
  required String nome,
  Map<String, dynamic> propriedades = const {},
  String tipo = 'texto',
  bool grupo = false,
}) {
  if (tipo == 'texto' &&
      ajusteLayout(context, id).oculto &&
      (!kDebugMode ||
          !(context
                  .dependOnInheritedWidgetOfExactType<_EscopoLayout>()
                  ?.notifier
                  ?.ativo ??
              false)))
    return const SizedBox.shrink();
  if (!kDebugMode || id == null) return child;
  final controle = context
      .dependOnInheritedWidgetOfExactType<_EscopoLayout>()
      ?.notifier;
  // Grupos mantêm a árvore estável para não recriar abas/controladores ao abrir o editor.
  if (controle == null || (!controle.ativo && !grupo)) return child;
  return Builder(
    builder: (alvoContext) {
      Map<String, dynamic> capturar() {
        final box = alvoContext.mounted ? alvoContext.findRenderObject() : null;
        final size = box is RenderBox && box.hasSize ? box.size : null;
        return {
          'tipo': tipo,
          'largura': size?.width,
          'altura': size?.height,
          ...propriedades,
        };
      }

      final pais = <String>[];
      alvoContext.visitAncestorElements((e) {
        if (e.widget is GrupoLayoutScope) {
          final pai = (e.widget as GrupoLayoutScope).id;
          if (pai != id && !pais.contains(pai)) pais.add(pai);
        }
        return true;
      });
      controle.registros[id] = RegistroLayout(nome, capturar, pais);
      if (controle.selecionado == id)
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => controle.atualizarCaptura(id),
        );
      final a = controle.de(id);
      final conteudo = tipo == 'texto' && a.oculto
          ? const SizedBox(
              width: 100,
              height: 24,
              child: Text(
                '(texto excluído)',
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
            )
          : child;
      final alvo = MouseRegion(
        cursor: controle.ativo ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: !controle.ativo
              ? null
              : (detalhes) {
                  FocusScope.of(alvoContext).unfocus();
                  if (grupo) {
                    for (final entrada in controle.registros.entries) {
                      final r = entrada.value;
                      if (r.pais.firstOrNull == id &&
                          (r.contemPonto?.call(detalhes.globalPosition) ??
                              false)) {
                        controle.selecionar(entrada.key, r.nome);
                        return;
                      }
                    }
                  }
                  controle.selecionar(id, nome);
                },
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              IgnorePointer(
                ignoring: controle.ativo && !grupo,
                child: conteudo,
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: !controle.ativo
                            ? Colors.transparent
                            : controle.selecionado == id
                            ? Colors.blue
                            : Colors.blue.withValues(alpha: 0.3),
                        width: controle.ativo && controle.selecionado == id
                            ? 2
                            : 1,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      final item = alvoContext
          .dependOnInheritedWidgetOfExactType<ItemLayoutScope>()
          ?.chave;
      if (grupo)
        return DestinoLayout(
          grupo: id,
          indice: controle.ordem(id).length,
          eixo: controle.eixos[id] ?? Axis.vertical,
          child: alvo,
        );
      if (item == null) return alvo;
      return Draggable<String>(
        data: item,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        maxSimultaneousDrags: controle.ativo ? 1 : 0,
        onDragStarted: () {
          controle.arrastando = item;
        },
        onDragEnd: (_) {
          controle.arrastando = null;
        },
        feedback: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.open_with),
                const SizedBox(width: 8),
                Text(nome, style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
        ),
        child: alvo,
      );
    },
  );
}

class ElementoLayoutGenerico extends StatelessWidget {
  const ElementoLayoutGenerico({
    super.key,
    required this.idLayout,
    required this.child,
    this.width,
    this.height,
    this.textoOriginal,
  });
  final String idLayout;
  final Widget child;
  final double? width;
  final double? height;
  final String? textoOriginal;
  @override
  Widget build(BuildContext context) {
    final a = ajusteLayout(context, idLayout);
    final theme = Theme.of(context);
    ButtonStyle estilo(ButtonStyle? b) => (b ?? const ButtonStyle()).copyWith(
      alignment: a.alinhamentoBotao,
      foregroundColor: a.cor == null ? null : WidgetStatePropertyAll(a.cor),
      textStyle: WidgetStatePropertyAll(
        a.estilo(
          b?.textStyle?.resolve({}) ??
              theme.textTheme.labelLarge ??
              const TextStyle(),
        ),
      ),
    );
    final conteudo = a.temFonte || a.alinhamento != null
        ? Theme(
            data: theme.copyWith(
              filledButtonTheme: FilledButtonThemeData(
                style: estilo(theme.filledButtonTheme.style),
              ),
              textButtonTheme: TextButtonThemeData(
                style: estilo(theme.textButtonTheme.style),
              ),
              outlinedButtonTheme: OutlinedButtonThemeData(
                style: estilo(theme.outlinedButtonTheme.style),
              ),
            ),
            child: child,
          )
        : child;
    return alvoLayout(
      context,
      SizedBox(
        width: a.largura ?? width,
        height: a.altura ?? height,
        child: conteudo,
      ),
      id: idLayout,
      nome: 'Botão',
      tipo: 'botao',
      propriedades: propriedadesTexto(
        context,
        a.exibir(textoOriginal ?? ''),
        alinhamento: a.alinhamento ?? TextAlign.center,
        estilo: a.estilo(
          theme.filledButtonTheme.style?.textStyle?.resolve({}) ??
              theme.textTheme.labelLarge ??
              const TextStyle(),
        ),
      ),
    );
  }
}

class EditorLayout extends StatefulWidget {
  const EditorLayout({super.key, required this.raiz, required this.child});
  final String raiz;
  final Widget child;
  @override
  State<EditorLayout> createState() => _EditorLayoutState();
}

class _EditorLayoutState extends State<EditorLayout> {
  final controle = ControleLayout();
  String mensagem = '';
  Offset? posicaoPainel;
  Size areaPainel = Size.zero;
  @override
  void reassemble() {
    super.reassemble();
    controle.fontes?.limpar();
    if (controle.selecionado != null) {
      try {
        controle.origem = controle.fontes?.localizar(
          controle.selecionado!,
          controle.nome,
        );
      } on FileSystemException {
        controle.origem = null;
      }
    }
  }

  void moverPainel(DragUpdateDetails d) {
    final largura = math.min(310.0, math.max(0.0, areaPainel.width - 16));
    final origem =
        posicaoPainel ?? Offset(math.max(8, areaPainel.width - largura - 8), 8);
    setState(
      () => posicaoPainel = Offset(
        (origem.dx + d.delta.dx).clamp(
          0.0,
          math.max(0.0, areaPainel.width - largura),
        ),
        (origem.dy + d.delta.dy).clamp(
          0.0,
          math.max(0.0, areaPainel.height - 120),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    controle.iniciar(widget.raiz);
  }

  @override
  void dispose() {
    controle.dispose();
    super.dispose();
  }

  Widget medida(String chave, String rotulo) {
    final valor = controle.atual(chave);
    return EntradaLayout(
      key: ValueKey('${controle.selecionado}:${controle.restauracoes}:$chave'),
      valor: valor is num && valor % 1 == 0
          ? valor.toInt().toString()
          : valor?.toString() ?? '',
      rotulo: rotulo,
      numerico: true,
      onChanged: (texto) {
        if (texto.trim().isEmpty) {
          controle.mudar(chave, null);
          return;
        }
        final numero = double.tryParse(texto.replaceAll(',', '.'));
        if (numero != null &&
            numero.isFinite &&
            (chave.startsWith('espaco') ? numero >= 0 : numero > 0) &&
            numero <= 4000)
          controle.mudar(chave, numero);
      },
    );
  }

  Widget painel() => Material(
    elevation: 12,
    borderRadius: BorderRadius.circular(12),
    child: SizedBox(
      width: 310,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          // Reserva uma calha para a barra sem cobrir campos ou setas das listas.
          padding: const EdgeInsets.only(right: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Row(
                children: [
                  Expanded(
                    child: MouseRegion(
                      cursor: SystemMouseCursors.move,
                      child: GestureDetector(
                        key: const ValueKey('layout.arrastarPainel'),
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: moverPainel,
                        child: const Row(
                          children: [
                            Icon(Icons.drag_indicator),
                            Expanded(
                              child: Text(
                                'Editar layout',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Sair da edição',
                    onPressed: controle.alternar,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (controle.selecionado == null)
                const Text(
                  'Arraste o título para mover este painel. Clique no elemento ou no espaço entre itens para editar.',
                ),
              if (controle.selecionado != null) ...[
                Text(
                  controle.nome,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  controle.origem == null
                      ? 'Arquivo: origem não localizada'
                      : 'Arquivo: ${controle.origem!.relativo}:${controle.origem!.linha}',
                  style: const TextStyle(fontSize: 11),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('layout.open'),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open'),
                  onPressed: controle.origem == null
                      ? null
                      : () async {
                          try {
                            await controle.origem!.abrir();
                          } catch (e) {
                            if (mounted)
                              setState(
                                () => mensagem = 'Não foi possível abrir: $e',
                              );
                          }
                        },
                ),
                if (controle.pais.isNotEmpty)
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    key: ValueKey(
                      '${controle.selecionado}:${controle.selecoes}:pais',
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Selecionar grupo / janela',
                    ),
                    items: [
                      for (final (indice, id) in controle.pais.indexed)
                        DropdownMenuItem(
                          value: id,
                          child: Text(
                            '${controle.registros[id]?.nome ?? 'Grupo'} · nível ${indice + 1}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null) controle.selecionarPai(id);
                    },
                  ),
                if (controle.propriedades.containsKey('texto')) ...[
                  EntradaLayout(
                    key: ValueKey(
                      '${controle.selecionado}:${controle.restauracoes}:texto',
                    ),
                    valor: controle.atual('texto')?.toString() ?? '',
                    rotulo: 'Texto',
                    variasLinhas: true,
                    onChanged: (s) {
                      controle.mudar('texto', s);
                      controle.mudar('oculto', s.isEmpty);
                    },
                  ),
                  OutlinedButton.icon(
                    onPressed: () => controle.mudar(
                      'oculto',
                      !controle.de(controle.selecionado!).oculto,
                    ),
                    icon: Icon(
                      controle.de(controle.selecionado!).oculto
                          ? Icons.visibility
                          : Icons.delete_outline,
                    ),
                    label: Text(
                      controle.de(controle.selecionado!).oculto
                          ? 'Mostrar texto novamente'
                          : 'Excluir texto',
                    ),
                  ),
                ],
                if (![
                  'grupo',
                  'janela',
                  'espaco',
                ].contains(controle.propriedades['tipo'])) ...[
                  medida('tamanhoFonte', 'Tamanho da fonte (pontos)'),
                  EntradaLayout(
                    key: ValueKey(
                      '${controle.selecionado}:${controle.restauracoes}:fonte',
                    ),
                    valor: controle.atual('fonte')?.toString() ?? '',
                    rotulo: 'Família da fonte',
                    onChanged: (s) => controle.mudar(
                      'fonte',
                      s.trim().isEmpty ? null : s.trim(),
                    ),
                  ),
                ],
                if (controle.propriedades['tipo'] != 'espaco') ...[
                  medida('largura', 'Largura (pontos)'),
                  if (controle.propriedades['alturaUniforme'] != true)
                    medida('altura', 'Altura (pontos)')
                  else
                    const Text(
                      'Altura padrão: ${Medida.campo} pontos. Altere Medida.campo em estilo.dart.',
                    ),
                ],
                if (controle.propriedades.containsKey('alinhamento'))
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    key: ValueKey(
                      '${controle.selecionado}:${controle.restauracoes}:alinhamento',
                    ),
                    initialValue:
                        controle.atual('alinhamento')?.toString() ?? 'start',
                    decoration: const InputDecoration(
                      labelText: 'Alinhamento do texto',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'left', child: Text('Esquerda')),
                      DropdownMenuItem(value: 'center', child: Text('Centro')),
                      DropdownMenuItem(value: 'right', child: Text('Direita')),
                      DropdownMenuItem(
                        value: 'justify',
                        child: Text('Justificado'),
                      ),
                      DropdownMenuItem(value: 'start', child: Text('Início')),
                      DropdownMenuItem(value: 'end', child: Text('Fim')),
                    ],
                    onChanged: (v) => controle.mudar('alinhamento', v),
                  ),
                if (controle.propriedades.containsKey('espaco'))
                  medida('espaco', 'Espaço entre objetos (pontos)'),
                if (controle.propriedades['tipo'] == 'grupo' &&
                    controle.registros.entries.any(
                      (e) =>
                          e.value.contemPonto != null &&
                          e.value.pais.firstOrNull == controle.selecionado,
                    ))
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      '${controle.selecionado}:${controle.selecoes}:intervalo',
                    ),
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Selecionar espaço entre itens',
                    ),
                    items: [
                      for (final e in controle.registros.entries)
                        if (e.value.contemPonto != null &&
                            e.value.pais.firstOrNull == controle.selecionado)
                          DropdownMenuItem(
                            value: e.key,
                            child: Text(
                              e.value.nome,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                    ],
                    onChanged: (id) {
                      if (id != null) controle.selecionarPai(id);
                    },
                  ),
                if (controle.propriedades.containsKey('espacoLinhas'))
                  medida('espacoLinhas', 'Espaço entre linhas (pontos)'),
                if (![
                  'grupo',
                  'janela',
                  'espaco',
                ].contains(controle.propriedades['tipo'])) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Negrito'),
                    value: controle.atual('negrito') == true,
                    onChanged: (v) => controle.mudar('negrito', v),
                  ),
                  for (final (chave, titulo) in [
                    ('italico', 'Itálico'),
                    ('sublinhado', 'Sublinhado'),
                  ])
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(titulo),
                      value: controle.atual(chave) == true,
                      onChanged: (v) => controle.mudar(chave, v),
                    ),
                  EntradaLayout(
                    key: ValueKey(
                      '${controle.selecionado}:${controle.restauracoes}:cor',
                    ),
                    valor:
                        '#${((controle.atual('cor') as int?) ?? 0xFF000000).toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                    rotulo: 'Cor da fonte (#RRGGBB)',
                    onChanged: (s) {
                      final hex = s.trim().replaceFirst('#', '');
                      if (hex.isEmpty) {
                        controle.mudar('cor', null);
                        return;
                      }
                      if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex))
                        controle.mudar(
                          'cor',
                          0xFF000000 | int.parse(hex, radix: 16),
                        );
                    },
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (nome, cor) in [
                        ('Preto', 0xFF000000),
                        ('Branco', 0xFFFFFFFF),
                        ('Vermelho', 0xFFF44336),
                        ('Azul', 0xFF2196F3),
                        ('Verde', 0xFF4CAF50),
                        ('Cinza', 0xFF757575),
                      ])
                        Tooltip(
                          message: nome,
                          child: InkWell(
                            onTap: () => controle.mudar('cor', cor),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Color(cor),
                                border: Border.all(color: Colors.grey),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                OutlinedButton.icon(
                  onPressed: () {
                    controle.restaurar();
                    setState(() {});
                  },
                  icon: const Icon(Icons.restore),
                  label: const Text('Restaurar este elemento'),
                ),
              ],
              FilledButton.icon(
                onPressed: () async {
                  try {
                    await controle.salvar();
                    if (mounted)
                      setState(() => mensagem = 'Ajustes salvos no projeto.');
                  } catch (e) {
                    if (mounted)
                      setState(() => mensagem = 'Não foi possível salvar: $e');
                  }
                },
                icon: const Icon(Icons.save),
                label: const Text('Salvar ajustes'),
              ),
              if (controle.ajustes.values.any((v) => v.containsKey('ordem')))
                OutlinedButton.icon(
                  onPressed: controle.restaurarPosicoes,
                  icon: const Icon(Icons.undo),
                  label: const Text('Restaurar posições'),
                ),
              if (mensagem.isNotEmpty) Text(mensagem),
              if (controle.erroInicial != null) Text(controle.erroInicial!),
              const Text(
                'As propriedades atuais são carregadas ao selecionar. Vazio restaura o padrão. Salve para manter após fechar.',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => _EscopoLayout(
    controle: controle,
    child: AnimatedBuilder(
      animation: controle,
      builder: (context, _) => Overlay.wrap(
        child: LayoutBuilder(
          builder: (context, limites) {
            areaPainel = limites.biggest;
            final largura = math.min(
              310.0,
              math.max(0.0, areaPainel.width - 16),
            );
            final x = (posicaoPainel?.dx ?? areaPainel.width - largura - 8)
                .clamp(0.0, math.max(0.0, areaPainel.width - largura));
            final y = (posicaoPainel?.dy ?? 8.0).clamp(
              0.0,
              math.max(0.0, areaPainel.height - 120),
            );
            return Stack(
              children: [
                Positioned.fill(child: widget.child),
                if (kDebugMode && !controle.ativo)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      elevation: 3,
                      borderRadius: BorderRadius.circular(12),
                      child: TextButton.icon(
                        onPressed: controle.alternar,
                        icon: const Icon(Icons.design_services),
                        label: const Text('Editar layout'),
                      ),
                    ),
                  ),
                if (kDebugMode && controle.ativo)
                  Positioned(
                    key: const ValueKey('layout.painel'),
                    top: y.toDouble(),
                    left: x.toDouble(),
                    width: largura,
                    height: math.max(0.0, areaPainel.height - y - 8),
                    // O editor fica acima do Navigator do aplicativo. As listas
                    // precisam de um Navigator próprio para abrir sobre o painel.
                    child: HeroControllerScope.none(
                      child: Navigator(
                        onGenerateRoute: (_) => PageRouteBuilder<void>(
                          transitionDuration: Duration.zero,
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  AnimatedBuilder(
                                    animation: controle,
                                    builder: (context, _) => Align(
                                      alignment: Alignment.topLeft,
                                      child: painel(),
                                    ),
                                  ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
