/// Tela CONSULTAR: as NFS-e emitidas por este programa, paginadas; a fila de contingência
/// (DPS pendentes de envio) no topo; exportação, estorno, substituição, XML e DANFSe.
library;

import '../editor_layout.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../app/correio.dart';
import '../app/sistema.dart';
import '../app/xml_ilegivel.dart';
import '../kit/arquivos.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import '../kit/tabela.dart';
import 'emitir.dart' show EmitirState, todos;
import 'periodo.dart';

/// '2160.00' -> '2.160,00' (sem símbolo). Vazio -> '—'; inválido -> o valor original.
String moedaBr(String valor) {
  final cru = valor.trim().replaceAll(',', '.');
  if (cru.isEmpty) return '—';
  final n = double.tryParse(cru);
  if (n == null || !n.isFinite) return valor.isEmpty ? '—' : valor;
  final fixo = n.abs().toStringAsFixed(2);
  final ponto = fixo.indexOf('.');
  final inteiro = fixo
      .substring(0, ponto)
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]}.');
  return '${n < 0 ? '-' : ''}$inteiro,${fixo.substring(ponto + 1)}';
}

String milhar(int n) =>
    '$n'.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]}.');

const _varias = '+'; // chave da opção "Várias…" da lista de empresa
const _maxOpcoes = 200;
const _maxLinhas = 100;
const _avisoPdf = 2000; // acima disso, avisa que o PDF fica pesado

// Formato -> (extensão, rótulo).
const formatosExportacao = {
  'xlsx': ('xlsx', 'Excel (.xlsx)'),
  'pdf': ('pdf', 'PDF (.pdf)'),
  'csv': ('csv', 'CSV (.csv)'),
};

const opcoesDeAmbiente = [
  Opcao('todos', 'Todos'),
  Opcao(ambProducao, 'Produção'),
  Opcao(ambHomologacao, 'Homologação'),
];

/// Janela de progresso da exportação (bloqueia a tela + permite cancelar).
class ProgressoExportacao {
  ProgressoExportacao(this.app);
  final App app;
  late final Dialogo dialogo;
  final String ficha = 'exportar-${DateTime.now().microsecondsSinceEpoch}';
  bool cancelada = false;
  double? valor = 0.0;
  String etapaAtual = 'Exportando…';
  String texto = 'Exportando… 0%';
  DateTime _ultimo = DateTime.fromMillisecondsSinceEpoch(0);

  void abrir() {
    dialogo = Dialogo(
      titulo: (_) => textoTitulo('Exportando dados'),
      largura: 400,
      conteudo: (_) => col(
        [
          // A barra indeterminada anima sem parar: fica em camada própria.
          fronteira(
            SizedBox(width: 380, child: LinearProgressIndicator(value: valor)),
          ),
          Tx(
            texto,
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura: TamanhosConsultar.rotuloTexto.largura,
            altura: TamanhosConsultar.rotuloTexto.altura,
            idLayout: 'TamanhosConsultar.rotuloTexto',
          ),
        ],
        justa: true,
        espaco: 14,
        idLayout: 'Grupo.consultar.col.1',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: cancelar,
          largura: TamanhosConsultar.botaoCancelar.largura,
          altura: TamanhosConsultar.botaoCancelar.altura,
          idLayout: 'TamanhosConsultar.botaoCancelar',
        ),
      ],
      idLayout: 'Janela.consultar.Dialogo.1',
    );
    app.mostrarDialogo(dialogo);
  }

  void etapa(String t, {bool indeterminada = false}) {
    etapaAtual = t;
    valor = indeterminada ? null : 0.0;
    texto = t + (indeterminada ? '' : ' 0%');
    dialogo.atualizar();
  }

  /// Avisos de andamento do núcleo: {feito, total}.
  void aviso(Object? a) {
    if (a is! Map || a['feito'] == null) return;
    final feito = (a['feito'] as num).toInt();
    final total = (a['total'] as num).toInt();
    final agora = DateTime.now();
    if (feito < total &&
        agora.difference(_ultimo) < const Duration(milliseconds: 120))
      return;
    _ultimo = agora;
    if (!app.dialogoAberto(dialogo))
      return; // janela já fechada (cancelada ou concluída)
    valor = total > 0 ? feito / total : null;
    texto = '$etapaAtual ${total > 0 ? (feito * 100 ~/ total) : 0}%';
    dialogo.atualizar();
  }

  /// Cancela NA HORA: fecha a janela já, sem esperar o trabalho perceber.
  void cancelar() {
    cancelada = true;
    try {
      chamar<Object?>('nucleo.cancelar', {'ficha': ficha}).catchError((
        Object e,
      ) {
        debugPrint('Falha ao cancelar: $e');
        return null;
      });
    } catch (_) {}
    fechar();
    app.toast('Exportação cancelada.');
  }

  void fechar() => app.fecharEsta(dialogo);
}

