/// Período das telas de notas: os períodos nomeados, o texto do intervalo e a janela do
/// período PERSONALIZADO, com dois calendários independentes.
library;

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart' show lerDataDoCampo;

const opcoesBasePeriodo = [
  Opcao('emissao', 'Emissão'),
  Opcao('competencia', 'Competência'),
];

const periodos = [
  ('hoje', 'Hoje'),
  ('mes', 'Este mês'),
  ('mes_ant', 'Mês anterior'),
  ('ano', 'Este ano'),
  ('custom', 'Personalizado'),
];

/// Largura da lista quando o campo mostra o intervalo.
const larguraPeriodoComDatas = 270.0;

String _z(int n) => n.toString().padLeft(2, '0');
String dataBr(DateTime d) =>
    '${_z(d.day)}/${_z(d.month)}/${d.year.toString().padLeft(4, '0')}';
String dataIso(DateTime? d) => d == null
    ? ''
    : '${d.year.toString().padLeft(4, '0')}-${_z(d.month)}-${_z(d.day)}';
String dataCompacta(DateTime? d, String vazio) =>
    d == null ? vazio : '${d.year}${_z(d.month)}${_z(d.day)}';

/// Opções da lista de período. "Personalizado" separa o que a lista aberta mostra (sempre
/// "Personalizado") do que o campo mostra com ela escolhida: com um intervalo em uso o
/// campo exibe as datas ([intervalo] não vazio).
List<Opcao> opcoesDePeriodo([String intervalo = '']) => [
  for (final (k, t) in periodos)
    k == 'custom'
        ? Opcao(k, intervalo.isEmpty ? t : intervalo, naLista: t)
        : Opcao(k, t),
];

/// Intervalo do período personalizado, como aparece no campo da lista.
String textoDoIntervalo(DateTime? de, DateTime? ate) =>
    (de == null || ate == null) ? '' : '${dataBr(de)} a ${dataBr(ate)}';

/// Período por extenso para as mensagens do Registro ("01/06/2026 até 30/06/2026").
String periodoPorExtenso(DateTime? ini, DateTime? fim) {
  if (ini != null && fim != null) return '${dataBr(ini)} até ${dataBr(fim)}';
  if (ini != null) return 'a partir de ${dataBr(ini)}';
  if (fim != null) return 'até ${dataBr(fim)}';
  return 'todas as datas';
}

/// Datas (ini, fim) de um período nomeado; "custom" devolve as recebidas.
(DateTime?, DateTime?) datasDoPeriodo(
  String periodo, [
  DateTime? de,
  DateTime? ate,
]) {
  final agora = DateTime.now();
  final hoje = DateTime(agora.year, agora.month, agora.day);
  switch (periodo) {
    case 'hoje':
      return (hoje, hoje);
    case 'mes':
      return (
        DateTime(hoje.year, hoje.month, 1),
        DateTime(hoje.year, hoje.month + 1, 0),
      );
    case 'mes_ant':
      return (
        DateTime(hoje.year, hoje.month - 1, 1),
        DateTime(hoje.year, hoje.month, 0),
      );
    case 'ano':
      return (DateTime(hoje.year, 1, 1), DateTime(hoje.year, 12, 31));
  }
  return (de, ate);
}

const _meses = [
  'Janeiro',
  'Fevereiro',
  'Março',
  'Abril',
  'Maio',
  'Junho',
  'Julho',
  'Agosto',
  'Setembro',
  'Outubro',
  'Novembro',
  'Dezembro',
];
const _semana = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S']; // domingo → sábado
final _calMin = DateTime(2020, 1, 1);
final _calMax = DateTime(2100, 12, 31);

class _Dia extends StatefulWidget {
  const _Dia({
    super.key,
    required this.dia,
    required this.meu,
    required this.aoClicar,
    required this.habilitado,
  });
  final DateTime dia;
  final bool habilitado;
  final bool meu;
  final VoidCallback aoClicar;

  @override
  State<_Dia> createState() => _DiaState();
}

class _DiaState extends State<_Dia> {
  bool _dentro = false;

