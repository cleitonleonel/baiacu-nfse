/// Lotes salvos no banco cifrado, com validação e transmissão sequencial por linha.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../kit/arquivos.dart';
import '../kit/campo.dart';
import '../kit/contorno_campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import '../kit/rolagem_linhas.dart';
import '../kit/tabela.dart';
import '../editor_layout.dart';
import 'cliente_form.dart';
import 'consultar.dart'
    show ProgressoExportacao, formatosExportacao, opcoesDeAmbiente;
import 'periodo.dart'
    show
        abrirCompetencia,
        abrirPeriodo,
        dataBr,
        dataIso,
        datasDoPeriodo,
        larguraPeriodoComDatas,
        opcoesDePeriodo,
        textoDoIntervalo;

class TelaLotes extends StatefulWidget {
  const TelaLotes({super.key, required this.app});
  final App app;
  @override
  State<TelaLotes> createState() => _TelaLotesState();
}

class _TelaLotesState extends State<TelaLotes> {
  static const _estiloAcaoDaLinha = ButtonStyle(
    fixedSize: WidgetStatePropertyAll(Size.square(32)),
    minimumSize: WidgetStatePropertyAll(Size.zero),
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
    shape: WidgetStatePropertyAll(CircleBorder()),
    alignment: Alignment.center,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
  );

  App get app => widget.app;
  final escolha = Suspensa();
  final pesquisa = TextEditingController();
  final rolagemRegistro = ControleRolagemPorLinhas(
    Medida.linhaDaTabela,
    keepScrollOffset: false,
  );
  static const _todoPeriodo = Opcao('todos', 'Todo o período');
  final filtroPeriodo = Suspensa(valor: 'todos');
  final filtroAmbiente = Suspensa(valor: 'todos', opcoes: opcoesDeAmbiente)
    ..por('todos');
  String periodoHistorico = 'todos';
  DateTime? periodoDe, periodoAte;
  final nomesClientes = <String, String>{};
  List<Map<String, dynamic>> lotes = [];
  Map<String, dynamic>? lote;
  final controles = <String, TextEditingController>{};
  List<Map<String, dynamic>> historico = [];
  bool ocupado = false, emitindo = false, sujo = false, parar = false;
  String prestador = '';
  bool editando = false, vendoHistorico = false;
  Map<String, dynamic>? execucao;
  String? linhaEmEnvio;
  List<Map<String, dynamic>> execucoes = [];

  Future<void> atualizarExecucoes() async {
    final prest = app.prestador;
    try {
      final dados = await chamar<List>('lotes.execucoes', {'prestador': prest});
      if (!mounted || prest != app.prestador) return;
      execucoes = [for (final e in dados) Map<String, dynamic>.from(e as Map)];
      app.lotesPendentes = execucoes
          .where((e) => (e['pendentes'] as int) > 0)
          .length;
      app.tiqueCasca.value++;
      setState(() {});
    } catch (e) {
      if (mounted) app.toast('$e', erro: true);
    }
  }

  String _id() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  List<Map<String, dynamic>> get linhas => [
    for (final l in (lote?['linhas'] as List? ?? []))
      Map<String, dynamic>.from(l as Map),
  ];
  @override
  void initState() {
    super.initState();
    _sincronizarPeriodo();
    app.aoEntrar[5] = carregar;
    app.aoTrocarPrestador.add(trocar);
  }

  @override
  void dispose() {
    app.aoEntrar.remove(5);
    app.aoTrocarPrestador.remove(trocar);
    for (final c in controles.values) {
      c.dispose();
    }
    pesquisa.dispose();
    rolagemRegistro.dispose();
    filtroPeriodo.dispose();
    filtroAmbiente.dispose();
    escolha.dispose();
    super.dispose();
  }

  void trocar() {
    if (!mounted) return;
    lote = null;
    execucao = null;
    execucoes = [];
    vendoHistorico = false;
    _limparFiltrosHistorico();
    editando = false;
    escolha.por(null);
    historico = [];
    _limparControles();
    sujo = false;
    carregar();
  }

  int _carga = 0;
  Future<void> carregar() async {
    if (!mounted || ocupado) return;
    final carga = ++_carga;
    final prest = app.prestador;
    if (prest.isEmpty) return;
    try {
      final dados = await Future.wait([
        chamar<List>('cadastro.list_tomadores', {'prestador': prest}),
        chamar<List>('lotes.listar', {'prestador': prest}),
      ]);
      if (!mounted || carga != _carga || prest != app.prestador) return;
      prestador = prest;
      nomesClientes
        ..clear()
        ..addEntries([
          for (final c in dados[0])
            MapEntry(c['documento'] as String, c['display'] as String),
        ]);
      lotes = [for (final l in dados[1]) Map<String, dynamic>.from(l as Map)];
      _atualizarEscolha();
      setState(() {});
      await atualizarExecucoes();
      if (vendoHistorico && execucao != null) await _historico();
    } catch (e) {
      if (mounted) app.toast('$e', erro: true);
    }
  }

  void _atualizarEscolha() {
    final atual = lote;
    escolha.opcoes = [
      for (final l in lotes)
        Opcao(
          l['id'] as String,
          (atual?['id'] == l['id'] ? atual!['nome'] : l['nome']) as String,
        ),
      if (atual != null && !lotes.any((l) => l['id'] == atual['id']))
        Opcao(atual['id'] as String, atual['nome'] as String),
    ];
    escolha.por(atual?['id'] as String?);
    escolha.avisar();
  }

  Future<void> abrir(String? id) async {
    if (id == null || ocupado || (id == lote?['id'] && !vendoHistorico)) return;
    if (sujo && !salvar()) {
      escolha.por(lote?['id'] as String?);
      escolha.avisar();
      return;
    }
    final prest = app.prestador;
    setState(() => ocupado = true);
    try {
      final dados = await chamar<Map>('lotes.obter', {
        'prestador': prest,
        'id': id,
      });
      if (!mounted || prest != app.prestador) return;
      lote = Map<String, dynamic>.from(dados);
      editando = false;
      sujo = false;
      vendoHistorico = false;
      _limparControles();
    } catch (e) {
      if (mounted) app.toast('$e', erro: true);
    } finally {
      if (mounted) setState(() => ocupado = false);
    }
  }

