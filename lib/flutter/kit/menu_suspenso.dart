/// A lista suspensa do Material (campo + menu), com o MESMO desenho e o mesmo comportamento da
/// `DropdownMenu` do Flutter 3.44 — o estado e a montagem abaixo seguem o original passo a
/// passo — mas PREGUIÇOSA:
///
/// - fechada, não monta item nenhum (a original montava e media TODOS os itens de cada lista,
///   escondidos, só para calcular uma largura que aqui é sempre dada);
/// - aberta, monta apenas os itens que estão à vista. A altura de cada item é calculada pelo
///   texto (a mesma conta que o botão do menu faz), de modo que a rolagem, a barra e a altura
///   do menu saem iguais às de uma lista inteira.
///
/// Uma lista de 900 itens abre, filtra e fecha no tempo de uma de 5.
//
// Partes copiadas de flutter/lib/src/material/dropdown_menu.dart:
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license.
library;

import 'contorno_campo.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'formatos.dart';

const double _kDefaultHorizontalPadding = 12.0;
const double _kInputStartGap = 4.0;

/// Um item da lista.
class ItemSuspenso {
  ItemSuspenso({
    required this.value,
    required this.label,
    this.enabled = true,
    this.naLista,
  });
  final String value;

  /// O que o campo mostra com este item escolhido (e por onde o filtro procura).
  final String label;
  final bool enabled;

  /// O que a lista aberta mostra, quando difere de [label].
  final String? naLista;

  // Como a BUSCA enxerga o item: pelo que ele mostra ou pelo código.
  late final TextoDeBusca busca = TextoDeBusca(label);
  late final String codigo = buscaCompacta(value);

  /// O item casa com o que foi digitado? [consulta] é o texto digitado sem espaços nem
  /// pontuação; [termos], as palavras dele.
  bool casa(String consulta, List<String> termos) =>
      busca.casa(consulta, termos) || codigo.contains(consulta);
}

/// Mede de antemão, aos poucos e só com a tela parada, a altura dos itens de uma lista
/// GRANDE cujo menu tem largura fixa ([larguraMenu]) — os catálogos. Sem isto a primeira
/// abertura da lista mediria os seus centenas de textos de uma vez.
void aquecerMenuSuspenso(
  BuildContext context,
  List<String> rotulos, {
  required double larguraMenu,
}) {
  // O menu de largura fixa usa a densidade do tema: é a assinatura que ele mesmo vai ler.
  final _Assinatura s = _Assinatura.de(context);
  final _Medidor medidor = _Medidor.para(
    s,
    math.max(0.0, larguraMenu - s.descontoHorizontal),
    fixo: true,
  );
  int i = 0;
  void fatia() {
    final Stopwatch relogio = Stopwatch()..start();
    while (i < rotulos.length && relogio.elapsedMicroseconds < 2500) {
      medidor.altura(rotulos[i++]);
    }
    medidor.fim();
    if (i < rotulos.length) {
      SchedulerBinding.instance.scheduleTask<void>(fatia, Priority.idle);
    }
  }

  SchedulerBinding.instance.scheduleTask<void>(fatia, Priority.idle);
}

class MenuSuspenso extends StatefulWidget {
  const MenuSuspenso({
    super.key,
    this.enabled = true,
    required this.width,
    this.menuHeight,
    this.menuWidth,
    this.label,
    this.hintText,
    this.enableFilter = false,
    this.enableSearch = true,
    this.textStyle,
    this.textAlign = TextAlign.start,
    this.inputDecorationTheme,
    required this.controller,
    this.initialSelection,
    this.onSelected,
    required this.focusNode,
    required this.entries,
  });

  final bool enabled;
  final double width;
  final double? menuHeight;

  /// Largura fixa do menu (nula = a do campo).
  final double? menuWidth;
  final Widget? label;
  final String? hintText;
  final bool enableFilter;
  final bool enableSearch;
  final TextStyle? textStyle;
  final TextAlign textAlign;
  final InputDecorationThemeData? inputDecorationTheme;
  final TextEditingController controller;
  final String? initialSelection;
  final ValueChanged<String?>? onSelected;
  final FocusNode focusNode;
  final List<ItemSuspenso> entries;

  @override
  State<MenuSuspenso> createState() => _MenuSuspensoState();
}

