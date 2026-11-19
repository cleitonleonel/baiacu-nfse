/// Visão financeira do prestador ativo, a partir das NFS-e de produção do Cofre.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart' show brlDigitos;
import 'periodo.dart';

part 'dashboard_graficos.dart';

const _verde = Color(0xff087f70);
const _verdeGrafico = Color(0xff5be0b9);
const _azulGrafico = Color(0xffaaa7fd);
const _ambar = Color(0xffeca955);

const _asteriscos = '****';

String _quantia(int centavos) =>
    brlDigitos(centavos.abs().toString()).substring(3);
String _brl(int centavos, {required bool mostrar}) => mostrar
    ? '${centavos < 0 ? '−' : ''}R\$ ${_quantia(centavos)}'
    : 'R\$ $_asteriscos';

String _percentual(double fracao) =>
    '${(fracao * 100).toStringAsFixed(1).replaceAll('.', ',')}%';

DateTime _diaUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day);

DateTime _moverMeses(DateTime data, int meses) {
  final fim = DateTime.utc(data.year, data.month + meses + 1, 0);
  return DateTime.utc(fim.year, fim.month, math.min(data.day, fim.day));
}

class _PeriodoGrafico {
  const _PeriodoGrafico(this.inicio, this.fim, {this.mesesAteAtual = 0});
  final DateTime inicio, fim;
  final int mesesAteAtual;
  int get dias => fim.difference(inicio).inDays + 1;
  List<String> get limites => [dataIso(inicio), dataIso(fim)];
  String get intervalo =>
      inicio == fim ? dataBr(inicio) : '${dataBr(inicio)} – ${dataBr(fim)}';
}

int _numero(Map m, String chave) => (m[chave] as num).toInt();

class _Valores {
  _Valores(Map m)
    : bruto = _numero(m, 'bruto'),
      liquido = _numero(m, 'liquido'),
      notas = _numero(m, 'notas');

  final int bruto, liquido, notas;
}

class _Cliente extends _Valores {
  _Cliente(Map m)
    : nome = (m['nome'] as String).trim(),
      doc = m['doc'] as String,
      super(m);

  final String nome, doc;
}

class _Resumo {
  _Resumo(Map m, List<_PeriodoGrafico> periodos, String modo)
    : grafico = _DadosGrafico(m, periodos, modo),
      total = _Valores(m['total'] as Map),
      anterior = _Valores(m['anterior'] as Map),
      anteriorIni = DateTime.parse(m['anterior_ini'] as String),
      anteriorFim = DateTime.parse(m['anterior_fim'] as String),
      rankingBruto = (m['ranking_bruto'] as List)
          .cast<Map>()
          .map(_Cliente.new)
          .toList(),
      rankingLiquido = (m['ranking_liquido'] as List)
          .cast<Map>()
          .map(_Cliente.new)
          .toList(),
      retencoes = _numero(m, 'retencoes'),
      xmlIndisponiveis = _numero(m, 'xml_indisponiveis'),
      xmlIlegiveis = [
        for (final v in (m['xml_ilegiveis'] as List? ?? const [])) v as int,
      ],
      clientes = _numero(m, 'clientes');

  final _Valores total, anterior;
  final DateTime anteriorIni, anteriorFim;
  final _DadosGrafico grafico;
  final List<_Cliente> rankingBruto, rankingLiquido;
  final int retencoes, xmlIndisponiveis, clientes;

  /// Notas do recorte cujo XML guardado não abre: dá para buscar de novo na SEFIN.
  final List<int> xmlIlegiveis;
}

class TelaDashboard extends StatefulWidget {
  const TelaDashboard({super.key, required this.app});
  final App app;

  @override
  State<TelaDashboard> createState() => _TelaDashboardState();
}

class _TelaDashboardState extends State<TelaDashboard> {
  static const _opcoes = [
    Opcao('hoje', 'Hoje'),
    Opcao('mes', 'Este mês'),
    Opcao('mes_ant', 'Mês anterior'),
    Opcao('90', 'Últimos 90 dias'),
    Opcao('ano', 'Este ano'),
    Opcao('12m', 'Últimos 12 meses'),
    Opcao('custom', 'Personalizado'),
  ];

