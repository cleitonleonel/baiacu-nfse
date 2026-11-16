/// Envio da NFS-e por e-mail ao tomador (o trabalho é do núcleo; aqui ficam o aviso de
/// progresso, o registro e a leitura em cache da configuração).
library;

import 'app.dart';

/// Config de e-mail do prestador em uso, em cache. Invalidada ao salvar o cartão E-mail e
/// na troca de prestador.
Map<String, dynamic> configEmail(App app) {
  if (app.emailCfg == null || app.emailCfgPrest != app.prestador) {
    try {
      app.emailCfg = app.prestador.isEmpty
          ? <String, dynamic>{}
          : jaMapa('correio.get_settings', {'prestador': app.prestador});
    } catch (_) {
      app.emailCfg =
          <String, dynamic>{}; // config ilegível: trata como desabilitado
    }
    app.emailCfgPrest = app.prestador;
  }
  return app.emailCfg!;
}

// A resposta por ambiente da configuração em uso (a Consulta pergunta a cada LINHA).
Map<String, dynamic>? _ativoDe;
final Map<String, bool> _ativoPara = {};

bool emailAtivoPara(Map<String, dynamic> cfg, String ambiente) {
  if (cfg.isEmpty) return false;
  if (!identical(cfg, _ativoDe)) {
    _ativoDe = cfg;
    _ativoPara.clear();
  }
  final ja_ = _ativoPara[ambiente];
  if (ja_ != null) return ja_;
  bool ativo;
  try {
    ativo = ja<bool>('correio.ativo_para', {
      'settings': cfg,
      'ambiente': ambiente,
    });
  } catch (_) {
    return false;
  }
  return _ativoPara[ambiente] = ativo;
}

bool emailAutoPara(Map<String, dynamic> cfg, String ambiente) {
  if (cfg.isEmpty) return false;
  return ja<bool>('correio.auto_para', {'settings': cfg, 'ambiente': ambiente});
}

/// Envia a nota de [chave] ao e-mail cadastrado do tomador. [prest] explícito: quando vem da
/// emissão é o prestador de quem emitiu (o usuário pode ter trocado de prestador no meio).
void enviarNfseEmail(
  App app, {
  required String tomador,
  required String chave,
  String ambiente = '',
  String rotulo = '',
  String prest = '',
  bool aposEmissao = false,
}) {
  final permissao = aposEmissao ? 'emitir.email' : 'consultar.email';
  if (!app.temPermissao(permissao, somenteLogado: aposEmissao)) {
    if (!aposEmissao) {
      app.exigirPermissao(
        permissao,
        () => enviarNfseEmail(
          app,
          tomador: tomador,
          chave: chave,
          ambiente: ambiente,
          rotulo: rotulo,
          prest: prest,
        ),
      );
    }
    return;
  }
  final prestador = prest.isEmpty ? app.prestador : prest;
  if (tomador.isEmpty || chave.isEmpty) {
    app.toast('NFS-e sem tomador ou chave para enviar por e-mail.', erro: true);
    return;
  }
  final nome = rotulo.isEmpty
      ? 'NFS-e de chave …${chave.length > 8 ? chave.substring(chave.length - 8) : chave}'
      : rotulo;
  // Aviso de progresso: fica na tela até o envio terminar; envios simultâneos empilham.
  final h = app.toastProgresso('Enviando $nome por e-mail ao tomador…');
  app.emSegundoPlano(() async {
    try {
      final r = Map<String, dynamic>.from(
        await chamar<Map>('correio.enviar_nfse', {
          if (aposEmissao) 'origem': 'emitir',
          'prestador': prestador,
          'tomador': tomador,
          'chave': chave,
          'ambiente': ambiente,
        }),
      );
      // O e-mail pode ter saído SEM a DANFSe (falha ao gerar o PDF): dizer só "enviado"
      // esconderia isso.
      final semPdf = (r['danfse_anexado'] ?? true) == true
          ? ''
          : ' (sem o DANFSe: ${r['danfse_error'] ?? 'PDF indisponível'})';
      app.toastFim(
        h,
        'E-mail enviado para ${r['to']} — $nome.$semPdf',
        erro: semPdf.isNotEmpty,
      );
      registrar(
        'NFS-e enviada por e-mail (prestador=$prestador tomador=$tomador chave=$chave)$semPdf',
      );
    } catch (e) {
      // Cota diária estourada e senha de app revogada NÃO são "tente de novo".
      var categoria = 'outro';
      var explicacao = '$e';
      try {
        final c = ja<List>('correio.classificar_erro', {
          'tipo': e is ErroNucleo ? e.tipo : 'Exception',
          'msg': '$e',
          'dados': e is ErroNucleo ? e.dados : null,
        });
        categoria = c[0] as String;
        explicacao = c[1] as String;
      } catch (_) {}
      registrar(
        'Falha ao enviar NFS-e por e-mail [$categoria] (prestador=$prestador '
        'tomador=$tomador chave=$chave): $e',
        nivel: 'warning',
      );
      app.toastFim(
        h,
        'Falha ao enviar e-mail da $nome: $explicacao',
        erro: true,
      );
    }
  });
}