class _MenuSuspensoState extends State<MenuSuspenso> {
  static const Map<ShortcutActivator, Intent> _editableShortcuts =
      <ShortcutActivator, Intent>{
        SingleActivator(
          LogicalKeyboardKey.arrowLeft,
        ): ExtendSelectionByCharacterIntent(
          forward: false,
          collapseSelection: true,
        ),
        SingleActivator(
          LogicalKeyboardKey.arrowRight,
        ): ExtendSelectionByCharacterIntent(
          forward: true,
          collapseSelection: true,
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): _ArrowUpIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): _ArrowDownIntent(),
      };

  final GlobalKey _anchorKey = GlobalKey();
  final GlobalKey<_ItensPreguicososState> _chaveItens =
      GlobalKey<_ItensPreguicososState>();
  late MenuController _controller;
  bool _enableFilter = false;
  late bool _enableSearch;
  late List<ItemSuspenso> filteredEntries;
  int? currentHighlight;
  bool _menuHasEnabledItem = false;
  TextEditingController get _effectiveTextEditingController =>
      widget.controller;
  final FocusNode _internalFocusNode = FocusNode();
  WidgetStatesController? _highlightedItemStatesController;
  final FocusNode _trailingIconButtonFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _enableSearch = widget.enableSearch;
    filteredEntries = widget.entries;
    _menuHasEnabledItem = filteredEntries.any(
      (ItemSuspenso entry) => entry.enabled,
    );
    final int index = filteredEntries.indexWhere(
      (ItemSuspenso entry) => entry.value == widget.initialSelection,
    );
    if (index != -1) {
      _effectiveTextEditingController.value = TextEditingValue(
        text: filteredEntries[index].label,
        selection: TextSelection.collapsed(
          offset: filteredEntries[index].label.length,
        ),
      );
    }
    _controller = MenuController();
  }

  @override
  void dispose() {
    _internalFocusNode.dispose();
    _trailingIconButtonFocusNode.dispose();
    _highlightedItemStatesController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MenuSuspenso oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enableFilter != widget.enableFilter) {
      if (!widget.enableFilter) {
        _enableFilter = false;
      }
    }
    if (oldWidget.enableSearch != widget.enableSearch) {
      if (!widget.enableSearch) {
        _enableSearch = widget.enableSearch;
        currentHighlight = null;
      }
    }
    // A original recebia uma lista de itens NOVA a cada montagem de quem a usa, e por isso
    // recomeçava daqui toda vez: continua assim, mesmo com a lista agora reaproveitada.
    currentHighlight = null;
    filteredEntries = widget.entries;
    _menuHasEnabledItem = filteredEntries.any(
      (ItemSuspenso entry) => entry.enabled,
    );
    if (oldWidget.initialSelection != widget.initialSelection) {
      final int index = filteredEntries.indexWhere(
        (ItemSuspenso entry) => entry.value == widget.initialSelection,
      );
      if (index != -1) {
        _effectiveTextEditingController.value = TextEditingValue(
          text: filteredEntries[index].label,
          selection: TextSelection.collapsed(
            offset: filteredEntries[index].label.length,
          ),
        );
      }
    }
  }

  bool canRequestFocus() => widget.focusNode.canRequestFocus;

  bool get isButton => !canRequestFocus();

  /// Traz o item realçado para o topo da área visível do menu (se o menu estiver aberto).
  void scrollToHighlight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final int? indice = currentHighlight;
      if (indice != null) {
        _chaveItens.currentState?.revelar(indice);
      }
    }, debugLabel: 'MenuSuspenso.scrollToHighlight');
  }

  List<ItemSuspenso> filter(
    List<ItemSuspenso> entries,
    TextEditingController textEditingController,
  ) {
    final List<String> termos = termosBusca(textEditingController.text);
    if (termos.isEmpty) {
      return entries;
    }
    final String consulta = termos.join();
    return entries
        .where((ItemSuspenso entry) => entry.casa(consulta, termos))
        .toList();
  }

  bool _shouldUpdateCurrentHighlight(List<ItemSuspenso> entries) {
    final List<String> termos = termosBusca(
      _effectiveTextEditingController.value.text,
    );
    if (termos.isEmpty) {
      return true;
    }

    // When `entries` are filtered by filter algorithm, currentHighlight may exceed the valid range of `entries` and should be updated.
    if (currentHighlight == null || currentHighlight! >= entries.length) {
      return true;
    }

    if (entries[currentHighlight!].casa(termos.join(), termos)) {
      return false;
    }

    return true;
  }

  int? search(
    List<ItemSuspenso> entries,
    TextEditingController textEditingController,
  ) {
    final List<String> termos = termosBusca(textEditingController.value.text);
    if (termos.isEmpty) {
      return null;
    }
    // O destaque vai para o código exato; senão, para o que COMEÇA pelo que foi digitado;
    // senão, para o primeiro que casa.
    final String consulta = termos.join();
    int index = entries.indexWhere(
      (ItemSuspenso entry) => entry.codigo == consulta,
    );
    if (index == -1) {
      index = entries.indexWhere(
        (ItemSuspenso entry) => entry.busca.junto.startsWith(consulta),
      );
    }
    if (index == -1) {
      index = entries.indexWhere(
        (ItemSuspenso entry) => entry.casa(consulta, termos),
      );
    }
    return index != -1 ? index : null;
  }

  /// O botão do item [i] de [entradas] — o mesmo que a original montava para todos de uma vez.
  Widget _botao(
    List<ItemSuspenso> entradas,
    int i,
    int? focusedIndex,
    bool useMaterial3,
  ) {
    final double effectiveInputStartGap = useMaterial3 ? _kInputStartGap : 0.0;
    final ItemSuspenso entry = entradas[i];

    const double padding = _kDefaultHorizontalPadding;
    ButtonStyle effectiveStyle = MenuItemButton.styleFrom(
      padding: const EdgeInsetsDirectional.only(
        start: padding,
        end: _kDefaultHorizontalPadding,
      ),
    );

    final ButtonStyle? themeStyle = MenuButtonTheme.of(context).style;

    final WidgetStateProperty<Color?>? effectiveForegroundColor =
        themeStyle?.foregroundColor;
    final WidgetStateProperty<Color?>? effectiveIconColor =
        themeStyle?.iconColor;
    final WidgetStateProperty<Color?>? effectiveOverlayColor =
        themeStyle?.overlayColor;
    final WidgetStateProperty<Color?>? effectiveBackgroundColor =
        themeStyle?.backgroundColor;

    // Simulate the focused state because the text field should always be focused
    // during traversal. Include potential MenuItemButton theme in the focus
    // simulation for all colors in the theme.
    final bool entryIsSelected = entry.enabled && i == focusedIndex;
    if (entryIsSelected) {
      final ButtonStyle defaultStyle = const MenuItemButton().defaultStyleOf(
        context,
      );

      Color? resolveFocusedColor(
        WidgetStateProperty<Color?>? colorStateProperty,
      ) {
        return colorStateProperty?.resolve(<WidgetState>{WidgetState.focused});
      }

      final Color focusedForegroundColor = resolveFocusedColor(
        effectiveForegroundColor ?? defaultStyle.foregroundColor!,
      )!;
      final Color focusedIconColor = resolveFocusedColor(
        effectiveIconColor ?? defaultStyle.iconColor!,
      )!;
      final Color focusedOverlayColor = resolveFocusedColor(
        effectiveOverlayColor ?? defaultStyle.overlayColor!,
      )!;
      // For the background color we can't rely on the default style which is transparent.
      // Defaults to onSurface.withOpacity(0.12).
      final Color focusedBackgroundColor =
          resolveFocusedColor(effectiveBackgroundColor) ??
          // ignore: deprecated_member_use (é a conta da original; a outra dá outra cor)
          Theme.of(context).colorScheme.onSurface.withOpacity(0.12);

      effectiveStyle = effectiveStyle.copyWith(
        backgroundColor: WidgetStatePropertyAll<Color>(focusedBackgroundColor),
        foregroundColor: WidgetStatePropertyAll<Color>(focusedForegroundColor),
        iconColor: WidgetStatePropertyAll<Color>(focusedIconColor),
        overlayColor: WidgetStatePropertyAll<Color>(focusedOverlayColor),
      );
    } else {
      effectiveStyle = effectiveStyle.copyWith(
        backgroundColor: effectiveBackgroundColor,
        foregroundColor: effectiveForegroundColor,
        iconColor: effectiveIconColor,
        overlayColor: effectiveOverlayColor,
      );
    }

    Widget label = Text(entry.naLista ?? entry.label);
    const double horizontalPadding = padding + _kDefaultHorizontalPadding;
    label = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.width - horizontalPadding - effectiveInputStartGap,
      ),
      child: label,
    );

    return ExcludeFocus(
      child: ExcludeSemantics(
        excluding: false,
        child: MenuItemButton(
          statesController: entryIsSelected
              ? _highlightedItemStatesController
              : null,
          style: effectiveStyle,
          onPressed: entry.enabled && widget.enabled
              ? () {
                  if (!mounted) {
                    // In some cases (e.g., nested menus), calling onSelected from MenuAnchor inside a postFrameCallback
                    // can result in the MenuItemButton's onPressed callback being triggered after the state has been disposed.
                    widget.controller.value = TextEditingValue(
                      text: entry.label,
                      selection: TextSelection.collapsed(
                        offset: entry.label.length,
                      ),
                    );
                    widget.onSelected?.call(entry.value);
                    return;
                  }
                  _effectiveTextEditingController.value = TextEditingValue(
                    text: entry.label,
                    selection: TextSelection.collapsed(
                      offset: entry.label.length,
                    ),
                  );
                  currentHighlight = widget.enableSearch ? i : null;
                  widget.onSelected?.call(entry.value);
                  _enableFilter = false;
                }
              : null,
          requestFocusOnHover: false,
          // MenuItemButton implementation is based on M3 spec for menu which specifies a
          // horizontal padding of 12 pixels.
          // In the context of DropdownMenu the M3 spec specifies that the menu item and the text
          // field content should be aligned. The text field has a horizontal padding of 16 pixels.
          // To conform with the 16 pixels padding, a 4 pixels padding is added in front of the item label.
          child: Padding(
            padding: EdgeInsetsDirectional.only(start: effectiveInputStartGap),
            child: label,
          ),
        ),
      ),
    );
  }

  void handleUpKey(_ArrowUpIntent _) {
    setState(() {
      if (!widget.enabled || !_menuHasEnabledItem || !_controller.isOpen) {
        return;
      }
      _enableFilter = false;
      _enableSearch = false;
      currentHighlight ??= 0;
      currentHighlight = (currentHighlight! - 1) % filteredEntries.length;
      while (!filteredEntries[currentHighlight!].enabled) {
        currentHighlight = (currentHighlight! - 1) % filteredEntries.length;
      }
      final String currentLabel = filteredEntries[currentHighlight!].label;
      _effectiveTextEditingController.value = TextEditingValue(
        text: currentLabel,
        selection: TextSelection.collapsed(offset: currentLabel.length),
      );
    });
  }

  void handleDownKey(_ArrowDownIntent _) {
    setState(() {
      if (!widget.enabled || !_menuHasEnabledItem || !_controller.isOpen) {
        return;
      }
      _enableFilter = false;
      _enableSearch = false;
      currentHighlight ??= -1;
      currentHighlight = (currentHighlight! + 1) % filteredEntries.length;
      while (!filteredEntries[currentHighlight!].enabled) {
        currentHighlight = (currentHighlight! + 1) % filteredEntries.length;
      }
      final String currentLabel = filteredEntries[currentHighlight!].label;
      _effectiveTextEditingController.value = TextEditingValue(
        text: currentLabel,
        selection: TextSelection.collapsed(offset: currentLabel.length),
      );
    });
  }

  void handleEnterKey(_EnterIntent _) {
    _handleSubmitted();
  }

  void handlePressed(
    MenuController controller, {
    bool focusForKeyboard = true,
  }) {
    if (controller.isOpen) {
      currentHighlight = null;
      controller.close();
    } else {
      filteredEntries = widget.entries;
      // close to open
      if (_effectiveTextEditingController.text.isNotEmpty) {
        _enableFilter = false;
      }
      controller.open();
      if (focusForKeyboard) {
        _internalFocusNode.requestFocus();
      }
    }
    setState(() {});
  }

  void _handleSubmitted() {
    if (currentHighlight != null) {
      final ItemSuspenso entry = filteredEntries[currentHighlight!];
      if (entry.enabled) {
        _effectiveTextEditingController.value = TextEditingValue(
          text: entry.label,
          selection: TextSelection.collapsed(offset: entry.label.length),
        );
        widget.onSelected?.call(entry.value);
      }
    } else {
      if (_controller.isOpen) {
        widget.onSelected?.call(null);
      }
    }
    if (!widget.enableSearch) {
      currentHighlight = null;
    }
    _controller.close();
  }

  @override
  Widget build(BuildContext context) {
    final bool useMaterial3 = Theme.of(context).useMaterial3;
    final DropdownMenuThemeData theme = DropdownMenuTheme.of(context);
    final DropdownMenuThemeData defaults = _DropdownMenuDefaultsM3(context);

    if (_enableFilter) {
      filteredEntries = filter(widget.entries, _effectiveTextEditingController);
    }
    _menuHasEnabledItem = filteredEntries.any(
      (ItemSuspenso entry) => entry.enabled,
    );

    if (_enableSearch) {
      final bool shouldUpdateCurrentHighlight = _shouldUpdateCurrentHighlight(
        filteredEntries,
      );
      if (shouldUpdateCurrentHighlight) {
        currentHighlight = search(
          filteredEntries,
          _effectiveTextEditingController,
        );
      }
      if (currentHighlight != null) {
        scrollToHighlight();
      }
    }

    // O item realçado ganha, a cada montagem, um controlador de estados novo (como "em foco").
    final List<ItemSuspenso> entradas = filteredEntries;
    final int? realcado = currentHighlight;
    if (realcado != null &&
        realcado < entradas.length &&
        entradas[realcado].enabled) {
      _highlightedItemStatesController?.dispose();
      _highlightedItemStatesController = WidgetStatesController(<WidgetState>{
        WidgetState.focused,
      });
    }
    final List<Widget> menu = entradas.isEmpty
        ? const <Widget>[]
        : <Widget>[
            _ItensPreguicosos(
              key: _chaveItens,
              entradas: entradas,
              larguraCampo: widget.width,
              alturaMaxima: widget.menuHeight,
              construir: (int i) => _botao(entradas, i, realcado, useMaterial3),
            ),
          ];

    final TextStyle? baseTextStyle =
        widget.textStyle ?? theme.textStyle ?? defaults.textStyle;
    final Color? disabledColor = theme.disabledColor ?? defaults.disabledColor;
    final TextStyle? effectiveTextStyle = widget.enabled
        ? baseTextStyle
        : baseTextStyle?.copyWith(color: disabledColor) ??
              TextStyle(color: disabledColor);

    // Menu de largura fixa: o estilo do tema com essa largura; senão, o estilo de fábrica.
    final double? menuWidth = widget.menuWidth;
    MenuStyle? effectiveMenuStyle =
        (menuWidth == null
            ? null
            : (theme.menuStyle ?? const MenuStyle()).copyWith(
                fixedSize: WidgetStateProperty.all(Size.fromWidth(menuWidth)),
              )) ??
        theme.menuStyle ??
        defaults.menuStyle!;

    effectiveMenuStyle = effectiveMenuStyle.copyWith(
      minimumSize: WidgetStateProperty.resolveWith<Size?>((
        Set<WidgetState> states,
      ) {
        final double? effectiveMaximumWidth = effectiveMenuStyle!.maximumSize
            ?.resolve(states)
            ?.width;
        return Size(
          math.min(widget.width, effectiveMaximumWidth ?? widget.width),
          0.0,
        );
      }),
    );

    if (widget.menuHeight != null) {
      effectiveMenuStyle = effectiveMenuStyle.copyWith(
        maximumSize: WidgetStatePropertyAll<Size>(
          Size(double.infinity, widget.menuHeight!),
        ),
      );
    }
    final InputDecorationThemeData effectiveInputDecorationTheme =
        widget.inputDecorationTheme ??
        theme.inputDecorationTheme ??
        defaults.inputDecorationTheme!;

    final MouseCursor? effectiveMouseCursor = switch (widget.enabled) {
      true => isButton ? SystemMouseCursors.click : SystemMouseCursors.text,
      false => null,
    };

    Widget menuAnchor = MenuAnchor(
      style: effectiveMenuStyle,
      reservedPadding: EdgeInsets.zero,
      controller: _controller,
      menuChildren: menu,
      crossAxisUnconstrained: false,
      builder: (BuildContext context, MenuController controller, Widget? child) {
        InputDecoration decoration = _buildDefaultDecoration(
          context,
          controller,
        );
        // If no suffixIcon is provided, the default IconButton is used for convenience.
        if (decoration.suffixIcon == null) {
          decoration = decoration.copyWith(
            suffixIcon: _buildDefaultSuffixIcon(context, controller),
          );
        }
        final InputDecoration effectiveDecoration = decoration.applyDefaults(
          effectiveInputDecorationTheme,
        );
        final InputDecoration textFieldDecoration = effectiveDecoration;

        final Widget textField = Semantics(
          button: isButton,
          expanded: _controller.isOpen,
          onExpand: _controller.isOpen
              ? null
              : () {
                  _controller.open();
                },
          onCollapse: !_controller.isOpen
              ? null
              : () {
                  _controller.close();
                },
          child: ExcludeSemantics(
            // When both `isTextField` and `isButton` are true, this widget will
            // still be treated as a text field on web. So excluding the semantics
            // of the `TextField` on web is needed.
            excluding: isButton && kIsWeb,
            child: TextField(
              key: _anchorKey,
              enabled: widget.enabled,
              mouseCursor: effectiveMouseCursor,
              focusNode: widget.focusNode,
              canRequestFocus: canRequestFocus(),
              enableInteractiveSelection: !isButton,
              readOnly: isButton,
              textAlign: widget.textAlign,
              textAlignVertical: TextAlignVertical.center,
              maxLines: 1,
              style: effectiveTextStyle,
              controller: _effectiveTextEditingController,
              onSubmitted: (_) => _handleSubmitted(),
              onTap: !widget.enabled
                  ? null
                  : () {
                      handlePressed(
                        controller,
                        focusForKeyboard: !canRequestFocus(),
                      );
                    },
              onChanged: (String text) {
                controller.open();
                setState(() {
                  filteredEntries = widget.entries;
                  _enableFilter = widget.enableFilter;
                  _enableSearch = widget.enableSearch;
                });
              },
              decoration: textFieldDecoration,
            ),
          ),
        );

        // A largura do campo é dada: os outros filhos da original (todos os itens do menu, o
        // rótulo e os ícones, medidos sem aparecer) só serviam para calculá-la quando faltava.
        // Um deles fica: a cópia escondida do botão da seta. Ela divide o nó de foco com o
        // botão que se vê e, por estar no canto esquerdo do campo, é quem põe a seta ANTES do
        // campo na ordem do Tab — sem ela a ordem se inverteria.
        final Widget body = _CorpoDoCampo(
          width: widget.width,
          children: <Widget>[
            textField,
            effectiveDecoration.suffixIcon ?? const SizedBox.shrink(),
          ],
        );

        return Shortcuts(shortcuts: _editableShortcuts, child: body);
      },
    );

    // Wrap the menu anchor with an Align to narrow down the constraints.
    // Without this Align, when tight constraints are applied to DropdownMenu,
    // the menu will appear below these constraints instead of below the
    // text field.
    menuAnchor = Align(
      alignment: AlignmentDirectional.topStart,
      widthFactor: 1.0,
      heightFactor: 1.0,
      child: menuAnchor,
    );

    return Actions(
      actions: <Type, Action<Intent>>{
        _ArrowUpIntent: CallbackAction<_ArrowUpIntent>(onInvoke: handleUpKey),
        _ArrowDownIntent: CallbackAction<_ArrowDownIntent>(
          onInvoke: handleDownKey,
        ),
        _EnterIntent: CallbackAction<_EnterIntent>(onInvoke: handleEnterKey),
        DismissIntent: DismissMenuAction(controller: _controller),
      },
      child: Stack(
        children: <Widget>[
          // Handling keyboard navigation when the Textfield has no focus.
          Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.arrowUp): _ArrowUpIntent(),
              SingleActivator(LogicalKeyboardKey.arrowDown): _ArrowDownIntent(),
              SingleActivator(LogicalKeyboardKey.enter): _EnterIntent(),
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            },
            child: Focus(
              focusNode: _internalFocusNode,
              skipTraversal: true,
              child: const SizedBox.shrink(),
            ),
          ),
          menuAnchor,
        ],
      ),
    );
  }

  InputDecoration _buildDefaultDecoration(
    BuildContext context,
    MenuController controller,
  ) {
    return InputDecoration(
      label: widget.label,
      hintText: widget.hintText,
      suffixIcon: _buildDefaultSuffixIcon(context, controller),
    );
  }

  Widget? _buildDefaultSuffixIcon(
    BuildContext context,
    MenuController controller,
  ) {
    final bool isCollapsed = widget.inputDecorationTheme?.isCollapsed ?? false;
    return Padding(
      padding: isCollapsed ? EdgeInsets.zero : const EdgeInsets.all(4.0),
      child: ExcludeSemantics(
        // When the text field is treated as a button (i.e., it can
        // not be focused), the trailing button should become part of
        // the text field button by excluding semantics. Otherwise,
        // it will inappropriately announce whether this icon button
        // is selected or not.
        excluding: isButton,
        child: IconButton(
          focusNode: _trailingIconButtonFocusNode,
          isSelected: controller.isOpen,
          constraints: widget.inputDecorationTheme?.suffixIconConstraints,
          padding: isCollapsed ? EdgeInsets.zero : null,
          icon: const Icon(Icons.arrow_drop_down),
          selectedIcon: const Icon(Icons.arrow_drop_up),
          onPressed: !widget.enabled
              ? null
              : () {
                  handlePressed(controller);
                },
        ),
      ),
    );
  }
}

