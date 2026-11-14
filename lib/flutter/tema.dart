/// Tema do programa e as duas cores que o usuário personaliza (Configurações > Personalização).
///
/// - FUNDO: o que fica atrás de tudo (página, trilho lateral, barra do topo).
/// - CARTÕES: os painéis. As janelas, menus e listas suspensas saem dela, um degrau mais
///   escuro cada — a mesma escada de superfícies do Material 3.
///
/// As cores são sempre CLARAS e pouco saturadas: o texto do sistema é escuro e não acompanha a
/// personalização.
library;

import 'package:flutter/material.dart';

import 'estilo.dart';
import 'kit/contorno_campo.dart';

/// "#RRGGBB" -> cor opaca.
Color corHex(String hex) =>
    Color(0xFF000000 | int.parse(hex.replaceFirst('#', ''), radix: 16));

/// A cor com outra opacidade (0 a 1).
Color comOpacidade(Color cor, double opacidade) =>
    cor.withValues(alpha: opacidade);

String _hex(int r, int g, int b) =>
    '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();

/// As duas cores em uso.
class Aparencia {
  const Aparencia(this.fundo, this.cartoes);
  final String fundo;
  final String cartoes;

  /// O tema índigo "de fábrica" usa fundo #FBF8FF e cartões #F5F2FA; o padrão daqui é o mesmo
  /// lilás, um ponto mais forte.
  static const nativo = Aparencia('#FBF8FF', '#F5F2FA');
  static const padrao = Aparencia('#F8F4FF', '#F1ECFA');

  @override
  bool operator ==(Object other) =>
      other is Aparencia && other.fundo == fundo && other.cartoes == cartoes;

  @override
  int get hashCode => Object.hash(fundo, cartoes);
}

String escurecer(String cor, double fator) {
  final v = int.parse(cor.replaceFirst('#', ''), radix: 16);
  int canal(int deslocamento) => (((v >> deslocamento) & 0xFF) * fator).round();
  return _hex(canal(16), canal(8), canal(0));
}

/// Cores de superfície em uso AGORA. Antes do login vale o padrão; depois, o que está salvo no
/// banco (a Personalização muda ao vivo).
Aparencia aparenciaAtual = Aparencia.padrao;

/// Tema do app. Em TODOS os botões: cursor de "mãozinha", hover/pressionado bem visível (preto
/// translúcido — funciona em botão claro e colorido) e cantos arredondados.
///
/// [realceHover]: mesma coisa, mais uma cor de hover VISÍVEL para as áreas clicáveis que usam a
/// do tema (cabeçalho de expansão, itens de lista) — a de fábrica é preto a 4%, quase
/// invisível. Só para temas ESCOPADOS; o da página não muda.
ThemeData temaApp({Aparencia? cores, bool realceHover = false}) {
  final a = cores ?? aparenciaAtual;
  final pronto = _temasApp[(a, realceHover)];
  if (pronto != null) return pronto;
  // (a Personalização experimenta muitas cores seguidas: as antigas não ficam guardadas)
  if (_temasApp.length >= 8) _temasApp.clear();
  return _temasApp[(a, realceHover)] = _montarTemaApp(a, realceHover);
}

// Montar um tema custa caro (a paleta inteira sai da cor-semente) e um tema novo, mesmo
// igual, faz tudo o que depende dele ser refeito: cada combinação é montada uma vez só.
final Map<(Aparencia, bool), ThemeData> _temasApp = {};
final Map<Aparencia, ThemeData> _temasTrilho = {};

/// O hot reload preserva os mapas globais; refaz o tema com as fontes editadas.
void limparTemasParaHotReload() {
  _temasApp.clear();
  _temasTrilho.clear();
}

