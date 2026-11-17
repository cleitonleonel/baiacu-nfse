/// Tela COFRE: todas as NFS-e do prestador, emitidas e recebidas, guardadas no banco de
/// notas; a sincronização com o ADN (manual e automática) e a exportação. A DANFSe não é
/// guardada: é gerada na hora, a partir do XML.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../editor_layout.dart';

import '../app/app.dart';
import '../app/sistema.dart';
import '../kit/arquivos.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/formatos.dart';
import '../kit/tabela.dart';
import 'consultar.dart';
import 'emitir.dart' show todos;
import 'periodo.dart';

const papelEmitida = 'E';
const papelRecebida = 'R';

const _opcoesTipo = [
  Opcao(todos, 'Todas'),
  Opcao(papelEmitida, 'Emitidas'),
  Opcao(papelRecebida, 'Recebidas'),
];
const _opcoesSituacao = [
  Opcao(todos, 'Todas'),
  Opcao('ativas', 'Ativas'),
  Opcao('canceladas', 'Canceladas'),
];

List<Opcao> _opcoesPeriodoCofre([String intervalo = '']) => [
  const Opcao('tudo', 'Todo o período'),
  ...opcoesDePeriodo(intervalo),
];

String intervaloTexto(int minutos) => minutos < 60
    ? '$minutos min'
    : (minutos == 60 ? '1 hora' : '${minutos ~/ 60} horas');

/// Frase com o que uma sincronização (um ou vários alvos) trouxe.
String resumoDaSincronizacao(Map tot) {
  final partes = ['${tot['novas']} nota(s) nova(s)'];
  if ((tot['novas'] as num) > 0) {
    partes.add(
      '${tot['emitidas']} emitida(s) e ${tot['recebidas']} recebida(s)',
    );
  }
  if ((tot['eventos'] as num) > 0) partes.add('${tot['eventos']} evento(s)');
  if ((tot['quarentena'] as num) > 0) {
    partes.add('${tot['quarentena']} documento(s) ilegível(is) em quarentena');
  }
  return '${partes.join(', ')}.';
}

class TelaCofre extends StatefulWidget {
  const TelaCofre({super.key, required this.app});
  final App app;

  @override
  State<TelaCofre> createState() => CofreState();
}

class CofreState extends State<TelaCofre> with TelaGuardada<TelaCofre> {
  @override
  App get app => widget.app;

  @override
  int get indiceDaTela => 4;

  // Colunas: 0 Tipo, 1 NFS-e, 2 Emitente/Tomador, 3 CNPJ/CPF (da outra parte), 4 Processada,
  // 5 Ambiente, 6 Status, 7 vServ, 8 vLíq.
  static const _larguras = [
    62.0,
    70.0,
    360.0,
    110.0,
    132.0,
    96.0,
    84.0,
    80.0,
    80.0,
  ];
  static const _larguraAcoes = 3 * Medida.botaoDaLinha;
  static const _alturaLinha = Medida.linhaDaTabela;
  static const _centradas = {0, 5, 6};
  static const _aDireita = {7, 8};
  static const _ordens = [
    'tipo',
    'numero',
    'nome',
    'doc',
    'data',
    'amb',
    'status',
    'vserv',
    'vliq',
  ];
  static const _larguraPeriodo = 200.0;
  static const _dicaSinc =
      'Buscar no ADN as notas emitidas e recebidas que ainda não estão aqui';

  int _pagina = 0;
  int _porPagina = 25;
  int _total = 0;
  (int, bool)? _ordem;
  String? _carregadoPrest;
  List<Map<String, dynamic>> _notas = const [];
  Map<String, String> _gruposClientes = {};
  String _vazio = '';
  bool _vazioErro = false;
  DateTime? _de;
  DateTime? _ate;
  String _periodoAnt = 'tudo'; // último período CONFIRMADO

  final _busca = TextEditingController();
  final _irPara = TextEditingController();
  final _ddTipo = Suspensa(valor: todos, opcoes: _opcoesTipo)..por(todos);
  final _ddBasePeriodo = Suspensa(valor: 'emissao', opcoes: opcoesBasePeriodo);

  final _ddPeriodo = Suspensa(valor: 'tudo', opcoes: _opcoesPeriodoCofre())
    ..por('tudo');
  final _ddAmbiente = Suspensa(valor: 'todos', opcoes: opcoesDeAmbiente)
    ..por('todos');
  final _ddSituacao = Suspensa(valor: todos, opcoes: _opcoesSituacao)
    ..por(todos);
  final _aoVivo = BuscaAoVivo();
  final _celulas = CelulasProntas();
  static const _alturaCabecalho = Medida.cabecalhoDaTabela;

  // ---- sincronização com o ADN --------------------------------------------------------------- //
  bool _sincAtiva = false;
  bool _sincCancelando = false;
  String _fichaSinc = '';
  String _textoSinc = '';
  final _giro = Giro(meiaVolta: true);

  // ---- manutenção do banco de notas + sincronização automática ------------------------------ //
  static const _esperaInicial = Duration(seconds: 45); // depois do login
  static const _passo = Duration(
    seconds: 20,
  ); // de quanto em quanto se confere se é hora
  static const _repetirMin = [5, 10, 20, 40]; // sem internet: novas tentativas
  Timer? _autoTimer;
  bool _autoCuidou = false;
  bool _autoRodando = false;
  String _fichaAuto = '';
  final Set<String> _autoAvisados = {};

  @override
  void initState() {
    super.initState();
    app.aoEntrar[4] = _entrar;
    app.aoTrocarPrestador.add(_aoTrocarPrestador);
    app.aoMudarNotas.add(_aoMudarNotas);
    app.aoPararTimers.add(_pararTudo);
    app.aoAtualizar(_redesenhar);
    app.cofreSincronizando = () => _sincAtiva || _autoRodando;
    app.cofreCancelarSinc = _cancelarFichas;
    app.cofreProxima = _autoProxima;
    app.cofreAtualizarSituacao = _atualizarSituacao;
    app.cofreCuidar = _cuidar;
    // Cofre: manutenção do banco de notas e, se ligada, a sincronização automática.
    if (!app.semPrestador) _iniciarAutomatica();
  }

  void _redesenhar() => redesenhar();

  void _aoMudarNotas() {
    _consultaAtual++;
    _carregando = false;
    _carregadoPrest = null;
  }

  void _aoTrocarPrestador() {
    _consultaAtual++;
    _carregando = false;
    // busca e página são do prestador anterior; a lista recarrega ao entrar
    _busca.text = '';
    _pagina = 0;
    _carregadoPrest = null;
  }

  void _cancelarFichas() {
    for (final f in [_fichaSinc, _fichaAuto]) {
      if (f.isNotEmpty) {
        try {
          chamar<Object?>('nucleo.cancelar', {'ficha': f}).catchError((
            Object e,
          ) {
            debugPrint('Falha ao cancelar: $e');
            return null;
          });
        } catch (_) {}
      }
    }
  }

  void _pararTudo() {
    _consultaAtual++;
    _carregando = false;
    _aoVivo.cancelar();
    _autoTimer?.cancel();
    _autoTimer = null;
    _cancelarFichas(); // sincronização (manual ou automática): para no próximo passo
  }

  @override
  void dispose() {
    _aoVivo.cancelar();
    _autoTimer?.cancel();
    _giro.dispose();
    app.semAtualizar(_redesenhar);
    app.aoTrocarPrestador.remove(_aoTrocarPrestador);
    app.aoMudarNotas.remove(_aoMudarNotas);
    app.aoPararTimers.remove(_pararTudo);
    _ddBasePeriodo.dispose();
    super.dispose();
  }