// `DropdownMenu` dispatches these private intents on arrow up/down keys.
// They are needed instead of the typical `DirectionalFocusIntent`s because
// `DropdownMenu` does not really navigate the focus tree upon arrow up/down
// keys: the focus stays on the text field and the menu items are given fake
// highlights as if they are focused. Using `DirectionalFocusIntent`s will cause
// the action to be processed by `EditableText`.
class _ArrowUpIntent extends Intent {
  const _ArrowUpIntent();
}

class _ArrowDownIntent extends Intent {
  const _ArrowDownIntent();
}

class _EnterIntent extends Intent {
  const _EnterIntent();
}

// --------------------------------------------------------------------------- //
// O campo, na largura dada (o corpo da original sem os itens do menu)
// --------------------------------------------------------------------------- //
/// O primeiro filho é o campo; os demais são medidos no mesmo lugar, sem serem desenhados
/// nem receberem o mouse (como na original).
class _CorpoDoCampo extends MultiChildRenderObjectWidget {
  const _CorpoDoCampo({required this.width, super.children});
  final double width;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCorpoDoCampo(width);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCorpoDoCampo renderObject,
  ) {
    renderObject.width = width;
  }
}

class _DadosDoCorpo extends ContainerBoxParentData<RenderBox> {}

class _RenderCorpoDoCampo extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DadosDoCorpo>,
        RenderBoxContainerDefaultsMixin<RenderBox, _DadosDoCorpo> {
  _RenderCorpoDoCampo(this._width);

  double _width;
  set width(double value) {
    if (_width == value) {
      return;
    }
    _width = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DadosDoCorpo) {
      child.parentData = _DadosDoCorpo();
    }
  }

  // A altura natural só é usada quando o pai não definiu uma altura menor.
  // Ignorar maxHeight fazia a borda ultrapassar o tamanho padronizado do campo.
  BoxConstraints _limites(BoxConstraints constraints) {
    final double widthConstraint = math.min(_width, constraints.maxWidth);
    return BoxConstraints(
      maxWidth: widthConstraint,
      minHeight: constraints.minHeight,
      maxHeight: math.max(
        constraints.minHeight,
        math.min(constraints.maxHeight, getMaxIntrinsicHeight(widthConstraint)),
      ),
    );
  }

  @override
  void performLayout() {
    final BoxConstraints innerConstraints = _limites(constraints);
    double? maxHeight;
    RenderBox? child = firstChild;
    while (child != null) {
      child.layout(innerConstraints, parentUsesSize: true);
      maxHeight ??= child.size.height;
      final _DadosDoCorpo dados = child.parentData! as _DadosDoCorpo;
      dados.offset = Offset.zero;
      child = dados.nextSibling;
    }
    size = constraints.constrain(Size(_width, maxHeight ?? 0.0));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? campo = firstChild;
    final double altura = campo == null
        ? 0.0
        : campo.getDryLayout(_limites(constraints)).height;
    return constraints.constrain(Size(_width, altura));
  }

  // A largura natural da original dependia de todos os itens do menu. Ninguém a pede (a
  // largura é sempre dada); se alguém pedir, é a dada.
  @override
  double computeMinIntrinsicWidth(double height) => _width;

  @override
  double computeMaxIntrinsicWidth(double height) => _width;

  @override
  double computeMinIntrinsicHeight(double width) =>
      firstChild?.getMinIntrinsicHeight(0) ?? 0.0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      firstChild?.getMaxIntrinsicHeight(0) ?? 0.0;

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? campo = firstChild;
    if (campo != null) {
      context.paintChild(campo, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? campo = firstChild;
    return campo != null && campo.hitTest(result, position: position);
  }

  // Só o campo existe para os leitores de tela (os outros filhos não aparecem).
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final RenderBox? campo = firstChild;
    if (campo != null) {
      visitor(campo);
    }
  }
}

