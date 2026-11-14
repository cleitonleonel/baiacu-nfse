import 'package:flutter/material.dart';

// Mãozinha e realce de hover iguais aos dos botões do app.
//
// O tema do app (tema.dart, iconButtonTheme) dá aos botões cursor de mãozinha e
// overlay preto 22% no hover / 38% ao pressionar. Menus (PopupMenuButton/PopupMenuItem) e
// InkWell NÃO leem esse tema, e no desktop o Flutter 3.44 usa `adaptiveClickable` por padrão
// (seta; só a web ganha mãozinha). Por isso os seletores da barra, os itens de menu e a paleta
// de cores pegam as cores daqui e põem `SystemMouseCursors.click` explicitamente.

/// Overlay de hover dos botões do app (preto 22% se o tema não disser outra coisa).
Color corHover(BuildContext context) =>
    IconButtonTheme.of(context).style?.overlayColor?.resolve({WidgetState.hovered}) ??
    Colors.black.withValues(alpha: 0.22);

/// Overlay de "pressionado" dos botões do app (preto 38% se o tema não disser outra coisa).
Color corPressionado(BuildContext context) =>
    IconButtonTheme.of(context).style?.overlayColor?.resolve({WidgetState.pressed}) ??
    Colors.black.withValues(alpha: 0.38);

/// Tema para um PopupMenuButton: o InkWell do botão e o dos itens usam o hover/pressionado dos
/// botões do app. O menu herda este tema (showMenu captura os temas do contexto do botão).
ThemeData temaDeMenu(BuildContext context) => Theme.of(context).copyWith(
      hoverColor: corHover(context),
      highlightColor: corPressionado(context),
      splashColor: corPressionado(context),
    );
