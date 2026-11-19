part of 'dashboard.dart';

const _textoGrafico = Color(0xffb3cdd0);
const _linhaGrafico = Color(0x397cc0c3);
const _coresComparacao = [
  _verdeGrafico,
  _azulGrafico,
  Color(0xfff6bc78),
  Color(0xfff5a9d2),
];

enum _Passo { hora, dia, semana, mes, ano }

class _LinhaGrafico {
  const _LinhaGrafico(this.rotulo, this.dica, this.cor);
  final String rotulo, dica;
  final Color cor;
}

class _ColunaGrafico {
  const _ColunaGrafico(
    this.inicio,
    this.fim,
    this.rotulo,
    this.intervalo,
    this.valores,
  );
  final int inicio, fim;
  final String rotulo, intervalo;
  final List<int> valores;
  double get centro => (inicio + fim) / 2;
}

class _DadosGrafico {
  _DadosGrafico(Map m, this.periodos, String modo) {
    final atual = periodos.first;
    unidade = switch (m['passo']) {
      'hora' => _Passo.hora,
      'dia' => _Passo.dia,
      'mes' => _Passo.mes,
      _ => _Passo.values.byName(m['grupo'] as String),
    };
    final series = m['series'] as List?;
    comparativo = series != null && periodos.length > 1;
    linhas = comparativo
        ? [
            for (var i = 0; i < periodos.length; i++)
              _LinhaGrafico(
                _nomeDoPeriodo(periodos[i].inicio, modo),
                periodos[i].intervalo,
                _coresComparacao[i],
              ),
          ]
        : const [
            _LinhaGrafico('Bruto', 'Faturamento bruto', _verdeGrafico),
            _LinhaGrafico('Líquido', 'Valor líquido das notas', _azulGrafico),
          ];
    if (series == null) {
      // Núcleos anteriores já entregam as faixas abertas no dashboard.
      final faixas = (m['faixas'] as List).cast<Map>();
      todos = faixas.length;
      recente = math.max(
        0,
        faixas.lastIndexWhere((f) => _numero(f, 'notas') > 0),
      );
      temNotas = faixas.any((f) => _numero(f, 'notas') > 0);
      camadas[unidade] = [
        for (var i = 0; i < faixas.length; i++) _colunaAnterior(i, faixas[i]),
      ];
      return;
    }
    todos = switch (unidade) {
      _Passo.hora =>
        (series.cast<List>().any(
              (linha) => linha.cast<List>().any((ponto) => ponto[0] == ''),
            ))
            ? 25
            : 24,
      _Passo.mes => _mesesEntre(atual.inicio, atual.fim) + 1,
      _ => atual.dias,
    };

    final valores = List.generate(linhas.length, (_) => List.filled(todos, 0));
    for (var i = 0; i < math.min(series.length, periodos.length); i++) {
      for (final ponto in (series[i] as List).cast<List>()) {
        final posicao = _indiceDoPonto(ponto[0] as String, periodos[i]);
        if (posicao < 0 || posicao >= todos) continue;
        final bruto = (ponto[1] as num).toInt();
        final liquido = (ponto[2] as num).toInt();
        final notas = (ponto[3] as num).toInt();
        if (notas > 0) {
          temNotas = true;
          if (i == 0) recente = math.max(recente, posicao);
        }
        valores[i][posicao] += bruto;
        if (!comparativo) valores[1][posicao] += liquido;
      }
    }
    camadas[unidade] = _agrupar(unidade, valores);
    if (unidade == _Passo.dia) {
      camadas[_Passo.semana] = _agrupar(_Passo.semana, valores);
      camadas[_Passo.mes] = _agrupar(_Passo.mes, valores);
    }
    if (unidade == _Passo.mes) {
      camadas[_Passo.ano] = _agrupar(_Passo.ano, valores);
    }
  }

