/// "Registros": o botão do topo com o contador de não lidos, a janela com os últimos
/// registros da SESSÃO em tempo real e a consulta ao histórico gravado em disco.
library;

import 'package:flutter/material.dart';

import '../kit/campo.dart';
import '../kit/flet.dart';
import 'app.dart';

String _dataHora(DateTime d) {
  String z(int n) => n.toString().padLeft(2, '0');
  return '${z(d.day)}/${z(d.month)}/${d.year} ${z(d.hour)}:${z(d.minute)}:${z(d.second)}';
}

class BotaoRegistros extends StatelessWidget {
  const BotaoRegistros({super.key, required this.app});
  final App app;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: app.tiqueRegistros,
    builder: (context, _, _) => Botao.texto(
      null,
      filho: lin(
        [
          const Icon(Icons.notifications_outlined, size: 18),
          Tx(
            'Registros (${app.naoLidos})',
            tam: Letra.texto,
            peso: app.naoLidos > 0 ? FontWeight.bold : null,
            largura: TamanhosRegistros.rotuloRegistrosAppNaoLidos.largura,
            altura: TamanhosRegistros.rotuloRegistrosAppNaoLidos.altura,
            idLayout: 'TamanhosRegistros.rotuloRegistrosAppNaoLidos',
          ),
        ],
        espaco: 6,
        justa: true,
        idLayout: 'Grupo.registros.lin.1',
      ),
      aoClicar: () => abrirRegistros(app),
      largura: TamanhosRegistros.botaoNull.largura,
      altura: TamanhosRegistros.botaoNull.altura,
      idLayout: 'TamanhosRegistros.botaoNull',
    ),
  );
}

/// Últimos 100 registros da SESSÃO, em TEMPO REAL (processos em andamento aparecem com o
/// anel girando e viram ✓/erro na hora). Abrir marca tudo como lido.
void abrirRegistros(App app) {
  if (!app.temPermissao('registros.consultar')) {
    app.exigirPermissao('registros.consultar', () => abrirRegistros(app));
    return;
  }
  app.marcarRegistrosLidos();

  Widget linha(Registro r) => lin(
    [
      Ct(
        largura: 20,
        alinhar: Alignment.center,
        child: r.progresso
            ? anel(tamanho: 16, traco: 2)
            : Icon(
                r.erro
                    ? Icons.error_outline
                    : r.aviso
                    ? Icons.info_outline
                    : Icons.check_circle_outline,
                size: 18,
                color: r.erro
                    ? Colors.red.shade700
                    : r.aviso
                    ? corAviso
                    : Colors.green.shade700,
              ),
      ),
      Tx(
        _dataHora(r.ts),
        tam: Letra.apoio,
        cor: Colors.grey.shade700,
        largura: TamanhosRegistros.rotuloDataHoraRTs.largura,
        altura: TamanhosRegistros.rotuloDataHoraRTs.altura,
        idLayout: 'TamanhosRegistros.rotuloDataHoraRTs',
      ),
      // Texto inteiro (sem "…"): dá para marcar com o mouse e copiar a mensagem completa.
      Expanded(
        child: Tx(
          r.msg,
          tam: Letra.texto,
          largura: TamanhosRegistros.rotuloRMsg.largura,
          altura: TamanhosRegistros.rotuloRMsg.altura,
          idLayout: 'TamanhosRegistros.rotuloRMsg',
        ),
      ),
    ],
    espaco: 8,
    cruzado: CrossAxisAlignment.start,
    idLayout: 'Grupo.registros.lin.2',
  );

  final d = Dialogo(
    titulo: (_) => LinhaTitulo([
      textoTitulo('Registros'),
      const Expanded(child: SizedBox()),
      Botao.texto(
        null,
        filho: lin(
          [
            const Icon(Icons.history, size: 17),
            Tx(
              'Consultar',
              largura: TamanhosRegistros.rotuloConsultar.largura,
              altura: TamanhosRegistros.rotuloConsultar.altura,
              idLayout: 'TamanhosRegistros.rotuloConsultar',
            ),
          ],
          espaco: 6,
          justa: true,
          idLayout: 'Grupo.registros.lin.3',
        ),
        dica: 'Histórico dos últimos 30 dias (lido dos logs em disco)',
        aoClicar: () => abrirHistoricoRegistros(app),
        largura: TamanhosRegistros.botaoNull2.largura,
        altura: TamanhosRegistros.botaoNull2.altura,
        idLayout: 'TamanhosRegistros.botaoNull2',
      ),
      BotaoIcone(
        Icons.close,
        dica: 'Fechar (Esc)',
        aoClicar: app.fecharDialogo,
        largura: TamanhosRegistros.botaoFecharEsc.largura,
        altura: TamanhosRegistros.botaoFecharEsc.altura,
        idLayout: 'TamanhosRegistros.botaoFecharEsc',
      ),
    ]),
    largura: 560,
    conteudo: (_) => SelectionArea(
      child: ValueListenableBuilder<int>(
        valueListenable: app.tiqueRegistros,
        builder: (context, _, _) {
          final itens = app.registros.reversed.toList();
          return SizedBox(
            height: 380,
            child: _Lista(
              espaco: 8,
              filhos: itens.isEmpty
                  ? [
                      Tx(
                        'Nenhum registro nesta sessão.',
                        italico: true,
                        cor: Colors.grey.shade600,
                        largura: TamanhosRegistros
                            .rotuloNenhumRegistroNestaSessao
                            .largura,
                        altura: TamanhosRegistros
                            .rotuloNenhumRegistroNestaSessao
                            .altura,
                        idLayout:
                            'TamanhosRegistros.rotuloNenhumRegistroNestaSessao',
                      ),
                    ]
                  : [for (final r in itens) linha(r)],
            ),
          );
        },
      ),
    ),
    idLayout: 'Janela.registros.Dialogo.1',
  );
  app.dialogoRegistros = d;
  app.mostrarDialogo(d);
}