  @override
  Widget build(BuildContext context) {
    final meu = widget.meu; // a ÚNICA marca do calendário: a data dele
    final dentroDoIntervalo = widget.habilitado;
    final caixa = Ct(
      altura: 32,
      raio: BorderRadius.circular(8),
      alinhar: Alignment.center,
      cor: meu
          ? Colors.indigo.shade600
          : ((_dentro && dentroDoIntervalo) ? Colors.indigo.shade50 : null),
      aoPairar: dentroDoIntervalo
          ? (dentro) {
              if (meu) return;
              setState(() => _dentro = dentro);
            }
          : null,
      child: Tx(
        '${widget.dia.day}',
        tam: Letra.texto,
        cor: !dentroDoIntervalo
            ? Colors.grey.shade400
            : (meu ? Colors.white : null),
        largura: TamanhosPeriodo.rotuloWidgetDiaDay.largura,
        altura: TamanhosPeriodo.rotuloWidgetDiaDay.altura,
        idLayout: 'TamanhosPeriodo.rotuloWidgetDiaDay',
      ),
    );
    // fora do intervalo: sem clique, sem hover, sem mãozinha
    if (!dentroDoIntervalo) return caixa;
    return Gesto(
      cursor: SystemMouseCursors.click,
      aoTocar: widget.aoClicar,
      child: caixa,
    );
  }
}

void abrirCompetencia(
  App app,
  DateTime inicial,
  void Function(DateTime, bool) aoOk, {
  bool permitirReplicar = false,
}) => _abrirCalendario(
  app,
  inicial,
  null,
  titulo: 'Data de competência',
  rotuloInicial: 'Competência',
  idLayout: permitirReplicar
      ? 'Janela.lotes.competencia'
      : 'Janela.emitir.competencia',
  minimo: DateTime(1),
  maximo: DateUtils.dateOnly(DateTime.now()),
  erroFutura: 'A competência não pode ser posterior a hoje.',
  permitirReplicar: permitirReplicar,
  aoDia: aoOk,
);

void abrirVencimento(App app, DateTime? inicial, ValueChanged<DateTime> aoOk) =>
    _abrirCalendario(
      app,
      inicial,
      null,
      titulo: 'Vencimento original',
      rotuloInicial: 'Vencimento',
      idLayout: 'Vencimento.calendario',
      minimo: DateTime(1900),
      maximo: DateTime(2199, 12, 31),
      aoDia: (dia, _) => aoOk(dia),
    );

/// Seleciona as duas datas do intervalo com calendários independentes.
void abrirPeriodo(
  App app,
  DateTime? de,
  DateTime? ate,
  void Function(DateTime, DateTime) aoOk, [
  VoidCallback? aoCancelar,
]) => _abrirCalendario(
  app,
  de,
  ate,
  titulo: 'Período personalizado',
  rotuloInicial: 'Data inicial',
  idLayout: 'Janela.periodo.Dialogo.1',
  minimo: _calMin,
  maximo: _calMax,
  aoPeriodo: aoOk,
  aoCancelar: aoCancelar,
);