  // ---- entrar na tela, filtros, ordenação, paginação ------------------------------------------ //
  /// A lista só é recarregada quando o prestador mudou (ou na 1ª vez) ou quando uma nota foi
  /// emitida/cancelada desde então.
  void _entrar() {
    if (_carregadoPrest != app.prestador) {
      _pagina = 0;
      carregarPagina();
    }
    _atualizarSituacao();
  }

  static String _ou(Object? v, String padrao) {
    final s = v?.toString() ?? '';
    return s.isEmpty ? padrao : s;
  }

  /// O filtro em uso: papel, ambiente, datas, busca, situação e ordem.
  ({
    String papel,
    String amb,
    DateTime? ini,
    DateTime? fim,
    String termo,
    String situacao,
    List<Object>? ordem,
  })
  filtro() {
    var (ini, fim) = datasDoPeriodo(_periodoAnt, _de, _ate);
    if (_periodoAnt == 'tudo') {
      ini = null;
      fim = null;
    }
    final tipo = _ddTipo.valor;
    final amb = _ddAmbiente.valor;
    final sit = _ddSituacao.valor;
    final o = _ordem;
    return (
      papel: (tipo == null || tipo.isEmpty || tipo == todos) ? '' : tipo,
      amb: ambRotulos.containsKey(amb) ? amb! : '',
      ini: ini,
      fim: fim,
      termo: _busca.text.trim(),
      situacao: (sit == null || sit.isEmpty || sit == todos) ? '' : sit,
      ordem: o == null ? null : [_ordens[o.$1], o.$2],
    );
  }

  bool get _temFiltro {
    final f = filtro();
    return f.papel.isNotEmpty ||
        f.amb.isNotEmpty ||
        f.ini != null ||
        f.fim != null ||
        f.termo.isNotEmpty ||
        f.situacao.isNotEmpty;
  }

  /// Consulta o banco de notas e mostra a página atual.
  int _consultaAtual = 0;
  bool _carregando = false;
  Future<void> carregarPagina() async {
    if (!app.temPermissao('cofre.pesquisar')) return;
    final consulta = ++_consultaAtual;
    _carregando = true;
    _redesenhar();
    final prest = app.prestador;
    final f = filtro();
    final porCompetencia = _ddBasePeriodo.valor == 'competencia';
    final porPagina = _porPagina;
    var paginaAtual = _pagina;
    bool atual() =>
        mounted &&
        app.viva &&
        consulta == _consultaAtual &&
        prest == app.prestador;
    var notas = <Map<String, dynamic>>[];
    var total = 0;
    var soma = 0.0;
    var erro = '';
    var grupos = <String, String>{};
    if (prest.isNotEmpty) {
      try {
        final pares = await chamar<List>('cadastro.tomadores_grupos', {
          'prestador': prest,
        });
        if (!atual()) return;
        grupos = {for (final par in pares) par[0] as String: par[1] as String};
        Future<Map> listar() => chamar<Map>('cofre.listar', {
          'por_competencia': porCompetencia,
          'dono': prest,
          'filtro': {
            'grupos': [
              for (final item in grupos.entries) [item.key, item.value],
            ],
            'papel': f.papel,
            'amb': f.amb,
            'ini': dataIso(f.ini),
            'fim': dataIso(f.fim),
            'termo': f.termo,
            'situacao': f.situacao,
            'ordem': f.ordem,
            'limite': porPagina,
            'offset': paginaAtual * porPagina,
          },
        });
        var r = await listar();
        if (!atual()) return;
        total = (r['total'] as num).toInt();
        if ((r['notas'] as List).isEmpty && total > 0 && paginaAtual > 0) {
          paginaAtual = math.max(0, (total / porPagina).ceil() - 1);
          r = await listar();
          if (!atual()) return;
          total = (r['total'] as num).toInt();
        }
        notas = [
          for (final n in r['notas'] as List)
            Map<String, dynamic>.from(n as Map),
        ];
        soma = (r['soma'] as num).toDouble();
      } on ErroNucleo catch (e) {
        if (e.tipo.startsWith('Cofre')) {
          erro = '$e';
        } else {
          registrar('Falha ao consultar o banco de notas: $e', nivel: 'error');
          erro = 'Não foi possível ler o banco de notas: $e';
        }
      } catch (e) {
        registrar('Falha ao consultar o banco de notas: $e', nivel: 'error');
        erro = 'Não foi possível ler o banco de notas: $e';
      }
    }
    if (!atual()) return;
    _carregando = false;
    _carregadoPrest = prest;
    _gruposClientes = grupos;
    _pagina = paginaAtual;
    _total = total;
    _notas = notas;
    _vazioErro = erro.isNotEmpty;
    _vazio = erro.isNotEmpty
        ? erro
        : total > 0
        ? '$total nota(s) · serviços: R\$ ${moedaBr(soma.toStringAsFixed(2))} (sem as canceladas)'
        : (_temFiltro
              ? 'Nenhuma nota com esse filtro.'
              : 'O cofre deste prestador está vazio. Use Sincronizar para buscar no ADN as notas emitidas e recebidas.');
    _redesenhar();
  }

  void _filtroMudou() {
    _pagina = 0;
    carregarPagina();
  }

  // ---- período (a mesma janela da Consulta) ---------------------------------------------------- //
  void _aoPeriodo(String? v) {
    if (v == 'custom') {
      // o filtro só muda quando a janela é confirmada
      abrirPeriodo(
        app,
        _de,
        _ate,
        (de, ate) {
          _de = de;
          _ate = ate;
          _periodoAnt = 'custom';
          _sincronizarPeriodo();
          _filtroMudou();
        },
        () {
          if (_periodoAnt != 'custom') {
            _ddPeriodo.por(_periodoAnt);
            _ddPeriodo.avisar();
          }
        },
      );
      return;
    }
    _periodoAnt = v ?? 'tudo';
    _sincronizarPeriodo();
    _filtroMudou();
  }

  String get _intervalo =>
      _periodoAnt == 'custom' ? textoDoIntervalo(_de, _ate) : '';

  void _sincronizarPeriodo() {
    _ddPeriodo.opcoes = _opcoesPeriodoCofre(_intervalo);
    _ddPeriodo.por(_ddPeriodo.valor);
    _ddPeriodo.avisar();
  }

  // ---- sincronização com o ADN ------------------------------------------------------------------ //
  /// Texto ao lado do botão: quando o ADN foi consultado pela última vez no ambiente em uso.
  /// Não mexe no texto durante uma sincronização (quem manda nele é o andamento).
  void _atualizarSituacao() {
    if (_sincAtiva) return;
    var texto = '';
    if (app.prestador.isNotEmpty) {
      final amb = ambRotulos[app.ambiente] ?? app.ambiente;
      try {
        final r = jaMapa('cofre.resumo', {'dono': app.prestador});
        final cur = (r['cursores'] as Map?)?[app.ambiente] as Map?;
        final quando = (cur?['quando'] as String?) ?? '';
        if (cur != null && quando.isNotEmpty) {
          texto =
              'Última consulta ao ADN ($amb): ${dataHora(quando)}'
              '${cur['em_dia'] == true ? '' : ' — interrompida, falta o resto'}';
        } else {
          texto = 'Ainda não sincronizado com o ADN ($amb).';
        }
        final quarentena = (r['quarentena'] as num?)?.toInt() ?? 0;
        if (quarentena > 0) {
          texto += ' · $quarentena documento(s) ilegível(is) em quarentena';
        }
        if (app.autoCfg['automatica'] == true) {
          texto +=
              ' · automática a cada ${intervaloTexto((app.autoCfg['intervalo'] as num).toInt())}';
        }
      } catch (_) {
        texto = ''; // a lista já mostra o erro do banco
      }
    }
    _textoSinc = texto;
    _redesenhar();
  }

