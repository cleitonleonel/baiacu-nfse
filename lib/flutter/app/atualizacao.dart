// Atualização do programa: a procura sozinha ao entrar (no máximo uma vez por dia), o botão
// "Atualização disponível" no topo e a janela que baixa, confere e instala a versão nova.
// O trabalho (GitHub, download, SHA-256 e o script de instalação) é do núcleo: atualizacao.rs.
import 'package:flutter/material.dart';

import '../kit/flet.dart';
import 'app.dart';
import 'sistema.dart';

/// A versão nova encontrada (null = nenhuma): o botão do topo aparece enquanto houver.
final atualizacaoDisponivel = ValueNotifier<Map<String, dynamic>?>(null);

const _verde = Color(0xFF15803D);

/// Procura versão nova. [automatica]: a procura sozinha ao entrar (respeita o intervalo, a
/// opção desligada e a versão pulada, e nunca mostra erro). Manual: sempre consulta e diz o
/// resultado.
Future<void> procurarAtualizacao(App app, {bool automatica = false}) async {
  final h = automatica ? null : app.toastProgresso('Procurando versão nova…');
  try {
    final r = Map<String, dynamic>.from(
      await chamar<Map>('atualizacao.verificar', {'automatica': automatica}),
    );
    if (r['disponivel'] == true) {
      atualizacaoDisponivel.value = r;
      if (h != null) {
        app.toastFim(h, 'Versão ${r['versao']} disponível.');
        abrirAtualizacao(app);
      }
    } else if (h != null && r['aviso'] != null) {
      app.toastFim(h, '${r['aviso']}', aviso: true);
    } else if (h != null) {
      app.toastFim(
        h,
        'Você já está na versão mais recente (${r['versao_atual']}).',
      );
    }
  } catch (e) {
    if (h != null) app.toastFim(h, '$e', erro: true);
  }
}

/// O botão do topo. Só aparece com versão nova.
class BotaoAtualizacao extends StatelessWidget {
  const BotaoAtualizacao({super.key, required this.app});
  final App app;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: atualizacaoDisponivel,
        builder: (context, info, _) {
          if (info == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Tooltip(
              message: 'Clique para ver o que mudou e atualizar.',
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => abrirAtualizacao(app),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
                  decoration: BoxDecoration(
                    color: _verde.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _verde.withValues(alpha: 0.45)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.system_update_alt,
                        size: 16,
                        color: _verde,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Atualização disponível',
                        style: const TextStyle(
                          fontSize: Letra.texto,
                          fontWeight: FontWeight.w600,
                          color: _verde,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
}

/// A janela da versão nova: o que mudou, e "Atualizar agora" / "Depois" / "Pular esta versão".
void abrirAtualizacao(App app) {
  final info = atualizacaoDisponivel.value;
  if (info == null) return;
  final versao = '${info['versao'] ?? ''}';
  final notas = '${info['notas'] ?? ''}'.trim();
  final instalavel = info['instalavel'] == true;
  final mb = ((info['tamanho'] as num?) ?? 0) / 1048576;
  late final Dialogo d;
  d = Dialogo(
    largura: 620,
    titulo: (_) => app.tituloComX('Versão $versao disponível'),
    conteudo: (context) {
      final esquema = Theme.of(context).colorScheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Você usa a versão ${info['versao_atual']}. A atualização mantém todos os seus '
            'dados (cadastros, notas, certificados e configurações).'
            '${mb > 0 ? ' Download de ${mb.toStringAsFixed(0)} MB.' : ''}',
            style: const TextStyle(fontSize: Letra.texto),
          ),
          const SizedBox(height: 12),
          Text(
            'O que mudou',
            style: const TextStyle(
              fontSize: Letra.subtitulo,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: esquema.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                notas.isEmpty ? 'Melhorias e correções.' : notas,
                style: const TextStyle(fontSize: Letra.texto, height: 1.4),
              ),
            ),
          ),
          if (!instalavel) ...[
            const SizedBox(height: 10),
            Text(
              'Esta cópia do programa não pode se atualizar sozinha (modo de desenvolvimento). '
              'Baixe a versão nova pela página do projeto.',
              style: TextStyle(
                fontSize: Letra.apoio,
                color: esquema.onSurfaceVariant,
              ),
            ),
          ],
        ],
      );
    },
    acoes: (context) => [
      TextButton(
        onPressed: () {
          try {
            ja<Object?>('atualizacao.configurar', {'pular': versao});
          } catch (_) {}
          atualizacaoDisponivel.value = null;
          app.fecharEsta(d);
          app.toast(
            'A versão $versao não será mais oferecida. Você pode procurar de novo em '
            'Configurações › Avançado › Atualizações.',
          );
        },
        child: const Text('Pular esta versão'),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            onPressed: () => app.fecharEsta(d),
            child: const Text('Depois'),
          ),
          const SizedBox(width: 8),
          if (instalavel)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _verde,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                app.fecharEsta(d);
                _baixarEInstalar(app, versao);
              },
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Atualizar agora'),
            )
          else
            FilledButton.icon(
              onPressed: () {
                try {
                  abrirEndereco('${info['pagina'] ?? ''}');
                } catch (e) {
                  app.toast('$e', erro: true);
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Abrir página de download'),
            ),
        ],
      ),
    ],
    alinhamentoAcoes: MainAxisAlignment.spaceBetween,
    idLayout: 'Janela.atualizacao',
  );
  app.mostrarDialogo(d);
}

