// Apoio ao projeto: a janela de doação (carteiras de cripto, cada uma com QR e endereço), aberta
// pelo botão de Configurações › Apoie este projeto e, uma vez só, com fogos, depois da primeira
// NFS-e emitida em produção. Quem recebe e essa regra ficam no núcleo (rust/src/doacao.rs).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../kit/flet.dart';
import 'app.dart';
import 'fogos.dart';

/// Depois de uma NFS-e emitida: diz se é a primeira em produção (a hora da janela, uma vez só).
bool doacaoAposEmissao({required bool producao}) {
  try {
    return ja<bool>('doacao.apos_emissao', {'producao': producao});
  } catch (_) {
    return false;
  }
}

// Paleta da doação: um rosa quente puxando para o violeta, igual em tema claro e escuro.
const _rosa = Color(0xFFE5486F);
const _violeta = Color(0xFF7A5AF8);

/// "Clique para contribuir" (Configurações › Apoie este projeto): ao passar o mouse, o fundo
/// claro vira o degradê rosa → violeta. Clicar abre a janela de doação.
class BotaoContribuir extends StatefulWidget {
  const BotaoContribuir({super.key, required this.app});
  final App app;

  @override
  State<BotaoContribuir> createState() => _BotaoContribuirState();
}

class _BotaoContribuirState extends State<BotaoContribuir> {
  bool _sobre = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _sobre = true),
    onExit: (_) => setState(() => _sobre = false),
    child: GestureDetector(
      onTap: () => widget.app.exigirPermissao(
        'config.apoio',
        () => abrirDoacao(widget.app),
      ),
      // Um degradê só, do claro ao vivo: animar de cor sólida para degradê passa por um fundo
      // vazio (o "branco" no meio do caminho).
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _sobre ? 1 : 0),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, t, _) {
          final claro = _rosa.withValues(alpha: 0.08);
          final frente = Color.lerp(_rosa, Colors.white, t)!;
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 20, 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color.lerp(claro, _rosa, t)!,
                  Color.lerp(claro, _violeta, t)!,
                ],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Color.lerp(
                  _rosa.withValues(alpha: 0.45),
                  _violeta.withValues(alpha: 0.0),
                  t,
                )!,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(
                  scale: 1 + 0.2 * t,
                  child: Icon(Icons.favorite, size: 18, color: frente),
                ),
                const SizedBox(width: 8),
                Text(
                  'Clique para contribuir',
                  style: TextStyle(
                    fontSize: Letra.texto,
                    fontWeight: FontWeight.w600,
                    color: frente,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

// ------------------------------------------------------------------------------------------- //
// Janela de doação
// ------------------------------------------------------------------------------------------- //
/// Abre a janela de doação. [primeira]: logo depois da primeira NFS-e em produção (comemora,
/// com título próprio e fogos).
void abrirDoacao(App app, {bool primeira = false, VoidCallback? aoFechar}) {
  if (!app.temPermissao('config.apoio', somenteLogado: primeira)) return;
  Map<String, dynamic> info;
  try {
    info = jaMapa('doacao.info');
  } catch (e) {
    app.toast('Não foi possível abrir a doação: $e', erro: true);
    return;
  }
  final j = _JanelaDoacao(app, info, primeira);
  late final Dialogo d;
  d = Dialogo(
    largura: 760,
    conteudo: (context) {
      j.dialogo = d;
      return j.conteudo(context);
    },
    acoes: (context) => j.acoes(context),
    alinhamentoAcoes: MainAxisAlignment.spaceBetween,
    aoFechar: aoFechar,
    idLayout: 'Janela.doacao',
  );
  app.mostrarDialogo(d);
}

class _JanelaDoacao {
  _JanelaDoacao(this.app, this.info, this._primeira) {
    _cripto = [
      for (final c in (info['cripto'] as List?) ?? const [])
        Map<String, dynamic>.from(c as Map),
    ];
  }

  final App app;
  final Map<String, dynamic> info;

  /// Logo depois da primeira NFS-e em produção: comemora (título e fogos).
  final bool _primeira;
  Dialogo? dialogo;

  late final List<Map<String, dynamic>> _cripto;
  int _moeda = 0;

  Map<String, dynamic> get _estado =>
      Map<String, dynamic>.from((info['estado'] as Map?) ?? const {});

  bool _fogosSoltos = false;

  void _redesenhar() => dialogo?.atualizar();

  Future<void> _copiar(String texto, String oque) async {
    await Clipboard.setData(ClipboardData(text: texto));
    app.toast('$oque copiado. Obrigado pelo apoio! 💜');
  }

  // ---- desenho ------------------------------------------------------------------------------ //
  Widget conteudo(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    if (_primeira && !_fogosSoltos) {
      _fogosSoltos = true;
      final camada = Overlay.maybeOf(context, rootOverlay: true);
      if (camada != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => soltarFogos(camada),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heroi(),
        const SizedBox(height: 16),
        _beneficios(esquema),
        const SizedBox(height: 18),
        _painelCripto(esquema),
      ],
    );
  }

  Widget _heroi() {
    final emissoes = (_estado['emissoes'] as num?)?.toInt() ?? 0;
    final primeira = _primeira;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 12, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_rosa, _violeta],
        ),
        boxShadow: [
          BoxShadow(
            color: _violeta.withValues(alpha: 0.30),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
            ),
            child: Icon(
              primeira ? Icons.celebration : Icons.favorite,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primeira ? 'Sua primeira NFS-e saiu! 🎉' : 'Este emissor é gratuito, e continua assim com a sua ajuda',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${primeira ? 'Que bom que deu certo. ' : ''}'
                  'O ${info['projeto'] ?? 'Baiacu NFS-e'} é feito de forma independente, '
                  'tem código aberto e não tem anúncio nem mensalidade. Cada doação '
                  'incentiva a manter o programa atualizado, acompanhar as mudanças da SEFIN, '
                  'corrigir erros e trazer novidades para todo mundo.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: Letra.texto + 0.5,
                    height: 1.45,
                  ),
                ),
                if (emissoes > 1) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 4, 12, 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.receipt_long,
                          color: Colors.white,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Você já emitiu $emissoes notas em produção com ele',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: Letra.apoio,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          BotaoIcone(
            Icons.close,
            dica: 'Fechar',
            cor: Colors.white,
            aoClicar: app.fecharDialogo,
            idLayout: 'Doacao.botaoFecharTopo',
          ),
        ],
      ),
    );
  }

  Widget _beneficios(ColorScheme esquema) {
    Widget item(IconData icone, String titulo, String texto) => Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: _violeta.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icone, size: 18, color: _violeta),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    fontSize: Letra.texto,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  texto,
                  style: TextStyle(
                    fontSize: Letra.apoio,
                    color: esquema.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        item(
          Icons.update,
          'Em dia com a SEFIN',
          'Leiautes, notas técnicas e regras novas.',
        ),
        const SizedBox(width: 14),
        item(
          Icons.code,
          'Código aberto',
          'Qualquer um pode ver, auditar e melhorar.',
        ),
        const SizedBox(width: 14),
        item(
          Icons.money_off,
          'Sem mensalidade',
          'Nada de anúncios nem plano pago.',
        ),
      ],
    );
  }

  /// Cartão branco com o QR (branco também no tema escuro: os leitores precisam do contraste).
  Widget _cartaoQr(Map<String, dynamic>? qr, {String? legenda}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 212,
        height: 212,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _violeta.withValues(alpha: 0.25), width: 2),
          boxShadow: [
            BoxShadow(
              color: _violeta.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: qr == null
            ? const Icon(Icons.qr_code_2, size: 120, color: Colors.black26)
            : CustomPaint(painter: _PintorQr(qr)),
      ),
      if (legenda != null) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: 212,
          child: Text(
            legenda,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: Letra.apoio, color: Colors.grey),
          ),
        ),
      ],
    ],
  );

  Widget _naoConfigurado(ColorScheme esquema, String texto) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: esquema.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(Icons.info_outline, color: esquema.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            texto,
            style: TextStyle(
              fontSize: Letra.texto,
              color: esquema.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _painelCripto(ColorScheme esquema) {
    if (_cripto.isEmpty) {
      return _naoConfigurado(
        esquema,
        'Nenhuma carteira de cripto configurada.',
      );
    }
    final c = _cripto[_moeda.clamp(0, _cripto.length - 1)];
    final endereco = '${c['endereco']}';
    final qr = c['qr'] is Map
        ? Map<String, dynamic>.from(c['qr'] as Map)
        : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _cartaoQr(qr, legenda: 'Leia com a sua carteira'),
        const SizedBox(width: 22),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Escolha a moeda',
                style: TextStyle(
                  fontSize: Letra.subtitulo,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, m) in _cripto.indexed)
                    ChoiceChip(
                      avatar: _iconeMoeda(m, 20),
                      label: Text('${m['simbolo']}'),
                      selected: i == _moeda,
                      showCheckmark: false,
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: i == _moeda ? Colors.white : esquema.onSurface,
                      ),
                      selectedColor: _violeta,
                      side: BorderSide(
                        color: i == _moeda ? _violeta : esquema.outlineVariant,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      onSelected: (_) {
                        _moeda = i;
                        _redesenhar();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber,
                      size: 16,
                      color: Colors.orange.shade800,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Envie ${c['moeda']} (${c['simbolo']}) somente pela rede '
                        '${c['rede']}. Outra rede pode perder a doação.',
                        style: TextStyle(
                          fontSize: Letra.apoio,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  color: esquema.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _iconeMoeda(c, 16),
                              const SizedBox(width: 6),
                              Text(
                                '${c['moeda']} (${c['simbolo']}) · rede ${c['rede']}',
                                style: TextStyle(
                                  fontSize: Letra.apoio,
                                  color: esquema.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Endereço',
                            style: TextStyle(
                              fontSize: Letra.apoio,
                              color: esquema.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          SelectableText(
                            endereco,
                            style: const TextStyle(
                              fontSize: Letra.texto,
                              fontFamily: 'Consolas',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Botao(
                      'Copiar',
                      icone: Icons.copy,
                      fundo: _violeta,
                      cor: Colors.white,
                      aoClicar: () =>
                          _copiar(endereco, 'Endereço ${c['simbolo']}'),
                      idLayout: 'Doacao.botaoCopiarEndereco',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// O ícone da moeda (assets/images/cripto_<símbolo>.svg); sem ícone, um círculo com a sigla.
  Widget _iconeMoeda(Map<String, dynamic> m, double tamanho) {
    final simbolo = '${m['simbolo'] ?? ''}'.toLowerCase();
    return SvgPicture.asset(
      'assets/images/cripto_$simbolo.svg',
      width: tamanho,
      height: tamanho,
      errorBuilder: (_, _, _) => CircleAvatar(
        radius: tamanho / 2,
        backgroundColor: _violeta,
        child: Text(
          simbolo.isEmpty ? '?' : simbolo[0].toUpperCase(),
          style: TextStyle(color: Colors.white, fontSize: tamanho * 0.55),
        ),
      ),
    );
  }

  List<Widget> acoes(BuildContext context) => [
    const SizedBox.shrink(),
    Botao(
      'Fechar',
      fundo: _violeta,
      cor: Colors.white,
      aoClicar: app.fecharDialogo,
      idLayout: 'Doacao.botaoFechar',
    ),
  ];
}

/// Desenha a matriz do QR (com a margem de 2 módulos que os leitores pedem).
class _PintorQr extends CustomPainter {
  _PintorQr(Map<String, dynamic> qr)
    : n = (qr['n'] as num?)?.toInt() ?? 0,
      modulos = '${qr['modulos'] ?? ''}';

  final int n;
  final String modulos;

  @override
  void paint(Canvas canvas, Size size) {
    if (n == 0 || modulos.length < n * n) return;
    const margem = 2;
    final lado = size.shortestSide / (n + 2 * margem);
    final tinta = Paint()
      ..color = const Color(0xFF1B1530)
      ..isAntiAlias = false;
    final caminho = Path();
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (modulos.codeUnitAt(y * n + x) == 0x31) {
          caminho.addRect(
            Rect.fromLTWH(
              (x + margem) * lado,
              (y + margem) * lado,
              lado + 0.5,
              lado + 0.5,
            ),
          );
        }
      }
    }
    canvas.drawPath(caminho, tinta);
  }

  @override
  bool shouldRepaint(_PintorQr old) => old.modulos != modulos || old.n != n;
}
