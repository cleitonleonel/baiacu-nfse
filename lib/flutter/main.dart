import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show MethodChannel, ServicesBinding;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'acesso/acesso.dart';
import 'app/app.dart';
import 'app/casca.dart';
import 'escala.dart';
import 'estilo.dart';
import 'editor_layout.dart';
import 'tema.dart';

/// Raiz dos dados: ProgramData na instalação; pasta do executável no ZIP portátil. Em
/// desenvolvimento, a variável NFSE_RAIZ aponta para a raiz do projeto.
String _raiz() {
  if (kDebugMode) {
    final dev = Platform.environment['NFSE_RAIZ'] ?? '';
    if (dev.isNotEmpty) return dev;
  }
  final pasta = File(Platform.resolvedExecutable).parent.path;
  if (File('$pasta/installed.marker').existsSync()) {
    final dados = Platform.environment['ProgramData'];
    if (dados == null || dados.isEmpty) {
      throw StateError(
        'Não foi possível localizar ProgramData. Repare a instalação do Baiacu.',
      );
    }
    return '$dados/Baiacu NFS-e';
  }
  return pasta;
}

void main(List<String> args) {
  LigacaoComEscala.iniciar();
  if (args.length == 1 && args.single == '--baiacu-validar-inicializacao') {
    final dados = Directory.systemTemp.createTempSync('baiacu-partida-');
    Never terminar(int codigo) {
      try {
        dados.deleteSync(recursive: true);
      } on FileSystemException {
        exit(1);
      }
      exit(codigo);
    }

    FlutterError.onError = (erro) {
      FlutterError.presentError(erro);
      terminar(1);
    };
    WidgetsBinding.instance.platformDispatcher.onError = (erro, pilha) {
      stderr.writeln('$erro\n$pilha');
      terminar(1);
    };
    Nucleo.iniciar(dados.path);
    runApp(
      RepaintBoundary(
        child: EmissorApp(
          aoPrepararAcesso: () async {
            await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
            // Código reservado ao teste de partida. Uma saída normal não confirma a versão.
            terminar(42);
          },
        ),
      ),
    );
    return;
  }
  Nucleo.iniciar(_raiz());
  Nucleo.chamar<Object?>('registro.registrar', {
    'nome': 'app',
    'msg': 'Aplicativo iniciado.',
  });
  runApp(const RepaintBoundary(child: EmissorApp()));
}

class EmissorApp extends StatefulWidget {
  const EmissorApp({super.key, this.aoPrepararAcesso});

  final VoidCallback? aoPrepararAcesso;

  @override
  State<EmissorApp> createState() => _EmissorAppState();
}

class _EmissorAppState extends State<EmissorApp> with WidgetsBindingObserver {
  static const _janela = MethodChannel('baiacu/janela');
  final _navegador = GlobalKey<NavigatorState>();
  App? _app;
  bool _avaliandoSaida = false;

  @override
  void reassemble() {
    super.reassemble();
    revisaoDoEstilo++;
    limparTemasParaHotReload();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _janela.setMethodCallHandler((chamada) async {
      if (chamada.method == 'sairDaBandeja' &&
          await _pedirSaida(daBandeja: true) == AppExitResponse.exit) {
        await ServicesBinding.instance.exitApplication(AppExitType.required);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _janela.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() => _pedirSaida();

  bool _saidaBloqueada() {
    final app = _app;
    if (app == null || !app.viva || !app.ocupado) return false;
    app.toast(
      'Conclua a operação ou a decisão de transmissão pendente antes de fechar.',
      erro: true,
    );
    return true;
  }

  Future<AppExitResponse> _pedirSaida({bool daBandeja = false}) async {
    if (_avaliandoSaida) return AppExitResponse.cancel;
    _avaliandoSaida = true;
    try {
      if (!daBandeja && _app?.minimizarAoFechar == true) {
        try {
          if (await _janela.invokeMethod<bool>('ocultarNaBandeja') == true) {
            return AppExitResponse.cancel;
          }
        } catch (e) {
          debugPrint('Falha ao mover o Baiacu para a bandeja: $e');
        }
      }
      final contexto = _navegador.currentContext;
      if (contexto == null || _saidaBloqueada()) return AppExitResponse.cancel;
      final confirmou = await showDialog<bool>(
        context: contexto,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Sair do Baiacu NFS-e?'),
          content: const SizedBox(
            width: 440,
            child: Text('Deseja realmente sair do programa?'),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sair'),
            ),
          ],
        ),
      );
      if (confirmou != true || _saidaBloqueada()) return AppExitResponse.cancel;

      final app = _app;
      if (app != null && app.viva) app.pararTimers(encerrarRede: false);
      await App.arrumarParaFechar().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      return AppExitResponse.exit;
    } finally {
      _avaliandoSaida = false;
    }
  }

  void _entrou(Usuario u) {
    final app = App(
      u,
      aoSair: _saiu,
      aoMudarAparencia: () {
        if (mounted) setState(() {});
      },
    );
    setState(() => _app = app);
  }

  void _saiu() {
    // As telas de acesso usam sempre as cores PADRÃO.
    aparenciaAtual = Aparencia.padrao;
    if (mounted) setState(() => _app = null);
  }

  @override
  Widget build(BuildContext context) {
    // As telas de acesso usam sempre as cores PADRÃO: as personalizadas moram no banco, que na
    // partida ainda está trancado — depois de um "Sair" a cara tem de ser a mesma.
    final app = _app;
    final cores = app == null ? Aparencia.padrao : aparenciaAtual;
    return MaterialApp(
      navigatorKey: _navegador,
      title: 'Baiacu NFS-e',
      debugShowCheckedModeBanner: false,
      theme: temaApp(cores: cores),
      themeMode: ThemeMode.light,
      // pt-BR: traduz o menu de contexto dos campos de texto (Recortar/Copiar/Colar/Selecionar tudo).
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Janela pequena: a tela inteira encolhe por igual (ver escala.dart).
      builder: (context, child) => EditorLayout(
        raiz:
            (kDebugMode ? Platform.environment['NFSE_RAIZ'] : null) ??
            File(Platform.resolvedExecutable).parent.path,
        child: NaEscala(child: child!),
      ),
      home: Scaffold(
        backgroundColor: corHex(cores.fundo),
        body: Stack(
          children: [
            SizedBox.expand(
              child: Column(
                spacing: 10,
                children: [
                  Expanded(
                    child: app == null
                        ? TelaAcesso(
                            aoEntrar: _entrou,
                            aoPreparar: widget.aoPrepararAcesso,
                          )
                        : Casca(key: ObjectKey(app), app: app),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