  App get app => widget.app;
  final _filtroPeriodo = Suspensa();
  final _filtroBase = Suspensa();
  final _filtroModo = Suspensa(
    valor: 'atual',
    opcoes: const [
      Opcao('atual', 'Atual'),
      Opcao('comparativo', 'Comparativo'),
    ],
  );
  String _periodo = 'hoje';
  bool _comparativo = false;
  bool _mostrar = false;
  DateTime? _de, _ate;
  String _base = 'emissao';
  int _pedido = 0;
  _Resumo? _resumo;
  bool _carregando = false;
  String? _falha;

  /// Substituições autorizadas na SEFIN que o Cofre ainda não refletiu: a nota antiga pode
  /// continuar somando até a atualização.
  int _substPendentes = 0;
  bool _substEmConferencia = false;

  /// Busca na SEFIN dos XMLs que não abrem, em andamento.
  bool _rebuscando = false;
  Timer? _atualizacaoDeNotas, _viradaDoDia;

  @override
  void initState() {
    super.initState();
    _filtroPeriodo.opcoes = _opcoes;
    _filtroPeriodo.por(_periodo);
    _filtroBase.opcoes = opcoesBasePeriodo;
    _filtroBase.por('emissao');
    app.aoEntrar[App.navDashboard] = _entrar;
    app.aoTrocarPrestador.add(_trocarPrestador);
    app.aoMudarNotas.add(_notasMudaram);
  }

  @override
  void dispose() {
    app.aoEntrar.remove(App.navDashboard);
    app.aoTrocarPrestador.remove(_trocarPrestador);
    app.aoMudarNotas.remove(_notasMudaram);
    _atualizacaoDeNotas?.cancel();
    _viradaDoDia?.cancel();
    _filtroModo.dispose();
    _filtroPeriodo.dispose();
    _filtroBase.dispose();
    super.dispose();
  }

  (DateTime, DateTime) get _datas {
    final hoje = DateUtils.dateOnly(DateTime.now());
    return switch (_periodo) {
      'hoje' => (hoje, hoje),
      'mes' => (DateTime(hoje.year, hoje.month), hoje),
      'mes_ant' => (
        DateTime(hoje.year, hoje.month - 1),
        DateTime(hoje.year, hoje.month, 0),
      ),
      '90' => (DateTime(hoje.year, hoje.month, hoje.day - 89), hoje),
      '12m' => (DateTime(hoje.year, hoje.month - 11), hoje),
      'custom' => (_de ?? hoje, _ate ?? hoje),
      _ => (DateTime(hoje.year), hoje),
    };
  }

  List<_PeriodoGrafico> _periodosPara(DateTime de, DateTime ate) {
    final atual = _PeriodoGrafico(_diaUtc(de), _diaUtc(ate));
    if (!_comparativo) return [atual];
    _PeriodoGrafico anterior(int n) {
      final deslocamento = 12 * n;
      final inicio = _moverMeses(atual.inicio, -deslocamento);
      final fim = _periodo == 'mes_ant'
          ? DateTime.utc(inicio.year, inicio.month + 1, 0)
          : _moverMeses(atual.fim, -deslocamento);
      return _PeriodoGrafico(inicio, fim, mesesAteAtual: deslocamento);
    }

    return [atual, for (var i = 1; i <= 3; i++) anterior(i)];
  }

  void _entrar() {
    _agendarVirada();
    _carregar();
  }

  void _agendarVirada() {
    _viradaDoDia?.cancel();
    final agora = DateTime.now();
    final amanha = DateTime(agora.year, agora.month, agora.day + 1);
    _viradaDoDia = Timer(amanha.difference(agora), () {
      if (app.viva && app.navAtual == App.navDashboard) {
        _agendarVirada();
        if (_periodo != 'custom') _carregar();
      }
    });
  }

  void _trocarPrestador() {
    _atualizacaoDeNotas?.cancel();
    _pedido++;
    setState(() {
      _resumo = null;
      _mostrar = false;
      _falha = null;
      _carregando = false;
      _substPendentes = 0;
      _substEmConferencia = false;
    });
  }

