import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
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
  final dev = Platform.environment['NFSE_RAIZ'] ?? '';
  if (dev.isNotEmpty) return dev;
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
  App? _app;

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// O "X" da janela. Com um trabalho em segundo plano ou uma decisão de transmissão
  /// pendente o fechamento é recusado; senão, a arrumação roda antes de o processo sair.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    final app = _app;
    if (app != null && app.viva) {
      if (app.ocupado) {
        app.toast(
          'Conclua a operação ou a decisão de transmissão pendente antes de fechar.',
          erro: true,
        );
        return AppExitResponse.cancel;
      }
      app.pararTimers(encerrarRede: false);
    }
    await App.arrumarParaFechar().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    return AppExitResponse.exit;
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
            Platform.environment['NFSE_RAIZ'] ??
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
