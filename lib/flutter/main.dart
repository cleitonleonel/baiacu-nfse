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

/// Raiz do programa (database/, logs/, configs/): a pasta do executável quando instalado; em
/// desenvolvimento, a variável NFSE_RAIZ aponta para a raiz do projeto.
String _raiz() {
  final dev = Platform.environment['NFSE_RAIZ'] ?? '';
  return dev.isNotEmpty ? dev : File(Platform.resolvedExecutable).parent.path;
}

void main() {
  LigacaoComEscala.iniciar();
  Nucleo.iniciar(_raiz());
  Nucleo.chamar<Object?>('registro.registrar', {
    'nome': 'app',
    'msg': 'Aplicativo iniciado.',
  });
  runApp(const RepaintBoundary(child: EmissorApp()));
}

class EmissorApp extends StatefulWidget {
  const EmissorApp({super.key});

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
        raiz: _raiz(),
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
                        ? TelaAcesso(aoEntrar: _entrou)
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
