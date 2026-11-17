import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../kit/arquivos.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import '../kit/tabela.dart';
import '../permissoes.dart';
import 'app.dart';

enum _Transferencia { exportar, importar }

typedef _Linha = (RegraPermissao regra, int profundidade);

class _BuscaPermissoes {
  _BuscaPermissoes(Iterable<RegraPermissao> regras) {
    for (final regra in regras) {
      (_filhas[regra.pai] ??= []).add(regra);
      _textos[regra.id] = TextoDeBusca('${regra.titulo} ${regra.id}');
    }
  }

  final _filhas = <String, List<RegraPermissao>>{};
  final _textos = <String, TextoDeBusca>{};

  Map<RegraPermissao, List<_Linha>> filtrar(List<String> termos) {
    final consulta = termos.join();
    bool corresponde(RegraPermissao regra) =>
        _textos[regra.id]!.casa(consulta, termos);

    void adicionar(
      List<_Linha> linhas,
      RegraPermissao regra,
      int profundidade,
      bool paiCorresponde,
    ) {
      final exibir = paiCorresponde || corresponde(regra);
      final inicio = linhas.length;
      linhas.add((regra, profundidade));
      for (final filha in _filhas[regra.id] ?? const []) {
        adicionar(linhas, filha, profundidade + 1, exibir);
      }
      // Sem resultado neste ramo, descarta também a linha que daria contexto.
      if (!exibir && linhas.length == inicio + 1) linhas.removeLast();
    }

    final resultado = <RegraPermissao, List<_Linha>>{};
    for (final modulo in _filhas[''] ?? const []) {
      final linhas = <_Linha>[];
      final exibir = corresponde(modulo);
      for (final filha in _filhas[modulo.id] ?? const []) {
        adicionar(linhas, filha, 0, exibir);
      }
      if (exibir || linhas.isNotEmpty) resultado[modulo] = linhas;
    }
    return resultado;
  }
}

final _opcoesNivel = {
  for (var minimo = 1; minimo <= 4; minimo++)
    minimo: [
      for (var nivel = minimo; nivel <= 4; nivel++)
        Opcao('$nivel', 'Nível $nivel'),
    ],
};