  void _notasMudaram() {
    if (app.navAtual != App.navDashboard) return;
    _atualizacaoDeNotas?.cancel();
    _atualizacaoDeNotas = Timer(const Duration(milliseconds: 400), () {
      if (app.viva && app.navAtual == App.navDashboard) _carregar();
    });
  }

  void _selecionarPeriodo(String? novo) {
    if (novo == null) return;
    if (novo == 'custom') {
      final (de, ate) = _datas;
      abrirPeriodo(
        app,
        _de ?? de,
        _ate ?? ate,
        (inicio, fim) {
          _periodo = 'custom';
          _de = inicio;
          _ate = fim;
          _filtroPeriodo.por(_periodo);
          _filtroPeriodo.avisar();
          _carregar(limpar: true);
        },
        () {
          _filtroPeriodo.por(_periodo);
          _filtroPeriodo.avisar();
        },
      );
      return;
    }
    if (_periodo == novo) return;
    _periodo = novo;
    _carregar(limpar: true);
  }

  void _carregar({bool limpar = false}) {
    final dono = app.prestador;
    if (dono.isEmpty) return;
    final pedido = ++_pedido;
    final (de, ate) = _datas;
    final periodos = _periodosPara(de, ate);
    final modo = _periodo;
    final exibido = _resumo?.grafico.periodos.first;
    setState(() {
      if (limpar ||
          (exibido != null &&
              (exibido.inicio != periodos.first.inicio ||
                  exibido.fim != periodos.first.fim))) {
        _resumo = null;
      }
      _falha = null;
      _carregando = true;
    });
    bool atual() =>
        mounted && app.viva && pedido == _pedido && dono == app.prestador;
    unawaited(
      app.emSegundoPlano(() async {
        // Antes do resumo: o núcleo tenta de novo as marcas pendentes e diz quantas restam.
        try {
          final pendentes = await chamar<List>(
            'cofre.substituicoes_pendentes',
            {'dono': dono},
          );
          final emConferencia = pendentes.any(
            (p) => p is Map && p['aguarda_conferencia'] == true,
          );
          if (atual() && (pendentes.length != _substPendentes || emConferencia != _substEmConferencia)) {
            setState(() {
              _substPendentes = pendentes.length;
              _substEmConferencia = emConferencia;
            });
          }
        } catch (e) {
          registrar(
            'Dashboard: substituições pendentes não puderam ser conferidas: $e',
            nivel: 'warning',
          );
        }
        if (!atual()) return;
        try {
          final mapa = await chamar<Map>('dashboard.resumo', {
            'dono': dono,
            'ini': dataIso(de),
            'fim': dataIso(ate),
            'competencia': _base == 'competencia',
            if (_base == 'movimento') 'movimento': true,
            if (periodos.length > 1)
              'anteriores': [for (final p in periodos.skip(1)) p.limites],
          });
          if (!atual()) return;
          final dados = _Resumo(mapa, periodos, modo);
          setState(() => _resumo = dados);
        } catch (e) {
          if (!atual()) return;
          setState(() => _falha = 'Não foi possível atualizar o dashboard.');
          app.toast('Não foi possível atualizar o dashboard. $e', erro: true);
        } finally {
          if (atual()) setState(() => _carregando = false);
        }
      }),
    );
  }

  /// Busca os XMLs um por vez. Uma falha da nota não impede a busca das demais.
  Future<void> _rebuscarIlegiveis(List<int> ids) async {
    if (_rebuscando || ids.isEmpty) return;
    final dono = app.prestador;
    if (!await app.autorizarAcao('cofre.rebuscar') ||
        !mounted || _rebuscando || dono != app.prestador) return;
    setState(() => _rebuscando = true);
    final h = app.toastProgresso(
      'Buscando na SEFIN ${ids.length == 1 ? 'o XML de 1 nota' : 'os XMLs de ${ids.length} notas'}…',
    );
    var certos = 0;
    var indisponiveis = 0;
    String? detalhe;
    String? pausa;
    await app.emSegundoPlano(() async {
      for (final id in ids) {
        if (!mounted || !app.viva || dono != app.prestador) break;
        try {
          await chamar<Map>('cofre.rebuscar_xml', {'dono': dono, 'nota_id': id});
          certos++;
        } catch (e) {
          registrar('Dashboard: busca do XML da nota $id falhou: $e', nivel: 'warning');
          final dados = e is ErroNucleo ? e.dados : null;
          if (dados is Map && dados['falha_da_nota'] == true) {
            indisponiveis++;
            detalhe ??= '$e';
            continue;
          }
          pausa = '$e';
          break;
        }
      }
    });
    final falhou = indisponiveis > 0 || pausa != null;
    final texto = !falhou
        ? '$certos XML(s) buscados na SEFIN e guardados de novo no Cofre.'
        : '$certos de ${ids.length} XML(s) recuperados.'
          '${indisponiveis > 0 ? ' $indisponiveis XML(s) indisponíveis.' : ''}'
          '${pausa != null ? ' A busca foi pausada. $pausa' : ' $detalhe'}';
    app.toastFim(h, texto, erro: falhou && certos == 0, aviso: falhou && certos > 0);
    if (certos > 0) app.notasMudaram();
    if (!mounted) return;
    setState(() => _rebuscando = false);
    _carregar();
  }