void apagarSeExistir(String caminho) {
  try {
    final f = File(caminho);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

class TelaConsultar extends StatefulWidget {
  const TelaConsultar({super.key, required this.app});
  final App app;

  @override
  State<TelaConsultar> createState() => ConsultarState();
}

class ConsultarState extends State<TelaConsultar>
    with TelaGuardada<TelaConsultar> {
  @override
  App get app => widget.app;

  @override
  int get indiceDaTela => 2;

  // Colunas de dados: 0 NFS-e, 1 Cliente, 2 Grupo, 3 Processada, 4 Ambiente, 5 Status,
  // 6 vServ, 7 vLíq. Largura FIXA por coluna.
  static const _larguras = [
    60.0,
    250.0,
    110.0,
    110.0,
    130.0,
    85.0,
    84.0,
    100.0,
    80.0,
  ];
  static const _larguraAcoes = 3 * Medida.botaoDaLinha;
  static const _centradas = {5, 6};
  static const _aDireita = {7, 8};
  static const _tentarDeNovo = Duration(
    seconds: 300,
  ); // reenvio automático da fila

  // ---- filtros --------------------------------------------------------------------------- //
  final _ddBasePeriodo = Suspensa(valor: 'emissao', opcoes: opcoesBasePeriodo);
  final _ddPeriodo = Suspensa(valor: 'mes', opcoes: opcoesDePeriodo())
    ..por('mes');
  DateTime? _de;
  DateTime? _ate;
  // Último período CONFIRMADO: é ele que filtra (a lista pode estar em "Personalizado" com
  // a janela das datas ainda aberta).
  String _periodoAnt = 'mes';
  final _busca = TextEditingController();
  final _irPara = TextEditingController();
  final _ddEmpresa = Suspensa(
    valor: todos,
    opcoes: const [Opcao(todos, 'Todas')],
  )..por(todos);
  final _ddAmbiente = Suspensa(valor: 'todos', opcoes: opcoesDeAmbiente)
    ..por('todos');
  Set<String>? _empresasSel; // nulo = todas; senão, os documentos filtrados
  String _ambiente = ''; // '' = todos
  bool _temClientes = false;
  final _aoVivo = BuscaAoVivo();
  Timer? _filtroTimer;
  final _celulasNotas = CelulasProntas();
  final _celulasPendentes = CelulasProntas();

  static const _alturaLinha = Medida.linhaDaTabela;
  static const _alturaCabecalho = Medida.cabecalhoDaTabela;

  // ---- o que está na tela ------------------------------------------------------------------ //
  (int, bool)? _ordem;
  String? _carregadoPrest;
  int _pagina = 0;
  int _porPagina = 25;
  int _total = 0;
  String _vazio = '';
  List<Map<String, dynamic>> _pendentes = const [];
  List<Map<String, dynamic>> _notas = const [];
  Map<String, String> _pares = const {};

  // ---- fila de contingência ------------------------------------------------------------------ //
  DateTime? _pendLimite; // hora do próximo reenvio automático
  Timer? _pendTimer;
  bool _pendEnviando = false;
  int _pendN = 0;
  final _pendContagem = ValueNotifier<String>('');

  @override
  void initState() {
    super.initState();
    app.aoEntrar[2] = () {
      if (_carregadoPrest != app.prestador) {
        recarregarTomadores();
      } else {
        carregarPagina();
      }
    };
    app.aoTrocarPrestador.add(_aoTrocarPrestador);
    app.recarregarTelas.add(recarregarTomadores);
    app.aoMudarNotas.add(_aoMudarNotas);
    app.recarregarConsulta = carregarPagina;
    app.pararFila = _pendParar;
    app.refazerAvisoFila = () {
      _refazerAvisoFila();
      _redesenhar();
    };
    app.aoPararTimers.add(_pararTimers);
    app.aoAtualizar(_redesenhar);
    // Fila de contingência: se ficaram DPS pendentes de outra sessão, o aviso e o ciclo de
    // reenvio automático já nascem ligados.
    if (!app.semPrestador) _refazerAvisoFila();
  }

  void _redesenhar() => redesenhar();

  void _aoMudarNotas() {
    _consultaAtual++;
    _carregando = false;
    _carregadoPrest = null;
  }

  void _aoTrocarPrestador() {
    _consultaAtual++;
    _avisoFilaAtual++;
    _carregando = false;
    _busca.text = '';
    _empresasSel = null;
    _pagina = 0;
  }

  void _pararTimers() {
    _consultaAtual++;
    _avisoFilaAtual++;
    _carregando = false;
    _aoVivo.cancelar();
    _filtroTimer?.cancel();
    _filtroTimer = null;
  }

  @override
  void dispose() {
    _pararTimers();
    _pendTimer?.cancel();
    app.semAtualizar(_redesenhar);
    app.aoTrocarPrestador.remove(_aoTrocarPrestador);
    app.recarregarTelas.remove(recarregarTomadores);
    app.aoMudarNotas.remove(_aoMudarNotas);
    app.aoPararTimers.remove(_pararTimers);
    _ddBasePeriodo.dispose();
    super.dispose();
  }

  // ---- fila de contingência (DPS pendentes de envio) ------------------------------------------ //
  /// Mostra/esconde o aviso de pendentes e liga/desliga o ciclo de reenvio (5 min).
  int _avisoFilaAtual = 0;
  Future<void> _refazerAvisoFila() async {
    final leitura = ++_avisoFilaAtual;
    app.atualizarLotesPendentes();
    final p = app.prestador;
    int quantidade;
    try {
      quantidade = p.isEmpty
          ? 0
          : await chamar<int>('emissao.count_pendentes', {'prestador': p});
    } catch (e) {
      debugPrint('Falha ao atualizar pendências: $e');
      return;
    }
    if (!mounted ||
        !app.viva ||
        leitura != _avisoFilaAtual ||
        p != app.prestador)
      return;
    _pendN = quantidade;
    _redesenhar();
    if (_pendN > 0 && _pendLimite == null && !_pendEnviando) {
      _pendLimite = DateTime.now().add(_tentarDeNovo);
      _pendTique();
    } else if (_pendN == 0) {
      _pendParar();
    }
  }

  void _pendParar() {
    _pendLimite = null;
    _pendTimer?.cancel();
    _pendTimer = null;
    _pendContagem.value = '';
  }

  /// Tique de 1 s do contador regressivo (só roda enquanto há pendentes).
  void _pendTique() {
    if (!app.viva) {
      _pendParar();
      return;
    }
    _pendTimer?.cancel();
    _pendTimer = null;
    final limite = _pendLimite;
    if (limite == null) return;
    final resto = (limite.difference(DateTime.now()).inMilliseconds / 1000)
        .round();
    if (resto <= 0) {
      _pendLimite = null;
      _reenviarTodas(automatico: true);
      return;
    }
    _pendContagem.value =
        'reenvio automático em ${resto ~/ 60}:${(resto % 60).toString().padLeft(2, '0')}';
    _pendTimer = app.agendar(const Duration(seconds: 1), () {
      _pendTimer = null;
      _pendTique();
    });
  }

  /// Reenvia TODAS as DPS pendentes do prestador atual (botão "Reenviar agora" ou o ciclo
  /// automático de 5 min).
  void _reenviarTodas({bool automatico = false}) {
    if (!app.temPermissao('consultar.reenviar', somenteLogado: automatico)) {
      if (!automatico)
        app.exigirPermissao('consultar.reenviar', () => _reenviarTodas());
      return;
    }
    if (!app.viva) {
      _pendParar();
      return;
    }
    if (_pendEnviando) return;
    if (app.ocupado) {
      if (automatico) {
        _pendLimite = DateTime.now().add(const Duration(seconds: 30));
        _pendTique();
      } else {
        app.toast('Aguarde a operação atual antes de reenviar a fila.');
      }
      return;
    }
    final prest = app.prestador;
    final cert = app.cert;
    final pend = prest.isEmpty
        ? <Map<String, dynamic>>[]
        : jaLista('emissao.list_pendentes', {'prestador': prest});
    if (pend.isEmpty) {
      _refazerAvisoFila();
      _redesenhar();
      return;
    }
    _pendEnviando = true;
    _pendParar();
    _pendContagem.value = 'reenviando…';
    app.emSegundoPlano(() async {
      var certos = 0;
      var cofrePendente = 0;
      final falhas = <String>[];
      for (final p in pend) {
        try {
          final r = await chamar<Object?>('emissao.reenviar_pendente', {
            'prestador': prest,
            'p': p,
            'cert': cert,
            'automatico': automatico,
          });
          if (r is Map && r['subst_cofre_pendente'] == true) cofrePendente++;
          certos++;
          registrar(
            'Pendente nº ${p['n_dps']} reenviado com sucesso (prestador=$prest)',
          );
        } catch (e) {
          if (automatico && e is ErroNucleo && e.tipo == 'DpsNaoLocalizada') {
            continue;
          }
          falhas.add('nº ${p['n_dps']}: $e');
          registrar(
            'Reenvio do pendente nº ${p['n_dps']} falhou (prestador=$prest): $e',
            nivel: 'error',
          );
        }
      }
      _pendEnviando = false;
      if (certos > 0) {
        app.notasMudaram(); // notas novas: a Consulta recarrega
        app.toast('$certos NFS-e pendente(s) transmitida(s) com sucesso.');
      }
      if (cofrePendente > 0) {
        app.toast(
          '$cofrePendente substituição(ões) autorizada(s) na SEFIN. Atualização do Cofre pendente.',
        );
      }
      // no ciclo automático a falha fica só no registro e no aviso
      if (falhas.isNotEmpty && !automatico) {
        app.toast('Reenvio falhou — ${falhas.take(2).join(' | ')}', erro: true);
      }
      _refazerAvisoFila();
      if (app.prestador == prest && app.navAtual == 2) {
        carregarPagina();
      } else {
        app.atualizar();
      }
    });
  }

  /// Reenvia UMA DPS pendente (botão da linha).
  void _reenviarUm(Map<String, dynamic> p) {
    if (!app.temPermissao('consultar.reenviar')) {
      app.exigirPermissao('consultar.reenviar', () => _reenviarUm(p));
      return;
    }
    if (app.ocupado) {
      app.toast('Aguarde a operação atual antes de reenviar.');
      return;
    }
    if (_pendEnviando) {
      app.toast('Já existe um reenvio em andamento — aguarde.', erro: true);
      return;
    }
    final prest = app.prestador;
    final cert = app.cert;
    _pendEnviando = true;
    app.toast('Reenviando DPS nº ${p['n_dps']}…');
    app.emSegundoPlano(() async {
      Object? r;
      try {
        r = await chamar<Object?>('emissao.reenviar_pendente', {
          'prestador': prest,
          'p': p,
          'cert': cert,
          'automatico': false,
        });
      } catch (e) {
        _pendEnviando = false;
        registrar(
          'Reenvio do pendente nº ${p['n_dps']} falhou: $e',
          nivel: 'error',
        );
        app.toast('Reenvio falhou: $e', erro: true);
        _refazerAvisoFila();
        if (app.prestador == prest && app.navAtual == 2) carregarPagina();
        return;
      }
      _pendEnviando = false;
      registrar(
        'Pendente nº ${p['n_dps']} reenviado com sucesso (prestador=$prest)',
      );
      app.toast(
        r is Map && r['subst_cofre_pendente'] == true
            ? 'NFS-e da DPS nº ${p['n_dps']} transmitida. Substituição autorizada na SEFIN. Atualização do Cofre pendente.'
            : 'NFS-e da DPS nº ${p['n_dps']} transmitida!',
      );
      app.notasMudaram();
      _refazerAvisoFila();
      if (app.prestador == prest && app.navAtual == 2) carregarPagina();
    });
  }

  /// Confirma e cancela um envio pendente (já autorizado por senha nível 2).
  void _cancelarPendente(Map<String, dynamic> p) {
    final nome = _ou(p['tomador_nome'], _ou(p['tomador'], ''));
    app.mostrarDialogo(
      Dialogo(
        titulo: (_) => LinhaTitulo([
          Icon(Icons.warning_amber, color: Colors.red.shade700),
          textoTitulo('Cancelar envio pendente'),
        ], espaco: 10),
        largura: 520,
        conteudo: (_) => col(
          [
            Tx(
              'Cancelar o envio da DPS nº ${p['n_dps']} (série ${p['serie']}) de $nome?',
              largura: TamanhosConsultar.rotuloCancelarOEnvioDaDPSNoPN.largura,
              altura: TamanhosConsultar.rotuloCancelarOEnvioDaDPSNoPN.altura,
              idLayout: 'TamanhosConsultar.rotuloCancelarOEnvioDaDPSNoPN',
            ),
            Tx(
              'Se o número ainda for o último reservado, ele é liberado e a próxima '
              'emissão o reutiliza; senão ele fica como lacuna (permitido na NFS-e '
              'Nacional — não existe inutilização de DPS). Uma cópia da DPS fica '
              'guardada no banco de dados, para auditoria.',
              tam: Letra.apoio,
              cor: Colors.grey.shade700,
              largura: TamanhosConsultar
                  .rotuloSeONumeroAindaForOUltimoReservado
                  .largura,
              altura: TamanhosConsultar
                  .rotuloSeONumeroAindaForOUltimoReservado
                  .altura,
              idLayout:
                  'TamanhosConsultar.rotuloSeONumeroAindaForOUltimoReservado',
            ),
          ],
          justa: true,
          idLayout: 'Grupo.consultar.col.2',
        ),
        acoes: (_) => [
          Botao.texto(
            'Voltar',
            aoClicar: app.fecharDialogo,
            largura: TamanhosConsultar.botaoVoltar.largura,
            altura: TamanhosConsultar.botaoVoltar.altura,
            idLayout: 'TamanhosConsultar.botaoVoltar',
          ),
          Botao(
            'Cancelar envio',
            icone: Icons.delete_forever,
            cor: Colors.white,
            fundo: Colors.red.shade700,
            aoClicar: () {
              Map<String, dynamic> info;
              try {
                info = jaMapa('emissao.cancelar_pendente', {
                  'prestador': app.prestador,
                  'p': p,
                });
              } catch (e) {
                app.toast('$e', erro: true);
                return;
              }
              app.fecharDialogo();
              registrar(
                'Envio pendente CANCELADO: nDPS=${p['n_dps']} série=${p['serie']} '
                'reaproveitado=${info['reaproveitado']} prestador=${app.prestador}',
              );
              if (info['reaproveitado'] == true) {
                app.toast(
                  'Envio cancelado. O número ${p['n_dps']} era o último reservado e foi '
                  'LIBERADO — a próxima emissão o reutiliza.',
                );
              } else {
                app.toast(
                  'Envio cancelado. O número ${p['n_dps']} fica como LACUNA na numeração '
                  '(a NFS-e Nacional não tem inutilização de DPS; pulos são permitidos).',
                );
              }
              _refazerAvisoFila();
              carregarPagina();
            },
            largura: TamanhosConsultar.botaoCancelarEnvio.largura,
            altura: TamanhosConsultar.botaoCancelarEnvio.altura,
            idLayout: 'TamanhosConsultar.botaoCancelarEnvio',
          ),
        ],
        idLayout: 'Janela.consultar.Dialogo.2',
      ),
    );
  }

  /// Salva uma cópia da DPS assinada (pendente) num local escolhido pelo usuário.
  Future<void> _baixarDps(Map<String, dynamic> p) async {
    if (!await app.autorizarAcao('consultar.xml')) return;
    final b64 = ja<String>('emissao.pendente_xml', {
      'prestador': app.prestador,
      'id': p['id'],
    });
    if (b64.isEmpty) {
      app.toast('Este envio não está mais na fila.', erro: true);
      return;
    }
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Baixar DPS (XML assinado)',
        nome: 'DPS_${p['serie']}_${p['n_dps']}.xml',
        extensoes: const ['xml'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    if (!destino.toLowerCase().endsWith('.xml')) destino += '.xml';
    final numero = _ou(p['n_dps'], '?');
    try {
      File(destino).writeAsBytesSync(base64Decode(b64));
      app.toast('DPS nº $numero (pendente) salva em: $destino');
    } catch (e) {
      app.toast('Falha ao salvar a DPS nº $numero: $e', erro: true);
    }
  }

  // ---- filtros ------------------------------------------------------------------------------- //
  static String _ou(Object? v, String padrao) {
    final s = v?.toString() ?? '';
    return s.isEmpty ? padrao : s;
  }

  void recarregarTomadores() {
    _refazerEmpresas();
    _aplicarFiltro();
  }

  List<Map<String, dynamic>> _tomadores() => app.prestador.isEmpty
      ? []
      : jaLista('cadastro.list_tomadores', {'prestador': app.prestador});

  /// Lista de empresa: opções (Todas + clientes + Várias…) e o valor que retrata o filtro em
  /// uso — "Todas", a empresa (uma só) ou "N de M empresas" (combinação feita na janela).
  void _refazerEmpresas() {
    final tomadores = _tomadores();
    _temClientes = tomadores.isNotEmpty;
    final docs = {for (final t in tomadores) t['documento'] as String};
    var sel = _empresasSel;
    if (sel != null) {
      sel = sel.intersection(docs);
      _empresasSel = sel;
    }
    final listados = [
      for (final t in tomadores.take(_maxOpcoes)) t['documento'] as String,
    ];
    var textoVarias = 'Várias…';
    String valor = todos;
    if (sel == null || (sel.length == docs.length && sel.containsAll(docs))) {
      valor = todos;
    } else if (sel.length == 1 && listados.contains(sel.first)) {
      valor = sel.first;
    } else if (tomadores.isNotEmpty) {
      textoVarias = sel.length != 1
          ? '${sel.length} de ${docs.length} empresas'
          : (tomadores
                    .where((t) => sel!.contains(t['documento']))
                    .map((t) => t['display'] as String)
                    .firstOrNull ??
                '1 empresa');
      valor = _varias;
    }
    _ddEmpresa.opcoes = [
      const Opcao(todos, 'Todas'),
      for (final t in tomadores.take(_maxOpcoes))
        Opcao(t['documento'] as String, t['display'] as String),
      // o que a lista aberta mostra × o que o campo mostra com ela escolhida
      if (tomadores.isNotEmpty) Opcao(_varias, textoVarias, naLista: 'Várias…'),
    ];
    _ddEmpresa.por(valor);
    _ddEmpresa.avisar();
  }

  void _aoEmpresa(String? escolha) {
    if (escolha == _varias) {
      _abrirEmpresas(); // o filtro só muda pelo que for marcado lá
      return;
    }
    _empresasSel = (escolha == null || escolha.isEmpty || escolha == todos)
        ? null
        : {escolha};
    _pagina = 0;
    _refazerEmpresas();
    if (app.prestador.isNotEmpty) carregarPagina();
  }

  void _alternarEmpresa(String doc, bool marcado) {
    _empresasSel ??= {for (final t in _tomadores()) t['documento'] as String};
    if (marcado) {
      _empresasSel!.add(doc);
    } else {
      _empresasSel!.remove(doc);
    }
    _pagina = 0;
    _refazerEmpresas();
    // Espera o usuário parar: sem isso, cada clique de caixa refazia a consulta inteira.
    _filtroTimer?.cancel();
    _filtroTimer = app.agendar(const Duration(milliseconds: 300), () {
      _filtroTimer = null;
      if (app.prestador.isNotEmpty) carregarPagina();
    });
  }

  /// Janela do filtro de empresas: busca por nome + caixas de marcar com rolagem + marcar/
  /// desmarcar todas. A lista aplica na hora (a tabela atrás já reflete cada clique).
  void _abrirEmpresas() {
    final tomadores = _tomadores();
    if (tomadores.isEmpty) {
      app.toast('Nenhum cliente cadastrado.', erro: true);
      return;
    }
    final docs = {for (final t in tomadores) t['documento'] as String};
    Set<String> sel() => _empresasSel ?? docs;
    late final Dialogo d;
    late final TextEditingController busca;

    void todasOuNenhuma(bool todas) {
      _empresasSel = todas ? null : <String>{}; // nulo = todas (sem filtro)
      _pagina = 0;
      _refazerEmpresas();
      if (app.prestador.isNotEmpty) carregarPagina();
      d.atualizar();
    }

    d = Dialogo(
      titulo: (_) => app.tituloComX('Filtrar por empresa'),
      largura: 460,
      conteudo: (_) {
        final termos = termosBusca(busca.text);
        final consulta = termos.join();
        final marcadas = sel();
        final filtrados = [
          for (final t in tomadores)
            if (termos.isEmpty ||
                TextoDeBusca(t['display'] as String).casa(consulta, termos))
              t,
        ];
        // Teto de linhas: acima dele, refine a busca.
        final visiveis = filtrados.take(_maxOpcoes).toList();
        return col(
          [
            CampoTexto(
              controle: busca,
              rotulo: 'Buscar empresa',
              largura: TamanhosConsultar.campoBuscarEmpresa.largura,
              iconePrefixo: const Icon(Icons.search),
              aoMudar: (_) => d.atualizar(),
              altura: TamanhosConsultar.campoBuscarEmpresa.altura,
              idLayout: 'TamanhosConsultar.campoBuscarEmpresa',
            ),
            lin(
              [
                Botao.texto(
                  'Marcar todas',
                  aoClicar: () => todasOuNenhuma(true),
                  largura: TamanhosConsultar.botaoMarcarTodas.largura,
                  altura: TamanhosConsultar.botaoMarcarTodas.altura,
                  idLayout: 'TamanhosConsultar.botaoMarcarTodas',
                ),
                Botao.texto(
                  'Desmarcar todas',
                  aoClicar: () => todasOuNenhuma(false),
                  largura: TamanhosConsultar.botaoDesmarcarTodas.largura,
                  altura: TamanhosConsultar.botaoDesmarcarTodas.altura,
                  idLayout: 'TamanhosConsultar.botaoDesmarcarTodas',
                ),
                const Expanded(child: SizedBox()),
                Tx(
                  '${marcadas.length} de ${docs.length} empresa(s) selecionada(s).',
                  tam: Letra.apoio,
                  cor: Colors.grey.shade700,
                  largura: TamanhosConsultar
                      .rotuloMarcadasLengthDeDocsLengthEmpresaSSelecionada
                      .largura,
                  altura: TamanhosConsultar
                      .rotuloMarcadasLengthDeDocsLengthEmpresaSSelecionada
                      .altura,
                  idLayout:
                      'TamanhosConsultar.rotuloMarcadasLengthDeDocsLengthEmpresaSSelecionada',
                ),
              ],
              espaco: 4,
              idLayout: 'Grupo.consultar.lin.1',
            ),
            Ct(
              borda: Border.all(color: Colors.grey.shade300, width: 1),
              raio: BorderRadius.circular(8),
              padding: const EdgeInsets.all(6),
              child: col(
                [
                  for (final t in visiveis)
                    Marcar(
                      idLayout: 'Checkbox.consultar.1',
                      valor: marcadas.contains(t['documento']),
                      filhoRotulo: TxCorte(
                        t['display'] as String,
                        largura: 380,
                        tam: Letra.texto,
                      ),
                      aoMudar: (v) {
                        _alternarEmpresa(t['documento'] as String, v ?? false);
                        d.atualizar();
                      },
                    ),
                  if (filtrados.length > visiveis.length)
                    Tx(
                      '… e mais ${filtrados.length - visiveis.length} empresa(s) — refine a '
                      'busca para vê-las.',
                      italico: true,
                      tam: Letra.apoio,
                      cor: Colors.grey.shade600,
                      largura: TamanhosConsultar
                          .rotuloEMaisFiltradosLengthVisiveisLengthEmpresaS
                          .largura,
                      altura: TamanhosConsultar
                          .rotuloEMaisFiltradosLengthVisiveisLengthEmpresaS
                          .altura,
                      idLayout:
                          'TamanhosConsultar.rotuloEMaisFiltradosLengthVisiveisLengthEmpresaS',
                    ),
                  if (filtrados.isEmpty)
                    Tx(
                      'Nenhuma empresa encontrada com essa busca.',
                      italico: true,
                      cor: Colors.grey.shade600,
                      largura: TamanhosConsultar
                          .rotuloNenhumaEmpresaEncontradaComEssaBusca
                          .largura,
                      altura: TamanhosConsultar
                          .rotuloNenhumaEmpresaEncontradaComEssaBusca
                          .altura,
                      idLayout:
                          'TamanhosConsultar.rotuloNenhumaEmpresaEncontradaComEssaBusca',
                    ),
                ],
                espaco: 0,
                justa: true,
                altura: 340,
                rolar: true,
                idLayout: 'Grupo.consultar.col.4',
              ),
            ),
          ],
          justa: true,
          idLayout: 'Grupo.consultar.col.3',
        );
      },
      // Fechou (botão, X ou Esc): o campo volta a retratar o filtro — inclusive "Todas", se
      // a janela foi aberta por "Várias…" e nada foi desmarcado.
      aoFechar: () {
        _refazerEmpresas();
        _redesenhar();
      },
      idLayout: 'Janela.consultar.Dialogo.3',
    );
    busca = d.texto();
    app.mostrarDialogo(d);
  }

  void _aoAmbiente(String? v) {
    final val = v ?? 'todos';
    _ambiente = ambRotulos.containsKey(val) ? val : '';
    _pagina = 0;
    if (app.prestador.isNotEmpty) carregarPagina();
  }

  void _aoPeriodo(String? v) {
    if (v == 'custom') {
      // As datas vêm da janela; o filtro só muda quando ela é confirmada.
      abrirPeriodo(
        app,
        _de,
        _ate,
        (de, ate) {
          _de = de;
          _ate = ate;
          _periodoAnt = 'custom';
          _sincronizarPeriodo();
          _aplicarFiltro();
        },
        () {
          // Fechou sem confirmar e o período em uso era outro: a lista volta a ele.
          if (_periodoAnt != 'custom') {
            _ddPeriodo.por(_periodoAnt);
            _ddPeriodo.avisar();
          }
        },
      );
      return;
    }
    _periodoAnt = v ?? 'mes';
    _sincronizarPeriodo();
    _aplicarFiltro();
  }

  /// Com "Personalizado" EM USO o campo da lista mostra o intervalo no lugar da palavra.
  void _sincronizarPeriodo() {
    final intervalo = _periodoAnt == 'custom'
        ? textoDoIntervalo(_de, _ate)
        : '';
    _ddPeriodo.opcoes = opcoesDePeriodo(intervalo);
    _ddPeriodo.por(_ddPeriodo.valor);
    _ddPeriodo.avisar();
    _redesenhar();
  }

  double get _larguraPeriodo =>
      (_periodoAnt == 'custom' && textoDoIntervalo(_de, _ate).isNotEmpty)
      ? larguraPeriodoComDatas
      : 200;

  (DateTime?, DateTime?) _datas() => datasDoPeriodo(_periodoAnt, _de, _ate);

  /// (empresas, ini, fim, termo, ambiente) em uso. Empresas: nulo = todas; lista (mesmo
  /// vazia) = só essas.
  (List<String>?, DateTime?, DateTime?, String, String?) filtro() {
    final (ini, fim) = _datas();
    return (
      _empresasSel?.toList(),
      ini,
      fim,
      _busca.text.trim(),
      ambRotulos.containsKey(_ambiente) ? _ambiente : null,
    );
  }

  Map<String, Object?> _opcoesDaConsulta({bool comBusca = true}) {
    final (toms, ini, fim, termo, amb) = filtro();
    return {
      'prestador': app.prestador,
      'tomadores': comBusca ? toms : null,
      'ini': dataIso(ini),
      'por_competencia': _ddBasePeriodo.valor == 'competencia',
      if (_ddBasePeriodo.valor == 'movimento') 'por_movimento': true,
      'fim': dataIso(fim),
      'termo': comBusca ? termo : '',
      'sort_col': _ordem?.$1,
      'asc': _ordem?.$2 ?? true,
      'ambiente': amb ?? '',
    };
  }

  /// Entrada da consulta: mostra a 1ª página das notas emitidas por este programa.
  void _aplicarFiltro() {
    if (app.prestador.isEmpty) {
      _consultaAtual++;
      _pendentes = const [];
      _notas = const [];
      _vazio = 'Selecione um prestador.';
      _total = 0;
      app.atualizar();
      return;
    }
    _pagina = 0;
    carregarPagina();
  }

  /// Mostra a página atual.
  int _consultaAtual = 0;
  bool _carregando = false;
  Future<void> carregarPagina() async {
    if (!app.temPermissao('consultar.pesquisar')) return;
    final consulta = ++_consultaAtual;
    _carregando = true;
    _redesenhar();
    final prest = app.prestador;
    final opcoes = _opcoesDaConsulta();
    final porPagina = _porPagina;
    var paginaAtual = _pagina;
    final (toms, ini, fim, _, _) = filtro();
    bool atual() =>
        mounted &&
        app.viva &&
        consulta == _consultaAtual &&
        prest == app.prestador;
    if (toms != null && toms.isEmpty) {
      _total = 0;
      _pendentes = const [];
      _notas = const [];
      _carregando = false;
      _vazio = 'Nenhuma empresa selecionada no filtro.';
      _carregadoPrest = prest;
      _redesenhar();
      return;
    }
    Future<List> pagina(int offset) => chamar<List>(
      'consulta.page_nfse_index',
      {...opcoes, 'limit': porPagina, 'offset': offset},
    );
    try {
      var r = await pagina(paginaAtual * porPagina);
      if (!atual()) return;
      final total = (r[0] as num).toInt();
      final paginas = math.max(1, (total / porPagina).ceil());
      final nova = paginaAtual.clamp(0, paginas - 1);
      if (nova != paginaAtual) {
        paginaAtual = nova;
        r = await pagina(paginaAtual * porPagina);
        if (!atual()) return;
      }
      final auxiliares = await Future.wait([
        if (paginaAtual == 0)
          chamar<List>('emissao.list_pendentes', {'prestador': prest})
        else
          Future<List>.value([]),
        chamar<List>('emissao.subst_pairs', {'prestador': prest}),
      ]);
      if (!atual()) return;
      final pend = [
        for (final v in auxiliares[0].take(_maxLinhas))
          Map<String, dynamic>.from(v as Map),
      ];
      _pagina = paginaAtual;
      _total = total;
      _pares = {
        for (final par in auxiliares[1]) par[0] as String: par[1] as String,
      };
      _pendentes = pend;
      _notas = [
        for (final x in (r[1] as List).take(_maxLinhas - pend.length))
          Map<String, dynamic>.from(x as Map),
      ];
      _carregadoPrest = prest;
      _refazerAvisoFila();
      final faixa = (ini != null || fim != null)
          ? ' • período ${ini == null ? '…' : dataBr(ini)} a ${fim == null ? '…' : dataBr(fim)}'
          : '';
      _vazio = _total == 0
          ? 'Nenhuma NFS-e encontrada$faixa.'
          : '${milhar(_total)} NFS-e encontrada(s)$faixa.';
    } catch (e) {
      if (!atual()) return;
      registrar('Falha ao carregar a página da Consulta: $e', nivel: 'error');
    }
    if (atual()) {
      _carregando = false;
      _redesenhar();
    }
  }

  int get _paginas => math.max(1, (_total / _porPagina).ceil());

  // ---- exportar dados: UMA janela para XMLs, DANFSe e relatórios --------------------------- //
  void _abrirExportar() {
    if (!app.temPermissao('consultar.exportar')) {
      app.exigirPermissao('consultar.exportar', () => _abrirExportar());
      return;
    }
    if (app.prestador.isEmpty) {
      app.toast('Selecione um prestador.', erro: true);
      return;
    }
    // Nasce com o período e o ambiente que estão na tela da Consulta.
    late final Dialogo d;
    late final Suspensa ddPer, ddAmb, ddBase;
    var de = _de;
    var ate = _ate;
    var anterior = _periodoAnt;
    var (xml, danfse, eventos, relatorio) = (true, false, false, false);
    final formatos = {for (final f in formatosExportacao.keys) f: f == 'xlsx'};
    final (toms, _, _, termo, _) = filtro();

    String intervalo() => anterior == 'custom' ? textoDoIntervalo(de, ate) : '';
    void mostrarPeriodo() {
      // Como na Consulta: com o personalizado em uso o campo mostra as datas. A lista alarga
      // e a do ambiente cede a diferença — as duas seguem lado a lado.
      ddPer.opcoes = opcoesDePeriodo(intervalo());
      ddPer.por(ddPer.valor);
      ddPer.avisar();
      d.atualizar();
    }

    double larguraPer() => intervalo().isEmpty ? 210 : larguraPeriodoComDatas;

    void aoPeriodo(String? v) {
      if (v == 'custom') {
        abrirPeriodo(
          app,
          de,
          ate,
          (a, b) {
            de = a;
            ate = b;
            anterior = 'custom';
            mostrarPeriodo();
          },
          () {
            // nunca chegou a ter datas: volta ao de antes
            if (anterior != 'custom') {
              ddPer.por(anterior);
              ddPer.avisar();
            }
          },
        );
        return;
      }
      anterior = v ?? 'mes';
      mostrarPeriodo();
    }

    void exportar() {
      final (ini, fim) = datasDoPeriodo(ddPer.valor ?? 'mes', de, ate);
      if (ddPer.valor == 'custom' && !(ini != null && fim != null)) {
        app.toast('Escolha as datas do período personalizado.', erro: true);
        return;
      }
      final amb = ambRotulos.containsKey(ddAmb.valor) ? ddAmb.valor : null;
      final fmts = relatorio
          ? [
              for (final e in formatos.entries)
                if (e.value) e.key,
            ]
          : <String>[];
      if (relatorio && fmts.isEmpty) {
        app.toast('Marque ao menos um formato para o relatório.', erro: true);
        return;
      }
      if (!(xml || danfse || eventos || fmts.isNotEmpty)) {
        app.toast('Marque o que deve ser exportado.', erro: true);
        return;
      }
      if (fmts.isNotEmpty && toms != null && toms.isEmpty) {
        app.toast('Nenhuma empresa selecionada no filtro.', erro: true);
        return;
      }
      app.fecharDialogo();
      _exportarDados(
        ini,
        fim,
        amb,
        xml,
        danfse,
        eventos,
        fmts,
        baseDaData: ddBase.valor,
      );
    }

    d = Dialogo(
      titulo: (_) => app.tituloComX('Exportar dados'),
      largura: 470,
      conteudo: (_) => col(
        [
          lin(
            [
              ListaSuspensa(
                estado: ddPer,
                rotulo: 'Período',
                largura:
                    TamanhosConsultar.campoPeriodo.largura ?? (larguraPer()),
                aoSelecionar: aoPeriodo,
                altura: TamanhosConsultar.campoPeriodo.altura,
                idLayout: 'TamanhosConsultar.campoPeriodo',
              ),
              ListaSuspensa(
                estado: ddAmb,
                rotulo: 'Ambiente',
                largura:
                    TamanhosConsultar.campoAmbiente.largura ??
                    (420 - larguraPer()),
                altura: TamanhosConsultar.campoAmbiente.altura,
                idLayout: 'TamanhosConsultar.campoAmbiente',
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.consultar.lin.2',
          ),
          ListaSuspensa(
            estado: ddBase,
            rotulo: 'Filtrar por',
            largura: 210,
            idLayout: 'Consultar.exportar.filtrarPor',
          ),
          Tx(
            'O que exportar',
            tam: Letra.apoio,
            peso: FontWeight.w600,
            largura: TamanhosConsultar.rotuloOQueExportar.largura,
            altura: TamanhosConsultar.rotuloOQueExportar.altura,
            idLayout: 'TamanhosConsultar.rotuloOQueExportar',
          ),
          col(
            [
              Marcar(
                idLayout: 'Checkbox.consultar.2',
                valor: xml,
                rotulo: 'XMLs das notas',
                aoMudar: (v) {
                  xml = v ?? false;
                  d.atualizar();
                },
              ),
              Marcar(
                idLayout: 'Checkbox.consultar.3',
                valor: danfse,
                rotulo: 'DANFSe (PDF)',
                aoMudar: (v) {
                  danfse = v ?? false;
                  d.atualizar();
                },
              ),
              Marcar(
                idLayout: 'Checkbox.consultar.4',
                valor: eventos,
                rotulo: 'Eventos (cancelamentos e substituições)',
                aoMudar: (v) {
                  eventos = v ?? false;
                  d.atualizar();
                },
              ),
              Marcar(
                idLayout: 'Checkbox.consultar.5',
                valor: relatorio,
                rotulo: 'Relatório',
                aoMudar: (v) {
                  relatorio = v ?? false;
                  d.atualizar();
                },
              ),
              if (relatorio)
                Ct(
                  padding: const EdgeInsets.fromLTRB(34, 0, 0, 4),
                  child: col(
                    [
                      Tx(
                        'Formatos do relatório:',
                        tam: Letra.apoio,
                        cor: Colors.grey.shade700,
                        largura:
                            TamanhosConsultar.rotuloFormatosDoRelatorio.largura,
                        altura:
                            TamanhosConsultar.rotuloFormatosDoRelatorio.altura,
                        idLayout: 'TamanhosConsultar.rotuloFormatosDoRelatorio',
                      ),
                      lin(
                        [
                          for (final e in formatosExportacao.entries)
                            Marcar(
                              idLayout: 'Checkbox.consultar.6',
                              compacto: true,
                              valor: formatos[e.key],
                              rotulo: e.value.$2,
                              aoMudar: (v) {
                                formatos[e.key] = v ?? false;
                                d.atualizar();
                              },
                            ),
                        ],
                        espaco: 4,
                        quebra: true,
                        idLayout: 'Grupo.consultar.lin.3',
                      ),
                    ],
                    espaco: 0,
                    justa: true,
                    idLayout: 'Grupo.consultar.col.7',
                  ),
                ),
            ],
            espaco: 0,
            justa: true,
            idLayout: 'Grupo.consultar.col.6',
          ),
          Tx(
            'Tudo sai num único arquivo .zip, cada tipo na sua pasta (xml, danfse, eventos e '
            'Relatorios); você escolhe onde salvá-lo.'
            '${(toms != null || termo.isNotEmpty) ? ' O relatório respeita a busca e o filtro de empresas da tela.' : ''}',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura: TamanhosConsultar
                .rotuloTudoSaiNumUnicoArquivoZipCadaTipo
                .largura,
            altura: TamanhosConsultar
                .rotuloTudoSaiNumUnicoArquivoZipCadaTipo
                .altura,
            idLayout:
                'TamanhosConsultar.rotuloTudoSaiNumUnicoArquivoZipCadaTipo',
          ),
        ],
        justa: true,
        espaco: 12,
        idLayout: 'Grupo.consultar.col.5',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosConsultar.botaoCancelar2.largura,
          altura: TamanhosConsultar.botaoCancelar2.altura,
          idLayout: 'TamanhosConsultar.botaoCancelar2',
        ),
        Botao(
          'Exportar',
          icone: Icons.download,
          aoClicar: exportar,
          largura: TamanhosConsultar.botaoExportar.largura,
          altura: TamanhosConsultar.botaoExportar.altura,
          idLayout: 'TamanhosConsultar.botaoExportar',
        ),
      ],
      idLayout: 'Janela.consultar.Dialogo.4',
    );
    ddPer = d.suspensa(valor: anterior, opcoes: opcoesDePeriodo(intervalo()));
    ddBase = d.suspensa(valor: _ddBasePeriodo.valor, opcoes: opcoesBasePeriodo);
    ddAmb = d.suspensa(
      valor: _ddAmbiente.valor ?? 'todos',
      opcoes: opcoesDeAmbiente,
    );
    app.mostrarDialogo(d);
  }

  /// Avisa que o PDF do relatório vai ficar pesado. true = gerar mesmo assim.
  Future<bool> _confirmarPdfGrande(int total) {
    final resposta = Completer<bool>();
    late final Dialogo d;
    void responder(bool v) {
      if (!resposta.isCompleted) resposta.complete(v);
    }

    d = Dialogo(
      titulo: (_) => LinhaTitulo([
        Icon(Icons.warning_amber, color: Colors.orange.shade700),
        textoTitulo('PDF grande'),
      ], espaco: 10),
      conteudo: (_) => Tx(
        'O relatório tem ${milhar(total)} notas. Um PDF com tantas linhas fica '
        'pesado e pode demorar bastante para gerar e abrir. Para muitos dados, '
        'prefira Excel ou CSV.',
        largura:
            TamanhosConsultar.rotuloORelatorioTemMilharTotalNotasUmPDF.largura,
        altura:
            TamanhosConsultar.rotuloORelatorioTemMilharTotalNotasUmPDF.altura,
        idLayout: 'TamanhosConsultar.rotuloORelatorioTemMilharTotalNotasUmPDF',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: () => app.fecharEsta(d),
          largura: TamanhosConsultar.botaoCancelar3.largura,
          altura: TamanhosConsultar.botaoCancelar3.altura,
          idLayout: 'TamanhosConsultar.botaoCancelar3',
        ),
        Botao(
          'Gerar PDF mesmo assim',
          icone: Icons.picture_as_pdf,
          aoClicar: () {
            responder(true);
            app.fecharEsta(d);
          },
          largura: TamanhosConsultar.botaoGerarPDFMesmoAssim.largura,
          altura: TamanhosConsultar.botaoGerarPDFMesmoAssim.altura,
          idLayout: 'TamanhosConsultar.botaoGerarPDFMesmoAssim',
        ),
      ],
      aoFechar: () => responder(false), // Cancelar, X e Esc
      idLayout: 'Janela.consultar.Dialogo.5',
    );
    app.mostrarDialogo(d);
    return resposta.future;
  }

  /// Gera o que foi marcado, SEMPRE num único .zip que o usuário escolhe onde salvar: xml/,
  /// danfse/ e eventos/ com os arquivos das notas, Relatorios/ com um arquivo por formato.
  Future<void> _exportarDados(
    DateTime? ini,
    DateTime? fim,
    String? amb,
    bool xml,
    bool danfse,
    bool eventos,
    List<String> fmts, {
    required String? baseDaData,
  }) async {
    final (toms, _, _, termo, _) = filtro();
    final prestador = app.prestador;
    final base = <String, Object?>{
      'prestador': prestador,
      'ini': dataIso(ini),
      'por_competencia': baseDaData == 'competencia',
      if (baseDaData == 'movimento') 'por_movimento': true,
      'fim': dataIso(fim),
      'ambiente': amb ?? '',
    };
    // Sem NADA no período/ambiente: avisa e nem abre a janela de salvar.
    int total;
    try {
      total = ja<int>('consulta.count_nfse_index', base);
    } catch (_) {
      total = -1;
    }
    if (total == 0) {
      app.toast(
        'Nenhuma NFS-e no período/ambiente escolhido — nada para exportar.',
        erro: true,
      );
      return;
    }
    if (fmts.contains('pdf')) {
      int n;
      try {
        n = ja<int>('consulta.count_nfse_index', {
          ...base,
          'tomadores': toms,
          'termo': termo,
        });
      } catch (_) {
        n = 0;
      }
      if (n > _avisoPdf && !await _confirmarPdfGrande(n)) return;
    }
    final nome =
        'nfse_${soDoc(prestador)}_${dataCompacta(ini, 'ini')}_${dataCompacta(fim, 'fim')}';
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Exportar dados (.zip)',
        nome: '$nome.zip',
        extensoes: const ['zip'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    if (!destino.toLowerCase().endsWith('.zip')) destino += '.zip';
    final dest = destino;
    final ordem = _ordem;
    final progresso = ProgressoExportacao(app)..abrir();

    app.emSegundoPlano(() async {
      final partes = <String>[]; // resumo para o aviso e o Registro
      var arquivos = 0;
      final rascunho = Directory.systemTemp.createTempSync('nfse_export_');
      try {
        // Começa do zero: o "Salvar como" já confirmou se era para substituir.
        apagarSeExistir(dest);
        if (xml || danfse || eventos) {
          progresso.etapa(
            'Exportando ${[if (xml) 'XMLs', if (danfse) 'DANFSe', if (eventos) 'eventos'].join(', ')}…',
          );
          final r = await chamar<List>('exportacao.xmls_zip', {
            ...base,
            'destino': dest,
            'incluir_xml': xml,
            'incluir_danfse': danfse,
            'incluir_eventos': eventos,
            'ficha': progresso.ficha,
          }, progresso.aviso);
          final (nXml, nPdf, nEvt) = (
            (r[0] as num).toInt(),
            (r[1] as num).toInt(),
            (r[2] as num).toInt(),
          );
          arquivos += nXml + nPdf + nEvt;
          partes.addAll([
            if (xml) '$nXml XML(s)',
            if (danfse) '$nPdf DANFSe',
            if (eventos) '$nEvt evento(s)',
          ]);
        }
        for (final fmt in fmts) {
          final (ext, rotulo) = formatosExportacao[fmt]!;
          // PDF: a montagem é opaca -> barra indeterminada (sem progresso fino).
          progresso.etapa(
            fmt == 'pdf'
                ? 'Gerando PDF… isso pode demorar.'
                : 'Gerando relatório $rotulo…',
            indeterminada: fmt == 'pdf',
          );
          if (progresso.cancelada) throw ErroNucleo('ExportCancelled', '');
          final arq = '${rascunho.path}${Platform.pathSeparator}$nome.$ext';
          final n = await chamar<int>('exportacao.$fmt', {
            ...base,
            'destino': arq,
            'tomadores': toms,
            'termo': termo,
            'sort_col': ordem?.$1,
            'asc': ordem?.$2 ?? true,
            'ficha': progresso.ficha,
          }, fmt == 'pdf' ? null : progresso.aviso);
          // terminou antes de perceber o cancelamento
          if (progresso.cancelada) throw ErroNucleo('ExportCancelled', '');
          await chamar<Object?>('exportacao.zip_anexar', {
            'destino': dest,
            'arquivo': arq,
            'nome': 'Relatorios/$nome.$ext',
          });
          arquivos++;
          partes.add('relatório $rotulo com $n nota(s)');
        }
        if (progresso.cancelada) throw ErroNucleo('ExportCancelled', '');
      } on ErroNucleo catch (e) {
        apagarSeExistir(dest);
        if (e.tipo == 'ExportCancelled' || progresso.cancelada) {
          // Cancelado (a janela já foi fechada pelo Cancelar): o zip não fica.
          return;
        }
        registrar('Falha ao exportar ($dest): $e', nivel: 'error');
        progresso.fechar();
        app.toast('Falha ao exportar: $e', erro: true);
        return;
      } catch (e) {
        registrar('Falha ao exportar ($dest): $e', nivel: 'error');
        apagarSeExistir(dest);
        progresso.fechar();
        app.toast('Falha ao exportar: $e', erro: true);
        return;
      } finally {
        try {
          rascunho.deleteSync(recursive: true);
        } catch (_) {}
      }
      progresso.fechar();
      if (arquivos == 0) {
        // Havia registros mas nenhum ARQUIVO existia: sem zip vazio.
        apagarSeExistir(dest);
        registrar(
          'Exportação sem arquivos no filtro — zip descartado ($dest)',
          nivel: 'warning',
        );
        app.toast(
          'Nenhum arquivo encontrado para exportar — o zip não foi gerado.',
          erro: true,
        );
        return;
      }
      registrar('Exportação concluída (${partes.join('; ')}) em $dest');
      app.toast(
        'Exportado para .zip: ${partes.join('; ')} '
        '(${periodoPorExtenso(ini, fim)}${amb != null ? ', ${ambRotulos[amb]}' : ''}).',
      );
    });
  }

  // ---- ações de cada nota -------------------------------------------------------------------- //
  /// Salva uma cópia do XML oficial (lido do banco de notas) num local escolhido.
  Future<void> _baixarXml(Map<String, dynamic> rec) async {
    if (!await app.autorizarAcao('consultar.xml')) return;
    final nome = _ou(rec['chave'], _ou(rec['nNFSe'], 'nfse'));
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Baixar XML da NFS-e',
        nome: '$nome.xml',
        extensoes: const ['xml'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    // Se o usuário renomeou o arquivo na janela do Windows, o nome pode vir SEM a extensão.
    if (!destino.toLowerCase().endsWith('.xml')) destino += '.xml';
    final numero = _ou(rec['nNFSe'], '?');
    final dest = destino;
    void gravar() {
      try {
        final b64 = ja<String>('cofre.xml_por_chave', {
          'dono': app.prestador,
          'chave': rec['chave'],
        });
        File(dest).writeAsBytesSync(base64Decode(b64));
        app.toast(
          'XML da NFS-e nº $numero (${rec['ambiente_label']}) salvo em: $dest',
        );
      } catch (e) {
        final id = notaComXmlIlegivel(e);
        if (id != null) {
          oferecerRebusca(
            app,
            dono: app.prestador,
            notaId: id,
            rotulo: 'NFS-e nº $numero',
            aoRecuperar: gravar,
          );
          return;
        }
        app.toast('Falha ao salvar XML da NFS-e nº $numero: $e', erro: true);
      }
    }

    gravar();
  }

  // ---- estorno (cancelamento) de NFS-e --------------------------------------------------------- //
  void _estornar(Map<String, dynamic> rec) {
    if (rec['cancelada'] == true) {
      app.toast('Esta NFS-e já está cancelada.', erro: true);
      return;
    }
    final dh = (rec['dhProc'] as String?) ?? '';
    final dataDaNota = RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(dh.trim())
        ? dh
        : ((rec['dCompet'] as String?) ?? '');
    final st = ja<List>('emissao.cancelamento_status', {'data': dataDaNota});
    final pode = st[0] == true;
    final limiteIso = st[1] as String?;
    final limite = limiteIso == null
        ? '—'
        : '${limiteIso.substring(8, 10)}/${limiteIso.substring(5, 7)}/${limiteIso.substring(0, 4)}';
    if (!pode) {
      // Prazo de cancelamento direto excedido — informa e bloqueia.
      app.mostrarDialogo(
        Dialogo(
          titulo: (_) => LinhaTitulo([
            Icon(Icons.warning_amber, color: Colors.orange.shade700),
            textoTitulo('Prazo de estorno excedido'),
          ], espaco: 10),
          largura: 540,
          conteudo: (_) => col(
            [
              Tx(
                'O prazo para cancelamento direto desta NFS-e era até $limite '
                '(dia 15 do mês seguinte ao da emissão).',
                largura: TamanhosConsultar
                    .rotuloOPrazoParaCancelamentoDiretoDestaNFSE
                    .largura,
                altura: TamanhosConsultar
                    .rotuloOPrazoParaCancelamentoDiretoDestaNFSE
                    .altura,
                idLayout:
                    'TamanhosConsultar.rotuloOPrazoParaCancelamentoDiretoDestaNFSE',
              ),
              Tx(
                'Depois desse prazo a Sefin Nacional não permite o cancelamento direto: '
                'é necessário solicitar Análise Fiscal para Cancelamento ou fazer '
                'cancelamento por substituição, conforme as regras do município.',
                cor: Colors.grey.shade700,
                tam: Letra.apoio,
                largura: TamanhosConsultar
                    .rotuloDepoisDessePrazoASefinNacionalNaoPermite
                    .largura,
                altura: TamanhosConsultar
                    .rotuloDepoisDessePrazoASefinNacionalNaoPermite
                    .altura,
                idLayout:
                    'TamanhosConsultar.rotuloDepoisDessePrazoASefinNacionalNaoPermite',
              ),
            ],
            justa: true,
            idLayout: 'Grupo.consultar.col.8',
          ),
          acoes: (_) => [
            Botao.texto(
              'Entendi',
              aoClicar: app.fecharDialogo,
              largura: TamanhosConsultar.botaoEntendi.largura,
              altura: TamanhosConsultar.botaoEntendi.altura,
              idLayout: 'TamanhosConsultar.botaoEntendi',
            ),
          ],
          idLayout: 'Janela.consultar.Dialogo.6',
        ),
      );
      return;
    }
    late final Dialogo d;
    late final Suspensa motivo;
    late final TextEditingController just;
    final codigo = _ou(rec['tpAmb'], _ou(rec['ambGer'], ''));
    final amb = ambRotulos[codigo] ?? '?';
    // Mesmo padrão de cor do resto do programa: Produção VERDE, Homologação VERMELHO.
    final cor = codigo == ambProducao
        ? Colors.green.shade700
        : Colors.red.shade700;
    d = Dialogo(
      titulo: (_) => textoTitulo('Estornar NFS-e nº ${rec['nNFSe']}'),
      largura: 560,
      conteudo: (_) => col(
        [
          Ct(
            cor: cor,
            padding: const EdgeInsets.all(10),
            raio: BorderRadius.circular(8),
            child: Tx(
              'AMBIENTE: $amb',
              cor: Colors.white,
              peso: FontWeight.bold,
              largura: TamanhosConsultar.rotuloAMBIENTEAmb.largura,
              altura: TamanhosConsultar.rotuloAMBIENTEAmb.altura,
              idLayout: 'TamanhosConsultar.rotuloAMBIENTEAmb',
            ),
          ),
          Tx(
            'Cliente: ${_ou(rec['tomador_nome'], _ou(rec['tomador'], '—'))}',
            largura: TamanhosConsultar
                .rotuloClienteOuRecTomadorNomeOuRecTomador
                .largura,
            altura: TamanhosConsultar
                .rotuloClienteOuRecTomadorNomeOuRecTomador
                .altura,
            idLayout:
                'TamanhosConsultar.rotuloClienteOuRecTomadorNomeOuRecTomador',
          ),
          Tx(
            'Prazo de estorno: até $limite.',
            largura: TamanhosConsultar.rotuloPrazoDeEstornoAteLimite.largura,
            altura: TamanhosConsultar.rotuloPrazoDeEstornoAteLimite.altura,
            idLayout: 'TamanhosConsultar.rotuloPrazoDeEstornoAteLimite',
          ),
          ListaSuspensa(
            estado: motivo,
            rotulo: 'Motivo do cancelamento',
            largura: TamanhosConsultar.campoMotivoDoCancelamento.largura!,
            altura: TamanhosConsultar.campoMotivoDoCancelamento.altura,
            idLayout: 'TamanhosConsultar.campoMotivoDoCancelamento',
          ),
          CampoTexto(
            controle: just,
            rotulo: 'Justificativa (mín. 15 caracteres)',
            variasLinhas: true,
            minLinhas: 2,
            maxLinhas: 4,
            largura:
                TamanhosConsultar.campoJustificativaMin15Caracteres.largura,
            maximo: 255,
            altura: TamanhosConsultar.campoJustificativaMin15Caracteres.altura,
            idLayout: 'TamanhosConsultar.campoJustificativaMin15Caracteres',
          ),
          Tx(
            'Esta ação transmite o evento de cancelamento à Sefin e não pode ser desfeita.',
            cor: Colors.orange.shade800,
            tam: Letra.apoio,
            largura: TamanhosConsultar
                .rotuloEstaAcaoTransmiteOEventoDeCancelamentoA
                .largura,
            altura: TamanhosConsultar
                .rotuloEstaAcaoTransmiteOEventoDeCancelamentoA
                .altura,
            idLayout:
                'TamanhosConsultar.rotuloEstaAcaoTransmiteOEventoDeCancelamentoA',
          ),
        ],
        justa: true,
        idLayout: 'Grupo.consultar.col.9',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosConsultar.botaoCancelar4.largura,
          altura: TamanhosConsultar.botaoCancelar4.altura,
          idLayout: 'TamanhosConsultar.botaoCancelar4',
        ),
        Botao(
          'Confirmar estorno',
          icone: Icons.cancel,
          aoClicar: () {
            final j = just.text.trim();
            if (j.length < 15) {
              app.toast(
                'A justificativa deve ter ao menos 15 caracteres.',
                erro: true,
              );
              return;
            }
            app.fecharDialogo();
            _fazerEstorno(rec, motivo.valor ?? '1', j);
          },
          largura: TamanhosConsultar.botaoConfirmarEstorno.largura,
          altura: TamanhosConsultar.botaoConfirmarEstorno.altura,
          idLayout: 'TamanhosConsultar.botaoConfirmarEstorno',
        ),
      ],
      idLayout: 'Janela.consultar.Dialogo.7',
    );
    motivo = d.suspensa(
      valor: '1',
      opcoes: [
        for (final (k, v) in jaPares('emissao.canc_motivos'))
          Opcao(k, '$k — $v'),
      ],
    );
    just = d.texto();
    app.mostrarDialogo(d);
  }

  void _fazerEstorno(Map<String, dynamic> rec, String cMotivo, String xMotivo) {
    final amb = rec['ambiente_label'];
    final n = rec['nNFSe'];
    final prest =
        app.prestador; // retrato: o trabalho não pode ler a tela depois
    final ht = app.toastProgresso('Estornando NFS-e nº $n ($amb)…');
    registrar(
      'Estorno iniciado: NFS-e nº $n chave ${rec['chave']} (prestador=$prest motivo=$cMotivo)',
    );
    app.emSegundoPlano(() async {
      Map<String, dynamic> res;
      try {
        res = Map<String, dynamic>.from(
          await chamar<Map>('emissao.cancelar_nfse', {
            'prestador': prest,
            'chave': rec['chave'],
            'c_motivo': cMotivo,
            'x_motivo': xMotivo,
          }),
        );
      } catch (e) {
        registrar('Erro ao estornar NFS-e nº $n: $e', nivel: 'error');
        // Pode ter sido REGISTRADO na SEFIN e o erro estar depois do envio. Nunca sugerir
        // "tente de novo" às cegas.
        app.toastFim(
          ht,
          'Não foi possível CONFIRMAR o estorno da NFS-e nº $n ($amb): $e',
          erro: true,
        );
        _resultadoEstorno(
          false,
          'Não foi possível confirmar o estorno da NFS-e nº $n. O evento PODE '
          'ter sido registrado na SEFIN. Confira o status no portal nacional '
          'antes de tentar de novo.\n\nDetalhe: $e',
          null,
        );
        return;
      }
      if (res['ok'] == true) {
        registrar('NFS-e nº $n CANCELADA com sucesso');
        final aviso = (res['aviso'] as String?) ?? '';
        if (aviso.isNotEmpty) {
          // Aceito pela SEFIN, mas o registro no banco de notas falhou: a nota continuaria
          // aparecendo ativa — precisa aparecer para o usuário.
          registrar(
            'Estorno da NFS-e nº $n aceito, mas sem marcador local: $aviso',
            nivel: 'warning',
          );
          app.toastFim(
            ht,
            'NFS-e nº $n ($amb) estornada, mas o registro local falhou.',
            erro: true,
          );
          _resultadoEstorno(
            true,
            'NFS-e nº $n cancelada na SEFIN.\n\n$aviso',
            res,
          );
        } else {
          app.toastFim(
            ht,
            'NFS-e nº $n ($amb) estornada — cancelamento aceito pela Sefin.',
          );
          _resultadoEstorno(true, 'NFS-e nº $n cancelada com sucesso.', res);
        }
      } else {
        registrar(
          'Sefin recusou cancelamento da NFS-e nº $n (HTTP ${res['status_code']})',
          nivel: 'error',
        );
        app.toastFim(
          ht,
          'Sefin recusou o estorno da NFS-e nº $n ($amb) — HTTP ${res['status_code']}.',
          erro: true,
        );
        _resultadoEstorno(
          false,
          'A Sefin não aceitou o cancelamento (HTTP ${res['status_code']}).',
          res,
        );
      }
      if (app.prestador == prest)
        carregarPagina(); // recarrega a página (status atualizado)
    });
  }

  /// Resultado do estorno: mensagem + botão OK no centro (Enter e Esc fecham). A resposta
  /// da Sefin fica num mini-botão ao lado da mensagem, que abre uma janela própria.
  void _resultadoEstorno(bool ok, String mensagem, Map<String, dynamic>? res) {
    String? resposta;
    final corpo = res?['body'];
    if (corpo != null) {
      resposta = corpo is String
          ? corpo
          : const JsonEncoder.withIndent('  ').convert(corpo);
    }
    app.mostrarDialogo(
      Dialogo(
        marcador: '_enter_fecha_',
        titulo: (_) => app.tituloComX('Estorno de NFS-e'),
        largura: 580,
        alinhamentoAcoes: MainAxisAlignment.center,
        conteudo: (_) => col(
          [
            lin([
              Icon(
                ok ? Icons.check_circle : Icons.error,
                color: ok ? Colors.green.shade600 : Colors.red.shade600,
              ),
              Expanded(
                child: Tx(
                  mensagem,
                  peso: FontWeight.bold,
                  largura: TamanhosConsultar.rotuloMensagem.largura,
                  altura: TamanhosConsultar.rotuloMensagem.altura,
                  idLayout: 'TamanhosConsultar.rotuloMensagem',
                ),
              ),
              if (resposta != null)
                Botao.contorno(
                  null,
                  filho: lin(
                    [
                      const Icon(Icons.receipt_long, size: 14),
                      Tx(
                        'Resposta da Sefin',
                        tam: Letra.apoio,
                        largura:
                            TamanhosConsultar.rotuloRespostaDaSefin.largura,
                        altura: TamanhosConsultar.rotuloRespostaDaSefin.altura,
                        idLayout: 'TamanhosConsultar.rotuloRespostaDaSefin',
                      ),
                    ],
                    espaco: 4,
                    justa: true,
                    idLayout: 'Grupo.consultar.lin.5',
                  ),
                  altura: TamanhosConsultar.botaoNull.altura,
                  dica: 'Ver a resposta completa da Sefin',
                  aoClicar: () => _abrirRespostaSefin(resposta!),
                  largura: TamanhosConsultar.botaoNull.largura,
                  idLayout: 'TamanhosConsultar.botaoNull',
                ),
            ], idLayout: 'Grupo.consultar.lin.4'),
          ],
          justa: true,
          idLayout: 'Grupo.consultar.col.10',
        ),
        acoes: (_) => [
          Botao(
            'OK',
            largura: TamanhosConsultar.botaoOK.largura,
            aoClicar: app.fecharDialogo,
            altura: TamanhosConsultar.botaoOK.altura,
            idLayout: 'TamanhosConsultar.botaoOK',
          ),
        ],
        idLayout: 'Janela.consultar.Dialogo.8',
      ),
    );
  }

  /// Janela com a resposta completa da Sefin (texto selecionável e rolável), POR CIMA da
  /// janela de resultado.
  void _abrirRespostaSefin(String texto) {
    app.mostrarDialogo(
      Dialogo(
        titulo: (_) => app.tituloComX('Resposta da Sefin'),
        largura: 640,
        conteudo: (_) => col(
          [
            Tx(
              texto.length > 8000 ? texto.substring(0, 8000) : texto,
              selecionavel: true,
              tam: Letra.codigo,
              fonte: 'Consolas',
              largura: TamanhosConsultar
                  .rotuloTextoLength8000TextoSubstring08000Texto
                  .largura,
              altura: TamanhosConsultar
                  .rotuloTextoLength8000TextoSubstring08000Texto
                  .altura,
              idLayout:
                  'TamanhosConsultar.rotuloTextoLength8000TextoSubstring08000Texto',
            ),
          ],
          rolar: true,
          altura: 380,
          idLayout: 'Grupo.consultar.col.11',
        ),
        idLayout: 'Janela.consultar.Dialogo.9',
      ),
    );
  }

  // ---- desenho ------------------------------------------------------------------------------- //
  Widget _celula(int i, String valor, {Color? cor, String? propria}) => Ct(
    largura: _larguras[i],
    alinhar: (i == 3 && valor == '—') || _centradas.contains(i)
        ? Alignment.center
        : (_aDireita.contains(i)
              ? Alignment.centerRight
              : Alignment.centerLeft),
    child: TxCorte(
      valor,
      largura: _larguras[i],
      solto: true,
      cor: cor,
      propria: propria,
    ),
  );

  PopupMenuItem<String> _item(
    String rotulo,
    IconData icone,
    Color cor,
    VoidCallback aoClicar,
  ) => PopupMenuItem<String>(
    value: rotulo,
    height: 48,
    mouseCursor: SystemMouseCursors.click,
    onTap: aoClicar,
    child: lin(
      [
        Icon(icone, size: 18, color: cor),
        Tx(
          rotulo,
          cor: cor,
          largura: TamanhosConsultar.rotuloRotulo.largura,
          altura: TamanhosConsultar.rotuloRotulo.altura,
          idLayout: 'TamanhosConsultar.rotuloRotulo:$rotulo',
        ),
      ],
      justa: true,
      idLayout: 'Grupo.consultar.lin.6',
    ),
  );

  /// Item "Enviar por e-mail" do menu "mais…". Quando o envio está desabilitado para o
  /// ambiente da nota, fica apagado, sem clique/mãozinha e com um risco no ícone.
  PopupMenuItem<String> _itemEmail(bool habilitado, VoidCallback aoClicar) {
    if (habilitado) {
      return PopupMenuItem<String>(
        value: 'email',
        height: 48,
        mouseCursor: SystemMouseCursors.click,
        onTap: aoClicar,
        child: lin(
          [
            const Icon(Icons.email_outlined, size: 18),
            Tx(
              'Enviar por e-mail',
              largura: TamanhosConsultar.rotuloEnviarPorEMail.largura,
              altura: TamanhosConsultar.rotuloEnviarPorEMail.altura,
              idLayout: 'TamanhosConsultar.rotuloEnviarPorEMail',
            ),
          ],
          justa: true,
          idLayout: 'Grupo.consultar.lin.7',
        ),
      );
    }
    return PopupMenuItem<String>(
      value: 'email_off',
      height: 48,
      enabled: false,
      mouseCursor: SystemMouseCursors.basic,
      child: lin(
        [
          SizedBox(
            width: 22,
            height: 18,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.email_outlined,
                  size: 18,
                  color: Colors.grey.shade400,
                ),
                Transform.rotate(
                  angle: -0.7854,
                  child: Ct(largura: 22, altura: 2, cor: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          Tx(
            'Enviar por e-mail',
            cor: Colors.grey.shade500,
            largura: TamanhosConsultar.rotuloEnviarPorEMail2.largura,
            altura: TamanhosConsultar.rotuloEnviarPorEMail2.altura,
            idLayout: 'TamanhosConsultar.rotuloEnviarPorEMail2',
          ),
        ],
        justa: true,
        idLayout: 'Grupo.consultar.lin.8',
      ),
    );
  }

  Widget _menuMais(List<PopupMenuEntry<String>> itens) => MenuMais(() => itens);

  DataRow _linhaPendente(Map<String, dynamic> p, LocalKey chave) {
    String s(String k) => (p[k] as String?) ?? '';
    // chave preenchida: a SEFIN JÁ aceitou esta nota — o reenvio só conclui o download.
    final aceita = s('chave').trim().isNotEmpty;
    final substituicao = s('subst_chave').isNotEmpty;
    return DataRow(
      // A chave é da POSIÇÃO, não do registro: trocar de página, filtrar ou ordenar atualiza
      // as linhas que já estão montadas em vez de desmontar todas e montar outras.
      key: chave,
      color: hoverPendente, // linha inteira laranja (+ hover mais forte)
      // Sempre "interativa" (é o que dá o realce do mouse): com uma janela aberta por cima o
      // mouse não chega aqui, e manter a linha com a MESMA estrutura evita desmontar e montar
      // de novo todas as células a cada janela que abre ou fecha.
      onSelectChanged: (_) {},
      // O conteúdo da linha fica montado enquanto a lista lida for a mesma.
      cells: _celulasPendentes.da(
        [_pendentes],
        p,
        () => [
          DataCell(
            _celula(
              0,
              _ou(s('n_dps'), '—'),
              propria:
                  'Número da DPS — a NFS-e (nº e chave) sai quando o envio for aceito',
            ),
          ),
          DataCell(_celula(1, _ou(s('tomador_nome'), _ou(s('tomador'), '—')))),
          DataCell(_celula(2, formatarDocumento(s('tomador')))),
          DataCell(_celula(3, _ou(s('grupo'), '—'))),
          DataCell(_celula(4, dataHora(s('criado_em')))),
          DataCell(
            _celula(5, ambRotulos[s('tp_amb')] ?? _ou(s('tp_amb'), '?')),
          ),
          DataCell(
            _celula(
              6,
              aceita ? 'ACEITA — falta o XML' : 'PENDENTE',
              cor: Colors.orange.shade800,
              propria: aceita
                  ? 'NFS-e já autorizada pela SEFIN (chave ${s('chave')})'
                  : null,
            ),
          ),
          DataCell(_celula(7, moedaBr(s('valor')))),
          DataCell(_celula(8, '—')),
          DataCell(
            Ct(
              largura: _larguraAcoes,
              alinhar: Alignment.centerLeft,
              child: lin(
                [
                  BotaoIcone(
                    Icons.send,
                    cor: Colors.orange.shade800,
                    dica: aceita
                        ? 'Concluir download (nota já aceita)'
                        : substituicao
                        ? 'Conferir na SEFIN e reenviar se a DPS não for localizada'
                        : 'Reenviar agora',
                    aoClicar: () => _reenviarUm(p),
                    largura: TamanhosConsultar
                        .botaoAceitaConcluirDownloadNotaJaAceitaReenviarAgora
                        .largura,
                    altura: TamanhosConsultar
                        .botaoAceitaConcluirDownloadNotaJaAceitaReenviarAgora
                        .altura,
                    idLayout:
                        'TamanhosConsultar.botaoAceitaConcluirDownloadNotaJaAceitaReenviarAgora',
                  ),
                  BotaoIcone(
                    Icons.download_for_offline,
                    dica: 'Baixar DPS (XML assinado)',
                    aoClicar: () => _baixarDps(p),
                    largura:
                        TamanhosConsultar.botaoBaixarDPSXMLAssinado.largura,
                    altura: TamanhosConsultar.botaoBaixarDPSXMLAssinado.altura,
                    idLayout: 'TamanhosConsultar.botaoBaixarDPSXMLAssinado',
                  ),
                  // A DPS da substituição fica na fila enquanto ainda pode ter sido aceita.
                  if (!aceita && !substituicao)
                    _menuMais([
                      _item(
                        'Cancelar envio (tira da fila)',
                        Icons.cancel_outlined,
                        Colors.red.shade700,
                        () => app.exigirPermissao(
                          'consultar.cancelar_pendente',
                          () => _cancelarPendente(p),
                          titulo: 'Cancelar envio pendente nº ${s('n_dps')}',
                        ),
                      ),
                    ]),
                ],
                espaco: 0,
                idLayout: 'Grupo.consultar.lin.9',
              ),
            ),
          ),
        ],
      ),
    );
  }

  DataRow _linhaNota(
    Map<String, dynamic> r,
    (Color, Color)? corPar,
    Map<String, dynamic> emailCfg,
    LocalKey chave,
  ) {
    String s(String k) => (r[k] as String?) ?? '';
    final codigo = _ou(s('tpAmb'), s('ambGer'));
    // HOMOLOGAÇÃO: todos os textos da linha em vermelho (destaque de que não é nota real).
    final homolog = codigo == ambHomologacao;
    final cor = homolog ? Colors.red.shade700 : null;
    final substPor = s('subst_por');
    final cancelada = r['cancelada'] == true;
    final numero = _ou(s('nNFSe'), '—');
    // Substituída tem prioridade sobre cancelada (a SEFIN cancela POR substituição).
    final status = substPor.isNotEmpty
        ? 'SUBST.'
        : (cancelada ? 'CANCELADA' : _ou(s('cStat'), '—'));
    final corStatus = substPor.isNotEmpty
        ? Colors.orange.shade800
        : ((cancelada || homolog) ? Colors.red.shade700 : null);
    final rotulo = 'NFS-e nº ${_ou(s('nNFSe'), '?')} (${s('ambiente_label')})';
    return DataRow(
      key: chave, // da posição, como nas pendentes
      // Linha pintada com a cor do PAR antiga↔substituta, ou o realce padrão.
      color: corPar != null ? corLinha(corPar.$1, corPar.$2) : hoverPadrao,
      // Sempre "interativa" (é o que dá o realce do mouse): com uma janela aberta por cima o
      // mouse não chega aqui, e manter a linha com a MESMA estrutura evita desmontar e montar
      // de novo todas as células a cada janela que abre ou fecha.
      onSelectChanged: (_) {},
      // O conteúdo da linha só depende da nota e da configuração de e-mail: fica montado
      // enquanto as duas forem as mesmas.
      cells: _celulasNotas.da(
        [_notas, emailCfg],
        r,
        () => [
          DataCell(_celula(0, numero, cor: cor)),
          DataCell(
            _celula(
              1,
              _ou(s('tomador_nome'), _ou(s('tomador'), '—')),
              cor: cor,
            ),
          ),
          DataCell(_celula(2, formatarDocumento(s('tomador')), cor: cor)),
          DataCell(_celula(3, _ou(s('grupo'), '—'), cor: cor)),
          DataCell(
            _celula(
              4,
              switch (_ddBasePeriodo.valor) {
                'competencia' => dataIsoParaBr(s('dCompet')),
                'movimento' => dataHora(s('movimento')),
                _ => dataHora(s('dhProc')),
              },
              cor: cor,
            ),
          ),
          DataCell(_celula(5, s('ambiente_label'), cor: cor)),
          DataCell(
            _celula(
              6,
              status,
              cor: corStatus,
              propria: substPor.isNotEmpty
                  ? 'SUBSTITUÍDA pela NFS-e de chave $substPor'
                  : null,
            ),
          ),
          DataCell(_celula(7, moedaBr(s('vServ')), cor: cor)),
          DataCell(_celula(8, moedaBr(s('vLiq')), cor: cor)),
          DataCell(
            Ct(
              largura: _larguraAcoes,
              alinhar: Alignment.centerLeft,
              child: lin(
                [
                  BotaoIcone(
                    Icons.download_for_offline,
                    dica: 'Baixar XML',
                    aoClicar: () => _baixarXml(r),
                    largura: TamanhosConsultar.botaoBaixarXML.largura,
                    altura: TamanhosConsultar.botaoBaixarXML.altura,
                    idLayout: 'TamanhosConsultar.botaoBaixarXML',
                  ),
                  // A DANFSe é gerada na hora, do XML guardado.
                  BotaoIcone(
                    Icons.picture_as_pdf,
                    cor: Colors.red.shade700,
                    dica: 'Abrir DANFSe (PDF)',
                    aoClicar: () =>
                        abrirDanfse(app, s('chave'), rotulo: rotulo),
                    largura: TamanhosConsultar.botaoAbrirDANFSePDF.largura,
                    altura: TamanhosConsultar.botaoAbrirDANFSePDF.altura,
                    idLayout: 'TamanhosConsultar.botaoAbrirDANFSePDF',
                  ),
                  // Menu "mais…": e-mail (apagado se desabilitado para o ambiente da nota) +
                  // substituição + estorno (os dois últimos só para notas vivas).
                  _menuMais([
                    _itemEmail(
                      emailAtivoPara(emailCfg, codigo),
                      () => enviarNfseEmail(
                        app,
                        tomador: s('tomador'),
                        chave: s('chave'),
                        ambiente: codigo,
                        rotulo: rotulo,
                      ),
                    ),
                    if (!cancelada && substPor.isEmpty) ...[
                      _item(
                        'Substituir NFS-e',
                        Icons.swap_horiz,
                        Colors.orange.shade800,
                        () => app.exigirPermissao(
                          'consultar.substituir',
                          () => app.exigirPermissao('emitir', () {
                            // A tela de emissão pode estar desmontada até receber a autorização.
                            app.atualizar();
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (app.viva) EmitirState.atual?.substituir(r);
                            });
                          }),
                          titulo: 'Substituir NFS-e nº $numero',
                        ),
                      ),
                      _item(
                        'Estornar (cancelar) NFS-e',
                        Icons.cancel_outlined,
                        Colors.red.shade700,
                        () => app.exigirPermissao(
                          'consultar.estornar',
                          () => _estornar(r),
                          titulo: 'Estornar NFS-e nº $numero',
                        ),
                      ),
                    ],
                  ]),
                ],
                espaco: 0,
                idLayout: 'Grupo.consultar.lin.10',
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _ordenar(int coluna, bool crescente) {
    _ordem = (coluna, crescente);
    _pagina = 0;
    if (app.prestador.isNotEmpty) carregarPagina();
  }

  /// A tabela (a parte cara da tela) com as linhas de [primeira] a [ultima].
  DataTable _montarTabela(
    bool inerte,
    Map<String, dynamic> emailCfg,
    int primeira,
    int ultima,
    LocalKey Function(int) chave,
  ) {
    // Cores por PAR de substituição: antiga e substituta compartilham a mesma cor; cada par
    // da página ganha a próxima cor da paleta. Cadeias (A→B→C) colapsam num grupo só.
    final chavesNovas = _pares.values.toSet();
    final coresDaPagina = <String, (Color, Color)>{};
    (Color, Color)? corDoPar(Map<String, dynamic> r) {
      final substPor = (r['subst_por'] as String?) ?? '';
      final chave = (r['chave'] as String?) ?? '';
      var id = (substPor.isNotEmpty && substPor != '?')
          ? substPor
          : (chavesNovas.contains(chave) ? chave : '');
      if (id.isEmpty) return null;
      final visto = <String>{};
      while (_pares.containsKey(id) && !visto.contains(id)) {
        visto.add(id);
        id = _pares[id]!;
      }
      return coresDaPagina.putIfAbsent(
        id,
        () => coresDePar[coresDaPagina.length % coresDePar.length],
      );
    }

    DataColumn coluna(
      String rotulo, {
      bool numerica = false,
      bool ordenavel = true,
    }) => DataColumn(
      label: Tx(
        rotulo,
        linhas: 1,
        semQuebra: true,
        tema: (rotulo == 'vServ' || rotulo == 'vLíq')
            ? (t) => t.titleSmall?.copyWith(letterSpacing: -0.2)
            : null,
        largura: TamanhosConsultar.rotuloRotulo2.largura,
        altura: TamanhosConsultar.rotuloRotulo2.altura,
        idLayout: 'TamanhosConsultar.rotuloRotulo2:$rotulo',
      ),
      numeric: numerica,
      // cabeçalhos centralizados na largura da coluna
      headingRowAlignment: switch (ajusteLayout(
        context,
        'TamanhosConsultar.rotuloRotulo2:$rotulo',
      ).alinhamento) {
        TextAlign.left || TextAlign.start => MainAxisAlignment.start,
        TextAlign.right || TextAlign.end => MainAxisAlignment.end,
        _ => MainAxisAlignment.center,
      },
      mouseCursor: ordenavel && !inerte
          ? WidgetStateMouseCursor.clickable
          : const WidgetStatePropertyAll(SystemMouseCursors.basic),
      onSort: (ordenavel && !inerte) ? _ordenar : null,
    );

    // As cores saem na ordem das linhas da página INTEIRA, estejam elas montadas ou não.
    final cores = [for (final r in _notas) corDoPar(r)];
    final pendentes = _pendentes.length;
    return TabelaPadrao(
      showCheckboxColumn: false,
      headingRowHeight: _alturaCabecalho,
      dataRowMinHeight: _alturaLinha,
      dataRowMaxHeight: _alturaLinha,
      columnSpacing: 14,
      sortColumnIndex: _ordem?.$1,
      sortAscending: _ordem?.$2 ?? false,
      columns: [
        coluna('NFS-e'),
        coluna('Cliente'),
        coluna('Documento'),
        coluna('Grupo'),
        coluna(
          switch (_ddBasePeriodo.valor) {
            'competencia' => 'Competência',
            'movimento' => 'Movimento',
            _ => 'Processada em',
          },
        ),
        coluna('Ambiente'),
        coluna('Status'),
        coluna('vServ', numerica: true),
        coluna('vLíq', numerica: true),
        coluna('Ações', ordenavel: false),
      ],
      rows: [
        for (var i = primeira; i <= ultima; i++)
          i < pendentes
              ? _linhaPendente(_pendentes[i], chave(i))
              : _linhaNota(
                  _notas[i - pendentes],
                  cores[i - pendentes],
                  emailCfg,
                  chave(i),
                ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final inerte = travado(context);
    final paginas = _paginas;
    final emailCfg = configEmail(app);
    final tabela = TabelaCabecalhoFixo(
      espacoAntesAcoes: 20,
      larguras: [..._larguras, _larguraAcoes],
      quantidade: _pendentes.length + _notas.length,
      alturaLinha: _alturaLinha,
      alturaCabecalho: _alturaCabecalho,
      entradas: [_pendentes, _notas, _pares, inerte, emailCfg, _ordem],
      montar: (primeira, ultima, chave) =>
          _montarTabela(inerte, emailCfg, primeira, ultima, chave),
    );

    return col(
      [
        lin([
          Tx(
            'Consultar NFS-e emitidas',
            tam: Letra.titulo,
            peso: FontWeight.bold,
            largura: TamanhosConsultar.rotuloConsultarNFSEEmitidas.largura,
            altura: TamanhosConsultar.rotuloConsultarNFSEEmitidas.altura,
            idLayout: 'TamanhosConsultar.rotuloConsultarNFSEEmitidas',
          ),
          const Expanded(child: SizedBox()),
          BotaoIcone(
            Icons.download,
            dica: 'Exportar dados',
            aoClicar: _abrirExportar,
            largura: TamanhosConsultar.botaoExportarDados.largura,
            altura: TamanhosConsultar.botaoExportarDados.altura,
            idLayout: 'TamanhosConsultar.botaoExportarDados',
          ),
        ], idLayout: 'Grupo.consultar.lin.11'),
        if (_pendN > 0 && app.temPermissao('consultar.pesquisar'))
          Ct(
            cor: Colors.orange.shade50,
            raio: BorderRadius.circular(8),
            borda: Border.all(color: Colors.orange.shade300, width: 1),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: lin([
              Icon(Icons.schedule_send, color: Colors.orange.shade800),
              Tx(
                'Existem NFS-e pendentes de envio: $_pendN pendente(s)',
                peso: FontWeight.w600,
                cor: Colors.orange.shade900,
                largura: TamanhosConsultar
                    .rotuloExistemNFSEPendentesDeEnvioPendNPendente
                    .largura,
                altura: TamanhosConsultar
                    .rotuloExistemNFSEPendentesDeEnvioPendNPendente
                    .altura,
                idLayout:
                    'TamanhosConsultar.rotuloExistemNFSEPendentesDeEnvioPendNPendente',
              ),
              const Expanded(child: SizedBox()),
              ValueListenableBuilder<String>(
                valueListenable: _pendContagem,
                builder: (context, texto, _) => Tx(
                  texto,
                  tam: Letra.apoio,
                  cor: Colors.orange.shade900,
                  largura: TamanhosConsultar.rotuloTexto2.largura,
                  altura: TamanhosConsultar.rotuloTexto2.altura,
                  idLayout: 'TamanhosConsultar.rotuloTexto2',
                ),
              ),
              Botao(
                'Reenviar agora',
                icone: Icons.send,
                cor: Colors.white,
                fundo: Colors.orange.shade800,
                aoClicar: _reenviarTodas,
                largura: TamanhosConsultar.botaoReenviarAgora.largura,
                altura: TamanhosConsultar.botaoReenviarAgora.altura,
                idLayout: 'TamanhosConsultar.botaoReenviarAgora',
              ),
            ], idLayout: 'Grupo.consultar.lin.12'),
          ),
        if (!app.temPermissao('consultar.pesquisar'))
          Expanded(
            child: AcessoRestrito(
              aoAutorizar: () =>
                  app.exigirPermissao('consultar.pesquisar', carregarPagina),
            ),
          )
        else ...[
          lin(
            [
              CampoTexto(
                controle: _busca,
                rotulo: rotuloDaBusca,
                largura: TamanhosConsultar.campoRotuloDaBusca.largura,
                iconePrefixo: const Icon(Icons.search),
                aoMudar: (_) => _aoVivo.tecla(() {
                  // Só recarrega se ainda estivermos na Consulta.
                  if (app.navAtual != 2 || app.prestador.isEmpty) return;
                  _pagina = 0;
                  carregarPagina();
                }, viva: () => app.viva && mounted),
                altura: TamanhosConsultar.campoRotuloDaBusca.altura,
                idLayout: 'TamanhosConsultar.campoRotuloDaBusca',
              ),
              ListaSuspensa(
                estado: _ddBasePeriodo,
                rotulo: 'Data',
                largura: 152,
                aoSelecionar: (_) => _aplicarFiltro(),
                idLayout: 'Consultar.filtrarPor',
              ),
              ListaSuspensa(
                estado: _ddPeriodo,
                rotulo: 'Período',
                largura:
                    TamanhosConsultar.campoPeriodo2.largura ??
                    (_larguraPeriodo),
                aoSelecionar: _aoPeriodo,
                altura: TamanhosConsultar.campoPeriodo2.altura,
                idLayout: 'TamanhosConsultar.campoPeriodo2',
              ),
              ListaSuspensa(
                estado: _ddAmbiente,
                rotulo: 'Ambiente',
                largura: TamanhosConsultar.campoAmbiente2.largura!,
                aoSelecionar: _aoAmbiente,
                altura: TamanhosConsultar.campoAmbiente2.altura,
                idLayout: 'TamanhosConsultar.campoAmbiente2',
              ),
              ListaSuspensa(
                estado: _ddEmpresa,
                rotulo: 'Empresa',
                largura: TamanhosConsultar.campoEmpresa.largura!,
                larguraMenu: 420,
                desabilitado: !_temClientes,
                aoSelecionar: _aoEmpresa,
                altura: TamanhosConsultar.campoEmpresa.altura,
                idLayout: 'TamanhosConsultar.campoEmpresa',
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.consultar.lin.13',
          ),
          Tx(
            _vazio,
            italico: true,
            cor: Colors.grey.shade600,
            largura: TamanhosConsultar.rotuloVazio.largura,
            altura: TamanhosConsultar.rotuloVazio.altura,
            idLayout: 'TamanhosConsultar.rotuloVazio',
          ),
          // Rolagem nas duas direções com a barra HORIZONTAL fixa no rodapé VISÍVEL.
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: AbsorbPointer(absorbing: _carregando, child: tabela),
                ),
                if (_carregando)
                  const Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
          divisor(altura: 1),
          BarraPaginacao(
            pagina: _pagina,
            paginas: paginas,
            porPagina: _porPagina,
            controleIr: _irPara,
            rotulo: _carregadoPrest == null ? '' : null,
            aoIr: (p) {
              _pagina = p;
              carregarPagina();
            },
            aoPorPagina: (n) {
              if (n == _porPagina) return;
              _porPagina = n;
              _pagina = 0;
              if (app.prestador.isNotEmpty) carregarPagina();
              _redesenhar();
            },
          ),
        ],
      ],
      espaco: 14,
      idLayout: 'Grupo.consultar.col.12',
    );
  }
}

/// Abre a DANFSe da nota. O PDF não é guardado: é gerado na hora, sem rede, a partir do XML
/// autorizado que está no banco de notas (já com a marca d'água de cancelada/substituída
/// quando for o caso), num arquivo temporário. [rotulo] identifica a nota no Registro.
void abrirDanfse(App app, String chave, {String rotulo = ''}) {
  if (!app.temPermissao('consultar.pdf')) {
    app.exigirPermissao(
      'consultar.pdf',
      () => abrirDanfse(app, chave, rotulo: rotulo),
    );
    return;
  }
  final nome = rotulo.isEmpty
      ? 'NFS-e de chave …${chave.length > 8 ? chave.substring(chave.length - 8) : chave}'
      : rotulo;
  final prest = app.prestador;
  app.emSegundoPlano(() async {
    String pdf;
    try {
      pdf = await chamar<String>('cofre.gerar_danfse', {
        'origem': 'consultar',
        'dono': prest,
        'chave': chave,
      });
    } catch (e) {
      final id = notaComXmlIlegivel(e);
      if (id != null && app.viva) {
        oferecerRebusca(
          app,
          dono: prest,
          notaId: id,
          rotulo: nome,
          aoRecuperar: () => abrirDanfse(app, chave, rotulo: rotulo),
        );
        return;
      }
      app.toast('Não foi possível gerar a DANFSe da $nome: $e', erro: true);
      return;
    }
    abrirCaminho(app, pdf);
  });
}