/// O estilo do Material com outro tamanho de letra (o espaço entre as letras acompanha).
TextStyle _letra(TextStyle? estilo, double tamanho) {
  final de = estilo?.fontSize ?? tamanho;
  final entre = estilo?.letterSpacing;
  return (estilo ?? const TextStyle()).copyWith(
    fontSize: tamanho,
    letterSpacing: entre == null ? null : entre * tamanho / de,
  );
}

/// Entrega ao Flutter os tamanhos de letra de estilo.dart: cada "papel" de texto do Material vai
/// para o tipo de item do programa que o usa.
ThemeData _comLetras(ThemeData tema) {
  final t = tema.textTheme;
  final botao = WidgetStatePropertyAll<TextStyle?>(
    _letra(t.labelLarge, Letra.botao),
  );
  ButtonStyle comLetra(ButtonStyle? estilo) =>
      (estilo ?? const ButtonStyle()).copyWith(textStyle: botao);
  return tema.copyWith(
    textTheme: t.copyWith(
      bodyLarge: _letra(
        t.bodyLarge,
        Letra.campo,
      ), // campos, listas suspensas, linhas clicáveis
      bodyMedium: _letra(t.bodyMedium, Letra.texto), // texto comum
      bodySmall: _letra(
        t.bodySmall,
        Letra.apoio,
      ), // contador, dica e erro dos campos; balões
      labelLarge: _letra(
        t.labelLarge,
        Letra.itemDeMenu,
      ), // itens de lista suspensa e de menu
      labelMedium: _letra(t.labelMedium, Letra.trilho), // trilho lateral
      titleSmall: _letra(t.titleSmall, Letra.aba),
      titleMedium: _letra(t.titleMedium, Letra.subtitulo),
      titleLarge: _letra(t.titleLarge, Letra.titulo),
    ),
    // Altura do campo = respiro de cima + linha de texto + respiro de baixo (o Flutter ainda
    // soma o ajuste de densidade, negativo no Windows). O rótulo que sobe para a borda é
    // desenhado a 75% do tamanho declarado.
    inputDecorationTheme: PadraoControles.decoracao(
      tema.inputDecorationTheme.copyWith(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical:
              (Medida.campo -
                  tema.visualDensity.baseSizeAdjustment.dy -
                  Letra.campo * (t.bodyLarge?.height ?? 1.5)) /
              2,
        ),
      ),
    ),
    checkboxTheme: tema.checkboxTheme.copyWith(
      side: const WidgetStateBorderSide.fromMap({
        WidgetState.any: BorderSide(color: PadraoControles.borda),
      }),
      shape: const FormaControle(),
    ),
    dividerTheme: const DividerThemeData(
      color: PadraoControles.separador,
      thickness: 0,
    ),
    tabBarTheme: tema.tabBarTheme.copyWith(
      labelStyle: _letra(t.titleSmall, Letra.aba),
      unselectedLabelStyle: _letra(t.titleSmall, Letra.aba),
    ),
    dataTableTheme: tema.dataTableTheme.copyWith(
      dataTextStyle: _letra(t.bodyMedium, Letra.tabela),
      headingTextStyle: _letra(t.titleSmall, Letra.cabecalhoDaTabela),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: comLetra(tema.elevatedButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: comLetra(tema.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: comLetra(tema.outlinedButtonTheme.style).copyWith(
        side: const WidgetStatePropertyAll(
          BorderSide(color: PadraoControles.borda),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: comLetra(tema.textButtonTheme.style),
    ),
  );
}

ThemeData _montarTemaApp(Aparencia a, bool realceHover) {
  var tema = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: Brightness.light,
  );
  // Só as superfícies são trocadas; o resto da paleta continua saindo do índigo. Os fatores
  // reproduzem os degraus do tema de fábrica (tons 96 > 94 > 92 > 90).
  final esquema = tema.colorScheme.copyWith(
    surface: corHex(a.fundo), // página, trilho, topo
    surfaceContainerLow: corHex(a.cartoes), // cartões
    surfaceContainer: corHex(
      escurecer(a.cartoes, 0.976),
    ), // menus e listas suspensas
    surfaceContainerHigh: corHex(
      a == Aparencia.nativo ? a.cartoes : escurecer(a.cartoes, 0.955),
    ), // janelas, calendário
    surfaceContainerHighest: corHex(escurecer(a.cartoes, 0.931)),
  );
  final hover = _PorEstado<Color?>([
    (WidgetState.hovered, comOpacidade(Colors.black, 0.22)),
    (WidgetState.pressed, comOpacidade(Colors.black, 0.38)),
  ], null);
  final mao = WidgetStateProperty.resolveWith<MouseCursor?>(
    (estados) => estados.contains(WidgetState.disabled)
        ? SystemMouseCursors.basic
        : SystemMouseCursors.click,
  );
  final botao = ButtonStyle(
    mouseCursor: mao,
    shape: WidgetStatePropertyAll<OutlinedBorder?>(
      FormaControle(
        side: BorderSide.none,
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    overlayColor: hover,
  );
  final botaoIcone = ButtonStyle(
    mouseCursor: mao,
    overlayColor: hover,
  ); // ícone fica redondo
  return _comLetras(
    tema.copyWith(
      colorScheme: esquema,
      shadowColor: esquema.shadow,
      hoverColor: realceHover ? comOpacidade(Colors.indigo, 0.10) : null,
      elevatedButtonTheme: ElevatedButtonThemeData(style: botao),
      filledButtonTheme: FilledButtonThemeData(style: botao),
      outlinedButtonTheme: OutlinedButtonThemeData(style: botao),
      textButtonTheme: TextButtonThemeData(style: botao),
      iconButtonTheme: IconButtonThemeData(style: botaoIcone),
      checkboxTheme: tema.checkboxTheme.copyWith(mouseCursor: mao),
      radioTheme: tema.radioTheme.copyWith(mouseCursor: mao),
      switchTheme: tema.switchTheme.copyWith(mouseCursor: mao),
      popupMenuTheme: tema.popupMenuTheme.copyWith(mouseCursor: mao),
    ),
  );
}

/// Tema ESCOPADO do trilho lateral: primary translúcido para o hover dos destinos.
ThemeData temaTrilho({Aparencia? cores}) {
  final a = cores ?? aparenciaAtual;
  final pronto = _temasTrilho[a];
  if (pronto != null) return pronto;
  if (_temasTrilho.length >= 4) _temasTrilho.clear();
  return _temasTrilho[a] = _montarTemaTrilho(a);
}

ThemeData _montarTemaTrilho(Aparencia a) {
  final tema = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: Brightness.light,
  );
  final esquema = tema.colorScheme.copyWith(
    primary: comOpacidade(Colors.indigo, 0.10),
    surface: corHex(a.fundo),
    surfaceContainerLow: corHex(a.cartoes),
    surfaceContainer: corHex(escurecer(a.cartoes, 0.976)),
    surfaceContainerHigh: corHex(escurecer(a.cartoes, 0.955)),
    surfaceContainerHighest: corHex(escurecer(a.cartoes, 0.931)),
  );
  return _comLetras(
    tema.copyWith(colorScheme: esquema, shadowColor: esquema.shadow),
  );
}

/// Valor por estado, na ORDEM dada: o primeiro estado presente decide; senão, o padrão.
class _PorEstado<T> extends WidgetStateProperty<T> {
  _PorEstado(this._estados, this._padrao);
  final List<(WidgetState, T)> _estados;
  final T _padrao;

  @override
  T resolve(Set<WidgetState> states) {
    for (final (estado, valor) in _estados) {
      if (states.contains(estado)) return valor;
    }
    return _padrao;
  }
}

/// Valor por estado para uso fora do tema (cores de linha de tabela, bordas…).
WidgetStateProperty<T> porEstado<T>(List<(WidgetState, T)> estados, T padrao) =>
    _PorEstado<T>(estados, padrao);