  final List<_PeriodoGrafico> periodos;
  final camadas = <_Passo, List<_ColunaGrafico>>{};
  late final List<_LinhaGrafico> linhas;
  late final _Passo unidade;
  late final int todos;
  late final bool comparativo;
  bool temNotas = false;
  int recente = 0;

  static int _mesesEntre(DateTime a, DateTime b) =>
      (b.year - a.year) * 12 + b.month - a.month;

  static String _nomeDoPeriodo(DateTime inicio, String modo) => switch (modo) {
    'ano' => '${inicio.year}',
    'mes' || 'mes_ant' => _mesAno(inicio),
    _ => dataBr(inicio),
  };

  _ColunaGrafico _colunaAnterior(int i, Map mapa) {
    final inicio = DateTime.parse(mapa['inicio'] as String);
    final fim = DateTime.parse(mapa['fim'] as String);
    final bruto = _numero(mapa, 'bruto');
    return _ColunaGrafico(
      i,
      i + 1,
      _rotuloData(unidade, inicio),
      _intervaloDatas(inicio, fim),
      comparativo
          ? [bruto, for (final _ in periodos.skip(1)) 0]
          : [bruto, _numero(mapa, 'liquido')],
    );
  }

  int _indiceDoPonto(String chave, _PeriodoGrafico p) {
    if (unidade == _Passo.hora) {
      return chave.isEmpty ? 24 : int.tryParse(chave) ?? -1;
    }
    final dia = _diaUtc(DateTime.parse(chave));
    final inicio = periodos.first.inicio;
    if (unidade == _Passo.mes)
      return _mesesEntre(p.inicio, dia).clamp(0, todos - 1);
    if (p.mesesAteAtual == 0) return dia.difference(p.inicio).inDays;
    // Ao alinhar fevereiro entre anos bissextos e comuns, os dias do
    // intervalo histórico continuam representados nas bordas da janela.
    return _moverMeses(
      dia,
      p.mesesAteAtual,
    ).difference(inicio).inDays.clamp(0, todos - 1);
  }

  DateTime _data(int i) {
    final inicio = periodos.first.inicio;
    return unidade == _Passo.mes
        ? DateTime.utc(inicio.year, inicio.month + i)
        : inicio.add(Duration(days: i));
  }

  List<_ColunaGrafico> _agrupar(_Passo passo, List<List<int>> serie) {
    final pontos = <_ColunaGrafico>[];
    for (var inicio = 0; inicio < todos;) {
      final data = unidade == _Passo.hora
          ? periodos.first.inicio
          : _data(inicio);
      final salto = switch (passo) {
        _Passo.semana => 7,
        _Passo.mes when unidade == _Passo.dia => DateTime.utc(
          data.year,
          data.month + 1,
        ).difference(data).inDays,
        _Passo.ano => 13 - data.month,
        _ => 1,
      };
      final fim = math.min(todos, inicio + salto);
      final valores = [
        for (final linha in serie)
          linha.getRange(inicio, fim).fold(0, (total, n) => total + n),
      ];
      final semHorario = passo == _Passo.hora && inicio == 24;
      pontos.add(
        _ColunaGrafico(
          inicio,
          fim,
          semHorario
              ? 'Sem horário'
              : passo == _Passo.hora
              ? _hora(inicio)
              : _rotuloData(passo, data),
          passo == _Passo.hora
              ? (semHorario
                    ? 'Sem horário'
                    : '${_hora(inicio)} – ${_hora(fim)}')
              : _intervaloDatas(
                  data.isBefore(periodos.first.inicio)
                      ? periodos.first.inicio
                      : data,
                  unidade == _Passo.mes
                      ? _fimDoMesNaJanela(fim - 1)
                      : _data(fim - 1),
                ),
          valores,
        ),
      );
      inicio = fim;
    }
    return pontos;
  }

