/// Cadastro do cliente (janela): aba "Dados do cliente" e aba "Serviço & Tributação", cada
/// uma com a própria edição (Editar <-> Salvar). O Salvar não fecha a janela.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app/app.dart';
import '../app/prestador_novo.dart';
import '../kit/campo.dart';
import '../kit/contorno_campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import 'emitir.dart';
import 'periodo.dart' show abrirVencimento;

// Índice de municípios já normalizado (1x por execução): (nome sem acento, código, nome, UF).
// A tela NUNCA monta uma lista suspensa com os ~5.570 municípios: a busca é em memória, por
// digitação.
List<(String, String, String, String)>? _municipios;
Map<String, (String, String)>? _municipiosPorCodigo;

(String, String, String, String) _municipio(Object? m) => (
  termosBusca((m as List)[1] as String).join(' '),
  m[0] as String,
  m[1] as String,
  m[2] as String,
);

List<(String, String, String, String)> municipiosBusca() => _municipios ??= [
  for (final m in ja<List>('consulta.municipios')) _municipio(m),
];

/// código do IBGE -> (nome, UF), montado uma vez.
Map<String, (String, String)> municipiosPorCodigo() => _municipiosPorCodigo ??=
    {for (final m in municipiosBusca()) m.$2: (m.$3, m.$4)};

bool _municipiosPedidos = false;

/// Deixa o índice de municípios pronto antes de alguém abrir um cadastro: a lista é lida
/// pelo núcleo fora da thread da tela e o índice é montado aos poucos, com a tela parada.
/// (Sem isto, o primeiro cadastro aberto na sessão esperava a leitura inteira.)
void aquecerMunicipios() {
  if (_municipios != null || _municipiosPedidos) return;
  _municipiosPedidos = true;
  () async {
    final List<Object?> bruto;
    try {
      bruto = await chamar<List>('consulta.municipios');
    } catch (_) {
      _municipiosPedidos = false; // quem precisar lê na hora, como sempre
      return;
    }
    final saida = <(String, String, String, String)>[];
    var i = 0;
    void fatia() {
      if (_municipios != null) return; // alguém precisou antes e já leu
      final relogio = Stopwatch()..start();
      while (i < bruto.length && relogio.elapsedMicroseconds < 2500) {
        saida.add(_municipio(bruto[i++]));
      }
      if (i < bruto.length) {
        SchedulerBinding.instance.scheduleTask<void>(fatia, Priority.idle);
      } else {
        _municipios = saida;
      }
    }

    SchedulerBinding.instance.scheduleTask<void>(fatia, Priority.idle);
  }();
}