void _abrirCalendario(
  App app,
  DateTime? de,
  DateTime? ate, {
  required String titulo,
  required String rotuloInicial,
  required String idLayout,
  required DateTime minimo,
  required DateTime maximo,
  String? erroFutura,
  bool permitirReplicar = false,
  VoidCallback? aoCancelar,
  void Function(DateTime, DateTime)? aoPeriodo,
  void Function(DateTime, bool)? aoDia,
}) {
  final unica = aoDia != null;
  bool replicar = false;
  late final Dialogo d;
  bool dentroDoIntervalo(DateTime x) =>
      !x.isBefore(minimo) && !x.isAfter(maximo);
  DateTime? diaValido(DateTime? valor) {
    if (valor == null) return null;
    final dia = DateUtils.dateOnly(valor);
    return dentroDoIntervalo(dia) ? dia : null;
  }

  final sel = <String, DateTime?>{'de': diaValido(de), 'ate': diaValido(ate)};
  final campos = <String, TextEditingController>{};
  final focos = <String, FocusNode>{};
  final erros = <String, String?>{'de': null, 'ate': null};
  final mes = <String, (int, int)>{};
  const larguraPainel = 286.0;
  const larguraPeriodo = 2 * larguraPainel + 41;

  DateTime limitar(DateTime x) =>
      x.isBefore(minimo) ? minimo : (x.isAfter(maximo) ? maximo : x);

  bool invertido() {
    final (a, b) = (sel['de'], sel['ate']);
    return a != null && b != null && b.isBefore(a);
  }

  bool podeConfirmar() =>
      sel['de'] != null && (unica || (sel['ate'] != null && !invertido()));

  void confirmar() {
    d.aoFechar = null; // daqui em diante, fechar NÃO é desistir
    app.fecharEsta(d);
    if (unica) {
      aoDia(sel['de']!, replicar);
    } else {
      aoPeriodo!(sel['de']!, sel['ate']!);
    }
  }

  bool mesValido(int ano, int m) {
    final ultimo = DateTime(ano, m + 1, 0);
    return !ultimo.isBefore(minimo) && !DateTime(ano, m, 1).isAfter(maximo);
  }

  void digitou(String qual, String texto) {
    final data = lerDataDoCampo(texto);
    final valida = diaValido(data);
    erros[qual] = null;
    if (texto.length == 10 && valida == null) {
      erros[qual] = data == null
          ? 'Data inválida'
          : data.isAfter(maximo) && erroFutura != null
          ? erroFutura
          : 'Data fora do intervalo permitido.';
    }
    final mudou = valida != sel[qual];
    sel[qual] = valida; // data incompleta ou inválida = sem data
    if (valida != null)
      mes[qual] = (valida.year, valida.month); // o calendário acompanha
    d.atualizar();
    // terminou a inicial: segue para a final
    if (!unica && valida != null && qual == 'de' && mudou)
      app.focar(focos['ate']);
  }

  String mascara(String texto) {
    var dig = texto.replaceAll(RegExp(r'[^0-9]'), '');
    if (dig.length > 8) dig = dig.substring(0, 8);
    return [
      dig.substring(0, dig.length < 2 ? dig.length : 2),
      if (dig.length > 2) dig.substring(2, dig.length < 4 ? dig.length : 4),
      if (dig.length > 4) dig.substring(4),
    ].where((x) => x.isNotEmpty).join('/');
  }

  Widget painel(String qual, String titulo) {
    final (ano, m) = mes[qual]!;
    final (anoAnt, mesAnt) = m == 1 ? (ano - 1, 12) : (ano, m - 1);
    final (anoProx, mesProx) = m == 12 ? (ano + 1, 1) : (ano, m + 1);
    void navegar(int delta) {
      final x = m - 1 + delta;
      mes[qual] = (ano + (x / 12).floor(), x % 12 + 1);
      d.atualizar();
    }

    final primeiro = DateTime(ano, m, 1);
    final ultimo = DateTime(ano, m + 1, 0);
    var dia = DateTime(ano, m, 1 - primeiro.weekday % 7);
    final semanas = <List<DateTime>>[];
    while (!dia.isAfter(ultimo)) {
      semanas.add([
        for (var i = 0; i < 7; i++) DateTime(dia.year, dia.month, dia.day + i),
      ]);
      dia = DateTime(dia.year, dia.month, dia.day + 7);
    }
    final escolhida = sel[qual];
    return col(
      [
        CampoTexto(
          controle: campos[qual]!,
          foco: focos[qual],
          rotulo: titulo,
          dica: 'dd/mm/aaaa',
          denso: true,
          largura: TamanhosPeriodo.campoTitulo.largura,
          focoInicial: qual == 'de',
          erro: erros[qual],
          mascara: mascara,
          aoMudar: (t) => digitou(qual, t),
          aoEnviar: (_) {
            if (podeConfirmar()) confirmar();
          },
          altura: TamanhosPeriodo.campoTitulo.altura,
          idLayout: 'TamanhosPeriodo.campoTitulo',
        ),
        col(
          [
            lin([
              BotaoIcone(
                Icons.chevron_left,
                dica: 'Mês anterior',
                tamanho: 20,
                desabilitado: !mesValido(anoAnt, mesAnt),
                aoClicar: () => navegar(-1),
                largura: TamanhosPeriodo.botaoMesAnterior.largura,
                altura: TamanhosPeriodo.botaoMesAnterior.altura,
                idLayout: 'TamanhosPeriodo.botaoMesAnterior',
              ),
              const Expanded(child: SizedBox()),
              Tx(
                '${_meses[m - 1]} $ano',
                peso: FontWeight.bold,
                tam: Letra.subtitulo,
                largura: TamanhosPeriodo.rotuloMesesM1Ano.largura,
                alinhar: TextAlign.center,
                altura: TamanhosPeriodo.rotuloMesesM1Ano.altura,
                idLayout: 'TamanhosPeriodo.rotuloMesesM1Ano',
              ),
              const Expanded(child: SizedBox()),
              BotaoIcone(
                Icons.chevron_right,
                dica: 'Próximo mês',
                tamanho: 20,
                desabilitado: !mesValido(anoProx, mesProx),
                aoClicar: () => navegar(1),
                largura: TamanhosPeriodo.botaoProximoMes.largura,
                altura: TamanhosPeriodo.botaoProximoMes.altura,
                idLayout: 'TamanhosPeriodo.botaoProximoMes',
              ),
            ], idLayout: 'Grupo.periodo.lin.1.$qual'),
            col(
              [
                lin(
                  [
                    for (final x in _semana)
                      Expanded(
                        child: Center(
                          child: Tx(
                            x,
                            tam: Letra.apoio,
                            cor: Colors.grey.shade600,
                            peso: FontWeight.w600,
                            largura: TamanhosPeriodo.rotuloX.largura,
                            altura: TamanhosPeriodo.rotuloX.altura,
                            idLayout: 'TamanhosPeriodo.rotuloX',
                          ),
                        ),
                      ),
                  ],
                  espaco: 2,
                  idLayout: 'Grupo.periodo.lin.2.$qual',
                ),
                for (final semana in semanas)
                  lin(
                    [
                      for (final x in semana)
                        Expanded(
                          child: x.month != m
                              ? const SizedBox(height: 32)
                              : _Dia(
                                  key: ValueKey(
                                    '$qual-${dataIso(x)}-${x == escolhida}',
                                  ),
                                  dia: x,
                                  habilitado: dentroDoIntervalo(x),
                                  meu: x == escolhida,
                                  aoClicar: () {
                                    sel[qual] = x;
                                    campos[qual]!.text = dataBr(x);
                                    erros[qual] = null;
                                    d.atualizar();
                                  },
                                ),
                        ),
                    ],
                    espaco: 2,
                    idLayout:
                        'Grupo.periodo.lin.3.$qual.${dataIso(semana.first)}',
                  ),
                // Sempre 6 linhas: mês de 4 ou 5 semanas não muda a altura da janela.
                for (var i = semanas.length; i < 6; i++) const Ct(altura: 32),
              ],
              espaco: 2,
              justa: true,
              idLayout: 'Grupo.periodo.col.3.$qual',
            ),
          ],
          justa: true,
          espaco: 8,
          idLayout: 'Grupo.periodo.col.2.$qual',
        ),
      ],
      justa: true,
      largura: larguraPainel,
      idLayout: 'Grupo.periodo.col.1.$qual',
    );
  }

  d = Dialogo(
    titulo: (_) => app.tituloComX(titulo),
    largura: unica ? larguraPainel : larguraPeriodo,
    conteudo: (context) => col(
      [
        if (unica)
          painel('de', rotuloInicial)
        else
          LayoutBuilder(
            builder: (context, limites) {
              final inicial = painel('de', rotuloInicial);
              final final_ = painel('ate', 'Data final');
              if (limites.maxWidth < larguraPeriodo) {
                return col([inicial, final_], justa: true, espaco: 16);
              }
              return lin(
                [
                  inicial,
                  Ct(
                    largura: 1,
                    altura: 320,
                    cor: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  final_,
                ],
                espaco: 20,
                cruzado: CrossAxisAlignment.start,
              );
            },
          ),
        if (permitirReplicar)
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              mouseCursor: SystemMouseCursors.click,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Replicar para as outras linhas'),
              value: replicar,
              onChanged: (v) {
                replicar = v ?? false;
                d.atualizar();
              },
            ),
          ),
        if (!unica)
          Tx(
            invertido() ? 'A data final é anterior à inicial.' : '',
            tam: Letra.apoio,
            cor: Colors.red.shade700,
            largura: TamanhosPeriodo
                .rotuloInvertidoADataFinalEAnteriorAInicial
                .largura,
            altura: TamanhosPeriodo
                .rotuloInvertidoADataFinalEAnteriorAInicial
                .altura,
            idLayout:
                'TamanhosPeriodo.rotuloInvertidoADataFinalEAnteriorAInicial',
          ),
      ],
      justa: true,
      espaco: 6,
      idLayout: 'Grupo.periodo.col.4',
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: () => app.fecharEsta(d),
        largura: TamanhosPeriodo.botaoCancelar.largura,
        altura: TamanhosPeriodo.botaoCancelar.altura,
        idLayout: 'TamanhosPeriodo.botaoCancelar',
      ),
      Botao(
        'Confirmar',
        icone: Icons.check,
        desabilitado: !podeConfirmar(),
        aoClicar: confirmar,
        largura: TamanhosPeriodo.botaoConfirmar.largura,
        altura: TamanhosPeriodo.botaoConfirmar.altura,
        idLayout: 'TamanhosPeriodo.botaoConfirmar',
      ),
    ],
    aoFechar: aoCancelar, // Cancelar, X e Esc passam por aqui
    idLayout: idLayout,
  );
  for (final q in const ['de', 'ate']) {
    final ref = limitar(sel[q] ?? DateTime.now());
    mes[q] = (ref.year, ref.month);
    campos[q] = d.texto(sel[q] == null ? '' : dataBr(sel[q]!));
    focos[q] = d.foco();
  }
  app.mostrarDialogo(d);
}
