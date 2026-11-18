// Clientes › Importar/exportar: modelo de planilha, importação com prévia dos erros e
// exportação nas mesmas colunas (rust/src/clientes_planilha.rs faz a leitura e a conferência).
import 'package:flutter/material.dart';

import '../app/app.dart';
import '../app/sistema.dart' show abrirCaminho;
import '../kit/arquivos.dart';
import '../kit/flet.dart';

const _extensoesImportacao = ['xlsx', 'xls', 'ods', 'csv'];

String _comExtensao(String caminho, String padrao) {
  final baixo = caminho.toLowerCase();
  return baixo.endsWith('.xlsx') || baixo.endsWith('.csv')
      ? caminho
      : '$caminho.$padrao';
}

void abrirImportarExportarClientes(App app, VoidCallback aoMudar) {
  if (app.prestador.isEmpty) return;
  late final Dialogo d;

  Widget bloco(IconData icone, String titulo, String texto, Widget botao) =>
      Builder(
        builder: (context) {
          final esquema = Theme.of(context).colorScheme;
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: esquema.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: esquema.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icone, color: esquema.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titulo,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(texto),
                      const SizedBox(height: 10),
                      botao,
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );

  Future<void> baixarModelo() async {
    final destino = await salvarArquivo(
      titulo: 'Salvar o modelo de planilha de clientes',
      nome: 'Modelo-clientes-Baiacu.xlsx',
      extensoes: const ['xlsx', 'csv'],
    );
    if (destino == null || destino.trim().isEmpty) return;
    try {
      await chamar<Object?>('clientes.modelo_planilha', {
        'destino': _comExtensao(destino, 'xlsx'),
      });
      app.toast('Modelo salvo. Preencha e use "Importar planilha".');
      abrirCaminho(app, _comExtensao(destino, 'xlsx'));
    } catch (e) {
      app.toast('Não foi possível salvar o modelo: $e', erro: true);
    }
  }

  Future<void> exportar() async {
    final prest = app.prestador;
    final destino = await salvarArquivo(
      titulo: 'Exportar clientes',
      nome: 'Clientes-$prest.xlsx',
      extensoes: const ['xlsx', 'csv'],
    );
    if (destino == null || destino.trim().isEmpty) return;
    final caminho = _comExtensao(destino, 'xlsx');
    final h = app.toastProgresso('Exportando os clientes…');
    await app.emSegundoPlano(() async {
      try {
        final r = Map<String, dynamic>.from(
          await chamar<Map>('clientes.exportar_planilha', {
            'prestador': prest,
            'destino': caminho,
          }),
        );
        app.toastFim(h, '${r['quantidade']} cliente(s) exportado(s).');
      } catch (e) {
        app.toastFim(h, 'Não foi possível exportar: $e', erro: true);
      }
    });
  }

  Future<void> importar() async {
    final origem = await escolherArquivo(
      titulo: 'Escolha a planilha de clientes',
      extensoes: _extensoesImportacao,
    );
    if (origem == null || origem.trim().isEmpty) return;
    final prest = app.prestador;
    final h = app.toastProgresso('Conferindo a planilha…');
    Map<String, dynamic> previa;
    try {
      previa = Map<String, dynamic>.from(
        await chamar<Map>('clientes.previa_importacao', {
          'prestador': prest,
          'origem': origem,
        }),
      );
      app.toastFim(h, 'Planilha conferida.');
    } catch (e) {
      app.toastFim(h, '$e', erro: true);
      return;
    }
    if (!app.viva || app.prestador != prest) return;
    app.fecharEsta(d);
    _mostrarPrevia(app, prest, origem, previa, aoMudar);
  }

  d = Dialogo(
    largura: 620,
    titulo: (_) => textoTitulo('Importar e exportar clientes'),
    conteudo: (_) => col(
      [
        bloco(
          Icons.description_outlined,
          'Modelo de planilha',
          'Planilha do Excel com as colunas aceitas e uma aba de instruções. Também serve '
              'CSV separado por ponto e vírgula.',
          Botao.contorno(
            'Baixar modelo',
            icone: Icons.download,
            aoClicar: () => app.exigirPermissao('clientes.importar', baixarModelo),
            idLayout: 'ClientesPlanilha.botaoModelo',
          ),
        ),
        bloco(
          Icons.upload_file,
          'Importar planilha',
          'Excel (.xlsx, .xls), OpenDocument (.ods) ou CSV, com cabeçalho. Antes de gravar, '
              'você vê cada linha com os erros encontrados. O CPF/CNPJ evita duplicados; o '
              'município pode vir pelo código IBGE ou pela cidade e UF.',
          Botao(
            'Importar planilha…',
            icone: Icons.upload_file,
            aoClicar: () => app.exigirPermissao('clientes.importar', importar),
            idLayout: 'ClientesPlanilha.botaoImportar',
          ),
        ),
        bloco(
          Icons.save_alt,
          'Exportar clientes',
          'Todos os clientes deste prestador, nas mesmas colunas: serve de backup e para levar '
              'os cadastros a outro computador ou programa.',
          Botao.contorno(
            'Exportar…',
            icone: Icons.save_alt,
            aoClicar: () => app.exigirPermissao('clientes.exportar', exportar),
            idLayout: 'ClientesPlanilha.botaoExportar',
          ),
        ),
      ],
      espaco: 12,
      justa: true,
    ),
    acoes: (_) => [
      Botao.texto(
        'Fechar',
        aoClicar: () => app.fecharEsta(d),
        idLayout: 'ClientesPlanilha.botaoFechar',
      ),
    ],
    idLayout: 'Janela.clientes.planilha',
  );
  app.mostrarDialogo(d);
}

void _mostrarPrevia(
  App app,
  String prest,
  String origem,
  Map<String, dynamic> previa,
  VoidCallback aoMudar,
) {
  final linhas = [
    for (final l in (previa['linhas'] as List?) ?? const [])
      Map<String, dynamic>.from(l as Map),
  ];
  final novos = (previa['novos'] as num?)?.toInt() ?? 0;
  final existentes = (previa['existentes'] as num?)?.toInt() ?? 0;
  final comErro = (previa['erros'] as num?)?.toInt() ?? 0;
  var atualizar = false;
  var gravando = false;
  late final Dialogo d;

  int aGravar() => novos + (atualizar ? existentes : 0);

  Future<void> gravar() async {
    if (gravando || aGravar() == 0) return;
    if (atualizar && !app.temPermissao('clientes.editar')) {
      app.exigirPermissao('clientes.editar', gravar);
      return;
    }
    gravando = true;
    d.atualizar();
    final h = app.toastProgresso('Importando os clientes…');
    await app.emSegundoPlano(() async {
      try {
        final r = Map<String, dynamic>.from(
          await chamar<Map>('clientes.importar_planilha', {
            'prestador': prest,
            'origem': origem,
            'atualizar': atualizar,
          }),
        );
        final falhas = (r['falhas'] as List?) ?? const [];
        app.toastFim(
          h,
          'Importação concluída: ${r['criados']} novo(s), ${r['atualizados']} atualizado(s), '
          '${r['pulados']} pulado(s)${falhas.isEmpty ? '' : ', ${falhas.length} com falha'}.',
          erro: falhas.isNotEmpty,
        );
        if (d.aberto) app.fecharEsta(d);
        aoMudar();
      } catch (e) {
        app.toastFim(h, 'Não foi possível importar: $e', erro: true);
        gravando = false;
        if (d.aberto) d.atualizar();
      }
    });
  }

  Widget linhaDaPrevia(BuildContext context, Map<String, dynamic> l) {
    final situacao = '${l['situacao']}';
    final (icone, cor, rotulo) = switch (situacao) {
      'novo' => (Icons.add_circle_outline, Colors.green.shade700, 'Novo'),
      'existente' => (Icons.sync, Colors.blue.shade700, 'Já cadastrado'),
      _ => (Icons.error_outline, Theme.of(context).colorScheme.error, 'Erro'),
    };
    final erros = [for (final e in (l['erros'] as List?) ?? const []) '$e'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text('${l['linha']}', textAlign: TextAlign.right),
          ),
          const SizedBox(width: 10),
          Icon(icone, color: cor, size: 18),
          const SizedBox(width: 6),
          SizedBox(
            width: 110,
            child: Text(rotulo, style: TextStyle(color: cor)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l['documento']}  ·  ${l['nome']}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if ('${l['municipio'] ?? ''}'.isNotEmpty)
                  Text('${l['municipio']}', style: const TextStyle(fontSize: 12)),
                for (final e in erros)
                  Text(e, style: TextStyle(color: cor, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  d = Dialogo(
    largura: 820,
    titulo: (_) => textoTitulo('Prévia da importação'),
    conteudo: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${linhas.length} linha(s): $novos nova(s), $existentes já cadastrada(s), '
          '$comErro com erro. As linhas com erro não são gravadas; corrija a planilha e '
          'importe de novo se quiser incluí-las.',
        ),
        const SizedBox(height: 8),
        if (existentes > 0)
          Marcar(
            rente: true,
            valor: atualizar,
            rotulo:
                'Atualizar os $existentes cliente(s) já cadastrado(s) com os dados da planilha '
                '(campos vazios na planilha não apagam nada)',
            desabilitado: gravando,
            aoMudar: (v) {
              atualizar = v == true;
              d.atualizar();
            },
            idLayout: 'ClientesPlanilha.marcarAtualizar',
          ),
        const Divider(),
        // Altura fixa e lista preguiçosa: uma planilha de milhares de linhas só monta as
        // que aparecem (shrinkWrap montaria todas de uma vez e travaria a janela).
        SizedBox(
          height: linhas.length > 8 ? 420 : linhas.length * 52.0 + 8,
          child: ListView.builder(
            itemCount: linhas.length,
            itemBuilder: (context, i) => linhaDaPrevia(context, linhas[i]),
          ),
        ),
      ],
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: () => app.fecharEsta(d),
        idLayout: 'ClientesPlanilha.botaoCancelar',
      ),
      Botao(
        aGravar() == 0
            ? 'Nada a importar'
            : 'Importar ${aGravar()} cliente(s)',
        icone: Icons.check,
        desabilitado: gravando || aGravar() == 0,
        aoClicar: gravar,
        idLayout: 'ClientesPlanilha.botaoConfirmarImportacao',
      ),
    ],
    idLayout: 'Janela.clientes.planilha.previa',
  );
  app.mostrarDialogo(d);
}
