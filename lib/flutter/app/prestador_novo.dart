/// Janela "Adicionar prestador" e as peças de documento/busca que outros cadastros usam.
library;

import 'package:flutter/material.dart';

import '../kit/arquivos.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import '../kit/svg_suave.dart';
import '../editor_layout.dart';
import 'app.dart';

/// Botão de busca com ícone próprio (CNPJ / CEP): fundo leve no hover + mãozinha.
class BotaoBusca extends StatefulWidget {
  const BotaoBusca(
    this.texto,
    this.svg,
    this.aoClicar, {
    super.key,
    this.idLayout,
    this.inerte = false,
    this.largura = 40,
    this.altura = 40,
  });
  final String texto;
  final String svg;
  final VoidCallback aoClicar;
  final double? largura;
  final double? altura;

  /// Apagado, sem clique e sem mãozinha.
  final bool inerte;

  final String? idLayout;

  @override
  State<BotaoBusca> createState() => _BotaoBuscaState();
}

class _BotaoBuscaState extends State<BotaoBusca> {
  bool _dentro = false;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: (widget.inerte || travado(context)) ? 0.45 : 1.0,
    child: _botao(context),
  );

  Widget _botao(BuildContext context) => alvoLayout(
    context,
    Gesto(
      cursor: (widget.inerte || travado(context))
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      aoTocar: (widget.inerte || travado(context)) ? null : widget.aoClicar,
      child: Ct(
        largura:
            ajusteLayout(context, widget.idLayout).largura ?? widget.largura,
        altura: ajusteLayout(context, widget.idLayout).altura ?? widget.altura,
        raio: BorderRadius.circular(8),
        alinhar: Alignment.center,
        cor: _dentro ? Colors.indigo.shade100 : Colors.transparent,
        dica: widget.texto,
        desabilitado: widget.inerte,
        animar: const Duration(milliseconds: 120),
        curva: Curves.easeOut,
        aoPairar: (dentro) => setState(() => _dentro = dentro),
        child: IconeSvgSuave('assets/images/${widget.svg}'),
      ),
    ),
    id: widget.idLayout,
    nome: widget.texto,
  );
}

/// O que o tipo de documento aceita: CPF = 11 dígitos; CNPJ = 14 posições (dígitos ou, no
/// CNPJ alfanumérico, letras nas 12 primeiras).
String mascaraDocumento(String valor, String? tipo) => ja<String>(
  'texto.mascara_documento',
  {'valor': valor, 'tipo_doc': (tipo == null || tipo.isEmpty) ? 'CNPJ' : tipo},
);

const tiposDocumento = [Opcao('CNPJ', 'CNPJ'), Opcao('CPF', 'CPF')];