/// Lista rolável que só monta o que está à vista.
class _Lista extends StatefulWidget {
  const _Lista({required this.filhos, this.espaco = 0, this.padding});
  final List<Widget> filhos;
  final double espaco;
  final EdgeInsetsGeometry? padding;

  @override
  State<_Lista> createState() => _ListaState();
}

class _ListaState extends State<_Lista> {
  final _c = ScrollController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, limites) {
      final lista = ListView.separated(
        controller: _c,
        clipBehavior: Clip.hardEdge,
        shrinkWrap: limites.maxHeight == double.infinity,
        padding: widget.padding,
        itemCount: widget.filhos.length,
        itemBuilder: (context, i) => widget.filhos[i],
        separatorBuilder: (context, i) => SizedBox(height: widget.espaco),
      );
      return Scrollbar(
        controller: _c,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: lista,
        ),
      );
    },
  );
}

/// Consulta os registros gravados em logs/nfse_AAAAMMDD.log. A lista da sessão morre ao
/// fechar o programa; esta é a visão que sobrevive.
void abrirHistoricoRegistros(App app) {
  if (!app.temPermissao('registros.historico')) {
    app.exigirPermissao(
      'registros.historico',
      () => abrirHistoricoRegistros(app),
    );
    return;
  }
  const teto = 200; // linhas montadas de uma vez
  late final Dialogo d;
  final periodo = Suspensa(
    valor: '30',
    opcoes: const [
      Opcao('7', 'Últimos 7 dias'),
      Opcao('15', 'Últimos 15 dias'),
      Opcao('30', 'Últimos 30 dias'),
    ],
  )..por('30');
  var soErros = false;
  var resumo = '';
  var linhas = <Map<String, dynamic>>[];
  var carregou = false;
  var sequencia = 0;
  late final TextEditingController busca;

  Future<void> buscar() async {
    if (!app.viva) return;
    final atual = ++sequencia;
    final dias = int.tryParse(periodo.valor ?? '30') ?? 30;
    final termo = busca.text.trim();
    final erros = soErros;
    resumo = 'Carregando registros...';
    d.atualizar();
    List<Map<String, dynamic>> regs;
    try {
      await chamar<Object?>('registro.sincronizar');
      regs = [
        for (final v in await chamar<List>('registros.consultar', {
          'dias': dias,
          'termo': termo,
          'so_erros': erros,
          'limite': teto,
        }))
          Map<String, dynamic>.from(v as Map),
      ];
    } catch (e) {
      registrar('Falha ao ler registros: $e', nivel: 'error');
      app.toast('Nao foi possivel ler os registros: $e', erro: true);
      return;
    }
    if (atual != sequencia || !app.viva || !app.dialogoAberto(d)) return;
    linhas = regs;
    carregou = true;
    resumo =
        '${regs.length} registro(s) — últimos $dias dias'
        '${regs.length >= teto ? ' (teto de $teto exibidos)' : ''}';
    d.atualizar();
  }

  String quando(String iso) {
    final t = DateTime.tryParse(iso);
    return t == null ? iso : _dataHora(t);
  }

  d = Dialogo(
    titulo: (_) => app.tituloComX('Consultar registros'),
    largura: 720,
    conteudo: (_) => SizedBox(
      height: 460,
      child: col(
        [
          lin(
            [
              ListaSuspensa(
                estado: periodo,
                rotulo: 'Período',
                largura: TamanhosRegistros.campoPeriodo.largura!,
                denso: true,
                aoSelecionar: (_) => buscar(),
                altura: TamanhosRegistros.campoPeriodo.altura,
                idLayout: 'TamanhosRegistros.campoPeriodo',
              ),
              CampoTexto(
                controle: busca,
                rotulo: 'Buscar no texto',
                largura: TamanhosRegistros.campoBuscarNoTexto.largura,
                denso: true,
                aoEnviar: (_) => buscar(),
                altura: TamanhosRegistros.campoBuscarNoTexto.altura,
                idLayout: 'TamanhosRegistros.campoBuscarNoTexto',
              ),
              Marcar(
                idLayout: 'Checkbox.registros.1',
                rente: false, // vem depois dos campos de busca
                valor: soErros,
                rotulo: 'Só erros e avisos',
                aoMudar: (v) {
                  soErros = v ?? false;
                  d.atualizar();
                  buscar();
                },
              ),
              Botao(
                'Buscar',
                icone: Icons.search,
                aoClicar: buscar,
                largura: TamanhosRegistros.botaoBuscar.largura,
                altura: TamanhosRegistros.botaoBuscar.altura,
                idLayout: 'TamanhosRegistros.botaoBuscar',
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.registros.lin.4',
          ),
          Tx(
            resumo,
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura: TamanhosRegistros.rotuloResumo.largura,
            altura: TamanhosRegistros.rotuloResumo.altura,
            idLayout: 'TamanhosRegistros.rotuloResumo',
          ),
          divisor(altura: 1),
          // marcar/copiar com o mouse
          Expanded(
            child: SelectionArea(
              child: _Lista(
                espaco: 6,
                padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
                filhos: !carregou
                    ? const []
                    : linhas.isEmpty
                    ? [
                        Tx(
                          'Nenhum registro no período.',
                          italico: true,
                          cor: Colors.grey.shade600,
                          largura: TamanhosRegistros
                              .rotuloNenhumRegistroNoPeriodo
                              .largura,
                          altura: TamanhosRegistros
                              .rotuloNenhumRegistroNoPeriodo
                              .altura,
                          idLayout:
                              'TamanhosRegistros.rotuloNenhumRegistroNoPeriodo',
                        ),
                      ]
                    : [
                        for (final r in linhas)
                          lin(
                            [
                              Icon(
                                r['erro'] == true
                                    ? Icons.error_outline
                                    : Icons.check_circle_outline,
                                size: 16,
                                color: r['erro'] == true
                                    ? Colors.red.shade700
                                    : Colors.green.shade700,
                              ),
                              Tx(
                                quando(r['quando'] as String),
                                tam: Letra.apoio,
                                largura: TamanhosRegistros
                                    .rotuloQuandoRQuandoAsString
                                    .largura,
                                cor: Colors.grey.shade700,
                                altura: TamanhosRegistros
                                    .rotuloQuandoRQuandoAsString
                                    .altura,
                                idLayout: 'TamanhosRegistros.rotuloQuandoRQuandoAsString',
                              ),
                              Expanded(
                                child: Tx(
                                  r['msg'] as String,
                                  tam: Letra.apoio,
                                  largura: TamanhosRegistros
                                      .rotuloRMsgAsString
                                      .largura,
                                  altura: TamanhosRegistros
                                      .rotuloRMsgAsString
                                      .altura,
                                  idLayout:
                                      'TamanhosRegistros.rotuloRMsgAsString',
                                ),
                              ),
                            ],
                            espaco: 8,
                            cruzado: CrossAxisAlignment.start,
                            idLayout: 'Grupo.registros.lin.5',
                          ),
                      ],
              ),
            ),
          ),
        ],
        espaco: 8,
        idLayout: 'Grupo.registros.col.1',
      ),
    ),
    idLayout: 'Janela.registros.Dialogo.2',
  );
  busca = d.texto();
  d.aoDescartar(periodo.dispose);
  app.mostrarDialogo(d);
  buscar();
}