  Widget _filtros(BuildContext context) {
    final escala = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(Letra.campo) / Letra.campo,
    );
    return lin(
      [
        ListaSuspensa(
          estado: _filtroPeriodo,
          rotulo: 'Período',
          largura: TamanhosDashboard.periodo.largura!,
          altura: TamanhosDashboard.periodo.altura,
          idLayout: TamanhosDashboard.periodo.id,
          aoSelecionar: _selecionarPeriodo,
        ),
        ListaSuspensa(
          estado: _filtroBase,
          rotulo: 'Data',
          largura: escala * TamanhosDashboard.base.largura!,
          altura: TamanhosDashboard.base.altura,
          idLayout: TamanhosDashboard.base.id,
          aoSelecionar: (valor) {
            if (valor == null || valor == _base) return;
            _base = valor;
            _carregar(limpar: true);
          },
        ),
        ListaSuspensa(
          estado: _filtroModo,
          rotulo: 'Visualização',
          largura: escala * TamanhosDashboard.modo.largura!,
          altura: TamanhosDashboard.modo.altura,
          idLayout: TamanhosDashboard.modo.id,
          aoSelecionar: (valor) {
            final comparar = valor == 'comparativo';
            if (comparar == _comparativo) return;
            _comparativo = comparar;
            _carregar(limpar: true);
          },
        ),
      ],
      quebra: true,
      espaco: 10,
      idLayout: 'Grupo.dashboard.lin.filtros',
    );
  }

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final (de, ate) = _datas;
    final dados = _resumo;
    return LayoutBuilder(
      builder: (context, limites) {
        final largo = limites.maxWidth >= 945;
        return ListView(
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                lin(
                  [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Tx(
                          'Visão financeira',
                          tam: Letra.titulo,
                          peso: FontWeight.bold,
                          idLayout: 'Dashboard.titulo',
                        ),
                        const SizedBox(height: 4),
                        lin(
                          [
                            Flexible(
                              child: Tx(
                                'Notas de produção no Cofre  •  ${dataBr(de)} a ${dataBr(ate)}',
                                tam: Letra.campo,
                                cor: cores.onSurfaceVariant,
                                idLayout: 'Dashboard.intervalo',
                              ),
                            ),
                            BotaoIcone(
                              _mostrar
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              dica: _mostrar
                                  ? 'Ocultar valores'
                                  : 'Mostrar valores',
                              aoClicar: () =>
                                  setState(() => _mostrar = !_mostrar),
                              largura: TamanhosDashboard.visibilidade.largura,
                              altura: TamanhosDashboard.visibilidade.altura,
                              idLayout: TamanhosDashboard.visibilidade.id,
                            ),
                          ],
                          justa: true,
                          cruzado: CrossAxisAlignment.center,
                          espaco: 6,
                          idLayout: 'Grupo.dashboard.lin.intervalo',
                        ),
                      ],
                    ),
                    // Os rótulos flutuantes avançam acima da borda dos campos.
                    Padding(
                      padding: EdgeInsets.only(
                        top: MediaQuery.textScalerOf(context)
                                .scale(Letra.rotuloNaBorda) / 2 + 2,
                      ),
                      child: _filtros(context),
                    ),
                  ],
                  quebra: true,
                  cruzado: CrossAxisAlignment.start,
                  principal: MainAxisAlignment.spaceBetween,
                  espaco: 18,
                  idLayout: 'Grupo.dashboard.lin.cabecalho',
                ),
                const SizedBox(height: 15),
                SizedBox(
                  height: 3,
                  child: _carregando
                      ? const LinearProgressIndicator(minHeight: 3)
                      : null,
                ),
                const SizedBox(height: 11),
                if (_substPendentes > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: lin(
                      [
                        Icon(Icons.sync_problem, size: 18, color: corAviso),
                        Flexible(
                          child: Tx(
                            _substEmConferencia
                                ? 'Há substituições em conferência. Os totais podem mudar quando o Cofre for atualizado.'
                                : _substPendentes == 1
                                ? 'Uma substituição foi autorizada na SEFIN e aguarda a atualização do Cofre. Até lá, os totais podem incluir a nota substituída.'
                                : '$_substPendentes substituições foram autorizadas na SEFIN e aguardam a atualização do Cofre. Até lá, os totais podem incluir as notas substituídas.',
                            cor: corAviso,
                            idLayout: 'Dashboard.avisoSubstituicao',
                          ),
                        ),
                      ],
                      espaco: 8,
                      idLayout: 'Grupo.dashboard.lin.avisoSubstituicao',
                    ),
                  ),
                if (_falha != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _estado(
                      Icons.cloud_off_outlined,
                      _falha!,
                      acao: Botao.contorno(
                        'Tentar novamente',
                        aoClicar: _carregar,
                        largura: TamanhosDashboard.repetir.largura,
                        altura: TamanhosDashboard.repetir.altura,
                        idLayout: TamanhosDashboard.repetir.id,
                      ),
                    ),
                  ),
                if (dados == null && _falha == null)
                  _estado(Icons.query_stats_rounded, 'Carregando o dashboard…'),
                if (dados != null) ...[
                  _indicadores(dados, largo),
                  const SizedBox(height: 18),
                  if (!dados.grafico.temNotas)
                    _estado(
                      Icons.receipt_long_outlined,
                      'Nenhuma nota de produção ativa no período',
                      texto:
                          'Escolha outras datas ou sincronize as notas no Cofre.',
                      acao: Botao.contorno(
                        'Abrir Cofre',
                        icone: Icons.lock_outline,
                        aoClicar: () => app.irPara(4),
                        largura: TamanhosDashboard.cofre.largura,
                        altura: TamanhosDashboard.cofre.altura,
                        idLayout: TamanhosDashboard.cofre.id,
                      ),
                    )
                  else ...[
                    _paineis(
                      largo,
                      _Receita(
                        key: ValueKey((
                          dataIso(de),
                          dataIso(ate),
                          _base,
                          _comparativo,
                        )),
                        dados: dados.grafico,
                        mostrar: _mostrar,
                      ),
                      _Composicao(
                        dados: dados,
                        mostrar: _mostrar,
                        rebuscando: _rebuscando,
                        aoRebuscar: () => _rebuscarIlegiveis(dados.xmlIlegiveis),
                      ),
                      pesoA: 7,
                      pesoB: 4,
                    ),
                    const SizedBox(height: 18),
                    _paineis(
                      largo,
                      _Ranking(dados: dados, liquido: false, mostrar: _mostrar),
                      _Ranking(dados: dados, liquido: true, mostrar: _mostrar),
                    ),
                    const SizedBox(height: 14),
                    Tx(
                      'O dashboard usa valores fiscais das NFS-e ativas do Cofre. '
                      'Recebimentos e custos não são registrados nesta visão.',
                      tam: Letra.apoio,
                      cor: cores.onSurfaceVariant,
                      idLayout: 'Dashboard.fonte',
                    ),
                  ],
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _estado(IconData icone, String titulo, {String? texto, Widget? acao}) {
    final cores = Theme.of(context).colorScheme;
    return _CartaoDashboard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Column(
          children: [
            Icon(icone, size: 31, color: cores.primary),
            const SizedBox(height: 12),
            Tx(
              titulo,
              tam: Letra.titulo,
              peso: FontWeight.w700,
              alinhar: TextAlign.center,
              idLayout: 'Dashboard.estado.titulo',
            ),
            if (texto != null) ...[
              const SizedBox(height: 6),
              Tx(
                texto,
                cor: cores.onSurfaceVariant,
                alinhar: TextAlign.center,
                idLayout: 'Dashboard.estado.descricao',
              ),
            ],
            if (acao != null) ...[const SizedBox(height: 14), acao],
          ],
        ),
      ),
    );
  }

  Widget _indicadores(_Resumo dados, bool largo) {
    final comparacao =
        '${dataBr(dados.anteriorIni)} a ${dataBr(dados.anteriorFim)}';
    final cartoes = [
      _Indicador(
        titulo: 'Faturamento bruto',
        id: 'bruto',
        valor: _brl(dados.total.bruto, mostrar: _mostrar),
        icone: Icons.trending_up_rounded,
        cor: _verde,
        rodape: _mostrar
            ? _variacao(dados.total.bruto, dados.anterior.bruto)
            : _asteriscos,
        dica: 'Período comparado · $comparacao',
      ),
      _Indicador(
        titulo: 'Líquido das notas',
        id: 'liquido',
        valor: _brl(dados.total.liquido, mostrar: _mostrar),
        icone: Icons.account_balance_wallet_outlined,
        cor: const Color(0xff6251ba),
        rodape: _mostrar
            ? _variacao(dados.total.liquido, dados.anterior.liquido)
            : _asteriscos,
        dica: 'Período comparado · $comparacao',
      ),
      _Indicador(
        titulo: 'Tributos retidos',
        id: 'retencoes',
        valor:
            dados.total.notas > 0 && dados.xmlIndisponiveis == dados.total.notas
            ? 'Indisponível'
            : _brl(dados.retencoes, mostrar: _mostrar),
        icone: Icons.account_balance_outlined,
        cor: const Color(0xff9f5c14),
        rodape: dados.xmlIndisponiveis > 0
            ? 'XMLs indisponíveis'
            : 'Retenções na fonte',
      ),
      _Indicador(
        titulo: 'Notas ativas',
        id: 'notas',
        valor: _mostrar ? '${dados.total.notas}' : _asteriscos,
        icone: Icons.receipt_long_outlined,
        cor: const Color(0xff2765a0),
        rodape: _mostrar
            ? '${dados.clientes} ${dados.clientes == 1 ? 'cliente identificado' : 'clientes identificados'}'
            : _asteriscos,
      ),
    ];
    return largo
        ? _linhaProporcional(cartoes)
        : Column(
            children: [
              _linhaProporcional(cartoes.sublist(0, 2)),
              const SizedBox(height: 12),
              _linhaProporcional(cartoes.sublist(2)),
            ],
          );
  }
}

