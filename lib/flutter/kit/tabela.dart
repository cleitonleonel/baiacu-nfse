/// Peças das telas de lista (Clientes, Consultar, Cofre): cor de linha com realce, campo
/// "ir para página", seletor "itens por página" e a busca que acompanha a digitação.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'campo.dart';
import 'flet.dart';
import 'contorno_campo.dart';
import 'rolagem_linhas.dart';
import '../editor_layout.dart';

/// As tabelas compartilham a mesma linha de um pixel, sem bordas sobrepostas.
class TabelaPadrao extends DataTable {
  TabelaPadrao({
    super.key,
    required super.columns,
    required super.rows,
    super.showCheckboxColumn = false,
    super.headingRowHeight,
    super.dataRowMinHeight,
    super.dataRowMaxHeight,
    super.columnSpacing,
    super.sortColumnIndex,
    super.sortAscending = true,
    bool esconderSeparadorInicial = false,
  }) : super(
         dividerThickness: 0,
         border: SeparadoresTabela(ignorarInicio: esconderSeparadorInicial),
       );

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Theme(
      data: tema.copyWith(
        dividerTheme: tema.dividerTheme.copyWith(color: Colors.transparent),
      ),
      child: Builder(builder: (context) => super.build(context)),
    );
  }
}

const tamanhosDePagina = [25, 50, 100];