  void _sincUi(bool ativa, [String texto = '']) {
    _sincAtiva = ativa;
    _sincCancelando = false;
    if (ativa) {
      _textoSinc = texto;
      _giro.girar(); // o ícone do botão gira até a sincronização acabar
      _redesenhar();
    } else {
      _giro.parar();
      _atualizarSituacao();
    }
  }

  /// Clique no botão único do Cofre: parado, sincroniza; sincronizando, cancela.
  void _botao() {
    if (_sincAtiva) {
      _cancelarSinc();
    } else {
      _sincronizar();
    }
  }

  void _cancelarSinc() {
    if (_sincCancelando) return; // já está cancelando
    _sincCancelando = true;
    try {
      chamar<Object?>('nucleo.cancelar', {'ficha': _fichaSinc}).catchError((
        Object e,
      ) {
        debugPrint('Falha ao cancelar: $e');
        return null;
      });
    } catch (_) {}
    _textoSinc =
        'Cancelando… o lote em andamento é descartado; os lotes '
        'completos ficam guardados.';
    _redesenhar();
  }

  /// Busca no ADN o que há de novo para o prestador em uso — no ambiente em uso ou em
  /// produção E homologação, conforme as Configurações. Roda em segundo plano; a tela
  /// acompanha os lotes e pode cancelar.
  void _sincronizar() {
    if (!app.temPermissao('cofre.sincronizar')) {
      app.exigirPermissao('cofre.sincronizar', () => _sincronizar());
      return;
    }
    if (_sincAtiva) return; // já está sincronizando
    if (app.prestador.isEmpty) {
      app.toast('Selecione um prestador.', erro: true);
      return;
    }
    final prest = app.prestador;
    final pares = app.paresCofre();
    if (pares.isEmpty) {
      app.toast('Nenhum prestador habilitado para sincronizar.', erro: true);
      return;
    }
    final ambientes = pares.map((p) => p[1] as String).toSet().toList();
    final rot = ambientes.map((a) => ambRotulos[a] ?? a).join(' e ');
    _fichaSinc = 'cofre-${DateTime.now().microsecondsSinceEpoch}';
    // O andamento aparece no texto ao lado do botão e no ícone dele, girando; o aviso vem só
    // no fim, com o resultado.
    _sincUi(true, 'Consultando o ADN ($rot)…');
    var ultimo = DateTime.fromMillisecondsSinceEpoch(0);

    void progresso(Object? a) {
      if (a is! Map) return;
      final agora = DateTime.now();
      // no máximo ~2 atualizações de texto por segundo
      if (a['fase'] != 'espera' &&
          agora.difference(ultimo) < const Duration(milliseconds: 400)) {
        return;
      }
      ultimo = agora;
      var texto = (a['texto'] as String?) ?? '';
      if (a['fase'] == 'adn' && ((a['documentos'] as num?) ?? 0) > 0) {
        texto =
            '${a['documentos']} documento(s) recebido(s), ${a['novas']} nota(s) '
            'nova(s)… (lote ${a['lotes']})';
      }
      if (texto.isNotEmpty && ambientes.length > 1) {
        texto = '${ambRotulos[a['amb']] ?? ''}: $texto';
      }
      if (_sincAtiva && !_sincCancelando && texto.isNotEmpty) {
        _textoSinc = texto;
        _redesenhar();
      }
    }

    app.emSegundoPlano(() async {
      Map<String, dynamic>? tot;
      try {
        tot = Map<String, dynamic>.from(
          await chamar<Map>('cofre.sincronizar_varios', {
            'pares': pares,
            'ficha': _fichaSinc,
          }, progresso),
        );
      } catch (e) {
        registrar('Falha na sincronização do Cofre: $e', nivel: 'error');
        tot = null;
        app.toast('Cofre: falha na sincronização: $e', erro: true);
      }
      // O prestador foi deletado no meio: não há resultado a anunciar.
      if (tot != null &&
          tot['cancelado'] == true &&
          (app.cofreApagando.contains(prest) ||
              !jaLista(
                'cadastro.list_prestadores',
              ).any((p) => p['documento'] == prest))) {
        tot = null;
      }
      if (tot != null) {
        final semRede = (tot['sem_rede'] as String?) ?? '';
        final erros = (tot['erros'] as List?) ?? const [];
        if (semRede.isNotEmpty) {
          app.toast('Cofre: $semRede', erro: true);
        } else if (erros.isNotEmpty) {
          // o mesmo erro nos dois ambientes aparece uma vez só
          final vistos = <String>[];
          for (final e in erros) {
            final m = (e as List)[2] as String;
            if (!vistos.contains(m)) vistos.add(m);
          }
          app.toast('Cofre: ${vistos.join(' ')}', erro: true);
        } else if (((tot['feitos'] as List?) ?? const []).isEmpty &&
            ((tot['recentes'] as num?) ?? 0) > 0) {
          app.toast(
            'Cofre: o ADN foi consultado há menos de 1 minuto e não havia '
            'nada novo. Aguarde um pouco para consultar de novo (limite de '
            'consultas do ADN).',
          );
        } else {
          final fim = tot['cancelado'] == true
              ? ' Sincronização CANCELADA — o lote que estava em andamento foi '
                    'descartado; os lotes completos estão guardados.'
              : (tot['limite'] == true
                    ? ' Ainda há mais no ADN: sincronize de novo para continuar.'
                    : '');
          app.toast('Cofre: ${resumoDaSincronizacao(tot)}$fim');
        }
      }
      await _cuidar(); // confere o banco de notas e refaz a cópia se estiver velha
      _sincUi(false);
      if (app.prestador == prest) carregarPagina();
    });
  }

  /// Manutenção do banco de notas: confere, recupera da cópia de segurança se preciso e
  /// refaz a cópia quando está velha. Só fala com o usuário se houve recuperação ou problema.
  Future<void> _cuidar() async {
    try {
      final m = Map<String, dynamic>.from(
        await chamar<Map>('cofre.manutencao'),
      );
      final avisos = <String>[];
      final aviso = (m['aviso'] as String?) ?? '';
      if (aviso.isNotEmpty) avisos.add(aviso);
      // recuperações feitas ao abrir o banco, fora daqui
      final recuperacoes = await chamar<List>('cofre.recuperacoes');
      if (recuperacoes.isNotEmpty && m['recuperado'] != true) {
        avisos.add(
          'O banco de notas não abria e foi recuperado da cópia de '
          'segurança. Sincronize o Cofre para trazer o que falta.',
        );
      }
      final ditos = <String>{};
      for (final t in avisos) {
        if (ditos.add(t)) app.toast('Cofre: $t', erro: true);
      }
      if (m['recuperado'] == true && app.navAtual == 4) carregarPagina();
    } catch (e) {
      // manutenção nunca derruba quem chamou
      registrar('Falha na manutenção do banco de notas: $e', nivel: 'error');
    }
  }