String _variacao(int atual, int anterior) {
  if (anterior <= 0) return 'Sem base de comparação';
  final percentual = (atual - anterior) * 100 / anterior;
  final numero = percentual.toStringAsFixed(1).replaceAll('.', ',');
  return '${percentual > 0 ? '+' : ''}$numero% vs. período anterior';
}

Widget _linhaProporcional(List<Widget> filhos) => Row(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (var i = 0; i < filhos.length; i++) ...[
      if (i > 0) const SizedBox(width: 12),
      Expanded(child: filhos[i]),
    ],
  ],
);

Widget _paineis(
  bool ladoALado,
  Widget a,
  Widget b, {
  int pesoA = 1,
  int pesoB = 1,
}) {
  return ladoALado
      ? Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: pesoA, child: a),
            const SizedBox(width: 18),
            Expanded(flex: pesoB, child: b),
          ],
        )
      : Column(children: [a, const SizedBox(height: 18), b]);
}

class _CartaoDashboard extends StatelessWidget {
  const _CartaoDashboard({required this.child, this.escuro = false});
  final Widget child;
  final bool escuro;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: escuro ? const Color(0xff285058) : cores.outlineVariant,
        ),
        color: escuro ? null : cores.surface,
        gradient: escuro
            ? const LinearGradient(
                colors: [
                  Color(0xff0c242c),
                  Color(0xff143e44),
                  Color(0xff15343d),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
      ),
      child: Padding(padding: const EdgeInsets.all(18), child: child),
    );
  }
}