/// Cabeçalho fora da rolagem vertical; ambas as partes compartilham as larguras
/// e a mesma rolagem horizontal. O corpo mantém a montagem por faixa visível.
class TabelaCabecalhoFixo extends StatelessWidget {
  const TabelaCabecalhoFixo({
    super.key,
    required this.quantidade,
    required this.alturaLinha,
    required this.alturaCabecalho,
    required this.entradas,
    required this.montar,
    required this.larguras,
    this.colunaExpansivel = 1,
    this.espacoAntesAcoes = 0,
  });
  final int quantidade;
  final double alturaLinha, alturaCabecalho;
  final List<Object?> entradas;
  final MontarTabela montar;
  final List<double> larguras;
  final int colunaExpansivel;
  final double espacoAntesAcoes;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, limites) {
      final cabecalho = montar(0, -1, (i) => ValueKey('cabecalho-$i'));
      final estiloCabecalho = DefaultTextStyle.of(context).style.merge(
        DataTableTheme.of(context).headingTextStyle ??
            Theme.of(context).textTheme.titleSmall ??
            const TextStyle(fontSize: 14),
      );
      final minimas = <double>[];
      for (var i = 0; i < cabecalho.columns.length; i++) {
        final coluna = cabecalho.columns[i];
        final rotulo = coluna.label;
        var texto = '';
        var estilo = estiloCabecalho;
        if (rotulo is Tx) {
          final ajuste = ajusteLayout(context, rotulo.idLayout);
          texto = ajuste.exibir(rotulo.valor);
          estilo = ajuste.estilo(
            estilo
                .merge(rotulo.tema?.call(Theme.of(context).textTheme))
                .merge(
                  TextStyle(
                    fontSize: rotulo.tam,
                    fontWeight: rotulo.peso,
                    fontFamily: rotulo.fonte,
                    fontVariations: const [],
                  ),
                ),
          );
        } else if (rotulo is Text) {
          texto = rotulo.data ?? rotulo.textSpan?.toPlainText() ?? '';
          estilo = estilo.merge(rotulo.style);
        }
        final medida = TextPainter(
          text: TextSpan(text: texto, style: estilo),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        // O DataTable reserva 18 pontos para ordenar e outros 18 ao centralizar.
        final seta = coluna.onSort == null
            ? 0.0
            : coluna.headingRowAlignment == MainAxisAlignment.center
            ? 36.0
            : 18.0;
        minimas.add(
          medida.width.ceilToDouble() +
              1 +
              seta +
              14 +
              (i == 0 || i == larguras.length - 1 ? 17 : 0),
        );
        medida.dispose();
      }
      final medidas = [
        for (var i = 0; i < larguras.length; i++)
          math.max(
            minimas[i],
            larguras[i] + 14 + (i == 0 || i == larguras.length - 1 ? 17 : 0),
          ),
      ];
      minimas[minimas.length - 1] += espacoAntesAcoes;
      medidas[medidas.length - 1] += espacoAntesAcoes;
      final totalInicial = medidas.fold(0.0, (a, b) => a + b);
      if (totalInicial > limites.maxWidth) {
        medidas[colunaExpansivel] -= math.min(
          totalInicial - limites.maxWidth,
          math.max(
            0.0,
            medidas[colunaExpansivel] -
                math.max(180, minimas[colunaExpansivel]),
          ),
        );
      }
      final minimo = medidas.fold(0.0, (a, b) => a + b);
      final largura = math.max(minimo, limites.maxWidth);
      medidas[colunaExpansivel] += largura - minimo;
      DataTable parte(DataTable tabela, bool cabecalho) => TabelaPadrao(
        esconderSeparadorInicial: !cabecalho,
        headingRowHeight: cabecalho ? alturaCabecalho : 0,
        dataRowMinHeight: alturaLinha,
        dataRowMaxHeight: alturaLinha,
        columnSpacing: 14,
        showCheckboxColumn: false,
        sortColumnIndex: cabecalho ? tabela.sortColumnIndex : null,
        sortAscending: tabela.sortAscending,
        columns: [
          for (var i = 0; i < tabela.columns.length; i++)
            DataColumn(
              label: cabecalho
                  ? Flexible(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: i == tabela.columns.length - 1
                              ? espacoAntesAcoes
                              : 0,
                        ),
                        child: tabela.columns[i].label,
                      ),
                    )
                  : const SizedBox.shrink(),
              numeric: tabela.columns[i].numeric,
              headingRowAlignment: tabela.columns[i].headingRowAlignment,
              columnWidth: FixedColumnWidth(medidas[i]),
              mouseCursor: tabela.columns[i].mouseCursor,
              onSort: cabecalho ? tabela.columns[i].onSort : null,
            ),
        ],
        rows: cabecalho
            ? const []
            : [
                for (final row in tabela.rows)
                  DataRow(
                    key: row.key,
                    selected: row.selected,
                    color: row.color,
                    mouseCursor: row.mouseCursor,
                    onSelectChanged: row.onSelectChanged,
                    onLongPress: row.onLongPress,
                    cells: [
                      for (var i = 0; i < row.cells.length; i++)
                        i != row.cells.length - 1 || espacoAntesAcoes == 0
                            ? row.cells[i]
                            : DataCell(
                                Padding(
                                  padding: EdgeInsets.only(
                                    left: espacoAntesAcoes,
                                  ),
                                  child: row.cells[i].child,
                                ),
                                placeholder: row.cells[i].placeholder,
                                showEditIcon: row.cells[i].showEditIcon,
                                onTap: row.cells[i].onTap,
                                onDoubleTap: row.cells[i].onDoubleTap,
                                onLongPress: row.cells[i].onLongPress,
                                onTapDown: row.cells[i].onTapDown,
                                onTapCancel: row.cells[i].onTapCancel,
                              ),
                    ],
                  ),
              ],
      );
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: largura,
          height: limites.maxHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              parte(cabecalho, true),
              divisor(altura: 1),
              Expanded(
                child: RolagemPorLinhas(
                  alturaLinha: alturaLinha,
                  child: TabelaPreguicosa(
                    quantidade: quantidade,
                    alturaLinha: alturaLinha,
                    alturaCabecalho: 0,
                    entradas: [...entradas, largura],
                    montar: (a, b, chave) => parte(montar(a, b, chave), false),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

// --------------------------------------------------------------------------- //
// O que já foi montado e não mudou não é montado de novo
// --------------------------------------------------------------------------- //
/// Listas e mapas valem pelo OBJETO (trocar a lista é a forma de dizer que ela mudou); o
/// resto, pelo valor.
bool _mesmasEntradas(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (identical(x, y)) continue;
    if (x is List || x is Map || x is Set || x != y) return false;
  }
  return true;
}

/// Guarda um controle montado enquanto as entradas dele forem as mesmas. Devolver o MESMO
/// controle a cada redesenho da tela faz o Flutter pular a parte inteira: nada dela é
/// remontado, medido ou pintado de novo.
class Guardado<T> {
  List<Object?>? _de;
  T? _valor;
  int _revisao = -1;

  T obter(List<Object?> de, T Function() montar) {
    final antes = _de;
    if (_revisao == revisaoDoEstilo &&
        antes != null &&
        _mesmasEntradas(antes, de))
      return _valor as T;
    final novo = montar();
    _de = de;
    _valor = novo;
    _revisao = revisaoDoEstilo;
    return novo;
  }
}

/// As células já montadas das linhas de uma tabela, enquanto os dados de onde elas saem
/// forem os mesmos: travar/destravar a tela e trocar de página não remontam o conteúdo das
/// linhas que já existiam.
class CelulasProntas {
  List<Object?>? _de;
  int _revisao = -1;
  final Map<Object, List<DataCell>> _linhas = {};

  List<DataCell> da(
    List<Object?> de,
    Object linha,
    List<DataCell> Function() montar,
  ) {
    final antes = _de;
    if (_revisao != revisaoDoEstilo ||
        antes == null ||
        !_mesmasEntradas(antes, de)) {
      _de = de;
      _revisao = revisaoDoEstilo;
      _linhas.clear();
    }
    return _linhas[linha] ??= montar();
  }
}

// --------------------------------------------------------------------------- //
// Tabela que só monta as linhas que estão à vista
// --------------------------------------------------------------------------- //
/// Monta a tabela com as linhas de [primeira] a [ultima] (inclusive; vazia se ultima <
/// primeira). Cada linha leva a chave que [chave] dá ao índice dela.
typedef MontarTabela = DataTable Function(
  int primeira,
  int ultima,
  LocalKey Function(int indice) chave,
);

/// A `DataTable` de uma tela de lista (dentro da rolagem vertical da tela), montada só na
/// faixa de linhas que está à vista — mais uma sobra em cima e embaixo. O que fica de fora
/// vira espaço em branco da altura exata, de modo que a rolagem e a barra são as de uma
/// tabela inteira. Página de 100 linhas custa o mesmo que uma de 15.
///
/// Vale para tabelas de linhas de altura FIXA ([alturaLinha]: as células enchem a altura
/// máxima da linha) e colunas de largura fixa (a largura não depende de quais linhas estão
/// montadas). Com a faixa começando adiante, o cabeçalho é desenhado logo acima dela — fora
/// da área visível, onde estaria uma linha que não foi montada.
class TabelaPreguicosa extends StatefulWidget {
  const TabelaPreguicosa({
    super.key,
    required this.quantidade,
    required this.alturaLinha,
    required this.alturaCabecalho,
    required this.entradas,
    required this.montar,
  });
  final int quantidade;
  final double alturaLinha;
  final double alturaCabecalho;

  /// Tudo de que a tabela depende: enquanto for o mesmo (e a faixa também), a tabela
  /// montada é reaproveitada inteira.
  final List<Object?> entradas;
  final MontarTabela montar;

  @override
  State<TabelaPreguicosa> createState() => _TabelaPreguicosaState();
}

class _TabelaPreguicosaState extends State<TabelaPreguicosa> {
  /// Linhas montadas além da área visível, de cada lado.
  static const _sobra = 4;

  /// A faixa é refeita quando a área visível chega a esta distância da borda montada.
  static const _folga = 1;

  ScrollPosition? _posicao;
  int _primeira = 0;
  int _ultima = -1;
  Size? _janelaConferida;
  bool _conferenciaMarcada = false;
  bool _avisoMarcado = false;
  final _guardada = Guardado<Widget>();

  // A linha de índice i usa o elemento da "vaga" que lhe coube: quando a faixa anda, as
  // linhas que entram reaproveitam os elementos das que saíram.
  final Map<int, int> _vagas = {};
  int _proximaVaga = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scrollable.maybeOf(context)?.position;
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

  /// Índices (primeiro, último) das linhas que tocam a área visível.
  (int, int) _aVista(Size janela) {
    final n = widget.quantidade;
    if (n <= 0) return (0, -1);
    final h = widget.alturaLinha;
    final cab = widget.alturaCabecalho;
    final total = cab + n * h;
    final p = _posicao;
    // A área visível nunca passa da janela do programa; a medida exata só vale enquanto a
    // janela for a mesma de quando foi lida.
    var altura = janela.height;
    if (p != null && p.hasViewportDimension && _janelaConferida == janela) {
      altura = math.min(altura, p.viewportDimension);
    }
    final pixels = (p != null && p.hasPixels) ? p.pixels : 0.0;
    // A posição pode estar adiante do fim (a lista encolheu e a rolagem ainda vai ser
    // corrigida neste mesmo quadro): cobre de onde ela pode parar até onde está.
    final de = math.max(0.0, math.min(pixels, total - altura));
    final ate = math.min(total, pixels + altura);
    final a = ((de - cab) / h).floor().clamp(0, n - 1);
    final b = (((ate - cab) / h).ceil() - 1).clamp(0, n - 1);
    return (a, b);
  }

  /// Acerta a faixa montada para cobrir a área visível. Devolve true se ela mudou.
  bool _acertar(Size janela, {bool refazer = false}) {
    final n = widget.quantidade;
    final (a, b) = _aVista(janela);
    if (n <= 0) {
      final mudou = _primeira != 0 || _ultima != -1;
      _primeira = 0;
      _ultima = -1;
      return mudou;
    }
    final cobre =
        _ultima >= _primeira &&
        _ultima <= n - 1 &&
        (_primeira == 0 || a - _folga >= _primeira) &&
        (_ultima == n - 1 || b + _folga <= _ultima);
    if (cobre && !refazer) return false;
    final primeira = math.max(0, a - _sobra);
    final ultima = math.min(n - 1, b + _sobra);
    final mudou = primeira != _primeira || ultima != _ultima;
    _primeira = primeira;
    _ultima = ultima;
    return mudou;
  }

  void _rolou() {
    if (!mounted) return;
    final antes = (_primeira, _ultima);
    if (!_acertar(MediaQuery.sizeOf(context))) return;
    // A rolagem avisa fora da montagem (roda do mouse, barra, tecla). Se um dia avisar no
    // meio de um quadro, a faixa nova entra no quadro seguinte.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _primeira = antes.$1;
      _ultima = antes.$2;
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

  LocalKey _chave(int indice) => ValueKey<int>(_vagas[indice]!);

  void _distribuirVagas() {
    final livres = <int>[];
    _vagas.removeWhere((indice, vaga) {
      if (indice >= _primeira && indice <= _ultima) return false;
      livres.add(vaga);
      return true;
    });
    for (var i = _primeira; i <= _ultima; i++) {
      if (!_vagas.containsKey(i)) {
        _vagas[i] = livres.isNotEmpty ? livres.removeLast() : _proximaVaga++;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final janela = MediaQuery.sizeOf(context);
    _acertar(janela);
    if (_janelaConferida != janela && !_conferenciaMarcada) {
      // Janela nova (ou primeira vez): neste quadro vale o teto (a altura da janela); depois
      // dele a área visível de verdade já foi medida.
      _conferenciaMarcada = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _conferenciaMarcada = false;
        if (!mounted) return;
        _janelaConferida = MediaQuery.sizeOf(context);
        if (_acertar(_janelaConferida!)) setState(() {});
      });
    }
    final n = widget.quantidade;
    final h = widget.alturaLinha;
    return _guardada.obter([...widget.entradas, n, h, _primeira, _ultima], () {
      _distribuirVagas();
      return Padding(
        padding: EdgeInsets.only(
          top: _primeira * h,
          bottom: n <= 0 ? 0 : (n - 1 - _ultima) * h,
        ),
        // Os botões de ação das linhas são os compactos (ver Medida, em estilo.dart): cabem
        // numa linha baixa.
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: (IconButtonTheme.of(context).style ?? const ButtonStyle())
                .merge(_botaoDaLinha),
          ),
          child: widget.montar(_primeira, _ultima, _chave),
        ),
      );
    });
  }
}

const _botaoDaLinha = ButtonStyle(
  fixedSize: WidgetStatePropertyAll<Size?>(Size.square(Medida.botaoDaLinha)),
  minimumSize: WidgetStatePropertyAll<Size?>(Size.zero),
  padding: WidgetStatePropertyAll<EdgeInsetsGeometry?>(EdgeInsets.zero),
  iconSize: WidgetStatePropertyAll<double?>(Medida.iconeDaLinha),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
);

/// Botão "mais ações" (os três pontinhos) de uma linha de tabela: abre um menu com [itens].
class MenuMais extends StatelessWidget {
  const MenuMais(this.itens, {super.key});
  final List<PopupMenuEntry<String>> Function() itens;

  @override
  Widget build(BuildContext context) => comDica(
    'Mais ações',
    TooltipVisibility(
      visible: false,
      child: PopupMenuButton<String>(
        enabled: !travado(context),
        tooltip: null,
        icon: const Icon(Icons.more_horiz),
        padding: EdgeInsets.zero,
        style: _botaoDaLinha.copyWith(alignment: Alignment.center),
        iconSize: Medida.iconeDaLinha,
        clipBehavior: Clip.antiAlias,
        onSelected: (_) {},
        onCanceled: () {},
        onOpened: () {},
        itemBuilder: (context) => itens(),
      ),
    ),
  );
}

/// Cor de uma linha com realce de hover. Apertada repete a cor do hover (sem isso a linha
/// fica preta enquanto o botão do mouse está apertado).
WidgetStateProperty<Color?> corLinha(Color normal, Color hover) =>
    WidgetStateProperty.resolveWith((estados) {
      if (estados.contains(WidgetState.hovered)) return hover;
      if (estados.contains(WidgetState.pressed)) return hover;
      return normal;
    });

final hoverPadrao = corLinha(Colors.transparent, Colors.indigo.shade50);
final hoverPendente = corLinha(Colors.orange.shade50, Colors.orange.shade100);

/// Pares de SUBSTITUIÇÃO (nota antiga + substituta) à vista ganham a mesma cor de fundo, um
/// tom pastel por par: (normal, hover). 8 cores antes de repetir.
final coresDePar = <(Color, Color)>[
  (Colors.purple.shade50, Colors.purple.shade100),
  (Colors.lightBlue.shade50, Colors.lightBlue.shade100),
  (Colors.green.shade50, Colors.green.shade100),
  (Colors.yellow.shade50, Colors.yellow.shade100),
  (Colors.cyan.shade50, Colors.cyan.shade100),
  (Colors.pink.shade50, Colors.pink.shade100),
  (Colors.lime.shade50, Colors.lime.shade100),
  (Colors.brown.shade50, Colors.brown.shade100),
];

/// Campo "ir para página", compacto e da mesma altura do seletor de itens por página.
class CampoIrPagina extends StatelessWidget {
  const CampoIrPagina({super.key, required this.controle, required this.aoIr});
  final TextEditingController controle;
  final ValueChanged<int> aoIr;

  @override
  Widget build(BuildContext context) => CampoTexto(
    controle: controle,
    largura: 58,
    altura: Medida.controleDePagina,
    compacto: true,
    tamanhoTexto: Letra.campo,
    alinhamento: TextAlign.center,
    dica: 'nº',
    // Não é "denso": o campo enche a altura dada (a do controle), com o texto no meio.
    denso: false,
    preenchimento: const EdgeInsets.fromLTRB(6, 2, 6, 2),
    aoEnviar: (_) {
      final digitos = controle.text.replaceAll(RegExp(r'[^0-9]'), '');
      controle.text = '';
      if (digitos.isNotEmpty) aoIr(int.parse(digitos) - 1);
    },
  );
}

/// Seletor "itens por página" (menu), da mesma altura do campo "ir para página".
class SeletorPorPagina extends StatelessWidget {
  const SeletorPorPagina({
    super.key,
    required this.atual,
    required this.aoEscolher,
  });
  final int atual;
  final ValueChanged<int> aoEscolher;

  @override
  Widget build(BuildContext context) => comDica(
    'Itens por página',
    TooltipVisibility(
      visible: false,
      child: PopupMenuButton<String>(
        enabled: !travado(context),
        tooltip: null,
        padding: EdgeInsets.zero,
        style: _botaoDaLinha.copyWith(alignment: Alignment.center),
        iconSize: Medida.iconeDaLinha,
        clipBehavior: Clip.antiAlias,
        onSelected: (_) {},
        onCanceled: () {},
        onOpened: () {},
        itemBuilder: (context) => [
          for (final n in tamanhosDePagina)
            PopupMenuItem<String>(
              value: '$n',
              height: 48,
              onTap: () => aoEscolher(n),
              child: Tx('$n', tam: Letra.texto),
            ),
        ],
        child: MouseRegion(
          cursor: travado(context)
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: Ct(
            altura: Medida.controleDePagina,
            padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
            alinhar: Alignment.center,
            borda: Border.all(color: Colors.grey.shade400, width: 1),
            raio: BorderRadius.circular(6),
            child: lin(
              [
                Tx('$atual', tam: Letra.texto, peso: FontWeight.w600),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
              espaco: 2,
              justa: true,
              principal: MainAxisAlignment.center,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Barra de paginação: anterior / "Página X de N" / próxima / ir para / por página.
class BarraPaginacao extends StatelessWidget {
  const BarraPaginacao({
    super.key,
    required this.pagina,
    required this.paginas,
    required this.porPagina,
    required this.controleIr,
    required this.aoIr,
    required this.aoPorPagina,
    this.rotulo,
  });
  final int pagina;
  final int paginas;
  final int porPagina;
  final TextEditingController controleIr;
  final ValueChanged<int> aoIr;
  final ValueChanged<int> aoPorPagina;

  /// Texto no lugar de "Página X de N".
  final String? rotulo;

  @override
  Widget build(BuildContext context) => lin([
    BotaoIcone(
      Icons.chevron_left,
      dica: 'Página anterior',
      desabilitado: pagina <= 0,
      aoClicar: () => aoIr(pagina - 1),
    ),
    Tx(rotulo ?? 'Página ${pagina + 1} de $paginas', peso: FontWeight.w600),
    BotaoIcone(
      Icons.chevron_right,
      dica: 'Próxima página',
      desabilitado: pagina >= paginas - 1,
      aoClicar: () => aoIr(pagina + 1),
    ),
    const Ct(largura: 16),
    const Tx('Ir para página:', tam: Letra.texto),
    CampoIrPagina(controle: controleIr, aoIr: aoIr),
    const Expanded(child: SizedBox()),
    const Tx('Por página:', tam: Letra.texto),
    SeletorPorPagina(atual: porPagina, aoEscolher: aoPorPagina),
  ], espaco: 6);
}

/// Busca AO VIVO: a lista acompanha a digitação.
/// - tecla isolada: a recarga sai no passo seguinte, sem espera;
/// - rajada (tecla presa, colar): as teclas que chegam com uma recarga marcada não marcam
///   outra, e entre o começo de uma recarga e o da seguinte passam pelo menos 80 ms;
/// - recarga CARA (nenhuma das 3 últimas em menos de 50 ms): volta a esperar o teclado
///   parar (250 ms); uma recarga barata basta para voltar a ser ao vivo.
class BuscaAoVivo {
  static const _ritmo = Duration(milliseconds: 80);
  static const _cara = Duration(milliseconds: 50);
  static const _pausa = Duration(milliseconds: 250);

  Timer? _marcada;
  DateTime _inicio = DateTime.fromMillisecondsSinceEpoch(0);
  List<Duration> _custos = const [];

  void tecla(void Function() recarregar, {bool Function()? viva}) {
    Duration espera;
    final cara = _custos.length == 3 && _custos.every((c) => c > _cara);
    if (cara) {
      _marcada?.cancel(); // recarga cara: só quando o teclado parar
      espera = _pausa;
    } else if (_marcada != null) {
      return;
    } else {
      espera = _inicio.add(_ritmo).difference(DateTime.now());
      if (espera.isNegative) espera = Duration.zero;
    }
    _marcada = Timer(espera, () {
      _marcada = null;
      if (viva != null && !viva()) return;
      final t0 = DateTime.now();
      try {
        recarregar();
      } catch (_) {}
      final ultimos = _custos.length > 2
          ? _custos.sublist(_custos.length - 2)
          : _custos;
      _custos = [...ultimos, DateTime.now().difference(t0)];
      _inicio = t0;
    });
  }

  void cancelar() {
    _marcada?.cancel();
    _marcada = null;
  }
}

/// Ordenação ESTÁVEL por chave de texto; invertida, os iguais mantêm a ordem em que estavam.
void ordenarPor<T>(
  List<T> lista,
  String Function(T) chave, {
  required bool crescente,
}) {
  final marcados = [
    for (var i = 0; i < lista.length; i++) (chave(lista[i]), i, lista[i]),
  ];
  marcados.sort((a, b) {
    final c = crescente ? a.$1.compareTo(b.$1) : b.$1.compareTo(a.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  for (var i = 0; i < lista.length; i++) {
    lista[i] = marcados[i].$3;
  }
}
