// Janela "Ajuda" (botão do trilho, abaixo de Configurações): abre o manual do usuário, que vem
// no pacote (docs/), e mostra o e-mail de suporte. Onde fica o manual e qual é o e-mail, o
// núcleo diz (rust/src/ajuda.rs).
import 'package:flutter/material.dart';

import '../kit/flet.dart';
import 'app.dart';
import 'logs.dart';
import 'sistema.dart';

void abrirAjuda(App app) {
  if (!app.temPermissao('ajuda')) {
    app.exigirPermissao('ajuda', () => abrirAjuda(app));
    return;
  }
  Map<String, dynamic> info;
  try {
    info = jaMapa('ajuda.info');
  } catch (e) {
    app.toast('Não foi possível abrir a ajuda: $e', erro: true);
    return;
  }
  var copiado = false;
  late final Dialogo d;
  d = Dialogo(
    largura: 620,
    titulo: (context) => const Text('Ajuda'),
    conteudo: (context) => _conteudo(context, app, info, copiado, () {
      if (!d.aberto) return;
      copiado = true;
      d.atualizar();
    }),
    acoes: (context) => [
      Botao(
        'Fechar',
        aoClicar: app.fecharDialogo,
        idLayout: 'Ajuda.botaoFechar',
      ),
    ],
    idLayout: 'Janela.ajuda',
  );
  app.mostrarDialogo(d);
}

Widget _conteudo(
  BuildContext context,
  App app,
  Map<String, dynamic> info,
  bool copiado,
  VoidCallback aoCopiar,
) {
  final esquema = Theme.of(context).colorScheme;
  final manual = '${info['manual'] ?? ''}';
  final temManual = info['manual_existe'] == true;
  final email = '${info['email'] ?? ''}';
  final versao = '${info['versao'] ?? ''}';

  Widget bloco({
    required IconData icone,
    required String titulo,
    required String texto,
    required List<Widget> filhos,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: esquema.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: esquema.outlineVariant),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: esquema.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icone, color: esquema.primary, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titulo,
                style: const TextStyle(
                  fontSize: Letra.subtitulo,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                texto,
                style: TextStyle(
                  fontSize: Letra.texto,
                  color: esquema.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              ...filhos,
            ],
          ),
        ),
      ],
    ),
  );

  final assunto = Uri.encodeComponent(
    'Baiacu NFS-e${versao.isEmpty ? '' : ' $versao'}: suporte',
  );

  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      bloco(
        icone: Icons.menu_book_outlined,
        titulo: 'Manual do usuário',
        texto:
            'O passo a passo de cada tela: primeiro acesso, emissão, clientes, consulta, '
            'Cofre, e-mail, backup e atualizações.',
        filhos: [
          if (temManual) ...[
            Botao(
              'Abrir o manual',
              icone: Icons.open_in_new,
              aoClicar: () => app.exigirPermissao(
                'ajuda.manual',
                () => abrirCaminho(app, manual),
              ),
              idLayout: 'Ajuda.botaoAbrirManual',
            ),
            const SizedBox(height: 8),
            SelectableText(
              manual,
              style: TextStyle(
                fontSize: Letra.apoio,
                color: esquema.onSurfaceVariant,
              ),
            ),
          ] else
            Text(
              'O manual não foi encontrado em $manual. Ele também está na página do '
              'projeto no GitHub.',
              style: TextStyle(fontSize: Letra.apoio, color: corAviso),
            ),
        ],
      ),
      const SizedBox(height: 14),
      bloco(
        icone: Icons.support_agent,
        titulo: 'Suporte',
        texto:
            'Dúvidas, uma ideia de melhoria ou um erro para relatar? Escreva para o e-mail '
            'abaixo. Num erro, conte o que estava fazendo e, se puder, mande uma captura da '
            'tela e o arquivo de "Exportar logs para o suporte" (CPF, CNPJ e e-mail saem '
            'mascarados). Nunca envie a senha nem o arquivo do certificado.',
        filhos: [
          lin(
            [
              Flexible(
                child: SelectableText(
                  email,
                  style: TextStyle(
                    fontSize: Letra.texto + 1,
                    fontWeight: FontWeight.w700,
                    color: esquema.primary,
                  ),
                ),
              ),
              BotaoIcone(
                copiado ? Icons.check : Icons.content_copy,
                tamanho: 16,
                dica: copiado ? 'E-mail copiado' : 'Copiar e-mail',
                aoClicar: () => app.exigirPermissao(
                  'ajuda.contato',
                  () => copiar(
                    app,
                    email,
                    aviso: 'E-mail copiado.',
                    aoCopiar: aoCopiar,
                  ),
                ),
                largura: TamanhosAjuda.botaoCopiarEmail.largura,
                altura: TamanhosAjuda.botaoCopiarEmail.altura,
                idLayout: TamanhosAjuda.botaoCopiarEmail.id,
              ),
            ],
            justa: true,
            espaco: 4,
            idLayout: 'Grupo.ajuda.email',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Botao(
                'Escrever e-mail',
                icone: Icons.mail_outline,
                aoClicar: () => app.exigirPermissao(
                  'ajuda.contato',
                  () => abrirUrl(app, 'mailto:$email?subject=$assunto'),
                ),
                idLayout: 'Ajuda.botaoEscreverEmail',
              ),
              Botao.contorno(
                'Exportar logs para o suporte',
                icone: Icons.folder_zip_outlined,
                aoClicar: () => exportarLogsSuporte(app),
                idLayout: 'Ajuda.botaoExportarLogs',
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
