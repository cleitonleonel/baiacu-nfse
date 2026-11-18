// Pré-visualização da emissão: a DPS que será transmitida, em duas abas — "Dados & tributos"
// (cartões legíveis, montados pelo núcleo a partir do próprio XML) e "XML da DPS" (o XML
// formatado, com ou sem a assinatura, e o botão de baixar).
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app.dart';
import '../kit/arquivos.dart';
import '../kit/flet.dart';

/// Abre a pré-visualização. [pv] é o retorno de `emissao.preview`; [argumentos] são os mesmos
/// que o geraram (usados de novo, com `assinar`, quando o usuário pede a assinatura).
/// [assinante] é o rótulo do procurador que assina ('' = o certificado próprio).
void abrirPreviaEmissao(
  App app, {
  required Map<String, dynamic> pv,
  required Map<String, Object?> argumentos,
  required String ambiente,
  String assinante = '',
}) {
  final previa = _Previa(app, pv, argumentos, ambiente, assinante);
  late final Dialogo d;
  d = Dialogo(
    titulo: (_) => app.tituloComX('Pré-visualização da emissão'),
    largura: 960,
    conteudo: (context) {
      previa.dialogo = d;
      final alto = (MediaQuery.sizeOf(context).height - 220).clamp(
        380.0,
        660.0,
      );
      return SizedBox(
        height: alto,
        child: Abas(
          inicial: previa.aba,
          aoMudar: (i) => previa.aba = i,
          rotulos: const [
            ('Dados & tributos', Icons.dashboard_outlined),
            ('XML da DPS', Icons.code),
          ],
          paineis: [previa.painelDados(context), previa.painelXml(context)],
        ),
      );
    },
    idLayout: 'Janela.emitir.Dialogo.previa',
  );
  app.mostrarDialogo(d);
}

class _Previa {
  _Previa(this.app, this.pv, this.argumentos, this.ambiente, this.assinante);

  final App app;
  Map<String, dynamic> pv;
  final Map<String, Object?> argumentos;
  final String ambiente;
  final String assinante;
  Dialogo? dialogo;
  int aba = 0;
  bool comAssinatura = false;

  bool get _temAssinada => (pv['xml_assinado'] as String?)?.isNotEmpty ?? false;

  String get _xmlExibido => comAssinatura && _temAssinada
      ? pv['xml_assinado'] as String
      : (pv['xml'] as String? ?? '');

