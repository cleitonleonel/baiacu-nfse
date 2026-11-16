/// Tela EMITIR: cliente, serviço, descrição e valor; a expansão "Mais campos" com a
/// tributação do serviço; pré-visualização, emissão, fila de contingência e substituição.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app/app.dart';
import '../app/correio.dart';
import '../app/doacao.dart';
import '../app/sistema.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import '../kit/menu_suspenso.dart' show aquecerMenuSuspenso;
import '../tema.dart';
import 'previa_emissao.dart';
import 'cliente_form.dart' show abrirCliente;

/// Chave da opção "Todos"/"Todas" das listas de filtro.
const todos = '*';
const semGrupo = '(Sem grupo)';

// Enumerações oficiais (XSD v1.01) das listas de tributação — as mesmas do cadastro do
// cliente e da expansão "Mais campos".
const cstOpcoes = [
  ('00', '00 - Nenhum'),
  ('01', '01 - Operação Tributável com Alíquota Básica'),
  ('02', '02 - Operação Tributável com Alíquota Diferenciada'),
  ('04', '04 - Monofásica - Revenda a Alíquota Zero'),
  ('05', '05 - Operação por Substituição Tributária'),
  ('06', '06 - Operação a Alíquota Zero'),
  ('07', '07 - Operação Isenta'),
  ('08', '08 - Operação sem Incidência'),
  ('09', '09 - Operação com Suspensão'),
  ('49', '49 - Outras Operações de Saída'),
  ('99', '99 - Outras Operações'),
];
const retOpcoes = [
  ('0', 'PIS/COFINS/CSLL Não Retidos'),
  ('1', 'PIS/COFINS Retidos'),
  ('2', 'PIS/COFINS Não Retidos'),
  ('3', 'PIS/COFINS/CSLL Retidos'),
  ('4', 'PIS/COFINS Retidos, CSLL Não Retido'),
  ('5', 'PIS Retido, COFINS/CSLL Não Retido'),
  ('6', 'COFINS Retido, PIS/CSLL Não Retido'),
  ('7', 'PIS Não Retido, COFINS/CSLL Retidos'),
  ('8', 'PIS/COFINS Não Retidos, CSLL Retido'),
  ('9', 'COFINS Não Retido, PIS/CSLL Retidos'),
];
const issOpcoes = [
  ('1', '1 - Operação tributável'),
  ('2', '2 - Imunidade'),
  ('3', '3 - Exportação de serviço'),
  ('4', '4 - Não Incidência'),
];
const retIssOpcoes = [
  ('1', '1 - Não Retido'),
  ('2', '2 - Retido pelo Tomador'),
  ('3', '3 - Retido pelo Intermediário'),
];

// Catálogos (Código de Tributação Nacional: 338 opções; Item da NBS: 918): a lista inteira
// só existe enquanto o campo está EDITÁVEL; travado, o campo guarda só a opção em uso.
final Map<String, List<(String, String)>> _catalogoPares = {};
final Map<String, Map<String, String>> _catalogoTextos = {};

List<(String, String)> catalogoPares(String tipo) => _catalogoPares.putIfAbsent(
  tipo,
  () => jaPares(
    tipo == 'tribnac' ? 'catalogo.tribnac_options' : 'catalogo.nbs_options',
  ),
);

String? catalogoTexto(String tipo, String codigo) =>
    _catalogoTextos.putIfAbsent(
      tipo,
      () => {for (final (c, t) in catalogoPares(tipo)) c: t},
    )[codigo];

/// Largura do menu das listas de catálogo (mais largo que o campo: os textos são longos).
const larguraMenuCatalogo = 660.0;

bool _catalogosAquecidos = false;

/// Uma vez por execução, com a tela parada: os textos dos dois catálogos são medidos de
/// antemão, para a lista abrir na hora já na primeira vez.
void aquecerCatalogos(BuildContext context) {
  if (_catalogosAquecidos) return;
  _catalogosAquecidos = true;
  for (final tipo in const ['tribnac', 'nbs']) {
    SchedulerBinding.instance.scheduleTask<void>(() {
      if (!context.mounted) return;
      aquecerMenuSuspenso(context, [
        for (final (_, texto) in catalogoPares(tipo)) texto,
      ], larguraMenu: larguraMenuCatalogo);
    }, Priority.idle);
  }
}

/// Lista suspensa de catálogo: nasce enxuta; a lista inteira entra em [encher].
class Catalogo {
  Catalogo(this.tipo);
  final String tipo;
  final Suspensa dd = Suspensa();
  bool cheio = false;

  void por(String valor) {
    if (!cheio) {
      final texto = valor.isEmpty ? null : catalogoTexto(tipo, valor);
      dd.opcoes = valor.isEmpty
          ? const []
          : [
              texto != null
                  ? Opcao(valor, texto)
                  : Opcao(valor, '$valor - Fora da lista atual', legado: true),
            ];
      dd.por(valor);
      dd.dica = (dd.texto ?? '').isEmpty ? null : dd.texto;
      return;
    }
    var ops = dd.opcoes;
    if (ops.any((o) => o.legado))
      ops = [
        for (final o in ops)
          if (!o.legado) o,
      ];
    if (valor.isNotEmpty && ops.every((o) => o.chave != valor)) {
      ops = [
        ...ops,
        Opcao(valor, '$valor - Fora da lista atual', legado: true),
      ];
    }
    dd.opcoes = ops;
    dd.por(valor);
    dd.dica = (dd.texto ?? '').isEmpty ? null : dd.texto;
  }

  /// Carrega a lista INTEIRA (o campo ficou editável). True se carregou agora.
  bool encher() {
    if (cheio) return false;
    final valor = dd.valor ?? '';
    dd.opcoes = opcoesDe(catalogoPares(tipo));
    cheio = true;
    por(valor);
    return true;
  }

  /// Volta a guardar só a opção em uso (o campo travou). True se enxugou agora.
  bool enxugar() {
    if (!cheio) return false;
    cheio = false;
    por(dd.valor ?? '');
    return true;
  }
}

/// Rótulos das listas em que o usuário digitou algo sem escolher um item.
List<String> naoSelecionadas(List<(Suspensa, String)> listas) {
  final pendentes = <String>[];
  for (final (dd, rotulo) in listas) {
    final anterior = dd.temAnterior ? dd.anterior : null;
    if (anterior != null &&
        dd.valor == null &&
        (dd.texto ?? '').trim().isEmpty) {
      dd.por(anterior);
    }
    final texto = dd.texto;
    if (texto == null) continue;
    final digitado = texto.trim();
    String? escolhido;
    for (final o in dd.opcoes) {
      if (o.chave == dd.valor) {
        escolhido = o.texto;
        break;
      }
    }
    if ((dd.valor != null && digitado != escolhido) ||
        (digitado.isNotEmpty && dd.valor == null)) {
      pendentes.add(rotulo);
    }
  }
  return pendentes;
}

/// Retrato do contexto de uma emissão (nada de ler a tela depois que ela começou).
typedef _Contexto = ({
  String op,
  String prest,
  String amb,
  String tomador,
  String slug,
  String xnome,
  Map<String, dynamic>? subst,
});

class TelaEmitir extends StatefulWidget {
  const TelaEmitir({super.key, required this.app});
  final App app;

  @override
  State<TelaEmitir> createState() => EmitirState();
}

class EmitirState extends State<TelaEmitir> with TelaGuardada<TelaEmitir> {
  @override
  App get app => widget.app;

  @override
  int get indiceDaTela => 0;

  /// A tela Emitir em uso (a Consulta inicia a substituição por aqui).
  static EmitirState? atual;

  // ---- estado da emissão -------------------------------------------------------- //
  Map<String, dynamic>? servico; // serviço carregado
  String? tomador; // documento do cliente selecionado
  String? slug; // serviço selecionado
  String xnome = ''; // razão social do cliente (para a confirmação)
  /// Substituição em andamento: a próxima emissão carrega o grupo <subst>.
  Map<String, dynamic>? subst;
  bool _travaUi = false; // trava de reentrância do botão Emitir
  bool _emitindo = false;
  Set<String>? gruposSel; // filtro de grupos (nulo = todos)
  String? _tomCarregadoPrest;

  // ---- controles ------------------------------------------------------------------ //
  final ddTomador = Suspensa();
  final ddServico = Suspensa();
  final ddGrupo = Suspensa(valor: todos, opcoes: const [Opcao(todos, 'Todos')])
    ..por(todos);
  List<(String, String, String)> _tomTodos =
      []; // (doc, texto, texto normalizado)
  Timer? _ddTimer; // restauração adiada do campo do cliente
  String? _tomAnterior;

  final xDesc = TextEditingController();
  final vServ = TextEditingController();
  // Descontos da nota (R$), informados a cada emissão como o valor. O incondicionado reduz as
  // bases de cálculo; o condicionado, só o valor líquido.
  final vDescInc = TextEditingController();
  final vDescCond = TextEditingController();
  final cTribNac = Catalogo('tribnac');
  final cNbs = Catalogo('nbs');
  final cLoc = TextEditingController();
  final cTribMun = TextEditingController();

  Suspensa _trib(List<(String, String)> ops) =>
      Suspensa(valor: ops.first.$1, opcoes: opcoesDe(ops))..por(ops.first.$1);

  late final ddCst = _trib(cstOpcoes);
  late final ddRet = _trib(retOpcoes);
  late final ddIss = _trib(issOpcoes);
  late final ddRetIss = _trib(retIssOpcoes);
  final rtcIndDest = Suspensa(
    opcoes: const [Opcao('0', 'Sim'), Opcao('1', 'Não')],
  );
  late final rtcIndOp = Suspensa(
    opcoes: opcoesDe(jaPares('catalogo.indop_options')),
  );
  late final rtcCst = Suspensa(
    opcoes: opcoesDe(jaPares('catalogo.cst_options')),
  );
  final rtcClasse = Suspensa();
  final destTipo = Suspensa(
    opcoes: const [Opcao('CNPJ', 'CNPJ'), Opcao('CPF', 'CPF')],
  );
  final destDoc = TextEditingController();
  final destNome = TextEditingController();
  final destMun = TextEditingController();
  final destCep = TextEditingController();
  final destLgr = TextEditingController();
  final destNro = TextEditingController();
  final destCpl = TextEditingController();
  final destBairro = TextEditingController();

  final pPis = TextEditingController();
  final pCofins = TextEditingController();
  final pIrrf = TextEditingController();
  final pCsll = TextEditingController();
  final pFed = TextEditingController();
  final pEst = TextEditingController();
  final pMun = TextEditingController();

  final lBase = TextEditingController();
  final lPis = TextEditingController();
  final lCofins = TextEditingController();
  final lIrrf = TextEditingController();
  final lCsll = TextEditingController();
  final lContrib = TextEditingController();
  final lFed = TextEditingController();
  final lEst = TextEditingController();
  final lMun = TextEditingController();

  bool cbContrib = true;

  // ---- certificado de procurador (escolha lembrada por serviço) ------------------------- //
  /// Procuradores do prestador: chave = documento, texto = titular (documento).
  List<Opcao> _procuradores = const [];
  List<Map<String, dynamic>> _procuradoresInfo = const [];

  /// O prestador tem certificado próprio? Sem ele, as notas são sempre do procurador.
  bool _temCertProprio = true;
  bool cbProcurador = false;
  final ddProcurador = Suspensa();

  /// Aviso quando o serviço guardava um procurador que foi excluído.
  String _procuradorSumiu = '';
  // Nota com desconto incondicionado: as retenções saem do valor já sem ele (o que a lei manda
  // reter é sobre o montante a pagar) ou, desmarcado, do valor cheio do serviço.
  bool cbRetAbate = true;
  String? _dicaContrib;
  bool _tribTravado = true;
  bool _tribAberto = false;
  // CST=00 zera a EXIBIÇÃO dos percentuais de PIS/COFINS e desmarca o checkbox de
  // contribuições; os valores reais ficam guardados aqui.
  bool _pctZero = false;
  String _pctZeroPis = '';
  String _pctZeroCofins = '';
  bool _contribZero = false;
  bool _contribZeroVal = true;
  bool _retZero = false;
  String _retZeroIrrf = '';
  String _retZeroCsll = '';
  Map<String, String> _tribGlob = {}; // percentuais herdados do prestador
  final _chaveExpansao = GlobalKey();

  @override
  void initState() {
    super.initState();
    atual = this;
    app.aoEntrar[0] = () {
      if (_tomCarregadoPrest != app.prestador) recarregarTomadores();
      _conferirCertificados();
    };
    app.aoMudarCertificados.add(_conferirCertificados);
    app.aoTrocarPrestador.add(_aoTrocarPrestador);
    app.recarregarTelas.add(recarregarTomadores);
    app.escDaTela[0] = cancelarTributos;
    // O serviço aberto mostra os percentuais HERDADOS de quando foi carregado: recarrega
    // (sem perder a descrição e o valor já digitados).
    app.tributosDoPrestadorMudaram = () {
      if (servico != null && (slug ?? '').isNotEmpty && _tribTravado)
        _descartarTributos();
    };
    app.aoAtualizar(_redesenhar);
    app.aoMudarGrupos.add(_aoMudarGrupos);
    carregarServico(null);
    if (!app.semPrestador) recarregarTomadores();
    for (final c in _camposRascunho) {
      _camposIniciais[c] = c.text;
      c.addListener(_atualizar);
    }
  }

  void _redesenhar() => redesenhar();

  void _aoMudarGrupos() {
    gruposSel = null;
    _tomCarregadoPrest = null;
  }

  /// O cadastro do cliente [doc] foi salvo: se é o cliente em uso aqui, recarrega a lista
  /// de serviços e o serviço carregado — senão a emissão gravaria o formulário antigo por
  /// cima do cadastro.
  void clienteSalvo(String doc) {
    final t = tomador;
    if (t == null || t.isEmpty || soDoc(t) != doc) return;
    final infos = jaLista('cadastro.list_servicos', {
      'prestador': app.prestador,
      'tomador': doc,
    });
    ddServico.opcoes = [
      for (final i in infos)
        Opcao(i['slug'] as String, _ou(i['nome'], i['slug'] as String)),
    ];
    final atualSlug = infos.any((i) => i['slug'] == slug)
        ? slug
        : (infos.isEmpty ? null : infos.first['slug'] as String);
    ddServico.por(atualSlug);
    ddServico.avisar();
    carregarServico(atualSlug);
  }

  void _aoTrocarPrestador() {
    gruposSel = null;
    ddTomador.por(null);
    subst = null; // substituição pendente era do prestador anterior
    limparFormulario();
  }

  @override
  void dispose() {
    for (final c in _camposRascunho) {
      c.removeListener(_atualizar);
    }
    if (atual == this) atual = null;
    _ddTimer?.cancel();
    app.semAtualizar(_redesenhar);
    app.aoMudarCertificados.remove(_conferirCertificados);
    app.aoTrocarPrestador.remove(_aoTrocarPrestador);
    app.recarregarTelas.remove(recarregarTomadores);
    app.aoMudarGrupos.remove(_aoMudarGrupos);
    super.dispose();
  }

  void _atualizar() => redesenhar();

  // ---- substituição ---------------------------------------------------------------- //
  String get _textoSubst {
    final s = subst;
    if (s == null) return '';
    final motivo = substMotivos()[s['cMotivo'] ?? ''] ?? '';
    return 'SUBSTITUIÇÃO da NFS-e nº ${_ou(s['nNFSe'], '—')} — motivo '
        '${s['cMotivo']} ($motivo). Corrija os dados e clique em Emitir: a '
        'nota antiga será cancelada por substituição. Competência e códigos de '
        'serviço/local são mantidos da nota original (exigência da SEFIN).';
  }

