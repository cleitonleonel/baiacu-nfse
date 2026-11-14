/// Tela CLIENTES: a lista de clientes (tomadores) do prestador, filtrada e ordenada em
/// memória e mostrada 25/50/100 por página; o cadastro abre em janela (cliente_form.dart).
library;

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import '../kit/tabela.dart';
import '../editor_layout.dart';
import 'cliente_form.dart';
import 'emitir.dart' show semGrupo, todos;
import 'grupos.dart';

class TelaClientes extends StatefulWidget {
  const TelaClientes({super.key, required this.app});
  final App app;

  @override
  State<TelaClientes> createState() => ClientesState();
}

class ClientesState extends State<TelaClientes>
    with TelaGuardada<TelaClientes> {
  @override
  App get app => widget.app;

  @override
  int get indiceDaTela => 1;

  // Larguras fixas das colunas: Documento / Nome / Grupo (+ Ações).
  static const _larguras = [130.0, 250.0, 100.0, 125.0, 200.0, 170.0];
  static const _larguraAcoes = 70.0;

  /// (doc, nome, grupo). Nulo = recarregar do banco na próxima vez.
  List<(String, String, String)>? _cache;
  List<(String, String, String)> _visiveis = [];
  int _pagina = 0;
  int _porPagina = 25;
  Set<String> _gruposCache = {};
  Map<String, TextoDeBusca> _buscaDe = {};
  Map<String, (String, String)> _contatos = {};
  Map<String, (String, String)> _ultimas = {};
  void _carregarUltimas() {
    _ultimas = {
      for (final item in ja<List>('cadastro.ultimas_nfse_clientes', {
        'prestador': app.prestador,
      }))
        (item as List)[0] as String: (item[1] as String, item[2] as String),
    };
  }

  // Ordenação PADRÃO: por nome, A→Z.
  (int, bool)? _ordem = (1, true);
  Set<String>? gruposSel;

  final _busca = TextEditingController();
  final _irPara = TextEditingController();
  final _ddGrupo = Suspensa(valor: todos, opcoes: const [Opcao(todos, 'Todos')])
    ..por(todos);
  final _aoVivo = BuscaAoVivo();
  final _celulas = CelulasProntas();

  static const _alturaLinha = Medida.linhaDaTabela;
  static const _alturaCabecalho = Medida.cabecalhoDaTabela;

  @override
  void initState() {
    super.initState();
    app.aoEntrar[1] = () {
      if (_cache == null) {
        recarregar();
      } else {
        _carregarUltimas();
        _redesenhar();
      }
    };
    app.aoTrocarPrestador.add(_aoTrocarPrestador);
    app.aoInvalidarClientes.add(_invalidar);
    app.aoMudarGrupos.add(_aoMudarGrupos);
    app.recarregarTelas.add(recarregar);
    app.aoPararTimers.add(_aoVivo.cancelar);
    app.aoAtualizar(_redesenhar);
  }

  void _redesenhar() => redesenhar();

  void _invalidar() => _cache = null;

  void _aoMudarGrupos() {
    gruposSel = null;
    _cache = null; // nomes/associações de grupo mudaram
  }

  void _aoTrocarPrestador() {
    gruposSel = null;
    _busca.text = '';
    _cache = null; // recarrega os clientes do novo prestador
    _pagina = 0;
  }

  @override
  void dispose() {
    _aoVivo.cancelar();
    app.semAtualizar(_redesenhar);
    app.aoTrocarPrestador.remove(_aoTrocarPrestador);
    app.aoInvalidarClientes.remove(_invalidar);
    app.aoMudarGrupos.remove(_aoMudarGrupos);
    app.recarregarTelas.remove(recarregar);
    app.aoPararTimers.remove(_aoVivo.cancelar);
    super.dispose();
  }

  // ---- cache + filtro/ordenação em memória + paginação --------------------------------- //
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
    if (_ddGrupo.opcoes.map((o) => o.chave).join('\n') != chaves.join('\n')) {
      _ddGrupo.opcoes = [
        const Opcao(todos, 'Todos'),
        for (final g in todas) Opcao(g, g),
      ];
    }
    _ddGrupo.por(gruposSel?.first ?? todos);
    _ddGrupo.avisar();
  }

  /// Lê a lista de clientes UMA vez e guarda em memória.
  void _carregarCache() {
    final p = app.prestador;
    if (p.isEmpty) {
      _cache = [];
      _gruposCache = {};
      _buscaDe = {};
      return;
    }
    _gruposCache = ja<List>('cadastro.list_grupos', {
      'prestador': p,
    }).cast<String>().toSet();
    final gmap = {
      for (final (d, g) in jaPares('cadastro.tomadores_grupos', {
        'prestador': p,
      }))
        d: g,
    };
    _contatos = {
      for (final item in ja<List>('cadastro.contatos_tomadores', {
        'prestador': p,
      }))
        (item as List)[0] as String: (item[1] as String, item[2] as String),
    };
    _carregarUltimas();
    _cache = [
      for (final t in jaLista('cadastro.list_tomadores', {'prestador': p}))
        (
          t['documento'] as String,
          (t['xNome'] as String?) ?? '',
          gmap[soDoc(t['documento'] as String)] ?? '',
        ),
    ];
    // A pesquisa acha pelo nome ou pelo documento, com ou sem pontuação.
    _buscaDe = {
      for (final (doc, nome, _) in _cache!) doc: TextoDeBusca('$nome $doc'),
    };
  }

  List<(String, String, String)> _calcularVisiveis() {
    final termos = termosBusca(_busca.text);
    final consulta = termos.join();
    final saida = <(String, String, String)>[];
    for (final (doc, nome, g) in _cache ?? const <(String, String, String)>[]) {
      if (termos.isNotEmpty &&
          !(_buscaDe[doc]?.casa(consulta, termos) ?? false))
        continue;
      final efetivo = (g.isNotEmpty && _gruposCache.contains(g)) ? g : semGrupo;
      final sel = gruposSel;
      if (sel != null && !sel.contains(efetivo)) continue;
      saida.add((doc, nome, efetivo));
    }
    final ordem = _ordem;
    if (ordem != null) {
      final (coluna, crescente) = ordem;
      final String Function((String, String, String))? chave = switch (coluna) {
        0 => (it) => it.$1,
        1 => (it) => it.$2.toUpperCase(),
        2 => (it) => (it.$3 == semGrupo ? '' : it.$3).toUpperCase(),
        3 => (it) => _contatos[it.$1]?.$1 ?? '',
        4 => (it) => _contatos[it.$1]?.$2 ?? '',
        5 => (it) => _ultimas[it.$1]?.$2 ?? '',
        _ => null,
      };
      if (chave != null) ordenarPor(saida, chave, crescente: crescente);
    }
    return saida;
  }

  /// Recalcula a lista visível (filtro/ordem) e volta à 1ª página.
  void _reaplicar() {
    if (_cache == null) _carregarCache();
    _pagina = 0;
    _visiveis = _calcularVisiveis();
    _redesenhar();
  }

  void recarregar() {
    _refazerGrupos();
    if (_cache == null) _carregarCache();
    _visiveis = _calcularVisiveis();
    _redesenhar();
  }

  int get _paginas {
    final total = _visiveis.length;
    return total == 0 ? 1 : (total + _porPagina - 1) ~/ _porPagina;
  }

  void _irPagina(int p) {
    _pagina = p;
    _redesenhar();
  }

  // ---- desenho ----------------------------------------------------------------------------- //
  DataRow _linha((String, String, String) item, LocalKey chave) {
    final (doc, nome, grupo) = item;
    Widget celula(String valor, double largura) => Ct(
      largura: largura,
      alinhar: Alignment.centerLeft,
      child: TxCorte(valor, largura: largura, solto: true),
    );
    return DataRow(
      // A chave é da POSIÇÃO, não do cliente: trocar de página, filtrar ou ordenar atualiza
      // as linhas que já estão montadas em vez de desmontar todas e montar outras.
      key: chave,
      color: hoverPadrao,
      // Sempre "interativa" (é o que dá o realce do mouse): com uma janela aberta por cima o
      // mouse não chega aqui, e manter a linha com a MESMA estrutura evita desmontar e montar
      // de novo todas as células a cada janela que abre ou fecha.
      onSelectChanged: (_) {},
      // O conteúdo da linha só depende do cliente: fica montado enquanto o cadastro lido for
      // o mesmo (filtrar, ordenar, paginar e abrir janelas não o refazem).
      cells: _celulas.da(
        [_cache, _contatos, _ultimas],
        item,
        () => [
          DataCell(celula(formatarDocumento(doc), _larguras[0])),
          DataCell(celula(nome.isEmpty ? '—' : nome, _larguras[1])),
          DataCell(
            celula(
              (grupo.isNotEmpty && grupo != semGrupo) ? grupo : '—',
              _larguras[2],
            ),
          ),
          DataCell(celula(_contatos[doc]?.$1 ?? '—', _larguras[3])),
          DataCell(celula(_contatos[doc]?.$2 ?? '—', _larguras[4])),
          DataCell(
            celula(
              _ultimas.containsKey(doc)
                  ? '${_ultimas[doc]!.$1} — ${dataHora(_ultimas[doc]!.$2)}'
                  : '—',
              _larguras[5],
            ),
          ),
          DataCell(
            Ct(
              largura: _larguraAcoes,
              alinhar: Alignment.centerLeft,
              child: lin(
                [
                  BotaoIcone(
                    Icons.edit,
                    dica: 'Editar',
                    aoClicar: () => app.exigirNivel(
                      2,
                      () => abrirCliente(app, doc),
                      titulo: 'Editar cliente',
                    ),
                    largura: TamanhosClientes.botaoEditar.largura,
                    altura: TamanhosClientes.botaoEditar.altura,
                    idLayout: 'TamanhosClientes.botaoEditar',
                  ),
                ],
                espaco: 0,
                idLayout: 'Grupo.clientes.lin.1',
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _ordenar(int coluna, bool crescente) {
    _ordem = (coluna, crescente);
    _reaplicar();
  }

  @override
  Widget build(BuildContext context) {
    final total = _visiveis.length;
    final paginas = _paginas;
    _pagina = _pagina.clamp(0, paginas - 1);
    final inerte = travado(context);

    DataColumn coluna(String rotulo, {bool ordenavel = true}) => DataColumn(
      label: Tx(
        rotulo,
        tam: 13,
        peso: FontWeight.bold,
        linhas: 1,
        semQuebra: true,
        largura: TamanhosClientes.rotuloRotulo.largura,
        altura: TamanhosClientes.rotuloRotulo.altura,
        idLayout: 'TamanhosClientes.rotuloRotulo:$rotulo',
      ),
      headingRowAlignment: switch (ajusteLayout(
        context,
        'TamanhosClientes.rotuloRotulo:$rotulo',
      ).alinhamento) {
        TextAlign.left || TextAlign.start => MainAxisAlignment.start,
        TextAlign.right || TextAlign.end => MainAxisAlignment.end,
        _ => MainAxisAlignment.center,
      },
      mouseCursor: WidgetStateMouseCursor.clickable,
      onSort: (ordenavel && !inerte) ? _ordenar : null,
    );

    // A tabela é a parte cara da tela: só é montada de novo quando muda o que ela mostra, e
    // só nas linhas que estão à vista.
    final inicio = _pagina * _porPagina;
    final tabela = TabelaCabecalhoFixo(
      espacoAntesAcoes: 20,
      larguras: [..._larguras, _larguraAcoes],
      quantidade: (total - inicio).clamp(0, _porPagina),
      alturaLinha: _alturaLinha,
      alturaCabecalho: _alturaCabecalho,
      entradas: [
        _visiveis,
        _pagina,
        _porPagina,
        inerte,
        _ordem,
        _contatos,
        _ultimas,
      ],
      montar: (primeira, ultima, chave) => TabelaPadrao(
        showCheckboxColumn: false,
        headingRowHeight: _alturaCabecalho,
        dataRowMinHeight: _alturaLinha,
        dataRowMaxHeight: _alturaLinha,
        columnSpacing: 14,
        sortColumnIndex: _ordem?.$1,
        sortAscending: _ordem?.$2 ?? false,
        columns: [
          coluna('Documento'),
          coluna('Nome / Razão social'),
          coluna('Grupo'),
          coluna('Telefone'),
          coluna('E-mail'),
          coluna('Última NFS-e emitida'),
          coluna('Ações', ordenavel: false),
        ],
        rows: [
          for (var i = primeira; i <= ultima; i++)
            _linha(_visiveis[inicio + i], chave(i)),
        ],
      ),
    );

    return col(
      [
        lin(
          [
            Tx(
              'Clientes (tomadores)',
              tam: Letra.titulo,
              peso: FontWeight.bold,
              largura: TamanhosClientes.rotuloClientesTomadores.largura,
              altura: TamanhosClientes.rotuloClientesTomadores.altura,
              idLayout: 'TamanhosClientes.rotuloClientesTomadores',
            ),
            const Expanded(child: SizedBox()),
            BotaoIcone(
              Icons.person_add,
              dica: 'Adicionar cliente',
              largura: TamanhosClientes.botaoAdicionarCliente.largura,
              altura: TamanhosClientes.botaoAdicionarCliente.altura,
              desabilitado: app.prestador.isEmpty,
              aoClicar: () => app.exigirNivel(
                2,
                () => abrirCliente(app, null),
                titulo: 'Novo cliente',
              ),
              idLayout: 'TamanhosClientes.botaoAdicionarCliente',
            ),
            BotaoIcone(
              Icons.groups,
              dica: 'Grupos de clientes',
              largura: TamanhosClientes.botaoGruposDeClientes.largura,
              altura: TamanhosClientes.botaoGruposDeClientes.altura,
              desabilitado: app.prestador.isEmpty,
              aoClicar: () => abrirGrupos(app),
              idLayout: 'TamanhosClientes.botaoGruposDeClientes',
            ),
          ],
          espaco: 4,
          idLayout: 'Grupo.clientes.lin.2',
        ),
        lin(
          [
            CampoTexto(
              controle: _busca,
              rotulo: 'Pesquisar cliente',
              largura: TamanhosClientes.campoPesquisarCliente.largura,
              iconePrefixo: const Icon(Icons.search),
              aoMudar: (_) => _aoVivo.tecla(() {
                if (app.navAtual == 1) _reaplicar();
              }, viva: () => app.viva && mounted),
              altura: TamanhosClientes.campoPesquisarCliente.altura,
              idLayout: 'TamanhosClientes.campoPesquisarCliente',
            ),
            ListaSuspensa(
              estado: _ddGrupo,
              rotulo: 'Grupo',
              largura: TamanhosClientes.campoGrupo.largura!,
              desabilitado: app.prestador.isEmpty,
              aoSelecionar: (escolha) {
                gruposSel =
                    (escolha == null || escolha.isEmpty || escolha == todos)
                    ? null
                    : {escolha};
                _reaplicar();
              },
              altura: TamanhosClientes.campoGrupo.altura,
              idLayout: 'TamanhosClientes.campoGrupo',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.clientes.lin.3',
        ),
        Tx(
          _cache == null
              ? ''
              : (total == 0
                    ? 'Nenhum cliente encontrado com esse filtro.'
                    : '$total cliente(s).'),
          italico: true,
          cor: Colors.grey.shade600,
          largura: TamanhosClientes
              .rotuloCacheNullTotal0NenhumClienteEncontradoCom
              .largura,
          altura: TamanhosClientes
              .rotuloCacheNullTotal0NenhumClienteEncontradoCom
              .altura,
          idLayout: 'TamanhosClientes.rotuloCacheNullTotal0NenhumClienteEncontradoCom',
        ),
        Expanded(child: tabela),
        divisor(altura: 1),
        BarraPaginacao(
          pagina: _pagina,
          paginas: paginas,
          porPagina: _porPagina,
          controleIr: _irPara,
          aoIr: _irPagina,
          aoPorPagina: (n) {
            if (n == _porPagina) return;
            _porPagina = n;
            _pagina = 0;
            _redesenhar();
          },
        ),
      ],
      espaco: 16,
      idLayout: 'Grupo.clientes.col.1',
    );
  }
}
