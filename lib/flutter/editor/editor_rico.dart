import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'barra.dart';
import 'caixa.dart';
import 'colar.dart';
import 'paleta_cores.dart';

/// Editor de texto rico embutido na tela (flutter_quill).
///
/// [valor] é o documento em Delta JSON (lista de operações do Quill). Edição do usuário ->
/// [aoMudar] com o Delta novo; [valor] trocado por quem montou a tela -> documento
/// substituído, sem ecoar de volta.
class EditorRico extends StatefulWidget {
  const EditorRico({
    super.key,
    required this.valor,
    this.aoMudar,
    this.bloqueado = false,
    this.placeholder,
    this.fontes = const [],
    this.tamanhos = const [],
    this.fontePadrao,
    this.tamanhoPadrao,
    this.variaveis = const [],
    this.largura,
    this.altura,
  });

  final String valor;
  final ValueChanged<String>? aoMudar;

  /// Card travado: a caixa fica acinzentada e não recebe mouse nem foco.
  final bool bloqueado;

  /// Texto exibido com o documento vazio.
  final String? placeholder;

  /// Famílias oferecidas no seletor de fonte.
  final List<String> fontes;

  /// Tamanhos oferecidos no seletor, em px sem unidade ("10", "12", "24").
  final List<String> tamanhos;

  /// Fonte/tamanho do texto sem formatação própria ("Arial"/"16").
  final String? fontePadrao;
  final String? tamanhoPadrao;

  /// Textos do menu "Inserir variável" (ex.: "{numero}"). Vazio = sem o menu.
  final List<String> variaveis;
  final double? largura;
  final double? altura;

  @override
  State<EditorRico> createState() => _EditorRicoState();
}

class _EditorRicoState extends State<EditorRico> {
  late final QuillController _controller;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// Último `valor` trocado com a tela, do jeito que foi trocado (JSON de quem montou ao
  /// receber, do editor ao enviar). Serve para perceber quando a TELA mudou o documento.
  String _ultimoValor = "";

  /// O mesmo documento serializado PELO EDITOR. O documento atual é comparado com este:
  /// comparar com o JSON recebido acusaria mudança só por diferença de serialização.
  String _ultimoValorDart = "";

  Timer? _atraso;
  bool _restaurando = false;