class _Indicador extends StatelessWidget {
  const _Indicador({
    required this.id,
    required this.titulo,
    required this.valor,
    required this.icone,
    required this.cor,
    required this.rodape,
    this.dica,
  });
  final String id, titulo, valor, rodape;
  final String? dica;
  final IconData icone;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final corIcone = cores.brightness == Brightness.dark
        ? Color.lerp(cor, Colors.white, .35)!
        : cor;
    return _CartaoDashboard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 33,
                height: 33,
                decoration: BoxDecoration(
                  color: cor.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icone, color: corIcone, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Tx(
                  titulo,
                  tam: Letra.texto,
                  peso: FontWeight.w600,
                  linhas: 1,
                  corte: TextOverflow.ellipsis,
                  dica: titulo,
                  idLayout: 'Dashboard.$id.rotulo',
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Align(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Tx(
                valor,
                tam: 26,
                peso: FontWeight.w700,
                idLayout: 'Dashboard.$id.valor',
              ),
            ),
          ),
          const SizedBox(height: 5),
          Tx(
            rodape,
            tam: Letra.apoio,
            cor: cores.onSurfaceVariant,
            linhas: 1,
            corte: TextOverflow.ellipsis,
            dica: dica ?? rodape,
            idLayout: 'Dashboard.$id.rodape',
          ),
        ],
      ),
    );
  }
}