  void _iniciarAutomatica() {
    app.autoCfg = Map<String, dynamic>.from(ja<Map>('cofre.config'));
    app.autoEstado
      ..['texto'] = ''
      ..['falhas'] = 0
      ..['tentar_em'] = 0.0
      ..['rodando'] = false;
    // Quase sempre dormindo: acorda de tempos em tempos para ver se é hora. Não tem anel
    // nem tela própria — só avisa quando chega nota nova.
    _autoTimer = Timer(_esperaInicial, () {
      _autoTique();
      _autoTimer = Timer.periodic(_passo, (_) => _autoTique());
    });
  }

  /// Época (segundos) da próxima sincronização automática.
  double _autoProxima() {
    final tentar = (app.autoEstado['tentar_em'] as num).toDouble();
    if (tentar > 0)
      return tentar; // sem internet na última: nova tentativa mais cedo
    return (ja<num>('cofre.ultima_automatica')).toDouble() +
        (app.autoCfg['intervalo'] as num) * 60;
  }

  Future<void> _autoTique() async {
    if (!app.temPermissao('cofre.sincronizar', somenteLogado: true)) return;
    if (!app.viva || _autoRodando) return;
    try {
      if (!_autoCuidou) {
        _autoCuidou = true;
        // uma conferência por sessão, mesmo sem automática
        final sit = jaMapa('cofre.situacao_protecao');
        if (ja<bool>('cofre.existe') || ((sit['copia_mb'] as num?) ?? 0) > 0)
          await _cuidar();
      }
      final cfg = app.autoCfg;
      final agoraS = DateTime.now().millisecondsSinceEpoch / 1000;
      if (cfg['automatica'] != true || _sincAtiva || agoraS < _autoProxima())
        return;
      final est = app.autoEstado;
      final pares = app.paresCofre();
      if (pares.isEmpty) return;
      _autoRodando = true;
      est['rodando'] = true;
      _fichaAuto = 'cofre-auto-${DateTime.now().microsecondsSinceEpoch}';
      Map<String, dynamic> tot;
      try {
        tot = Map<String, dynamic>.from(
          await chamar<Map>('cofre.sincronizar_varios', {
            'pares': pares,
            'ficha': _fichaAuto,
          }),
        );
      } finally {
        _autoRodando = false;
        est['rodando'] = false;
      }
      if (!app.viva) return;
      final n = DateTime.now();
      String z(int x) => x.toString().padLeft(2, '0');
      final agora =
          '${z(n.day)}/${z(n.month)}/${n.year} ${z(n.hour)}:${z(n.minute)}';
      final semRede = (tot['sem_rede'] as String?) ?? '';
      if (semRede.isNotEmpty) {
        // Internet/ADN fora: nada foi gravado pela metade. Tenta de novo em 5, 10, 20 e 40
        // min (nunca além do intervalo escolhido) e depois volta ao ritmo normal.
        est['falhas'] = (est['falhas'] as int) + 1;
        final falhas = est['falhas'] as int;
        final espera = math.min(
          (cfg['intervalo'] as num).toInt(),
          _repetirMin[math.min(falhas, _repetirMin.length) - 1],
        );
        est['tentar_em'] =
            DateTime.now().millisecondsSinceEpoch / 1000 + espera * 60;
        est['texto'] =
            '$agora: sem conexão com o ADN. Nova tentativa em ${intervaloTexto(espera)}.';
        registrar('Cofre (automática): $semRede', nivel: 'warning');
        return;
      }
      est['falhas'] = 0;
      est['tentar_em'] = 0.0;
      if (tot['cancelado'] == true) return;
      ja<Object?>('cofre.marcar_automatica');
      final erros = (tot['erros'] as List?) ?? const [];
      final comErro = <String>{};
      for (final e in erros) {
        final (prest, amb, msg) = (
          (e as List)[0] as String,
          e[1] as String,
          e[2] as String,
        );
        comErro.add(prest);
        // uma vez por sessão, só no registro
        if (_autoAvisados.add('$prest|$msg')) {
          registrar(
            'Cofre (automática): ${formatarDocumento(prest)} [${ambRotulos[amb] ?? amb}]: $msg',
            nivel: 'warning',
          );
        }
      }
      est['texto'] =
          '$agora: ${resumoDaSincronizacao(tot)}'
          '${erros.isNotEmpty ? ' ${comErro.length} prestador(es) não pôde(puderam) ser consultado(s) — veja os Registros.' : ''}';
      if (((tot['novas'] as num) + (tot['eventos'] as num)) > 0) {
        app.toast(
          'Cofre (sincronização automática): ${resumoDaSincronizacao(tot)}',
        );
        if (app.navAtual == 4) carregarPagina();
        await _cuidar();
      }
      _atualizarSituacao();
    } catch (e) {
      // a rodada ruim não pode parar o ciclo
      registrar('Falha na rodada automática do Cofre: $e', nivel: 'error');
    }
  }

  // ---- ações de linha ------------------------------------------------------------------------------ //
  String _rotulo(Map<String, dynamic> n) =>
      'NFS-e nº ${_ou(n['nNFSe'], '?')} (${(n['papel_rotulo'] as String).toLowerCase()})';

  /// Gera a DANFSe do XML guardado e abre. O PDF vai para a pasta temporária do sistema.
  void _abrirDanfse(Map<String, dynamic> n) {
    if (!app.temPermissao('cofre.pdf')) {
      app.exigirPermissao('cofre.pdf', () => _abrirDanfse(n));
      return;
    }
    final prest = app.prestador;
    app.emSegundoPlano(() async {
      String pdf;
      try {
        pdf = await chamar<String>('cofre.gerar_danfse', {
          'dono': prest,
          'chave': n['chave'],
        });
      } catch (e) {
        registrar('Falha ao gerar a DANFSe pelo Cofre: $e', nivel: 'error');
        app.toast(
          'Não foi possível gerar a DANFSe da ${_rotulo(n)}: $e',
          erro: true,
        );
        return;
      }
      abrirCaminho(app, pdf);
    });
  }