// --------------------------------------------------------------------------- //
// Os itens do menu, montados só na faixa que está à vista
// --------------------------------------------------------------------------- //
class _ItensPreguicosos extends StatefulWidget {
  const _ItensPreguicosos({
    super.key,
    required this.entradas,
    required this.construir,
    required this.larguraCampo,
    required this.alturaMaxima,
  });
  final List<ItemSuspenso> entradas;
  final Widget Function(int indice) construir;
  final double larguraCampo;

  /// Teto da altura do menu (nulo = a altura da janela).
  final double? alturaMaxima;

  @override
  State<_ItensPreguicosos> createState() => _ItensPreguicososState();
}

class _ItensPreguicososState extends State<_ItensPreguicosos> {
  /// Sobra montada acima e abaixo da área visível.
  static const double _margem = 96;

  ScrollPosition? _posicao;
  _Alturas? _alturas;
  int _primeiro = 0;
  int _ultimo = -1;
  bool _avisoMarcado = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollPosition? p = Scrollable.maybeOf(context)?.position;
    if (!identical(p, _posicao)) {
      _posicao?.removeListener(_rolou);
      _posicao = p?..addListener(_rolou);
    }
  }

  @override
  void dispose() {
    _posicao?.removeListener(_rolou);
    super.dispose();
  }

  void _rolou() {
    final _Alturas? a = _alturas;
    if (a == null || !mounted) {
      return;
    }
    final (int p, int u) = _faixa(a);
    if (p == _primeiro && u == _ultimo) {
      return;
    }
    // A rolagem avisa fora da montagem (roda do mouse, barra, tecla); se um dia avisar no
    // meio de um quadro, a faixa nova entra no quadro seguinte.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_avisoMarcado) {
        _avisoMarcado = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _avisoMarcado = false;
          if (mounted) setState(() {});
        });
      }
      return;
    }
    setState(() {});
  }

  double get _teto => widget.alturaMaxima ?? MediaQuery.sizeOf(context).height;

  /// Índices (primeiro, último) dos itens que tocam a área visível, com a margem.
  (int, int) _faixa(_Alturas a) {
    final int n = a.inicio.length - 1;
    final double total = a.inicio[n];
    final ScrollPosition? p = _posicao;
    final double pixels = (p != null && p.hasPixels) ? p.pixels : 0.0;
    final double teto = _teto;
    // A posição pode estar adiante do fim (a lista encolheu e a rolagem ainda vai ser
    // corrigida neste mesmo quadro): a faixa cobre de onde ela pode parar até onde está.
    final double de = math.max(0.0, math.min(pixels, total - teto)) - _margem;
    final double ate = math.min(total, pixels + teto) + _margem;
    int primeiro = _indiceEm(a.inicio, de);
    int ultimo = _indiceEm(a.inicio, ate);
    if (primeiro < 0) primeiro = 0;
    if (ultimo > n - 1) ultimo = n - 1;
    return (primeiro, ultimo);
  }

  /// O item em cuja faixa vertical [y] cai (busca binária nos começos).
  static int _indiceEm(List<double> inicio, double y) {
    int a = 0;
    int b = inicio.length - 2;
    if (y <= 0) return 0;
    while (a < b) {
      final int m = (a + b + 1) >> 1;
      if (inicio[m] <= y) {
        a = m;
      } else {
        b = m - 1;
      }
    }
    return a;
  }

  /// Rola até o item [indice] ficar no topo da área visível (o que a original fazia com o
  /// item realçado).
  void revelar(int indice) {
    final _Alturas? a = _alturas;
    final ScrollPosition? p = _posicao;
    if (a == null ||
        p == null ||
        !mounted ||
        indice < 0 ||
        indice >= a.inicio.length - 1) {
      return;
    }
    if (!p.hasPixels || !p.hasContentDimensions) {
      return;
    }
    final double alvo = clampDouble(
      a.inicio[indice],
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    if (alvo == p.pixels) {
      return;
    }
    p.jumpTo(alvo);
  }

  @override
  Widget build(BuildContext context) {
    return _LarguraNatural(
      largura: widget.larguraCampo,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints limites) {
          final double largura = limites.maxWidth;
          final _Alturas a = _alturas = _Alturas.de(
            context,
            widget.entradas,
            largura,
          );
          final (int primeiro, int ultimo) = _faixa(a);
          _primeiro = primeiro;
          _ultimo = ultimo;
          return SizedBox(
            width: largura,
            height: a.inicio[a.inicio.length - 1],
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                for (int i = primeiro; i <= ultimo; i++)
                  Positioned(
                    key: ValueKey<int>(i),
                    top: a.inicio[i],
                    left: 0,
                    width: largura,
                    child: widget.construir(i),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Onde começa cada item (e, na última posição, a altura de todos juntos) para uma largura.
class _Alturas {
  _Alturas._(this.entradas, this.largura, this.assinatura, this.inicio);
  final List<ItemSuspenso> entradas;
  final double largura;
  final _Assinatura assinatura;
  final List<double> inicio;

  static _Alturas? _ultima;

  static _Alturas de(
    BuildContext context,
    List<ItemSuspenso> entradas,
    double largura,
  ) {
    final _Assinatura s = _Assinatura.de(context);
    final _Alturas? u = _ultima;
    if (u != null &&
        identical(u.entradas, entradas) &&
        u.largura == largura &&
        u.assinatura == s) {
      return u;
    }
    // A mesma conta do botão do menu: altura mínima do botão (com a densidade), ou a do
    // texto quando ele passa de uma linha; e o alvo de toque mínimo, quando o tema pede.
    final double larguraTexto = math.max(0.0, largura - s.descontoHorizontal);
    final _Medidor medidor = _Medidor.para(s, larguraTexto);
    final List<double> inicio = List<double>.filled(entradas.length + 1, 0.0);
    double y = 0.0;
    for (int i = 0; i < entradas.length; i++) {
      final ItemSuspenso e = entradas[i];
      final double texto = medidor.altura(e.naLista ?? e.label);
      final double botao = math.max(s.alturaMinima, texto + s.respiroVertical);
      y += math.max(botao, s.alvoMinimo);
      inicio[i + 1] = y;
    }
    medidor.fim();
    return _ultima = _Alturas._(entradas, largura, s, inicio);
  }
}

/// Tudo o que decide a altura de um item, lido do tema em uso DENTRO do menu.
@immutable
class _Assinatura {
  const _Assinatura({
    required this.estilo,
    required this.escala,
    required this.local,
    required this.direcao,
    required this.comportamento,
    required this.alturaMinima,
    required this.respiroVertical,
    required this.alvoMinimo,
    required this.descontoHorizontal,
  });
  final TextStyle estilo;
  final TextScaler escala;
  final Locale? local;
  final TextDirection direcao;
  final TextHeightBehavior? comportamento;
  final double alturaMinima;
  final double respiroVertical;
  final double alvoMinimo;
  final double descontoHorizontal;

  static _Assinatura de(BuildContext context) {
    final ThemeData tema = Theme.of(context);
    const MenuItemButton molde = MenuItemButton();
    final ButtonStyle padrao = molde.defaultStyleOf(context);
    final ButtonStyle fundido =
        molde.themeStyleOf(context)?.merge(padrao) ?? padrao;
    const Set<WidgetState> nenhum = <WidgetState>{};
    final VisualDensity densidade = fundido.visualDensity ?? tema.visualDensity;
    final Offset ajuste = densidade.baseSizeAdjustment;
    final Size minimo =
        fundido.minimumSize?.resolve(nenhum) ?? const Size(64, 48);
    final double dx = math.max(0.0, ajuste.dx);
    final double dy = ajuste.dy;
    // O respiro do item é só horizontal (12 de cada lado); a densidade soma dy em cima e
    // embaixo e dx dos lados, sem deixar nada negativo.
    final double vertical = 2 * math.max(0.0, dy);
    final MaterialTapTargetSize alvo =
        fundido.tapTargetSize ?? tema.materialTapTargetSize;
    TextStyle estilo =
        fundido.textStyle?.resolve(nenhum) ?? tema.textTheme.labelLarge!;
    if (MediaQuery.boldTextOf(context)) {
      estilo = estilo.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    return _Assinatura(
      // a cor não muda a medida: fica de fora para a assinatura não variar com o estado
      estilo: estilo.copyWith(color: const Color(0xFF000000)),
      escala: MediaQuery.textScalerOf(context),
      local: Localizations.maybeLocaleOf(context),
      direcao: Directionality.of(context),
      comportamento: DefaultTextHeightBehavior.maybeOf(context),
      alturaMinima: densidade
          .effectiveConstraints(BoxConstraints(minHeight: minimo.height))
          .minHeight,
      respiroVertical: vertical,
      alvoMinimo: alvo == MaterialTapTargetSize.padded
          ? kMinInteractiveDimension + dy
          : 0.0,
      descontoHorizontal:
          2 * (_kDefaultHorizontalPadding + dx) +
          (tema.useMaterial3 ? _kInputStartGap : 0.0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _Assinatura &&
      other.estilo == estilo &&
      other.escala == escala &&
      other.local == local &&
      other.direcao == direcao &&
      other.comportamento == comportamento &&
      other.alturaMinima == alturaMinima &&
      other.respiroVertical == respiroVertical &&
      other.alvoMinimo == alvoMinimo &&
      other.descontoHorizontal == descontoHorizontal;

  @override
  int get hashCode => Object.hash(
    estilo,
    escala,
    local,
    direcao,
    comportamento,
    alturaMinima,
    respiroVertical,
    alvoMinimo,
    descontoHorizontal,
  );
}

/// Mede a altura do texto de cada item numa largura, guardando o que já mediu (os catálogos
/// são sempre os mesmos textos).
class _Medidor {
  _Medidor._(this.assinatura, this.largura);
  final _Assinatura assinatura;
  final double largura;
  final Map<String, double> _guardadas = <String, double>{};
  TextPainter? _pintor;

  /// Medido de antemão (catálogos): não sai da memória para dar lugar a outro.
  bool fixo = false;

  static final List<_Medidor> _todos = <_Medidor>[];
  static const int _maximo = 16;

  static _Medidor para(_Assinatura s, double largura, {bool fixo = false}) {
    for (int i = 0; i < _todos.length; i++) {
      final _Medidor m = _todos[i];
      if (m.largura == largura && m.assinatura == s) {
        if (i != _todos.length - 1) {
          _todos
            ..removeAt(i)
            ..add(m);
        }
        if (fixo) m.fixo = true;
        return m;
      }
    }
    final _Medidor novo = _Medidor._(s, largura)..fixo = fixo;
    _todos.add(novo);
    if (_todos.length > _maximo) {
      final int velho = _todos.indexWhere((_Medidor m) => !m.fixo);
      if (velho >= 0 && velho < _todos.length - 1) {
        _todos.removeAt(velho);
      }
    }
    return novo;
  }

  double altura(String texto) {
    final double? ja = _guardadas[texto];
    if (ja != null) {
      return ja;
    }
    final TextPainter pintor = _pintor ??= TextPainter(
      textDirection: assinatura.direcao,
      textScaler: assinatura.escala,
      locale: assinatura.local,
      textHeightBehavior: assinatura.comportamento,
    );
    pintor.text = TextSpan(text: texto, style: assinatura.estilo);
    pintor.layout(maxWidth: largura);
    final double h = pintor.height;
    if (_guardadas.length < 6000) {
      _guardadas[texto] = h;
    }
    return h;
  }

  void fim() {
    _pintor?.dispose();
    _pintor = null;
  }
}

/// Diz ao menu a largura natural do conjunto de itens sem precisar montá-los. Na original
/// ela era a do item mais largo, limitada à largura do campo — e o menu nunca fica mais
/// estreito que o campo (ou tem largura fixa): dá na mesma responder a do campo.
class _LarguraNatural extends SingleChildRenderObjectWidget {
  const _LarguraNatural({required this.largura, super.child});
  final double largura;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLarguraNatural(largura);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLarguraNatural renderObject,
  ) {
    renderObject.largura = largura;
  }
}

class _RenderLarguraNatural extends RenderProxyBox {
  _RenderLarguraNatural(this._largura);
  double _largura;
  set largura(double v) {
    if (v == _largura) return;
    _largura = v;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _largura;

  @override
  double computeMaxIntrinsicWidth(double height) => _largura;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;
}

// Hand coded defaults. These will be updated once we have tokens/spec.
class _DropdownMenuDefaultsM3 extends DropdownMenuThemeData {
  _DropdownMenuDefaultsM3(this.context)
    : super(
        disabledColor: Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: 0.38),
      );

  final BuildContext context;
  late final ThemeData _theme = Theme.of(context);

  @override
  TextStyle? get textStyle => _theme.textTheme.bodyLarge;

  @override
  MenuStyle get menuStyle {
    return const MenuStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(112.0, 0.0)),
      maximumSize: WidgetStatePropertyAll<Size>(Size.infinite),
      visualDensity: VisualDensity.standard,
    );
  }

  @override
  InputDecorationThemeData get inputDecorationTheme {
    return PadraoControles.decoracao(const InputDecorationThemeData());
  }
}