  void _limparControles() {
    final antigos = controles.values.toList();
    controles.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in antigos) {
        c.dispose();
      }
    });
  }

  Future<void> _historico({bool propagarErro = false}) async {
    if (!vendoHistorico) return;
    final prest = app.prestador;
    final id = execucao?['id'];
    if (id == null) return;
    try {
      final dados = await chamar<List>('lotes.historico', {
        'prestador': prest,
        'id': id,
      });
      if (!mounted ||
          prest != app.prestador ||
          !vendoHistorico ||
          id != execucao?['id'])
        return;
      setState(
        () => historico = [
          for (final h in dados) Map<String, dynamic>.from(h as Map),
        ],
      );
    } catch (e) {
      if (propagarErro) rethrow;
      if (mounted) app.toast('$e', erro: true);
    }
  }

  bool salvar() {
    if (lote == null || ocupado) return false;
    if (!sujo) {
      setState(() => editando = false);
      return true;
    }
    if (!app.temPermissao('lotes.editar')) {
      app.exigirPermissao('lotes.editar', salvar);
      return false;
    }
    try {
      final itens = linhas;
      for (var i = 0; i < itens.length; i++) {
        final linha = itens[i];
        if (controles["${linha['id']}.vServ"]?.text == '') {
          throw FormatException('Linha ${i + 1}: informe o valor do serviço.');
        }
      }
      final salvo = jaMapa('lotes.salvar', {
        'prestador': prestador,
        'lote': lote,
      });
      setState(() {
        lote = salvo;
        sujo = false;
        editando = false;
        _atualizarEscolha();
      });
      carregar();
      return true;
    } catch (e) {
      app.toast('Lote não salvo: $e', erro: true);
      return false;
    }
  }

  void criar() {
    if (ocupado ||
        editando ||
        prestador.isEmpty ||
        prestador != app.prestador) {
      return;
    }
    _editarNome();
  }

  void _editarNome({bool renomear = false}) {
    if (!app.temPermissao('lotes.editar')) {
      app.exigirPermissao(
        'lotes.editar',
        () => _editarNome(renomear: renomear),
      );
      return;
    }
    final alvo = renomear ? lote : null;
    final nomeAnterior = alvo?['nome'] as String? ?? '';
    final id = alvo?['id'];
    final prest = app.prestador;
    late final Dialogo d;
    late final TextEditingController nome;
    String? erro;
    void confirmar() {
      if (prest != app.prestador || (renomear && alvo != lote)) return;
      final novo = nome.text.trim();
      final chave = novo.toLowerCase();
      erro = novo.isEmpty
          ? 'Informe o nome do lote.'
          : novo.runes.length > 30 && novo != nomeAnterior.trim()
          ? 'O nome do lote pode ter até 30 caracteres.'
          : lotes.any(
              (l) =>
                  l['id'] != id &&
                  (l['nome'] as String).trim().toLowerCase() == chave,
            )
          ? 'Já existe um lote com este nome.'
          : null;
      if (erro != null) {
        d.atualizar();
        return;
      }
      if (renomear) {
        if (alvo!['nome'] != novo) {
          alvo['nome'] = novo;
          sujo = true;
        }
      } else {
        lote = {'id': _id(), 'nome': novo, 'revisao': 0, 'linhas': <Object>[]};
        sujo = true;
        editando = true;
        vendoHistorico = false;
        _limparControles();
        historico = [];
      }
      app.fecharEsta(d);
      setState(_atualizarEscolha);
    }

    d = Dialogo(
      titulo: (_) => app.tituloComX(renomear ? 'Editar lote' : 'Criar lote'),
      largura: 440,
      conteudo: (_) => CampoTexto(
        controle: nome,
        rotulo: 'Nome do lote',
        largura: 440,
        focoInicial: true,
        maximo: max(30, nomeAnterior.characters.length),
        erro: erro,
        aoEnviar: (_) => confirmar(),
        aoMudar: (_) {
          if (erro != null) {
            erro = null;
            d.atualizar();
          }
        },
      ),
      acaoEsquerda: alvo == null
          ? null
          : (_) => Botao.contorno(
              'Excluir lote',
              icone: Icons.delete_forever,
              cor: Colors.red.shade700,
              aoClicar: () {
                app.fecharEsta(d);
                _confirmarExclusao(alvo);
              },
              idLayout: 'Lotes.botaoExcluirLote',
            ),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.nome.botaoCancelar'),
        Botao(renomear ? 'Renomear' : 'Criar', aoClicar: confirmar, idLayout: 'Lotes.nome.botaoConfirmar'),
      ],
    );
    nome = d.texto(nomeAnterior);
    app.mostrarDialogo(d);
  }

  void _confirmarExclusao(Map<String, dynamic> alvo) {
    late final Dialogo d;
    d = Dialogo(
      titulo: (_) => app.tituloComX('Excluir lote'),
      largura: 440,
      conteudo: (_) => Tx(
        'Excluir o lote “${alvo['nome']}”? As emissões realizadas continuam no histórico.',
      ),
      acaoEsquerda: (_) => Botao.contorno(
        'Excluir lote',
        icone: Icons.delete_forever,
        cor: Colors.red.shade700,
        aoClicar: () {
          app.fecharEsta(d);
          _excluir(alvo);
        },
        idLayout: 'Lotes.botaoExcluirLote2',
      ),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.botaoCancelar2'),
      ],
    );
    app.mostrarDialogo(d);
  }

  Future<void> _excluir(Map<String, dynamic> alvo) async {
    if (alvo != lote || ocupado || prestador != app.prestador) return;
    final prest = prestador;
    final id = alvo['id'];
    final revisao = alvo['revisao'] as int;
    setState(() => ocupado = true);
    app.trabalhos++;
    try {
      if (revisao > 0) {
        await chamar<Object?>('lotes.excluir', {
          'prestador': prest,
          'id': id,
          'revisao': revisao,
        });
      }
      if (!mounted || prest != app.prestador) return;
      setState(() {
        lote = null;
        historico = [];
        lotes.removeWhere((l) => l['id'] == id);
        sujo = false;
        editando = false;
        _limparControles();
        _atualizarEscolha();
      });
      app.toast('Lote excluído.');
    } catch (e) {
      if (mounted) app.toast('Não foi possível excluir o lote: $e', erro: true);
    } finally {
      app.trabalhos--;
      if (mounted) {
        setState(() => ocupado = false);
        carregar();
      }
    }
  }

  void cancelarEdicao() {
    late final Dialogo d;
    d = Dialogo(
      titulo: (_) => textoTitulo('Cancelar edição do lote'),
      largura: 440,
      conteudo: (_) =>
          const Tx('Descartar as alterações ainda não salvas neste lote?'),
      acoes: (_) => [
        Botao.texto('Continuar editando', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.botaoContinuarEditando'),
        Botao(
          'Descartar alterações',
          aoClicar: () {
            try {
              if ((lote?['revisao'] as int? ?? 0) > 0) {
                lote = jaMapa('lotes.obter', {
                  'prestador': app.prestador,
                  'id': lote!['id'],
                });
              } else {
                lote = null;
              }
              editando = false;
              sujo = false;
              _limparControles();
              _atualizarEscolha();
              app.fecharEsta(d);
              setState(() {});
            } catch (e) {
              app.toast('$e', erro: true);
            }
          },
          idLayout: 'Lotes.botaoDescartarAlteracoes',
        ),
      ],
    );
    app.mostrarDialogo(d);
  }

  void adicionar() {
    final modelo = lote;
    if (!editando || ocupado || modelo == null) return;
    if (!app.temPermissao('lotes.editar')) {
      app.exigirPermissao('lotes.editar', adicionar);
      return;
    }
    final prest = app.prestador;
    final existentes = {
      for (final l in linhas) (l['tomador'] as String, l['servico'] as String),
    };
    final catalogo = <String, List<Map>>{};
    final carregando = <String>{};
    final falhas = <String, String>{};
    final marcados = <(String, String)>{};
    String? cliente;
    var confirmando = false;
    var aberto = true;
    late final Dialogo d;
    late final TextEditingController busca;
    bool ativo() =>
        aberto && mounted && lote == modelo && app.prestador == prest;

    Future<void> selecionarCliente(String doc) async {
      if (confirmando) return;
      cliente = doc;
      if (catalogo.containsKey(doc) || !carregando.add(doc)) {
        d.atualizar();
        return;
      }
      falhas.remove(doc);
      d.atualizar();
      try {
        final dados = await chamar<List>('cadastro.list_servicos', {
          'prestador': prest,
          'tomador': doc,
        });
        catalogo[doc] = dados.cast<Map>();
      } catch (e) {
        falhas[doc] = '$e';
      } finally {
        carregando.remove(doc);
        if (ativo()) d.atualizar();
      }
    }

    void marcar((String, String) par, bool selecionado) {
      if (selecionado && existentes.length + marcados.length >= 1000) {
        app.toast('O lote pode ter até 1000 linhas.', erro: true);
        return;
      }
      if (selecionado) {
        marcados.add(par);
      } else {
        marcados.remove(par);
      }
      d.atualizar();
    }

    Future<void> adicionarMarcados() async {
      if (!ativo() || confirmando || marcados.isEmpty) return;
      confirmando = true;
      d.atualizar();
      final competencia = dataIso(DateTime.now());
      final novos = <Map<String, dynamic>>[];
      try {
        for (final (tomador, servico) in marcados) {
          final form = await chamar<Map>('cadastro.get_servico', {
            'prestador': prest,
            'tomador': tomador,
            'servico': servico,
          });
          if (!ativo()) return;
          novos.add({
            'id': _id(),
            'tomador': tomador,
            'servico': servico,
            'competencia': competencia,
            'form': form,
          });
        }
        setState(() {
          (modelo['linhas'] as List).addAll(novos);
          sujo = true;
        });
        app.fecharEsta(d);
      } catch (e) {
        if (ativo())
          app.toast('Não foi possível carregar os serviços: $e', erro: true);
      } finally {
        confirmando = false;
        if (ativo()) d.atualizar();
      }
    }

    final hover = hoverPadrao.resolve({WidgetState.hovered});
    Widget listaServicos() {
      final doc = cliente;
      if (doc == null) return const Center(child: Tx('Selecione um cliente.'));
      if (carregando.contains(doc)) return Center(child: anel(tamanho: 24));
      if (falhas[doc] case final erro?) return Center(child: Tx(erro));
      final servicos = catalogo[doc] ?? [];
      if (servicos.isEmpty) {
        return const Center(
          child: Tx('Nenhum serviço cadastrado para este cliente.'),
        );
      }
      return ListView.builder(
        key: ValueKey(doc),
        itemCount: servicos.length,
        itemBuilder: (_, i) {
          final s = servicos[i];
          final par = (doc, s['slug'] as String);
          final noLote = existentes.contains(par);
          final selecionado = marcados.contains(par);
          final desabilitado = noLote || confirmando;
          return ListTile(
            dense: true,
            enabled: !desabilitado,
            mouseCursor: desabilitado ? null : SystemMouseCursors.click,
            hoverColor: hover,
            leading: Marcar(
              valor: noLote || selecionado,
              desabilitado: desabilitado,
              aoMudar: (v) => marcar(par, v == true),
              idLayout: 'Lotes.adicionar.marcarServico',
              rente: false, // mantém a área de toque do leading do ListTile
            ),
            title: Tx(
              '${s['nome']}',
              linhas: 2,
              corte: TextOverflow.ellipsis,
              idLayout: 'Lotes.adicionar.itemServico',
            ),
            subtitle: noLote
                ? const Tx(
                    'Já está no lote',
                    tam: Letra.apoio,
                    idLayout: 'Lotes.adicionar.jaNoLote',
                  )
                : null,
            onTap: desabilitado ? null : () => marcar(par, !selecionado),
          );
        },
      );
    }

    d = Dialogo(
      idLayout: 'Janela.lotes.adicionarServicos',
      titulo: (_) => const Tx(
        'Adicionar clientes e serviços ao lote',
        tam: Letra.titulo,
        idLayout: 'Lotes.adicionar.titulo',
      ),
      largura: 820,
      aoFechar: () => aberto = false,
      conteudo: (context) {
        final termo = termosBusca(busca.text);
        final clientes = [
          for (final c in nomesClientes.entries)
            if (termo.every(buscaCompacta(c.value).contains)) c,
        ];
        final contagem = <String, int>{};
        for (final (doc, _) in marcados) {
          contagem.update(doc, (n) => n + 1, ifAbsent: () => 1);
        }
        return SizedBox(
          height: max(
            120.0,
            ajusteLayout(
                  context,
                  'Janela.lotes.adicionarServicos.corpo',
                ).altura ??
                410,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: alvoLayout(
              context,
              _paineisAjustaveis(
                calha: 24,
                esquerdo: (
                  id: 'Lotes.adicionar.painelClientes',
                  nome: 'Painel de clientes',
                  corpo: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Tx(
                        'Clientes',
                        peso: FontWeight.bold,
                        idLayout: 'Lotes.adicionar.tituloClientes',
                      ),
                      const SizedBox(height: 8),
                      CampoTexto(
                        controle: busca,
                        rotulo: 'Pesquisar cliente',
                        expandir: true,
                        iconePrefixo: const Icon(Icons.search),
                        aoMudar: (_) => d.atualizar(),
                        desabilitado: confirmando,
                        idLayout: 'Lotes.adicionar.pesquisa',
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: clientes.isEmpty
                            ? const Center(
                                child: Tx('Nenhum cliente encontrado.'),
                              )
                            : ListView.builder(
                                itemCount: clientes.length,
                                itemBuilder: (context, i) {
                                  final c = clientes[i];
                                  final n = contagem[c.key] ?? 0;
                                  return ListTile(
                                    dense: true,
                                    enabled: !confirmando,
                                    selected: cliente == c.key,
                                    selectedTileColor: Theme.of(
                                      context,
                                    ).colorScheme.secondaryContainer,
                                    hoverColor: hover,
                                    mouseCursor: confirmando
                                        ? null
                                        : SystemMouseCursors.click,
                                    title: Tx(
                                      c.value,
                                      linhas: 2,
                                      corte: TextOverflow.ellipsis,
                                      idLayout: 'Lotes.adicionar.itemCliente',
                                    ),
                                    trailing: n == 0
                                        ? null
                                        : Tx(
                                            '$n',
                                            idLayout:
                                                'Lotes.adicionar.marcados',
                                          ),
                                    onTap: () => selecionarCliente(c.key),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                direito: (
                  id: 'Lotes.adicionar.painelServicos',
                  nome: 'Painel de serviços',
                  corpo: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Tx(
                        'Serviços',
                        peso: FontWeight.bold,
                        idLayout: 'Lotes.adicionar.tituloServicos',
                      ),
                      const SizedBox(height: 8),
                      Expanded(child: listaServicos()),
                    ],
                  ),
                ),
              ),
              id: 'Janela.lotes.adicionarServicos.corpo',
              nome: 'Listas de clientes e serviços',
              tipo: 'grupo',
              grupo: true,
              propriedades: const {'somenteAltura': true},
            ),
          ),
        );
      },
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: () => app.fecharEsta(d),
          idLayout: 'Lotes.adicionar.cancelar',
        ),
        Botao(
          confirmando
              ? 'Adicionando…'
              : marcados.isEmpty
              ? 'Adicionar'
              : 'Adicionar (${marcados.length})',
          desabilitado: marcados.isEmpty || confirmando,
          aoClicar: adicionarMarcados,
          idLayout: 'Lotes.adicionar.confirmar',
        ),
      ],
    );
    busca = d.texto();
    app.mostrarDialogo(d);
  }

  Future<void> importar() async {
    if (!app.temPermissao('lotes.editar')) {
      app.exigirPermissao('lotes.editar', importar);
      return;
    }
    if (sujo && !salvar()) return;
    final prest = prestador;
    final caminho = await escolherArquivo(
      titulo: 'Importar lote do Baiacu',
      extensoes: const ['json'],
    );
    if (caminho == null || !mounted || prest != app.prestador) return;
    try {
      final arquivo = File(caminho);
      if (await arquivo.length() > 5 * 1024 * 1024)
        throw const FormatException('Lote maior que 5 MB.');
      final doc = jsonDecode(await arquivo.readAsString()) as Map;
      if (doc['formato'] != 'baiacu-lote' ||
          doc['versao'] != 1 ||
          doc['prestador'] != app.prestador)
        throw const FormatException(
          'Formato, versão ou prestador incompatível.',
        );
      final novo = Map<String, dynamic>.from(doc['lote'] as Map)
        ..['id'] = _id()
        ..['revisao'] = 0;
      for (final linha in novo['linhas'] as List) {
        linha['id'] = _id();
      }
      if (!mounted || prest != app.prestador) return;
      final salvo = jaMapa('lotes.salvar', {
        'prestador': app.prestador,
        'lote': novo,
      });
      if (!mounted) return;
      setState(() {
        lote = salvo;
        sujo = false;
        editando = false;
        vendoHistorico = false;
        _limparControles();
      });
      carregar();
      app.toast(
        'Lote importado. Confira os dados e as notas existentes antes de emitir.',
      );
    } catch (e) {
      app.toast('Não foi possível importar: $e', erro: true);
    }
  }

  Future<void> exportar() async {
    if (!app.temPermissao('lotes.exportar_modelo')) {
      app.exigirPermissao('lotes.exportar_modelo', exportar);
      return;
    }
    if (!salvar()) return;
    final documento = {
      'formato': 'baiacu-lote',
      'versao': 1,
      'prestador': prestador,
      'lote': lote,
    };
    final destino = await salvarArquivo(
      titulo: 'Exportar lote',
      nome: 'lote-baiacu.json',
      extensoes: const ['json'],
    );
    if (destino == null) return;
    try {
      await File(destino).writeAsString(
        const JsonEncoder.withIndent('  ').convert(documento),
        flush: true,
      );
      app.toast('Lote exportado.');
    } catch (e) {
      app.toast('Não foi possível exportar: $e', erro: true);
    }
  }

  void editar(Map<String, dynamic> linha) {
    if (!editando || ocupado) return;
    abrirCliente(
      app,
      linha['tomador'] as String,
      aba: 1,
      slug: linha['servico'] as String,
      servicoDoLote: Map<String, dynamic>.from(linha['form'] as Map),
      aoConfirmarLote: (form) {
        setState(() {
          final atual = (lote!['linhas'] as List).firstWhere(
            (l) => l['id'] == linha['id'],
          );
          atual['form'] = form;
          for (final chave in ['vServ', 'vDescCond', 'vDescIncond']) {
            controles['${linha['id']}.$chave']?.text = decimalBrl(
              '${form[chave] ?? ''}',
            ).replaceFirst(r'R$ ', '');
          }
          sujo = true;
        });
        return true;
      },
    );
  }

  Future<void> validarEmitir() async {
    if (ocupado || app.ocupado) return;
    for (final permissao in ['lotes.emitir', 'emitir.transmitir']) {
      if (!app.temPermissao(permissao)) {
        app.exigirPermissao(permissao, validarEmitir);
        return;
      }
    }
    if (!salvar() || linhas.isEmpty) return;
    final prest = app.prestador;
    final amb = app.ambiente;
    final modelo = lote!;
    setState(() => ocupado = true);
    bool repetido;
    var avisos = <Map<String, dynamic>>[];
    try {
      repetido = await chamar<bool>('lotes.repetido_intervalo', {
        'prestador': prest,
        'id': modelo['id'],
      });
      try {
        avisos = [
          for (final a in await chamar<List>('lotes.avisos_tributacao', {
            'prestador': prest,
            'id': modelo['id'],
          }))
            Map<String, dynamic>.from(a as Map),
        ];
      } catch (e) {
        // A conferência é só orientação: uma falha nela não impede o envio.
        registrar('Falha ao conferir a tributação do lote: $e', nivel: 'warning');
      }
    } catch (e) {
      if (mounted) app.toast('$e', erro: true);
      return;
    } finally {
      if (mounted) setState(() => ocupado = false);
    }
    if (!mounted ||
        app.prestador != prest ||
        lote != modelo ||
        app.ambiente != amb) {
      return;
    }
    _confirmarEnvio(modelo, prest, amb, repetido: repetido, avisos: avisos);
  }

  void _confirmarEnvio(
    Map<String, dynamic> modelo,
    String prest,
    String amb, {
    required bool repetido,
    List<Map<String, dynamic>> avisos = const [],
  }) {
    final total = (modelo['linhas'] as List).length;
    final notas = total == 1 ? '1 nota' : '$total notas';
    final ambiente = ambRotulos[amb] ?? amb;
    late final Dialogo d;
    late final TextEditingController? palavra;
    bool confirmado() => !repetido || palavra!.text.trim() == 'transmitir';
    void transmitir() {
      if (!d.aberto || !confirmado()) return;
      final confirmacao = palavra?.text.trim() ?? '';
      app.fecharEsta(d);
      _iniciarEnvio(modelo, prest, amb, confirmacao);
    }

    d = Dialogo(
      idLayout: 'Janela.lotes.transmitir',
      titulo: (_) => textoTitulo('Confirmar transmissão do lote'),
      largura: 520,
      conteudo: (context) => col(
        [
          Tx(
            'Deseja transmitir $notas do lote “${modelo['nome']}” em $ambiente?',
          ),
          if (avisos.isNotEmpty) ...[
            Tx(
              '${avisos.length == 1 ? '1 linha tem' : '${avisos.length} linhas têm'} combinação '
              'tributária (IBS/CBS) fora do Anexo VIII da NFS-e e pode ser recusada:',
              cor: Colors.orange.shade800,
              peso: FontWeight.w600,
            ),
            for (final a in avisos.take(5))
              Tx(
                '• ${a['tomador']} · ${a['servico']}: ${((a['avisos'] as List?) ?? const []).join(' ')}',
                tam: Letra.apoio,
              ),
            if (avisos.length > 5)
              Tx('… e mais ${avisos.length - 5}.', tam: Letra.apoio),
          ],
          if (repetido) ...[
            Tx(
              'Este lote já teve uma transmissão iniciada no intervalo configurado. '
              'Uma nova transmissão pode gerar notas em duplicidade.',
              cor: Theme.of(context).colorScheme.error,
              peso: FontWeight.w600,
            ),
            CampoTexto(
              controle: palavra!,
              rotulo: 'Digite “transmitir” para confirmar',
              dicaRotulo: false,
              largura: 310,
              focoInicial: true,
              aoMudar: (_) => d.atualizar(),
              aoEnviar: (_) => transmitir(),
            ),
          ],
        ],
        justa: true,
        espaco: 12,
      ),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.transmitir.botaoCancelar'),
        Botao(
          'Transmitir lote',
          icone: Icons.send_outlined,
          desabilitado: !confirmado(),
          aoClicar: transmitir,
          idLayout: 'Lotes.botaoTransmitirLote',
        ),
      ],
    );
    palavra = repetido ? d.texto() : null;
    app.mostrarDialogo(d);
  }

  Future<void> _iniciarEnvio(
    Map<String, dynamic> modelo,
    String prest,
    String amb,
    String confirmacao,
  ) async {
    if (!mounted ||
        ocupado ||
        app.ocupado ||
        app.prestador != prest ||
        lote != modelo ||
        app.ambiente != amb)
      return;
    setState(() => ocupado = true);
    app.trabalhos++;
    try {
      final dados = await chamar<Map>('lotes.iniciar', {
        'prestador': prest,
        'id': modelo['id'],
        'revisao': modelo['revisao'],
        'ambiente': amb,
        'confirmacao_repeticao': confirmacao,
      });
      if (!mounted || prest != app.prestador) return;
      final novo = Map<String, dynamic>.from(dados)..['ambiente'] = amb;
      setState(() {
        execucao = novo;
        historico = [];
        vendoHistorico = true;
        _limparFiltrosHistorico();
        execucoes = [
          {
            'id': novo['id'],
            'nome': novo['nome'],
            'ambiente': amb,
            'criado': DateTime.now().toIso8601String(),
            'pendentes': (novo['linhas'] as List).length,
            'concluida': false,
          },
          ...execucoes.where((e) => e['id'] != novo['id']),
        ];
        app.lotesPendentes = execucoes
            .where((e) => (e['pendentes'] as int) > 0)
            .length;
        app.tiqueCasca.value++;
      });
    } catch (e) {
      if (mounted) {
        if (e is ErroNucleo &&
            e.tipo == 'LoteRepetidoNoIntervalo' &&
            app.prestador == prest &&
            lote == modelo &&
            app.ambiente == amb) {
          _confirmarEnvio(modelo, prest, amb, repetido: true);
        } else {
          app.toast('$e', erro: true);
        }
      }
      return;
    } finally {
      app.trabalhos--;
      if (mounted) setState(() => ocupado = false);
    }
    await _emitir();
  }

  bool _concluida(Map e) => e['concluida'] == true || e['pendentes'] == 0;

  String _statusRegistro(Map e) => _concluida(e) ? 'Concluído' : 'Pendente';

  bool get execucaoConcluida =>
      execucoes.any((e) => e['id'] == execucao?['id'] && _concluida(e));

  Map<String, dynamic>? _resultadoDaLinha(Map linha) => historico
      .where(
        (e) =>
            e['linha'] == linha['id'] &&
            e['competencia'] == linha['competencia'],
      )
      .firstOrNull;

  bool _aguardando(Object? estado) => estado == null || estado == 'preparando';

  bool _retransmissivel(Object? estado) =>
      _aguardando(estado) || estado == 'falhou' || estado == 'fila';

  void _acompanharEnvio(String execucaoId, int indice) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !vendoHistorico ||
          execucao?['id'] != execucaoId ||
          !rolagemRegistro.hasClients)
        return;
      final posicao = rolagemRegistro.position;
      if (!posicao.hasContentDimensions || !posicao.hasViewportDimension)
        return;
      const altura = Medida.linhaDaTabela;
      final inicio = indice * altura;
      final fim = inicio + altura;
      final double destino;
      if (inicio < posicao.pixels) {
        destino = inicio;
      } else if (fim > posicao.pixels + posicao.viewportDimension) {
        destino = ((fim - posicao.viewportDimension) / altura).ceil() * altura;
      } else {
        return;
      }
      rolagemRegistro.jumpTo(destino.clamp(0.0, posicao.maxScrollExtent));
    });
  }

  Future<void> _emitir({String? apenas, bool todas = false}) async {
    final atual = execucao;
    if (ocupado || app.ocupado || atual == null || execucaoConcluida) return;
    final prest = app.prestador;
    final amb = atual['ambiente'];
    if (amb != app.ambiente) {
      app.toast(
        'Selecione o ambiente desta execução para transmitir.',
        erro: true,
      );
      return;
    }
    for (final permissao in ['lotes.emitir', 'emitir.transmitir']) {
      if (!app.temPermissao(permissao)) {
        app.exigirPermissao(
          permissao,
          () => _emitir(apenas: apenas, todas: todas),
        );
        return;
      }
    }
    setState(() {
      ocupado = true;
      emitindo = true;
      parar = false;
    });
    app.trabalhos++;
    var emitidas = 0;
    try {
      final itens = (atual['linhas'] as List).cast<Map>();
      for (var i = 0; i < itens.length; i++) {
        if (parar || !mounted || prest != app.prestador) break;
        final linha = itens[i];
        final id = linha['id'] as String;
        final estado = _resultadoDaLinha(linha)?['estado'];
        if (apenas == null
            ? !(todas ? _retransmissivel(estado) : _aguardando(estado))
            : id != apenas) {
          continue;
        }
        setState(() => linhaEmEnvio = id);
        _acompanharEnvio(atual['id'] as String, i);
        try {
          await chamar<Map>('lotes.retransmitir', {
            'prestador': prest,
            'id': atual['id'],
            'linha': id,
            'revisao': atual['revisao'],
            'ambiente': amb,
          });
          emitidas++;
        } catch (e) {
          final limitado =
              e is ErroNucleo &&
              e.dados is Map &&
              (e.dados as Map)['status_code'] == 429;
          if (mounted && (limitado || apenas != null)) {
            app.toast('$e', erro: true);
          }
          if (limitado) parar = true;
        }
        await _historico(propagarErro: true);
        if (mounted) setState(() => linhaEmEnvio = null);
      }
      if (emitidas > 0 && mounted) {
        app.toast(
          emitidas == 1 ? '1 nota emitida.' : '$emitidas notas emitidas.',
        );
      }
    } catch (e) {
      if (mounted)
        app.toast('Não foi possível atualizar o registro: $e', erro: true);
    } finally {
      app.notasMudaram();
      app.refazerAvisoFila?.call();
      if (mounted) await atualizarExecucoes();
      app.trabalhos--;
      if (mounted)
        setState(() {
          ocupado = false;
          emitindo = false;
          linhaEmEnvio = null;
        });
    }
  }

  void escolherCompetencia(Map<String, dynamic> linha) {
    abrirCompetencia(
      app,
      lerDataDoCampo(linha['competencia'] as String) ?? DateTime.now(),
      (data, replicar) {
        void aplicar() {
          setState(() {
            for (final l in lote!['linhas'] as List) {
              if (replicar || l['id'] == linha['id']) {
                l['competencia'] = dataIso(data);
              }
            }
            sujo = true;
          });
        }

        if (!replicar) {
          aplicar();
          return;
        }
        late final Dialogo d;
        d = Dialogo(
          titulo: (_) => textoTitulo('Replicar competência'),
          largura: 500,
          conteudo: (_) => Tx(
            'Atualizar a competência de todas as linhas do lote para ${dataIsoParaBr(dataIso(data))}?',
          ),
          acoes: (_) => [
            Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.botaoCancelar4'),
            Botao(
              'Confirmar',
              aoClicar: () {
                app.fecharEsta(d);
                aplicar();
              },
              idLayout: 'Lotes.botaoConfirmar',
            ),
          ],
        );
        app.mostrarDialogo(d);
      },
      permitirReplicar: true,
    );
  }

  void removerLinha(Map<String, dynamic> linha) {
    if (!editando || ocupado) return;
    late final Dialogo d;
    d = Dialogo(
      titulo: (_) => textoTitulo('Excluir linha do lote'),
      largura: 480,
      conteudo: (_) => Tx(
        'Excluir ${nomesClientes[linha['tomador']] ?? linha['tomador']} e o serviço ${linha['form']['nome'] ?? linha['servico']} deste lote?',
      ),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.botaoCancelar5'),
        Botao(
          'Excluir linha',
          aoClicar: () {
            app.fecharEsta(d);
            setState(() {
              (lote!['linhas'] as List).removeWhere(
                (l) => l['id'] == linha['id'],
              );
              sujo = true;
            });
          },
          idLayout: 'Lotes.botaoExcluirLinha',
        ),
      ],
    );
    app.mostrarDialogo(d);
  }

  void voltar() {
    if (ocupado) return;
    setState(() {
      vendoHistorico = false;
      pesquisa.clear();
    });
  }

  void _sincronizarPeriodo() {
    filtroPeriodo.opcoes = [
      _todoPeriodo,
      ...opcoesDePeriodo(
        periodoHistorico == 'custom'
            ? textoDoIntervalo(periodoDe, periodoAte)
            : '',
      ),
    ];
    filtroPeriodo.por(periodoHistorico);
    filtroPeriodo.avisar();
  }

  void _limparFiltrosHistorico() {
    pesquisa.clear();
    periodoHistorico = 'todos';
    periodoDe = periodoAte = null;
    _sincronizarPeriodo();
    filtroAmbiente.por('todos');
    filtroAmbiente.avisar();
  }

  void _selecionarPeriodo(String? valor) {
    if (valor == 'custom') {
      abrirPeriodo(
        app,
        periodoDe,
        periodoAte,
        (de, ate) => setState(() {
          periodoDe = de;
          periodoAte = ate;
          periodoHistorico = 'custom';
          _sincronizarPeriodo();
        }),
        _sincronizarPeriodo,
      );
      return;
    }
    setState(() {
      periodoHistorico = valor ?? 'todos';
      _sincronizarPeriodo();
    });
  }

  String _dataRegistro(DateTime? data) {
    if (data == null) return 'Sem data registrada';
    String dois(int numero) => numero.toString().padLeft(2, '0');
    return '${dataBr(data)} - ${dois(data.hour)}:${dois(data.minute)}';
  }

  DateTime? _dataCriacao(Map e) =>
      DateTime.tryParse('${e['criado'] ?? ''}')?.toLocal();

  List<Map<String, dynamic>> get _registrosVisiveis {
    final busca = termosBusca(pesquisa.text);
    final amb = filtroAmbiente.valor;
    final (ini, fim) = periodoHistorico == 'todos'
        ? (null, null)
        : datasDoPeriodo(periodoHistorico, periodoDe, periodoAte);
    final de = dataIso(ini);
    final ate = dataIso(fim);
    return execucoes.where((e) {
      if (amb != 'todos' && e['ambiente'] != amb) return false;
      final data = _dataCriacao(e);
      final dia = dataIso(data);
      if (de.isNotEmpty && dia.compareTo(de) < 0) return false;
      if (ate.isNotEmpty && (dia.isEmpty || dia.compareTo(ate) > 0)) {
        return false;
      }
      if (busca.isEmpty) return true;
      final ambiente = filtroAmbiente.textoDe(e['ambiente'] as String?);
      final texto = buscaCompacta(
        '${e['nome']} ${e['id']} ${_dataRegistro(data)} $dia '
        '$ambiente ${_statusRegistro(e)}',
      );
      return busca.every(texto.contains);
    }).toList();
  }

  void _abrirExportarRegistros() {
    final registros = _registrosVisiveis;
    if (registros.isEmpty) return;
    if (!app.temPermissao('lotes.exportar')) {
      app.exigirPermissao('lotes.exportar', _abrirExportarRegistros);
      return;
    }
    final prest = app.prestador;
    final ids = [for (final e in registros) e['id'] as String];
    final selecionado = execucao?['id'] as String?;
    final temSelecionado = ids.contains(selecionado);
    final formatos = <String>{'pdf'};
    var xml = true, danfse = false;
    late final Suspensa escopo;
    late final Dialogo d;
    d = Dialogo(
      idLayout: 'Janela.historicoLotes.exportar',
      titulo: (_) => textoTitulo('Exportar dados'),
      largura: 420,
      conteudo: (_) => col([
        ListaSuspensa(
          estado: escopo,
          rotulo: 'Registros',
          largura: 320,
          buscar: false,
          idLayout: 'Lotes.listaRegistros',
        ),
        const Tx('Relatório', peso: FontWeight.w600),
        lin(
          [
            for (final e in formatosExportacao.entries)
              Marcar(
                rotulo: e.value.$2,
                valor: formatos.contains(e.key),
                aoMudar: (v) {
                  if (v == true) {
                    formatos.add(e.key);
                  } else {
                    formatos.remove(e.key);
                  }
                  d.atualizar();
                },
                idLayout: 'HistoricoLotes.exportar.marcarFormato',
              ),
          ],
          quebra: true,
          espaco: 8,
        ),
        const Tx('Documentos das notas emitidas', peso: FontWeight.w600),
        lin(
          [
            Marcar(
              rotulo: 'XML das NFS-e',
              valor: xml,
              aoMudar: (v) {
                xml = v == true;
                d.atualizar();
              },
              idLayout: 'Lotes.marcarXmlDasNfsE',
            ),
            Marcar(
              rotulo: 'DANFSe (.pdf)',
              rente: false, // vem depois da opção de XML
              valor: danfse,
              aoMudar: (v) {
                danfse = v == true;
                d.atualizar();
              },
              idLayout: 'Lotes.marcarDanfsePdf',
            ),
          ],
          quebra: true,
          espaco: 8,
        ),
      ], justa: true),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'HistoricoLotes.exportar.botaoCancelar'),
        Botao(
          'Exportar',
          icone: Icons.download,
          desabilitado: formatos.isEmpty && !xml && !danfse,
          aoClicar: () {
            final escolhidos = escopo.valor == 'selecionado'
                ? [selecionado!]
                : ids;
            app.fecharEsta(d);
            _exportarRegistros(
              prest,
              escolhidos,
              formatos.toList(),
              xml,
              danfse,
            );
          },
          idLayout: 'HistoricoLotes.exportar.botaoExportar',
        ),
      ],
    );
    escopo = d.suspensa(
      valor: temSelecionado ? 'selecionado' : 'filtrados',
      opcoes: [
        if (temSelecionado) const Opcao('selecionado', 'Registro selecionado'),
        Opcao('filtrados', 'Registros filtrados (${registros.length})'),
      ],
    );
    app.mostrarDialogo(d);
  }

  Future<void> _exportarRegistros(
    String prest,
    List<String> ids,
    List<String> formatos,
    bool xml,
    bool danfse,
  ) async {
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Exportar dados (.zip)',
        nome: 'registros_lotes_${dataIso(DateTime.now())}.zip',
        extensoes: const ['zip'],
      );
    } catch (e) {
      if (mounted)
        app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (!mounted ||
        prest != app.prestador ||
        destino == null ||
        destino.isEmpty) {
      return;
    }
    final caminho = destino.toLowerCase().endsWith('.zip')
        ? destino
        : '$destino.zip';
    final progresso = ProgressoExportacao(app)..abrir();
    await app.emSegundoPlano(() async {
      try {
        final r = await chamar<Map>(
          'exportacao.lotes_zip',
          {
            'prestador': prest,
            'destino': caminho,
            'execucoes': ids,
            'formatos': formatos,
            'incluir_xml': xml,
            'incluir_danfse': danfse,
            'ficha': progresso.ficha,
          },
          (aviso) {
            if (progresso.cancelada) return;
            if (aviso is Map && aviso['etapa'] is String) {
              progresso.etapa(
                aviso['etapa'] as String,
                indeterminada: aviso['indeterminada'] == true,
              );
            } else {
              progresso.aviso(aviso);
            }
          },
        );
        if (progresso.cancelada) return;
        final itens = [
          '${r['lotes']} lote(s)',
          if (r['relatorios'] != 0) '${r['relatorios']} relatório(s)',
          if (r['xml'] != 0) '${r['xml']} XML(s)',
          if (r['danfse'] != 0) '${r['danfse']} DANFSe',
        ];
        final faltas = r['sem_xml'] == 0
            ? ''
            : ' ${r['sem_xml']} nota(s) emitida(s) sem XML disponível no Cofre.';
        app.toast('Exportação concluída. ${itens.join(' · ')}.$faltas');
      } catch (e) {
        if (!progresso.cancelada) app.toast('$e', erro: true);
      } finally {
        progresso.fechar();
      }
    });
  }

  void importarExportar() {
    late final Dialogo d;
    d = Dialogo(
      titulo: (_) => textoTitulo('Importar / exportar lote'),
      largura: 440,
      conteudo: (_) =>
          const Tx('Importe um lote do Baiacu ou exporte o lote selecionado.'),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.botaoCancelar7'),
        const Spacer(),
        Botao.contorno(
          'Importar',
          aoClicar: () {
            app.fecharEsta(d);
            importar();
          },
          idLayout: 'Lotes.botaoImportar',
        ),
        Botao(
          'Exportar',
          desabilitado: lote == null,
          aoClicar: () {
            app.fecharEsta(d);
            exportar();
          },
          idLayout: 'Lotes.botaoExportar2',
        ),
      ],
    );
    app.mostrarDialogo(d);
  }

  Future<void> abrirExecucao(Map<String, dynamic> e) async {
    if (ocupado) return;
    final prest = app.prestador;
    setState(() => ocupado = true);
    try {
      final dados = await chamar<Map>('lotes.obter', {
        'prestador': prest,
        'id': e['id'],
      });
      if (!mounted || prest != app.prestador) return;
      setState(() {
        execucao = Map<String, dynamic>.from(dados)
          ..['ambiente'] = e['ambiente'];
        historico = [];
        vendoHistorico = true;
      });
      await _historico();
    } catch (erro) {
      app.toast('$erro', erro: true);
    } finally {
      if (mounted) setState(() => ocupado = false);
    }
  }

  Future<bool> _alterarRegistro(
    String metodo, {
    Map? linha,
    Map<String, dynamic>? form,
  }) async {
    final atual = execucao;
    if (ocupado || atual == null || execucaoConcluida) return false;
    setState(() => ocupado = true);
    app.trabalhos++;
    try {
      final dados = await chamar<Object?>(metodo, {
        'prestador': app.prestador,
        'id': atual['id'],
        'ambiente': atual['ambiente'],
        if (linha != null) 'linha': linha['id'],
        if (form != null) 'form': form,
      });
      if (mounted && dados is Map && execucao?['id'] == atual['id']) {
        setState(
          () =>
              execucao = Map<String, dynamic>.from(dados)
                ..['ambiente'] = atual['ambiente'],
        );
      }
      return true;
    } catch (e) {
      if (mounted) app.toast('$e', erro: true);
      return false;
    } finally {
      if (mounted) {
        await _historico();
        await atualizarExecucoes();
      }
      app.trabalhos--;
      if (mounted) setState(() => ocupado = false);
    }
  }

  bool _autorizarTratamento(VoidCallback acao, {bool editar = false}) {
    for (final permissao in [
      'lotes.emitir.tratar',
      if (editar) 'lotes.editar',
    ]) {
      if (!app.temPermissao(permissao)) {
        app.exigirPermissao(permissao, acao);
        return false;
      }
    }
    return true;
  }

  void _editarRegistro(Map linha) {
    if (!_autorizarTratamento(() => _editarRegistro(linha), editar: true))
      return;
    abrirCliente(
      app,
      linha['tomador'] as String,
      aba: 1,
      slug: linha['servico'] as String,
      servicoDoLote: Map<String, dynamic>.from(linha['form'] as Map),
      aoConfirmarLote: (form) =>
          _alterarRegistro('lotes.editar_linha', linha: linha, form: form),
    );
  }

  void _confirmarTratamento({Map? linha}) {
    if (!_autorizarTratamento(() => _confirmarTratamento(linha: linha))) return;
    final remover = linha != null;
    final titulo = remover
        ? 'Remover linha da emissão'
        : 'Finalizar o lote mesmo assim';
    late final Dialogo d;
    d = Dialogo(
      titulo: (_) => textoTitulo(titulo),
      largura: 540,
      conteudo: (_) => Tx(
        remover
            ? 'A linha ficará riscada no registro e deixará de ser enviada por esta execução.'
            : 'Concluir a execução com as pendências atuais? As linhas e o histórico continuarão visíveis.',
      ),
      acoes: (_) => [
        Botao.texto('Cancelar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.pendencia.botaoCancelar'),
        Botao(
          remover ? 'Remover linha' : 'Finalizar lote',
          aoClicar: () {
            app.fecharEsta(d);
            _alterarRegistro(
              remover ? 'lotes.remover_falha' : 'lotes.finalizar',
              linha: linha,
            );
          },
          idLayout: 'Lotes.pendencia.botaoConfirmar',
        ),
      ],
    );
    app.mostrarDialogo(d);
  }

  Widget tabelaHistorico() {
    final itens = (execucao!['linhas'] as List).cast<Map>();
    final anteriores = execucao!['nome'].toString().endsWith(
      '(histórico anterior)',
    );
    const larguras = [205.0, 165.0, 95.0, 94.0, 99.0, 191.0, 102.0];
    const titulos = [
      'Cliente',
      'Serviço',
      'Competência',
      'Número',
      'Valor serviço',
      'Situação',
      'Ações',
    ];
    return TabelaCabecalhoFixo(
      key: ValueKey(execucao!['id']),
      controleVertical: rolagemRegistro,
      quantidade: itens.length,
      alturaLinha: Medida.linhaDaTabela,
      alturaCabecalho: Medida.cabecalhoDaTabela,
      larguras: larguras,
      colunasLayout: [
        for (final titulo in titulos) 'HistoricoLotes.coluna.$titulo',
      ],
      largurasMinimas: const {6: 130},
      entradas: [
        execucao,
        historico,
        ocupado,
        linhaEmEnvio,
        execucaoConcluida,
        app.ambiente,
      ],
      montar: (primeira, ultima, chave) => TabelaPadrao(
        columns: [
          for (final titulo in titulos)
            DataColumn(
              label: Tx(
                titulo,
                tam: Letra.cabecalhoDaTabela,
                peso: FontWeight.bold,
                idLayout: 'HistoricoLotes.cabecalho.$titulo',
              ),
            ),
        ],
        rows: [
          for (var i = primeira; i <= ultima; i++)
            linhaHistorico(itens[i], anteriores, chave(i)),
        ],
      ),
    );
  }

  DataRow linhaHistorico(Map linha, bool anteriores, LocalKey chave) {
    final h = _resultadoDaLinha(linha);
    final estado = h?['estado'];
    final numero = estado == 'emitida' ? _numeroDaNota(h!) : '-';
    final removida = estado == 'removida';
    final enviando = linhaEmEnvio == linha['id'];
    final concluida = execucaoConcluida;
    final pendente = [
      'falhou',
      'fila',
      'conferir',
      'enviando',
    ].contains(estado);
    final tratando = pendente && !concluida && !enviando;
    final resultado = h?['resultado'];
    final erro = resultado is Map ? '${resultado['erro'] ?? ''}'.trim() : '';
    final espera = estado == null || estado == 'preparando';
    final situacao = enviando
        ? 'Enviando'
        : switch (estado) {
            'emitida' => 'Emitida',
            'fila' => 'Em contingência',
            'falhou' => 'Falhou',
            'conferir' || 'enviando' => 'Envio a conferir',
            'removida' => 'Removida',
            _ => concluida ? 'Encerrada sem envio' : 'Aguardando',
          };
    final corTexto = removida ? Colors.grey.shade700 : null;
    Tx texto(String valor, {String? dica, String? idLayout}) => Tx(
      valor,
      idLayout: idLayout,
      tam: Letra.tabela,
      cor: corTexto,
      dica: dica,
      linhas: 1,
      corte: TextOverflow.ellipsis,
      tema: removida
          ? (_) => const TextStyle(decoration: TextDecoration.lineThrough)
          : null,
    );
    return DataRow(
      key: chave,
      color: WidgetStatePropertyAll(
        removida
            ? Colors.grey.shade200
            : (pendente && !enviando ? Colors.orange.shade50 : null),
      ),
      cells: [
        DataCell(
          texto(
            nomesClientes[linha['tomador']] ?? '${linha['tomador']}',
            idLayout: 'HistoricoLotes.linha.cliente',
          ),
        ),
        DataCell(
          texto(
            anteriores
                ? 'Valores não preservados'
                : '${linha['form']['nome'] ?? linha['servico']}',
            idLayout: 'HistoricoLotes.linha.resultado',
          ),
        ),
        DataCell(
          texto(
            dataIsoParaBr(linha['competencia'] as String),
            idLayout: 'HistoricoLotes.linha.competencia',
          ),
        ),
        DataCell(texto(numero, idLayout: 'HistoricoLotes.linha.numero')),
        DataCell(
          Align(
            alignment: Alignment.centerRight,
            child: texto(
              anteriores
                  ? '—'
                  : decimalBrl(
                      '${linha['form']['vServ'] ?? ''}',
                    ).replaceFirst(r'R$ ', ''),
              idLayout: 'HistoricoLotes.linha.valor',
            ),
          ),
        ),
        DataCell(
          Row(
            spacing: 6,
            children: [
              if (enviando || (espera && !concluida)) anel(tamanho: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    texto(
                      situacao,
                      dica: erro.isEmpty ? null : erro,
                      idLayout: 'HistoricoLotes.linha.situacao',
                    ),
                    if (linha['editada'] == true)
                      texto(
                        'Dados editados',
                        idLayout: 'HistoricoLotes.linha.editada',
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tratando) ...[
                BotaoIcone(
                  Icons.edit_outlined,
                  dica: 'Editar dados desta emissão',
                  largura: Medida.botaoDaLinha,
                  altura: Medida.botaoDaLinha,
                  estilo: _estiloAcaoDaLinha,
                  desabilitado: ocupado,
                  idLayout: 'HistoricoLotes.linha.editar',
                  aoClicar: () => _editarRegistro(linha),
                ),
                BotaoIcone(
                  Icons.delete_outline,
                  dica: 'Remover linha desta emissão',
                  largura: Medida.botaoDaLinha,
                  altura: Medida.botaoDaLinha,
                  estilo: _estiloAcaoDaLinha,
                  desabilitado: ocupado,
                  idLayout: 'HistoricoLotes.linha.remover',
                  aoClicar: () => _confirmarTratamento(linha: linha),
                ),
              ],
              if ((pendente || erro.isNotEmpty) && !removida)
                BotaoIcone(
                  Icons.info_outline,
                  dica: 'Informações da emissão',
                  largura: Medida.botaoDaLinha,
                  altura: Medida.botaoDaLinha,
                  estilo: _estiloAcaoDaLinha,
                  aoClicar: () => _informacoesEmissao(
                    linha['id'] as String,
                    situacao,
                    erro,
                    podeRetransmitir: tratando && _retransmissivel(estado),
                  ),
                  idLayout: 'Lotes.botaoIconeInformacoesDaEmissao',
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _numeroDaNota(Map registro) {
    final resultado = registro['resultado'];
    final oficial = resultado is Map ? resultado['official_nfse'] : null;
    for (final valor in [
      registro['nNFSe'],
      if (oficial is Map) oficial['nNFSe'],
      if (resultado is Map) resultado['nNFSe'],
    ]) {
      if (valor is String && valor.trim().isNotEmpty) return valor.trim();
      if (valor is int) return '$valor';
    }
    return '-';
  }

  void _informacoesEmissao(
    String linha,
    String situacao,
    String erro, {
    required bool podeRetransmitir,
  }) {
    late final Dialogo d;
    d = Dialogo(
      idLayout: 'Janela.lotes.resultadoEmissao',
      titulo: (_) => textoTitulo('Resultado da emissão'),
      largura: 620,
      conteudo: (_) => col(
        [Tx(situacao, peso: FontWeight.w600), if (erro.isNotEmpty) Tx(erro)],
        justa: true,
        espaco: 8,
      ),
      acoes: (_) => [
        Botao.texto('Fechar', aoClicar: () => app.fecharEsta(d), idLayout: 'Lotes.resultadoEmissao.botaoFechar'),
        if (podeRetransmitir)
          Botao(
            'Tentar retransmitir',
            idLayout: 'HistoricoLotes.linha.retransmitir',
            desabilitado: ocupado || app.ambiente != execucao?['ambiente'],
            aoClicar: () {
              app.fecharEsta(d);
              _emitir(apenas: linha);
            },
          ),
      ],
    );
    app.mostrarDialogo(d);
  }

  Widget _paineisAjustaveis({
    required ({String id, String nome, Widget corpo}) esquerdo,
    required ({String id, String nome, Widget corpo}) direito,
    required double calha,
    double? larguraEsquerda,
  }) => LayoutBuilder(
    builder: (context, limites) {
      final divisor = min(calha, limites.maxWidth);
      final disponivel = limites.maxWidth - divisor;
      final minimaEsquerda = min(115.0, disponivel / 3);
      final minimaDireita = min(180.0, disponivel / 2);
      final maximaEsquerda = disponivel - minimaDireita;
      final esquerda =
          (ajusteLayout(context, esquerdo.id).largura ??
                  larguraEsquerda ??
                  disponivel * .4)
              .clamp(minimaEsquerda, maximaEsquerda);
      final maximaDireita = disponivel - esquerda;
      final direita =
          (ajusteLayout(context, direito.id).largura ?? maximaDireita).clamp(
            minimaDireita,
            maximaDireita,
          );

      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          alvoLarguraLayout(
            context,
            SizedBox(width: esquerda, child: esquerdo.corpo),
            id: esquerdo.id,
            nome: esquerdo.nome,
            largura: esquerda,
            minima: minimaEsquerda,
            maxima: maximaEsquerda,
          ),
          VerticalDivider(width: divisor),
          alvoLarguraLayout(
            context,
            SizedBox(width: direita, child: direito.corpo),
            id: direito.id,
            nome: direito.nome,
            largura: direita,
            minima: minimaDireita,
            maxima: maximaDireita,
          ),
        ],
      );
    },
  );

  Widget historicoWidget(List<Map<String, dynamic>> registros) {
    final selecionado = registros.any((e) => e['id'] == execucao?['id']);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _paineisAjustaveis(
              calha: 14,
              larguraEsquerda: 176,
              esquerdo: (
                id: 'HistoricoLotes.painel.lista',
                nome: 'Painel de lotes',
                corpo: registros.isEmpty
                    ? const Center(child: Tx('Nenhum registro encontrado.'))
                    : Material(
                        type: MaterialType.transparency,
                        child: ListView.builder(
                          itemCount: registros.length,
                          itemBuilder: (context, i) {
                            final e = registros[i];
                            final nome = '${e['nome']}';
                            return ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              selected: execucao?['id'] == e['id'],
                              selectedTileColor: Theme.of(
                                context,
                              ).colorScheme.secondaryContainer,
                              hoverColor: hoverPadrao.resolve({
                                WidgetState.hovered,
                              }),
                              mouseCursor: SystemMouseCursors.click,
                              title: Tx(
                                nome,
                                tam: Letra.tabela,
                                peso: FontWeight.w600,
                                linhas: 2,
                                corte: TextOverflow.ellipsis,
                                dica: nome,
                                idLayout: 'HistoricoLotes.item.nome',
                              ),
                              subtitle: Tx(
                                '${_dataRegistro(_dataCriacao(e))}\n${_statusRegistro(e)}',
                                tam: Letra.apoio,
                                idLayout: 'HistoricoLotes.item.dataStatus',
                              ),
                              onTap: ocupado ? null : () => abrirExecucao(e),
                            );
                          },
                        ),
                      ),
              ),
              direito: (
                id: 'HistoricoLotes.painel.registro',
                nome: 'Painel do registro',
                corpo: !selecionado
                    ? const Center(
                        child: Tx('Selecione uma emissão realizada.'),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Tx(
                            '${execucao!['nome']}',
                            tam: Letra.subtitulo,
                            peso: FontWeight.bold,
                            idLayout: 'HistoricoLotes.registro.nome',
                          ),
                          const SizedBox(height: 14),
                          Expanded(child: tabelaHistorico()),
                        ],
                      ),
              ),
            ),
          ),
          divisor(altura: 1),
          const SizedBox(height: 14),
          Row(
            spacing: Medida.espacoEntreCampos,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Botao(
                'Voltar',
                icone: Icons.arrow_back,
                fundo: ocupado ? null : Colors.indigo.shade700,
                cor: ocupado ? null : Colors.white,
                aoClicar: voltar,
                desabilitado: ocupado,
                idLayout: 'HistoricoLotes.voltar',
              ),
              Expanded(
                child: lin(
                  [
                    if (emitindo)
                      Botao.texto(
                        'Parar após esta nota',
                        aoClicar: () => setState(() => parar = true),
                        idLayout: 'Lotes.botaoPararAposEstaNota',
                      ),
                    if (!emitindo && !execucaoConcluida && selecionado) ...[
                      Botao.contorno(
                        'Retransmitir tudo',
                        icone: Icons.replay,
                        idLayout: 'HistoricoLotes.retransmitir',
                        desabilitado:
                            ocupado ||
                            execucao?['ambiente'] != app.ambiente ||
                            !(execucao!['linhas'] as List).cast<Map>().any(
                              (linha) => _retransmissivel(
                                _resultadoDaLinha(linha)?['estado'],
                              ),
                            ),
                        aoClicar: () => _emitir(todas: true),
                      ),
                      Botao(
                        'Finalizar o lote mesmo assim',
                        icone: Icons.check,
                        idLayout: 'HistoricoLotes.finalizar',
                        desabilitado: ocupado,
                        aoClicar: _confirmarTratamento,
                      ),
                    ],
                  ],
                  quebra: true,
                  principal: MainAxisAlignment.end,
                  idLayout: 'Grupo.historicoLotes.rodape',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget campo(Map<String, dynamic> linha, String chave, double largura) =>
      alvoLayout(
        context,
        campoInterno(linha, chave, largura),
        id: 'Lotes.valor.$chave',
        nome: chave,
        tipo: 'campo',
      );

  Widget campoInterno(
    Map<String, dynamic> linha,
    String chave,
    double largura,
  ) {
    final id = '${linha['id']}.$chave';
    final form = linha['form'] as Map;
    final valor = chave == 'competencia'
        ? dataIsoParaBr(linha['competencia'] as String)
        : decimalBrl('${form[chave] ?? ''}').replaceFirst(r'R$ ', '');
    final desabilitado =
        ocupado ||
        (chave != 'competencia' && '${form['cTribNac']}'.startsWith('9905'));
    final ajuste = ajusteLayout(context, 'Lotes.valor.$chave');
    final altura = (ajuste.altura ?? Medida.botaoDaLinha).clamp(
      20.0,
      Medida.linhaDaTabela,
    );
    if (!editando) {
      return SizedBox(
        width: largura,
        child: Tx(
          valor,
          tam: Letra.tabela,
          alinhar: chave == 'competencia' ? TextAlign.center : TextAlign.right,
        ),
      );
    }
    if (chave == 'competencia') {
      return SizedBox(
        width: largura,
        height: altura,
        child: Botao.texto(
          null,
          compacto: true,
          desabilitado: desabilitado,
          dica: 'Escolher a competência',
          aoClicar: () => escolherCompetencia(linha),
          filho: Text(
            valor,
            style: ajuste.estilo(const TextStyle(fontSize: Letra.tabela)),
          ),
          idLayout: 'Lotes.botaoEscolherACompetencia',
        ),
      );
    }
    return CampoTexto(
      controle: controles.putIfAbsent(
        id,
        () => TextEditingController(text: valor),
      ),
      largura: largura,
      compacto: true,
      altura: altura,
      denso: false,
      desabilitado: desabilitado,
      alinhamento: TextAlign.right,
      estilo: ajuste.estilo(const TextStyle(fontSize: Letra.tabela)),
      preenchimento: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      mascara: (texto) => brlDigitos(texto).replaceFirst(r'R$ ', ''),
      aoMudar: (texto) => setState(() {
        final atual = (lote!['linhas'] as List).firstWhere(
          (l) => l['id'] == linha['id'],
        );
        atual['form'][chave] = brlDecimal(texto);
        sujo = true;
      }),
    );
  }

  Widget grade() => LayoutBuilder(
    builder: (context, limites) {
      final itens = linhas;
      final largura = max(1100.0, limites.maxWidth);
      const chaves = [
        'cliente',
        'servico',
        'vServ',
        'vDescCond',
        'vDescIncond',
        'competencia',
        'acoes',
      ];
      const titulos = [
        'Cliente',
        'Serviço',
        'Valor do serviço',
        'Desc. cond.',
        'Desc. incond.',
        'Competência',
        'Ações',
      ];
      const pesos = [22, 18, 12, 11, 11, 12, 18];
      const minimas = [100.0, 100.0, 120.0, 105.0, 105.0, 108.0, 106.0];
      final larguras = [
        for (var i = 0; i < chaves.length; i++)
          max(
            minimas[i],
            ajusteLayout(context, 'Lotes.coluna.${chaves[i]}').largura ??
                largura * pesos[i] / 104,
          ),
      ];
      Widget celula(int i, Widget child) => SizedBox(
        width: larguras[i],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      );
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: larguras.reduce((a, b) => a + b),
          child: Column(
            children: [
              SizedBox(
                height: Medida.cabecalhoDaTabela,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (var i = 0; i < chaves.length; i++)
                      alvoLarguraLayout(
                        context,
                        celula(
                          i,
                          Tx(
                            titulos[i],
                            tam: Letra.cabecalhoDaTabela,
                            peso: FontWeight.bold,
                            idLayout: 'Lotes.cabecalho.${chaves[i]}',
                            linhas: 1,
                            corte: TextOverflow.ellipsis,
                          ),
                        ),
                        id: 'Lotes.coluna.${chaves[i]}',
                        nome: 'Coluna ${titulos[i]}',
                        largura: larguras[i],
                        minima: minimas[i],
                      ),
                  ],
                ),
              ),
              divisor(altura: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: itens.length,
                  itemBuilder: (context, i) {
                    final l = itens[i];
                    final form = l['form'] as Map;
                    return Container(
                      key: ValueKey(l['id']),
                      height: Medida.linhaDaTabela,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: PadraoControles.separador,
                            width: 0,
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          celula(
                            0,
                            Tx(
                              nomesClientes[l['tomador']] ?? '${l['tomador']}',
                              tam: Letra.tabela,
                              linhas: 1,
                              corte: TextOverflow.ellipsis,
                              dica: nomesClientes[l['tomador']],
                              idLayout: 'Lotes.linha.cliente',
                            ),
                          ),
                          celula(
                            1,
                            Tx(
                              '${form['nome'] ?? l['servico']}',
                              tam: Letra.tabela,
                              linhas: 1,
                              corte: TextOverflow.ellipsis,
                              idLayout: 'Lotes.linha.servico',
                            ),
                          ),
                          for (var c = 2; c <= 5; c++)
                            celula(c, campo(l, chaves[c], larguras[c] - 20)),
                          celula(
                            6,
                            Row(
                              children: [
                                BotaoIcone(
                                  Icons.edit_outlined,
                                  dica: 'Editar serviço no lote',
                                  largura: 32,
                                  altura: 32,
                                  estilo: _estiloAcaoDaLinha,
                                  desabilitado: ocupado || !editando,
                                  aoClicar: () => editar(l),
                                  idLayout: 'Lotes.linha.editar',
                                ),
                                BotaoIcone(
                                  Icons.delete_outline,
                                  dica: 'Excluir linha do lote',
                                  largura: 32,
                                  altura: 32,
                                  estilo: _estiloAcaoDaLinha,
                                  desabilitado: ocupado || !editando,
                                  aoClicar: () => removerLinha(l),
                                  idLayout: 'Lotes.linha.excluir',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final registros = vendoHistorico
        ? _registrosVisiveis
        : const <Map<String, dynamic>>[];
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (vendoHistorico) ...[
            lin(
              [
                Expanded(
                  child: Tx(
                    'Registros de emissão em lote',
                    tam: Letra.titulo,
                    peso: FontWeight.bold,
                    idLayout: 'HistoricoLotes.titulo',
                  ),
                ),
                Botao.contorno(
                  'Exportar dados',
                  icone: Icons.download,
                  aoClicar: _abrirExportarRegistros,
                  desabilitado: ocupado || registros.isEmpty,
                  idLayout: 'HistoricoLotes.exportar',
                ),
              ],
              altura: Medida.campo,
              idLayout: 'Grupo.historicoLotes.topo',
            ),
            const SizedBox(height: 14),
            lin(
              [
                CampoTexto(
                  controle: pesquisa,
                  rotulo: 'Pesquisar emissões realizadas',
                  largura: 345,
                  iconePrefixo: const Icon(Icons.search),
                  desabilitado: ocupado,
                  aoMudar: (_) => setState(() {}),
                  idLayout: 'HistoricoLotes.pesquisa',
                ),
                ListaSuspensa(
                  estado: filtroPeriodo,
                  rotulo: 'Período da emissão do lote',
                  largura: periodoHistorico == 'custom'
                      ? larguraPeriodoComDatas
                      : 220,
                  desabilitado: ocupado,
                  buscar: false,
                  aoSelecionar: _selecionarPeriodo,
                  idLayout: 'HistoricoLotes.periodo',
                ),
                ListaSuspensa(
                  estado: filtroAmbiente,
                  rotulo: 'Ambiente',
                  largura: 155,
                  desabilitado: ocupado,
                  buscar: false,
                  aoSelecionar: (_) => setState(() {}),
                  idLayout: 'HistoricoLotes.ambiente',
                ),
              ],
              quebra: true,
              idLayout: 'Grupo.historicoLotes.filtros',
            ),
            const SizedBox(height: 14),
            historicoWidget(registros),
          ] else ...[
            lin(
              [
                Expanded(
                  child: Tx(
                    'Emitir em lote',
                    tam: Letra.titulo,
                    peso: FontWeight.bold,
                    idLayout: 'Lotes.titulo',
                  ),
                ),
                lin(
                  [
                    Botao.contorno(
                      'Importar / exportar lote',
                      icone: Icons.import_export,
                      aoClicar: importarExportar,
                      desabilitado: ocupado || editando,
                      idLayout: 'Lotes.importarExportar',
                    ),
                    _BotaoHistorico(
                      pendente: app.lotesPendentes > 0,
                      desabilitado: ocupado || editando,
                      aoClicar: () {
                        atualizarExecucoes();
                        setState(() => vendoHistorico = true);
                      },
                    ),
                  ],
                  justa: true,
                  espaco: Medida.espacoEntreCampos,
                  idLayout: 'Grupo.lotes.acoesTopo',
                ),
              ],
              altura: Medida.campo,
              idLayout: 'Grupo.lotes.topo',
            ),
            const SizedBox(height: 14),
            lin(
              [
                ListaSuspensa(
                  estado: escolha,
                  rotulo: 'Lote salvo',
                  largura: 360,
                  aoSelecionar: abrir,
                  desabilitado: ocupado || editando,
                  idLayout: 'Lotes.selecao',
                ),
                if (editando)
                  BotaoIcone(
                    Icons.edit_outlined,
                    dica: 'Renomear ou excluir o lote',
                    aoClicar: () => _editarNome(renomear: true),
                    desabilitado: ocupado,
                    idLayout: 'Lotes.editarNome',
                  )
                else
                  Botao(
                    'Criar lote',
                    icone: Icons.add,
                    aoClicar: criar,
                    desabilitado:
                        ocupado ||
                        prestador.isEmpty ||
                        prestador != app.prestador,
                    idLayout: 'Lotes.criar',
                  ),
              ],
              espaco: 12,
              idLayout: 'Grupo.lotes.selecao',
            ),
            const SizedBox(height: 14),
            if (lote != null) ...[
              Tx(
                '${lote!['nome']}',
                tam: Letra.subtitulo,
                peso: FontWeight.bold,
                idLayout: 'Lotes.nome',
              ),
              const SizedBox(height: 8),
              Expanded(child: grade()),
              divisor(altura: 1),
              const SizedBox(height: 12),
              lin(
                [
                  if (editando)
                    Botao.contorno(
                      'Adicionar cliente / serviço',
                      icone: Icons.person_add_alt,
                      aoClicar: adicionar,
                      desabilitado: ocupado,
                      idLayout: 'Lotes.adicionar',
                    ),
                  if (editando)
                    Botao.contorno(
                      'Cancelar edição',
                      icone: Icons.delete_outline,
                      aoClicar: cancelarEdicao,
                      desabilitado: ocupado,
                      idLayout: 'Lotes.cancelar',
                    ),
                  Botao.contorno(
                    editando ? 'Salvar lote' : 'Editar lote',
                    icone: editando ? Icons.save_outlined : Icons.edit_outlined,
                    desabilitado: ocupado,
                    aoClicar: () {
                      if (editando) {
                        salvar();
                      } else {
                        void abrirEdicao() {
                          if (mounted && !ocupado)
                            setState(() => editando = true);
                        }

                        if (app.temPermissao('lotes.editar')) {
                          abrirEdicao();
                        } else {
                          app.exigirPermissao('lotes.editar', abrirEdicao);
                        }
                      }
                    },
                    idLayout: 'Lotes.salvarEditar',
                  ),
                  if (!editando) const Spacer(),
                  if (!editando && !sujo)
                    Botao(
                      'Transmitir lote',
                      icone: Icons.send_outlined,
                      aoClicar: validarEmitir,
                      desabilitado: ocupado || linhas.isEmpty,
                      idLayout: 'Lotes.emitir',
                    ),
                ],
                espaco: 12,
                quebra: editando,
                espacoLinhas: 8,
                altura: editando ? null : Medida.campo,
                idLayout: 'Grupo.lotes.rodape',
              ),
            ] else
              const Expanded(
                child: Center(
                  child: Text('Crie um lote ou selecione um lote salvo.'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _BotaoHistorico extends StatefulWidget {
  const _BotaoHistorico({
    required this.pendente,
    required this.desabilitado,
    required this.aoClicar,
  });
  final bool pendente, desabilitado;
  final VoidCallback aoClicar;
  @override
  State<_BotaoHistorico> createState() => _BotaoHistoricoState();
}

class _BotaoHistoricoState extends State<_BotaoHistorico>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animacao = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  void _atualizar() {
    if (widget.pendente) {
      _animacao.repeat(reverse: true);
    } else {
      _animacao.stop();
      _animacao.value = 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _atualizar();
  }

  @override
  void didUpdateWidget(covariant _BotaoHistorico oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pendente != widget.pendente) _atualizar();
  }

  @override
  void dispose() {
    _animacao.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animacao,
    builder: (context, _) => Botao.contorno(
      'Emissões realizadas',
      idLayout: 'Lotes.historico',
      icone: Icons.history,
      fundo: widget.pendente
          ? Colors.orange.withValues(alpha: .06 + _animacao.value * .22)
          : null,
      desabilitado: widget.desabilitado,
      aoClicar: widget.aoClicar,
    ),
  );
}