void abrirPermissoesNivel(App app) {
  if (app.usuario.nivel != 4) {
    app.toast(
      'Somente o usuário nível 4 logado pode editar permissões.',
      erro: true,
    );
    return;
  }

  try {
    Permissoes.carregar(jaMapa('permissoes.carregar'));
  } catch (e) {
    app.toast('Não foi possível carregar as permissões: $e', erro: true);
    return;
  }

  var valores = Map<String, int>.of(Permissoes.niveis);
  final indice = _BuscaPermissoes(Permissoes.regras);
  final todos = indice.filtrar(const []);
  var resultados = todos;
  var modulosVisiveis = [for (final modulo in todos.keys) (modulo, 0)];
  var selecionado = todos.keys.firstOrNull;
  String? linhaSobMouse;
  final aoVivo = BuscaAoVivo();
  var consultaAtual = '';
  late final TextEditingController busca;
  final seletores = <String, Suspensa>{};
  var alterado = false;
  var ocupado = false;
  late final Dialogo d;

  Map<String, Object> perfil() => {
    'formato': 'baiacu-permissoes',
    'versao': 1,
    'niveis': valores,
  };

  Future<void> transferir(_Transferencia operacao) async {
    if (ocupado || !d.aberto) return;
    ocupado = true;
    d.atualizar();
    final exportar = operacao == _Transferencia.exportar;
    try {
      if (exportar) {
        final caminho = await salvarArquivo(
          titulo: 'Exportar permissões',
          nome: 'Baiacu-permissoes.json',
          extensoes: const ['json'],
        );
        if (caminho == null || !d.aberto) return;
        final json = const JsonEncoder.withIndent('  ').convert(perfil());
        await File(caminho).writeAsString(json, flush: true);
        app.toast('Permissões exportadas.');
      } else {
        final caminho = await escolherArquivo(
          titulo: 'Importar permissões',
          extensoes: const ['json'],
        );
        if (caminho == null || !d.aberto) return;
        final arquivo = File(caminho);
        if (await arquivo.length() > 256 * 1024) {
          throw const FormatException('Arquivo maior que 256 KB.');
        }
        final texto = await arquivo.readAsString();
        if (!d.aberto) return;
        final validado = jaMapa('permissoes.validar', {
          'perfil': jsonDecode(
            texto.startsWith('\ufeff') ? texto.substring(1) : texto,
          ),
        });
        valores = Map<String, int>.from(validado['niveis'] as Map);
        alterado = true;
        app.toast(
          'Perfil carregado para revisão. Clique em Salvar para aplicar.',
        );
      }
    } catch (e) {
      final acao = exportar ? 'exportar' : 'importar';
      app.toast('Não foi possível $acao as permissões: $e', erro: true);
    } finally {
      ocupado = false;
      d.atualizar();
    }
  }

  void filtrar() {
    final termos = termosBusca(busca.text);
    final consulta = termos.join(' ');
    if (consulta == consultaAtual) return;
    consultaAtual = consulta;
    resultados = termos.isEmpty ? todos : indice.filtrar(termos);
    modulosVisiveis = [for (final modulo in resultados.keys) (modulo, 0)];
    if (!resultados.containsKey(selecionado)) {
      selecionado = resultados.keys.firstOrNull;
    }
    d.atualizar();
  }

  Widget nivel(RegraPermissao regra) {
    final minimo = regra.fixa ? 4 : Permissoes.efetivo(regra.pai, valores);
    final efetivo = Permissoes.efetivo(regra.id, valores);
    final herdado = !regra.fixa && efetivo > valores[regra.id]!;
    final estado = seletores.putIfAbsent(regra.id, () => d.suspensa());
    estado.opcoes = _opcoesNivel[minimo]!;
    if (estado.valor != '$efetivo') estado.por('$efetivo');

    return Row(
      children: [
        SizedBox(
          width: 20,
          child: regra.fixa || herdado
              ? comDica(
                  regra.fixa ? 'Nível fixo' : 'Nível mínimo herdado',
                  Icon(
                    regra.fixa
                        ? Icons.lock_outline
                        : Icons.subdirectory_arrow_right,
                    size: 15,
                  ),
                )
              : null,
        ),
        ListaSuspensa(
          key: ValueKey(regra.id),
          estado: estado,
          rotulo: 'Nível mínimo de ${regra.titulo}',
          largura: 110,
          emTabela: true,
          tamanhoTexto: Letra.tabela,
          buscar: false,
          desabilitado: regra.fixa || ocupado,
          aoSelecionar: (escolha) {
            if (escolha == null) return;
            final novo = int.parse(escolha);
            if (novo == efetivo) return;
            valores = {...valores, regra.id: novo};
            alterado = true;
            d.atualizar();
          },
        ),
      ],
    );
  }

  Widget tabela(
    BuildContext context, {
    required bool principal,
    required List<_Linha> linhas,
  }) {
    final cores = Theme.of(context).colorScheme;
    DataColumn cabecalho(String texto, {bool centralizado = false}) =>
        DataColumn(
          label: Tx(texto, tam: Letra.cabecalhoDaTabela, peso: FontWeight.bold),
          headingRowAlignment: centralizado
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
        );

    DataRow linha(_Linha item, LocalKey chave) {
      final (regra, profundidade) = item;
      final ativa = principal && regra == selecionado;
      return DataRow(
        key: chave,
        selected: ativa,
        color: WidgetStatePropertyAll(
          linhaSobMouse == regra.id
              ? hoverPadrao.resolve({WidgetState.hovered})
              : ativa
              ? cores.secondaryContainer
              : null,
        ),
        mouseCursor: WidgetStatePropertyAll(
          principal && !ocupado
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
        ),
        onHover: (dentro) {
          if (!dentro && linhaSobMouse != regra.id) return;
          final nova = dentro ? regra.id : null;
          if (linhaSobMouse == nova) return;
          linhaSobMouse = nova;
          d.atualizar();
        },
        onSelectChanged: ocupado
            ? null
            : (_) {
                if (!principal || ativa) return;
                selecionado = regra;
                d.atualizar();
              },
        cells: [
          DataCell(
            Padding(
              padding: EdgeInsets.only(left: profundidade * 18.0),
              child: Row(
                children: [
                  if (profundidade > 0)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.subdirectory_arrow_right, size: 14),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, limites) => TxCorte(
                        regra.titulo,
                        largura: limites.maxWidth,
                        solto: true,
                        tam: Letra.tabela,
                        peso: principal ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  if (principal) const Icon(Icons.chevron_right, size: 16),
                ],
              ),
            ),
          ),
          DataCell(nivel(regra)),
        ],
      );
    }

    return TabelaCabecalhoFixo(
      key: principal ? null : ValueKey((selecionado?.id, consultaAtual)),
      quantidade: linhas.length,
      alturaLinha: Medida.campo + 4,
      alturaCabecalho: Medida.cabecalhoDaTabela,
      larguras: [principal ? 152 : 248, 130],
      colunaExpansivel: 0,
      entradas: [linhas, valores, selecionado, ocupado, cores, linhaSobMouse],
      montar: (primeira, ultima, chave) => TabelaPadrao(
        columns: [
          cabecalho(principal ? 'Módulos principais' : 'Submódulos e ações'),
          cabecalho('Nível mínimo', centralizado: true),
        ],
        rows: [
          for (var i = primeira; i <= ultima; i++) linha(linhas[i], chave(i)),
        ],
      ),
    );
  }

  d = Dialogo(
    marcador: 'permissoes_nivel',
    largura: 960,
    titulo: (_) => app.tituloComX('Permissões de nível'),
    conteudo: (_) {
      final acoes = resultados[selecionado] ?? const <_Linha>[];
      return SizedBox(
        height: 584,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Tx(
              'Escolha o nível mínimo de cada ação. O nível do módulo pai também se aplica.',
            ),
            const SizedBox(height: 12),
            CampoTexto(
              controle: busca,
              rotulo: 'Buscar módulo ou ação',
              iconePrefixo: const Icon(Icons.search),
              expandir: true,
              aoMudar: (_) => aoVivo.tecla(filtrar, viva: () => d.aberto),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, limites) => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: (limites.maxWidth * 0.41).clamp(0, 344).toDouble(),
                      child: tabela(
                        context,
                        principal: true,
                        linhas: modulosVisiveis,
                      ),
                    ),
                    divisorVertical(largura: 16),
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          tabela(context, principal: false, linhas: acoes),
                          if (acoes.isEmpty)
                            Positioned.fill(
                              top: Medida.cabecalhoDaTabela,
                              child: Center(
                                child: Text(
                                  selecionado == null
                                      ? 'Nenhum módulo ou ação encontrado.'
                                      : 'Nenhuma ação neste módulo.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            divisor(altura: 12),
            if (alterado) const Tx('Alterações não salvas', tam: Letra.apoio),
          ],
        ),
      );
    },
    acoes: (_) => [
      SizedBox(
        width: double.infinity,
        child: Row(
          children: [
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  style: const ButtonStyle(
                    mouseCursor: WidgetStateMouseCursor.clickable,
                  ),
                  onPressed: () => transferir(_Transferencia.exportar),
                  child: const Text('Exportar permissões'),
                ),
                MenuItemButton(
                  style: const ButtonStyle(
                    mouseCursor: WidgetStateMouseCursor.clickable,
                  ),
                  onPressed: () => transferir(_Transferencia.importar),
                  child: const Text('Importar permissões'),
                ),
              ],
              builder: (_, controle, _) => Botao.contorno(
                'Exportar/importar permissões',
                aoClicar: controle.open,
                desabilitado: ocupado,
                icone: Icons.swap_vert,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: ocupado ? null : () => app.fecharEsta(d),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: ocupado || !alterado
                  ? null
                  : () {
                      try {
                        Permissoes.aplicar(
                          jaMapa('permissoes.salvar', {'perfil': perfil()}),
                        );
                        app.fecharEsta(d);
                        app.atualizar();
                        app.toast('Permissões salvas.');
                      } catch (e) {
                        app.toast(
                          'Não foi possível salvar as permissões: $e',
                          erro: true,
                        );
                      }
                    },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    ],
  );
  busca = d.texto();
  d.aoDescartar(aoVivo.cancelar);
  app.mostrarDialogo(d);
}