  DateTime _fimDoMesNaJanela(int i) {
    final mes = _data(i);
    final fim = DateTime.utc(mes.year, mes.month + 1, 0);
    return fim.isAfter(periodos.first.fim) ? periodos.first.fim : fim;
  }

  _Passo passoVisivel(double amplitude) {
    if (camadas.length == 1) return unidade;
    if (unidade == _Passo.mes) return amplitude > 72 ? _Passo.ano : _Passo.mes;
    if (amplitude <= 36) return _Passo.dia;
    if (amplitude <= 112) return _Passo.semana;
    return _Passo.mes;
  }

  static String _hora(int h) => '${h.toString().padLeft(2, '0')}h';

  static String _intervaloDatas(DateTime a, DateTime b) =>
      a == b ? dataBr(a) : '${dataBr(a)} – ${dataBr(b)}';
}

const _mesesGrafico = [
  'Jan',
  'Fev',
  'Mar',
  'Abr',
  'Mai',
  'Jun',
  'Jul',
  'Ago',
  'Set',
  'Out',
  'Nov',
  'Dez',
];

String _mesAno(DateTime data) =>
    '${_mesesGrafico[data.month - 1]}/${(data.year % 100).toString().padLeft(2, '0')}';

String _rotuloData(_Passo passo, DateTime data) => switch (passo) {
  _Passo.ano => '${data.year}',
  _Passo.mes => _mesAno(data),
  _ =>
    '${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')}',
};

class _Receita extends StatefulWidget {
  const _Receita({super.key, required this.dados, required this.mostrar});
  final _DadosGrafico dados;
  final bool mostrar;

  @override
  State<_Receita> createState() => _ReceitaState();
}

typedef _Janela = (double, double);