int _numeroDoSlug(String slug) =>
    int.tryParse(slug.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

String _cima(String? s) => (s ?? '').trim().toUpperCase();

/// [aba]/[slug]: aba e serviço com que a janela abre (usados ao REABRIR o cadastro quando o
/// Esc cancela uma edição — o usuário volta para onde estava).
void abrirCliente(
  App app,
  String? tomador, {
  int aba = 0,
  String? slug,
  Map<String, dynamic>? servicoDoLote,
  FutureOr<bool> Function(Map<String, dynamic>)? aoConfirmarLote,
}) {
  final emLote = aoConfirmarLote != null;
  final chave = emLote
      ? 'lotes.editar'
      : tomador == null
      ? 'clientes.adicionar'
      : 'clientes.editar';
  if (!app.temPermissao(chave)) {
    app.exigirPermissao(
      chave,
      () => abrirCliente(
        app,
        tomador,
        aba: aba,
        slug: slug,
        servicoDoLote: servicoDoLote,
        aoConfirmarLote: aoConfirmarLote,
      ),
    );
    return;
  }
  // Cliente é sempre de UM prestador: sem prestador ativo não há onde cadastrar.
  if (app.prestador.isEmpty) {
    app.toast('Selecione um prestador.', erro: true);
    return;
  }
  final editando = tomador != null;
  final p = app.prestador;
  final prestador = jaMapa('cadastro.get_prestador_form', {'prestador': p});
  final municipioPrestador = (prestador['cLocEmi'] as String? ?? '').trim();
  final form = editando
      ? jaMapa('cadastro.get_tomador_form', {
          'prestador': p,
          'tomador': tomador,
        })
      : <String, dynamic>{'tipo_doc': 'CNPJ'};
  String fs(String k) => (form[k] as String?) ?? '';

  final gruposDisp = p.isEmpty
      ? <String>[]
      : ja<List>('cadastro.list_grupos', {'prestador': p}).cast<String>();
  var grupoAtual = editando
      ? ja<String>('cadastro.get_tomador_grupo', {
          'prestador': p,
          'tomador': fs('documento'),
        })
      : '';
  final trib = p.isEmpty
      ? <String, String>{}
      : {
          for (final (k, v) in jaPares('cadastro.read_tributos', {
            'prestador': p,
          }))
            k: v,
        };

  // Serviços do cliente em memória (slug -> serviço + ordem).
  final servicos = <String, Map<String, dynamic>>{};
  final ordem = <String>[];
  Map<String, dynamic> servicoPadrao() =>
      jaMapa('cadastro.servico_padrao')..['cLocPrestacao'] = municipioPrestador;
  final novos = <String>{}; // criados NESTA janela (ainda não existem no banco)
  final removidos =
      <String>{}; // serviços excluídos, apagados do banco ao Salvar

  /// Põe na memória os serviços GRAVADOS do cliente ([documento] vazio = cliente novo).
  void lerServicos(String documento) {
    servicos.clear();
    ordem.clear();
    novos.clear();
    removidos.clear();
    if (documento.isNotEmpty) {
      final infos = jaLista('cadastro.list_servicos', {
        'prestador': p,
        'tomador': documento,
      });
      for (final i in infos) {
        final s = i['slug'] as String;
        servicos[s] = jaMapa('cadastro.get_servico', {
          'prestador': p,
          'tomador': documento,
          'servico': s,
        });
        ordem.add(s);
      }
    }
  }

  if (servicoDoLote != null && slug != null) {
    servicos[slug] = Map<String, dynamic>.from(servicoDoLote);
    ordem.add(slug);
  } else {
    lerServicos(editando ? fs('documento') : '');
  }
  // Estado da janela: serviço em edição, se já é um cliente salvo e o documento salvo (o
  // Salvar NÃO fecha a janela: "novo cliente" vira "edição" depois do 1º salvar).
  var slugAtual = (slug != null && ordem.contains(slug))
      ? slug
      : (ordem.isEmpty ? '' : ordem.first);
  bool temServico() => slugAtual.isNotEmpty && servicos.containsKey(slugAtual);
  var jaSalvo = editando;
  var docSalvo = editando ? soDoc(fs('documento')) : '';
  var abaAtual = emLote ? 1 : aba;

  String proximoSlug() {
    final usados = {...servicos.keys, ...removidos};
    var i = 1;
    while (usados.contains('serv$i')) {
      i++;
    }
    return 'serv$i';
  }

  late final Dialogo d;
  d = Dialogo(
    titulo: (_) => app.tituloComX(
      emLote
          ? 'Serviço do lote · ${fs('xNome')}'
          : editando
          ? 'Editar cliente'
          : 'Novo cliente',
    ),
    largura: 760,
    alinhamentoAcoes: MainAxisAlignment.spaceBetween,
    conteudo: (_) => const SizedBox.shrink(),
    idLayout: 'Janela.cliente_form.Dialogo.1',
  );
  // (o conteúdo e as ações de verdade são ligados no fim, quando tudo existe)

  // ---- dados do cliente ------------------------------------------------------------------ //
  final fTipo = d.suspensa(
    valor: fs('tipo_doc').isEmpty ? 'CNPJ' : fs('tipo_doc'),
    opcoes: tiposDocumento,
  );
  final fDoc = d.texto(mascaraDocumento(fs('documento'), fTipo.valor));
  final fIm = d.texto(_cima(fs('IM')));
  final fGrupo = d.suspensa(
    valor: grupoAtual.isEmpty ? semGrupo : grupoAtual,
    opcoes: [
      const Opcao(semGrupo, semGrupo),
      for (final g in gruposDisp) Opcao(g, g),
    ],
  );
  final fNome = d.texto(_cima(fs('xNome')));
  final informacoes = <_ContatoCliente>[];
  final contatosSalvos = form['contatos'] as List?;
  if (contatosSalvos != null) {
    for (final bruto in contatosSalvos) {
      final contato = Map<String, dynamic>.from(bruto as Map);
      informacoes.add(
        _ContatoCliente(
          d,
          contato['tipo'] as String,
          contato['valor'] as String? ?? '',
          contato['observacao'] as String? ?? '',
          contato['principal'] == true,
          personalizado: contato['rotulo'] as String? ?? '',
        ),
      );
    }
  } else {
    final porTipo = <String, List<_ContatoCliente>>{};
    for (final tipo in ['telefone', 'email']) {
      final valores =
          ((form[tipo == 'email' ? 'emails' : 'telefones'] as List?) ??
                  const [])
              .cast<String>();
      final legado = fs(tipo == 'email' ? 'email' : 'fone');
      final origem = valores.isNotEmpty
          ? valores
          : [if (legado.isNotEmpty) legado];
      final notas =
          ((form[tipo == 'email'
                          ? 'observacoes_emails'
                          : 'observacoes_telefones']
                      as List?) ??
                  const [])
              .cast<String>();
      final principal =
          (form[tipo == 'email' ? 'email_principal' : 'telefone_principal']
                  as num?)
              ?.toInt() ??
          0;
      porTipo[tipo] = [
        for (var i = 0; i < origem.length; i++)
          _ContatoCliente(
            d,
            tipo,
            origem[i],
            notas.elementAtOrNull(i) ?? '',
            i == principal,
          ),
      ];
    }
    for (final tipo
        in ((form['ordem_contatos'] as List?) ?? const []).cast<String>()) {
      final fila = porTipo[tipo];
      if (fila != null && fila.isNotEmpty) informacoes.add(fila.removeAt(0));
    }
    for (final fila in porTipo.values) informacoes.addAll(fila);
  }
  if (informacoes.isEmpty && !jaSalvo) {
    informacoes.add(_ContatoCliente(d, 'telefone', '', '', true));
    informacoes.add(_ContatoCliente(d, 'email', '', '', true));
  }
  final fObservacoesGerais = d.texto(fs('observacoes_gerais'));
  void acertarPrincipais() {
    for (final tipo in ['telefone', 'email']) {
      final lista = informacoes.where((r) => r.categoria == tipo).toList();
      if (lista.isEmpty) continue;
      final principal =
          lista.where((r) => r.principal).firstOrNull ?? lista.first;
      for (final r in lista) r.principal = identical(r, principal);
    }
    for (final r in informacoes.where((r) => r.categoria == 'outros')) {
      r.principal = false;
    }
  }

  void contatoEncontrado(String tipo, String valor) {
    final lista = informacoes.where((r) => r.categoria == tipo).toList();
    if (lista.isEmpty) {
      informacoes.add(_ContatoCliente(d, tipo, valor, '', true));
    } else {
      (lista.where((r) => r.principal).firstOrNull ?? lista.first).valor.text =
          valor;
    }
  }

  acertarPrincipais();
  void removerContato(_ContatoCliente contato) {
    void remover() {
      if (!d.aberto) return;
      informacoes.remove(contato);
      acertarPrincipais();
      d.atualizar();
    }

    if (contato.valor.text.trim().isEmpty) {
      remover();
      return;
    }
    late final Dialogo confirmacao;
    confirmacao = Dialogo(
      titulo: (_) => textoTitulo('Remover contato'),
      largura: 360,
      conteudo: (_) =>
          Tx('Remover ${contato.rotulo}: ${contato.valor.text.trim()}?'),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(confirmacao)),
        Botao(
          'Remover',
          icone: Icons.delete_outline,
          aoClicar: () {
            app.fecharEsta(confirmacao);
            remover();
          },
        ),
      ],
      idLayout: 'Cliente.contato.confirmarExclusao',
    );
    app.mostrarDialogo(confirmacao);
  }

  void personalizarContato(_ContatoCliente contato) {
    late final Dialogo editor;
    late final TextEditingController nome;
    var categoria = contato.personalizado.isEmpty
        ? 'outros'
        : contato.categoria;
    void salvarTipo() {
      final rotulo = nome.text.trim();
      if (rotulo.isEmpty) {
        app.toast('Informe o nome do contato.', erro: true);
        return;
      }
      if (d.aberto) {
        final anterior = contato.categoria;
        contato.definirTipo(categoria, personalizado: rotulo);
        if (anterior != categoria) contato.principal = false;
        acertarPrincipais();
        d.atualizar();
      }
      app.fecharEsta(editor);
    }

    editor = Dialogo(
      titulo: (_) => textoTitulo('Personalizar contato'),
      largura: 360,
      conteudo: (_) => col([
        CampoTexto(
          controle: nome,
          rotulo: 'Nome do contato',
          largura: double.infinity,
          focoInicial: true,
          aoEnviar: (_) => salvarTipo(),
          idLayout: 'Cliente.contato.nomePersonalizado',
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final (chave, texto) in [
              ('telefone', 'Telefone'),
              ('email', 'E-mail'),
              ('outros', 'Outros'),
            ])
              Marcar(
                valor: categoria == chave,
                rotulo: texto,
                compacto: true,
                aoMudar: (v) {
                  if (v != true) return;
                  categoria = chave;
                  editor.atualizar();
                },
                idLayout: 'Cliente.contato.classificacao:$chave',
              ),
          ],
        ),
      ], justa: true),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(editor)),
        Botao('Salvar', icone: Icons.save, aoClicar: salvarTipo),
      ],
      idLayout: 'Cliente.contato.personalizar',
    );
    nome = editor.texto(contato.personalizado);
    app.mostrarDialogo(editor);
  }

  final fCmun = d.texto(fs('cMun'));
  final fCep = d.texto(fs('CEP'));
  final munBusca = municipiosBusca();
  final munPorCod = municipiosPorCodigo();
  final fCidade = d.texto(
    (fs('cMun').isNotEmpty && munPorCod.containsKey(fs('cMun')))
        ? _cima(munPorCod[fs('cMun')]!.$1)
        : _cima(fs('xCidade')),
  );
  final fUf = d.texto(_cima(fs('UF')));
  final fLgr = d.texto(_cima(fs('xLgr')));
  final fNro = d.texto(_cima(fs('nro')));
  final fCpl = d.texto(_cima(fs('xCpl')));
  final fBairro = d.texto(_cima(fs('xBairro')));
  var sugestoes = <(String, String, String)>[]; // (código, nome, UF)

  // ---- campos do serviço (carregados/lidos por carregarServico/coletarServico) ------------ //
  final fServNome = d.texto();
  final fLocPrest = d.texto();
  var plataformaDigital = false;
  final fTribNac = Catalogo('tribnac');
  final fNbs = Catalogo('nbs');
  d.aoDescartar(fTribNac.dd.dispose);
  d.aoDescartar(fNbs.dd.dispose);
  final fTribMun = d.texto();
  var temIntermediario = false;
  final ddIntermTipo = d.suspensa(valor: 'CNPJ', opcoes: tiposDocumento);
  final fIntermDoc = d.texto();
  final fIntermNome = d.texto();
  final fIntermIm = d.texto();
  final fDesc = d.texto();
  final ddCst = d.suspensa(
    valor: cstOpcoes.first.$1,
    opcoes: opcoesDe(cstOpcoes),
  );
  final ddRet = d.suspensa(
    valor: retOpcoes.first.$1,
    opcoes: opcoesDe(retOpcoes),
  );
  final ddIss = d.suspensa(
    valor: issOpcoes.first.$1,
    opcoes: opcoesDe(issOpcoes),
  );
  final ddRetIss = d.suspensa(
    valor: retIssOpcoes.first.$1,
    opcoes: opcoesDe(retIssOpcoes),
  );
  final ddRtcDest = d.suspensa(
    opcoes: const [Opcao('0', 'Sim'), Opcao('1', 'Não')],
  );
  final ddRtcIndOp = d.suspensa(
    opcoes: opcoesDe(jaPares('catalogo.indop_options')),
  );
  final ddRtcCst = d.suspensa(
    opcoes: opcoesDe(jaPares('catalogo.cst_options')),
  );
  final ddRtcClasse = d.suspensa();
  final ddDestTipo = d.suspensa(opcoes: tiposDocumento);
  final fDestDoc = d.texto();
  final fDestNome = d.texto();
  final fDestMun = d.texto();
  final fDestCep = d.texto();
  final fDestLgr = d.texto();
  final fDestNro = d.texto();
  final fDestCpl = d.texto();
  final fDestBairro = d.texto();
  final fPis = d.texto();
  final fCofins = d.texto();
  final fIrrf = d.texto();
  final fCsll = d.texto();
  final fFed = d.texto();
  final fEst = d.texto();
  final fMun = d.texto();
  var cbContrib = true;
  final ddServico = d.suspensa();
  // Locação (só no leiaute novo da NFS-e, NT 009): imóvel (cTribNac 99.03.xx) e bens móveis
  // (99.04.01). As listas crescem e encolhem com os botões da aba.
  final fLocMun = d.texto();
  final fLocCoprop = d.texto();
  final fLocVenc = d.texto();
  var vencAutomatico = false;
  var vencDia = 10;
  var vencMeses = 1;
  var vencManualLoc = '';
  var vencManualCond = '';
  final unidades = <_Unidade>[];
  final bens = <_Bem>[];
  bool eImovel() => (fTribNac.dd.valor ?? '').startsWith('9903');
  bool eBemMovel() => (fTribNac.dd.valor ?? '') == '990401';
  // Condomínio (cTribNac 99.05.01): usa o município e as unidades do imóvel; o valor da nota e
  // os descontos são a soma das cobranças e dos descontos daqui.
  final fCondVenc = d.texto();
  final cobrancas = <_Cobranca>[];
  final descontosCond = <_DescontoCond>[];
  bool eCondominio() => (fTribNac.dd.valor ?? '').startsWith('9905');

  // Estado de edição: o cadastro abre TRAVADO; "Editar" libera os campos e dá lugar ao
  // "Salvar". São DUAS edições independentes. Cliente novo abre com os dados liberados;
  // o serviço só é criado e liberado ao clicar em "Novo serviço".
  var editaDados = !editando;
  var editaServ = emLote;
  // CST=00: percentuais de PIS/COFINS ZERADOS na tela e "incluir contribuições" desmarcado
  // (os valores reais ficam guardados aqui e voltam ao escolher um CST tributado).
  var pctZero = false;
  var pctZeroPis = '';
  var pctZeroCofins = '';
  var contribZero = false;
  var contribZeroVal = true;
  var retZero = false;
  var retZeroIrrf = '';
  var retZeroCsll = '';

  String pctPis() => pctZero ? pctZeroPis : fPis.text;
  String pctCofins() => pctZero ? pctZeroCofins : fCofins.text;
  String pctIrrf() => retZero ? retZeroIrrf : fIrrf.text;
  String pctCsll() => retZero ? retZeroCsll : fCsll.text;
  bool abaEmEdicao() => abaAtual == 1 ? editaServ && temServico() : editaDados;

  /// Aplica o que o CST trava e a carga/descarga dos catálogos.
  void acertar() {
    final semCalc = (ddCst.valor ?? '01') == '00';
    final naoRetido = (ddRet.valor ?? '0') == '0';
    if (naoRetido && !retZero) {
      retZero = true;
      retZeroIrrf = fIrrf.text;
      retZeroCsll = fCsll.text;
      fIrrf.text = '0,00';
      fCsll.text = '0,00';
    } else if (!naoRetido && retZero) {
      fIrrf.text = retZeroIrrf;
      fCsll.text = retZeroCsll;
      retZero = false;
    }
    if (semCalc && !pctZero) {
      pctZero = true;
      pctZeroPis = fPis.text;
      pctZeroCofins = fCofins.text;
      fPis.text = '0,00';
      fCofins.text = '0,00';
    } else if (!semCalc && pctZero) {
      fPis.text = pctZeroPis;
      fCofins.text = pctZeroCofins;
      pctZero = false;
    }
    if ((semCalc || naoRetido) && !contribZero) {
      contribZero = true;
      contribZeroVal = cbContrib;
      cbContrib = false;
    } else if (!semCalc && !naoRetido && contribZero) {
      cbContrib = contribZeroVal;
      contribZero = false;
    }
    if (!editaDados)
      sugestoes = []; // sem sugestões clicáveis com os dados travados
    // Catálogos: lista inteira só com o serviço em edição.
    for (final c in [fTribNac, fNbs]) {
      if (editaServ && temServico() ? c.encher() : c.enxugar()) c.dd.avisar();
    }
    d.atualizar();
  }

  void classes(String cst, [String escolhida = '']) {
    final ops = jaPares('catalogo.class_options', {'cst': cst});
    ddRtcClasse.opcoes = opcoesDe(ops);
    ddRtcClasse.por(ops.any((o) => o.$1 == escolhida) ? escolhida : null);
    ddRtcClasse.avisar();
  }

  String vencimentoAutomaticoIso() =>
      ja<String>('cadastro.calcular_vencimento', {
        'referencia': DateTime.now().toIso8601String().substring(0, 10),
        'dia': vencDia,
        'meses': vencMeses,
      });

  void atualizarVencimentoVisual() {
    if (vencAutomatico) {
      if (vencDia < 1 || vencDia > 31 || vencMeses < 0 || vencMeses > 12) {
        fLocVenc.clear();
        fCondVenc.clear();
        return;
      }
      final visual = dataIsoParaBr(vencimentoAutomaticoIso());
      fLocVenc.text = visual;
      fCondVenc.text = visual;
    } else {
      fLocVenc.text = dataIsoParaBr(vencManualLoc);
      fCondVenc.text = dataIsoParaBr(vencManualCond);
    }
  }

  void configurarVencimento() {
    var ligado = vencAutomatico;
    late final Dialogo config;
    late final Suspensa dia;
    late final Suspensa meses;
    config = Dialogo(
      titulo: (_) => textoTitulo('Configurar vencimento'),
      largura: 460,
      conteudo: (_) => col([
        Marcar(
          valor: ligado,
          rotulo: 'Calcular vencimento automaticamente',
          aoMudar: (v) {
            ligado = v == true;
            config.atualizar();
          },
          idLayout: 'Vencimento.automatico',
        ),
        ListaSuspensa(
          estado: dia,
          rotulo: 'Todo dia',
          largura: 130,
          desabilitado: !ligado,
          idLayout: 'Vencimento.dia',
        ),
        ListaSuspensa(
          estado: meses,
          rotulo: 'Mês de vencimento',
          largura: 400,
          desabilitado: !ligado,
          idLayout: 'Vencimento.meses',
        ),
        const Tx(
          'A referência é o mês da competência do aluguel. Dias que não existirem serão ajustados ao último dia do mês.',
          tam: Letra.apoio,
        ),
      ], justa: true),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(config)),
        Botao(
          'Salvar',
          icone: Icons.save,
          aoClicar: () {
            if (!vencAutomatico) {
              vencManualLoc = dataBrParaIso(fLocVenc.text);
              vencManualCond = dataBrParaIso(fCondVenc.text);
            }
            vencAutomatico = ligado;
            vencDia = int.tryParse(dia.valor ?? '') ?? 10;
            vencMeses = int.tryParse(meses.valor ?? '') ?? 1;
            atualizarVencimentoVisual();
            app.fecharEsta(config);
            d.atualizar();
          },
        ),
      ],
      idLayout: 'Vencimento.configuracao',
    );
    dia = config.suspensa(
      valor: '$vencDia',
      opcoes: [for (var i = 1; i <= 31; i++) Opcao('$i', '$i')],
    );
    meses = config.suspensa(
      valor: '$vencMeses',
      opcoes: [
        const Opcao('0', 'Do mesmo mês da competência'),
        const Opcao('1', 'Do mês subsequente'),
        for (var i = 2; i <= 12; i++)
          Opcao('$i', '$i meses após a competência'),
      ],
    );
    app.mostrarDialogo(config);
  }

  void escolherVencimento(bool locacao) {
    final campo = locacao ? fLocVenc : fCondVenc;
    abrirVencimento(app, lerDataDoCampo(campo.text) ?? DateTime.now(), (data) {
      campo.text = diaBr(data);
      d.atualizar();
    });
  }

  /// Preenche os campos de serviço + tributação a partir de um serviço.
  void carregarServico(Map<String, dynamic> sf) {
    String s(String k) => (sf[k] as String?) ?? '';
    pctZero = false; // carregando valores REAIS; acertar() re-zera se CST=00
    contribZero = false;
    retZero = false;
    fServNome.text = _cima(s('nome'));
    fLocPrest.text = s('cLocPrestacao');
    fTribNac.por(s('cTribNac'));
    fTribMun.text = s('cTribMun');
    temIntermediario = [
      s('interm_documento'),
      s('interm_xNome'),
      s('interm_IM'),
    ].any((v) => v.trim().isNotEmpty);
    ddIntermTipo.por(s('interm_tipo').isEmpty ? 'CNPJ' : s('interm_tipo'));
    fIntermDoc.text = mascaraDocumento(
      s('interm_documento'),
      ddIntermTipo.valor,
    );
    fIntermNome.text = s('interm_xNome');
    fIntermIm.text = s('interm_IM');
    fNbs.por(s('cNBS'));
    fDesc.text = ja<String>('texto.limpar_descricao', {
      'valor': _cima(s('xDescServ')),
    });
    ddCst.por(s('pis_CST'));
    ddRet.por(s('tpRetPisCofins'));
    ddIss.por(s('tribISSQN'));
    ddRetIss.por(s('tpRetISSQN'));
    plataformaDigital = sf['rtc_plataforma_digital'] == true;
    ddRtcDest.por(s('rtc_indDest'));
    ddRtcIndOp.por(s('rtc_cIndOp'));
    ddRtcCst.por(s('rtc_CST'));
    classes(s('rtc_CST'), s('rtc_cClassTrib'));
    ddDestTipo.por(s('dest_tipo').isEmpty ? 'CNPJ' : s('dest_tipo'));
    fDestDoc.text = s('dest_documento');
    fDestNome.text = s('dest_xNome');
    fDestMun.text = s('dest_cMun');
    fDestCep.text = s('dest_CEP');
    fDestLgr.text = s('dest_xLgr');
    fDestNro.text = s('dest_nro');
    fDestCpl.text = s('dest_xCpl');
    fDestBairro.text = s('dest_xBairro');
    cbContrib =
        temServico() &&
        (s('incluir_contrib').isEmpty ? '1' : s('incluir_contrib')).trim() !=
            '0';
    fLocMun.text = s('loc_cMun');
    fLocCoprop.text = copropriedadeVirgula(
      s('loc_pCopropriedade').replaceAll('.', ','),
    );
    vencAutomatico = sf['venc_automatico'] == true;
    vencDia = (sf['venc_dia'] as num?)?.toInt() ?? 10;
    vencMeses = (sf['venc_meses'] as num?)?.toInt() ?? 1;
    vencManualLoc = s('loc_dVencOrig');
    vencManualCond = s('cond_dVencOrig');
    unidades
      ..clear()
      ..addAll([
        for (final u in (sf['loc_unidades'] as List?) ?? const [])
          _Unidade(d, Map<String, dynamic>.from(u as Map)),
      ]);
    bens
      ..clear()
      ..addAll([
        for (final x in (sf['bens_moveis'] as List?) ?? const [])
          _Bem(d, Map<String, dynamic>.from(x as Map)),
      ]);
    atualizarVencimentoVisual();
    cobrancas
      ..clear()
      ..addAll([
        for (final x in (sf['cond_cobrancas'] as List?) ?? const [])
          _Cobranca(d, Map<String, dynamic>.from(x as Map)),
      ]);
    descontosCond
      ..clear()
      ..addAll([
        for (final x in (sf['cond_descontos'] as List?) ?? const [])
          _DescontoCond(d, Map<String, dynamic>.from(x as Map)),
      ]);
    // Percentuais exibidos SEMPRE com vírgula (mesmo que a configuração use ponto).
    String pct(String sobra, String herdado) => !temServico()
        ? ''
        : pctVirgula(
            s(sobra).trim().isEmpty ? (trib[herdado] ?? '') : s(sobra).trim(),
          );
    fPis.text = pct('ov_pAliqPis', 'pAliqPis');
    fCofins.text = pct('ov_pAliqCofins', 'pAliqCofins');
    fIrrf.text = pct('ov_pIRRF', 'irrf');
    fCsll.text = pct('ov_pCSLL', 'csll');
    fFed.text = pct('ov_pTotTribFed', 'pTotTribFed');
    fEst.text = pct('ov_pTotTribEst', 'pTotTribEst');
    fMun.text = pct('ov_pTotTribMun', 'pTotTribMun');
    for (final x in [
      fTribNac.dd,
      fNbs.dd,
      ddCst,
      ddRet,
      ddIss,
      ddRetIss,
      ddRtcDest,
      ddRtcIndOp,
      ddRtcCst,
      ddDestTipo,
    ]) {
      x.avisar();
    }
    acertar();
  }

  /// Lê os campos de serviço + tributação. O valor do serviço NÃO é editado aqui (só na
  /// tela Emitir): preserva o que já estava no serviço.
  Map<String, dynamic> coletarServico() {
    final atual = servicos[slugAtual];
    final f = servicoPadrao();
    var nome = _cima(fServNome.text);
    if (nome.isEmpty) nome = 'Serviço';
    if (nome.length > 25) nome = nome.substring(0, 25);
    f['nome'] = nome;
    f['cLocPrestacao'] = fLocPrest.text.trim();
    f['cTribNac'] = (fTribNac.dd.valor ?? '').trim();
    f['cTribMun'] = fTribMun.text.trim();
    f['interm_tipo'] = ddIntermTipo.valor ?? 'CNPJ';
    f['interm_documento'] = temIntermediario ? soDoc(fIntermDoc.text) : '';
    f['interm_xNome'] = temIntermediario ? fIntermNome.text.trim() : '';
    f['interm_IM'] = temIntermediario ? fIntermIm.text.trim() : '';
    f['xDescServ'] = _cima(fDesc.text);
    f['cNBS'] = (fNbs.dd.valor ?? '').trim();
    f['rtc_plataforma_digital'] = plataformaDigital;
    f['rtc_indDest'] = ddRtcDest.valor ?? '';
    f['rtc_cIndOp'] = ddRtcIndOp.valor ?? '';
    f['rtc_CST'] = ddRtcCst.valor ?? '';
    f['rtc_cClassTrib'] = ddRtcClasse.valor ?? '';
    f['dest_tipo'] = ddDestTipo.valor ?? 'CNPJ';
    f['dest_documento'] = fDestDoc.text;
    f['dest_xNome'] = fDestNome.text;
    f['dest_cMun'] = fDestMun.text;
    f['dest_CEP'] = fDestCep.text;
    f['dest_xLgr'] = fDestLgr.text;
    f['dest_nro'] = fDestNro.text;
    f['dest_xCpl'] = fDestCpl.text;
    f['dest_xBairro'] = fDestBairro.text;
    f['vServ'] = (atual?['vServ'] as String?) ?? '';
    f['tribISSQN'] = ddIss.valor ?? '';
    f['tpRetISSQN'] = ddRetIss.valor ?? '';
    f['pis_CST'] = ddCst.valor ?? '';
    f['tpRetPisCofins'] = ddRet.valor ?? '';
    // Com CST=00 o checkbox está só VISUALMENTE desmarcado — vale o guardado.
    f['incluir_contrib'] = (contribZero ? contribZeroVal : cbContrib)
        ? '1'
        : '0';
    // percentuais EFETIVOS (com CST=00 a tela mostra 0, mas o real fica guardado)
    f['ov_pAliqPis'] = sobraPercentual(pctPis(), trib['pAliqPis']);
    f['ov_pAliqCofins'] = sobraPercentual(pctCofins(), trib['pAliqCofins']);
    f['ov_pIRRF'] = sobraPercentual(pctIrrf(), trib['irrf']);
    f['ov_pCSLL'] = sobraPercentual(pctCsll(), trib['csll']);
    f['ov_pTotTribFed'] = sobraPercentual(fFed.text, trib['pTotTribFed']);
    f['ov_pTotTribEst'] = sobraPercentual(fEst.text, trib['pTotTribEst']);
    f['ov_pTotTribMun'] = sobraPercentual(fMun.text, trib['pTotTribMun']);
    f['vRetIRRF_manual'] = (atual?['vRetIRRF_manual'] as String?) ?? '';
    f['vRetCSLL_manual'] = (atual?['vRetCSLL_manual'] as String?) ?? '';
    f['ret_abate_desconto'] = (atual?['ret_abate_desconto'] as String?) ?? '1';
    // O núcleo só guarda os dados de locação quando o código de tributação é de locação.
    f['loc_cMun'] = fLocMun.text.trim();
    f['loc_pCopropriedade'] = fLocCoprop.text.trim();
    f['loc_dVencOrig'] = vencAutomatico
        ? vencManualLoc
        : dataBrParaIso(fLocVenc.text.trim());
    f['venc_automatico'] = vencAutomatico;
    f['venc_dia'] = vencDia;
    f['venc_meses'] = vencMeses;
    f['loc_unidades'] = [for (final u in unidades) u.mapa()];
    f['bens_moveis'] = [for (final x in bens) x.mapa()];
    f['cond_dVencOrig'] = vencAutomatico
        ? vencManualCond
        : dataBrParaIso(fCondVenc.text.trim());
    f['cond_cobrancas'] = [for (final x in cobrancas) x.mapa()];
    f['cond_descontos'] = [for (final x in descontosCond) x.mapa()];
    // Descontos da nota: como o valor, são da tela Emitir — aqui só se preserva o que havia.
    // No condomínio os três saem das listas acima (o núcleo soma): não vai valor avulso.
    final cond = eCondominio();
    if (cond) f['vServ'] = '';
    f['vDescIncond'] = cond ? '' : ((atual?['vDescIncond'] as String?) ?? '');
    f['vDescCond'] = cond ? '' : ((atual?['vDescCond'] as String?) ?? '');
    return f;
  }

  List<Opcao> opcoesDeServico() => [
    for (final s in ordem)
      Opcao(
        s,
        ((servicos[s]!['nome'] as String?) ?? '').trim().isEmpty
            ? s
            : (servicos[s]!['nome'] as String).trim(),
      ),
  ];

  void trocarPara(String s) {
    slugAtual = servicos.containsKey(s) ? s : '';
    if (!temServico()) editaServ = false;
    ddServico.opcoes = opcoesDeServico();
    ddServico.por(slugAtual.isEmpty ? null : slugAtual);
    ddServico.avisar();
    carregarServico(servicos[slugAtual] ?? {});
  }

  void novoServico() {
    if (!app.temPermissao('clientes.servicos')) {
      app.exigirPermissao('clientes.servicos', novoServico);
      return;
    }
    if (temServico()) servicos[slugAtual] = coletarServico();
    final s = proximoSlug();
    servicos[s] = servicoPadrao()..['nome'] = 'Serviço ${_numeroDoSlug(s)}';
    ordem.add(s);
    novos.add(s); // só vai ao banco se for preenchido E o cadastro salvo
    editaServ =
        true; // criar um serviço novo já entra em edição (só a do serviço)
    trocarPara(s);
  }

  /// "Cancelar" da aba Serviço & Tributação: descarta o que não foi salvo dos SERVIÇOS (edição,
  /// serviço novo, exclusão à espera do Salvar) e re-trava a aba. Os dados do cliente, na outra
  /// aba, ficam como estão.
  void cancelarServico() {
    final onde = slugAtual;
    lerServicos(docSalvo);
    editaServ = false;
    trocarPara(
      ordem.contains(onde) ? onde : (ordem.isEmpty ? '' : ordem.first),
    );
  }

  void excluirServicoConfirmado() {
    final s = slugAtual;
    ordem.remove(s);
    servicos.remove(s);
    if (!novos.contains(s)) removidos.add(s); // novos nunca chegaram ao banco
    novos.remove(s);
    editaServ = true; // a exclusão só vale ao Salvar: o botão tem de aparecer
    trocarPara(ordem.isEmpty ? '' : ordem.first);
  }

  /// Exclusão exige digitar "deletar" (mesmo padrão do excluir cliente).
  void pedirExcluirServico() {
    if (!temServico()) return;
    if (!app.temPermissao('clientes.servicos')) {
      app.exigirPermissao('clientes.servicos', pedirExcluirServico);
      return;
    }
    final nomeServ = ((servicos[slugAtual]!['nome'] as String?) ?? '').isEmpty
        ? slugAtual
        : servicos[slugAtual]!['nome'] as String;
    late final Dialogo c;
    late final TextEditingController campo;
    late final FocusNode focoDoCampo;
    void confirmar() {
      if (campo.text.trim().toLowerCase() != 'deletar') {
        app.toast("Digite exatamente 'deletar' para confirmar.", erro: true);
        focoDoCampo.requestFocus();
        return;
      }
      app.fecharDialogo(); // fecha só a confirmação (o cadastro continua aberto)
      excluirServicoConfirmado();
    }

    c = Dialogo(
      titulo: (_) => LinhaTitulo([
        Icon(Icons.warning_amber, color: Colors.red.shade700),
        textoTitulo('Excluir serviço'),
      ], espaco: 10),
      largura: 420,
      conteudo: (_) => col(
        [
          Tx(
            "Excluir o serviço '$nomeServ' deste cliente? "
            'A exclusão é gravada ao Salvar o cadastro.',
            largura: TamanhosDadosCliente
                .rotuloExcluirOServicoNomeServDesteClienteAExclusao
                .largura,
            altura: TamanhosDadosCliente
                .rotuloExcluirOServicoNomeServDesteClienteAExclusao
                .altura,
            idLayout:
                'TamanhosDadosCliente.rotuloExcluirOServicoNomeServDesteClienteAExclusao',
          ),
          CampoTexto(
            controle: campo,
            rotulo: "Digite 'deletar' para confirmar",
            largura:
                TamanhosDadosCliente.campoDigiteDeletarParaConfirmar.largura,
            foco: focoDoCampo,
            focoInicial: true,
            aoEnviar: (_) => confirmar(),
            altura: TamanhosDadosCliente.campoDigiteDeletarParaConfirmar.altura,
            idLayout: 'TamanhosDadosCliente.campoDigiteDeletarParaConfirmar',
          ),
        ],
        justa: true,
        idLayout: 'Grupo.cliente_form.col.1',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosDadosCliente.botaoCancelar.largura,
          altura: TamanhosDadosCliente.botaoCancelar.altura,
          idLayout: 'TamanhosDadosCliente.botaoCancelar',
        ),
        Botao(
          'Excluir',
          icone: Icons.delete_forever,
          cor: Colors.white,
          fundo: Colors.red.shade700,
          aoClicar: confirmar,
          largura: TamanhosDadosCliente.botaoExcluir.largura,
          altura: TamanhosDadosCliente.botaoExcluir.altura,
          idLayout: 'TamanhosDadosCliente.botaoExcluir',
        ),
      ],
      idLayout: 'Janela.cliente_form.Dialogo.2',
    );
    campo = c.texto();
    focoDoCampo = c.foco();
    app.mostrarDialogo(c);
  }

  // ---- busca de CNPJ / CEP ------------------------------------------------------------------ //
  /// Cidade/UF a partir da busca: nome oficial da lista do IBGE pelo código (quando
  /// disponível) ou o texto devolvido pela consulta.
  void preencherCidadeUf(Map dados) {
    final cmun = (dados['cMun'] as String?) ?? '';
    if (cmun.isNotEmpty && munPorCod.containsKey(cmun)) {
      final (nome, uf) = munPorCod[cmun]!;
      fCidade.text = _cima(nome);
      fUf.text = uf;
    } else if (((dados['cidade'] as String?) ?? '').isNotEmpty) {
      fCidade.text = _cima(dados['cidade'] as String);
    }
    if (((dados['uf'] as String?) ?? '').isNotEmpty)
      fUf.text = _cima(dados['uf'] as String);
    sugestoes = []; // preenchimento automático dispensa as sugestões
  }

  void aplicarBusca(Map dados, bool cnpj, String esperado) {
    if (!app.viva || !editaDados || !app.dialogoAberto(d)) return;
    final atual = cnpj ? soDoc(fDoc.text) : soDigitos(fCep.text);
    if (atual != esperado) return;
    String t(String k) => (dados[k] as String?) ?? '';
    final campos = [('xLgr', fLgr), ('xCpl', fCpl), ('xBairro', fBairro)];
    if (cnpj) campos.addAll([('xNome', fNome), ('nro', fNro)]);
    for (final (chave, campo) in campos) {
      if (t(chave).isNotEmpty) campo.text = _cima(t(chave));
    }
    if (cnpj) {
      if (t('CEP').isNotEmpty) fCep.text = t('CEP');
      if (t('fone').isNotEmpty)
        contatoEncontrado('telefone', soDigitos(t('fone')));
      if (t('email').isNotEmpty)
        contatoEncontrado('email', t('email').toLowerCase());
    }
    if (t('cMun').isNotEmpty) fCmun.text = t('cMun');
    preencherCidadeUf(dados);
    d.atualizar();
    app.toast(
      cnpj
          ? 'Dados do CNPJ preenchidos.${t('cMun').isNotEmpty ? '' : ' (cMun não resolvido - confira o CEP)'}'
          : 'Endereço do CEP preenchido.',
    );
  }

  void buscarDados(bool cnpj) {
    if (!editaDados) return;
    if (!app.temPermissao('clientes.consulta_publica')) {
      app.exigirPermissao('clientes.consulta_publica', () => buscarDados(cnpj));
      return;
    }
    final esperado = cnpj ? soDoc(fDoc.text) : soDigitos(fCep.text);
    final tamanho = cnpj ? 14 : 8;
    final rotulo = cnpj ? 'CNPJ' : 'CEP';
    if (esperado.length != tamanho) {
      app.toast(
        'Informe um $rotulo ($tamanho ${cnpj ? 'caracteres' : 'dígitos'}) para buscar.',
        erro: true,
      );
      return;
    }
    app.toast('Consultando $rotulo...');
    app.emSegundoPlano(() async {
      Map dados;
      try {
        dados = await chamar<Map>(
          cnpj ? 'consulta.cnpj' : 'consulta.cep',
          cnpj ? {'cnpj': esperado} : {'cep': esperado},
        );
      } catch (e) {
        app.toast('Falha ao consultar $rotulo: $e', erro: true);
        return;
      }
      aplicarBusca(dados, cnpj, esperado);
    });
  }

  // ---- salvar --------------------------------------------------------------------------------- //
  var salvandoLote = false;
  Future<void> salvar() async {
    // Cliente já salvo: grava só o que a aba em edição cobre (dados OU serviços). Cliente
    // ainda não salvo: grava tudo de uma vez.
    if (aoConfirmarLote != null) {
      if (salvandoLote) return;
      if (slugAtual != slug || !temServico()) {
        app.toast(
          'Edite o serviço deste lote na aba Serviço & Tributação.',
          erro: true,
        );
        return;
      }
      final form = coletarServico();
      final erros = ja<List>('cadastro.servico_validate', {
        'form': form,
        'prestador': p,
        'require_rtc': false,
      });
      if (erros.isNotEmpty) {
        app.toast('Corrija: ${erros.join('; ')}', erro: true);
        return;
      }
      salvandoLote = true;
      try {
        if (await aoConfirmarLote(Map<String, dynamic>.from(form)) &&
            d.aberto) {
          app.fecharEsta(d);
        }
      } finally {
        salvandoLote = false;
      }
      return;
    }
    final tudo = !jaSalvo;
    final comDados = tudo || abaAtual == 0;
    final comServ = tudo || abaAtual == 1;
    final regraDados = jaSalvo ? 'clientes.editar' : 'clientes.adicionar';
    final grupo = fGrupo.valor == semGrupo ? '' : fGrupo.valor ?? '';
    final mudarGrupo = comDados && grupo != grupoAtual;
    if (comDados && !app.temPermissao(regraDados)) {
      app.exigirPermissao(regraDados, salvar);
      return;
    }
    if (comServ &&
        (ordem.isNotEmpty || removidos.isNotEmpty) &&
        !app.temPermissao('clientes.servicos')) {
      app.exigirPermissao('clientes.servicos', salvar);
      return;
    }
    if (mudarGrupo && !app.temPermissao('clientes.grupos')) {
      app.exigirPermissao('clientes.grupos', salvar);
      return;
    }
    final erros = <String>[];
    Map<String, dynamic>? novo;
    if (comDados) {
      final preenchidos = informacoes
          .where((r) => r.valor.text.trim().isNotEmpty)
          .toList();
      final telefones = preenchidos
          .where((r) => r.categoria == 'telefone')
          .toList();
      final emails = preenchidos.where((r) => r.categoria == 'email').toList();
      int principal(List<_ContatoCliente> lista) {
        final indice = lista.indexWhere((r) => r.principal);
        return indice < 0 ? 0 : indice;
      }

      String valorPrincipal(List<_ContatoCliente> lista) =>
          lista.isEmpty ? '' : lista[principal(lista)].valor.text;
      for (final r in preenchidos) {
        final valor = r.valor.text.trim();
        if (valor.isEmpty) continue;
        if (r.categoria == 'email' &&
            !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(valor))
          erros.add('Revise o e-mail: $valor');
        if (r.categoria == 'telefone' &&
            !RegExp(r'^\+?[\d\s().-]+$').hasMatch(valor))
          erros.add('Revise o telefone: $valor');
      }
      novo = {
        'tipo_doc': fTipo.valor ?? 'CNPJ',
        'documento': fDoc.text,
        'IM': _cima(fIm.text),
        'xNome': _cima(fNome.text),
        'contatos': [for (final r in preenchidos) r.mapa()],
        'email': valorPrincipal(emails).trim().toLowerCase(),
        'fone': valorPrincipal(telefones),
        'telefones': telefones.map((r) => r.valor.text).toList(),
        'emails': emails.map((r) => r.valor.text.trim().toLowerCase()).toList(),
        'observacoes_telefones': telefones
            .map((r) => r.observacao.text)
            .toList(),
        'observacoes_emails': emails.map((r) => r.observacao.text).toList(),
        'telefone_principal': principal(telefones) < 0
            ? 0
            : principal(telefones),
        'email_principal': principal(emails) < 0 ? 0 : principal(emails),
        'ordem_contatos': [
          for (final r in informacoes)
            if (r.valor.text.trim().isNotEmpty) r.categoria,
        ],
        'observacoes_gerais': fObservacoesGerais.text,
        'cMun': fCmun.text.trim(),
        'CEP': fCep.text,
        'xLgr': _cima(fLgr.text),
        'nro': _cima(fNro.text),
        'xCpl': _cima(fCpl.text),
        'xBairro': _cima(fBairro.text),
        'xCidade': _cima(fCidade.text),
        'UF': _cima(fUf.text),
      };
      erros.addAll(
        ja<List>('cadastro.tomador_validate', {'form': novo}).cast<String>(),
      );
    }
    if (comServ) {
      if (temServico()) servicos[slugAtual] = coletarServico();
      // O cadastro guarda o preenchimento parcial; a emissão faz a validação fiscal completa.
    }
    if (erros.isNotEmpty) {
      app.toast('Corrija: ${erros.join('; ')}', erro: true);
      return;
    }
    if (mudarGrupo && novo != null) {
      // Documento já cadastrado? NÃO substitui em silêncio — manda editar o existente.
      final docNovo = soDoc(novo['documento'] as String);
      final existe = ja<bool>('cadastro.tomador_cadastrado', {
        'prestador': p,
        'tomador': docNovo,
      });
      if (existe && (!jaSalvo || docSalvo != docNovo)) {
        final x =
            (jaMapa('cadastro.get_tomador_form', {
                  'prestador': p,
                  'tomador': docNovo,
                })['xNome']
                as String?) ??
            '';
        app.toast(
          'Este ${novo['tipo_doc']} já está cadastrado (${x.isEmpty ? docNovo : x}). '
          'Edite o cliente existente na lista.',
          erro: true,
        );
        return;
      }
    }
    var doc = docSalvo;
    try {
      if (novo != null) {
        // Documento mudou na edição? Move o cadastro (e o grupo) antes de salvar.
        if (jaSalvo &&
            docSalvo.isNotEmpty &&
            docSalvo != soDoc(novo['documento'] as String)) {
          ja<Object?>('cadastro.rename_tomador', {
            'prestador': p,
            'antigo': docSalvo,
            'novo': novo['documento'],
          });
        }
        ja<Object?>('cadastro.save_tomador_form', {
          'prestador': p,
          'form': novo,
        });
        doc = soDoc(novo['documento'] as String);
      }
      if (comServ) {
        for (final s in removidos) {
          ja<Object?>('cadastro.delete_servico', {
            'prestador': p,
            'tomador': doc,
            'servico': s,
          });
        }
        for (final s in ordem) {
          ja<Object?>('cadastro.save_servico', {
            'prestador': p,
            'tomador': doc,
            'servico': s,
            'form': servicos[s],
          });
          novos.remove(s); // agora existe no banco
        }
      }
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    if (novo != null) {
      try {
        ja<Object?>('cadastro.set_tomador_grupo', {
          'prestador': p,
          'tomador': novo['documento'],
          'grupo': grupo,
        });
        grupoAtual = grupo;
      } catch (e) {
        app.toast('$e', erro: true);
        return;
      }
    }
    final nomeCli = novo != null ? novo['xNome'] as String : _cima(fNome.text);
    registrar(
      'Cliente ${jaSalvo ? 'editado' : 'criado'}: $nomeCli ($doc) prestador=$p — '
      '${[if (comDados) 'dados', if (comServ) '${ordem.length} serviço(s)'].join(' + ')}',
    );
    // NÃO fecha a janela: mantém a tela/serviço atual, apenas re-trava o que foi salvo.
    jaSalvo = true;
    docSalvo = doc;
    if (comDados) {
      informacoes.removeWhere((r) => r.valor.text.trim().isEmpty);
      acertarPrincipais();
      editaDados = false;
    }
    if (comServ) {
      removidos.clear();
      editaServ = false;
      ddServico.opcoes = opcoesDeServico(); // nomes podem ter mudado
      ddServico.por(slugAtual.isEmpty ? null : slugAtual);
      ddServico.avisar();
    }
    acertar();
    app.toast(
      comDados ? 'Cliente $nomeCli salvo.' : 'Serviços de $nomeCli salvos.',
    );
    if (comDados)
      app.clientesMudaram(); // o cadastro mudou: as listas são refeitas
    // Cliente selecionado na EMITIR? Recarrega lá a lista de serviços e o serviço carregado.
    EmitirState.atual?.clienteSalvo(doc);
    app.atualizar();
  }

  // ---- desenho ----------------------------------------------------------------------------------- //
  Widget campo(
    TextEditingController c,
    String rotulo,
    Tamanho tamanho, {
    required bool travado,
    String? rotuloNaBorda,
    String Function(String)? mascara,
    int? maximo,
    bool ocultarContador = false,
    bool pct = false,
    String? dica,
    String? dicaMouse,
    ValueChanged<String>? aoMudar,
  }) => CampoTexto(
    controle: c,
    rotulo: rotulo,
    rotuloNaBorda: rotuloNaBorda,
    largura: tamanho.largura!,
    altura: tamanho.altura,
    desabilitado: travado,
    maximo: maximo,
    ocultarContador: ocultarContador,
    dica: dica,
    dicaMouse: dicaMouse,
    textoSufixo: pct ? const Text('%') : null,
    mascara: mascara ?? (pct ? pctVirgula : null),
    aoMudar: aoMudar,
    idLayout: tamanho.id,
  );

  String maiusculas(String s) => s.toUpperCase();
  String Function(String) soNumeros(int max) => (s) {
    final dig = soDigitos(s);
    return dig.length > max ? dig.substring(0, max) : dig;
  };

  Widget lista(
    Suspensa s,
    String rotulo,
    Tamanho tamanho, {
    required bool travado,
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
    larguraMenu: larguraMenu,
    aoSelecionar: aoSelecionar,
    idLayout: tamanho.id,
  );

  Widget negrito(String t) => Tx(
    t,
    tam: Letra.subtitulo,
    peso: FontWeight.bold,
    largura: TamanhosDadosCliente.rotuloT.largura,
    altura: TamanhosDadosCliente.rotuloT.altura,
    idLayout: 'TamanhosDadosCliente.rotuloT:$t',
  );

  Widget painel(Widget conteudo) =>
      Ct(padding: const EdgeInsets.fromLTRB(4, 18, 4, 0), child: conteudo);

  Widget abaDados() {
    final t = !editaDados;
    final ehCpf = (fTipo.valor ?? 'CNPJ') == 'CPF';
    return col(
      [
        negrito('Identificação'),
        lin(
          [
            ListaSuspensa(
              estado: fTipo,
              rotulo: 'Tipo',
              largura: TamanhosDadosCliente.campoTipo.largura!,
              desabilitado: t,
              aoSelecionar: (_) {
                fDoc.text = mascaraDocumento(fDoc.text, fTipo.valor);
                acertar();
              },
              altura: TamanhosDadosCliente.campoTipo.altura,
              idLayout: 'TamanhosDadosCliente.campoTipo',
            ),
            campo(
              fDoc,
              'Documento',
              TamanhosDadosCliente.campoDocumento,
              travado: t,
              mascara: (s) => mascaraDocumento(s, fTipo.valor),
            ),
            // Não existe consulta pública de CPF (só de CNPJ): com Tipo=CPF o botão de
            // busca fica apagado, com a dica explicando.
            BotaoBusca(
              ehCpf
                  ? 'Busca automática só existe para CNPJ (CPF não tem consulta pública)'
                  : 'Buscar CNPJ',
              'cnpj_find.svg',
              () => buscarDados(true),
              inerte: t || ehCpf,
              largura: TamanhosDadosCliente
                  .botaoEhCpfBuscaAutomaticaSoExisteParaCNPJCPF
                  .largura,
              altura: TamanhosDadosCliente
                  .botaoEhCpfBuscaAutomaticaSoExisteParaCNPJCPF
                  .altura,
              idLayout:
                  'TamanhosDadosCliente.botaoEhCpfBuscaAutomaticaSoExisteParaCNPJCPF',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.1',
        ),
        lin(
          [
            campo(
              fNome,
              'Nome / Razão social',
              TamanhosDadosCliente.campoNomeRazaoSocial,
              travado: t,
              mascara: maiusculas,
            ),
            campo(
              fIm,
              'Inscrição municipal',
              TamanhosDadosCliente.campoInscricaoMunicipal,
              travado: t,
              mascara: maiusculas,
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.2',
        ),
        ListaSuspensa(
          estado: fGrupo,
          rotulo: 'Grupo',
          largura: TamanhosDadosCliente.campoGrupo.largura!,
          desabilitado: t,
          altura: TamanhosDadosCliente.campoGrupo.altura,
          idLayout: 'TamanhosDadosCliente.campoGrupo',
        ),
        divisor(),
        negrito('Endereço'),
        lin(
          [
            campo(
              fCep,
              'CEP',
              TamanhosDadosCliente.campoCEP,
              travado: t,
              mascara: soNumeros(8),
            ),
            BotaoBusca(
              'Buscar CEP',
              'cep_find.svg',
              () => buscarDados(false),
              inerte: t,
              largura: TamanhosDadosCliente.botaoBuscarCEP.largura,
              altura: TamanhosDadosCliente.botaoBuscarCEP.altura,
              idLayout: 'TamanhosDadosCliente.botaoBuscarCEP',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.4',
        ),
        lin(
          [
            campo(
              fLgr,
              'Logradouro',
              TamanhosDadosCliente.campoLogradouro,
              travado: t,
              mascara: maiusculas,
            ),
            campo(
              fNro,
              'Número',
              TamanhosDadosCliente.campoNumero,
              travado: t,
              mascara: maiusculas,
            ),
            campo(
              fCpl,
              'Complemento',
              TamanhosDadosCliente.campoComplemento,
              travado: t,
              mascara: maiusculas,
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.5',
        ),
        lin(
          [
            // Cidade: campo + SUGESTÕES sob demanda (2 letras ou mais filtram a lista do
            // IBGE em memória e mostram até 8; clicar preenche Cidade/UF/cMun).
            campo(
              fCidade,
              'Cidade',
              TamanhosDadosCliente.campoCidade,
              travado: t,
              mascara: _cima,
              aoMudar: (v) {
                final termo = termosBusca(v).join(' ');
                final achou = <(String, String, String)>[];
                if (termo.length >= 2) {
                  for (final (norm, cod, nome, uf) in munBusca) {
                    // 1º: começa com o termo
                    if (norm.startsWith(termo)) {
                      achou.add((cod, nome, uf));
                      if (achou.length >= 8) break;
                    }
                  }
                  if (achou.length < 8) {
                    for (final (norm, cod, nome, uf) in munBusca) {
                      // 2º: contém o termo
                      if (norm.contains(termo) && !norm.startsWith(termo)) {
                        achou.add((cod, nome, uf));
                        if (achou.length >= 8) break;
                      }
                    }
                  }
                }
                sugestoes = achou;
                d.atualizar();
              },
            ),
            campo(
              fUf,
              'UF',
              TamanhosDadosCliente.campoUF,
              travado: t,
              mascara: (s) {
                final u = _cima(s);
                return u.length > 2 ? u.substring(0, 2) : u;
              },
            ),
            campo(
              fCmun,
              'cMun (IBGE)',
              TamanhosDadosCliente.campoCMunIBGE,
              travado: t,
              mascara: soNumeros(7),
            ),
            campo(
              fBairro,
              'Bairro',
              TamanhosDadosCliente.campoBairro,
              travado: t,
              mascara: maiusculas,
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.6',
        ),
        if (sugestoes.isNotEmpty)
          Ct(
            largura: 340,
            padding: const EdgeInsets.all(4),
            borda: Border.all(color: Colors.grey.shade300, width: 1),
            raio: BorderRadius.circular(8),
            cor: Colors.white,
            child: col(
              [
                for (final (cod, nome, uf) in sugestoes)
                  Botao.texto(
                    null,
                    filho: Tx(
                      '$nome ($uf)',
                      tam: Letra.texto,
                      largura: TamanhosDadosCliente.rotuloNomeUf.largura,
                      altura: TamanhosDadosCliente.rotuloNomeUf.altura,
                      idLayout: 'TamanhosDadosCliente.rotuloNomeUf',
                    ),
                    aoClicar: () {
                      final (n, u) = munPorCod[cod]!;
                      fCidade.text = _cima(n);
                      fUf.text = u;
                      fCmun.text = cod;
                      sugestoes = [];
                      d.atualizar();
                    },
                    largura: TamanhosDadosCliente.botaoNull.largura,
                    altura: TamanhosDadosCliente.botaoNull.altura,
                    idLayout: 'TamanhosDadosCliente.botaoNull',
                  ),
              ],
              espaco: 0,
              justa: true,
              idLayout: 'Grupo.cliente_form.col.3',
            ),
          ),
        divisor(),
        negrito('Informações / contatos'),
        Tx(
          'A estrela indica o contato principal de cada tipo usado na NFS-e.',
          tam: Letra.apoio,
        ),
        Padding(
          padding: const EdgeInsets.only(right: 32),
          child: LayoutBuilder(
            builder: (context, limites) {
              final largura = limites.maxWidth.clamp(560.0, double.infinity);
              final disponivel = largura - 152;
              final larguras = [152.0, disponivel * .45, disponivel * .55];
              Widget celula(int i, Widget filho) => SizedBox(
                width: larguras[i],
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: filho,
                ),
              );
              final tabela = Theme(
                data: Theme.of(context).copyWith(
                  dividerTheme: const DividerThemeData(
                    color: Colors.transparent,
                  ),
                ),
                child: DataTable(
                  key: const ValueKey('Cliente.contatos.tabela'),
                  showCheckboxColumn: false,
                  horizontalMargin: 0,
                  columnSpacing: 0,
                  headingRowHeight: 32,
                  dataRowMinHeight: 40,
                  dataRowMaxHeight: 40,
                  dividerThickness: 0,
                  border: SeparadoresTabela(
                    grade: true,
                    densidade: MediaQuery.devicePixelRatioOf(context),
                  ),
                  headingRowColor: WidgetStatePropertyAll(
                    Theme.of(context).colorScheme.surfaceContainerLow,
                  ),
                  columns: [
                    for (final (i, titulo) in [
                      'Tipo',
                      'Valor',
                      'Observações',
                    ].indexed)
                      DataColumn(
                        label: celula(
                          i,
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Center(
                              child: Tx(
                                titulo,
                                tam: 13,
                                peso: FontWeight.bold,
                                idLayout: 'Cliente.contato.cabecalho:$titulo',
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                  rows: [
                    for (final (i, r) in informacoes.indexed)
                      DataRow(
                        key: ObjectKey(r),
                        cells: [
                          DataCell(
                            celula(
                              0,
                              Row(
                                children: [
                                  if (r.categoria != 'outros')
                                    BotaoIcone(
                                      r.principal
                                          ? Icons.star
                                          : Icons.star_outline,
                                      largura: 32,
                                      altura: 32,
                                      padding: EdgeInsets.zero,
                                      restricoes: const BoxConstraints.tightFor(
                                        width: 32,
                                        height: 32,
                                      ),
                                      estilo: const ButtonStyle(
                                        fixedSize: WidgetStatePropertyAll(
                                          Size.square(32),
                                        ),
                                        minimumSize: WidgetStatePropertyAll(
                                          Size.zero,
                                        ),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        alignment: Alignment.center,
                                      ),
                                      dica: r.principal
                                          ? 'Contato principal'
                                          : 'Usar como principal',
                                      cor: r.principal
                                          ? Colors.orange.shade700
                                          : null,
                                      desabilitado: t || r.principal,
                                      aoClicar: () {
                                        for (final outro in informacoes.where(
                                          (o) => o.categoria == r.categoria,
                                        )) {
                                          outro.principal = identical(outro, r);
                                        }
                                        d.atualizar();
                                      },
                                    ),
                                  if (r.categoria == 'outros')
                                    const SizedBox(width: 32),
                                  Expanded(
                                    child: ListaSuspensa(
                                      estado: r.tipo,
                                      rotulo: 'Tipo',
                                      emTabela: true,
                                      largura: larguras[0] - 40,
                                      desabilitado: t,
                                      idLayout: 'Cliente.contato.tipo:$i',
                                      aoSelecionar: (valor) {
                                        if (valor == 'personalizar') {
                                          r.tipo.por(
                                            r.personalizado.isEmpty
                                                ? r.categoria
                                                : 'personalizado',
                                          );
                                          r.tipo.avisar();
                                          personalizarContato(r);
                                          return;
                                        }
                                        if (valor == 'personalizado') return;
                                        final anterior = r.categoria;
                                        r.definirTipo(valor ?? 'telefone');
                                        if (anterior != r.categoria) {
                                          r.principal = false;
                                        }
                                        acertarPrincipais();
                                        d.atualizar();
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          DataCell(
                            celula(
                              1,
                              CampoTexto(
                                controle: r.valor,
                                desabilitado: t,
                                rotulo: 'Valor',
                                emTabela: true,
                                largura: larguras[1] - 8,
                                idLayout: 'Cliente.contato.valor:$i',
                                estilo: TextStyle(
                                  color: r.principal
                                      ? Colors.orange.shade700
                                      : null,
                                ),
                              ),
                            ),
                          ),
                          DataCell(
                            celula(
                              2,
                              CampoTexto(
                                controle: r.observacao,
                                desabilitado: t,
                                rotulo: 'Observações',
                                emTabela: true,
                                largura: larguras[2] - 8,
                                idLayout: 'Cliente.contato.observacao:$i',
                                estilo: TextStyle(
                                  color: r.principal
                                      ? Colors.orange.shade700
                                      : null,
                                ),
                                sufixo: BotaoIcone(
                                  Icons.remove_circle_outline,
                                  dica: 'Remover contato',
                                  desabilitado: t,
                                  aoClicar: () => removerContato(r),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              );
              return largura > limites.maxWidth
                  ? Rolagem(
                      direcao: Axis.horizontal,
                      justa: true,
                      child: tabela,
                    )
                  : tabela;
            },
          ),
        ),
        if (!t)
          Botao.texto(
            'Adicionar contato',
            icone: Icons.add,
            aoClicar: () {
              if (informacoes.any(
                (c) => !c.principal && c.valor.text.trim().isEmpty,
              )) {
                app.toast(
                  'Preencha o contato adicional vazio antes de adicionar outro.',
                  erro: true,
                );
                return;
              }
              informacoes.add(_ContatoCliente(d, 'telefone', '', '', false));
              acertarPrincipais();
              d.atualizar();
            },
          ),
        Padding(
          padding: const EdgeInsets.only(right: 32),
          child: CampoTexto(
            controle: fObservacoesGerais,
            rotulo: 'Observações',
            largura: double.infinity,
            desabilitado: t,
            variasLinhas: true,
            minLinhas: 3,
            maxLinhas: 3,
            idLayout: 'Cliente.observacoesGerais',
          ),
        ),
      ],
      rolar: true,
      justa: true,
      idLayout: 'Grupo.cliente_form.col.2',
    );
  }

  Widget abaServico() {
    final t = !editaServ || !temServico();
    final semCalc = (ddCst.valor ?? '01') == '00';
    final naoRetido = (ddRet.valor ?? '0') == '0';
    Widget catalogo(Catalogo c, String rotulo) => lista(
      c.dd,
      rotulo,
      TamanhosServicosTributos.campoRotulo,
      travado: t,
      larguraMenu: larguraMenuCatalogo,
      aoSelecionar: (v) {
        c.por(v ?? '');
        c.dd.avisar();
        if (identical(c, fTribNac) &&
            eImovel() &&
            fLocMun.text.trim().isNotEmpty) {
          fLocPrest.text = fLocMun.text.trim();
        }
        d.atualizar(); // o código de tributação decide se os blocos de locação aparecem
      },
    );
    final cinza = Colors.grey.shade600;
    // Limite de tamanho SEM o contador embaixo do campo (ele desalinharia a linha).
    String Function(String) ate(int n, {bool maiusculo = false}) => (s) {
      final v = maiusculo ? s.toUpperCase() : s;
      return v.length > n ? v.substring(0, n) : v;
    };
    // ---- locação de imóvel: uma faixa por unidade, com as parcelas que saem da base ---------- //
    List<Widget> blocoImovel({required bool locacao}) => [
      divisor(),
      negrito(locacao ? 'Locação de imóvel' : 'Condomínio'),
      Tx(
        locacao
            ? 'Leiaute novo da NFS-e (NT 009). O valor total do aluguel sai do valor da nota e do '
                  'percentual de copropriedade (100% quando há um só locador).'
            : 'Leiaute novo da NFS-e (NT 009). O valor da nota é a soma das cobranças abaixo; os '
                  'descontos da nota, a soma dos descontos abaixo.',
        tam: Letra.apoio,
        cor: cinza,
        largura: TamanhosServicosTributos
            .rotuloLocacaoLeiauteNovoDaNFSENT009
            .largura,
        altura:
            TamanhosServicosTributos.rotuloLocacaoLeiauteNovoDaNFSENT009.altura,
        idLayout:
            'TamanhosServicosTributos.rotuloLocacaoLeiauteNovoDaNFSENT009',
      ),
      lin(
        [
          campo(
            fLocMun,
            'Município do imóvel (IBGE)',
            TamanhosServicosTributos.campoMunicipioDoImovelIBGE,
            travado: t,
            mascara: soNumeros(7),
            aoMudar: (_) {
              if (eImovel()) fLocPrest.text = fLocMun.text.trim();
            },
          ),
          if (locacao)
            campo(
              fLocCoprop,
              'Copropriedade',
              TamanhosServicosTributos.campoCopropriedade,
              travado: t,
              pct: true,
              mascara: copropriedadeVirgula,
              dica: '100,00',
              dicaMouse:
                  'Participação do locador: de 0 a 100%, com até duas casas decimais. Um único locador: 100%.',
            ),
          lin(
            [
              CampoTexto(
                controle: locacao ? fLocVenc : fCondVenc,
                rotulo: 'Vencimento original (dd/mm/aaaa)',
                largura: TamanhosServicosTributos
                    .campoVencimentoOriginalAAAAMMDD
                    .largura,
                altura: TamanhosServicosTributos
                    .campoVencimentoOriginalAAAAMMDD
                    .altura,
                desabilitado: t || vencAutomatico,
                somenteLeitura: true,
                sufixo: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ((locacao ? fLocVenc : fCondVenc).text.isNotEmpty &&
                        !vencAutomatico)
                      BotaoIcone(
                        Icons.clear,
                        dica: 'Limpar vencimento',
                        desabilitado: t,
                        aoClicar: () {
                          (locacao ? fLocVenc : fCondVenc).clear();
                          d.atualizar();
                        },
                      ),
                    BotaoIcone(
                      Icons.calendar_month,
                      dica: 'Escolher no calendário',
                      desabilitado: t || vencAutomatico,
                      aoClicar: () => escolherVencimento(locacao),
                    ),
                  ],
                ),
                idLayout:
                    'TamanhosServicosTributos.campoVencimentoOriginalAAAAMMDD',
                dicaMouse: locacao
                    ? (vencAutomatico
                          ? 'Vencimento automático pela competência do aluguel. Esta é uma prévia para o mês atual; a emissão usa a competência efetiva.'
                          : 'Data limite original para pagar este aluguel. Ex.: aluguel de outubro vence em 10/11. Não é o fim do contrato.')
                    : 'Data limite original para pagar esta cobrança do condomínio.',
              ),
              Botao.contorno(
                'Config. venc.',
                largura: 142,
                icone: Icons.settings,
                desabilitado: t,
                aoClicar: configurarVencimento,
                idLayout: 'Vencimento.abrirConfiguracao',
              ),
            ],
            justa: true,
            idLayout: 'Vencimento.campoEConfiguracao',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.cliente_form.lin.7',
      ),
      for (final (i, u) in unidades.indexed) ...[
        lin([
          negrito('Unidade ${i + 1}'),
          Botao.texto(
            'Remover unidade',
            icone: Icons.delete_outline,
            desabilitado: t,
            aoClicar: () {
              unidades.removeAt(i);
              d.atualizar();
            },
            largura: TamanhosServicosTributos.botaoRemoverUnidade.largura,
            altura: TamanhosServicosTributos.botaoRemoverUnidade.altura,
            idLayout: 'TamanhosServicosTributos.botaoRemoverUnidade',
          ),
        ], idLayout: 'Grupo.cliente_form.lin.8'),
        Tx(
          'Identifique a unidade pelo código CIB ou pelo endereço (um dos dois).',
          tam: Letra.apoio,
          cor: cinza,
          largura: TamanhosServicosTributos
              .rotuloIdentifiqueAUnidadePeloCodigoCIBOuPelo
              .largura,
          altura: TamanhosServicosTributos
              .rotuloIdentifiqueAUnidadePeloCodigoCIBOuPelo
              .altura,
          idLayout:
              'TamanhosServicosTributos.rotuloIdentifiqueAUnidadePeloCodigoCIBOuPelo',
        ),
        lin(
          [
            campo(
              u.insc,
              'Inscrição imobiliária (IPTU)',
              TamanhosServicosTributos.campoInscricaoImobiliariaIPTU,
              travado: t,
              mascara: ate(30),
            ),
            campo(
              u.cib,
              'Código CIB',
              TamanhosServicosTributos.campoCodigoCIB,
              travado: t,
              dicaMouse:
                  'Identificador nacional do imóvel no Cadastro Imobiliário Brasileiro (7 caracteres + dígito verificador, ex.: A3N8Z4F-Y). Não é a matrícula nem a inscrição do IPTU. Se não tiver CIB, use o endereço.',
              // 9 = os 8 caracteres e o hífen opcional da máscara AAAAAAA-D; o núcleo remove o hífen.
              mascara: ate(9, maiusculo: true),
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.9',
        ),
        lin(
          [
            campo(
              u.cep,
              'CEP',
              TamanhosServicosTributos.campoCEP,
              travado: t,
              mascara: soNumeros(8),
            ),
            campo(
              u.lgr,
              'Logradouro',
              TamanhosServicosTributos.campoLogradouro,
              travado: t,
              mascara: maiusculas,
            ),
            campo(
              u.nro,
              'Número',
              TamanhosServicosTributos.campoNumero,
              travado: t,
            ),
            campo(
              u.cpl,
              'Complemento',
              TamanhosServicosTributos.campoComplemento,
              travado: t,
              mascara: maiusculas,
            ),
            campo(
              u.bairro,
              'Bairro',
              TamanhosServicosTributos.campoBairro,
              travado: t,
              mascara: maiusculas,
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.10',
        ),
        if (locacao)
          for (final (j, a) in u.ajustes.indexed)
            lin(
              [
                lista(
                  a.tipo,
                  'Parcela fora da base do IBS/CBS',
                  TamanhosServicosTributos.campoParcelaForaDaBaseDoIBSCBS,
                  travado: t,
                  aoSelecionar: (_) => d.atualizar(),
                ),
                if (a.tipo.valor == '99')
                  campo(
                    a.descricao,
                    'Descrição da parcela',
                    TamanhosServicosTributos.campoDescricaoDaParcela,
                    travado: t,
                    mascara: ate(150),
                  ),
                campo(
                  a.valor,
                  r'Valor (R$)',
                  TamanhosServicosTributos.campoValorR,
                  travado: t,
                  mascara: pctVirgula,
                ),
                Botao.texto(
                  'Remover',
                  icone: Icons.delete_outline,
                  desabilitado: t,
                  aoClicar: () {
                    u.ajustes.removeAt(j);
                    d.atualizar();
                  },
                  largura: TamanhosServicosTributos.botaoRemover.largura,
                  altura: TamanhosServicosTributos.botaoRemover.altura,
                  idLayout: 'TamanhosServicosTributos.botaoRemover',
                ),
              ],
              quebra: true,
              idLayout: 'Grupo.cliente_form.lin.11',
            ),
        if (locacao)
          Botao.texto(
            'Parcela fora da base (IPTU, condomínio…)',
            icone: Icons.add,
            desabilitado: t || u.ajustes.length >= 1000,
            aoClicar: () {
              u.ajustes.add(_Ajuste(d, const {}));
              d.atualizar();
            },
            largura: TamanhosServicosTributos
                .botaoParcelaForaDaBaseIPTUCondominio
                .largura,
            altura: TamanhosServicosTributos
                .botaoParcelaForaDaBaseIPTUCondominio
                .altura,
            idLayout:
                'TamanhosServicosTributos.botaoParcelaForaDaBaseIPTUCondominio',
          ),
      ],
      Botao.contorno(
        'Adicionar unidade',
        icone: Icons.add,
        desabilitado: t || unidades.length >= 99,
        aoClicar: () {
          unidades.add(_Unidade(d, const {}));
          d.atualizar();
        },
        largura: TamanhosServicosTributos.botaoAdicionarUnidade.largura,
        altura: TamanhosServicosTributos.botaoAdicionarUnidade.altura,
        idLayout: 'TamanhosServicosTributos.botaoAdicionarUnidade',
      ),
    ];
    // ---- condomínio: cobranças (a soma é o valor da nota) e descontos ------------------------ //
    List<Widget> blocoCobrancas() => [
      negrito('Cobranças'),
      for (final (i, x) in cobrancas.indexed) ...[
        lin(
          [
            lista(
              x.tipo,
              'Tipo de cobrança',
              TamanhosServicosTributos.campoTipoDeCobranca,
              travado: t,
              aoSelecionar: (_) {
                x.acertarDetalhes();
                d.atualizar();
              },
            ),
            if (x.tipo.valor == '99')
              campo(
                x.descricao,
                'Descrição da cobrança',
                TamanhosServicosTributos.campoDescricaoDaCobranca,
                travado: t,
                mascara: ate(150),
              ),
            // Com detalhamento, o valor da cobrança é a soma dos itens: só se vê.
            campo(
              x.valor,
              r'Valor (R$)',
              TamanhosServicosTributos.campoValorR2,
              travado: t || x.detalhes.isNotEmpty,
              mascara: pctVirgula,
              aoMudar: (_) => d.atualizar(),
            ),
            comDica(
              'Opcional: reparte esta cobrança em itens (energia, água, IPTU…). O valor da cobrança '
              'passa a ser a soma deles.',
              Botao.texto(
                'Detalhar',
                icone: Icons.playlist_add,
                desabilitado: t || x.detalhes.length >= 20,
                aoClicar: () {
                  x.detalhes.add(_Detalhe(d, const {}, x.tipo.valor));
                  d.atualizar();
                },
                largura: TamanhosServicosTributos.botaoDetalhar.largura,
                altura: TamanhosServicosTributos.botaoDetalhar.altura,
                idLayout: 'TamanhosServicosTributos.botaoDetalhar',
              ),
            ),
            Botao.texto(
              'Remover',
              icone: Icons.delete_outline,
              desabilitado: t,
              aoClicar: () {
                cobrancas.removeAt(i);
                d.atualizar();
              },
              largura: TamanhosServicosTributos.botaoRemover2.largura,
              altura: TamanhosServicosTributos.botaoRemover2.altura,
              idLayout: 'TamanhosServicosTributos.botaoRemover2',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.12',
        ),
        for (final (j, y) in x.detalhes.indexed)
          Ct(
            padding: const EdgeInsets.only(left: 28),
            child: lin(
              [
                lista(
                  y.tipo,
                  'Tipo de detalhe',
                  TamanhosServicosTributos.campoTipoDeDetalhe,
                  travado: t,
                  aoSelecionar: (_) => d.atualizar(),
                ),
                if (y.tipo.valor == '999')
                  campo(
                    y.descricao,
                    'Descrição do detalhe',
                    TamanhosServicosTributos.campoDescricaoDoDetalhe,
                    travado: t,
                    mascara: ate(150),
                  ),
                campo(
                  y.valor,
                  r'Valor do item (R$)',
                  TamanhosServicosTributos.campoValorDoItemR,
                  travado: t,
                  mascara: pctVirgula,
                  aoMudar: (_) {
                    x.somar();
                    d.atualizar();
                  },
                ),
                Botao.texto(
                  'Remover item',
                  icone: Icons.delete_outline,
                  desabilitado: t,
                  aoClicar: () {
                    x.detalhes.removeAt(j);
                    x.somar();
                    d.atualizar();
                  },
                  largura: TamanhosServicosTributos.botaoRemoverItem.largura,
                  altura: TamanhosServicosTributos.botaoRemoverItem.altura,
                  idLayout: 'TamanhosServicosTributos.botaoRemoverItem',
                ),
              ],
              quebra: true,
              idLayout: 'Grupo.cliente_form.lin.13',
            ),
          ),
      ],
      lin(
        [
          Botao.contorno(
            'Adicionar cobrança',
            icone: Icons.add,
            desabilitado: t || cobrancas.length >= 20,
            aoClicar: () {
              cobrancas.add(_Cobranca(d, const {}));
              d.atualizar();
            },
            largura: TamanhosServicosTributos.botaoAdicionarCobranca.largura,
            altura: TamanhosServicosTributos.botaoAdicionarCobranca.altura,
            idLayout: 'TamanhosServicosTributos.botaoAdicionarCobranca',
          ),
          Tx(
            'Valor da nota: ${decimalBrl(_somaDe(cobrancas.map((x) => x.valor.text)))}',
            tam: Letra.apoio,
            cor: cinza,
            largura: TamanhosServicosTributos
                .rotuloValorDaNotaDecimalBrlSomaDeCobrancasMapX
                .largura,
            altura: TamanhosServicosTributos
                .rotuloValorDaNotaDecimalBrlSomaDeCobrancasMapX
                .altura,
            idLayout:
                'TamanhosServicosTributos.rotuloValorDaNotaDecimalBrlSomaDeCobrancasMapX',
          ),
        ],
        quebra: true,
        idLayout: 'Grupo.cliente_form.lin.14',
      ),
      negrito('Descontos do condomínio'),
      for (final (i, x) in descontosCond.indexed)
        lin(
          [
            lista(
              x.tipo,
              'Tipo de desconto',
              TamanhosServicosTributos.campoTipoDeDesconto,
              travado: t,
            ),
            campo(
              x.descricao,
              'Descrição do desconto',
              TamanhosServicosTributos.campoDescricaoDoDesconto,
              travado: t,
              mascara: ate(150),
            ),
            campo(
              x.valor,
              r'Valor (R$)',
              TamanhosServicosTributos.campoValorR3,
              travado: t,
              mascara: pctVirgula,
            ),
            Botao.texto(
              'Remover',
              icone: Icons.delete_outline,
              desabilitado: t,
              aoClicar: () {
                descontosCond.removeAt(i);
                d.atualizar();
              },
              largura: TamanhosServicosTributos.botaoRemover3.largura,
              altura: TamanhosServicosTributos.botaoRemover3.altura,
              idLayout: 'TamanhosServicosTributos.botaoRemover3',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.15',
        ),
      Botao.contorno(
        'Adicionar desconto',
        icone: Icons.add,
        desabilitado: t || descontosCond.length >= 10,
        aoClicar: () {
          descontosCond.add(_DescontoCond(d, const {}));
          d.atualizar();
        },
        largura: TamanhosServicosTributos.botaoAdicionarDesconto.largura,
        altura: TamanhosServicosTributos.botaoAdicionarDesconto.altura,
        idLayout: 'TamanhosServicosTributos.botaoAdicionarDesconto',
      ),
    ];
    // ---- locação de bens móveis: uma linha por bem ------------------------------------------- //
    List<Widget> blocoBens() => [
      divisor(),
      negrito('Bens móveis locados'),
      Tx(
        'Leiaute novo da NFS-e (NT 009). Informe cada bem locado.',
        tam: Letra.apoio,
        cor: cinza,
        largura: TamanhosServicosTributos
            .rotuloLeiauteNovoDaNFSENT009Informe
            .largura,
        altura:
            TamanhosServicosTributos.rotuloLeiauteNovoDaNFSENT009Informe.altura,
        idLayout:
            'TamanhosServicosTributos.rotuloLeiauteNovoDaNFSENT009Informe',
      ),
      for (final (i, x) in bens.indexed)
        lin(
          [
            campo(
              x.ncm,
              'NCM',
              TamanhosServicosTributos.campoNCM,
              travado: t,
              mascara: soNumeros(8),
            ),
            campo(
              x.descricao,
              'Descrição do bem',
              TamanhosServicosTributos.campoDescricaoDoBem,
              travado: t,
              mascara: ate(150),
            ),
            campo(
              x.quantidade,
              'Quantidade',
              TamanhosServicosTributos.campoQuantidade,
              travado: t,
              mascara: soNumeros(3),
            ),
            Botao.texto(
              'Remover',
              icone: Icons.delete_outline,
              desabilitado: t,
              aoClicar: () {
                bens.removeAt(i);
                d.atualizar();
              },
              largura: TamanhosServicosTributos.botaoRemover4.largura,
              altura: TamanhosServicosTributos.botaoRemover4.altura,
              idLayout: 'TamanhosServicosTributos.botaoRemover4',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.16',
        ),
      Botao.contorno(
        'Adicionar bem',
        icone: Icons.add,
        desabilitado: t || bens.length >= 1000,
        aoClicar: () {
          bens.add(_Bem(d, const {}));
          d.atualizar();
        },
        largura: TamanhosServicosTributos.botaoAdicionarBem.largura,
        altura: TamanhosServicosTributos.botaoAdicionarBem.altura,
        idLayout: 'TamanhosServicosTributos.botaoAdicionarBem',
      ),
    ];
    Widget pct(
      TextEditingController c,
      String rotulo,
      String herdado, {
      bool travado = false,
    }) => campo(
      c,
      rotulo,
      TamanhosServicosTributos.campoRotulo2,
      travado: t || travado,
      pct: true,
      // a dica é o valor herdado do prestador
      dica: pctVirgula(trib[herdado] ?? ''),
      aoMudar: (_) => acertar(),
    );
    return col(
      [
        // Fora de edição: o seletor do serviço e, encostado à DIREITA, o "Novo serviço". Com o
        // serviço em edição os dois somem (trocar de serviço ou criar outro no meio da edição
        // confundia) e a aba começa pelo nome do serviço; voltam ao salvar ou cancelar.
        if (!editaServ)
          lin(
            [
              Ct(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                child: ListaSuspensa(
                  estado: ddServico,
                  rotulo: 'Serviço',
                  desabilitado: !temServico(),
                  largura: TamanhosServicosTributos.campoServico.largura!,
                  aoSelecionar: (escolha) {
                    if (escolha != null) trocarPara(escolha);
                  },
                  altura: TamanhosServicosTributos.campoServico.altura,
                  idLayout: 'TamanhosServicosTributos.campoServico',
                ),
              ),
              const Expanded(child: SizedBox()),
              Ct(
                padding: const EdgeInsets.fromLTRB(0, 0, 18, 0),
                child: Botao.contorno(
                  'Novo serviço',
                  icone: Icons.add,
                  aoClicar: novoServico,
                  largura: TamanhosServicosTributos.botaoNovoServico.largura,
                  altura: TamanhosServicosTributos.botaoNovoServico.altura,
                  idLayout: 'TamanhosServicosTributos.botaoNovoServico',
                ),
              ),
            ],
            cruzado: CrossAxisAlignment.start,
            idLayout: 'Grupo.cliente_form.lin.17',
          ),
        // O nome e a linha que o separa do resto, juntos; em edição o nome é o primeiro campo da
        // aba e ganha o mesmo respiro de cima do seletor (o rótulo fica sobre a borda).
        col(
          [
            Ct(
              padding: EdgeInsets.only(top: editaServ ? 8 : 0),
              child: campo(
                fServNome,
                'Nome do serviço',
                TamanhosServicosTributos.campoNomeDoServico,
                travado: t,
                maximo: 25,
                ocultarContador: true,
                mascara: maiusculas,
              ),
            ),
            divisor(),
          ],
          espaco: editaServ ? 0 : 10,
          justa: true,
          idLayout: 'Grupo.cliente_form.col.5',
        ),
        negrito('Serviço'),
        lin(
          [
            campo(
              fLocPrest,
              eImovel() || eCondominio()
                  ? 'Local do imóvel (IBGE)'
                  : 'Local prestação (IBGE)',
              TamanhosServicosTributos.campoLocalPrestacaoCMun,
              travado: t,
              mascara: soNumeros(7),
              dicaMouse:
                  'Município onde a operação acontece. A cidade do prestador é só uma sugestão; na locação, use a cidade do imóvel.',
            ),
            catalogo(fTribNac, 'Código de Tributação Nacional'),
            campo(
              fTribMun,
              'Cód. Tribut. Mun. (cTribMun)',
              TamanhosServicosTributos.campoCTribMun,
              travado: t,
              rotuloNaBorda: 'Trib. Mun. (cTribMun)',
              dicaMouse:
                  'Complemento municipal de 3 dígitos, quando fornecido pela prefeitura. Na locação sem ISSQN, deixe em branco. Não use 000.',
            ),
            catalogo(fNbs, 'Item da NBS'),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.18',
        ),
        CampoTexto(
          controle: fDesc,
          rotulo: 'Descrição do serviço',
          largura: TamanhosServicosTributos.campoDescricaoDoServico.largura,
          variasLinhas: true,
          minLinhas: 3,
          maxLinhas: 10,
          desabilitado: t,
          mascara: (s) =>
              ja<String>('texto.limpar_descricao', {'valor': s.toUpperCase()}),
          altura: TamanhosServicosTributos.campoDescricaoDoServico.altura,
          idLayout: 'TamanhosServicosTributos.campoDescricaoDoServico',
        ),
        Tx(
          'O valor do serviço é informado na tela Emitir, a cada emissão.',
          tam: Letra.apoio,
          cor: Colors.grey.shade600,
          largura: TamanhosServicosTributos
              .rotuloOValorDoServicoEInformadoNaTela
              .largura,
          altura: TamanhosServicosTributos
              .rotuloOValorDoServicoEInformadoNaTela
              .altura,
          idLayout:
              'TamanhosServicosTributos.rotuloOValorDoServicoEInformadoNaTela',
        ),
        divisor(),
        Marcar(
          valor: temIntermediario,
          rotulo: 'Informar intermediário no Brasil (ex.: imobiliária)',
          desabilitado: t,
          aoMudar: t
              ? null
              : (v) {
                  temIntermediario = v == true;
                  d.atualizar();
                },
          idLayout: 'Cliente.intermediario.informar',
        ),
        if (temIntermediario) ...[
          Tx(
            'O cliente continua sendo o tomador do aluguel. Identifique aqui quem intermediou a operação.',
            tam: Letra.apoio,
            cor: Colors.grey.shade600,
            idLayout: 'Cliente.intermediario.orientacao',
          ),
          lin(
            [
              ListaSuspensa(
                estado: ddIntermTipo,
                rotulo: 'Documento do intermediário',
                largura: 180,
                desabilitado: t,
                aoSelecionar: (_) {
                  fIntermDoc.text = mascaraDocumento(
                    fIntermDoc.text,
                    ddIntermTipo.valor,
                  );
                  d.atualizar();
                },
                idLayout: 'Cliente.intermediario.tipo',
              ),
              CampoTexto(
                controle: fIntermDoc,
                rotulo: 'CPF/CNPJ do intermediário',
                desabilitado: t,
                mascara: (v) => mascaraDocumento(v, ddIntermTipo.valor),
                idLayout: 'Cliente.intermediario.documento',
              ),
              CampoTexto(
                controle: fIntermNome,
                rotulo: 'Nome/Razão social do intermediário',
                desabilitado: t,
                maximo: 150,
                ocultarContador: true,
                mascara: maiusculas,
                idLayout: 'Cliente.intermediario.nome',
              ),
              CampoTexto(
                controle: fIntermIm,
                rotulo: 'Inscrição municipal do intermediário (opcional)',
                desabilitado: t,
                maximo: 15,
                ocultarContador: true,
                idLayout: 'Cliente.intermediario.inscricao',
              ),
            ],
            quebra: true,
            idLayout: 'Cliente.intermediario.campos',
          ),
        ],
        divisor(),
        negrito('Situação tributária'),
        lin(
          [
            lista(
              ddCst,
              'Situação Tributária do PIS/COFINS (CST)',
              TamanhosServicosTributos.campoSituacaoTributariaDoPISCOFINSCST,
              travado: t,
              aoSelecionar: (_) => acertar(),
            ),
            lista(
              ddRet,
              'Tipo de retenção do PIS/COFINS/CSLL',
              TamanhosServicosTributos.campoTipoDeRetencaoDoPISCOFINSCSLL,
              travado: t,
              aoSelecionar: (_) => acertar(),
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.19',
        ),
        lin(
          [
            lista(
              ddIss,
              'Tributação do ISSQN',
              TamanhosServicosTributos.campoTributacaoDoISSQN,
              travado: t,
            ),
            lista(
              ddRetIss,
              'Retenção do ISSQN',
              TamanhosServicosTributos.campoRetencaoDoISSQN,
              travado: t,
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.20',
        ),
        divisor(),
        negrito('IBS/CBS'),
        Marcar(
          valor: plataformaDigital,
          rotulo:
              'Operação abrangida pelo art. 22 da LC 214/2025 (plataforma digital)',
          desabilitado: t,
          aoMudar: (v) {
            plataformaDigital = v ?? false;
            d.atualizar();
          },
        ),
        lin(
          [
            lista(
              ddRtcDest,
              'Destinatário é o próprio adquirente?',
              TamanhosServicosTributos.campoDestinatarioEOProprioAdquirente,
              travado: t,
              aoSelecionar: (_) => d.atualizar(),
            ),
            lista(
              ddRtcIndOp,
              'Indicador da operação (cIndOp)',
              TamanhosServicosTributos.campoIndicadorDaOperacaoCIndOp,
              travado: t,
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.21',
        ),
        if (ddRtcDest.valor == '1')
          col(
            [
              lin(
                [
                  lista(
                    ddDestTipo,
                    'Documento do destinatário',
                    TamanhosServicosTributos.campoDocumentoDoDestinatario,
                    travado: t,
                  ),
                  campo(
                    fDestDoc,
                    'Número do documento',
                    TamanhosServicosTributos.campoNumeroDoDocumento,
                    travado: t,
                  ),
                  campo(
                    fDestNome,
                    'Nome do destinatário',
                    TamanhosServicosTributos.campoNomeDoDestinatario,
                    travado: t,
                    mascara: maiusculas,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.cliente_form.lin.22',
              ),
              lin(
                [
                  campo(
                    fDestMun,
                    'Município (IBGE)',
                    TamanhosServicosTributos.campoMunicipioIBGE,
                    travado: t,
                  ),
                  campo(
                    fDestCep,
                    'CEP',
                    TamanhosServicosTributos.campoCEP2,
                    travado: t,
                  ),
                  campo(
                    fDestLgr,
                    'Logradouro',
                    TamanhosServicosTributos.campoLogradouro2,
                    travado: t,
                    mascara: maiusculas,
                  ),
                  campo(
                    fDestNro,
                    'Número',
                    TamanhosServicosTributos.campoNumero2,
                    travado: t,
                  ),
                  campo(
                    fDestCpl,
                    'Complemento',
                    TamanhosServicosTributos.campoComplemento2,
                    travado: t,
                    mascara: maiusculas,
                  ),
                  campo(
                    fDestBairro,
                    'Bairro',
                    TamanhosServicosTributos.campoBairro2,
                    travado: t,
                    mascara: maiusculas,
                  ),
                ],
                quebra: true,
                idLayout: 'Grupo.cliente_form.lin.23',
              ),
            ],
            espaco: 8,
            justa: true,
            idLayout: 'Grupo.cliente_form.col.6',
          ),
        lin(
          [
            lista(
              ddRtcCst,
              'Situação tributária IBS/CBS (CST)',
              TamanhosServicosTributos.campoSituacaoTributariaIBSCBSCST,
              travado: t,
              aoSelecionar: (v) {
                classes(v ?? '');
                d.atualizar();
              },
            ),
            lista(
              ddRtcClasse,
              'Classificação tributária IBS/CBS',
              TamanhosServicosTributos.campoClassificacaoTributariaIBSCBS,
              travado: t,
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.24',
        ),
        if (eImovel()) ...blocoImovel(locacao: true),
        if (eCondominio()) ...[
          ...blocoImovel(locacao: false),
          ...blocoCobrancas(),
        ],
        if (eBemMovel()) ...blocoBens(),
        divisor(),
        negrito('Percentuais de PIS/COFINS'),
        lin(
          [
            pct(fPis, 'PIS', 'pAliqPis', travado: semCalc),
            pct(fCofins, 'COFINS', 'pAliqCofins', travado: semCalc),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.25',
        ),
        divisor(),
        negrito('Retenções (IRRF / Contribuições Sociais)'),
        lin(
          [
            pct(fIrrf, 'IRRF', 'irrf', travado: naoRetido),
            pct(fCsll, 'CSLL', 'csll', travado: naoRetido),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.26',
        ),
        // A margem negativa alinha o quadradinho com a borda do campo IRRF acima.
        PuxarEsquerda(
          recuo: 10,
          child: Marcar(
            idLayout: 'Checkbox.cliente_form.1',
            valor: cbContrib,
            rotulo: 'Incluir contribuições sociais (PIS + COFINS + CSLL)',
            sobreposicao: Colors.transparent,
            raioRespingo: 0,
            desabilitado: t || naoRetido || semCalc,
            aoMudar: (v) {
              cbContrib = v ?? false;
              acertar();
            },
          ),
        ),
        divisor(),
        negrito('Totais aproximados dos tributos (Lei 12.741)'),
        lin(
          [
            pct(fFed, 'Federal', 'pTotTribFed'),
            pct(fEst, 'Estadual', 'pTotTribEst'),
            pct(fMun, 'Municipal', 'pTotTribMun'),
          ],
          quebra: true,
          idLayout: 'Grupo.cliente_form.lin.27',
        ),
      ],
      rolar: true,
      justa: true,
      idLayout: 'Grupo.cliente_form.col.4',
    );
  }

  ddServico.opcoes = opcoesDeServico();
  ddServico.por(slugAtual.isEmpty ? null : slugAtual);
  carregarServico(
    servicos[slugAtual] ?? {},
  ); // estado inicial (antes de exibir a janela)

  d.conteudo = (_) => SizedBox(
    height: 520,
    child: emLote
        ? painel(abaServico())
        : Abas(
            inicial: aba,
            rotulos: const [
              ('Dados do cliente', Icons.person),
              ('Serviço & Tributação', Icons.account_balance),
            ],
            // "Excluir cliente" só na aba Dados; "Excluir serviço" só na aba Serviço & Tributação.
            // Editar/Salvar acompanham a aba: cada uma tem a própria edição.
            aoMudar: (i) {
              abaAtual = i == 1 ? 1 : 0;
              d.atualizar();
            },
            paineis: [painel(abaDados()), painel(abaServico())],
          ),
  );
  d.acoes = (_) => emLote
      ? [
          Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d)),
          Botao('Confirmar alterações', icone: Icons.check, aoClicar: salvar),
        ]
      : [
          lin(
            [
              if (abaAtual == 0 && jaSalvo)
                Botao.contorno(
                  'Excluir cliente',
                  icone: Icons.delete_forever,
                  cor: Colors.red.shade700,
                  aoClicar: () => app.exigirPermissao(
                    'clientes.excluir',
                    () => _confirmarExcluirCliente(
                      app,
                      docSalvo,
                      _cima(fNome.text),
                    ),
                  ),
                  largura: TamanhosServicosTributos.botaoExcluirCliente.largura,
                  altura: TamanhosServicosTributos.botaoExcluirCliente.altura,
                  idLayout: 'TamanhosServicosTributos.botaoExcluirCliente',
                ),
              if (abaAtual == 1 && !editaServ)
                Botao.contorno(
                  'Excluir serviço',
                  desabilitado: !temServico(),
                  icone: Icons.delete_outline,
                  cor: Colors.red.shade700,
                  aoClicar: pedirExcluirServico,
                  largura: TamanhosServicosTributos.botaoExcluirServico.largura,
                  altura: TamanhosServicosTributos.botaoExcluirServico.altura,
                  idLayout: 'TamanhosServicosTributos.botaoExcluirServico',
                ),
              // Em edição o lugar é do "Cancelar" (cliente ainda não salvo não tem para onde voltar:
              // ali quem desiste fecha a janela).
              if (abaAtual == 1 && editaServ && jaSalvo)
                Botao.contorno(
                  'Cancelar',
                  icone: Icons.close,
                  aoClicar: cancelarServico,
                  largura: TamanhosServicosTributos.botaoCancelar.largura,
                  altura: TamanhosServicosTributos.botaoCancelar.altura,
                  idLayout: 'TamanhosServicosTributos.botaoCancelar',
                ),
            ],
            espaco: 8,
            justa: true,
            idLayout: 'Grupo.cliente_form.lin.28',
          ),
          lin(
            [
              // Editar <-> Salvar alternam conforme o modo DA ABA à vista.
              if (!abaEmEdicao())
                Botao.contorno(
                  'Editar',
                  desabilitado: abaAtual == 1 && !temServico(),
                  icone: Icons.edit,
                  aoClicar: () => app.exigirPermissao(
                    abaAtual == 1 ? 'clientes.servicos' : 'clientes.editar',
                    () {
                      // Só a aba à vista entra em edição; a outra continua como estava.
                      if (abaAtual == 1) {
                        editaServ = true;
                      } else {
                        editaDados = true;
                      }
                      acertar();
                    },
                  ),
                  largura: TamanhosServicosTributos.botaoEditar.largura,
                  altura: TamanhosServicosTributos.botaoEditar.altura,
                  idLayout: 'TamanhosServicosTributos.botaoEditar',
                ),
              if (abaEmEdicao())
                Botao(
                  'Salvar',
                  icone: Icons.save,
                  aoClicar: salvar,
                  largura: TamanhosServicosTributos.botaoSalvar.largura,
                  altura: TamanhosServicosTributos.botaoSalvar.altura,
                  idLayout: 'TamanhosServicosTributos.botaoSalvar',
                ),
            ],
            espaco: 8,
            justa: true,
            idLayout: 'Grupo.cliente_form.lin.29',
          ),
        ];
  // Esc com um cadastro JÁ SALVO em edição: descarta o que não foi salvo e volta ao modo só
  // leitura — reabre a janela a partir do que está gravado, na mesma aba e no mesmo serviço.
  // Cliente ainda não salvo não tem leitura para onde voltar: ali o Esc fecha.
  d.escCancelaEdicao = () {
    if (emLote) return false;
    if (!((editaDados || editaServ) && jaSalvo && docSalvo.isNotEmpty))
      return false;
    final (doc, abaDeAgora, slugDeAgora) = (docSalvo, abaAtual, slugAtual);
    app.fecharEsta(d);
    abrirCliente(app, doc, aba: abaDeAgora, slug: slugDeAgora);
    return true;
  };
  app.mostrarDialogo(d);
}

/// Exclui o CADASTRO do cliente (mantém as notas emitidas). Pede confirmação digitando o
/// documento.
void _confirmarExcluirCliente(App app, String doc, String nome) {
  late final Dialogo d;
  late final TextEditingController campo;
  late final FocusNode focoDoCampo;

  void excluir() {
    if (soDoc(campo.text) != soDoc(doc)) {
      app.toast(
        'Documento não confere. Digite exatamente para confirmar.',
        erro: true,
      );
      focoDoCampo.requestFocus();
      return;
    }
    try {
      ja<Object?>('cadastro.delete_tomador', {
        'prestador': app.prestador,
        'tomador': doc,
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    registrar(
      'Cliente (cadastro) EXCLUÍDO: $nome ($doc) prestador=${app.prestador}',
    );
    app.fecharDialogo(); // fecha a confirmação
    app.fecharDialogo(); // fecha o cadastro
    app.toast(
      'Cadastro de $nome excluído. As NFS-e já emitidas foram mantidas.',
    );
    app.clientesMudaram(); // cadastro removido: as listas são refeitas
    app.atualizar();
  }

  d = Dialogo(
    titulo: (_) => LinhaTitulo([
      Icon(Icons.warning_amber, color: Colors.red.shade700),
      textoTitulo('Excluir cliente'),
    ], espaco: 10),
    largura: 500,
    conteudo: (_) => col(
      [
        Tx(
          "Excluir o CADASTRO do cliente '$nome' (${formatarDocumento(doc)})?",
          largura: TamanhosServicosTributos
              .rotuloExcluirOCADASTRODoClienteNomeFormatarDocumentoDoc
              .largura,
          altura: TamanhosServicosTributos
              .rotuloExcluirOCADASTRODoClienteNomeFormatarDocumentoDoc
              .altura,
          idLayout:
              'TamanhosServicosTributos.rotuloExcluirOCADASTRODoClienteNomeFormatarDocumentoDoc',
        ),
        Tx(
          'As NFS-e já emitidas deste cliente são MANTIDAS — só o cadastro é removido '
          '(ele some da lista de clientes e da emissão).',
          tam: Letra.apoio,
          cor: Colors.grey.shade700,
          largura: TamanhosServicosTributos
              .rotuloAsNFSEJaEmitidasDesteClienteSao
              .largura,
          altura: TamanhosServicosTributos
              .rotuloAsNFSEJaEmitidasDesteClienteSao
              .altura,
          idLayout:
              'TamanhosServicosTributos.rotuloAsNFSEJaEmitidasDesteClienteSao',
        ),
        CampoTexto(
          controle: campo,
          rotulo: 'Digite o documento para confirmar',
          largura: TamanhosServicosTributos
              .campoDigiteODocumentoParaConfirmar
              .largura,
          dica: formatarDocumento(doc),
          foco: focoDoCampo,
          focoInicial: true,
          aoEnviar: (_) => excluir(),
          altura: TamanhosServicosTributos
              .campoDigiteODocumentoParaConfirmar
              .altura,
          idLayout:
              'TamanhosServicosTributos.campoDigiteODocumentoParaConfirmar',
        ),
      ],
      justa: true,
      idLayout: 'Grupo.cliente_form.col.7',
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: app.fecharDialogo,
        largura: TamanhosServicosTributos.botaoCancelar2.largura,
        altura: TamanhosServicosTributos.botaoCancelar2.altura,
        idLayout: 'TamanhosServicosTributos.botaoCancelar2',
      ),
      Botao(
        'Excluir',
        icone: Icons.delete_forever,
        cor: Colors.white,
        fundo: Colors.red.shade700,
        aoClicar: excluir,
        largura: TamanhosServicosTributos.botaoExcluir.largura,
        altura: TamanhosServicosTributos.botaoExcluir.altura,
        idLayout: 'TamanhosServicosTributos.botaoExcluir',
      ),
    ],
    idLayout: 'Janela.cliente_form.Dialogo.3',
  );
  campo = d.texto();
  focoDoCampo = d.foco();
  app.mostrarDialogo(d);
}

// ------------------------------------------------------------------------------------------- //
// Locação (leiaute novo da NFS-e): os campos de cada item das listas do cadastro do serviço.
// Os controles pertencem à janela (`d`): são descartados com ela.
// ------------------------------------------------------------------------------------------- //
const _tiposDeParcela = [
  Opcao(
    '01',
    '01 - Tributos inclusos no aluguel (IPTU, contribuição de melhoria)',
  ),
  Opcao('02', '02 - Emolumento incluso no aluguel'),
  Opcao('03', '03 - Condomínio incluso no aluguel'),
  Opcao('04', '04 - Redutor social (só locação residencial)'),
  Opcao('99', '99 - Outras parcelas inclusas no aluguel'),
];

const _tiposDeCobranca = [
  Opcao('01', '01 - Condomínio ordinário'),
  Opcao('02', '02 - Condomínio privativo'),
  Opcao('03', '03 - Fundo de promoção e propaganda'),
  Opcao('04', '04 - Impostos e taxas'),
  Opcao('05', '05 - Fundo de reserva'),
  Opcao('99', '99 - Outra cobrança'),
];

const _tiposDeDescontoCond = [
  Opcao('1', '1 - Incondicionado'),
  Opcao('2', '2 - Condicionado'),
];

String _txt(Map<String, dynamic> m, String k) => (m[k] as String?) ?? '';

/// Soma de valores digitados ("1.234,56" ou "1234.56"), em texto decimal.
String _somaDe(Iterable<String> valores) {
  var centavos = 0;
  for (final v in valores) {
    final n =
        double.tryParse(v.trim().replaceAll('.', '').replaceAll(',', '.')) ??
        double.tryParse(v.trim().replaceAll(',', '.'));
    if (n != null && n.isFinite) centavos += (n * 100).round();
  }
  return (centavos / 100).toStringAsFixed(2);
}

Map<String, dynamic>? _tabelaDeDetalhes;

/// Os tipos de detalhe que um tipo de cobrança admite (sem tipo escolhido, todos). A tabela é a
/// do núcleo — é ele quem confere —, lida uma vez.
List<Opcao> _detalhesDe(String? tipoDaCobranca) {
  final tabela = _tabelaDeDetalhes ??= jaMapa('cadastro.detalhes_de_cobranca');
  final admitidos =
      ((tabela['admitidos'] as Map)[tipoDaCobranca ?? ''] as List?)?.toSet();
  return [
    for (final par in tabela['tipos'] as List)
      if (admitidos == null || admitidos.contains((par as List)[0]))
        Opcao((par as List)[0] as String, par[1] as String),
  ];
}

/// Item do detalhamento (opcional) de uma cobrança do condomínio.
class _Detalhe {
  _Detalhe(Dialogo d, Map<String, dynamic> m, String? tipoDaCobranca)
    : tipo = d.suspensa(
        valor: _txt(m, 'tipo').isEmpty ? null : _txt(m, 'tipo'),
        opcoes: _detalhesDe(tipoDaCobranca),
      ),
      descricao = d.texto(_txt(m, 'descricao')),
      valor = d.texto(pctVirgula(_txt(m, 'valor')));
  final Suspensa tipo;
  final TextEditingController descricao;
  final TextEditingController valor;

  Map<String, dynamic> mapa() => {
    'tipo': tipo.valor ?? '',
    'descricao': descricao.text.trim(),
    'valor': valor.text.trim(),
  };
}

/// Cobrança do condomínio, com o seu detalhamento.
class _Cobranca {
  _Cobranca(Dialogo d, Map<String, dynamic> m)
    : tipo = d.suspensa(
        valor: _txt(m, 'tipo').isEmpty ? null : _txt(m, 'tipo'),
        opcoes: _tiposDeCobranca,
      ),
      descricao = d.texto(_txt(m, 'descricao')),
      valor = d.texto(pctVirgula(_txt(m, 'valor'))),
      detalhes = [
        for (final x in (m['detalhes'] as List?) ?? const [])
          _Detalhe(d, Map<String, dynamic>.from(x as Map), _txt(m, 'tipo')),
      ];
  final Suspensa tipo;
  final TextEditingController descricao;
  final TextEditingController valor;
  final List<_Detalhe> detalhes;

  /// Com detalhamento, o valor da cobrança é a soma dos itens.
  void somar() {
    if (detalhes.isNotEmpty)
      valor.text = pctVirgula(_somaDe(detalhes.map((x) => x.valor.text)));
  }

  /// O tipo da cobrança mudou: as listas dos itens passam a oferecer só o que ele admite.
  void acertarDetalhes() {
    final opcoes = _detalhesDe(tipo.valor);
    for (final x in detalhes) {
      x.tipo.opcoes = opcoes;
      if (!opcoes.any((o) => o.chave == x.tipo.valor)) x.tipo.por(null);
      x.tipo.avisar();
    }
  }

  Map<String, dynamic> mapa() => {
    'tipo': tipo.valor ?? '',
    'descricao': descricao.text.trim(),
    'valor': valor.text.trim(),
    'detalhes': [for (final x in detalhes) x.mapa()],
  };
}

/// Desconto do condomínio (incondicionado ou condicionado), com descrição.
class _DescontoCond {
  _DescontoCond(Dialogo d, Map<String, dynamic> m)
    : tipo = d.suspensa(
        valor: _txt(m, 'tipo').isEmpty ? null : _txt(m, 'tipo'),
        opcoes: _tiposDeDescontoCond,
      ),
      descricao = d.texto(_txt(m, 'descricao')),
      valor = d.texto(pctVirgula(_txt(m, 'valor')));
  final Suspensa tipo;
  final TextEditingController descricao;
  final TextEditingController valor;

  Map<String, dynamic> mapa() => {
    'tipo': tipo.valor ?? '',
    'descricao': descricao.text.trim(),
    'valor': valor.text.trim(),
  };
}

/// Parcela do aluguel que não entra na base do IBS/CBS.
class _Ajuste {
  _Ajuste(Dialogo d, Map<String, dynamic> m)
    : tipo = d.suspensa(
        valor: _txt(m, 'tipo').isEmpty ? null : _txt(m, 'tipo'),
        opcoes: _tiposDeParcela,
      ),
      descricao = d.texto(_txt(m, 'descricao')),
      valor = d.texto(pctVirgula(_txt(m, 'valor')));
  final Suspensa tipo;
  final TextEditingController descricao;
  final TextEditingController valor;

  Map<String, dynamic> mapa() => {
    'tipo': tipo.valor ?? '',
    'descricao': tipo.valor == '99' ? descricao.text.trim() : '',
    'valor': valor.text.trim(),
  };
}

class _ContatoCliente {
  _ContatoCliente(
    Dialogo d,
    String categoria,
    String texto,
    String nota,
    this.principal, {
    String personalizado = '',
  }) : tipo = d.suspensa(),
       valor = d.texto(texto),
       observacao = d.texto(nota) {
    definirTipo(categoria, personalizado: personalizado);
  }
  final Suspensa tipo;
  final TextEditingController valor, observacao;
  bool principal;
  late String categoria;
  String personalizado = '';

  String get rotulo => personalizado.isNotEmpty
      ? personalizado
      : categoria == 'email'
      ? 'E-mail'
      : 'Telefone';

  void definirTipo(String categoria, {String personalizado = ''}) {
    this.categoria = categoria;
    this.personalizado = personalizado;
    tipo.opcoes = [
      const Opcao('telefone', 'Telefone'),
      const Opcao('email', 'E-mail'),
      if (personalizado.isNotEmpty) Opcao('personalizado', personalizado),
      const Opcao('personalizar', 'Personalizar'),
    ];
    tipo.por(personalizado.isEmpty ? categoria : 'personalizado');
    tipo.avisar();
  }

  Map<String, dynamic> mapa() => {
    'tipo': categoria,
    'rotulo': personalizado,
    'valor': valor.text.trim(),
    'observacao': observacao.text,
    'principal': categoria != 'outros' && principal,
  };
}

/// Unidade imobiliária da locação: código CIB OU endereço.
class _Unidade {
  _Unidade(Dialogo d, Map<String, dynamic> m)
    : insc = d.texto(_txt(m, 'inscImobFisc')),
      cib = d.texto(_txt(m, 'cCIB')),
      cep = d.texto(_txt(m, 'CEP')),
      lgr = d.texto(_txt(m, 'xLgr')),
      nro = d.texto(_txt(m, 'nro')),
      cpl = d.texto(_txt(m, 'xCpl')),
      bairro = d.texto(_txt(m, 'xBairro')),
      ajustes = [
        for (final a in (m['ajustes'] as List?) ?? const [])
          _Ajuste(d, Map<String, dynamic>.from(a as Map)),
      ];
  final TextEditingController insc;
  final TextEditingController cib;
  final TextEditingController cep;
  final TextEditingController lgr;
  final TextEditingController nro;
  final TextEditingController cpl;
  final TextEditingController bairro;
  final List<_Ajuste> ajustes;

  Map<String, dynamic> mapa() => {
    'inscImobFisc': insc.text.trim(),
    'cCIB': cib.text.trim(),
    'CEP': cep.text.trim(),
    'xLgr': lgr.text.trim(),
    'nro': nro.text.trim(),
    'xCpl': cpl.text.trim(),
    'xBairro': bairro.text.trim(),
    'ajustes': [for (final a in ajustes) a.mapa()],
  };
}

/// Bem móvel locado.
class _Bem {
  _Bem(Dialogo d, Map<String, dynamic> m)
    : ncm = d.texto(_txt(m, 'ncm')),
      descricao = d.texto(_txt(m, 'descricao')),
      quantidade = d.texto(_txt(m, 'quantidade'));
  final TextEditingController ncm;
  final TextEditingController descricao;
  final TextEditingController quantidade;

  Map<String, dynamic> mapa() => {
    'ncm': ncm.text.trim(),
    'descricao': descricao.text.trim(),
    'quantidade': quantidade.text.trim(),
  };
}
