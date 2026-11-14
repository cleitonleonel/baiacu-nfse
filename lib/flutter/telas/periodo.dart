/// Período das telas de notas: os períodos nomeados, o texto do intervalo e a janela do
/// período PERSONALIZADO, com dois calendários independentes.
library;

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';

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
String dataBr(DateTime d) => '${_z(d.day)}/${_z(d.month)}/${d.year}';
String dataIso(DateTime? d) =>
    d == null ? '' : '${d.year}-${_z(d.month)}-${_z(d.day)}';
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

bool _noIntervalo(DateTime d) => !d.isBefore(_calMin) && !d.isAfter(_calMax);

class _Dia extends StatefulWidget {
  const _Dia({
    super.key,
    required this.dia,
    required this.meu,
    required this.aoClicar,
  });
  final DateTime dia;
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
    final dentroDoIntervalo = _noIntervalo(widget.dia);
    final caixa = Ct(
      largura: 38,
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

/// Dois calendários INDEPENDENTES — data inicial à esquerda, final à direita. Cada um marca
/// só a PRÓPRIA data e tem um campo para digitá-la (dd/mm/aaaa); clicar num dia preenche o
/// campo, digitar leva o calendário ao mês. "Confirmar" exige as duas datas, com a final não
/// anterior à inicial. [aoOk] roda ao confirmar; [aoCancelar] se a janela fechar de qualquer
/// outro jeito (Cancelar, X, Esc).
void abrirPeriodo(
  App app,
  DateTime? de,
  DateTime? ate,
  void Function(DateTime de, DateTime ate) aoOk, [
  VoidCallback? aoCancelar,
]) {
  late final Dialogo d;
  final sel = <String, DateTime?>{'de': de, 'ate': ate};
  final campos = <String, TextEditingController>{};
  final focos = <String, FocusNode>{};
  final erros = <String, String?>{'de': null, 'ate': null};
  final mes = <String, (int, int)>{};

  DateTime limitar(DateTime x) =>
      x.isBefore(_calMin) ? _calMin : (x.isAfter(_calMax) ? _calMax : x);

  bool invertido() {
    final (a, b) = (sel['de'], sel['ate']);
    return a != null && b != null && b.isBefore(a);
  }

  bool podeConfirmar() =>
      sel['de'] != null && sel['ate'] != null && !invertido();

  void confirmar() {
    d.aoFechar = null; // daqui em diante, fechar NÃO é desistir
    app.fecharEsta(d);
    aoOk(sel['de']!, sel['ate']!);
  }

  bool mesValido(int ano, int m) {
    final ultimo = DateTime(ano, m + 1, 0);
    return !ultimo.isBefore(_calMin) && !DateTime(ano, m, 1).isAfter(_calMax);
  }

  void digitou(String qual, String texto) {
    // Máscara: só dígitos, as barras entram sozinhas (01102026 -> 01/10/2026).
    var dig = texto.replaceAll(RegExp(r'[^0-9]'), '');
    if (dig.length > 8) dig = dig.substring(0, 8);
    DateTime? valida;
    erros[qual] = null;
    if (dig.length == 8) {
      final (dia, m, ano) = (
        int.parse(dig.substring(0, 2)),
        int.parse(dig.substring(2, 4)),
        int.parse(dig.substring(4)),
      );
      final x = DateTime(ano, m, dia);
      valida = (x.year == ano && x.month == m && x.day == dia) ? x : null;
      if (valida == null || !_noIntervalo(valida)) {
        valida = null;
        erros[qual] = 'Data inválida';
      }
    }
    final mudou = valida != sel[qual];
    sel[qual] = valida; // data incompleta ou inválida = sem data
    if (valida != null)
      mes[qual] = (valida.year, valida.month); // o calendário acompanha
    d.atualizar();
    // terminou a inicial: segue para a final
    if (valida != null && qual == 'de' && mudou) app.focar(focos['ate']);
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
    var dia = primeiro.subtract(Duration(days: primeiro.weekday % 7));
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
            ], idLayout: 'Grupo.periodo.lin.1'),
            col(
              [
                lin(
                  [
                    for (final x in _semana)
                      Ct(
                        largura: 38,
                        alinhar: Alignment.center,
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
                  ],
                  espaco: 2,
                  idLayout: 'Grupo.periodo.lin.2',
                ),
                for (final semana in semanas)
                  lin(
                    [
                      for (final x in semana)
                        if (x.month == m)
                          _Dia(
                            key: ValueKey(
                              '$qual-${dataIso(x)}-${x == escolhida}',
                            ),
                            dia: x,
                            meu: x == escolhida,
                            aoClicar: () {
                              sel[qual] = x;
                              campos[qual]!.text = dataBr(x);
                              erros[qual] = null;
                              d.atualizar();
                            },
                          )
                        else
                          const Ct(largura: 38, altura: 32),
                    ],
                    espaco: 2,
                    idLayout: 'Grupo.periodo.lin.3',
                  ),
                // Sempre 6 linhas: mês de 4 ou 5 semanas não muda a altura da janela.
                for (var i = semanas.length; i < 6; i++) const Ct(altura: 32),
              ],
              espaco: 2,
              justa: true,
              idLayout: 'Grupo.periodo.col.3',
            ),
          ],
          justa: true,
          espaco: 8,
          idLayout: 'Grupo.periodo.col.2',
        ),
      ],
      justa: true,
      largura: 286,
      idLayout: 'Grupo.periodo.col.1',
    );
  }

  d = Dialogo(
    titulo: (_) => app.tituloComX('Período personalizado'),
    largura: 613,
    conteudo: (context) => col(
      [
        lin(
          [
            painel('de', 'Data inicial'),
            Ct(
              largura: 1,
              altura: 320,
              cor: Theme.of(context).colorScheme.outlineVariant,
            ),
            painel('ate', 'Data final'),
          ],
          espaco: 20,
          cruzado: CrossAxisAlignment.start,
          idLayout: 'Grupo.periodo.lin.4',
        ),
        Tx(
          invertido() ? 'A data final é anterior à inicial.' : '',
          tam: Letra.apoio,
          cor: Colors.red.shade700,
          largura: TamanhosPeriodo
              .rotuloInvertidoADataFinalEAnteriorAInicial
              .largura,
          altura:
              TamanhosPeriodo.rotuloInvertidoADataFinalEAnteriorAInicial.altura,
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
    idLayout: 'Janela.periodo.Dialogo.1',
  );
  for (final q in const ['de', 'ate']) {
    final ref = limitar(sel[q] ?? DateTime.now());
    mes[q] = (ref.year, ref.month);
    campos[q] = d.texto(sel[q] == null ? '' : dataBr(sel[q]!));
    focos[q] = d.foco();
  }
  app.mostrarDialogo(d);
}