void abrirNovoPrestador(App app) {
  late final Dialogo d;
  late final Suspensa tipo;
  late final TextEditingController doc, nome, senhaCert;
  var caminhoCert = '';
  var procurador = false;

  String dicaCert() => procurador
      ? 'Certificado de quem tem procuração eletrônica do prestador na Receita '
            '(ex.: imobiliária, contador) ou do responsável legal (e-CPF). A nota sai '
            'com os dados do prestador; a SEFIN confere a procuração no envio.'
      : (tipo.valor ?? 'CNPJ') == 'CPF'
      ? 'Para CPF é necessário um certificado de PESSOA FÍSICA (e-CPF) '
            'do MESMO CPF — o sistema confere o documento do certificado.'
      : 'O certificado (e-CNPJ A1) deve ser do MESMO CNPJ informado — '
            'o sistema confere o documento do certificado.';

  void buscar() {
    final numero = soDoc(doc.text);
    if (numero.length != 14) {
      app.toast('Informe um CNPJ (14 caracteres) para buscar.', erro: true);
      return;
    }
    app.toast('Consultando CNPJ…');
    app.emSegundoPlano(() async {
      Map dados;
      try {
        dados = await chamar<Map>('consulta.cnpj', {'cnpj': numero});
      } catch (e) {
        app.toast('Falha ao consultar CNPJ: $e', erro: true);
        return;
      }
      final x = (dados['xNome'] as String?) ?? '';
      if (x.isNotEmpty) {
        app.toast('Nome preenchido pelo CNPJ.');
        nome.text = x.toUpperCase();
        d.atualizar();
      }
    });
  }

  Future<void> escolherCert() async {
    String? caminho;
    try {
      caminho = await escolherArquivo(
        titulo: 'Selecionar certificado (.pfx) do prestador',
        extensoes: const ['pfx'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (caminho != null) {
      caminhoCert = caminho;
      d.atualizar();
    }
  }

  Future<void> salvar() async {
    if (caminhoCert.isEmpty) {
      app.toast('Selecione o certificado (.pfx) do prestador.', erro: true);
      return;
    }
    if (senhaCert.text.trim().isEmpty) {
      app.toast('Informe a senha do certificado.', erro: true);
      return;
    }
    final tipoDoc = tipo.valor ?? 'CNPJ';
    String criado;
    try {
      criado = await chamar<String>(
        'cadastro.create_prestador_com_certificado',
        {
          'documento': doc.text,
          'xNome': nome.text.toUpperCase(),
          'tipo_doc': tipoDoc,
          'caminho': caminhoCert,
          'senha': senhaCert.text.trim(),
          'procurador': procurador,
        },
      );
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    registrar(
      'Prestador criado: ${formatarDocumento(criado)} ($tipoDoc) já com certificado'
      '${procurador ? ' (marcado como de procurador)' : ''}',
    );
    app.ddPrestador.opcoes = [
      for (final p in jaLista('cadastro.list_prestadores'))
        Opcao(p['documento'] as String, p['display'] as String),
    ];
    app.ddPrestador.por(criado);
    app.fecharDialogo();
    app.trocarPrestador(criado);
    app.toast(
      'Prestador ${formatarDocumento(criado)} criado com certificado. '
      'Preencha os tributos e confira os dados em Configurações › Prestador.',
    );
  }

  d = Dialogo(
    titulo: (_) => textoTitulo('Adicionar prestador'),
    largura: 560,
    conteudo: (_) => col(
      [
        lin(
          [
            ListaSuspensa(
              estado: tipo,
              rotulo: 'Tipo',
              largura: TamanhosPrestadores.campoTipo.largura!,
              aoSelecionar: (_) {
                doc.text = mascaraDocumento(doc.text, tipo.valor);
                d.atualizar();
              },
              altura: TamanhosPrestadores.campoTipo.altura,
              idLayout: 'TamanhosPrestadores.campoTipo',
            ),
            CampoTexto(
              controle: doc,
              rotulo: 'Documento',
              largura: TamanhosPrestadores.campoDocumento.largura,
              mascara: (s) => mascaraDocumento(s, tipo.valor),
              altura: TamanhosPrestadores.campoDocumento.altura,
              idLayout: 'TamanhosPrestadores.campoDocumento',
            ),
            BotaoBusca(
              'Buscar CNPJ',
              'cnpj_find.svg',
              buscar,
              largura: TamanhosPrestadores.botaoBuscarCNPJ.largura,
              altura: TamanhosPrestadores.botaoBuscarCNPJ.altura,
              idLayout: 'TamanhosPrestadores.botaoBuscarCNPJ',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.prestador_novo.lin.1',
        ),
        lin(
          [
            CampoTexto(
              controle: nome,
              rotulo: 'Razão social / Nome',
              largura: TamanhosPrestadores.campoRazaoSocialNome.largura,
              altura: TamanhosPrestadores.campoRazaoSocialNome.altura,
              idLayout: 'TamanhosPrestadores.campoRazaoSocialNome',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.prestador_novo.lin.2',
        ),
        divisor(),
        Tx(
          'Certificado digital',
          peso: FontWeight.bold,
          largura: TamanhosPrestadores.rotuloCertificadoDigital.largura,
          altura: TamanhosPrestadores.rotuloCertificadoDigital.altura,
          idLayout: 'TamanhosPrestadores.rotuloCertificadoDigital',
        ),
        Marcar(
          valor: procurador,
          rotulo: 'Adicionar certificado digital como procurador do prestador',
          dica:
              'Marque quando o certificado for de outra pessoa ou empresa com '
              'procuração eletrônica do prestador (ou do responsável legal). Ele fica '
              'em Configurações › Certificado, no cartão do procurador.',
          aoMudar: (v) {
            procurador = v == true;
            d.atualizar();
          },
          rente: true,
          idLayout: 'TamanhosPrestadores.marcarCertificadoProcurador',
        ),
        Tx(
          dicaCert(),
          tam: Letra.apoio,
          cor: Colors.grey.shade600,
          largura: TamanhosPrestadores.rotuloDicaCert.largura,
          altura: TamanhosPrestadores.rotuloDicaCert.altura,
          idLayout: 'TamanhosPrestadores.rotuloDicaCert',
        ),
        lin(
          [
            Botao.contorno(
              'Selecionar .pfx',
              icone: Icons.folder_open,
              aoClicar: escolherCert,
              largura: TamanhosPrestadores.botaoSelecionarPfx.largura,
              altura: TamanhosPrestadores.botaoSelecionarPfx.altura,
              idLayout: 'TamanhosPrestadores.botaoSelecionarPfx',
            ),
            Tx(
              caminhoCert.isEmpty
                  ? 'Nenhum certificado selecionado.'
                  : caminhoCert,
              tam: Letra.apoio,
              cor: Colors.grey.shade700,
              largura: TamanhosPrestadores
                  .rotuloCaminhoCertIsEmptyNenhumCertificadoSelecionadoCaminhoCert
                  .largura,
              altura: TamanhosPrestadores
                  .rotuloCaminhoCertIsEmptyNenhumCertificadoSelecionadoCaminhoCert
                  .altura,
              idLayout: 'TamanhosPrestadores.rotuloCaminhoCertIsEmptyNenhumCertificadoSelecionadoCaminhoCert',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.prestador_novo.lin.3',
        ),
        lin(
          [
            CampoTexto(
              controle: senhaCert,
              rotulo: 'Senha do certificado (.pfx)',
              largura: TamanhosPrestadores.campoSenhaDoCertificadoPfx.largura,
              senha: true,
              revelarSenha: true,
              altura: TamanhosPrestadores.campoSenhaDoCertificadoPfx.altura,
              idLayout: 'TamanhosPrestadores.campoSenhaDoCertificadoPfx',
            ),
          ],
          quebra: true,
          idLayout: 'Grupo.prestador_novo.lin.4',
        ),
        Tx(
          'Depois de criar: preencha os tributos do prestador e confira os '
          'dados em Configurações › Prestador.',
          tam: Letra.apoio,
          cor: Colors.grey.shade600,
          largura: TamanhosPrestadores
              .rotuloDepoisDeCriarPreenchaOsTributosDoPrestador
              .largura,
          altura: TamanhosPrestadores
              .rotuloDepoisDeCriarPreenchaOsTributosDoPrestador
              .altura,
          idLayout: 'TamanhosPrestadores.rotuloDepoisDeCriarPreenchaOsTributosDoPrestador',
        ),
      ],
      justa: true,
      espaco: 12,
      idLayout: 'Grupo.prestador_novo.col.1',
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: app.fecharDialogo,
        largura: TamanhosPrestadores.botaoCancelar.largura,
        altura: TamanhosPrestadores.botaoCancelar.altura,
        idLayout: 'TamanhosPrestadores.botaoCancelar',
      ),
      Botao(
        'Criar prestador',
        icone: Icons.save,
        aoClicar: salvar,
        largura: TamanhosPrestadores.botaoCriarPrestador.largura,
        altura: TamanhosPrestadores.botaoCriarPrestador.altura,
        idLayout: 'TamanhosPrestadores.botaoCriarPrestador',
      ),
    ],
    idLayout: 'Janela.prestador_novo.Dialogo.1',
  );
  tipo = d.suspensa(valor: 'CNPJ', opcoes: tiposDocumento);
  doc = d.texto();
  nome = d.texto();
  senhaCert = d.texto();
  app.mostrarDialogo(d);
}