  static String _ou(Object? v, String padrao) {
    final s = v?.toString() ?? '';
    return s.isEmpty ? padrao : s;
  }

  static Map<String, String>? _substMotivos;
  static Map<String, String> substMotivos() => _substMotivos ??= {
    for (final (c, r) in jaPares('emissao.subst_motivos')) c: r,
  };

  void cancelarSubstituicao() {
    final s = subst;
    if (s == null) return;
    registrar(
      'Substituição abandonada pelo usuário (chave antiga=${s['chave']})',
    );
    subst = null;
    // Recarrega o serviço do cadastro: desfaz os campos imutáveis da nota antiga que a
    // substituição havia forçado na tela (e re-trava a expansão).
    if ((tomador ?? '').isNotEmpty && (slug ?? '').isNotEmpty)
      carregarServico(slug);
    app.atualizar();
    app.toast('Substituição cancelada — a próxima emissão volta a ser normal.');
  }

  List<List<String>> _imutaveis([Map<String, dynamic>? s]) => [
    for (final p in ((s ?? subst)?['imutaveis'] as List? ?? const []))
      [(p as List)[0] as String, p[1] as String],
  ];

  String? _imutavel(String nome) {
    for (final p in _imutaveis()) {
      if (p[0] == nome) return p[1];
    }
    return null;
  }