class _ReceitaState extends State<_Receita>
    with SingleTickerProviderStateMixin {
  final _foco = FocusNode();
  final _selecao = ValueNotifier<double?>(null);
  late final _animacao = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 155),
    value: 1,
  );
  late _Janela _origem = _inteira;
  late _Janela _alvo = _inteira;
  _DadosGrafico get dados => widget.dados;

  _Janela get _inteira => (0, dados.todos.toDouble());
  double get _amplitudeMinima => math.min(3.0, dados.todos.toDouble());

  _Janela get _janela {
    final t = Curves.easeOutCubic.transform(_animacao.value);
    return (
      _origem.$1 + (_alvo.$1 - _origem.$1) * t,
      _origem.$2 + (_alvo.$2 - _origem.$2) * t,
    );
  }

  @override
  void didUpdateWidget(covariant _Receita oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dados.todos != dados.todos) {
      _alvo = _origem = _inteira;
      _animacao.value = 1;
      _selecao.value = null;
    }
  }

  @override
  void dispose() {
    _animacao.dispose();
    _selecao.dispose();
    _foco.dispose();
    super.dispose();
  }

  _Janela _comZoom(bool aproximar, double ancora) {
    final (de, ate) = _alvo;
    final largura = ate - de;
    final nova = (largura * (aproximar ? .63 : 1 / .63)).clamp(
      _amplitudeMinima,
      dados.todos.toDouble(),
    );
    final inicio = (de + (largura - nova) * ancora).clamp(
      0.0,
      dados.todos - nova,
    );
    return (inicio, inicio + nova);
  }

  void _aplicarZoom(_Janela destino) {
    if (destino == _alvo) return;
    _origem = _janela;
    _alvo = destino;
    _animacao.forward(from: 0);
  }

  void _zoomPeloBotao(bool aproximar) =>
      _aplicarZoom(_comZoom(aproximar, _selecao.value ?? .5));

  @override
  Widget build(BuildContext context) {
    final estilo = Theme.of(
      context,
    ).textTheme.bodySmall!.copyWith(fontSize: 10.5, color: _textoGrafico);
    return _CartaoDashboard(
      escuro: true,
      child: SizedBox(
        height: dados.comparativo ? 326 : 300,
        child: AnimatedBuilder(
          animation: _animacao,
          builder: (context, _) {
            final vista = _VistaReceita(dados, _janela, widget.mostrar);
            final rotulo = switch (vista.passo) {
              _Passo.hora => 'Por hora',
              _Passo.dia => 'Diário',
              _Passo.semana => 'Semanal',
              _Passo.mes => 'Mensal',
              _Passo.ano => 'Anual',
            };
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Tx(
                        'Receita por período',
                        tam: 19,
                        peso: FontWeight.w700,
                        cor: Colors.white,
                        idLayout: 'Dashboard.receita.titulo',
                      ),
                    ),
                    _lupa(
                      false,
                      TamanhosDashboard.afastar,
                      Icons.zoom_out,
                      'Afastar gráfico',
                    ),
                    _lupa(
                      true,
                      TamanhosDashboard.aproximar,
                      Icons.zoom_in,
                      'Aproximar gráfico',
                    ),
                  ],
                ),
                Tx(
                  dados.comparativo ? '$rotulo  •  Faturamento bruto' : rotulo,
                  tam: Letra.texto,
                  cor: _textoGrafico,
                  idLayout: 'Dashboard.receita.subtitulo',
                ),
                const SizedBox(height: 9),
                ValueListenableBuilder<double?>(
                  valueListenable: _selecao,
                  builder: (context, selecao, _) {
                    final selecionada = vista.selecionada(selecao);
                    return Semantics(
                      liveRegion: _foco.hasFocus,
                      child: Wrap(
                        spacing: 14,
                        runSpacing: 5,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Tx(
                            selecionada.intervalo,
                            cor: Colors.white,
                            tam: Letra.apoio,
                            peso: FontWeight.w600,
                            idLayout: 'Dashboard.receita.data',
                          ),
                          for (var i = 0; i < dados.linhas.length; i++)
                            _leitura(
                              dados.linhas[i],
                              selecionada.valores[i],
                              i,
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Expanded(child: _grafico(vista, estilo)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _lupa(bool aproximar, Tamanho tamanho, IconData icone, String dica) =>
      BotaoIcone(
        icone,
        dica: dica,
        cor: _textoGrafico,
        tamanho: 21,
        desabilitado: _comZoom(aproximar, .5) == _alvo,
        aoClicar: () => _zoomPeloBotao(aproximar),
        largura: tamanho.largura,
        altura: tamanho.altura,
        idLayout: tamanho.id,
      );

  Widget _leitura(_LinhaGrafico linha, int valor, int id) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Marcador(linha.cor),
          const SizedBox(width: 6),
          Tx(
            linha.rotulo,
            dica: linha.dica,
            cor: _textoGrafico,
            tam: Letra.apoio,
            idLayout: 'Dashboard.receita.legenda.$id',
          ),
        ],
      ),
      Tx(
        _brl(valor, mostrar: widget.mostrar),
        cor: Colors.white,
        peso: FontWeight.w700,
        idLayout: 'Dashboard.receita.valor.$id',
      ),
    ],
  );

  Widget _grafico(_VistaReceita vista, TextStyle estilo) {
    return Focus(
      focusNode: _foco,
      onKeyEvent: (_, evento) {
        if (evento is KeyUpEvent) return KeyEventResult.ignored;
        final delta = switch (evento.logicalKey) {
          LogicalKeyboardKey.arrowLeft => -1,
          LogicalKeyboardKey.arrowRight => 1,
          _ => 0,
        };
        if (delta == 0) return KeyEventResult.ignored;
        final i = vista.colunas.indexOf(vista.selecionada(_selecao.value));
        final destino =
            vista.colunas[(i + delta).clamp(0, vista.colunas.length - 1)];
        _selecao.value = vista.fracao(destino.centro);
        return KeyEventResult.handled;
      },
      child: Semantics(
        label: 'Gráfico de receita. Use as setas para percorrer os períodos.',
        child: LayoutBuilder(
          builder: (context, limites) {
            final caixa = _VistaReceita.caixa(
              Size(limites.maxWidth, limites.maxHeight),
            );
            double fracao(Offset pos) =>
                ((pos.dx - caixa.left) / caixa.width).clamp(0.0, 1.0);
            return Listener(
              onPointerSignal: (evento) {
                if (evento is! PointerScrollEvent) return;
                final ancora = fracao(evento.localPosition);
                // A roda pertence ao gráfico também nos limites de zoom.
                GestureBinding.instance.pointerSignalResolver.register(evento, (
                  _,
                ) {
                  if (evento.scrollDelta.dy == 0) return;
                  _selecao.value = ancora;
                  _aplicarZoom(_comZoom(evento.scrollDelta.dy < 0, ancora));
                });
              },
              child: MouseRegion(
                onHover: (evento) =>
                    _selecao.value = fracao(evento.localPosition),
                onExit: (_) {
                  if (!_foco.hasFocus) _selecao.value = null;
                },
                child: Gesto(
                  cursor: SystemMouseCursors.click,
                  aoTocar: _foco.requestFocus,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: _PintorReceita(vista, estilo),
                        ),
                      ),
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: _PintorSelecao(vista, _selecao),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VistaReceita {
  _VistaReceita(this.dados, this.janela, this.mostrar) {
    passo = dados.passoVisivel(janela.$2 - janela.$1);
    final camada = dados.camadas[passo]!;
    // Lookups por posição evitam percorrer todo o histórico a cada frame de zoom.
    final primeira = _indice(camada, janela.$1);
    final ultima = _indice(camada, janela.$2 - .0001);
    colunas = camada.sublist(primeira, ultima + 1);
    if (!mostrar) {
      teto = 4;
      return;
    }
    var maximo = 0;
    for (final coluna in colunas) {
      for (final valor in coluna.valores) {
        maximo = math.max(maximo, valor);
      }
    }
    final alvo = math.max(1.0, maximo / 4);
    final ordem = math.pow(10, (math.log(alvo) / math.ln10).floor());
    final passoEixo = [1, 2, 2.5, 5, 10].firstWhere((p) => p * ordem >= alvo);
    teto = (4 * passoEixo * ordem).toDouble();
  }

  final _DadosGrafico dados;
  final _Janela janela;
  final bool mostrar;
  late final _Passo passo;
  late final double teto;
  late final List<_ColunaGrafico> colunas;

  static int _indice(List<_ColunaGrafico> colunas, double posicao) {
    var a = 0;
    var b = colunas.length - 1;
    while (a < b) {
      final meio = (a + b) ~/ 2;
      if (colunas[meio].fim <= posicao) {
        a = meio + 1;
      } else {
        b = meio;
      }
    }
    return a;
  }

  _ColunaGrafico selecionada(double? posicao) {
    final unidade = posicao == null
        ? (mostrar ? dados.recente.toDouble() : janela.$2)
        : janela.$1 + posicao * (janela.$2 - janela.$1);
    return colunas[_indice(colunas, unidade)];
  }

  static Rect caixa(Size s) => Rect.fromLTRB(
    60,
    10,
    math.max(61, s.width - 15),
    math.max(11, s.height - 24),
  );
  double fracao(double posicao) =>
      ((posicao - janela.$1) / (janela.$2 - janela.$1)).clamp(0.0, 1.0);
  double x(_ColunaGrafico c, Rect r) =>
      colunas.length == 1 ? r.center.dx : r.left + r.width * fracao(c.centro);
  double y(int valor, Rect r) =>
      r.bottom - (valor / teto).clamp(0.0, 1.0) * r.height;
}

class _PintorReceita extends CustomPainter {
  _PintorReceita(this.vista, this.estilo);
  final _VistaReceita vista;
  final TextStyle estilo;

  @override
  void paint(Canvas canvas, Size size) {
    final r = _VistaReceita.caixa(size);
    final linhas = Paint()
      ..color = _linhaGrafico
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = r.bottom - r.height * i / 4;
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), linhas);
      _texto(
        canvas,
        vista.mostrar ? _abreviar(vista.teto * i / 4) : _asteriscos,
        Offset(r.left - 9, y),
        estilo,
        alinhamento: 1,
        meioDaAltura: true,
      );
    }

    final n = vista.colunas.length;
    final marcas = math.min(n, math.max(2, (r.width / 62).floor()));
    for (var i = 0; i < marcas; i++) {
      final posicao = marcas == 1 ? 0 : (i * (n - 1) / (marcas - 1)).round();
      final coluna = vista.colunas[posicao];
      _texto(
        canvas,
        coluna.rotulo,
        Offset(vista.x(coluna, r), r.bottom + 9),
        estilo,
        alinhamento: .5,
        largura: size.width,
      );
    }

    if (!vista.mostrar) {
      _texto(
        canvas,
        'Valores ocultos',
        r.center,
        estilo,
        alinhamento: .5,
        meioDaAltura: true,
      );
      return;
    }
    canvas.save();
    canvas.clipRect(r.inflate(6));
    for (var i = vista.dados.linhas.length - 1; i >= 0; i--) {
      _serie(canvas, r, i);
    }
    canvas.restore();
  }

  void _serie(Canvas canvas, Rect r, int i) {
    final cor = vista.dados.linhas[i].cor;
    final pontos = [
      for (final c in vista.colunas)
        Offset(vista.x(c, r), vista.y(c.valores[i], r)),
    ];
    final primeiro = pontos.first;
    if (pontos.length == 1) {
      canvas.drawCircle(primeiro, 3.5, Paint()..color = cor);
      return;
    }
    final linha = Path()..moveTo(primeiro.dx, primeiro.dy);
    for (var i = 1; i < pontos.length; i++) {
      final a = pontos[i - 1], b = pontos[i];
      final d = (b.dx - a.dx) * .38;
      linha.cubicTo(a.dx + d, a.dy, b.dx - d, b.dy, b.dx, b.dy);
    }
    if (i == 0 && !vista.dados.comparativo) {
      final area = Path.from(linha)
        ..lineTo(pontos.last.dx, r.bottom)
        ..lineTo(primeiro.dx, r.bottom)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            colors: [cor.withValues(alpha: .28), cor.withValues(alpha: .015)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ).createShader(r),
      );
    }
    canvas.drawPath(
      linha,
      Paint()
        ..color = cor
        ..style = PaintingStyle.stroke
        ..strokeWidth = i == 0 ? 2.8 : 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_PintorReceita anterior) =>
      vista.janela != anterior.vista.janela ||
      vista.dados != anterior.vista.dados ||
      vista.mostrar != anterior.vista.mostrar ||
      estilo != anterior.estilo;
}

String _abreviar(double centavos) {
  final valor = centavos / 100;
  final (numero, sufixo) = switch (valor) {
    >= 1000000000 => (valor / 1000000000, ' bi'),
    >= 1000000 => (valor / 1000000, ' mi'),
    >= 1000 => (valor / 1000, ' mil'),
    _ => (valor, ''),
  };
  final casas = numero.truncateToDouble() == numero ? 0 : (valor < 1 ? 2 : 1);
  return '${numero.toStringAsFixed(casas).replaceAll('.', ',')}$sufixo';
}

void _texto(
  Canvas canvas,
  String texto,
  Offset posicao,
  TextStyle estilo, {
  required double alinhamento,
  bool meioDaAltura = false,
  double? largura,
}) {
  final p = TextPainter(
    text: TextSpan(text: texto, style: estilo),
    textDirection: TextDirection.ltr,
  )..layout();
  final x = posicao.dx - p.width * alinhamento;
  p.paint(
    canvas,
    Offset(
      largura == null ? x : x.clamp(0.0, math.max(0.0, largura - p.width)),
      posicao.dy - (meioDaAltura ? p.height / 2 : 0),
    ),
  );
  p.dispose();
}

class _PintorSelecao extends CustomPainter {
  _PintorSelecao(this.vista, this.selecao) : super(repaint: selecao);
  final _VistaReceita vista;
  final ValueNotifier<double?> selecao;

  @override
  void paint(Canvas canvas, Size size) {
    final r = _VistaReceita.caixa(size);
    final coluna = vista.selecionada(selecao.value);
    final x = vista.x(coluna, r);
    final linha = Paint()
      ..strokeWidth = 1
      ..color = const Color(0xff638b8b);
    for (var y = r.top; y < r.bottom; y += 7) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, math.min(y + 3, r.bottom)),
        linha,
      );
    }
    if (!vista.mostrar) return;
    for (var i = coluna.valores.length - 1; i >= 0; i--) {
      final posicao = Offset(x, vista.y(coluna.valores[i], r));
      canvas.drawCircle(posicao, 5, Paint()..color = const Color(0xff193f45));
      canvas.drawCircle(
        posicao,
        3.6,
        Paint()..color = vista.dados.linhas[i].cor,
      );
    }
  }

  @override
  bool shouldRepaint(_PintorSelecao anterior) =>
      vista.janela != anterior.vista.janela ||
      vista.dados != anterior.vista.dados ||
      vista.mostrar != anterior.vista.mostrar;
}

class _Rosca extends StatelessWidget {
  const _Rosca({
    required this.proporcao,
    required this.disponivel,
    required this.mostrar,
    required this.trilha,
  });
  final double proporcao;
  final bool disponivel, mostrar;
  final Color trilha;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final percentual =
        '${(proporcao * 100).toStringAsFixed(1).replaceAll('.', ',')}%';
    return SizedBox.square(
      dimension: 144,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: disponivel && mostrar ? 1 : 0),
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeOutCubic,
              builder: (_, progresso, _) => CustomPaint(
                painter: _PintorRosca(
                  trilha,
                  mostrar ? proporcao : 0,
                  mostrar ? progresso : 0,
                ),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tx(
                  mostrar ? (disponivel ? percentual : '—') : '****%',
                  tam: 24,
                  peso: FontWeight.w700,
                  idLayout: 'Dashboard.composicao.percentual',
                ),
                Tx(
                  'retidos',
                  tam: Letra.apoio,
                  cor: cores.onSurfaceVariant,
                  idLayout: 'Dashboard.composicao.legenda',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PintorRosca extends CustomPainter {
  _PintorRosca(this.trilha, this.proporcao, this.progresso);
  final Color trilha;
  final double proporcao, progresso;

  @override
  void paint(Canvas canvas, Size size) {
    final centro = size.center(Offset.zero);
    final raio = size.shortestSide / 2 - 10;
    final contorno = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13;
    canvas.drawCircle(centro, raio, contorno..color = trilha);
    final r = Rect.fromCircle(center: centro, radius: raio);
    const volta = 2 * math.pi;
    const inicio = -math.pi / 2;
    final fatia = volta * proporcao;
    final desenho = volta * progresso;
    final separacao = proporcao > .015 && proporcao < .985 ? .052 : 0.0;
    canvas.drawArc(
      r,
      inicio + separacao,
      math.max(0, math.min(fatia, desenho) - 2 * separacao),
      false,
      contorno..color = _ambar,
    );
    canvas.drawArc(
      r,
      inicio + fatia + separacao,
      math.max(0, desenho - fatia - 2 * separacao),
      false,
      contorno..color = _verde,
    );
  }

  @override
  bool shouldRepaint(_PintorRosca anterior) =>
      trilha != anterior.trilha ||
      proporcao != anterior.proporcao ||
      progresso != anterior.progresso;
}