class _Composicao extends StatelessWidget {
  const _Composicao({
    required this.dados,
    required this.mostrar,
    required this.rebuscando,
    required this.aoRebuscar,
  });
  final _Resumo dados;
  final bool mostrar;
  final bool rebuscando;
  final VoidCallback aoRebuscar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final total = dados.total.liquido + dados.retencoes;
    final proporcao = total == 0 ? 0.0 : dados.retencoes / total;
    final parcial = dados.xmlIndisponiveis > 0;
    final semXml = dados.xmlIndisponiveis == dados.total.notas;
    return _CartaoDashboard(
      child: SizedBox(
        height: dados.grafico.comparativo ? 326 : 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Tx(
              'Líquido e retenções',
              tam: 18,
              peso: FontWeight.w700,
              idLayout: 'Dashboard.composicao.titulo',
            ),
            Tx(
              'Valores informados nas notas',
              tam: Letra.texto,
              cor: cores.onSurfaceVariant,
              idLayout: 'Dashboard.composicao.subtitulo',
            ),
            Expanded(
              child: Center(
                child: _Rosca(
                  proporcao: proporcao,
                  disponivel: !parcial && total > 0,
                  mostrar: mostrar,
                  trilha: cores.outlineVariant,
                ),
              ),
            ),
            Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              columnWidths: const {
                0: FlexColumnWidth(),
                1: FixedColumnWidth(32),
                2: IntrinsicColumnWidth(),
              },
              children: [
                _valorDaComposicao(
                  'Líquido',
                  dados.total.liquido,
                  _verde,
                  'liquido',
                ),
                _valorDaComposicao(
                  'Tributos retidos',
                  semXml ? null : dados.retencoes,
                  _ambar,
                  'retencoes',
                ),
              ],
            ),
            if (parcial) ...[
              const SizedBox(height: 8),
              lin(
                [
                  Expanded(
                    child: Tx(
                      mostrar
                          ? '${dados.xmlIndisponiveis} de ${dados.total.notas} notas sem XML legível.'
                          : 'Há notas sem XML legível.',
                      tam: Letra.apoio,
                      cor: cores.onSurfaceVariant,
                      idLayout: 'Dashboard.composicao.cobertura',
                    ),
                  ),
                  if (dados.xmlIlegiveis.isNotEmpty)
                    Botao.texto(
                      rebuscando ? 'Buscando…' : 'Buscar na SEFIN',
                      icone: Icons.cloud_download_outlined,
                      compacto: true,
                      desabilitado: rebuscando,
                      dica: 'Busca de novo, pela chave de acesso, a NFS-e autorizada de cada nota cujo XML não abre e troca a cópia do Cofre.',
                      aoClicar: aoRebuscar,
                      idLayout: 'Dashboard.composicao.buscarXml',
                    ),
                ],
                espaco: 6,
                idLayout: 'Grupo.dashboard.lin.cobertura',
              ),
            ],
          ],
        ),
      ),
    );
  }

  TableRow _valorDaComposicao(
    String rotulo,
    int? valor,
    Color cor,
    String id,
  ) => TableRow(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            _Marcador(cor),
            const SizedBox(width: 8),
            Expanded(
              child: Tx(rotulo, idLayout: 'Dashboard.composicao.$id.rotulo'),
            ),
          ],
        ),
      ),
      Tx(
        valor == null ? '' : 'R\$',
        alinhar: TextAlign.center,
        peso: FontWeight.w700,
        idLayout: 'Dashboard.composicao.$id.moeda',
      ),
      Tx(
        valor == null
            ? '—'
            : mostrar
            ? '${valor < 0 ? '−' : ''}${_quantia(valor)}'
            : _asteriscos,
        alinhar: TextAlign.right,
        peso: FontWeight.w700,
        idLayout: 'Dashboard.composicao.$id.valor',
      ),
    ],
  );
}

