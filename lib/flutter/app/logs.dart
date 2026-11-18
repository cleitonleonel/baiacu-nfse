// Logs: exportação para o suporte (janela Ajuda e Configurações › Avançado › Logs). O núcleo
// junta os logs dos últimos 30 dias, o log do atualizador e um resumo do sistema num .zip, com
// CPF, CNPJ e e-mail sempre mascarados (rust/src/registro.rs).
import 'dart:io';

import '../kit/arquivos.dart';
import 'app.dart';
import 'sistema.dart';

/// Dias de logs que entram no pacote do suporte.
const diasLogsSuporte = 30;

Future<void> exportarLogsSuporte(App app) async {
  if (!app.temPermissao('ajuda.logs')) {
    app.exigirPermissao('ajuda.logs', () => exportarLogsSuporte(app));
    return;
  }
  final agora = DateTime.now();
  String dois(int n) => n.toString().padLeft(2, '0');
  final nome =
      'Baiacu-logs-suporte-${agora.year}${dois(agora.month)}${dois(agora.day)}-'
      '${dois(agora.hour)}${dois(agora.minute)}.zip';
  final destino = await salvarArquivo(
    titulo: 'Salvar os logs para o suporte',
    nome: nome,
    extensoes: const ['zip'],
  );
  if (destino == null || destino.trim().isEmpty) return;
  final caminho = destino.toLowerCase().endsWith('.zip') ? destino : '$destino.zip';
  final h = app.toastProgresso('Juntando os logs…');
  await app.emSegundoPlano(() async {
    try {
      final r = Map<String, dynamic>.from(
        await chamar<Map>('registro.exportar_suporte', {
          'destino': caminho,
          'dias': diasLogsSuporte,
        }),
      );
      app.toastFim(
        h,
        'Logs exportados (${r['arquivos']} arquivos). Envie o .zip ao suporte por e-mail.',
      );
      final pasta = File(caminho).parent.path;
      abrirCaminho(app, pasta);
    } catch (e) {
      registrar('Falha ao exportar os logs para o suporte: $e', nivel: 'error');
      app.toastFim(h, 'Não foi possível exportar os logs: $e', erro: true);
    }
  });
}