  Future<void> _salvarXml(Map<String, dynamic> n) async {
    if (!await app.autorizarAcao('cofre.xml')) return;
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Salvar XML da NFS-e',
        nome: '${n['chave']}.xml',
        extensoes: const ['xml'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    if (!destino.toLowerCase().endsWith('.xml')) destino += '.xml';
    try {
      final b64 = ja<String>('cofre.xml_da_nota', {'nota_id': n['id']});
      File(destino).writeAsBytesSync(base64Decode(b64));
      app.toast('XML da ${_rotulo(n)} salvo em: $destino');
    } catch (e) {
      app.toast('Falha ao salvar o XML da ${_rotulo(n)}: $e', erro: true);
    }
  }

  Future<void> _salvarDanfse(Map<String, dynamic> n) async {
    if (!await app.autorizarAcao('cofre.pdf')) return;
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Salvar DANFSe (PDF)',
        nome: 'NFSe_${_ou(n['nNFSe'], n['chave'] as String)}.pdf',
        extensoes: const ['pdf'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    if (!destino.toLowerCase().endsWith('.pdf')) destino += '.pdf';
    final dest = destino;
    final prest = app.prestador;
    app.emSegundoPlano(() async {
      try {
        final pdf = await chamar<String>('cofre.gerar_danfse', {
          'dono': prest,
          'chave': n['chave'],
        });
        await File(pdf).copy(dest);
        app.toast('DANFSe da ${_rotulo(n)} salva em: $dest');
      } catch (e) {
        registrar('Falha ao salvar a DANFSe pelo Cofre: $e', nivel: 'error');
        app.toast('Falha ao salvar a DANFSe da ${_rotulo(n)}: $e', erro: true);
      }
    });
  }

  // ---- exportar dados do Cofre ----------------------------------------------------------------------- //
  /// Em cima, os filtros (nascem como estão na tela): tipo, período, ambiente, situação e a
  /// busca. Embaixo, o que sai e como SEPARAR o resultado: por mês/ano e por emitidas/
  /// recebidas. Tudo vai para UM arquivo .zip.
  void _abrirExportar() {
    if (!app.temPermissao('cofre.exportar')) {
      app.exigirPermissao('cofre.exportar', () => _abrirExportar());
      return;
    }
    if (app.prestador.isEmpty) {
      app.toast('Selecione um prestador.', erro: true);
      return;
    }
    final f0 = filtro();
    final termo = f0.termo;
    late final Dialogo d;
    late final Suspensa ddPer, ddTipo, ddAmb, ddSit;
    var de = _de;
    var ate = _ate;
    var anterior = _periodoAnt;
    var soBusca = true;
    var (xml, danfse, eventos, relatorio) = (true, false, false, false);
    var (porMes, porTipo) = (false, false);
    var porCompetencia = _ddBasePeriodo.valor == 'competencia';
    final formatos = {for (final f in formatosExportacao.keys) f: f == 'xlsx'};

    String intervalo() => anterior == 'custom' ? textoDoIntervalo(de, ate) : '';
    double larguraPer() => intervalo().isEmpty ? 210 : larguraPeriodoComDatas;
    void mostrarPeriodo() {
      // Com o personalizado em uso o campo mostra as datas: a lista alarga e a do tipo, ao
      // lado, cede a diferença.
      ddPer.opcoes = _opcoesPeriodoCofre(intervalo());
      ddPer.por(ddPer.valor);
      ddPer.avisar();
      d.atualizar();
    }

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
      anterior = v ?? 'tudo';
      mostrarPeriodo();
    }

    void exportar() {
      final per = ddPer.valor ?? 'tudo';
      DateTime? ini;
      DateTime? fim;
      if (per != 'tudo') {
        (ini, fim) = datasDoPeriodo(per, de, ate);
        if (per == 'custom' && !(ini != null && fim != null)) {
          app.toast('Escolha as datas do período personalizado.', erro: true);
          return;
        }
      }
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
      final tipo = ddTipo.valor;
      final sit = ddSit.valor;
      final filtro = <String, Object?>{
        'por_competencia': porCompetencia,
        'papel': (tipo == null || tipo.isEmpty || tipo == todos) ? '' : tipo,
        'ambiente': ambRotulos.containsKey(ddAmb.valor) ? ddAmb.valor : '',
        'ini': dataIso(ini),
        'fim': dataIso(fim),
        'situacao': (sit == null || sit.isEmpty || sit == todos) ? '' : sit,
        'termo': (termo.isNotEmpty && soBusca) ? termo : '',
      };
      final opcoes = <String, Object?>{
        'incluir_xml': xml,
        'incluir_danfse': danfse,
        'incluir_eventos': eventos,
        'formatos': fmts,
        'por_mes': porMes,
        'por_tipo': porTipo,
      };
      app.fecharDialogo();
      _exportarDados(filtro, opcoes, ini, fim);
    }

    Widget caixa(
      String rotulo,
      bool valor,
      ValueChanged<bool> aoMudar, {
      bool compacto = false,
    }) => Marcar(
      idLayout: 'Checkbox.cofre.1',
      compacto: compacto,
      valor: valor,
      rotulo: rotulo,
      aoMudar: (v) {
        aoMudar(v ?? false);
        d.atualizar();
      },
    );

    d = Dialogo(
      titulo: (_) => app.tituloComX('Exportar dados do Cofre'),
      largura: 470,
      conteudo: (_) => col(
        [
          lin(
            [
              ListaSuspensa(
                estado: ddPer,
                rotulo: 'Período',
                largura: TamanhosCofre.campoPeriodo.largura ?? (larguraPer()),
                aoSelecionar: aoPeriodo,
                altura: TamanhosCofre.campoPeriodo.altura,
                idLayout: 'TamanhosCofre.campoPeriodo',
              ),
              ListaSuspensa(
                estado: ddTipo,
                rotulo: 'Tipo',
                largura:
                    TamanhosCofre.campoTipo.largura ?? (420 - larguraPer()),
                altura: TamanhosCofre.campoTipo.altura,
                idLayout: 'TamanhosCofre.campoTipo',
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.cofre.lin.1',
          ),
          lin(
            [
              ListaSuspensa(
                estado: ddAmb,
                rotulo: 'Ambiente',
                largura: TamanhosCofre.campoAmbiente.largura!,
                altura: TamanhosCofre.campoAmbiente.altura,
                idLayout: 'TamanhosCofre.campoAmbiente',
              ),
              ListaSuspensa(
                estado: ddSit,
                rotulo: 'Situação',
                largura: TamanhosCofre.campoSituacao.largura!,
                altura: TamanhosCofre.campoSituacao.altura,
                idLayout: 'TamanhosCofre.campoSituacao',
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.cofre.lin.2',
          ),
          caixa(
            'Filtrar período pela competência',
            porCompetencia,
            (v) => porCompetencia = v,
          ),
          if (termo.isNotEmpty)
            caixa(
              'Só o que a busca da tela encontra (“$termo”)',
              soBusca,
              (v) => soBusca = v,
            ),
          Tx(
            'O que exportar',
            tam: Letra.apoio,
            peso: FontWeight.w600,
            largura: TamanhosCofre.rotuloOQueExportar.largura,
            altura: TamanhosCofre.rotuloOQueExportar.altura,
            idLayout: 'TamanhosCofre.rotuloOQueExportar',
          ),
          col(
            [
              caixa('XMLs das notas', xml, (v) => xml = v),
              caixa('DANFSe (PDF)', danfse, (v) => danfse = v),
              caixa(
                'Eventos (cancelamentos e substituições)',
                eventos,
                (v) => eventos = v,
              ),
              caixa('Relatório', relatorio, (v) => relatorio = v),
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
                            TamanhosCofre.rotuloFormatosDoRelatorio.largura,
                        altura: TamanhosCofre.rotuloFormatosDoRelatorio.altura,
                        idLayout: 'TamanhosCofre.rotuloFormatosDoRelatorio',
                      ),
                      lin(
                        [
                          for (final e in formatosExportacao.entries)
                            caixa(
                              e.value.$2,
                              formatos[e.key]!,
                              (v) => formatos[e.key] = v,
                              compacto: true,
                            ),
                        ],
                        espaco: 4,
                        quebra: true,
                        idLayout: 'Grupo.cofre.lin.3',
                      ),
                    ],
                    espaco: 0,
                    justa: true,
                    idLayout: 'Grupo.cofre.col.3',
                  ),
                ),
            ],
            espaco: 0,
            justa: true,
            idLayout: 'Grupo.cofre.col.2',
          ),
          Tx(
            'Separar',
            tam: Letra.apoio,
            peso: FontWeight.w600,
            largura: TamanhosCofre.rotuloSeparar.largura,
            altura: TamanhosCofre.rotuloSeparar.altura,
            idLayout: 'TamanhosCofre.rotuloSeparar',
          ),
          col(
            [
              caixa(
                'Por mês/ano — uma pasta para cada mês (2026-09, 2026-10…)',
                porMes,
                (v) => porMes = v,
              ),
              caixa(
                'Emitidas e recebidas — uma pasta para cada',
                porTipo,
                (v) => porTipo = v,
              ),
            ],
            espaco: 0,
            justa: true,
            idLayout: 'Grupo.cofre.col.4',
          ),
          Tx(
            'Tudo sai num único arquivo .zip, cada tipo na sua pasta (xml, danfse, '
            'eventos e Relatorios). Separando, cada pasta de mês ou de tipo ganha '
            'as suas — e o seu relatório.',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura:
                TamanhosCofre.rotuloTudoSaiNumUnicoArquivoZipCadaTipo.largura,
            altura:
                TamanhosCofre.rotuloTudoSaiNumUnicoArquivoZipCadaTipo.altura,
            idLayout: 'TamanhosCofre.rotuloTudoSaiNumUnicoArquivoZipCadaTipo',
          ),
        ],
        justa: true,
        espaco: 12,
        rolar: true,
        idLayout: 'Grupo.cofre.col.1',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosCofre.botaoCancelar.largura,
          altura: TamanhosCofre.botaoCancelar.altura,
          idLayout: 'TamanhosCofre.botaoCancelar',
        ),
        Botao(
          'Exportar',
          icone: Icons.download,
          aoClicar: exportar,
          largura: TamanhosCofre.botaoExportar.largura,
          altura: TamanhosCofre.botaoExportar.altura,
          idLayout: 'TamanhosCofre.botaoExportar',
        ),
      ],
      idLayout: 'Janela.cofre.Dialogo.1',
    );
    ddPer = d.suspensa(
      valor: anterior,
      opcoes: _opcoesPeriodoCofre(intervalo()),
    );
    ddTipo = d.suspensa(
      valor: f0.papel.isEmpty ? todos : f0.papel,
      opcoes: _opcoesTipo,
    );
    ddAmb = d.suspensa(
      valor: f0.amb.isEmpty ? 'todos' : f0.amb,
      opcoes: opcoesDeAmbiente,
    );
    ddSit = d.suspensa(
      valor: f0.situacao.isEmpty ? todos : f0.situacao,
      opcoes: _opcoesSituacao,
    );
    app.mostrarDialogo(d);
  }