  /// Janela do "Substituir NFS-e": motivo + justificativa. Confirmar leva à tela Emitir com
  /// o cliente da nota carregado e o aviso de substituição ativo.
  void substituir(Map<String, dynamic> rec) {
    if (rec['cancelada'] == true ||
        ((rec['subst_por'] as String?) ?? '').isNotEmpty) {
      app.toast('Esta NFS-e já está cancelada/substituída.', erro: true);
      return;
    }
    final codigo = _ou(rec['tpAmb'], _ou(rec['ambGer'], ''));
    if (codigo != app.ambiente) {
      app.toast(
        'A nota foi emitida em ${ambRotulos[codigo] ?? '?'} e o app '
        'está em ${ambRotulos[app.ambiente] ?? '?'}. Troque o '
        'ambiente em Configurações para substituí-la.',
        erro: true,
      );
      return;
    }
    late final Dialogo d;
    late final Suspensa motivo;
    late final TextEditingController just;

    void continuar() {
      final j = just.text.trim();
      final m = motivo.valor ?? '99';
      // XSD: xMotivo é opcional, mas quando presente exige 15–255 caracteres. Com motivo
      // 99 (Outros) a justificativa é obrigatória.
      if (m == '99' && j.length < 15) {
        app.toast(
          'Para o motivo 99 (Outros), descreva a justificativa (mín. 15 caracteres).',
          erro: true,
        );
        return;
      }
      if (j.isNotEmpty && j.length < 15) {
        app.toast(
          'A justificativa, quando preenchida, deve ter ao menos 15 caracteres.',
          erro: true,
        );
        return;
      }
      app.fecharDialogo();
      _iniciarSubstituicao(rec, m, j);
    }

    d = Dialogo(
      titulo: (_) =>
          textoTitulo('Substituir NFS-e nº ${_ou(rec['nNFSe'], '—')}'),
      largura: 560,
      conteudo: (_) => col(
        [
          Tx(
            'Cliente: ${_ou(rec['tomador_nome'], _ou(rec['tomador'], '—'))}',
            largura: TamanhosEmitir
                .rotuloClienteOuRecTomadorNomeOuRecTomador
                .largura,
            altura:
                TamanhosEmitir.rotuloClienteOuRecTomadorNomeOuRecTomador.altura,
            idLayout:
                'TamanhosEmitir.rotuloClienteOuRecTomadorNomeOuRecTomador',
          ),
          Tx(
            'A substituição emite uma NOTA NOVA vinculada a esta; ao ser aceita, '
            'a SEFIN cancela a nota antiga por substituição (evento e105102) e '
            'liga as duas chaves.',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura: TamanhosEmitir
                .rotuloASubstituicaoEmiteUmaNOTANOVAVinculadaA
                .largura,
            altura: TamanhosEmitir
                .rotuloASubstituicaoEmiteUmaNOTANOVAVinculadaA
                .altura,
            idLayout:
                'TamanhosEmitir.rotuloASubstituicaoEmiteUmaNOTANOVAVinculadaA',
          ),
          ListaSuspensa(
            estado: motivo,
            rotulo: 'Motivo da substituição',
            largura: TamanhosEmitir.campoMotivoDaSubstituicao.largura!,
            altura: TamanhosEmitir.campoMotivoDaSubstituicao.altura,
            idLayout: 'TamanhosEmitir.campoMotivoDaSubstituicao',
          ),
          CampoTexto(
            controle: just,
            rotulo: 'Justificativa (mín. 15 caracteres)',
            variasLinhas: true,
            minLinhas: 2,
            maxLinhas: 4,
            largura: TamanhosEmitir.campoJustificativaMin15Caracteres.largura,
            maximo: 255,
            altura: TamanhosEmitir.campoJustificativaMin15Caracteres.altura,
            idLayout: 'TamanhosEmitir.campoJustificativaMin15Caracteres',
          ),
          Tx(
            'Ao continuar, você vai para a tela Emitir com o cliente desta nota '
            'carregado — corrija o que precisa e clique em Emitir NFS-e.',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura:
                TamanhosEmitir.rotuloAoContinuarVoceVaiParaATelaEmitir.largura,
            altura:
                TamanhosEmitir.rotuloAoContinuarVoceVaiParaATelaEmitir.altura,
            idLayout: 'TamanhosEmitir.rotuloAoContinuarVoceVaiParaATelaEmitir',
          ),
        ],
        justa: true,
        idLayout: 'Grupo.emitir.col.1',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosEmitir.botaoCancelar.largura,
          altura: TamanhosEmitir.botaoCancelar.altura,
          idLayout: 'TamanhosEmitir.botaoCancelar',
        ),
        Botao(
          'Continuar para a emissão',
          icone: Icons.swap_horiz,
          aoClicar: continuar,
          largura: TamanhosEmitir.botaoContinuarParaAEmissao.largura,
          altura: TamanhosEmitir.botaoContinuarParaAEmissao.altura,
          idLayout: 'TamanhosEmitir.botaoContinuarParaAEmissao',
        ),
      ],
      idLayout: 'Janela.emitir.Dialogo.1',
    );
    motivo = d.suspensa(
      valor: '99',
      opcoes: [
        for (final e in substMotivos().entries)
          Opcao(e.key, '${e.key} — ${e.value}'),
      ],
    );
    just = d.texto();
    app.mostrarDialogo(d);
  }

  void _iniciarSubstituicao(
    Map<String, dynamic> rec,
    String cMotivo,
    String xMotivo,
  ) {
    // E0060: a SEFIN rejeita a substituta se dCompet/cTribNac/cTribMun/cLocPrestacao
    // mudarem em relação à nota original — os valores são lidos do XML dela e FORÇADOS na
    // emissão, independentemente do que estiver no cadastro.
    final chave = rec['chave'] as String;
    var imut = <List<String>>[];
    try {
      final xml = ja<String>('cofre.xml_por_chave', {
        'origem': 'substituir',
        'dono': app.prestador,
        'chave': chave,
      });
      imut = [
        for (final p in ja<List>('emissao.subst_campos_imutaveis', {
          'xml': xml,
        }))
          [(p as List)[0] as String, p[1] as String],
      ];
    } catch (e) {
      registrar(
        'XML da NFS-e a substituir ($chave) não pôde ser lido: $e',
        nivel: 'error',
      );
      imut = [];
    }
    final doc = soDoc((rec['tomador'] as String?) ?? '');
    subst = {
      'chave': chave,
      'nNFSe': rec['nNFSe'] ?? '',
      'cMotivo': cMotivo,
      'xMotivo': xMotivo,
      'tomador': doc,
      'imutaveis': imut,
    };
    registrar(
      'Substituição iniciada: NFS-e nº ${rec['nNFSe']} chave $chave '
      'motivo=$cMotivo (prestador=${app.prestador})',
    );
    gruposSel = null; // filtro de grupos não pode esconder o cliente da nota
    app.irPara(0); // vai para a Emitir (recarrega tomadores)
    final nasOpcoes = _tomTodos.any((t) => t.$1 == doc);
    if (doc.isNotEmpty && nasOpcoes) {
      ddTomador.porValorCru(doc);
      _aplicarFiltro(''); // puxa a opção selecionada para a janela
      ddTomador.por(doc);
      _aoSelecionarTomador(doc);
      // Pré-preenche o VALOR com o da nota antiga (o resto vem do serviço cadastrado).
      final v = (rec['vServ'] as String?) ?? '';
      if (v.isNotEmpty) vServ.text = decimalBrl(v);
      // Espelha na tela os campos imutáveis da nota original (o que será emitido).
      if (imut.isNotEmpty) {
        cTribNac.por(_imutavel('cTribNac') ?? '');
        cTribMun.text = _imutavel('cTribMun') ?? '';
        cLoc.text = _imutavel('cLocPrestacao') ?? '';
      }
      _recalcular();
    } else {
      app.toast(
        'O cadastro do cliente desta nota não existe mais — selecione o '
        'cliente manualmente para emitir a substituta.',
        erro: true,
      );
    }
    if (imut.isEmpty) {
      app.toast(
        'Não foi possível ler os campos da nota original (competência/códigos '
        'de serviço). A SEFIN exige que eles NÃO mudem na substituição — '
        'confira antes de emitir.',
        erro: true,
      );
    }
    app.atualizar();
  }

  void _limparSubstSeFor(String chave) {
    if (subst != null && subst!['chave'] == chave) {
      subst = null;
      _atualizar();
    }
  }

  // ---- cliente, grupo e serviço ----------------------------------------------------- //
  // Janela de opções da lista de clientes: com MUITOS clientes, o filtro roda aqui (por
  // digitação, em memória) e só as primeiras opções vão para a tela.
  static const _maxOpcoes = 200;

  void recarregarTomadores() {
    _refazerGrupos();
    final p = app.prestador;
    var lista = p.isEmpty
        ? <Map<String, dynamic>>[]
        : jaLista('cadastro.list_tomadores', {'prestador': p});
    final grupos = p.isEmpty
        ? <String>[]
        : ja<List>('cadastro.list_grupos', {'prestador': p}).cast<String>();
    final sel = gruposSel;
    if (sel != null) {
      final gmap = {
        for (final (d, g) in jaPares('cadastro.tomadores_grupos', {
          'prestador': p,
        }))
          d: g,
      };
      lista = [
        for (final t in lista)
          if (sel.contains(() {
            var g = gmap[soDoc(t['documento'] as String)] ?? '';
            if (g.isEmpty) g = semGrupo;
            if (!grupos.contains(g)) g = semGrupo;
            return g;
          }()))
            t,
      ];
    }
    _tomTodos = [
      for (final t in lista)
        (
          t['documento'] as String,
          t['display'] as String,
          buscaCompacta(t['display'] as String),
        ),
    ];
    _aplicarFiltro('');
    final v = ddTomador.valor;
    if (v != null && lista.every((t) => t['documento'] != v)) {
      // Cliente selecionado saiu da lista (filtro de grupos/exclusão): limpa a seleção, o
      // rótulo exibido e o formulário inteiro.
      ddTomador.por(null);
      limparFormulario();
    }
    _tomCarregadoPrest = p;
    ddTomador.avisar();
    _atualizar();
  }

  /// (Re)monta as opções da lista de clientes: lista completa quando pequena; janela das
  /// primeiras — filtrada pela digitação, "começa com" primeiro — quando grande.
  void _aplicarFiltro(String termo) {
    final termos = termosBusca(termo);
    final compacto = termos.join();
    List<(String, String, String)> achou;
    if (_tomTodos.length <= _maxOpcoes || compacto.isEmpty) {
      achou = _tomTodos;
    } else {
      final comeca = [
        for (final p in _tomTodos)
          if (p.$3.startsWith(compacto)) p,
      ];
      final contem = [
        for (final p in _tomTodos)
          if (termos.every(p.$3.contains) && !p.$3.startsWith(compacto)) p,
      ];
      achou = [...comeca, ...contem];
    }
    var recorte = achou.take(_maxOpcoes).toList();
    // A opção SELECIONADA nunca sai da janela (sem ela o campo perderia o rótulo).
    final sel = ddTomador.valor;
    if (sel != null && recorte.every((p) => p.$1 != sel)) {
      for (final p in _tomTodos) {
        if (p.$1 == sel) {
          recorte = [p, ...recorte.take(_maxOpcoes - 1)];
          break;
        }
      }
    }
    final atuais = ddTomador.opcoes;
    if (atuais.length == recorte.length) {
      var igual = true;
      for (var i = 0; i < atuais.length; i++) {
        if (atuais[i].chave != recorte[i].$1 ||
            atuais[i].texto != recorte[i].$2) {
          igual = false;
          break;
        }
      }
      if (igual) return;
    }
    ddTomador.opcoes = [for (final p in recorte) Opcao(p.$1, p.$2)];
  }

  void _aoTextoTomador(String texto) {
    _atualizar();
    // Só age com lista GRANDE (janela nossa); pequenas ficam com o filtro do próprio menu.
    if (_tomTodos.length <= _maxOpcoes) return;
    _aplicarFiltro(texto);
    ddTomador.avisar();
  }

  void _refazerGrupos() {
    final p = app.prestador;
    final grupos = p.isEmpty
        ? <String>[]
        : ja<List>('cadastro.list_grupos', {'prestador': p}).cast<String>();
    final todas = [...grupos, semGrupo];
    var sel = gruposSel;
    if (sel != null) {
      sel = sel.intersection(
        todas.toSet(),
      ); // grupo removido/renomeado: volta a Todos
      gruposSel = sel.isEmpty ? null : sel;
    }
    final chaves = [todos, ...todas];
    if (ddGrupo.opcoes.map((o) => o.chave).join('\n') != chaves.join('\n')) {
      ddGrupo.opcoes = [
        const Opcao(todos, 'Todos'),
        for (final g in todas) Opcao(g, g),
      ];
    }
    ddGrupo.por(gruposSel?.first ?? todos);
    ddGrupo.avisar();
  }

  void _aoGrupo(String? escolha) {
    gruposSel = (escolha == null || escolha.isEmpty || escolha == todos)
        ? null
        : {escolha};
    recarregarTomadores();
  }

  void _aoSelecionarTomador(String? doc) {
    _cancelarTimer(); // seleção feita: aborta a restauração agendada na saída do campo
    if (doc == null || doc.isEmpty) {
      limparFormulario();
      return;
    }
    _tomAnterior = doc; // nova seleção vira o "restaurável" do próximo ciclo
    tomador = soDoc(doc);
    xnome =
        (jaMapa('cadastro.get_tomador_form', {
              'prestador': app.prestador,
              'tomador': doc,
            })['xNome']
            as String?) ??
        '';
    final infos = jaLista('cadastro.list_servicos', {
      'prestador': app.prestador,
      'tomador': doc,
    });
    ddServico.opcoes = [
      for (final i in infos)
        Opcao(i['slug'] as String, _ou(i['nome'], i['slug'] as String)),
    ];
    // Auto-seleciona o 1º serviço (ou o único).
    final primeiro = infos.isEmpty ? null : infos.first['slug'] as String;
    ddServico.por(primeiro);
    ddServico.avisar();
    carregarServico(primeiro);
    _atualizar();
  }

  void _cancelarTimer() {
    _ddTimer?.cancel();
    _ddTimer = null;
  }

  // Regras do campo do cliente:
  // - FOCO com cliente selecionado: ZERA o campo na hora (a seleção fica guardada; o
  //   formulário não é mexido). O campo vazio faz o PRÓXIMO clique abrir a lista direto.
  // - FOCO com campo vazio: não mexe em nada.
  // - SAÍDA sem escolher: restaura o cliente anterior com ATRASO de 0,35 s; escolher um
  //   item cancela a restauração.
  void _aoFocarTomador() {
    _cancelarTimer();
    final v = ddTomador.valor;
    if (v == null) return;
    _tomAnterior = v;
    ddTomador.porValorCru(null);
    ddTomador.texto = '';
    if (_tomTodos.length > _maxOpcoes)
      _aplicarFiltro(''); // reabre com a janela inicial
    ddTomador.avisar();
  }

  void _aoDesfocarTomador() {
    _cancelarTimer();
    if (ddTomador.valor != null) return; // já selecionou
    _ddTimer = app.agendar(
      const Duration(milliseconds: 350),
      _restaurarTomador,
    );
  }

  void _restaurarTomador() {
    _ddTimer = null;
    if (ddTomador.valor != null) return; // uma seleção chegou nesse meio-tempo
    final anterior = _tomAnterior;
    if (anterior == null || anterior.isEmpty) return; // não havia cliente antes
    ddTomador.porValorCru(anterior);
    _aplicarFiltro(''); // garante a opção selecionada na janela atual
    ddTomador.texto =
        _tomTodos.where((t) => t.$1 == anterior).map((t) => t.$2).firstOrNull ??
        '';
    ddTomador.avisar();
  }

  // ---- tributação na expansão "Mais campos" ------------------------------------------ //
  String get _pctPis => _pctZero ? _pctZeroPis : pPis.text;
  String get _pctCofins => _pctZero ? _pctZeroCofins : pCofins.text;
  String get _pctIrrf => _retZero ? _retZeroIrrf : pIrrf.text;
  String get _pctCsll => _retZero ? _retZeroCsll : pCsll.text;

  void alternarTributos() {
    if (!app.temPermissao('emitir.tributos')) {
      app.exigirPermissao('emitir.tributos', () => alternarTributos());
      return;
    }
    if (_tribTravado) {
      if ((tomador ?? '').isEmpty || (slug ?? '').isEmpty) {
        app.toast(
          'Selecione um cliente e um serviço para editar os dados.',
          erro: true,
        );
        return;
      }
      _tribTravado = false;
      _recalcular();
      return;
    }
    _salvarTributos();
  }

  String? get _competencia => _imutavel('dCompet');

  List<String> _validar(Map<String, dynamic> form) {
    final exigeRtc = ja<bool>('cadastro.rtc_required', {
      'prestador': app.prestador,
      'form': form,
      'ambiente': app.ambiente,
      'competencia': _competencia ?? '',
    });
    return ja<List>('cadastro.servico_validate', {
      'form': form,
      'prestador': app.prestador,
      'require_rtc': exigeRtc,
    }).cast<String>();
  }

  void _salvarTributos() {
    Map<String, dynamic> form;
    try {
      form = coletar();
      final erros = _validar(form);
      if (erros.isNotEmpty) {
        app.toast('Corrija: ${erros.join('; ')}', erro: true);
        return;
      }
      ja<Object?>('cadastro.save_servico', {
        'origem': 'emitir',
        'prestador': app.prestador,
        'tomador': tomador,
        'servico': slug,
        'form': form,
      });
    } catch (e) {
      app.toast('Não foi possível salvar os dados: $e', erro: true);
      return;
    }
    servico = form;
    _tribTravado = true;
    _recalcular();
    app.toast('Dados salvos no serviço.');
  }

  /// Esc com os tributos em edição: descarta o que não foi salvo e re-trava (a expansão
  /// continua aberta). True se havia edição aberta.
  bool cancelarTributos() {
    if (_tribTravado) return false;
    _tribTravado = true;
    _descartarTributos();
    return true;
  }

  void _descartarTributos() {
    final descricao = xDesc.text;
    final valor = vServ.text;
    final descontos = (vDescInc.text, vDescCond.text, cbRetAbate);
    carregarServico(slug);
    xDesc.text = descricao;
    vServ.text = valor;
    vDescInc.text = descontos.$1;
    vDescCond.text = descontos.$2;
    cbRetAbate = descontos.$3;
    _recalcular();
  }

  void _classes(String cst, [String escolhida = '']) {
    final ops = jaPares('catalogo.class_options', {'cst': cst});
    rtcClasse.opcoes = opcoesDe(ops);
    rtcClasse.por(ops.any((o) => o.$1 == escolhida) ? escolhida : null);
    rtcClasse.avisar();
  }

  static String _brl(Dec d) => decimalBrl(d.fixo2());

  /// Recalcula os R$ da expansão e aplica o que o CST e a retenção travam.
  void _recalcular() {
    final cst = ddCst.valor ?? '01';
    final ret = ddRet.valor ?? '0';
    final semCalc = cst == '00';
    final naoRetido = ret == '0';
    if (naoRetido && !_retZero) {
      _retZero = true;
      _retZeroIrrf = pIrrf.text;
      _retZeroCsll = pCsll.text;
      pIrrf.text = '0,00';
      pCsll.text = '0,00';
    } else if (!naoRetido && _retZero) {
      pIrrf.text = _retZeroIrrf;
      pCsll.text = _retZeroCsll;
      _retZero = false;
    }
    // CST=00 <-> tributado: zera/restaura a EXIBIÇÃO dos percentuais de PIS/COFINS.
    if (semCalc && !_pctZero) {
      _pctZero = true;
      _pctZeroPis = pPis.text;
      _pctZeroCofins = pCofins.text;
      pPis.text = '0,00';
      pCofins.text = '0,00';
    } else if (!semCalc && _pctZero) {
      pPis.text = _pctZeroPis;
      pCofins.text = _pctZeroCofins;
      _pctZero = false;
    }
    // CST=00 <-> tributado: desmarca/restaura a EXIBIÇÃO do checkbox de contribuições.
    if ((semCalc || naoRetido) && !_contribZero) {
      _contribZero = true;
      _contribZeroVal = cbContrib;
      cbContrib = false;
    } else if (!semCalc && !naoRetido && _contribZero) {
      cbContrib = _contribZeroVal;
      _contribZero = false;
    }
    // O EFETIVO, não o que está na tela: com CST=00 o checkbox é desmarcado só para
    // exibição, mas a retenção gravada no cadastro continua devida e é transmitida.
    final contribEfetivo = _contribZero ? _contribZeroVal : cbContrib;
    final semContrib = !contribEfetivo;
    // Base do PIS/COFINS próprio: o valor do serviço menos o desconto INCONDICIONADO (o núcleo
    // calcula igual; o condicionado não reduz base). As retenções têm a base delas.
    final base = _baseDosTributos();
    final baseRet = _baseDasRetencoes();
    final vpis = Dec.percentual(base, Dec.ouZero(_pctPis));
    final vcofins = Dec.percentual(base, Dec.ouZero(_pctCofins));
    final vcsll = Dec.percentual(baseRet, Dec.ouZero(pCsll.text));
    final virrf = Dec.percentual(baseRet, Dec.ouZero(pIrrf.text));
    final contrib = _contribuicoesRetidas(baseRet);
    final zero = decimalBrl('0.00');
    lBase.text = semCalc ? zero : _brl(base);
    lPis.text = semCalc ? zero : _brl(vpis);
    lCofins.text = semCalc ? zero : _brl(vcofins);
    lIrrf.text = naoRetido ? zero : _brl(virrf);
    lCsll.text = (naoRetido || semContrib) ? zero : _brl(vcsll);
    lContrib.text = (naoRetido || semContrib) ? zero : _brl(contrib);
    _dicaContrib = (semCalc && _contribZero && _contribZeroVal)
        ? 'CST 00 não apura PIS/COFINS, mas a retenção gravada no cadastro do serviço '
              'CONTINUA devida e é transmitida na nota.'
        : null;
    lFed.text = _brl(Dec.percentual(base, Dec.ouZero(pFed.text)));
    lEst.text = _brl(Dec.percentual(base, Dec.ouZero(pEst.text)));
    lMun.text = _brl(Dec.percentual(base, Dec.ouZero(pMun.text)));
    // Catálogos: lista inteira só com os tributos em edição.
    for (final c in [cTribNac, cNbs]) {
      if (_tribTravado ? c.enxugar() : c.encher()) c.dd.avisar();
    }
    _atualizar();
  }

  Dec _baseDosTributos() =>
      Dec.ouZero(brlDecimal(vServ.text)) -
      Dec.ouZero(brlDecimal(vDescInc.text));

  bool get _temDescontoIncondicionado =>
      Dec.ouZero(brlDecimal(vDescInc.text)).positivo;

  /// Base das retenções (IRRF e CSLL/PIS/COFINS): a mesma do PIS/COFINS, ou o valor cheio do
  /// serviço quando a caixa está desmarcada numa nota com desconto incondicionado.
  Dec _baseDasRetencoes() => (cbRetAbate || !_temDescontoIncondicionado)
      ? _baseDosTributos()
      : Dec.ouZero(brlDecimal(vServ.text));

  /// PIS + COFINS + CSLL retidos, cada um arredondado antes de somar (como o núcleo).
  Dec _contribuicoesRetidas(Dec base) =>
      (Dec.percentual(base, Dec.ouZero(_pctPis)) +
              Dec.percentual(base, Dec.ouZero(_pctCofins)) +
              Dec.percentual(base, Dec.ouZero(pCsll.text)))
          .dinheiro();

  /// Condomínio: o valor da nota e os descontos são as somas das cobranças e dos descontos
  /// lançados no cadastro do cliente — aqui só se vê.
  bool get _condominio => (cTribNac.dd.valor ?? '').startsWith('9905');

  /// Carrega o serviço escolhido no corpo da emissão (a expansão volta TRAVADA).
  void carregarServico(String? novo) {
    slug = novo;
    _tribTravado = true;
    _pctZero = false;
    _contribZero = false;
    _retZero = false;
    if (novo == null || novo.isEmpty || (tomador ?? '').isEmpty) {
      servico = null;
      _tribGlob = {};
      for (final c in [
        xDesc,
        vServ,
        vDescInc,
        vDescCond,
        cLoc,
        cTribMun,
        destDoc,
        destNome,
        destMun,
        destCep,
        destLgr,
        destNro,
        destCpl,
        destBairro,
        pPis,
        pCofins,
        pIrrf,
        pCsll,
        pFed,
        pEst,
        pMun,
      ]) {
        c.text = '';
      }
      cTribNac.por('');
      cNbs.por('');
      ddCst.por(cstOpcoes.first.$1);
      ddRet.por(retOpcoes.first.$1);
      ddIss.por(issOpcoes.first.$1);
      ddRetIss.por(retIssOpcoes.first.$1);
      rtcIndDest.por(null);
      rtcIndOp.por(null);
      rtcCst.por(null);
      destTipo.por('CNPJ');
      _classes('');
      cbContrib = true;
      cbRetAbate = true;
      _carregarProcuradores('');
      _avisarListas();
      _recalcular();
      return;
    }
    final f = jaMapa('cadastro.get_servico', {
      'prestador': app.prestador,
      'tomador': tomador,
      'servico': novo,
    });
    servico = f;
    String s(String k) => (f[k] as String?) ?? '';
    final glob = app.prestador.isEmpty
        ? <String, String>{}
        : {
            for (final (k, v) in jaPares('cadastro.read_tributos', {
              'prestador': app.prestador,
            }))
              k: v,
          };
    _tribGlob = glob;
    // o que vai ser emitido
    xDesc.text = ja<String>('texto.limpar_descricao', {
      'valor': s('xDescServ'),
    });
    vServ.text = decimalBrl(s('vServ'));
    vDescInc.text = decimalBrl(s('vDescIncond'));
    vDescCond.text = decimalBrl(s('vDescCond'));
    cTribNac.por(s('cTribNac'));
    cNbs.por(s('cNBS'));
    cLoc.text = s('cLocPrestacao');
    cTribMun.text = s('cTribMun');
    ddCst.por(s('pis_CST'));
    ddRet.por(s('tpRetPisCofins'));
    ddIss.por(s('tribISSQN'));
    ddRetIss.por(s('tpRetISSQN'));
    rtcIndDest.por(s('rtc_indDest'));
    rtcIndOp.por(s('rtc_cIndOp'));
    rtcCst.por(s('rtc_CST'));
    _classes(s('rtc_CST'), s('rtc_cClassTrib'));
    destTipo.por(s('dest_tipo').isEmpty ? 'CNPJ' : s('dest_tipo'));
    destDoc.text = s('dest_documento');
    destNome.text = s('dest_xNome');
    destMun.text = s('dest_cMun');
    destCep.text = s('dest_CEP');
    destLgr.text = s('dest_xLgr');
    destNro.text = s('dest_nro');
    destCpl.text = s('dest_xCpl');
    destBairro.text = s('dest_xBairro');
    cbContrib =
        (s('incluir_contrib').isEmpty ? '1' : s('incluir_contrib')).trim() !=
        '0';
    cbRetAbate = s('ret_abate_desconto').trim() != '0';
    _carregarProcuradores(s('cert_procurador'));
    // Percentuais exibidos SEMPRE com vírgula (mesmo que a configuração use ponto).
    String pct(String sobra, String herdado) => pctVirgula(
      s(sobra).trim().isEmpty ? (glob[herdado] ?? '') : s(sobra).trim(),
    );
    pPis.text = pct('ov_pAliqPis', 'pAliqPis');
    pCofins.text = pct('ov_pAliqCofins', 'pAliqCofins');
    pIrrf.text = pct('ov_pIRRF', 'irrf');
    pCsll.text = pct('ov_pCSLL', 'csll');
    pFed.text = pct('ov_pTotTribFed', 'pTotTribFed');
    pEst.text = pct('ov_pTotTribEst', 'pTotTribEst');
    pMun.text = pct('ov_pTotTribMun', 'pTotTribMun');
    _avisarListas();
    _recalcular();
  }

  /// Lê os procuradores do prestador e aplica a escolha guardada no serviço.
  void _carregarProcuradores(String guardado) {
    _procuradorSumiu = '';
    if (app.prestador.isEmpty || servico == null) {
      _procuradores = const [];
      _procuradoresInfo = const [];
      _temCertProprio = true;
      cbProcurador = false;
      ddProcurador.opcoes = const [];
      ddProcurador.por(null);
      return;
    }
    final infos = jaLista('cadastro.procuradores_info', {
      'prestador': app.prestador,
    });
    _procuradoresInfo = infos;
    _procuradores = [
      for (final i in infos)
        Opcao(i['documento'] as String, _rotuloProcurador(i)),
    ];
    _temCertProprio = ja<String>('cadastro.cert_proprio', {
      'prestador': app.prestador,
    }).isNotEmpty;
    final docs = [for (final o in _procuradores) o.chave];
    final doc = soDoc(guardado);
    final existe = docs.contains(doc);
    if (doc.isNotEmpty && !existe) {
      _procuradorSumiu =
          'O procurador ${formatarDocumento(doc)} escolhido antes neste serviço não '
          'está mais cadastrado. Confira quem assina antes de emitir.';
    }
    ddProcurador.opcoes = _procuradores;
    ddProcurador.por(existe ? doc : (docs.isEmpty ? null : docs.first));
    // Sem certificado próprio, quem assina é sempre um procurador.
    cbProcurador = _procuradores.isNotEmpty && (!_temCertProprio || existe);
    ddProcurador.avisar();
  }

  /// Quem assina agora ('' = o certificado próprio).
  String get _assinanteAtual => cbProcurador ? (ddProcurador.valor ?? '') : '';

  /// Confere de novo os certificados do prestador (podem ter sido excluídos ou importados
  /// depois que o serviço foi aberto) mantendo a escolha atual, se ela ainda existir.
  /// Devolve true se quem assina mudou.
  bool _conferirCertificados() {
    if (servico == null) return false;
    final antes = _assinanteAtual;
    _carregarProcuradores(antes);
    final mudou = _assinanteAtual != antes;
    if (mounted) redesenhar();
    return mudou;
  }

  String _rotuloProcurador(Map<String, dynamic> i) {
    final doc = formatarDocumento((i['documento'] as String?) ?? '');
    final titular = (i['titular'] as String?) ?? '';
    final dias = (i['dias_restantes'] as num?)?.toInt();
    final vencido = dias != null && dias < 0 ? ' — VENCIDO' : '';
    final nome = titular.isEmpty ? doc : '$titular ($doc)';
    return '$nome$vencido';
  }

  /// Rótulo de quem assina a nota, para a confirmação ('' = o certificado próprio).
  String get _assinaComo {
    if (!cbProcurador) return '';
    final doc = ddProcurador.valor ?? '';
    for (final o in _procuradores) {
      if (o.chave == doc) return o.texto;
    }
    return formatarDocumento(doc);
  }

  /// "Assinar com certificado de procurador", acima dos botões de pré-visualizar e emitir.
  /// Com mais de um procurador, marcar abre a escolha; o escolhido aparece ao lado, com
  /// "Trocar…".
  Widget _linhaProcurador() {
    final varios = _procuradores.length > 1;
    return lin(
      [
        Marcar(
          valor: cbProcurador,
          rotulo: 'Assinar com certificado de procurador',
          compacto: true,
          desabilitado: !_temCertProprio || _emitindo,
          dica: _temCertProprio
              ? 'A nota sai com os dados do prestador; o certificado do procurador só '
                    'assina e transmite (a SEFIN confere a procuração). A escolha fica '
                    'salva neste serviço ao emitir.'
              : 'Este prestador não tem certificado próprio: as notas são assinadas '
                    'pelo procurador.',
          aoMudar: (v) {
            if (v == true && varios) {
              _escolherProcurador();
              return;
            }
            if (!app.temPermissao('emitir.procurador')) {
              app.exigirPermissao('emitir.procurador', () {
                cbProcurador = v == true;
                _atualizar();
              });
              return;
            }
            cbProcurador = v == true;
            if (cbProcurador) _procuradorSumiu = '';
            _atualizar();
          },
          idLayout: 'TamanhosEmitir.marcarAssinarProcurador',
        ),
        if (cbProcurador && _procuradores.isNotEmpty)
          Tx(
            varios ? _assinaComo : _procuradores.first.texto,
            tam: Letra.apoio,
            peso: FontWeight.w600,
            cor: Colors.grey.shade800,
            largura: TamanhosEmitir.rotuloProcuradorUnico.largura,
            altura: TamanhosEmitir.rotuloProcuradorUnico.altura,
            idLayout: 'TamanhosEmitir.rotuloProcuradorUnico',
          ),
        if (cbProcurador && varios)
          Botao.texto(
            'Trocar…',
            icone: Icons.swap_horiz,
            desabilitado: _emitindo,
            aoClicar: _escolherProcurador,
            largura: TamanhosEmitir.botaoTrocarProcurador.largura,
            altura: TamanhosEmitir.botaoTrocarProcurador.altura,
            idLayout: 'TamanhosEmitir.botaoTrocarProcurador',
          ),
        if (_procuradorSumiu.isNotEmpty)
          Tx(
            _procuradorSumiu,
            tam: Letra.apoio,
            cor: Colors.orange.shade800,
            largura: TamanhosEmitir.rotuloProcuradorSumiu.largura,
            altura: TamanhosEmitir.rotuloProcuradorSumiu.altura,
            idLayout: 'TamanhosEmitir.rotuloProcuradorSumiu',
          ),
      ],
      espaco: 12,
      quebra: true,
      idLayout: 'Grupo.emitir.lin.procurador',
    );
  }

  /// Janela "Qual procurador assina?": um cartão por procurador; clicar escolhe e fecha.
  /// Fechar sem escolher deixa como estava.
  void _escolherProcurador() {
    if (!app.temPermissao('emitir.procurador')) {
      app.exigirPermissao('emitir.procurador', _escolherProcurador);
      return;
    }
    if (_emitindo) return;
    late final Dialogo d;
    final atual = cbProcurador ? (ddProcurador.valor ?? '') : '';

    void escolher(String doc) {
      ddProcurador.por(doc);
      cbProcurador = true;
      _procuradorSumiu = '';
      app.fecharEsta(d);
      _atualizar();
    }

    Widget item(BuildContext context, Map<String, dynamic> i) {
      final esquema = Theme.of(context).colorScheme;
      final doc = (i['documento'] as String?) ?? '';
      final titular = (i['titular'] as String?) ?? '';
      final dias = (i['dias_restantes'] as num?)?.toInt();
      final ate = (i['not_after'] as String?) ?? '';
      final venc = ate.length >= 10
          ? '${ate.substring(8, 10)}/${ate.substring(5, 7)}/${ate.substring(0, 4)}'
          : '';
      final vencido = dias != null && dias < 0;
      final escolhido = doc == atual;
      final validade = venc.isEmpty
          ? ''
          : vencido
          ? 'VENCIDO em $venc'
          : 'válido até $venc';
      return Material(
        color: escolhido
            ? esquema.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: escolhido ? esquema.primary : esquema.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => escolher(doc),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                Icon(
                  doc.length == 11 ? Icons.person_outline : Icons.business,
                  color: esquema.primary,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titular.isEmpty ? formatarDocumento(doc) : titular,
                        style: const TextStyle(
                          fontSize: Letra.texto,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          '${doc.length == 11 ? 'CPF' : 'CNPJ'} ${formatarDocumento(doc)}',
                          if (validade.isNotEmpty) validade,
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: Letra.apoio,
                          color: vencido
                              ? Colors.red.shade700
                              : esquema.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (escolhido)
                  Icon(Icons.check_circle, color: esquema.primary, size: 20),
              ],
            ),
          ),
        ),
      );
    }

    d = Dialogo(
      titulo: (_) => app.tituloComX('Qual procurador assina?'),
      largura: 520,
      conteudo: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (n, i) in _procuradoresInfo.indexed) ...[
            if (n > 0) const SizedBox(height: 8),
            item(context, i),
          ],
        ],
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosEmitir.botaoCancelarProcurador.largura,
          altura: TamanhosEmitir.botaoCancelarProcurador.altura,
          idLayout: 'TamanhosEmitir.botaoCancelarProcurador',
        ),
      ],
      idLayout: 'Janela.emitir.Dialogo.procurador',
    );
    app.mostrarDialogo(d);
  }

  void _avisarListas() {
    for (final d in [
      cTribNac.dd,
      cNbs.dd,
      ddCst,
      ddRet,
      ddIss,
      ddRetIss,
      rtcIndDest,
      rtcIndOp,
      rtcCst,
      destTipo,
    ]) {
      d.avisar();
    }
  }

  final _camposIniciais = <TextEditingController, String>{};
  List<TextEditingController> get _camposRascunho => [
    xDesc,
    vServ,
    vDescInc,
    vDescCond,
    cLoc,
    cTribMun,
    destDoc,
    destNome,
    destMun,
    destCep,
    destLgr,
    destNro,
    destCpl,
    destBairro,
    pPis,
    pCofins,
    pIrrf,
    pCsll,
    pFed,
    pEst,
    pMun,
  ];
  bool get _temRascunho =>
      (tomador ?? '').isNotEmpty ||
      (ddTomador.texto ?? '').trim().isNotEmpty ||
      (ddGrupo.valor ?? todos) != todos ||
      gruposSel != null ||
      (slug ?? '').isNotEmpty ||
      subst != null ||
      _camposRascunho.any(
        (c) => c.text.trim() != (_camposIniciais[c] ?? '').trim(),
      ) ||
      ddCst.valor != cstOpcoes.first.$1 ||
      ddRet.valor != retOpcoes.first.$1 ||
      ddIss.valor != issOpcoes.first.$1 ||
      ddRetIss.valor != retIssOpcoes.first.$1 ||
      rtcCst.valor != null ||
      rtcIndOp.valor != null ||
      rtcClasse.valor != null;

  void _cancelarEmissao() {
    if (!app.temPermissao('emitir.rascunho')) {
      app.exigirPermissao('emitir.rascunho', () => _cancelarEmissao());
      return;
    }
    if (_emitindo || _travaUi || app.ocupado) return;
    FocusManager.instance.primaryFocus?.unfocus();
    subst = null;
    gruposSel = null;
    limparFormulario();
    ddTomador.ciclo++; // invalida restaurações de foco pendentes
    ddTomador.por(null);
    ddTomador.texto = '';
    _aplicarFiltro('');
    ddTomador.avisar();
    ddGrupo.por(todos);
    ddGrupo.avisar();
    _tribAberto = false;
    recarregarTomadores();
    _atualizar();
  }

  void limparFormulario() {
    servico = null;
    tomador = null;
    slug = null;
    xnome = '';
    _cancelarTimer(); // nada pendente de restaurar no campo de cliente
    _tomAnterior = null;
    ddServico.opcoes = const [];
    ddServico.por(null);
    ddServico.avisar();
    carregarServico(null); // limpa corpo + expansão e re-trava
  }

  /// O serviço como será emitido (o do cadastro com o que está na tela por cima).
  Map<String, dynamic> coletar() {
    final base = servico;
    if (base == null || (tomador ?? '').isEmpty || (slug ?? '').isEmpty) {
      throw ErroNucleo(
        'ValueError',
        'Selecione um cliente e um serviço antes de emitir.',
      );
    }
    final pendentes = naoSelecionadas([
      (cTribNac.dd, 'Código de Tributação Nacional'),
      (cNbs.dd, 'Item da NBS'),
      (ddCst, 'Situação Tributária do PIS/COFINS (CST)'),
      (ddRet, 'Tipo de retenção do PIS/COFINS/CSLL'),
      (ddIss, 'Tributação do ISSQN'),
      (ddRetIss, 'Retenção do ISSQN'),
      (rtcIndDest, 'Destinatário é o próprio adquirente?'),
      (rtcIndOp, 'Indicador da operação (cIndOp)'),
      (rtcCst, 'Situação tributária IBS/CBS (CST)'),
      (rtcClasse, 'Classificação tributária IBS/CBS'),
      if (rtcIndDest.valor == '1') (destTipo, 'Documento do destinatário'),
    ]);
    if (pendentes.isNotEmpty) {
      throw ErroNucleo(
        'ValueError',
        'Selecione uma opção da lista em: ${pendentes.join(', ')}',
      );
    }
    final f = Map<String, dynamic>.of(base);
    f['xDescServ'] = xDesc.text;
    f['vServ'] = brlDecimal(vServ.text);
    f['vDescIncond'] = brlDecimal(vDescInc.text);
    f['vDescCond'] = brlDecimal(vDescCond.text);
    f['cert_procurador'] = cbProcurador ? (ddProcurador.valor ?? '') : '';
    f['cTribNac'] = cTribNac.dd.valor ?? '';
    f['cNBS'] = cNbs.dd.valor ?? '';
    f['cLocPrestacao'] = cLoc.text;
    f['cTribMun'] = cTribMun.text;
    f['tribISSQN'] = ddIss.valor ?? '';
    f['tpRetISSQN'] = ddRetIss.valor ?? '';
    f['rtc_indDest'] = rtcIndDest.valor ?? '';
    f['rtc_cIndOp'] = rtcIndOp.valor ?? '';
    f['rtc_CST'] = rtcCst.valor ?? '';
    f['rtc_cClassTrib'] = rtcClasse.valor ?? '';
    f['dest_tipo'] = destTipo.valor ?? 'CNPJ';
    f['dest_documento'] = destDoc.text;
    f['dest_xNome'] = destNome.text;
    f['dest_cMun'] = destMun.text;
    f['dest_CEP'] = destCep.text;
    f['dest_xLgr'] = destLgr.text;
    f['dest_nro'] = destNro.text;
    f['dest_xCpl'] = destCpl.text;
    f['dest_xBairro'] = destBairro.text;
    f['pis_CST'] = ddCst.valor ?? '';
    f['tpRetPisCofins'] = ddRet.valor ?? '';
    f['incluir_contrib'] = (_contribZero ? _contribZeroVal : cbContrib)
        ? '1'
        : '0';
    f['ret_abate_desconto'] = cbRetAbate ? '1' : '0';
    f['ov_pAliqPis'] = sobraPercentual(_pctPis, _tribGlob['pAliqPis']);
    f['ov_pAliqCofins'] = sobraPercentual(_pctCofins, _tribGlob['pAliqCofins']);
    f['ov_pIRRF'] = sobraPercentual(_pctIrrf, _tribGlob['irrf']);
    f['ov_pCSLL'] = sobraPercentual(_pctCsll, _tribGlob['csll']);
    f['ov_pTotTribFed'] = sobraPercentual(pFed.text, _tribGlob['pTotTribFed']);
    f['ov_pTotTribEst'] = sobraPercentual(pEst.text, _tribGlob['pTotTribEst']);
    f['ov_pTotTribMun'] = sobraPercentual(pMun.text, _tribGlob['pTotTribMun']);
    // CST=00: retenções gravadas como valores literais (derivados dos percentuais reais).
    if (f['pis_CST'] == '00') {
      final b = _baseDasRetencoes();
      final virrf = Dec.percentual(b, Dec.ouZero(pIrrf.text));
      final contrib = _contribuicoesRetidas(b);
      f['vRetIRRF_manual'] = virrf.fixo2();
      f['vRetCSLL_manual'] = contrib.fixo2();
    } else {
      f['vRetIRRF_manual'] = '';
      f['vRetCSLL_manual'] = '';
    }
    return f;
  }

  List<Object?>? _extraSubst([Map<String, dynamic>? s]) {
    final sub = s ?? subst;
    if (sub == null) return null;
    return ja<List>('emissao.subst_overrides', {
      'chave': sub['chave'],
      'c_motivo': sub['cMotivo'],
      'x_motivo': sub['xMotivo'] ?? '',
      'imutaveis': _imutaveis(sub),
    });
  }

  // ---- pré-visualização --------------------------------------------------------------- //
  void aoPrevisualizar() {
    if (!app.temPermissao('emitir.previa')) {
      app.exigirPermissao('emitir.previa', () => aoPrevisualizar());
      return;
    }
    if (!_pronto()) return;
    if (!_tribTravado) {
      app.toast('Salve os dados antes de pré-visualizar.', erro: true);
      return;
    }
    Map<String, dynamic> pv;
    Map<String, Object?> argumentos;
    try {
      // Pré-visualizar NÃO grava nada: o serviço vai em memória.
      final form = coletar();
      final erros = _validar(form);
      if (erros.isNotEmpty) {
        app.toast('Corrija: ${erros.join('; ')}', erro: true);
        return;
      }
      if (!Dec.ouZero(form['vServ'] as String).positivo) {
        app.toast('Informe o valor do serviço.', erro: true);
        return;
      }
      // Substituição em andamento: o XML mostrado inclui o grupo <subst>.
      argumentos = {
        'prestador': app.prestador,
        'tomador': tomador,
        'ambiente': app.ambiente,
        'servico': slug,
        'form': form,
        'extra_overrides': _extraSubst() ?? const [],
      };
      pv = jaMapa('emissao.preview', argumentos);
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    abrirPreviaEmissao(
      app,
      pv: pv,
      argumentos: argumentos,
      ambiente: ambRotulos[pv['tp_amb']] ?? '',
      assinante: _assinaComo,
    );
  }

  bool _pronto() {
    if (app.prestador.isEmpty) {
      app.toast('Selecione um prestador.', erro: true);
      return false;
    }
    // Sempre relido do banco: o certificado pode ter sido excluído com esta tela aberta.
    // (O aviso já faz esta tela reler os procuradores: compara com quem assinava ANTES.)
    final assinavaAntes = _assinanteAtual;
    final tinhaServico = servico != null;
    app.certificadosMudaram();
    if (app.cert.isEmpty) {
      app.toast(
        'Nenhum certificado digital cadastrado para o prestador. Importe um em '
        'Configurações > Certificado.',
        erro: true,
      );
      return false;
    }
    if ((tomador ?? '').isEmpty || ddTomador.valor == null) {
      app.toast('Selecione um cliente (tomador).', erro: true);
      return false;
    }
    if (servico == null || (slug ?? '').isEmpty) {
      app.toast('Selecione um serviço.', erro: true);
      return false;
    }
    if (tinhaServico && _assinanteAtual != assinavaAntes) {
      app.toast(
        'Os certificados do prestador mudaram. Confira quem assina a nota e tente de novo.',
        erro: true,
      );
      return false;
    }
    return true;
  }

  // ---- emissão -------------------------------------------------------------------------- //
  /// Libera a trava de reentrância do botão Emitir e o reabilita.
  void _liberar() {
    _travaUi = false;
    _atualizar();
  }

  void aoEmitir() {
    // TRAVA NA ENTRADA: um 2º clique não pode abrir um segundo "Confirmar emissão".
    if (_travaUi) return;
    _travaUi = true;
    _atualizar();

    if (!_pronto()) return _liberar();
    if (!_tribTravado) {
      app.toast('Salve os dados antes de emitir.', erro: true);
      return _liberar();
    }
    Map<String, dynamic> form;
    try {
      form = coletar();
      final erros = _validar(form);
      if (erros.isNotEmpty) {
        app.toast('Corrija o cadastro: ${erros.join('; ')}', erro: true);
        return _liberar();
      }
      // O certificado que vai assinar: o próprio ou o do procurador escolhido.
      final certEmissao = ja<String>('cadastro.cert_da_emissao', {
        'prestador': app.prestador,
        'form': form,
      });
      final temSenha =
          certEmissao.isNotEmpty &&
          ja<bool>('cadastro.tem_senha_do_certificado', {
            'prestador': app.prestador,
            'cert': certEmissao,
          });
      if (!temSenha) {
        app.toast(
          'Certificado/senha não configurado. Atualize o certificado na aba Configurações.',
          erro: true,
        );
        return _liberar();
      }
      if (!Dec.ouZero(form['vServ'] as String).positivo) {
        app.toast('Informe o valor do serviço.', erro: true);
        return _liberar();
      }
    } catch (e) {
      app.toast('$e', erro: true);
      return _liberar();
    }
    // Mantém o salvamento de descrição/valor ao clicar Emitir. Os tributos estão travados
    // aqui e qualquer edição deles já exigiu "Salvar tributos".
    bool salvarDados() {
      try {
        ja<Object?>('cadastro.save_servico', {
          'origem': 'emitir',
          'prestador': app.prestador,
          'tomador': tomador,
          'servico': slug,
          'form': form,
        });
        return true;
      } catch (e) {
        app.toast(
          'Não foi possível salvar no cadastro do cliente: $e',
          erro: true,
        );
        return false;
      }
    }

    final amb = ambRotulos[app.ambiente] ?? '';
    final producao = app.ambiente == ambProducao;
    final cor = producao ? Colors.green.shade700 : Colors.red.shade700;

    void confirmar() {
      late final Dialogo d;
      final vBrl = decimalBrl(form['vServ'] as String);
      final assinaComo = _assinaComo;
      d = Dialogo(
        marcador:
            'confirmar_emissao', // um 2º igual é recusado (anti-duplicidade)
        titulo: (_) => textoTitulo('Confirmar emissão'),
        conteudo: (_) => col(
          [
            Ct(
              cor: cor,
              padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
              raio: BorderRadius.circular(6),
              child: Tx(
                'AMBIENTE: $amb',
                cor: Colors.white,
                peso: FontWeight.bold,
                tam: Letra.apoio,
                largura: TamanhosEmitir.rotuloAMBIENTEAmb.largura,
                altura: TamanhosEmitir.rotuloAMBIENTEAmb.altura,
                idLayout: 'TamanhosEmitir.rotuloAMBIENTEAmb',
              ),
            ),
            if (subst != null)
              Ct(
                cor: Colors.orange.shade50,
                raio: BorderRadius.circular(6),
                borda: Border.all(color: Colors.orange.shade300, width: 1),
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: Tx(
                  'SUBSTITUIÇÃO da NFS-e nº ${_ou(subst!['nNFSe'], '—')} — '
                  'a nota antiga será cancelada por substituição.',
                  cor: Colors.orange.shade900,
                  peso: FontWeight.w600,
                  tam: Letra.apoio,
                  largura: TamanhosEmitir
                      .rotuloSUBSTITUICAODaNFSENoOuSubstNNFSe
                      .largura,
                  altura: TamanhosEmitir
                      .rotuloSUBSTITUICAODaNFSENoOuSubstNNFSe
                      .altura,
                  idLayout:
                      'TamanhosEmitir.rotuloSUBSTITUICAODaNFSENoOuSubstNNFSe',
                ),
              ),
            Tx(
              'Cliente: $xnome',
              largura: TamanhosEmitir.rotuloClienteXnome.largura,
              altura: TamanhosEmitir.rotuloClienteXnome.altura,
              idLayout: 'TamanhosEmitir.rotuloClienteXnome',
            ),
            Tx(
              'Serviço: ${form['nome']}',
              largura: TamanhosEmitir.rotuloServicoFormNome.largura,
              altura: TamanhosEmitir.rotuloServicoFormNome.altura,
              idLayout: 'TamanhosEmitir.rotuloServicoFormNome',
            ),
            if (assinaComo.isNotEmpty)
              Tx(
                'Assinada pelo procurador: $assinaComo',
                peso: FontWeight.w600,
                largura: TamanhosEmitir.rotuloAssinadaPeloProcurador.largura,
                altura: TamanhosEmitir.rotuloAssinadaPeloProcurador.altura,
                idLayout: 'TamanhosEmitir.rotuloAssinadaPeloProcurador',
              ),
            Tx(
              'Valor do serviço: ${vBrl.isEmpty ? 'R\$ ${form['vServ']}' : vBrl}',
              largura: TamanhosEmitir
                  .rotuloValorDoServicoVBrlIsEmptyRFormVServ
                  .largura,
              altura: TamanhosEmitir
                  .rotuloValorDoServicoVBrlIsEmptyRFormVServ
                  .altura,
              idLayout:
                  'TamanhosEmitir.rotuloValorDoServicoVBrlIsEmptyRFormVServ',
            ),
            if (Dec.ouZero(form['vDescIncond'] as String).positivo)
              Tx(
                'Desconto incondicionado: ${decimalBrl(form['vDescIncond'] as String)}',
                largura: TamanhosEmitir
                    .rotuloDescontoIncondicionadoDecimalBrlFormVDescIncondAsString
                    .largura,
                altura: TamanhosEmitir
                    .rotuloDescontoIncondicionadoDecimalBrlFormVDescIncondAsString
                    .altura,
                idLayout: 'TamanhosEmitir.rotuloDescontoIncondicionadoDecimalBrlFormVDescIncondAsString',
              ),
            if (Dec.ouZero(form['vDescCond'] as String).positivo)
              Tx(
                'Desconto condicionado: ${decimalBrl(form['vDescCond'] as String)}',
                largura: TamanhosEmitir
                    .rotuloDescontoCondicionadoDecimalBrlFormVDescCondAsString
                    .largura,
                altura: TamanhosEmitir
                    .rotuloDescontoCondicionadoDecimalBrlFormVDescCondAsString
                    .altura,
                idLayout: 'TamanhosEmitir.rotuloDescontoCondicionadoDecimalBrlFormVDescCondAsString',
              ),
            Tx(
              'Esta ação transmite a DPS à SEFIN e não pode ser desfeita.'
              '${producao ? '' : ' É uma emissão de teste.'}',
              largura:
                  TamanhosEmitir.rotuloEstaAcaoTransmiteADPSASEFINE.largura,
              altura: TamanhosEmitir.rotuloEstaAcaoTransmiteADPSASEFINE.altura,
              idLayout: 'TamanhosEmitir.rotuloEstaAcaoTransmiteADPSASEFINE',
            ),
          ],
          justa: true,
          idLayout: 'Grupo.emitir.col.4',
        ),
        acoes: (_) => [
          Botao.texto(
            'Cancelar',
            aoClicar: () => app.fecharEsta(d),
            largura: TamanhosEmitir.botaoCancelar2.largura,
            altura: TamanhosEmitir.botaoCancelar2.altura,
            idLayout: 'TamanhosEmitir.botaoCancelar2',
          ),
          Botao(
            producao ? 'Confirmar e emitir' : 'Confirmar e emitir ($amb)',
            icone: Icons.send,
            aoClicar: () => _emitir(form, d),
            largura: TamanhosEmitir
                .botaoProducaoConfirmarEEmitirConfirmarEEmitirAmb
                .largura,
            altura: TamanhosEmitir
                .botaoProducaoConfirmarEEmitirConfirmarEEmitirAmb
                .altura,
            idLayout: 'TamanhosEmitir.botaoProducaoConfirmarEEmitirConfirmarEEmitirAmb',
          ),
        ],
        // Fechar por Cancelar, Esc ou "X" destrava o botão Emitir do mesmo jeito.
        aoFechar: _liberar,
        idLayout: 'Janela.emitir.Dialogo.3',
      );
      app.mostrarDialogo(d);
    }

    // Emitir NFS-e exige nível 2. O aoCancelar é OBRIGATÓRIO: sem ele, cancelar a
    // autorização deixaria o botão Emitir morto.
    app.exigirPermissao('emitir.transmitir', () {
      app.exigirPermissao('emitir.tributos', () {
        if (salvarDados()) {
          confirmar();
        } else {
          _liberar();
        }
      }, aoCancelar: _liberar);
    }, aoCancelar: _liberar);
  }

  /// Devolve a tela Emitir ao estado utilizável.
  void _reabilitar() {
    _emitindo = false;
    _travaUi = false;
    _atualizar();
  }

  static final _aleatorio = math.Random();

  void _emitir(Map<String, dynamic> form, Dialogo d) {
    // Confirmou: o gancho de fechamento NÃO reabilita o botão aqui — quem devolve a tela
    // é _reabilitar, no fim da emissão.
    d.aoFechar = null;
    app.fecharEsta(d); // fecha por IDENTIDADE
    _emitindo = true;
    _travaUi = true;
    _atualizar();

    // RETRATO do contexto: a emissão leva segundos e nada impede o usuário de trocar de
    // cliente, de prestador ou de ambiente nesse meio-tempo.
    final op = [
      for (var i = 0; i < 8; i++) _aleatorio.nextInt(16).toRadixString(16),
    ].join();
    final prest = app.prestador;
    final cert = app.cert;
    final ambCod = app.ambiente;
    final tom = tomador!;
    final serv = slug!;
    final nome = xnome;
    final sub = subst == null ? null : Map<String, dynamic>.of(subst!);
    final amb = ambRotulos[ambCod] ?? '';
    registrar(
      '[$op] Emissão iniciada: prestador=$prest tomador=$tom serviço=$serv '
      'ambiente=$ambCod valor=${form['vServ']}'
      '${sub != null ? ' SUBSTITUI chave=${sub['chave']}' : ''}',
    );
    // Aviso de progresso: fica na tela até a transmissão terminar.
    final ht = app.toastProgresso(
      '${sub != null ? 'Substituindo' : 'Emitindo'} NFS-e ($amb) para $nome…',
    );
    final ctx = (
      op: op,
      prest: prest,
      amb: ambCod,
      tomador: tom,
      slug: serv,
      xnome: nome,
      subst: sub,
    );

    app.emSegundoPlano(() async {
      Map<String, dynamic> resultado;
      Map<String, dynamic> oficial;
      String numero;
      try {
        resultado = Map<String, dynamic>.from(
          await chamar<Map>('emissao.emitir', {
            'prestador': prest,
            'tomador': tom,
            'servico': serv,
            'cert': cert,
            'ambiente': ambCod,
            'extra_overrides': _extraSubst(sub) ?? const [],
          }),
        );
        oficial = Map<String, dynamic>.from(
          (resultado['official_nfse'] as Map?) ?? const {},
        );
        numero = _ou(oficial['nNFSe'], '?');
      } on ErroNucleo catch (e) {
        final dados = e.dados is Map
            ? Map<String, dynamic>.from(e.dados as Map)
            : <String, dynamic>{};
        if (e.tipo == 'TransmissionPending') {
          app.toastFim(
            ht,
            'Não foi possível transmitir agora a NFS-e de $nome ($amb).',
            erro: true,
          );
          registrar(
            '[$op] Transmissão indisponível (prestador=$prest tomador=$tom '
            'nDPS=${dados['n_dps']} chave=${_ou(dados['chave'], '-')}): $e',
            nivel: 'error',
          );
          if (((dados['chave'] as String?) ?? '').isNotEmpty) {
            _filaPosAceite(e, dados, ctx, form);
          } else {
            _mostrarFalhaTransmissao(e, dados, ctx, form);
          }
        } else if (e.tipo == 'EmissionRejected') {
          app.toastFim(
            ht,
            'NFS-e de $nome ($amb) REJEITADA pela SEFIN.',
            erro: true,
          );
          registrar(
            '[$op] Emissão rejeitada (prestador=$prest tomador=$tom '
            'HTTP ${dados['status_code']}): $e',
            nivel: 'error',
          );
          _mostrarErro('$e', null);
        } else {
          app.toastFim(
            ht,
            'Falha na emissão da NFS-e de $nome ($amb).',
            erro: true,
          );
          registrar(
            '[$op] Falha na emissão (prestador=$prest tomador=$tom): $e',
            nivel: 'error',
          );
          _mostrarErro(
            '$e',
            dados['log_path'] as String?,
            numeroEmitida: dados['current_nfse_number']?.toString(),
          );
        }
        _reabilitar();
        return;
      } catch (e, pilha) {
        app.toastFim(
          ht,
          'Falha na emissão da NFS-e de $nome ($amb).',
          erro: true,
        );
        registrar(
          '[$op] Erro inesperado na emissão (prestador=$prest tomador=$tom): $e\n$pilha',
          nivel: 'error',
        );
        _mostrarErro('$e', null, detalhes: '$pilha');
        _reabilitar();
        return;
      }

      // ------------------------------------------------------------------ //
      // A NOTA FOI EMITIDA. Daqui pra frente NADA pode dizer "falha na emissão": cada
      // passo tem o SEU tratamento e nenhum derruba o veredicto.
      // ------------------------------------------------------------------ //
      _reabilitar(); // libera a tela JÁ, sem esperar e-mail
      final chaveNova = _ou(oficial['chaveAcesso'], '');
      registrar(
        '[$op] NFS-e emitida: nº $numero chave ${chaveNova.isEmpty ? '?' : chaveNova} '
        '(prestador=$prest tomador=$tom serviço=$serv)',
      );
      if (sub != null) {
        try {
          ja<Object?>('emissao.marcar_substituida', {
            'prestador': prest,
            'chave_antiga': sub['chave'],
            'chave_nova': chaveNova,
          });
          registrar(
            '[$op] NFS-e nº ${sub['nNFSe']} SUBSTITUÍDA pela chave '
            '${chaveNova.isEmpty ? '?' : chaveNova}',
          );
        } catch (e) {
          registrar(
            '[$op] Falha ao marcar a NFS-e antiga como substituída: $e',
            nivel: 'error',
          );
        }
        _limparSubstSeFor(sub['chave'] as String);
      }
      app.toastFim(
        ht,
        'NFS-e nº $numero ($amb) emitida para $nome.'
        '${sub != null ? ' A nº ${sub['nNFSe']} foi substituída.' : ''}',
      );
      app.notasMudaram(); // nova nota: Consulta e Cofre recarregam ao abrir
      // Primeira NFS-e em produção: a janela de doação com fogos, uma vez só, depois de fechar o
      // resultado (nunca no meio da emissão).
      final lembrarDoacao = doacaoAposEmissao(producao: ambCod == '1');
      try {
        _mostrarResultado(
          resultado,
          aoFechar: lembrarDoacao
              ? () => Future.delayed(
                  const Duration(milliseconds: 400),
                  () => abrirDoacao(app, primeira: true),
                )
              : null,
        );
      } catch (e) {
        registrar(
          '[$op] NFS-e nº $numero EMITIDA — falhou só a exibição do resultado: $e',
          nivel: 'error',
        );
      }
      // E-mail automático FORA do caminho crítico da emissão.
      try {
        final cfg = jaMapa('correio.get_settings', {'prestador': prest});
        if (!emailAutoPara(cfg, ambCod)) return;
      } catch (e) {
        registrar(
          '[$op] Não foi possível ler a configuração de e-mail: $e',
          nivel: 'error',
        );
        return;
      }
      enviarNfseEmail(
        app,
        prest: prest,
        aposEmissao: true,
        tomador: tom,
        chave: chaveNova,
        ambiente: ambCod,
        rotulo: 'NFS-e nº $numero ($amb)',
      );
    });
  }

  Map<String, Object?>? _substDaFila(Map<String, dynamic>? sub) => sub == null
      ? null
      : {
          'chave': sub['chave'],
          'nNFSe': sub['nNFSe'],
          'cMotivo': sub['cMotivo'],
          'xMotivo': sub['xMotivo'],
          'tomador': sub['tomador'],
        };

  void _enfileirar(
    Map<String, dynamic> dados,
    _Contexto ctx,
    Map<String, dynamic> form,
  ) {
    ja<Object?>('emissao.enqueue_pendente', {
      'prestador': ctx.prest,
      'tomador': ctx.tomador,
      'servico': ctx.slug,
      'tomador_nome': ctx.xnome,
      'valor': form['vServ'],
      'exc': dados,
      'subst': _substDaFila(ctx.subst),
    });
  }

  /// Nota ACEITA pela SEFIN mas sem o XML baixado: não há escolha a fazer (o número já foi
  /// consumido) — entra direto na fila, que conclui o download sozinha.
  void _filaPosAceite(
    ErroNucleo ex,
    Map<String, dynamic> dados,
    _Contexto ctx,
    Map<String, dynamic> form,
  ) {
    final sub = ctx.subst;
    final chave = dados['chave'] as String;
    try {
      _enfileirar(dados, ctx, form);
    } catch (e2) {
      _mostrarErro(
        'A NFS-e FOI ACEITA pela SEFIN (chave $chave), mas o XML não baixou e a '
        'fila falhou: $e2. Use o Recarregar da Consulta mais tarde.',
        dados['log_path'] as String?,
        numeroEmitida: '${dados['n_dps']}',
      );
      return;
    }
    if (sub != null) {
      // A nota nova FOI aceita (chave existe): a antiga já pode ser marcada.
      try {
        ja<Object?>('emissao.marcar_substituida', {
          'prestador': ctx.prest,
          'chave_antiga': sub['chave'],
          'chave_nova': chave,
        });
      } catch (e) {
        registrar(
          '[${ctx.op}] Falha ao marcar a NFS-e antiga como substituída: $e',
          nivel: 'error',
        );
      }
      _limparSubstSeFor(sub['chave'] as String);
    }
    registrar(
      '[${ctx.op}] NFS-e aceita sem XML baixado -> fila (nDPS=${dados['n_dps']} '
      'chave=$chave prestador=${ctx.prest})',
    );
    app.toast(
      'NFS-e ACEITA pela SEFIN, mas o XML ainda não baixou — ficou na fila '
      'para concluir o download automaticamente.',
      erro: true,
    );
    app.refazerAvisoFila?.call();
    if (app.prestador == ctx.prest && app.navAtual == 2)
      app.recarregarConsulta?.call();
  }

  /// Falha de TRANSMISSÃO (não de negócio): oferece descartar o envio ou guardar a DPS na
  /// fila de contingência. DECISÃO OBRIGATÓRIA: Esc não fecha.
  void _mostrarFalhaTransmissao(
    ErroNucleo ex,
    Map<String, dynamic> dados,
    _Contexto ctx,
    Map<String, dynamic> form,
  ) {
    final sub = ctx.subst;
    final nDps = dados['n_dps'];
    final serie = dados['serie'];
    late final Dialogo d;

    void descartar() {
      app.fecharEsta(d);
      // Guarda a DPS assinada fora da fila: é o único insumo para resgate se a SEFIN tiver
      // processado o envio sem responder.
      try {
        ja<Object?>('emissao.arquivar_dps_descartada', {
          'prestador': ctx.prest,
          'exc': dados,
          'tomador': ctx.tomador,
          'tomador_nome': ctx.xnome,
        });
      } catch (e) {
        registrar(
          '[${ctx.op}] Falha ao arquivar a DPS descartada: $e',
          nivel: 'error',
        );
      }
      registrar(
        '[${ctx.op}] Envio descartado pelo usuário (nDPS=$nDps série=$serie '
        'prestador=${ctx.prest})',
      );
      app.toast(
        'Envio descartado. Se a SEFIN tiver processado esta DPS, o número '
        '$nDps já está consumido lá.',
        erro: true,
      );
    }

    void fila() {
      try {
        _enfileirar(dados, ctx, form);
      } catch (e2) {
        app.toast('Não foi possível adicionar à fila: $e2', erro: true);
        return;
      }
      registrar(
        '[${ctx.op}] DPS nº $nDps (série $serie) adicionada à FILA '
        '(prestador=${ctx.prest} tomador=${ctx.tomador})',
      );
      app.fecharEsta(d);
      // A substituição agora vive no registro do pendente: quando o reenvio for aceito, a
      // nota antiga é marcada automaticamente.
      if (sub != null) _limparSubstSeFor(sub['chave'] as String);
      app.toast(
        'DPS nº $nDps adicionada à fila — reenvio automático a cada 5 min.',
      );
      app.refazerAvisoFila?.call();
      if (app.prestador == ctx.prest && app.navAtual == 2)
        app.recarregarConsulta?.call();
    }

    d = Dialogo(
      marcador: '_modal_obrigatorio_',
      titulo: (_) => LinhaTitulo([
        Icon(Icons.wifi_off, color: Colors.orange.shade800),
        textoTitulo('Não foi possível transmitir'),
      ], espaco: 10),
      largura: 560,
      conteudo: (_) => col(
        [
          Tx(
            'Motivo: $ex',
            selecionavel: true,
            largura: TamanhosEmitir.rotuloMotivoEx.largura,
            altura: TamanhosEmitir.rotuloMotivoEx.altura,
            idLayout: 'TamanhosEmitir.rotuloMotivoEx',
          ),
          Tx(
            'A DPS nº $nDps (série $serie) já está pronta e assinada. '
            'O que deseja fazer?',
            largura: TamanhosEmitir.rotuloADPSNoNDpsSerieSerieJaEsta.largura,
            altura: TamanhosEmitir.rotuloADPSNoNDpsSerieSerieJaEsta.altura,
            idLayout: 'TamanhosEmitir.rotuloADPSNoNDpsSerieSerieJaEsta',
          ),
          Tx(
            '• Adicionar à fila: o número fica RESERVADO, a nota aparece na '
            'Consulta como PENDENTE (linha laranja) e o envio é retentado '
            'automaticamente a cada 5 minutos — ou na hora, pelo botão Reenviar.',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura: TamanhosEmitir
                .rotuloAdicionarAFilaONumeroFicaRESERVADOA
                .largura,
            altura:
                TamanhosEmitir.rotuloAdicionarAFilaONumeroFicaRESERVADOA.altura,
            idLayout:
                'TamanhosEmitir.rotuloAdicionarAFilaONumeroFicaRESERVADOA',
          ),
          Tx(
            '• Descartar: nada é gravado aqui. Como a SEFIN não respondeu, NÃO '
            'há como saber se ela chegou a processar esta DPS; se tiver '
            'processado, a próxima emissão com o nº $nDps será rejeitada '
            '(E0014).',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura: TamanhosEmitir
                .rotuloDescartarNadaEGravadoAquiComoASEFIN
                .largura,
            altura:
                TamanhosEmitir.rotuloDescartarNadaEGravadoAquiComoASEFIN.altura,
            idLayout:
                'TamanhosEmitir.rotuloDescartarNadaEGravadoAquiComoASEFIN',
          ),
        ],
        justa: true,
        idLayout: 'Grupo.emitir.col.5',
      ),
      acoes: (_) => [
        Botao.contorno(
          'Descartar envio',
          aoClicar: descartar,
          largura: TamanhosEmitir.botaoDescartarEnvio.largura,
          altura: TamanhosEmitir.botaoDescartarEnvio.altura,
          idLayout: 'TamanhosEmitir.botaoDescartarEnvio',
        ),
        Botao(
          'Adicionar à fila',
          icone: Icons.schedule_send,
          aoClicar: fila,
          largura: TamanhosEmitir.botaoAdicionarAFila.largura,
          altura: TamanhosEmitir.botaoAdicionarAFila.altura,
          idLayout: 'TamanhosEmitir.botaoAdicionarAFila',
        ),
      ],
      idLayout: 'Janela.emitir.Dialogo.4',
    );
    app.mostrarDialogo(d);
  }

  Widget _avisoLaranja(Widget conteudo) => Ct(
    cor: Colors.orange.shade50,
    raio: BorderRadius.circular(6),
    borda: Border.all(color: Colors.orange.shade300, width: 1),
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
    child: conteudo,
  );

  void _mostrarResultado(
    Map<String, dynamic> resultado, {
    VoidCallback? aoFechar,
  }) {
    final oficial = Map<String, dynamic>.from(
      (resultado['official_nfse'] as Map?) ?? const {},
    );
    final danfse = Map<String, dynamic>.from(
      (resultado['danfse'] as Map?) ?? const {},
    );
    final numero = _ou(oficial['nNFSe'], '?');
    final chave = _ou(oficial['chaveAcesso'], '?');
    final email = resultado['email'] is Map
        ? Map<String, dynamic>.from(resultado['email'] as Map)
        : null;
    // Só o OK: abrir XML/DANFSe e reenviar e-mail ficam na Consulta. Esc, ENTER e o "X" do
    // título também fecham.
    app.mostrarDialogo(
      Dialogo(
        marcador: '_enter_fecha_',
        aoFechar: aoFechar,
        titulo: (_) => app.tituloComX('Emissão concluída'),
        largura: 520,
        conteudo: (_) => col(
          [
            lin([
              Icon(Icons.check_circle, color: Colors.green.shade600),
              Tx(
                'NFS-e nº $numero emitida!',
                tam: Letra.subtitulo,
                peso: FontWeight.bold,
                largura: TamanhosEmitir.rotuloNFSENoNumeroEmitida.largura,
                altura: TamanhosEmitir.rotuloNFSENoNumeroEmitida.altura,
                idLayout: 'TamanhosEmitir.rotuloNFSENoNumeroEmitida',
              ),
            ], idLayout: 'Grupo.emitir.lin.1'),
            Tx(
              'Chave de acesso:\n$chave',
              selecionavel: true,
              largura: TamanhosEmitir.rotuloChaveDeAcessoNChave.largura,
              altura: TamanhosEmitir.rotuloChaveDeAcessoNChave.altura,
              idLayout: 'TamanhosEmitir.rotuloChaveDeAcessoNChave',
            ),
            if (resultado['recuperada_e0014'] == true)
              // A nota NÃO foi gerada agora: a SEFIN respondeu que a DPS já tinha sido
              // processada e a chave veio da consulta. Nunca silencioso.
              _avisoLaranja(
                Tx(
                  'Esta NFS-e JÁ EXISTIA na SEFIN com o nº $numero (envio anterior). Os '
                  'dados acima vieram do XML oficial, não do que você acabou de montar — '
                  'CONFIRA o valor e o serviço.',
                  cor: Colors.orange.shade900,
                  peso: FontWeight.w600,
                  tam: Letra.apoio,
                  largura:
                      TamanhosEmitir.rotuloEstaNFSEJAEXISTIANaSEFINCom.largura,
                  altura:
                      TamanhosEmitir.rotuloEstaNFSEJAEXISTIANaSEFINCom.altura,
                  idLayout: 'TamanhosEmitir.rotuloEstaNFSEJAEXISTIANaSEFINCom',
                ),
              ),
            if (danfse.isNotEmpty && danfse['generated'] != true)
              _avisoLaranja(
                col(
                  [
                    Tx(
                      danfseIndisponivel,
                      tam: Letra.apoio,
                      cor: Colors.orange.shade900,
                      largura: TamanhosEmitir.rotuloDanfseIndisponivel.largura,
                      altura: TamanhosEmitir.rotuloDanfseIndisponivel.altura,
                      idLayout: 'TamanhosEmitir.rotuloDanfseIndisponivel',
                    ),
                    lin(
                      [
                        Botao.texto(
                          'Abrir Consulta Pública',
                          icone: Icons.open_in_new,
                          aoClicar: () => abrirUrl(
                            app,
                            ja<String>('consulta.url_nfse', {
                              'ambiente': '${oficial['tipoAmbiente'] ?? ''}',
                            }),
                          ),
                          largura:
                              TamanhosEmitir.botaoAbrirConsultaPublica.largura,
                          altura:
                              TamanhosEmitir.botaoAbrirConsultaPublica.altura,
                          idLayout: 'TamanhosEmitir.botaoAbrirConsultaPublica',
                        ),
                        Botao.texto(
                          'Copiar chave',
                          icone: Icons.content_copy,
                          aoClicar: () => copiar(app, chave),
                          largura: TamanhosEmitir.botaoCopiarChave.largura,
                          altura: TamanhosEmitir.botaoCopiarChave.altura,
                          idLayout: 'TamanhosEmitir.botaoCopiarChave',
                        ),
                      ],
                      espaco: 4,
                      justa: true,
                      idLayout: 'Grupo.emitir.lin.2',
                    ),
                  ],
                  justa: true,
                  espaco: 6,
                  idLayout: 'Grupo.emitir.col.7',
                ),
              ),
            if (email != null)
              email['sent'] == true
                  ? Tx(
                      'E-mail enviado para ${email['to']}.',
                      cor: Colors.green.shade700,
                      tam: Letra.apoio,
                      largura:
                          TamanhosEmitir.rotuloEMailEnviadoParaEmailTo.largura,
                      altura:
                          TamanhosEmitir.rotuloEMailEnviadoParaEmailTo.altura,
                      idLayout: 'TamanhosEmitir.rotuloEMailEnviadoParaEmailTo',
                    )
                  : Tx(
                      'E-mail automático não foi enviado: '
                      '${email['error'] ?? 'erro desconhecido'}',
                      cor: Colors.orange.shade800,
                      tam: Letra.apoio,
                      largura: TamanhosEmitir
                          .rotuloEMailAutomaticoNaoFoiEnviadoEmailError
                          .largura,
                      altura: TamanhosEmitir
                          .rotuloEMailAutomaticoNaoFoiEnviadoEmailError
                          .altura,
                      idLayout: 'TamanhosEmitir.rotuloEMailAutomaticoNaoFoiEnviadoEmailError',
                    ),
          ],
          justa: true,
          idLayout: 'Grupo.emitir.col.6',
        ),
        acoes: (_) => [
          Botao(
            'OK',
            aoClicar: app.fecharDialogo,
            largura: TamanhosEmitir.botaoOK.largura,
            altura: TamanhosEmitir.botaoOK.altura,
            idLayout: 'TamanhosEmitir.botaoOK',
          ),
        ],
        idLayout: 'Janela.emitir.Dialogo.5',
      ),
    );
  }

  void _mostrarErro(
    String mensagem,
    String? caminhoLog, {
    String? detalhes,
    String? numeroEmitida,
  }) {
    final emitida = (numeroEmitida ?? '').isNotEmpty;
    // Número preenchido = a SEFIN ACEITOU a nota; só o pós-aceite falhou. O título tem de
    // gritar que NÃO é para reemitir.
    final titulo = lin(
      emitida
          ? [
              Icon(Icons.warning_amber, color: Colors.orange.shade800),
              textoTitulo('NFS-e nº $numeroEmitida EMITIDA — não reemita'),
            ]
          : [
              Icon(Icons.error, color: Colors.red.shade600),
              textoTitulo('Falha na emissão'),
            ],
      espaco: 8,
      justa: true,
      idLayout: 'Grupo.emitir.lin.3',
    );
    app.mostrarDialogo(
      Dialogo(
        titulo: (_) => app.tituloComX(titulo),
        largura: 560,
        conteudo: (_) => col(
          [
            if (emitida)
              _avisoLaranja(
                Tx(
                  'A nota nº $numeroEmitida EXISTE na SEFIN e o número já foi '
                  'consumido. Emitir de novo geraria uma NOTA DUPLICADA. '
                  'Confira na Consulta ou no portal nacional.',
                  cor: Colors.orange.shade900,
                  peso: FontWeight.w600,
                  tam: Letra.apoio,
                  largura: TamanhosEmitir
                      .rotuloANotaNoNumeroEmitidaEXISTENaSEFINE
                      .largura,
                  altura: TamanhosEmitir
                      .rotuloANotaNoNumeroEmitidaEXISTENaSEFINE
                      .altura,
                  idLayout:
                      'TamanhosEmitir.rotuloANotaNoNumeroEmitidaEXISTENaSEFINE',
                ),
              ),
            Tx(
              mensagem,
              selecionavel: true,
              largura: TamanhosEmitir.rotuloMensagem.largura,
              altura: TamanhosEmitir.rotuloMensagem.altura,
              idLayout: 'TamanhosEmitir.rotuloMensagem',
            ),
            if ((detalhes ?? '').isNotEmpty)
              ExpansionTile(
                maintainState: false,
                initiallyExpanded: false,
                enableFeedback: true,
                showTrailingIcon: true,
                title: Tx(
                  'Detalhes técnicos',
                  largura: TamanhosEmitir.rotuloDetalhesTecnicos.largura,
                  altura: TamanhosEmitir.rotuloDetalhesTecnicos.altura,
                  idLayout: 'TamanhosEmitir.rotuloDetalhesTecnicos',
                ),
                children: [
                  Ct(
                    padding: const EdgeInsets.all(10),
                    child: Tx(
                      detalhes!,
                      selecionavel: true,
                      tam: Letra.apoio,
                      largura: TamanhosEmitir.rotuloDetalhes.largura,
                      altura: TamanhosEmitir.rotuloDetalhes.altura,
                      idLayout: 'TamanhosEmitir.rotuloDetalhes',
                    ),
                  ),
                ],
              ),
          ],
          justa: true,
          idLayout: 'Grupo.emitir.col.8',
        ),
        acoes: (_) => [
          if ((caminhoLog ?? '').isNotEmpty)
            Botao.texto(
              'Abrir log',
              icone: Icons.article,
              aoClicar: () => abrirCaminho(app, caminhoLog!),
              largura: TamanhosEmitir.botaoAbrirLog.largura,
              altura: TamanhosEmitir.botaoAbrirLog.altura,
              idLayout: 'TamanhosEmitir.botaoAbrirLog',
            ),
        ],
        idLayout: 'Janela.emitir.Dialogo.6',
      ),
    );
  }

  // ---- desenho ---------------------------------------------------------------------------- //
  static const _rotuloC = TextStyle(fontSize: Letra.texto);

  /// Campo "compacto" da expansão: letra menor nos rótulos/valores + denso.
  Widget _campoC(
    TextEditingController c,
    String rotulo,
    Tamanho tamanho, {
    bool travado = false,
    bool leitura = false,
    bool pct = false,
    bool maiusculas = false,
    bool recalcula = false,
    String? rotuloNaBorda,
  }) => CampoTexto(
    controle: c,
    rotulo: rotulo,
    rotuloNaBorda: rotuloNaBorda,
    largura: tamanho.largura!,
    altura: tamanho.altura,
    tamanhoTexto: Letra.campo,
    estiloRotulo: _rotuloC,
    denso: true,
    desabilitado: travado,
    somenteLeitura: leitura,
    textoSufixo: pct ? const Text('%') : null,
    mascara: pct ? pctVirgula : (maiusculas ? (s) => s.toUpperCase() : null),
    aoMudar: recalcula ? (_) => _recalcular() : null,
    idLayout: tamanho.id,
  );

  Widget _listaC(
    Suspensa s,
    String rotulo,
    Tamanho tamanho, {
    bool travado = false,
    double? larguraMenu,
    ValueChanged<String?>? aoSelecionar,
  }) => ListaSuspensa(
    estado: s,
    rotulo: rotulo,
    largura: tamanho.largura!,
    altura: tamanho.altura,
    editavel: true,
    filtrar: true,
    substituirAoFocar: true,
    desabilitado: travado,
    tamanhoTexto: Letra.campo,
    estiloRotulo: _rotuloC,
    denso: true,
    larguraMenu: larguraMenu,
    aoSelecionar: aoSelecionar,
    idLayout: tamanho.id,
  );

  Widget _secao(String t) => Tx(
    t,
    tam: Letra.texto,
    peso: FontWeight.bold,
    largura: TamanhosEmitir.rotuloT.largura,
    altura: TamanhosEmitir.rotuloT.altura,
    idLayout: 'TamanhosEmitir.rotuloT:$t',
  );

  Widget _maisCampos() {
    final t = _tribTravado;
    final semCalc = (ddCst.valor ?? '01') == '00';
    final naoRetido = (ddRet.valor ?? '0') == '0';
    // SUBSTITUIÇÃO: a SEFIN não deixa mudar o código de tributação nem o local da prestação
    // — mesmo com a expansão liberada, esses campos ficam travados.
    final imutavel = subst != null && _imutaveis().isNotEmpty;
    Widget catalogo(Catalogo c, String rotulo) => _listaC(
      c.dd,
      rotulo,
      TamanhosTributosEmissao.campoRotulo,
      travado: t || (imutavel && c == cTribNac),
      larguraMenu: larguraMenuCatalogo,
      aoSelecionar: (v) {
        c.por(v ?? '');
        c.dd.avisar();
      },
    );
    return ExpansionTile(
      key: _chaveExpansao,
      maintainState: true,
      initiallyExpanded: _tribAberto,
      tilePadding: EdgeInsets.zero,
      backgroundColor: const Color(0x0A6750A4),
      collapsedBackgroundColor: const Color(0x0A6750A4),
      shape: const Border(),
      collapsedShape: const Border(),
      enableFeedback: true,
      showTrailingIcon: true,
      enabled: !travado(context),
      title: Tx(
        'Mais campos do serviço / tributação',
        tam: Letra.texto,
        largura:
            TamanhosTributosEmissao.rotuloMaisCamposDoServicoTributacao.largura,
        altura:
            TamanhosTributosEmissao.rotuloMaisCamposDoServicoTributacao.altura,
        idLayout: 'TamanhosTributosEmissao.rotuloMaisCamposDoServicoTributacao',
      ),
      onExpansionChanged: (aberto) {
        _tribAberto = aberto;
        if (!aberto && !_tribTravado) {
          _descartarTributos();
        } else {
          _recalcular();
        }
      },
      children: [
        Ct(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
          child: col(
            [
              _secao('Serviço'),
              lin(
                [
                  catalogo(cTribNac, 'Código de Tributação Nacional'),
                  catalogo(cNbs, 'Item da NBS'),
                  _campoC(
                    cLoc,
                    'Local de prestação (cMun)',
                    TamanhosTributosEmissao.campoLocalDePrestacaoCMun,
                    travado: t || imutavel,
                  ),
                  _campoC(
                    cTribMun,
                    'Cód. Tribut. Mun. (cTribMun)',
                    TamanhosTributosEmissao.campoCTribMun,
                    travado: t || imutavel,
                    rotuloNaBorda: 'Trib. Mun. (cTribMun)',
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.4',
              ),
              divisor(),
              _secao('Situação tributária'),
              lin(
                [
                  _listaC(
                    ddCst,
                    'Situação Tributária do PIS/COFINS (CST)',
                    TamanhosTributosEmissao
                        .campoSituacaoTributariaDoPISCOFINSCST,
                    travado: t,
                    aoSelecionar: (_) => _recalcular(),
                  ),
                  _listaC(
                    ddRet,
                    'Tipo de retenção do PIS/COFINS/CSLL',
                    TamanhosTributosEmissao.campoTipoDeRetencaoDoPISCOFINSCSLL,
                    travado: t,
                    aoSelecionar: (_) => _recalcular(),
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.5',
              ),
              lin(
                [
                  _listaC(
                    ddIss,
                    'Tributação do ISSQN',
                    TamanhosTributosEmissao.campoTributacaoDoISSQN,
                    travado: t,
                  ),
                  _listaC(
                    ddRetIss,
                    'Retenção do ISSQN',
                    TamanhosTributosEmissao.campoRetencaoDoISSQN,
                    travado: t,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.6',
              ),
              divisor(),
              _secao('IBS/CBS'),
              lin(
                [
                  _listaC(
                    rtcIndDest,
                    'Destinatário é o próprio adquirente?',
                    TamanhosTributosEmissao
                        .campoDestinatarioEOProprioAdquirente,
                    travado: t,
                    aoSelecionar: (_) => _atualizar(),
                  ),
                  _listaC(
                    rtcIndOp,
                    'Indicador da operação (cIndOp)',
                    TamanhosTributosEmissao.campoIndicadorDaOperacaoCIndOp,
                    travado: t,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.7',
              ),
              if (rtcIndDest.valor == '1')
                col(
                  [
                    lin(
                      [
                        _listaC(
                          destTipo,
                          'Documento do destinatário',
                          TamanhosTributosEmissao.campoDocumentoDoDestinatario,
                          travado: t,
                        ),
                        _campoC(
                          destDoc,
                          'Número do documento',
                          TamanhosTributosEmissao.campoNumeroDoDocumento,
                          travado: t,
                        ),
                        _campoC(
                          destNome,
                          'Nome do destinatário',
                          TamanhosTributosEmissao.campoNomeDoDestinatario,
                          travado: t,
                          maiusculas: true,
                        ),
                      ],
                      quebra: true,
                      idLayout: 'Grupo.emitir.lin.8',
                    ),
                    lin(
                      [
                        _campoC(
                          destMun,
                          'Município (IBGE)',
                          TamanhosTributosEmissao.campoMunicipioIBGE,
                          travado: t,
                        ),
                        _campoC(
                          destCep,
                          'CEP',
                          TamanhosTributosEmissao.campoCEP,
                          travado: t,
                        ),
                        _campoC(
                          destLgr,
                          'Logradouro',
                          TamanhosTributosEmissao.campoLogradouro,
                          travado: t,
                          maiusculas: true,
                        ),
                        _campoC(
                          destNro,
                          'Número',
                          TamanhosTributosEmissao.campoNumero,
                          travado: t,
                        ),
                        _campoC(
                          destCpl,
                          'Complemento',
                          TamanhosTributosEmissao.campoComplemento,
                          travado: t,
                          maiusculas: true,
                        ),
                        _campoC(
                          destBairro,
                          'Bairro',
                          TamanhosTributosEmissao.campoBairro,
                          travado: t,
                          maiusculas: true,
                        ),
                      ],
                      quebra: true,
                      idLayout: 'Grupo.emitir.lin.9',
                    ),
                  ],
                  espaco: Medida.espacoEntreCampos,
                  justa: true,
                  idLayout: 'Grupo.emitir.col.10',
                ),
              lin(
                [
                  _listaC(
                    rtcCst,
                    'Situação tributária IBS/CBS (CST)',
                    TamanhosTributosEmissao.campoSituacaoTributariaIBSCBSCST,
                    travado: t,
                    aoSelecionar: (v) {
                      _classes(v ?? '');
                      _atualizar();
                    },
                  ),
                  _listaC(
                    rtcClasse,
                    'Classificação tributária IBS/CBS',
                    TamanhosTributosEmissao.campoClassificacaoTributariaIBSCBS,
                    travado: t,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.10',
              ),
              divisor(),
              _secao('Cálculo próprio de PIS/COFINS'),
              lin(
                [
                  _campoC(
                    pPis,
                    'PIS',
                    TamanhosTributosEmissao.campoPIS,
                    travado: t || semCalc,
                    pct: true,
                    recalcula: true,
                  ),
                  _campoC(
                    pCofins,
                    'COFINS',
                    TamanhosTributosEmissao.campoCOFINS,
                    travado: t || semCalc,
                    pct: true,
                    recalcula: true,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.11',
              ),
              lin(
                [
                  _campoC(
                    lBase,
                    'Base (R\$)',
                    TamanhosTributosEmissao.campoBaseR,
                    travado: true,
                    leitura: true,
                  ),
                  _campoC(
                    lPis,
                    'PIS (R\$)',
                    TamanhosTributosEmissao.campoPISR,
                    travado: true,
                    leitura: true,
                  ),
                  _campoC(
                    lCofins,
                    'COFINS (R\$)',
                    TamanhosTributosEmissao.campoCOFINSR,
                    travado: true,
                    leitura: true,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.12',
              ),
              divisor(),
              _secao('Retenções (IRRF / Contribuições Sociais)'),
              lin(
                [
                  _campoC(
                    pIrrf,
                    'IRRF',
                    TamanhosTributosEmissao.campoIRRF,
                    travado: t || naoRetido,
                    pct: true,
                    recalcula: true,
                  ),
                  _campoC(
                    pCsll,
                    'CSLL',
                    TamanhosTributosEmissao.campoCSLL,
                    travado: t || naoRetido,
                    pct: true,
                    recalcula: true,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.13',
              ),
              // A margem negativa alinha o quadradinho com a borda do campo IRRF.
              PuxarEsquerda(
                recuo: 10,
                child: Marcar(
                  idLayout: 'Checkbox.emitir.1',
                  valor: cbContrib,
                  rotulo: 'Incluir contribuições sociais (PIS + COFINS + CSLL)',
                  estiloRotulo: _rotuloC,
                  sobreposicao: Colors.transparent,
                  raioRespingo: 0,
                  desabilitado: t || naoRetido || semCalc,
                  dica: _dicaContrib,
                  aoMudar: (v) {
                    cbContrib = v ?? false;
                    _recalcular();
                  },
                ),
              ),
              lin(
                [
                  _campoC(
                    lIrrf,
                    'IRRF (R\$)',
                    TamanhosTributosEmissao.campoIRRFR,
                    travado: true,
                    leitura: true,
                  ),
                  _campoC(
                    lCsll,
                    'CSLL (R\$)',
                    TamanhosTributosEmissao.campoCSLLR,
                    travado: true,
                    leitura: true,
                  ),
                  _campoC(
                    lContrib,
                    'Contribuições Sociais Retidas (R\$)',
                    TamanhosTributosEmissao.campoContribuicoesSociaisRetidasR,
                    travado: true,
                    leitura: true,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.14',
              ),
              divisor(),
              _secao('Totais aproximados dos tributos (Lei 12.741)'),
              lin(
                [
                  _campoC(
                    pFed,
                    'Federal',
                    TamanhosTributosEmissao.campoFederal,
                    travado: t,
                    pct: true,
                    recalcula: true,
                  ),
                  _campoC(
                    pEst,
                    'Estadual',
                    TamanhosTributosEmissao.campoEstadual,
                    travado: t,
                    pct: true,
                    recalcula: true,
                  ),
                  _campoC(
                    pMun,
                    'Municipal',
                    TamanhosTributosEmissao.campoMunicipal,
                    travado: t,
                    pct: true,
                    recalcula: true,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.15',
              ),
              lin(
                [
                  _campoC(
                    lFed,
                    'Federal (R\$)',
                    TamanhosTributosEmissao.campoFederalR,
                    travado: true,
                    leitura: true,
                  ),
                  _campoC(
                    lEst,
                    'Estadual (R\$)',
                    TamanhosTributosEmissao.campoEstadualR,
                    travado: true,
                    leitura: true,
                  ),
                  _campoC(
                    lMun,
                    'Municipal (R\$)',
                    TamanhosTributosEmissao.campoMunicipalR,
                    travado: true,
                    leitura: true,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.emitir.lin.16',
              ),
              Tx(
                'Endereço e identificação do cliente são editados na aba Clientes.',
                tam: Letra.apoio,
                cor: Colors.grey.shade600,
                largura: TamanhosTributosEmissao
                    .rotuloEnderecoEIdentificacaoDoClienteSaoEditadosNa
                    .largura,
                altura: TamanhosTributosEmissao
                    .rotuloEnderecoEIdentificacaoDoClienteSaoEditadosNa
                    .altura,
                idLayout: 'TamanhosTributosEmissao.rotuloEnderecoEIdentificacaoDoClienteSaoEditadosNa',
              ),
            ],
            espaco: Medida.espacoEntreCampos,
            justa: true,
            idLayout: 'Grupo.emitir.col.9',
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dados = Ct(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 0),
      child: col(
        [
          Tx(
            'Dados da emissão',
            tam: Letra.subtitulo,
            peso: FontWeight.bold,
            largura: TamanhosEmitir.rotuloDadosDaEmissao.largura,
            altura: TamanhosEmitir.rotuloDadosDaEmissao.altura,
            idLayout: 'TamanhosEmitir.rotuloDadosDaEmissao',
          ),
          lin([
            Expanded(
              child: CampoTexto(
                controle: xDesc,
                rotulo: 'Descrição do serviço',
                variasLinhas: true,
                minLinhas: 6,
                maxLinhas: 16,
                expandir: true,
                // Só entra o que a NFS-e aceita (aspas curvas, travessão e reticências de
                // texto colado viram os simples; emoji e símbolos fora do Latin-1 saem).
                mascara: (s) =>
                    ja<String>('texto.limpar_descricao', {'valor': s}),
                largura: TamanhosEmitir.campoDescricaoDoServico.largura,
                altura: TamanhosEmitir.campoDescricaoDoServico.altura,
                idLayout: 'TamanhosEmitir.campoDescricaoDoServico',
              ),
            ),
          ], idLayout: 'Grupo.emitir.lin.17'),
          lin(
            [
              CampoTexto(
                controle: vServ,
                rotulo: 'Valor do serviço',
                largura: TamanhosEmitir.campoValorDoServico.largura,
                dica: 'R\$ 0,00',
                mascara: brlDigitos,
                desabilitado: _condominio,
                aoMudar: (_) => _recalcular(),
                altura: TamanhosEmitir.campoValorDoServico.altura,
                idLayout: 'TamanhosEmitir.campoValorDoServico',
              ),
              comDica(
                'Concedido sem condição (consta da nota): reduz a base de cálculo dos tributos.',
                CampoTexto(
                  controle: vDescInc,
                  rotulo: 'Desconto incondicionado',
                  rotuloNaBorda: 'Desconto incondic.',
                  largura: TamanhosEmitir.campoDescontoIncondicionado.largura,
                  dica: 'R\$ 0,00',
                  mascara: brlDigitos,
                  desabilitado: _condominio,
                  aoMudar: (_) => _recalcular(),
                  altura: TamanhosEmitir.campoDescontoIncondicionado.altura,
                  idLayout: 'TamanhosEmitir.campoDescontoIncondicionado',
                ),
              ),
              comDica(
                'Depende de um evento futuro (ex.: pagar em dia): não reduz a base, só o valor líquido.',
                CampoTexto(
                  controle: vDescCond,
                  rotulo: 'Desconto condicionado',
                  rotuloNaBorda: 'Desconto condic.',
                  largura: TamanhosEmitir.campoDescontoCondicionado.largura,
                  dica: 'R\$ 0,00',
                  mascara: brlDigitos,
                  desabilitado: _condominio,
                  altura: TamanhosEmitir.campoDescontoCondicionado.altura,
                  idLayout: 'TamanhosEmitir.campoDescontoCondicionado',
                ),
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.emitir.lin.18',
          ),
          if (_condominio)
            Tx(
              'Condomínio: o valor e os descontos são a soma das cobranças e dos descontos lançados '
              'no cadastro do cliente (Clientes › Serviço & Tributação).',
              tam: Letra.apoio,
              cor: Colors.grey.shade700,
              largura:
                  TamanhosEmitir.rotuloCondominioOValorEOsDescontosSaoA.largura,
              altura:
                  TamanhosEmitir.rotuloCondominioOValorEOsDescontosSaoA.altura,
              idLayout: 'TamanhosEmitir.rotuloCondominioOValorEOsDescontosSaoA',
            ),
          // Só há o que escolher quando a nota tem desconto incondicionado.
          if (_temDescontoIncondicionado)
            PuxarEsquerda(
              recuo: 10,
              child: Marcar(
                idLayout: 'Checkbox.emitir.2',
                valor: cbRetAbate,
                rotulo: 'Retenções (IRRF e CSLL/PIS/COFINS) calculadas sobre o valor já com o desconto incondicionado',
                dica:
                    'Marcado: a retenção sai do que vai ser pago (Lei 10.833/2003, art. 31), sem o desconto. '
                    'Desmarque se o seu cliente retém sobre o valor cheio do serviço. '
                    'O PIS/COFINS próprio sempre desconta: é o que a lei manda.',
                aoMudar: (v) {
                  cbRetAbate = v ?? true;
                  _recalcular();
                },
              ),
            ),
          // O cabeçalho da expansão é clicável e se pinta com o mouse em cima: a cor vem do
          // tema escopado, e o cartão transparente dá à expansão uma superfície por cima do
          // fundo onde a tinta do hover aparece.
          Theme(
            data: temaApp(realceHover: true),
            child: Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              color: Colors.transparent,
              shadowColor: Colors.transparent,
              semanticContainer: true,
              borderOnForeground: true,
              child: _maisCampos(),
            ),
          ),
        ],
        espaco: 14,
        justa: true,
        idLayout: 'Grupo.emitir.col.11',
      ),
    );
    return col(
      [
        Tx(
          'Emitir NFS-e',
          tam: Letra.titulo,
          peso: FontWeight.bold,
          largura: TamanhosEmitir.rotuloEmitirNFSE.largura,
          altura: TamanhosEmitir.rotuloEmitirNFSE.altura,
          idLayout: 'TamanhosEmitir.rotuloEmitirNFSE',
        ),
        // Aviso de SUBSTITUIÇÃO: a próxima emissão carrega o grupo <subst> e cancela a nota
        // antiga por substituição.
        if (subst != null)
          Ct(
            cor: Colors.orange.shade50,
            raio: BorderRadius.circular(8),
            borda: Border.all(color: Colors.orange.shade300, width: 1),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: lin([
              Icon(
                Icons.swap_horizontal_circle_outlined,
                color: Colors.orange.shade800,
              ),
              Expanded(
                child: Tx(
                  _textoSubst,
                  cor: Colors.orange.shade900,
                  peso: FontWeight.w600,
                  linhas: 2,
                  largura: TamanhosEmitir.rotuloTextoSubst.largura,
                  altura: TamanhosEmitir.rotuloTextoSubst.altura,
                  idLayout: 'TamanhosEmitir.rotuloTextoSubst',
                ),
              ),
              Botao.contorno(
                'Cancelar substituição',
                icone: Icons.close,
                aoClicar: cancelarSubstituicao,
                largura: TamanhosEmitir.botaoCancelarSubstituicao.largura,
                altura: TamanhosEmitir.botaoCancelarSubstituicao.altura,
                idLayout: 'TamanhosEmitir.botaoCancelarSubstituicao',
              ),
            ], idLayout: 'Grupo.emitir.lin.19'),
          ),
        lin(
          [
            ListaSuspensa(
              estado: ddTomador,
              rotulo: 'Cliente (tomador)',
              rotuloSemResultados: 'Adicionar cliente…',
              aoSemResultados: () {
                _cancelarTimer();
                _tomAnterior = null;
                abrirCliente(app, null);
              },
              largura: TamanhosEmitir.campoClienteTomador.largura!,
              editavel: true,
              filtrar: true,
              aoSelecionar: _aoSelecionarTomador,
              aoFocar: _aoFocarTomador,
              aoDesfocar: _aoDesfocarTomador,
              aoTexto: _aoTextoTomador,
              altura: TamanhosEmitir.campoClienteTomador.altura,
              idLayout: 'TamanhosEmitir.campoClienteTomador',
            ),
            ListaSuspensa(
              estado: ddGrupo,
              rotulo: 'Grupo',
              largura: TamanhosEmitir.campoGrupo.largura!,
              desabilitado: app.prestador.isEmpty,
              aoSelecionar: _aoGrupo,
              altura: TamanhosEmitir.campoGrupo.altura,
              idLayout: 'TamanhosEmitir.campoGrupo',
            ),
            ListaSuspensa(
              estado: ddServico,
              rotulo: 'Serviço',
              largura: TamanhosEmitir.campoServico.largura!,
              aoSelecionar: (v) {
                carregarServico(v);
                _atualizar();
              },
              altura: TamanhosEmitir.campoServico.altura,
              idLayout: 'TamanhosEmitir.campoServico',
            ),
          ],
          espaco: Medida.espacoEntreCampos,
          quebra: true,
          idLayout: 'Grupo.emitir.lin.20',
        ),
        Expanded(
          child: col([dados], rolar: true, idLayout: 'Grupo.emitir.col.13'),
        ),
        if (servico != null && _procuradores.isNotEmpty) ...[
          divisor(altura: 1),
          // Caixa de marcar mais baixa nesta faixa (só na vertical: o alinhamento à esquerda
          // continua o de sempre).
          Theme(
            data: Theme.of(context).copyWith(
              checkboxTheme: Theme.of(context).checkboxTheme
                  .copyWith(visualDensity: const VisualDensity(vertical: -4)),
            ),
            child: Ct(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _linhaProcurador(),
            ),
          ),
        ],
        divisor(altura: 1),
        // Barra de ações FIXA no rodapé. "Editar dados" fica à direita e só aparece com
        // a expansão de tributos aberta.
        Ct(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
          child: lin(
            [
              if (_tribTravado) ...[
                Botao.contorno(
                  'Pré-visualizar (sem enviar)',
                  icone: Icons.fact_check,
                  desabilitado: _emitindo,
                  aoClicar: aoPrevisualizar,
                  largura: TamanhosEmitir.botaoPreVisualizarSemEnviar.largura,
                  altura: TamanhosEmitir.botaoPreVisualizarSemEnviar.altura,
                  idLayout: 'TamanhosEmitir.botaoPreVisualizarSemEnviar',
                ),
                Botao(
                  'Emitir NFS-e',
                  icone: Icons.send,
                  desabilitado: _travaUi || _emitindo,
                  aoClicar: aoEmitir,
                  largura: TamanhosEmitir.botaoEmitirNFSE.largura,
                  altura: TamanhosEmitir.botaoEmitirNFSE.altura,
                  idLayout: 'TamanhosEmitir.botaoEmitirNFSE',
                ),
              ],
              if (_emitindo) anel(tamanho: 22),
              const Expanded(child: SizedBox()),
              if (!_tribAberto && _temRascunho)
                Botao.contorno(
                  'Cancelar emissão',
                  icone: Icons.delete_outline,
                  desabilitado: _emitindo || _travaUi || app.ocupado,
                  aoClicar: _cancelarEmissao,
                ),
              if (_tribAberto)
                Botao.contorno(
                  _tribTravado ? 'Editar dados' : 'Salvar dados',
                  icone: _tribTravado ? Icons.edit : Icons.save,
                  aoClicar: alternarTributos,
                  largura: TamanhosEmitir
                      .botaoTribTravadoEditarTributosSalvarTributos
                      .largura,
                  altura: TamanhosEmitir
                      .botaoTribTravadoEditarTributosSalvarTributos
                      .altura,
                  idLayout: 'TamanhosEmitir.botaoTribTravadoEditarTributosSalvarTributos',
                ),
            ],
            espaco: 12,
            idLayout: 'Grupo.emitir.lin.21',
          ),
        ),
      ],
      espaco: 14,
      idLayout: 'Grupo.emitir.col.12',
    );
  }
}

const danfseIndisponivel =
    'O download automático do DANFSe (PDF) foi descontinuado pela SEFIN em 03/08/2026 — '
    'não existe mais API de DANFSe para o contribuinte. O XML oficial da nota continua '
    'sendo baixado e guardado normalmente. Para obter o PDF, use a Consulta Pública com a '
    'chave de acesso.';