  // ---- aba "Dados & tributos" ------------------------------------------------------------ //
  // Muitos textos: aqui vão Text simples (leves), com UMA área de seleção para o painel todo.
  Widget painelDados(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final resumo = Map<String, dynamic>.from(
      (pv['resumo'] as Map?) ?? const {},
    );
    final destaques = [
      for (final x in (resumo['destaques'] as List?) ?? const [])
        Map<String, dynamic>.from(x as Map),
    ];
    final cartoes = [
      for (final x in (resumo['cartoes'] as List?) ?? const [])
        Map<String, dynamic>.from(x as Map),
    ];
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(2, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _faixaDeEstado(esquema),
            ..._avisosTributacao(),
            if (destaques.isNotEmpty) ...[
              const SizedBox(height: 14),
              _destaques(esquema, destaques),
            ],
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, c) =>
                  _grade(esquema, cartoes, c.maxWidth >= 640 ? 2 : 1),
            ),
          ],
        ),
      ),
    );
  }

  /// Combinações de NBS, item, cIndOp e cClassTrib que o Anexo VIII da NFS-e não prevê. Não
  /// impedem a transmissão (a tabela oficial ainda é preliminar), mas costumam virar recusa.
  List<Widget> _avisosTributacao() {
    final avisos = [
      for (final a in (pv['avisos_tributacao'] as List?) ?? const []) '$a',
    ];
    if (avisos.isEmpty) return const [];
    final cor = Colors.orange.shade800;
    return [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cor.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: cor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Compatibilidade tributária (IBS/CBS): confira antes de transmitir',
                    style: TextStyle(color: cor, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final a in avisos)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $a'),
              ),
          ],
        ),
      ),
    ];
  }

  /// Nº/série, ambiente, validação do XSD e quem assina, em etiquetas.
  Widget _faixaDeEstado(ColorScheme esquema) {
    final problemas = (pv['validation_issues'] as num?)?.toInt() ?? 0;
    final producao = pv['tp_amb'] == '1';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _etiqueta(
          Icons.tag,
          'DPS nº ${pv['n_dps']} · série ${pv['serie']}',
          esquema.primary,
        ),
        _etiqueta(
          producao ? Icons.public : Icons.science_outlined,
          ambiente.isEmpty ? 'Ambiente ${pv['tp_amb']}' : ambiente,
          producao ? Colors.green.shade700 : Colors.red.shade700,
        ),
        problemas == 0
            ? _etiqueta(
                Icons.verified_outlined,
                'XSD válido',
                Colors.green.shade700,
              )
            : _etiqueta(
                Icons.error_outline,
                'XSD: $problemas problema(s)',
                Colors.red.shade700,
              ),
        _etiqueta(
          Icons.draw_outlined,
          assinante.isEmpty
              ? 'Assina: certificado do prestador'
              : 'Assina: procurador $assinante',
          esquema.onSurfaceVariant,
        ),
      ],
    );
  }

  Widget _etiqueta(IconData icone, String texto, Color cor) => Container(
    padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
    decoration: BoxDecoration(
      color: cor.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: cor.withValues(alpha: 0.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 15, color: cor),
        const SizedBox(width: 6),
        Text(
          texto,
          style: TextStyle(
            fontSize: Letra.apoio,
            fontWeight: FontWeight.w600,
            color: cor,
          ),
        ),
      ],
    ),
  );

  /// Os números que mais importam, grandes, numa faixa.
  Widget _destaques(ColorScheme esquema, List<Map<String, dynamic>> itens) =>
      Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        decoration: BoxDecoration(
          color: esquema.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: esquema.primary.withValues(alpha: 0.18)),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final porLinha = c.maxWidth >= 640 ? itens.length : 2;
            final largura = (c.maxWidth - (porLinha - 1) * 18) / porLinha;
            return Wrap(
              spacing: 18,
              runSpacing: 12,
              children: [
                for (final (i, x) in itens.indexed)
                  SizedBox(
                    width: largura,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${x['rotulo'] ?? ''}',
                          style: TextStyle(
                            fontSize: Letra.apoio,
                            color: esquema.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${x['valor'] ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: i == 0 ? 20 : Letra.subtitulo,
                            fontWeight: FontWeight.w700,
                            color: i == 0 ? esquema.primary : esquema.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      );

  /// Os cartões em linhas de [colunas]: os de uma mesma linha têm a mesma altura (a do maior),
  /// então topos e bases ficam alinhados.
  Widget _grade(
    ColorScheme esquema,
    List<Map<String, dynamic>> cartoes,
    int colunas,
  ) {
    final linhas = <Widget>[];
    for (var i = 0; i < cartoes.length; i += colunas) {
      final fim = math.min(i + colunas, cartoes.length);
      if (linhas.isNotEmpty) linhas.add(const SizedBox(height: 14));
      linhas.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = i; j < i + colunas; j++) ...[
                if (j > i) const SizedBox(width: 14),
                Expanded(
                  child: j < fim
                      ? _cartao(esquema, cartoes[j])
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: linhas,
    );
  }

  static IconData _icone(String nome) => switch (nome) {
    'dps' => Icons.receipt_long_outlined,
    'prestador' => Icons.storefront_outlined,
    'tomador' => Icons.person_outline,
    'intermediario' => Icons.handshake_outlined,
    'servico' => Icons.home_repair_service_outlined,
    'valores' => Icons.payments_outlined,
    'issqn' => Icons.account_balance_outlined,
    'federais' => Icons.flag_outlined,
    'total' => Icons.pie_chart_outline,
    'ibscbs' => Icons.percent,
    _ => Icons.description_outlined,
  };

  Widget _cartao(ColorScheme esquema, Map<String, dynamic> c) {
    final linhas = [
      for (final x in (c['linhas'] as List?) ?? const [])
        Map<String, dynamic>.from(x as Map),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: esquema.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: esquema.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: esquema.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _icone('${c['icone']}'),
                  size: 16,
                  color: esquema.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${c['titulo'] ?? ''}',
                  style: const TextStyle(
                    fontSize: Letra.subtitulo,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final (i, l) in linhas.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
              child: _linha(esquema, l, i == 0),
            ),
        ],
      ),
    );
  }

  Widget _linha(ColorScheme esquema, Map<String, dynamic> l, bool primeira) {
    final secao = l['secao'] as String?;
    if (secao != null) {
      return Padding(
        padding: EdgeInsets.only(top: primeira ? 0 : 6),
        child: Row(
          children: [
            Text(
              secao.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: esquema.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(height: 1, color: esquema.outlineVariant),
            ),
          ],
        ),
      );
    }
    final rotulo = Text(
      '${l['rotulo'] ?? ''}',
      style: TextStyle(fontSize: Letra.apoio, color: esquema.onSurfaceVariant),
    );
    final valor = '${l['valor'] ?? ''}';
    if (l['longo'] == true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          rotulo,
          const SizedBox(height: 2),
          Text(valor, style: const TextStyle(fontSize: Letra.texto)),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 4, child: rotulo),
        const SizedBox(width: 12),
        Expanded(
          flex: 6,
          child: Text(
            valor,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: Letra.texto,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  // ---- aba "XML da DPS" ------------------------------------------------------------------ //
  Widget painelXml(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Marcar(
                valor: comAssinatura,
                rotulo: 'Exibir assinatura no XML',
                compacto: true,
                rente: true,
                dica:
                    'Assina a DPS agora com o certificado que a emissão vai usar, só para '
                    'mostrar e baixar. Nada é enviado e a numeração não muda.',
                aoMudar: (v) => _alternarAssinatura(v == true),
                idLayout: 'TamanhosEmitir.marcarExibirAssinatura',
              ),
              const Spacer(),
              Tx(
                comAssinatura
                    ? 'DPS assinada (o que seria transmitido)'
                    : 'DPS sem assinatura',
                tam: Letra.apoio,
                cor: esquema.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Ct(
              cor: esquema.surfaceContainerLow,
              raio: BorderRadius.circular(10),
              borda: Border.all(color: esquema.outlineVariant),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Tx(
                  _xmlExibido,
                  selecionavel: true,
                  tam: Letra.codigo,
                  fonte: 'Consolas',
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Tx(
                  comAssinatura
                      ? 'O arquivo baixado é o XML assinado exatamente como seria '
                            'transmitido (sem quebras de linha), para a assinatura continuar '
                            'válida. A emissão monta e assina a DPS de novo, com a data e a '
                            'hora do envio.'
                      : 'A NFS-e oficial é gerada e devolvida pela Sefin Nacional após o '
                            'envio; ela envolve esta DPS e acrescenta número, chave e os '
                            'valores apurados.',
                  tam: Letra.apoio,
                  cor: esquema.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Botao.contorno(
                'Copiar',
                icone: Icons.copy,
                aoClicar: _copiar,
                largura: TamanhosEmitir.botaoCopiarXmlDps.largura,
                altura: TamanhosEmitir.botaoCopiarXmlDps.altura,
                idLayout: 'TamanhosEmitir.botaoCopiarXmlDps',
              ),
              const SizedBox(width: 8),
              Botao(
                comAssinatura
                    ? 'Baixar XML da DPS (assinado)'
                    : 'Baixar XML da DPS',
                icone: Icons.download,
                aoClicar: _baixar,
                largura: TamanhosEmitir.botaoBaixarXmlDps.largura,
                altura: TamanhosEmitir.botaoBaixarXmlDps.altura,
                idLayout: 'TamanhosEmitir.botaoBaixarXmlDps',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _alternarAssinatura(bool ligar) {
    if (ligar && !_temAssinada) {
      try {
        // Monta e assina de novo: o XML sem assinatura e o assinado ficam iguais (mesma
        // data/hora), e os cartões passam a mostrar exatamente essa DPS.
        pv = jaMapa('emissao.preview', {...argumentos, 'assinar': true});
      } catch (e) {
        app.toast('Não foi possível assinar a DPS: $e', erro: true);
        return;
      }
    }
    comAssinatura = ligar;
    dialogo?.atualizar();
  }

  Future<void> _copiar() async {
    await Clipboard.setData(ClipboardData(text: _xmlExibido));
    app.toast('XML copiado.');
  }

  Future<void> _baixar() async {
    final assinado = comAssinatura && _temAssinada;
    final conteudo = assinado
        ? (pv['xml_assinado_bruto'] as String? ?? '')
        : (pv['xml'] as String? ?? '');
    if (conteudo.isEmpty) return;
    final nome =
        'DPS_${pv['serie']}_${pv['n_dps']}${assinado ? '_assinada' : ''}.xml';
    String? destino;
    try {
      destino = await salvarArquivo(
        titulo: assinado ? 'Baixar XML da DPS (assinado)' : 'Baixar XML da DPS',
        nome: nome,
        extensoes: const ['xml'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (destino == null || destino.isEmpty) return;
    if (!destino.toLowerCase().endsWith('.xml')) destino += '.xml';
    try {
      File(destino).writeAsStringSync(conteudo, flush: true);
      app.toast('XML da DPS salvo em: $destino');
    } catch (e) {
      app.toast('Falha ao salvar o XML: $e', erro: true);
    }
  }
}