  /// Gera o .zip da exportação do Cofre, com a mesma barra de progresso e o mesmo Cancelar
  /// da exportação da Consulta.
  Future<void> _exportarDados(
    Map<String, Object?> filtro,
    Map<String, Object?> opcoes,
    DateTime? ini,
    DateTime? fim,
  ) async {
    final prestador = app.prestador;
    int total;
    try {
      total = ja<int>('exportacao.contar_cofre', {
        'prestador': prestador,
        ...filtro,
      });
    } catch (e) {
      app.toast('Não foi possível consultar o Cofre: $e', erro: true);
      return;
    }
    if (total == 0) {
      app.toast(
        'Nenhuma nota no Cofre com esses filtros — nada para exportar.',
        erro: true,
      );
      return;
    }
    final fmts = (opcoes['formatos'] as List).cast<String>();
    if (fmts.contains('pdf') &&
        total > 2000 &&
        !await _confirmarPdfGrande(total))
      return;
    var base = 'cofre_${soDoc(prestador)}';
    if (ini != null || fim != null) {
      base += '_${dataCompacta(ini, 'ini')}_${dataCompacta(fim, 'fim')}';
    }
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: 'Exportar dados do Cofre (.zip)',
        nome: '$base.zip',
        extensoes: const ['zip'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    if (!destino.toLowerCase().endsWith('.zip')) destino += '.zip';
    final dest = destino;
    final progresso = ProgressoExportacao(app)..abrir();

    app.emSegundoPlano(() async {
      Map<String, dynamic> r;
      try {
        // Começa do zero: o "Salvar como" já confirmou se era para substituir.
        apagarSeExistir(dest);
        r = Map<String, dynamic>.from(
          await chamar<Map>(
            'exportacao.cofre_zip',
            {
              'prestador': prestador,
              'destino': dest,
              ...filtro,
              ...opcoes,
              'ficha': progresso.ficha,
            },
            (a) {
              if (a is Map && a['etapa'] != null) {
                progresso.etapa(
                  a['etapa'] as String,
                  indeterminada: a['indeterminada'] == true,
                );
              } else {
                progresso.aviso(a);
              }
            },
          ),
        );
        if (progresso.cancelada) throw ErroNucleo('ExportCancelled', '');
      } on ErroNucleo catch (e) {
        apagarSeExistir(dest);
        if (e.tipo == 'ExportCancelled' || progresso.cancelada)
          return; // o zip não fica
        registrar('Falha ao exportar o Cofre ($dest): $e', nivel: 'error');
        progresso.fechar();
        app.toast('Falha ao exportar: $e', erro: true);
        return;
      } catch (e) {
        registrar('Falha ao exportar o Cofre ($dest): $e', nivel: 'error');
        apagarSeExistir(dest);
        progresso.fechar();
        app.toast('Falha ao exportar: $e', erro: true);
        return;
      }
      progresso.fechar();
      final partes = [
        if (opcoes['incluir_xml'] == true) '${r['xml']} XML(s)',
        if (opcoes['incluir_danfse'] == true) '${r['danfse']} DANFSe',
        if (opcoes['incluir_eventos'] == true) '${r['eventos']} evento(s)',
        if (fmts.isNotEmpty) '${r['relatorios']} relatório(s)',
      ];
      final onde = (r['pastas'] as num) > 1
          ? ' em ${r['pastas']} pasta(s)'
          : '';
      registrar(
        'Exportação do Cofre concluída (${partes.join('; ')}; ${r['notas']} nota(s)$onde) '
        'em $dest',
      );
      app.toast(
        'Cofre exportado para .zip: ${partes.join('; ')} — ${r['notas']} nota(s)'
        '$onde (${periodoPorExtenso(ini, fim)}).',
      );
    });
  }

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
        largura: TamanhosCofre.rotuloORelatorioTemMilharTotalNotasUmPDF.largura,
        altura: TamanhosCofre.rotuloORelatorioTemMilharTotalNotasUmPDF.altura,
        idLayout: 'TamanhosCofre.rotuloORelatorioTemMilharTotalNotasUmPDF',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: () => app.fecharEsta(d),
          largura: TamanhosCofre.botaoCancelar2.largura,
          altura: TamanhosCofre.botaoCancelar2.altura,
          idLayout: 'TamanhosCofre.botaoCancelar2',
        ),
        Botao(
          'Gerar PDF mesmo assim',
          icone: Icons.picture_as_pdf,
          aoClicar: () {
            responder(true);
            app.fecharEsta(d);
          },
          largura: TamanhosCofre.botaoGerarPDFMesmoAssim.largura,
          altura: TamanhosCofre.botaoGerarPDFMesmoAssim.altura,
          idLayout: 'TamanhosCofre.botaoGerarPDFMesmoAssim',
        ),
      ],
      aoFechar: () => responder(false),
      idLayout: 'Janela.cofre.Dialogo.2',
    );
    app.mostrarDialogo(d);
    return resposta.future;
  }

  // ---- desenho ----------------------------------------------------------------------------------- //
  Widget _celula(int i, String valor, {Color? cor, String? propria}) => Ct(
    largura: _larguras[i],
    alinhar: _centradas.contains(i)
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
    IconData icone,
    String rotulo,
    VoidCallback aoClicar,
  ) => PopupMenuItem<String>(
    value: rotulo,
    height: 48,
    mouseCursor: SystemMouseCursors.click,
    onTap: aoClicar,
    child: lin(
      [
        Icon(icone, size: 18),
        Tx(
          rotulo,
          largura: TamanhosCofre.rotuloRotulo.largura,
          altura: TamanhosCofre.rotuloRotulo.altura,
          idLayout: 'TamanhosCofre.rotuloRotulo:$rotulo',
        ),
      ],
      justa: true,
      idLayout: 'Grupo.cofre.lin.4',
    ),
  );

  DataRow _linha(Map<String, dynamic> n, LocalKey chave) {
    String s(String k) => (n[k] as String?) ?? '';
    final homolog = s('amb') == ambHomologacao;
    // homologação em vermelho, como na Consulta
    final cor = homolog ? Colors.red.shade700 : null;
    final papel = s('papel');
    final outroPapel = papel != papelEmitida && papel != papelRecebida;
    final corTipo = homolog
        ? cor
        : (papel == papelEmitida
              ? Colors.indigo.shade700
              : (papel == papelRecebida ? Colors.teal.shade700 : null));
    final outroDoc = s('outro_doc');
    final substPor = s('subst_por');
    final cancelada = n['cancelada'] == true;
    return DataRow(
      // A chave é da POSIÇÃO, não da nota: trocar de página, filtrar ou ordenar atualiza as
      // linhas que já estão montadas em vez de desmontar todas e montar outras.
      key: chave,
      color: hoverPadrao,
      // Sempre "interativa" (é o que dá o realce do mouse): com uma janela aberta por cima o
      // mouse não chega aqui, e manter a linha com a MESMA estrutura evita desmontar e montar
      // de novo todas as células a cada janela que abre ou fecha.
      onSelectChanged: (_) {},
      // O conteúdo da linha fica montado enquanto a página lida for a mesma.
      cells: _celulas.da(
        [_notas, _gruposClientes],
        n,
        () => [
          DataCell(
            _celula(
              0,
              outroPapel ? 'Outra' : s('papel_rotulo'),
              cor: corTipo,
              propria: outroPapel
                  ? 'O prestador aparece nesta nota sem ser o emitente nem o tomador '
                        '(intermediário, por exemplo).'
                  : null,
            ),
          ),
          DataCell(_celula(1, _ou(s('nNFSe'), '—'), cor: cor)),
          DataCell(_celula(2, _ou(s('outro_nome'), '—'), cor: cor)),
          DataCell(
            _celula(
              3,
              outroDoc.isEmpty ? '—' : formatarDocumento(outroDoc),
              cor: cor,
            ),
          ),
          DataCell(
            _celula(
              4,
              _ddBasePeriodo.valor == 'competencia'
                  ? dataIsoParaBr(s('dCompet'))
                  : dataHora(s('dhProc')),
              cor: cor,
            ),
          ),
          DataCell(
            _celula(5, ambRotulos[s('amb')] ?? _ou(s('amb'), '?'), cor: cor),
          ),
          DataCell(
            _celula(
              6,
              substPor.isNotEmpty
                  ? 'SUBST.'
                  : (cancelada ? 'CANCELADA' : _ou(s('cStat'), '—')),
              cor: substPor.isNotEmpty
                  ? Colors.orange.shade800
                  : ((cancelada || homolog) ? Colors.red.shade700 : null),
              propria: substPor.isNotEmpty
                  ? 'SUBSTITUÍDA pela NFS-e de chave $substPor'
                  : null,
            ),
          ),
          DataCell(
            _celula(
              7,
              moedaBr((n['vServ'] as num).toStringAsFixed(2)),
              cor: cor,
            ),
          ),
          DataCell(
            _celula(
              8,
              moedaBr((n['vLiq'] as num).toStringAsFixed(2)),
              cor: cor,
            ),
          ),
          DataCell(
            Ct(
              largura: _larguraAcoes,
              alinhar: Alignment.centerLeft,
              child: lin(
                [
                  BotaoIcone(
                    Icons.download_for_offline,
                    dica: 'Salvar XML',
                    aoClicar: () => _salvarXml(n),
                    largura: TamanhosCofre.botaoSalvarXML.largura,
                    altura: TamanhosCofre.botaoSalvarXML.altura,
                    idLayout: 'TamanhosCofre.botaoSalvarXML',
                  ),
                  BotaoIcone(
                    Icons.picture_as_pdf,
                    cor: Colors.red.shade700,
                    dica: 'Abrir DANFSe (gerada na hora)',
                    aoClicar: () => _abrirDanfse(n),
                    largura: TamanhosCofre.botaoAbrirDANFSeGeradaNaHora.largura,
                    altura: TamanhosCofre.botaoAbrirDANFSeGeradaNaHora.altura,
                    idLayout: 'TamanhosCofre.botaoAbrirDANFSeGeradaNaHora',
                  ),
                  MenuMais(
                    () => [
                      _item(
                        Icons.save_alt,
                        'Salvar DANFSe (PDF) como…',
                        () => _salvarDanfse(n),
                      ),
                      _item(
                        Icons.content_copy,
                        'Copiar chave de acesso',
                        () => copiar(
                          app,
                          s('chave'),
                          aviso: 'Chave de acesso copiada.',
                        ),
                      ),
                    ],
                  ),
                ],
                espaco: 0,
                idLayout: 'Grupo.cofre.lin.5',
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
    carregarPagina();
  }

  /// A tabela (a parte cara da tela) com as linhas de [primeira] a [ultima].
  DataTable _montarTabela(
    bool inerte,
    int primeira,
    int ultima,
    LocalKey Function(int) chave,
  ) {
    DataColumn coluna(
      String rotulo, {
      bool numerica = false,
      bool ordenavel = true,
    }) => DataColumn(
      label: Tx(
        rotulo == 'vServ'
            ? 'Valor Serviço'
            : rotulo == 'vLíq'
            ? 'Valor Líquido'
            : rotulo,
        tam: 13,
        peso: FontWeight.bold,
        linhas: 1,
        semQuebra: true,
        tema: (rotulo == 'vServ' || rotulo == 'vLíq')
            ? (t) => t.titleSmall?.copyWith(letterSpacing: -0.2)
            : null,
        largura: TamanhosCofre.rotuloRotulo2.largura,
        altura: TamanhosCofre.rotuloRotulo2.altura,
        idLayout: 'TamanhosCofre.rotuloRotulo2:$rotulo',
      ),
      numeric: numerica,
      headingRowAlignment: switch (ajusteLayout(
        context,
        'TamanhosCofre.rotuloRotulo2:$rotulo',
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

    return TabelaPadrao(
      showCheckboxColumn: false,
      headingRowHeight: _alturaCabecalho,
      dataRowMinHeight: _alturaLinha,
      dataRowMaxHeight: _alturaLinha,
      columnSpacing: 14,
      sortColumnIndex: _ordem?.$1,
      sortAscending: _ordem?.$2 ?? false,
      columns: [
        coluna('Tipo'),
        coluna('NFS-e'),
        coluna('Emitente / Tomador'),
        coluna('Documento'),
        coluna(
          _ddBasePeriodo.valor == 'competencia'
              ? 'Competência'
              : 'Processada em',
        ),
        coluna('Ambiente'),
        coluna('Status'),
        coluna('vServ', numerica: true),
        coluna('vLíq', numerica: true),
        coluna('Ações', ordenavel: false),
      ],
      rows: [
        for (var i = primeira; i <= ultima; i++) _linha(_notas[i], chave(i)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final inerte = travado(context);
    final paginas = math.max(1, (_total / _porPagina).ceil());
    final tabela = TabelaCabecalhoFixo(
      espacoAntesAcoes: 20,
      larguras: [..._larguras, _larguraAcoes],
      colunaExpansivel: 2,
      quantidade: _notas.length,
      alturaLinha: _alturaLinha,
      alturaCabecalho: _alturaCabecalho,
      entradas: [_notas, _gruposClientes, inerte, _ordem],
      montar: (primeira, ultima, chave) =>
          _montarTabela(inerte, primeira, ultima, chave),
    );

    // É UM botão. Parado, "Sincronizar"; durante a sincronização fica vermelho, escrito
    // "Cancelar", com o ícone girando — clicar cancela.
    final icone = IconeGiratorio(_giro, Icons.sync);
    final vermelho = Colors.red.shade700;
    final botaoSinc = comDica(
      _sincAtiva
          ? 'Parar a sincronização (o lote em andamento é descartado)'
          : _dicaSinc,
      ElementoLayoutGenerico(
        width: TamanhosCofre.botaoSincronizar.largura,
        height: TamanhosCofre.botaoSincronizar.altura,
        child: FilledButton.icon(
          style: _sincAtiva
              ? ButtonStyle(
                  foregroundColor: const WidgetStatePropertyAll(Colors.white),
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (estados) => estados.contains(WidgetState.disabled)
                        ? vermelho.withValues(alpha: 0.55)
                        : vermelho,
                  ),
                  elevation: const WidgetStatePropertyAll(1.0),
                )
              : null,
          autofocus: false,
          // desabilitado até a sincronização parar de fato
          onPressed: (inerte || _sincCancelando) ? null : _botao,
          onLongPress: (inerte || _sincCancelando) ? null : () {},
          onHover: (inerte || _sincCancelando) ? null : (_) {},
          clipBehavior: Clip.none,
          icon: icone,
          label: Text(
            ajusteLayout(context, 'TamanhosCofre.botaoSincronizar').exibir(
              _sincAtiva
                  ? (_sincCancelando ? 'Cancelando…' : 'Cancelar')
                  : 'Sincronizar',
            ),
          ),
        ),
        idLayout: 'TamanhosCofre.botaoSincronizar',
        textoOriginal: _sincAtiva
            ? (_sincCancelando ? 'Cancelando…' : 'Cancelar')
            : 'Sincronizar',
      ),
    );

    return col(
      [
        lin([
          Tx(
            'Cofre de NFS-e',
            tam: Letra.titulo,
            peso: FontWeight.bold,
            largura: TamanhosCofre.rotuloCofreDeNFSE.largura,
            altura: TamanhosCofre.rotuloCofreDeNFSE.altura,
            idLayout: 'TamanhosCofre.rotuloCofreDeNFSE',
          ),
          const Expanded(child: SizedBox()),
          // Sincronização com o ADN: situação à esquerda do botão.
          Ct(
            largura: 430,
            alinhar: Alignment.centerRight,
            child: Tx(
              _textoSinc,
              tam: Letra.apoio,
              cor: Colors.grey.shade700,
              linhas: 2,
              alinhar: TextAlign.right,
              largura: TamanhosCofre.rotuloTextoSinc.largura,
              altura: TamanhosCofre.rotuloTextoSinc.altura,
              idLayout: 'TamanhosCofre.rotuloTextoSinc',
            ),
          ),
          Botao.contorno(
            'Exportar dados',
            icone: Icons.download,
            aoClicar: _abrirExportar,
            largura: TamanhosCofre.botaoExportarDados.largura,
            altura: TamanhosCofre.botaoExportarDados.altura,
            idLayout: 'TamanhosCofre.botaoExportarDados',
          ),
          botaoSinc,
        ], idLayout: 'Grupo.cofre.lin.6'),
        Tx(
          'Todas as notas deste prestador, emitidas e recebidas, guardadas no banco de '
          'notas. A DANFSe não é guardada: é gerada na hora, a partir do XML.',
          tam: Letra.apoio,
          cor: Colors.grey.shade700,
          largura: TamanhosCofre
              .rotuloTodasAsNotasDestePrestadorEmitidasERecebidas
              .largura,
          altura: TamanhosCofre
              .rotuloTodasAsNotasDestePrestadorEmitidasERecebidas
              .altura,
          idLayout:
              'TamanhosCofre.rotuloTodasAsNotasDestePrestadorEmitidasERecebidas',
        ),
        if (!app.temPermissao('cofre.pesquisar'))
          Expanded(
            child: AcessoRestrito(
              aoAutorizar: () =>
                  app.exigirPermissao('cofre.pesquisar', carregarPagina),
            ),
          )
        else ...[
          lin(
            [
              CampoTexto(
                controle: _busca,
                rotulo: rotuloDaBusca,
                largura: TamanhosCofre.campoRotuloDaBusca.largura,
                iconePrefixo: const Icon(Icons.search),
                aoMudar: (_) => _aoVivo.tecla(() {
                  if (app.navAtual != 4) return;
                  _pagina = 0;
                  carregarPagina();
                }, viva: () => app.viva && mounted),
                altura: TamanhosCofre.campoRotuloDaBusca.altura,
                idLayout: 'TamanhosCofre.campoRotuloDaBusca',
              ),
              ListaSuspensa(
                estado: _ddTipo,
                rotulo: 'Tipo',
                largura: TamanhosCofre.campoTipo2.largura!,
                aoSelecionar: (_) => _filtroMudou(),
                altura: TamanhosCofre.campoTipo2.altura,
                idLayout: 'TamanhosCofre.campoTipo2',
              ),
              ListaSuspensa(
                estado: _ddBasePeriodo,
                rotulo: 'Data',
                largura: 154,
                aoSelecionar: (_) => _filtroMudou(),
                idLayout: 'Cofre.filtrarPor',
              ),
              ListaSuspensa(
                estado: _ddPeriodo,
                rotulo: 'Período',
                largura:
                    TamanhosCofre.campoPeriodo2.largura ??
                    (_intervalo.isEmpty
                        ? _larguraPeriodo
                        : larguraPeriodoComDatas),
                aoSelecionar: _aoPeriodo,
                altura: TamanhosCofre.campoPeriodo2.altura,
                idLayout: 'TamanhosCofre.campoPeriodo2',
              ),
              ListaSuspensa(
                estado: _ddAmbiente,
                rotulo: 'Ambiente',
                largura: TamanhosCofre.campoAmbiente2.largura!,
                aoSelecionar: (_) => _filtroMudou(),
                altura: TamanhosCofre.campoAmbiente2.altura,
                idLayout: 'TamanhosCofre.campoAmbiente2',
              ),
              ListaSuspensa(
                estado: _ddSituacao,
                rotulo: 'Situação',
                largura: TamanhosCofre.campoSituacao2.largura!,
                aoSelecionar: (_) => _filtroMudou(),
                altura: TamanhosCofre.campoSituacao2.altura,
                idLayout: 'TamanhosCofre.campoSituacao2',
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.cofre.lin.7',
          ),
          Tx(
            _vazio,
            italico: true,
            cor: _vazioErro ? Colors.red.shade700 : Colors.grey.shade600,
            largura: TamanhosCofre.rotuloVazio.largura,
            altura: TamanhosCofre.rotuloVazio.altura,
            idLayout: 'TamanhosCofre.rotuloVazio',
          ),
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
              _pagina = math.max(0, p);
              carregarPagina();
            },
            aoPorPagina: (n) {
              if (n == _porPagina) return;
              _porPagina = n;
              _pagina = 0;
              carregarPagina();
            },
          ),
        ],
      ],
      espaco: 12,
      idLayout: 'Grupo.cofre.col.5',
    );
  }
}
