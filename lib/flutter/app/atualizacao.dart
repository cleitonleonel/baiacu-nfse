// Atualização do programa: a procura sozinha ao entrar (no máximo uma vez por dia), o botão
// "Atualização disponível" no topo e a janela que baixa, confere e instala a versão nova.
// O núcleo consulta a release, baixa o pacote e aciona o atualizador.
import 'package:flutter/material.dart';

import '../kit/flet.dart';
import 'app.dart';
import 'sistema.dart';

/// A versão nova encontrada (null = nenhuma): o botão do topo aparece enquanto houver.
final atualizacaoDisponivel = ValueNotifier<Map<String, dynamic>?>(null);
final _avisoExibido = Expando<String>();

const _verde = Color(0xFF15803D);


/// Procura versão nova. [automatica]: a procura sozinha ao entrar (respeita o intervalo, a
/// opção desligada e a versão pulada, e nunca mostra erro). Manual: sempre consulta e diz o
/// resultado.
Future<void> procurarAtualizacao(
  App app, {
  bool automatica = false,
  bool aoEntrar = false,
}) async {
  if (automatica) {
    if (!app.temPermissao('config.atualizacao.preparar', somenteLogado: true))
      return;
  } else if (!await app.autorizarAcao('config.atualizacao.preparar')) {
    return;
  }
  final h = automatica ? null : app.toastProgresso('Procurando versão nova…');
  try {
    final r = Map<String, dynamic>.from(
      await chamar<Map>('atualizacao.verificar', {
        'automatica': automatica,
        'ao_entrar': aoEntrar,
      }),
    );
    if (!app.viva) return;
    if (r['disponivel'] == true) {
      if (h != null) {
        app.toastFim(h, 'Versão ${r['versao']} disponível.');
      }
      mostrarAtualizacaoDisponivel(app, r, automatica: automatica);
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

/// Instalação atualizada pelo botão desde a 1.0.0.2: sem o serviço de dados, os bancos abrem no
/// modo antigo. Só o nível 4 é avisado (é quem pode rodar o instalador), uma vez por sessão.
void avisarModoAntigo(App app) {
  if (!app.viva || app.usuario.nivel < 4) return;
  try {
    if (jaMapa('atualizacao.estado')['modo_antigo'] != true) return;
  } catch (_) {
    return;
  }
  app.toast(
    'Para ativar a nova proteção dos dados, execute o instalador uma vez '
    '(Configurações › Avançado › Atualizações).',
  );
  registrar(
    'Instalação sem o serviço de dados (atualizada pelo botão): aviso mostrado ao nível 4.',
    nivel: 'warning',
  );
}

void mostrarAtualizacaoDisponivel(
  App app,
  Map<String, dynamic> info, {
  required bool automatica,
}) {
  atualizacaoDisponivel.value = info;
  if (!automatica) {
    abrirAtualizacao(app);
    return;
  }

  final versao = '${info['versao']}';
  void avisar() {
    if (!app.viva ||
        _avisoExibido[app] == versao ||
        atualizacaoDisponivel.value?['versao'] != info['versao'] ||
        !app.temPermissao('config.atualizacao', somenteLogado: true)) {
      return;
    }
    if (app.ocupado || app.dialogos.isNotEmpty) {
      app.agendar(const Duration(seconds: 2), avisar);
      return;
    }
    abrirAtualizacao(app);
  }

  avisar();
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
                mouseCursor: SystemMouseCursors.click,
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
  if (!app.temPermissao('config.atualizacao')) {
    app.exigirPermissao('config.atualizacao', () => abrirAtualizacao(app));
    return;
  }
  final versao = '${info['versao'] ?? ''}';
  if (app.dialogos.any((d) => d.marcador == 'atualizacao_disponivel')) return;
  _avisoExibido[app] = versao;
  final notas = '${info['notas'] ?? ''}'.trim();
  final instalavel = info['instalavel'] == true;
  final mb = ((info['tamanho'] as num?) ?? 0) / 1048576;
  late final Dialogo d;
  d = Dialogo(
    largura: 620,
    marcador: 'atualizacao_disponivel',
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
            child: _NotasDaVersao(notas: notas),
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
      Botao.texto(
        'Pular esta versão',
        aoClicar: () {
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
        idLayout: 'Atualizacao.botaoPular',
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Botao.contorno(
            'Depois',
            aoClicar: () => app.fecharEsta(d),
            idLayout: 'Atualizacao.botaoDepois',
          ),
          const SizedBox(width: 8),
          if (instalavel)
            Botao(
              'Atualizar agora',
              icone: Icons.download,
              fundo: _verde,
              cor: Colors.white,
              aoClicar: () {
                app.fecharEsta(d);
                _baixarEInstalar(app, versao);
              },
              idLayout: 'Atualizacao.botaoAtualizarAgora',
            )
          else
            Botao(
              'Abrir página de download',
              icone: Icons.open_in_new,
              aoClicar: () {
                try {
                  abrirEndereco('${info['pagina'] ?? ''}');
                } catch (e) {
                  app.toast('$e', erro: true);
                }
              },
              idLayout: 'Atualizacao.botaoPaginaDownload',
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
  if (!app.temPermissao('config.atualizacao.preparar')) {
    app.exigirPermissao(
      'config.atualizacao.preparar',
      () => _baixarEInstalar(app, versao),
    );
    return;
  }
  if (_baixando) return;
  _baixando = true;
  final h = app.toastProgresso('Baixando a versão $versao…');
  final andamento = ValueNotifier<Map<String, Object?>>({
    'etapa': 'Preparando o download…',
    'percentual': null,
  });
  final janela = Dialogo(
    largura: 480,
    titulo: (_) => LinhaTitulo([textoTitulo('Baixando a atualização')]),
    conteudo: (_) => ValueListenableBuilder<Map<String, Object?>>(
      valueListenable: andamento,
      builder: (context, estado, _) {
        final percentual = estado['percentual'] as num?;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${estado['etapa']}',
              style: const TextStyle(fontSize: Letra.texto),
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: percentual == null
                  ? null
                  : (percentual / 100).clamp(0.0, 1.0),
            ),
            const SizedBox(height: 8),
            if (percentual != null)
              Text('${percentual.round()}%', textAlign: TextAlign.right),
          ],
        );
      },
    ),
  );
  app.mostrarDialogo(janela);
  app.emSegundoPlano(() async {
    try {
      final baixada = await Nucleo.chamarAcompanhando<Map>(
        'atualizacao.baixar',
        {'versao': versao},
        aoAvisar: (aviso) {
          if (aviso is Map && aviso['etapa'] != null) {
            andamento.value = {
              'etapa': '${aviso['etapa']}',
              'percentual': aviso['percentual'],
            };
            app.toastAndamento(h, '${aviso['etapa']}…');
          }
        },
      );
      final versaoBaixada = '${baixada['versao']}';
      app.fecharEsta(janela);
      app.toastFim(h, 'Versão $versaoBaixada baixada e conferida.');
      // Fora do trabalho em segundo plano: fechar o programa espera ele terminar.
      app.agendar(
        const Duration(milliseconds: 100),
        () => _confirmar(app, versaoBaixada),
      );
    } catch (e) {
      app.toastFim(h, 'Não foi possível atualizar: $e', erro: true);
    } finally {
      app.fecharEsta(janela);
      andamento.dispose();
      _baixando = false;
    }
  });
}

void _confirmar(App app, String versao) {
  var instalando = false;
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
      Botao.contorno(
        'Instalar depois',
        aoClicar: () => app.fecharEsta(d),
        idLayout: 'Atualizacao.botaoInstalarDepois',
      ),
      Botao(
        'Instalar e reiniciar',
        icone: Icons.restart_alt,
        fundo: _verde,
        cor: Colors.white,
        idLayout: 'Atualizacao.botaoInstalarReiniciar',
        aoClicar: () async {
          if (app.ocupado) {
            app.toast(
              'Conclua a operação em andamento antes de instalar a atualização.',
              erro: true,
            );
            return;
          }
          if (instalando ||
              !await app.autorizarAcao('config.atualizacao.instalar'))
            return;
          if (instalando || !d.aberto) return;
          instalando = true;
          final progresso = app.toastProgresso('Preparando a instalação…');
          try {
            await chamar<Object?>('atualizacao.instalar', {'versao': versao});
            app.toastFim(progresso, 'Atualizador iniciado.');
          } catch (e) {
            instalando = false;
            app.toastFim(progresso, '$e', erro: true);
            return;
          }
          app.fecharEsta(d);
          registrar(
            'Atualização para a versão $versao: fechando para instalar.',
          );
          await app.fechar();
        },
      ),
    ],
    alinhamentoAcoes: MainAxisAlignment.end,
    idLayout: 'Janela.atualizacao.confirmar',
  );
  app.mostrarDialogo(d);
}

class _NotasDaVersao extends StatefulWidget {
  const _NotasDaVersao({required this.notas});
  final String notas;
  @override
  State<_NotasDaVersao> createState() => _NotasDaVersaoState();
}

class _NotasDaVersaoState extends State<_NotasDaVersao> {
  final _rolagem = ScrollController();
  @override
  void dispose() {
    _rolagem.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _rolagem,
    thumbVisibility: true,
    child: SingleChildScrollView(
      controller: _rolagem,
      padding: const EdgeInsets.only(right: 12),
      child: SelectableText(
        widget.notas.isEmpty ? 'Melhorias e correções.' : widget.notas,
        style: const TextStyle(fontSize: Letra.texto, height: 1.4),
      ),
    ),
  );
}