class _Ranking extends StatelessWidget {
  const _Ranking({
    required this.dados,
    required this.liquido,
    required this.mostrar,
  });
  final _Resumo dados;
  final bool liquido, mostrar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final lista = liquido ? dados.rankingLiquido : dados.rankingBruto;
    final chave = liquido ? 'rankingLiquido' : 'rankingBruto';
    final cor = liquido ? const Color(0xff8170da) : const Color(0xff209b85);
    final base = liquido ? dados.total.liquido : dados.total.bruto;
    return _CartaoDashboard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tx(
            liquido ? 'Clientes por valor líquido' : 'Melhores clientes',
            tam: 18,
            peso: FontWeight.w700,
            idLayout: 'Dashboard.$chave.titulo',
          ),
          const SizedBox(height: 3),
          Tx(
            liquido
                ? 'Por líquido das notas, antes dos custos'
                : 'Por faturamento bruto',
            tam: Letra.texto,
            cor: cores.onSurfaceVariant,
            idLayout: 'Dashboard.$chave.subtitulo',
          ),
          const SizedBox(height: 18),
          if (lista.isEmpty)
            Tx(
              'As notas do período não identificam o tomador.',
              cor: cores.onSurfaceVariant,
              idLayout: 'Dashboard.$chave.vazio',
            ),
          for (var i = 0; i < lista.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _linhaCliente(lista[i], i, base, cor, cores, chave),
          ],
        ],
      ),
    );
  }

  Widget _linhaCliente(
    _Cliente c,
    int i,
    int base,
    Color cor,
    ColorScheme cores,
    String chave,
  ) {
    final valor = liquido ? c.liquido : c.bruto;
    final fracao = base <= 0 ? 0.0 : (valor / base).clamp(0.0, 1.0);
    final nome = c.nome.isEmpty ? c.doc : c.nome;
    final id = 'Dashboard.$chave.linha';
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            color: cores.surfaceContainerHighest,
          ),
          child: Tx('${i + 1}', peso: FontWeight.w700, idLayout: '$id.posicao'),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Tx(
                      nome,
                      linhas: 1,
                      corte: TextOverflow.ellipsis,
                      dica: mostrar
                          ? '$nome · ${c.notas} ${c.notas == 1 ? 'nota' : 'notas'}'
                          : nome,
                      peso: FontWeight.w600,
                      idLayout: '$id.cliente',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tx(
                    mostrar ? _percentual(fracao) : '****%',
                    dica: 'Participação no total do período',
                    cor: cores.onSurfaceVariant,
                    idLayout: '$id.participacao',
                  ),
                  const SizedBox(width: 9),
                  Tx(
                    _brl(valor, mostrar: mostrar),
                    peso: FontWeight.w700,
                    idLayout: '$id.valor',
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: mostrar ? fracao : 0),
                duration: const Duration(milliseconds: 470),
                curve: Curves.easeOutCubic,
                builder: (context, x, _) => Container(
                  height: 5,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: cores.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: FractionallySizedBox(
                    widthFactor: mostrar ? x : 0,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(
                          colors: [cor.withValues(alpha: .65), cor],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Marcador extends StatelessWidget {
  const _Marcador(this.cor);
  final Color cor;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: cor, shape: BoxShape.circle),
  );
}