bool _baixando = false;

void _baixarEInstalar(App app, String versao) {
  if (_baixando) return;
  _baixando = true;
  final h = app.toastProgresso('Baixando a versão $versao…');
  app.emSegundoPlano(() async {
    try {
      await Nucleo.chamarAcompanhando<Object?>(
        'atualizacao.baixar',
        const {},
        aoAvisar: (aviso) {
          if (aviso is Map && aviso['etapa'] != null) {
            app.toastAndamento(h, '${aviso['etapa']}…');
          }
        },
      );
      app.toastFim(h, 'Versão $versao baixada e conferida.');
      // Fora do trabalho em segundo plano: fechar o programa espera ele terminar.
      app.agendar(const Duration(milliseconds: 100), () => _confirmar(app, versao));
    } catch (e) {
      app.toastFim(h, 'Não foi possível atualizar: $e', erro: true);
    } finally {
      _baixando = false;
    }
  });
}

void _confirmar(App app, String versao) {
  late final Dialogo d;
  d = Dialogo(
    largura: 480,
    titulo: (_) => app.tituloComX('Instalar a versão $versao'),
    conteudo: (_) => const Text(
      'O programa vai fechar, instalar a versão nova e abrir de novo sozinho em alguns '
      'segundos. Seus dados não são alterados.',
      style: TextStyle(fontSize: Letra.texto),
    ),
    acoes: (_) => [
      OutlinedButton(
        onPressed: () => app.fecharEsta(d),
        child: const Text('Instalar depois'),
      ),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: _verde,
          foregroundColor: Colors.white,
        ),
        onPressed: () async {
          if (app.ocupado) {
            app.toast(
              'Conclua a operação em andamento antes de instalar a atualização.',
              erro: true,
            );
            return;
          }
          try {
            ja<Object?>('atualizacao.instalar');
          } catch (e) {
            app.toast('$e', erro: true);
            return;
          }
          app.fecharEsta(d);
          registrar('Atualização para a versão $versao: fechando para instalar.');
          await app.fechar();
        },
        icon: const Icon(Icons.restart_alt, size: 16),
        label: const Text('Instalar e reiniciar'),
      ),
    ],
    alinhamentoAcoes: MainAxisAlignment.end,
    idLayout: 'Janela.atualizacao.confirmar',
  );
  app.mostrarDialogo(d);
}