  @override
  void initState() {
    super.initState();
    _ultimoValor = widget.valor;
    _controller = QuillController(
      document: _documentoDe(_ultimoValor),
      selection: const TextSelection.collapsed(offset: 0),
      onReplaceText: aceitarSubstituicao,
      config: QuillControllerConfig(
        // Colar só com a formatação que a barra oferece (ver colar.dart).
        // ignore: experimental_member_use
        clipboardConfig: QuillClipboardConfig(
          // ignore: experimental_member_use
          onRichTextPaste: (delta, isExternal) async => filtrarColado(
            delta,
            fontes: widget.fontes,
            tamanhos: widget.tamanhos,
            fontePadrao: widget.fontePadrao,
            tamanhoPadrao: widget.tamanhoPadrao,
          ),
        ),
      ),
    );
    _ultimoValorDart = _valorAtual();
    _controller.addListener(_aoMudar);
    // Perder o foco (ex.: clicar em "Salvar") envia na hora o que estiver pendente, para a
    // tela não gravar sem as últimas teclas.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _enviarAgora();
    });
  }

  @override
  void dispose() {
    _atraso?.cancel();
    _controller.removeListener(_aoMudar);
    _controller.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Document _documentoDe(String valor) {
    try {
      if (valor.trim().isNotEmpty) {
        final dados = jsonDecode(valor);
        final ops = dados is Map ? dados["ops"] : dados;
        if (ops is List && ops.isNotEmpty) {
          return Document.fromJson(ops);
        }
      }
    } catch (e) {
      debugPrint("EditorRico: Delta inválido ignorado: $e");
    }
    return Document();
  }

  String _valorAtual() => jsonEncode(_controller.document.toDelta().toJson());

  void _substituirDocumento(String valor) {
    _controller.removeListener(_aoMudar);
    _controller.document = _documentoDe(valor);
    _ultimoValorDart = _valorAtual();
    _controller.addListener(_aoMudar);
  }

  void _aoMudar() {
    if (_controller.readOnly) {
      // Card TRAVADO: no flutter_quill 11.5.1 os atalhos de teclado (Ctrl+B, Ctrl+Z, recuo...)
      // alteram o documento mesmo com readOnly. Desfaz na hora e não envia nada — senão a
      // alteração acidental ia junto no próximo Salvar. Trocar o documento também zera o
      // histórico: um Ctrl+Z depois de salvar não traz a versão antiga de volta.
      if (!_restaurando && _valorAtual() != _ultimoValorDart) {
        _restaurando = true;
        scheduleMicrotask(() {
          if (mounted) {
            _substituirDocumento(_ultimoValor);
            setState(() {}); // barra remontada no documento novo (desfazer/refazer)
          }
          _restaurando = false;
        });
      }
      return;
    }
    // O listener também dispara em mudança de seleção; _enviarAgora descarta o que não mudou
    // o documento.
    _atraso?.cancel();
    _atraso = Timer(const Duration(milliseconds: 200), _enviarAgora);
  }

  void _enviarAgora() {
    _atraso?.cancel();
    if (!mounted || _controller.readOnly) return;
    final valor = _valorAtual();
    if (valor == _ultimoValorDart) return;
    _ultimoValor = valor;
    _ultimoValorDart = valor;
    widget.aoMudar?.call(valor);
  }

  void _inserir(String texto) {
    final sel = _controller.selection;
    final fim = _controller.document.length - 1;
    final inicio = sel.isValid ? sel.start.clamp(0, fim) : fim;
    final tamanho = sel.isValid ? (sel.end - sel.start).clamp(0, fim - inicio) : 0;
    _controller.replaceText(
      inicio,
      tamanho,
      texto,
      TextSelection.collapsed(offset: inicio + texto.length),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.valor != _ultimoValor) {
      // Mudança vinda da tela (outro prestador, edição descartada...).
      _ultimoValor = widget.valor;
      _substituirDocumento(widget.valor);
    }

    final bloqueado = widget.bloqueado;
    _controller.readOnly = bloqueado;
    if (_focusNode.canRequestFocus == bloqueado) {
      // Travou ou destravou: travado não recebe foco (nem pelo Tab) e perde o que tinha.
      // Aplicado depois do frame — mexer em foco durante o build não é seguro.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.canRequestFocus = !widget.bloqueado;
      });
    }

    final fontePadrao = widget.fontePadrao;

    final barra = construirBarra(
      controller: _controller,
      fontes: widget.fontes,
      tamanhos: widget.tamanhos,
      fontePadrao: fontePadrao,
      tamanhoPadrao: widget.tamanhoPadrao,
      variaveis: widget.variaveis,
      aoInserirVariavel: _inserir,
      // Paleta própria: o diálogo de cor do flutter_quill quebra sem as traduções dele
      // no Navigator do app (ver paleta_cores.dart).
      aoEscolherCor: (c, fundo) => escolherCor(context, c, fundo),
      aoFormatar: _focusNode.requestFocus,
    );

    final editor = QuillEditor(
      controller: _controller,
      focusNode: _focusNode,
      scrollController: _scroll,
      config: QuillEditorConfig(
        placeholder: widget.placeholder,
        padding: const EdgeInsets.all(12),
        scrollable: true,
        expands: false,
        autoFocus: false,
        // Texto sem fonte/tamanho próprios = o padrão que a barra mostra e o e-mail usa.
        customStyles: estilosPadraoEditor(
          context,
          fonte: fontePadrao,
          tamanho: widget.tamanhoPadrao,
        ),
      ),
    );

    final Widget caixa = Localizations.override(
      context: context,
      delegates: const [FlutterQuillLocalizations.delegate],
      child: CaixaEditor(
        bloqueado: bloqueado,
        barra: barra,
        // Listas/títulos de HTML antigo também na fonte padrão (o estilo de parágrafo só
        // cobre as linhas comuns).
        texto: fontePadrao == null
            ? editor
            : DefaultTextStyle.merge(style: TextStyle(fontFamily: fontePadrao), child: editor),
      ),
    );
    return (widget.largura == null && widget.altura == null)
        ? caixa
        : SizedBox(width: widget.largura, height: widget.altura, child: caixa);
  }
}
