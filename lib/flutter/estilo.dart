/// FONTES e TAMANHOS do programa. Fontes por tipo; larguras e alturas por área.
///
/// As cores ficam em tema.dart, que aplica as fontes. As telas usam as medidas da seção Tamanhos. Os números
/// são pontos a 100%: o Windows multiplica pela escala do monitor (125%, 150%…) e a janela
/// pequena reduz tudo por igual (escala.dart).
library;

/// Incrementada no hot reload para refazer somente os controles visuais em cache.
int revisaoDoEstilo = 0;

/// Tamanho da letra de cada tipo de texto.
abstract final class Letra {
  /// Título de tela ("Emitir NFS-e") e de janela ("Editar cliente").
  static const double titulo = 16;

  /// Subtítulo: título de cartão e de seção ("Backup", "Dados da emissão", "Serviço") e a
  /// faixa do ambiente.
  static const double subtitulo = 14;

  /// Texto comum (e o rótulo das caixas de marcar).
  static const double texto = 12;

  /// O que se digita ou se escolhe nos campos e nas listas suspensas.
  static const double campo = 13;

  /// Rótulo de campo, lista suspensa e checkbox, em qualquer posição.
  static const double rotulo = 12;
  static const double rotuloNaBorda = rotulo;

  /// Itens das listas suspensas e dos menus.
  static const double itemDeMenu = 12;

  /// Botões.
  static const double botao = 12;

  /// Abas.
  static const double aba = 12;

  /// Nomes do trilho lateral (Emitir, Clientes…).
  static const double trilho = 12;

  /// Tabelas: células e cabeçalho.
  static const double tabela = 12;
  static const double cabecalhoDaTabela = 12;

  /// Texto de apoio: observações em cinza, contador e dica dos campos, balões de ajuda.
  static const double apoio = 11;

  /// Letra de máquina: XML, respostas da SEFIN, caminhos de pasta.
  static const double codigo = 11;

  /// A senha mestra, mostrada grande para ser anotada.
  static const double senhaMestra = 20;
}

/// Alturas que não saem do tamanho da letra.
abstract final class Medida {
  /// Altura única dos campos de uma linha e de todas as listas suspensas.
  /// Substitui alturas individuais; caixas de várias linhas mantêm altura própria.
  static const double campo = 40;

  /// Distância padrão entre campos e listas, nas linhas e entre linhas.
  static const double espacoEntreCampos = 12;

  /// Tabelas de Clientes, Consultar e Cofre: altura de cada linha e do cabeçalho.
  static const double linhaDaTabela = 36;
  static const double cabecalhoDaTabela = 38;

  /// Barra de páginas das tabelas: o campo "ir para página" e o seletor "por página".
  static const double controleDePagina = 32;

  /// Botão de ação dentro de uma linha de tabela: lado do quadrado clicável e tamanho do ícone.
  static const double botaoDaLinha = 32;
  static const double iconeDaLinha = 20;
}

// =============================================================================
// TAMANHOS — larguras e alturas dos campos/labels, rótulos e botões, por área.
// =============================================================================
// Em desenvolvimento: abra extras/desenvolver.bat, edite aqui e salve. O hot reload
// aplica automaticamente sem fechar a tela ou sair do usuário.
// Para distribuir o resultado final, use extras/compilar_exe.bat.
// Exemplo: TamanhosEmitir.botaoEmitirNFSE = Tamanho(largura: 180, altura: 44).
// null mantém o tamanho automático original do Flutter (ou o cálculo responsivo
// da tela). Nos campos/listas com largura numérica, mantenha uma largura positiva.
// As medidas são pontos lógicos: seguem a escala do monitor e de escala.dart.
// O campo/label inclui seu rótulo; rotulo* controla um texto independente.
// Repetições têm sufixos 2, 3... porque aparecem em lugares diferentes da área.
// Campos de uma linha e listas usam sempre Medida.campo, inclusive no editor.
// Caixas de várias linhas permitem altura própria. Nos campos expandir:true,
// a largura automática é definida pela linha, até escolher uma largura no editor.
// Dimensões menores que o conteúdo podem cortá-lo; null preserva a altura natural
// dos campos com mensagens de erro, contadores e várias linhas.

class Tamanho {
  const Tamanho({this.largura, this.altura, this.id = ''});
  final String id;
  final double? largura;
  final double? altura;
}

/// Clientes - listagem e pesquisa.
abstract final class TamanhosClientes {
  /// rotulo
  static const rotuloRotulo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosClientes.rotuloRotulo',
  );

  /// Clientes (tomadores)
  static const rotuloClientesTomadores = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosClientes.rotuloClientesTomadores',
  );

  /// Pesquisar cliente
  static const campoPesquisarCliente = Tamanho(
    largura: 380,
    altura: null,
    id: 'TamanhosClientes.campoPesquisarCliente',
  );

  /// Grupo
  static const campoGrupo = Tamanho(
    largura: 220,
    altura: null,
    id: 'TamanhosClientes.campoGrupo',
  );

  /// _cache == null               ? ''               : (total == 0                     ? 'Nenhum cliente encontrado com esse
  static const rotuloCacheNullTotal0NenhumClienteEncontradoCom = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosClientes.rotuloCacheNullTotal0NenhumClienteEncontradoCom',
  );

  /// Editar
  static const botaoEditar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosClientes.botaoEditar',
  );

  /// Adicionar cliente
  static const botaoAdicionarCliente = Tamanho(
    largura: 40,
    altura: 40,
    id: 'TamanhosClientes.botaoAdicionarCliente',
  );

  /// Grupos de clientes
  static const botaoGruposDeClientes = Tamanho(
    largura: 40,
    altura: 40,
    id: 'TamanhosClientes.botaoGruposDeClientes',
  );
}

/// Clientes - cadastro e dados.
abstract final class TamanhosDadosCliente {
  /// "Excluir o serviço '$nomeServ' deste cliente? "             'A exclusão é gravada ao Salvar o cadastro.'
  static const rotuloExcluirOServicoNomeServDesteClienteAExclusao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDadosCliente.rotuloExcluirOServicoNomeServDesteClienteAExclusao',
  );

  /// Digite 'deletar' para confirmar
  static const campoDigiteDeletarParaConfirmar = Tamanho(
    largura: 300,
    altura: null,
    id: 'TamanhosDadosCliente.campoDigiteDeletarParaConfirmar',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDadosCliente.botaoCancelar',
  );

  /// Excluir
  static const botaoExcluir = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDadosCliente.botaoExcluir',
  );

  /// t
  static const rotuloT = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDadosCliente.rotuloT',
  );

  /// Tipo
  static const campoTipo = Tamanho(
    largura: 110,
    altura: null,
    id: 'TamanhosDadosCliente.campoTipo',
  );

  /// Documento
  static const campoDocumento = Tamanho(
    largura: 180,
    altura: null,
    id: 'TamanhosDadosCliente.campoDocumento',
  );

  /// Nome / Razão social
  static const campoNomeRazaoSocial = Tamanho(
    largura: 560,
    altura: null,
    id: 'TamanhosDadosCliente.campoNomeRazaoSocial',
  );

  /// Inscrição municipal
  static const campoInscricaoMunicipal = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosDadosCliente.campoInscricaoMunicipal',
  );

  /// Telefone
  static const campoTelefone = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosDadosCliente.campoTelefone',
  );

  /// E-mail
  static const campoEMail = Tamanho(
    largura: 300,
    altura: null,
    id: 'TamanhosDadosCliente.campoEMail',
  );

  /// Grupo
  static const campoGrupo = Tamanho(
    largura: 240,
    altura: null,
    id: 'TamanhosDadosCliente.campoGrupo',
  );

  /// CEP
  static const campoCEP = Tamanho(
    largura: 120,
    altura: null,
    id: 'TamanhosDadosCliente.campoCEP',
  );

  /// Logradouro
  static const campoLogradouro = Tamanho(
    largura: 440,
    altura: null,
    id: 'TamanhosDadosCliente.campoLogradouro',
  );

  /// Número
  static const campoNumero = Tamanho(
    largura: 100,
    altura: null,
    id: 'TamanhosDadosCliente.campoNumero',
  );

  /// Complemento
  static const campoComplemento = Tamanho(
    largura: 220,
    altura: null,
    id: 'TamanhosDadosCliente.campoComplemento',
  );

  /// Cidade
  static const campoCidade = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosDadosCliente.campoCidade',
  );

  /// UF
  static const campoUF = Tamanho(
    largura: 80,
    altura: null,
    id: 'TamanhosDadosCliente.campoUF',
  );

  /// cMun (IBGE)
  static const campoCMunIBGE = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosDadosCliente.campoCMunIBGE',
  );

  /// Bairro
  static const campoBairro = Tamanho(
    largura: 240,
    altura: null,
    id: 'TamanhosDadosCliente.campoBairro',
  );

  /// null
  static const botaoNull = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDadosCliente.botaoNull',
  );

  /// $nome ($uf)
  static const rotuloNomeUf = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDadosCliente.rotuloNomeUf',
  );

  /// ehCpf                 ? 'Busca automática só existe para CNPJ (CPF não tem consulta pública)'                 : 'Buscar
  static const botaoEhCpfBuscaAutomaticaSoExisteParaCNPJCPF = Tamanho(
    largura: 40,
    altura: 40,
    id: 'TamanhosDadosCliente.botaoEhCpfBuscaAutomaticaSoExisteParaCNPJCPF',
  );

  /// Buscar CEP
  static const botaoBuscarCEP = Tamanho(
    largura: 40,
    altura: 40,
    id: 'TamanhosDadosCliente.botaoBuscarCEP',
  );
}

/// Serviços e tributos - cadastro do cliente.
abstract final class TamanhosServicosTributos {
  /// rotulo
  static const campoRotulo = Tamanho(
    largura: 520,
    altura: null,
    id: 'TamanhosServicosTributos.campoRotulo',
  );

  /// locacao             ? 'Leiaute novo da NFS-e (NT 009). O valor total do aluguel sai do valor da nota e do '
  static const rotuloLocacaoLeiauteNovoDaNFSENT009 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.rotuloLocacaoLeiauteNovoDaNFSENT009',
  );

  /// Município do imóvel (IBGE)
  static const campoMunicipioDoImovelIBGE = Tamanho(
    largura: 230,
    altura: null,
    id: 'TamanhosServicosTributos.campoMunicipioDoImovelIBGE',
  );

  /// Copropriedade
  static const campoCopropriedade = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosServicosTributos.campoCopropriedade',
  );

  /// Vencimento original (AAAA-MM-DD)
  static const campoVencimentoOriginalAAAAMMDD = Tamanho(
    largura: 290,
    altura: null,
    id: 'TamanhosServicosTributos.campoVencimentoOriginalAAAAMMDD',
  );

  /// Remover unidade
  static const botaoRemoverUnidade = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoRemoverUnidade',
  );

  /// Identifique a unidade pelo código CIB ou pelo endereço (um dos dois).
  static const rotuloIdentifiqueAUnidadePeloCodigoCIBOuPelo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.rotuloIdentifiqueAUnidadePeloCodigoCIBOuPelo',
  );

  /// Inscrição imobiliária (IPTU)
  static const campoInscricaoImobiliariaIPTU = Tamanho(
    largura: 250,
    altura: null,
    id: 'TamanhosServicosTributos.campoInscricaoImobiliariaIPTU',
  );

  /// Código CIB
  static const campoCodigoCIB = Tamanho(
    largura: 160,
    altura: null,
    id: 'TamanhosServicosTributos.campoCodigoCIB',
  );

  /// CEP
  static const campoCEP = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosServicosTributos.campoCEP',
  );

  /// Logradouro
  static const campoLogradouro = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosServicosTributos.campoLogradouro',
  );

  /// Número
  static const campoNumero = Tamanho(
    largura: 130,
    altura: null,
    id: 'TamanhosServicosTributos.campoNumero',
  );

  /// Complemento
  static const campoComplemento = Tamanho(
    largura: 230,
    altura: null,
    id: 'TamanhosServicosTributos.campoComplemento',
  );

  /// Bairro
  static const campoBairro = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosServicosTributos.campoBairro',
  );

  /// Parcela fora da base do IBS/CBS
  static const campoParcelaForaDaBaseDoIBSCBS = Tamanho(
    largura: 520,
    altura: null,
    id: 'TamanhosServicosTributos.campoParcelaForaDaBaseDoIBSCBS',
  );

  /// Descrição da parcela
  static const campoDescricaoDaParcela = Tamanho(
    largura: 300,
    altura: null,
    id: 'TamanhosServicosTributos.campoDescricaoDaParcela',
  );

  /// Valor (R$)
  static const campoValorR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosServicosTributos.campoValorR',
  );

  /// Remover
  static const botaoRemover = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoRemover',
  );

  /// Parcela fora da base (IPTU, condomínio…)
  static const botaoParcelaForaDaBaseIPTUCondominio = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoParcelaForaDaBaseIPTUCondominio',
  );

  /// Adicionar unidade
  static const botaoAdicionarUnidade = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoAdicionarUnidade',
  );

  /// Tipo de cobrança
  static const campoTipoDeCobranca = Tamanho(
    largura: 330,
    altura: null,
    id: 'TamanhosServicosTributos.campoTipoDeCobranca',
  );

  /// Descrição da cobrança
  static const campoDescricaoDaCobranca = Tamanho(
    largura: 300,
    altura: null,
    id: 'TamanhosServicosTributos.campoDescricaoDaCobranca',
  );

  /// Valor (R$)
  static const campoValorR2 = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosServicosTributos.campoValorR2',
  );

  /// Detalhar
  static const botaoDetalhar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoDetalhar',
  );

  /// Remover
  static const botaoRemover2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoRemover2',
  );

  /// Tipo de detalhe
  static const campoTipoDeDetalhe = Tamanho(
    largura: 300,
    altura: null,
    id: 'TamanhosServicosTributos.campoTipoDeDetalhe',
  );

  /// Descrição do detalhe
  static const campoDescricaoDoDetalhe = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosServicosTributos.campoDescricaoDoDetalhe',
  );

  /// Valor do item (R$)
  static const campoValorDoItemR = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosServicosTributos.campoValorDoItemR',
  );

  /// Remover item
  static const botaoRemoverItem = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoRemoverItem',
  );

  /// Adicionar cobrança
  static const botaoAdicionarCobranca = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoAdicionarCobranca',
  );

  /// Valor da nota: ${decimalBrl(_somaDe(cobrancas.map((x) => x.valor.text)))}
  static const rotuloValorDaNotaDecimalBrlSomaDeCobrancasMapX = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.rotuloValorDaNotaDecimalBrlSomaDeCobrancasMapX',
  );

  /// Tipo de desconto
  static const campoTipoDeDesconto = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosServicosTributos.campoTipoDeDesconto',
  );

  /// Descrição do desconto
  static const campoDescricaoDoDesconto = Tamanho(
    largura: 330,
    altura: null,
    id: 'TamanhosServicosTributos.campoDescricaoDoDesconto',
  );

  /// Valor (R$)
  static const campoValorR3 = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosServicosTributos.campoValorR3',
  );

  /// Remover
  static const botaoRemover3 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoRemover3',
  );

  /// Adicionar desconto
  static const botaoAdicionarDesconto = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoAdicionarDesconto',
  );

  /// Leiaute novo da NFS-e (NT 009). Informe cada bem locado.
  static const rotuloLeiauteNovoDaNFSENT009Informe = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.rotuloLeiauteNovoDaNFSENT009Informe',
  );

  /// NCM
  static const campoNCM = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosServicosTributos.campoNCM',
  );

  /// Descrição do bem
  static const campoDescricaoDoBem = Tamanho(
    largura: 430,
    altura: null,
    id: 'TamanhosServicosTributos.campoDescricaoDoBem',
  );

  /// Quantidade
  static const campoQuantidade = Tamanho(
    largura: 130,
    altura: null,
    id: 'TamanhosServicosTributos.campoQuantidade',
  );

  /// Remover
  static const botaoRemover4 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoRemover4',
  );

  /// Adicionar bem
  static const botaoAdicionarBem = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoAdicionarBem',
  );

  /// rotulo
  static const campoRotulo2 = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosServicosTributos.campoRotulo2',
  );

  /// Serviço
  static const campoServico = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosServicosTributos.campoServico',
  );

  /// Novo serviço
  static const botaoNovoServico = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoNovoServico',
  );

  /// Nome do serviço
  static const campoNomeDoServico = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosServicosTributos.campoNomeDoServico',
  );

  /// Local prestação (cMun)
  static const campoLocalPrestacaoCMun = Tamanho(
    largura: 200,
    altura: null,
    id: 'TamanhosServicosTributos.campoLocalPrestacaoCMun',
  );

  /// cTribMun
  static const campoCTribMun = Tamanho(
    largura: 160,
    altura: null,
    id: 'TamanhosServicosTributos.campoCTribMun',
  );

  /// Descrição do serviço
  static const campoDescricaoDoServico = Tamanho(
    largura: 540,
    altura: null,
    id: 'TamanhosServicosTributos.campoDescricaoDoServico',
  );

  /// O valor do serviço é informado na tela Emitir, a cada emissão.
  static const rotuloOValorDoServicoEInformadoNaTela = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.rotuloOValorDoServicoEInformadoNaTela',
  );

  /// Situação Tributária do PIS/COFINS (CST)
  static const campoSituacaoTributariaDoPISCOFINSCST = Tamanho(
    largura: 430,
    altura: null,
    id: 'TamanhosServicosTributos.campoSituacaoTributariaDoPISCOFINSCST',
  );

  /// Tipo de retenção do PIS/COFINS/CSLL
  static const campoTipoDeRetencaoDoPISCOFINSCSLL = Tamanho(
    largura: 330,
    altura: null,
    id: 'TamanhosServicosTributos.campoTipoDeRetencaoDoPISCOFINSCSLL',
  );

  /// Tributação do ISSQN
  static const campoTributacaoDoISSQN = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosServicosTributos.campoTributacaoDoISSQN',
  );

  /// Retenção do ISSQN
  static const campoRetencaoDoISSQN = Tamanho(
    largura: 250,
    altura: null,
    id: 'TamanhosServicosTributos.campoRetencaoDoISSQN',
  );

  /// Destinatário é o próprio adquirente?
  static const campoDestinatarioEOProprioAdquirente = Tamanho(
    largura: 370,
    altura: null,
    id: 'TamanhosServicosTributos.campoDestinatarioEOProprioAdquirente',
  );

  /// Indicador da operação (cIndOp)
  static const campoIndicadorDaOperacaoCIndOp = Tamanho(
    largura: 620,
    altura: null,
    id: 'TamanhosServicosTributos.campoIndicadorDaOperacaoCIndOp',
  );

  /// Documento do destinatário
  static const campoDocumentoDoDestinatario = Tamanho(
    largura: 200,
    altura: null,
    id: 'TamanhosServicosTributos.campoDocumentoDoDestinatario',
  );

  /// Número do documento
  static const campoNumeroDoDocumento = Tamanho(
    largura: 230,
    altura: null,
    id: 'TamanhosServicosTributos.campoNumeroDoDocumento',
  );

  /// Nome do destinatário
  static const campoNomeDoDestinatario = Tamanho(
    largura: 430,
    altura: null,
    id: 'TamanhosServicosTributos.campoNomeDoDestinatario',
  );

  /// Município (IBGE)
  static const campoMunicipioIBGE = Tamanho(
    largura: 180,
    altura: null,
    id: 'TamanhosServicosTributos.campoMunicipioIBGE',
  );

  /// CEP
  static const campoCEP2 = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosServicosTributos.campoCEP2',
  );

  /// Logradouro
  static const campoLogradouro2 = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosServicosTributos.campoLogradouro2',
  );

  /// Número
  static const campoNumero2 = Tamanho(
    largura: 130,
    altura: null,
    id: 'TamanhosServicosTributos.campoNumero2',
  );

  /// Complemento
  static const campoComplemento2 = Tamanho(
    largura: 230,
    altura: null,
    id: 'TamanhosServicosTributos.campoComplemento2',
  );

  /// Bairro
  static const campoBairro2 = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosServicosTributos.campoBairro2',
  );

  /// Situação tributária IBS/CBS (CST)
  static const campoSituacaoTributariaIBSCBSCST = Tamanho(
    largura: 380,
    altura: null,
    id: 'TamanhosServicosTributos.campoSituacaoTributariaIBSCBSCST',
  );

  /// Classificação tributária IBS/CBS
  static const campoClassificacaoTributariaIBSCBS = Tamanho(
    largura: 620,
    altura: null,
    id: 'TamanhosServicosTributos.campoClassificacaoTributariaIBSCBS',
  );

  /// Excluir cliente
  static const botaoExcluirCliente = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoExcluirCliente',
  );

  /// Excluir serviço
  static const botaoExcluirServico = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoExcluirServico',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoCancelar',
  );

  /// Editar
  static const botaoEditar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoEditar',
  );

  /// Salvar
  static const botaoSalvar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoSalvar',
  );

  /// Excluir o CADASTRO do cliente '$nome' (${formatarDocumento(doc)})?
  static const rotuloExcluirOCADASTRODoClienteNomeFormatarDocumentoDoc =
      Tamanho(largura: null, altura: null);

  /// As NFS-e já emitidas deste cliente são MANTIDAS — só o cadastro é removido '           '(ele some da lista de clientes e
  static const rotuloAsNFSEJaEmitidasDesteClienteSao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.rotuloAsNFSEJaEmitidasDesteClienteSao',
  );

  /// Digite o documento para confirmar
  static const campoDigiteODocumentoParaConfirmar = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosServicosTributos.campoDigiteODocumentoParaConfirmar',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoCancelar2',
  );

  /// Excluir
  static const botaoExcluir = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosServicosTributos.botaoExcluir',
  );
}

/// Cofre.
abstract final class TamanhosCofre {
  /// Período
  static const campoPeriodo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.campoPeriodo',
  );

  /// Tipo
  static const campoTipo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.campoTipo',
  );

  /// Ambiente
  static const campoAmbiente = Tamanho(
    largura: 210,
    altura: null,
    id: 'TamanhosCofre.campoAmbiente',
  );

  /// Situação
  static const campoSituacao = Tamanho(
    largura: 210,
    altura: null,
    id: 'TamanhosCofre.campoSituacao',
  );

  /// O que exportar
  static const rotuloOQueExportar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloOQueExportar',
  );

  /// Formatos do relatório:
  static const rotuloFormatosDoRelatorio = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloFormatosDoRelatorio',
  );

  /// Separar
  static const rotuloSeparar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloSeparar',
  );

  /// Tudo sai num único arquivo .zip, cada tipo na sua pasta (xml, danfse, '             'eventos e Relatorios). Separando, c
  static const rotuloTudoSaiNumUnicoArquivoZipCadaTipo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloTudoSaiNumUnicoArquivoZipCadaTipo',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoCancelar',
  );

  /// Exportar
  static const botaoExportar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoExportar',
  );

  /// O relatório tem ${milhar(total)} notas. Um PDF com tantas linhas fica '         'pesado e pode demorar bastante para ger
  static const rotuloORelatorioTemMilharTotalNotasUmPDF = Tamanho(
    largura: 440,
    altura: null,
    id: 'TamanhosCofre.rotuloORelatorioTemMilharTotalNotasUmPDF',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoCancelar2',
  );

  /// Gerar PDF mesmo assim
  static const botaoGerarPDFMesmoAssim = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoGerarPDFMesmoAssim',
  );

  /// rotulo
  static const rotuloRotulo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloRotulo',
  );

  /// rotulo
  static const rotuloRotulo2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloRotulo2',
  );

  /// Cofre de NFS-e
  static const rotuloCofreDeNFSE = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloCofreDeNFSE',
  );

  /// _textoSinc
  static const rotuloTextoSinc = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloTextoSinc',
  );

  /// Exportar dados
  static const botaoExportarDados = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoExportarDados',
  );

  /// Todas as notas deste prestador, emitidas e recebidas, guardadas no banco de '           'notas. A DANFSe não é guardada:
  static const rotuloTodasAsNotasDestePrestadorEmitidasERecebidas = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloTodasAsNotasDestePrestadorEmitidasERecebidas',
  );

  /// rotuloDaBusca
  static const campoRotuloDaBusca = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosCofre.campoRotuloDaBusca',
  );

  /// Tipo
  static const campoTipo2 = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosCofre.campoTipo2',
  );

  /// Período
  static const campoPeriodo2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.campoPeriodo2',
  );

  /// Ambiente
  static const campoAmbiente2 = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosCofre.campoAmbiente2',
  );

  /// Situação
  static const campoSituacao2 = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosCofre.campoSituacao2',
  );

  /// _vazio
  static const rotuloVazio = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.rotuloVazio',
  );

  /// Salvar XML
  static const botaoSalvarXML = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoSalvarXML',
  );

  /// Abrir DANFSe (gerada na hora)
  static const botaoAbrirDANFSeGeradaNaHora = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoAbrirDANFSeGeradaNaHora',
  );

  /// Sincronizar
  static const botaoSincronizar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosCofre.botaoSincronizar',
  );
}

/// Configurações.
abstract final class TamanhosConfiguracoes {

  /// Procurar versão nova sozinho
  static const marcarAtualizacaoAutomatica = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.marcarAtualizacaoAutomatica',
  );

  /// Procurar atualizações agora
  static const botaoProcurarAtualizacao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoProcurarAtualizacao',
  );

  /// Texto do cartão "Apoie este projeto"
  static const rotuloApoio = Tamanho(largura: null, altura: null, id: 'TamanhosConfiguracoes.rotuloApoio');

  /// Acessar página GitHub
  static const botaoPaginaGithub = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoPaginaGithub',
  );

  /// t
  static const rotuloT = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloT',
  );

  /// t
  static const rotuloT2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloT2',
  );

  /// O prestador ${formatarDocumento(doc)} e TUDO o que é dele vão ser '             'apagados agora, de vez: cadastro, clien
  static const rotuloOPrestadorFormatarDocumentoDocETUDOOQue = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloOPrestadorFormatarDocumentoDocETUDOOQue',
  );

  /// Isto não pode ser desfeito.
  static const rotuloIstoNaoPodeSerDesfeito = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloIstoNaoPodeSerDesfeito',
  );

  /// Não, voltar
  static const botaoNaoVoltar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoNaoVoltar',
  );

  /// apagando ? 'Apagando…' : 'Sim, deletar tudo'
  static const botaoApagandoApagandoSimDeletarTudo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoApagandoApagandoSimDeletarTudo',
  );

  /// Você vai apagar PERMANENTEMENTE o prestador ${formatarDocumento(doc)} '             'e todos os seus dados: clientes, gr
  static const rotuloVoceVaiApagarPERMANENTEMENTEOPrestadorFormatarDocumentoDoc =
      Tamanho(largura: null, altura: null);

  /// Digite o documento para confirmar
  static const campoDigiteODocumentoParaConfirmar = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosConfiguracoes.campoDigiteODocumentoParaConfirmar',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoCancelar',
  );

  /// Deletar definitivamente
  static const botaoDeletarDefinitivamente = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoDeletarDefinitivamente',
  );

  /// Configurações
  static const rotuloConfiguracoes = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloConfiguracoes',
  );

  /// Editar
  static const botaoEditar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoEditar',
  );

  /// rotuloSalvar
  static const botaoRotuloSalvar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoRotuloSalvar',
  );

  /// Nome de exibição (lista de prestadores)
  static const campoNomeDeExibicaoListaDePrestadores = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosConfiguracoes.campoNomeDeExibicaoListaDePrestadores',
  );

  /// Tipo
  static const campoTipo = Tamanho(
    largura: 110,
    altura: null,
    id: 'TamanhosConfiguracoes.campoTipo',
  );

  /// Documento
  static const campoDocumento = Tamanho(
    largura: 240,
    altura: null,
    id: 'TamanhosConfiguracoes.campoDocumento',
  );

  /// Inscrição municipal
  static const campoInscricaoMunicipal = Tamanho(
    largura: 200,
    altura: null,
    id: 'TamanhosConfiguracoes.campoInscricaoMunicipal',
  );

  /// Razão social / Nome
  static const campoRazaoSocialNome = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosConfiguracoes.campoRazaoSocialNome',
  );

  /// Preencher do certificado
  static const botaoPreencherDoCertificado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoPreencherDoCertificado',
  );

  /// Telefone
  static const campoTelefone = Tamanho(
    largura: 200,
    altura: null,
    id: 'TamanhosConfiguracoes.campoTelefone',
  );

  /// E-mail
  static const campoEMail = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosConfiguracoes.campoEMail',
  );

  /// cLocEmi (município, IBGE)
  static const campoCLocEmiMunicipioIBGE = Tamanho(
    largura: 240,
    altura: null,
    id: 'TamanhosConfiguracoes.campoCLocEmiMunicipioIBGE',
  );

  /// opSimpNac
  static const campoOpSimpNac = Tamanho(
    largura: 210,
    altura: null,
    id: 'TamanhosConfiguracoes.campoOpSimpNac',
  );

  /// regApTribSN
  static const campoRegApTribSN = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosConfiguracoes.campoRegApTribSN',
  );

  /// regEspTrib
  static const campoRegEspTrib = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosConfiguracoes.campoRegEspTrib',
  );

  /// Deletar prestador
  static const botaoDeletarPrestador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoDeletarPrestador',
  );

  /// rotulo
  static const campoRotulo = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosConfiguracoes.campoRotulo',
  );

  /// s
  static const rotuloS = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloS',
  );

  /// _aviso
  static const rotuloAviso = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloAviso',
  );

  /// titular.isEmpty ? '—' : titular
  static const rotuloTitularIsEmptyTitular = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloTitularIsEmptyTitular',
  );

  /// Documento: ${formatarDocumento((_info['documento'] as String?) ?? '')}
  static const rotuloDocumentoFormatarDocumentoInfoDocumentoAsString = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloDocumentoFormatarDocumentoInfoDocumentoAsString',
  );

  /// Validade: $texto
  static const rotuloValidadeTexto = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloValidadeTexto',
  );

  /// Arquivo: $_certNome.pfx
  static const rotuloArquivoCertNomePfx = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloArquivoCertNomePfx',
  );

  /// Certificado $_certNome.pfx presente, mas a senha não está '         'validada no cofre. Reimporte abaixo.
  static const rotuloCertificadoCertNomePfxPresenteMasASenhaNao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloCertificadoCertNomePfxPresenteMasASenhaNao',
  );

  /// Nenhum certificado configurado.
  static const rotuloNenhumCertificadoConfigurado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloNenhumCertificadoConfigurado',
  );

  /// Importar / atualizar certificado
  static const rotuloImportarAtualizarCertificado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloImportarAtualizarCertificado',
  );

  /// Selecionar .pfx
  static const botaoSelecionarPfx = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoSelecionarPfx',
  );

  /// Senha do certificado (.pfx)
  static const campoSenhaDoCertificadoPfx = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosConfiguracoes.campoSenhaDoCertificadoPfx',
  );

  /// Excluir certificado (botão do cartão)
  static const botaoExcluirCertificado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoExcluirCertificado',
  );

  /// Excluir certificado (confirmação)
  static const botaoConfirmarExcluirCertificado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoConfirmarExcluirCertificado',
  );

  /// O certificado … será apagado deste prestador
  static const rotuloExcluirCertificado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloExcluirCertificado',
  );

  /// As notas já emitidas não mudam…
  static const rotuloExcluirCertificadoNota = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloExcluirCertificadoNota',
  );

  /// Ambiente
  static const campoAmbiente = Tamanho(
    largura: 180,
    altura: null,
    id: 'TamanhosConfiguracoes.campoAmbiente',
  );

  /// Servidor SMTP
  static const campoServidorSMTP = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosConfiguracoes.campoServidorSMTP',
  );

  /// Porta
  static const campoPorta = Tamanho(
    largura: 100,
    altura: null,
    id: 'TamanhosConfiguracoes.campoPorta',
  );

  /// Segurança
  static const campoSeguranca = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosConfiguracoes.campoSeguranca',
  );

  /// Usuário SMTP
  static const campoUsuarioSMTP = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosConfiguracoes.campoUsuarioSMTP',
  );

  /// Senha/app password
  static const campoSenhaAppPassword = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosConfiguracoes.campoSenhaAppPassword',
  );

  /// E-mail remetente
  static const campoEMailRemetente = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosConfiguracoes.campoEMailRemetente',
  );

  /// Nome do remetente
  static const campoNomeDoRemetente = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosConfiguracoes.campoNomeDoRemetente',
  );

  /// Assunto
  static const campoAssunto = Tamanho(
    largura: 560,
    altura: null,
    id: 'TamanhosConfiguracoes.campoAssunto',
  );

  /// _htmlVisivel ? 'Ocultar código HTML' : 'Mostrar código HTML'
  static const botaoHtmlVisivelOcultarCodigoHTMLMostrarCodigoHTML = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoHtmlVisivelOcultarCodigoHTMLMostrarCodigoHTML',
  );

  /// Código HTML (gerado pelo editor)
  static const campoCodigoHTMLGeradoPeloEditor = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.campoCodigoHTMLGeradoPeloEditor',
  );

  /// E-mail para teste
  static const campoEMailParaTeste = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosConfiguracoes.campoEMailParaTeste',
  );

  /// _testando ? 'Testando...' : 'Testar'
  static const botaoTestandoTestandoTestar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoTestandoTestandoTestar',
  );

  /// Ambiente
  static const campoAmbiente2 = Tamanho(
    largura: 220,
    altura: null,
    id: 'TamanhosConfiguracoes.campoAmbiente2',
  );

  /// Série
  static const campoSerie = Tamanho(
    largura: 160,
    altura: null,
    id: 'TamanhosConfiguracoes.campoSerie',
  );

  /// Próximo nº DPS
  static const campoProximoNoDPS = Tamanho(
    largura: 180,
    altura: null,
    id: 'TamanhosConfiguracoes.campoProximoNoDPS',
  );

  /// Alterar a numeração pode causar rejeição por duplicidade na SEFIN. Use com cuidado.
  static const rotuloAlterarANumeracaoPodeCausarRejeicaoPorDuplicidade =
      Tamanho(largura: null, altura: null);

  /// Editar
  static const botaoEditar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoEditar2',
  );

  /// Salvar ambiente e numeração
  static const botaoSalvarAmbienteENumeracao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoSalvarAmbienteENumeracao',
  );

  /// Ambientes
  static const campoAmbientes = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosConfiguracoes.campoAmbientes',
  );

  /// Prestadores
  static const campoPrestadores = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosConfiguracoes.campoPrestadores',
  );

  /// Intervalo
  static const campoIntervalo = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosConfiguracoes.campoIntervalo',
  );

  /// Conferir e copiar agora
  static const botaoConferirECopiarAgora = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoConferirECopiarAgora',
  );

  /// rotulo
  static const rotuloRotulo = Tamanho(
    largura: 78,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloRotulo',
  );

  /// valor
  static const rotuloValor = Tamanho(
    largura: 46,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloValor',
  );

  /// titulo
  static const rotuloTitulo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloTitulo',
  );

  /// dica
  static const rotuloDica = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloDica',
  );

  /// Código
  static const campoCodigo = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosConfiguracoes.campoCodigo',
  );

  /// nome
  static const rotuloNome = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloNome',
  );

  /// Temas prontos
  static const rotuloTemasProntos = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloTemasProntos',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoCancelar2',
  );

  /// Editar
  static const botaoEditar3 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoEditar3',
  );

  /// Salvar (Personalização: cores e animação do login)
  static const botaoSalvarCores = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoSalvarCores',
  );

  /// erro
  static const rotuloErro = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloErro',
  );

  /// O que guardar
  static const campoOQueGuardar = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosConfiguracoes.campoOQueGuardar',
  );

  /// Cancelar
  static const botaoCancelar3 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoCancelar3',
  );

  /// Continuar
  static const botaoContinuar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoContinuar',
  );

  /// Este backup foi cifrado com outra chave (outra instalação, ou '             'anterior a uma troca de senha mestra). Digi
  static const rotuloEsteBackupFoiCifradoComOutraChaveOutra = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloEsteBackupFoiCifradoComOutraChaveOutra',
  );

  /// Senha mestra do backup
  static const campoSenhaMestraDoBackup = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosConfiguracoes.campoSenhaMestraDoBackup',
  );

  /// erro
  static const rotuloErro2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloErro2',
  );

  /// Cancelar
  static const botaoCancelar4 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoCancelar4',
  );

  /// Continuar
  static const botaoContinuar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoContinuar2',
  );

  /// Reiniciando o aplicativo…
  static const rotuloReiniciandoOAplicativo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloReiniciandoOAplicativo',
  );

  /// Conferindo e trocando os bancos…
  static const rotuloConferindoETrocandoOsBancos = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloConferindoETrocandoOsBancos',
  );

  /// Isto SUBSTITUI o que está nesta instalação pelo conteúdo do backup'             '${quando.isEmpty ? '' : ' (feito em $qu
  static const rotuloIstoSUBSTITUIOQueEstaNestaInstalacaoPelo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloIstoSUBSTITUIOQueEstaNestaInstalacaoPelo',
  );

  /// origem
  static const rotuloOrigem = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloOrigem',
  );

  /// t
  static const rotuloT3 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloT3',
  );

  /// Em seguida o aplicativo reinicia sozinho.
  static const rotuloEmSeguidaOAplicativoReiniciaSozinho = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloEmSeguidaOAplicativoReiniciaSozinho',
  );

  /// Cancelar
  static const botaoCancelar5 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoCancelar5',
  );

  /// Restaurar
  static const botaoRestaurar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoRestaurar',
  );

  /// Anote esta senha e guarde FORA do computador (papel). '             'Ela NÃO será mostrada novamente:
  static const rotuloAnoteEstaSenhaEGuardeFORADoComputador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloAnoteEstaSenhaEGuardeFORADoComputador',
  );

  /// Senha mestra de recuperação
  static const campoSenhaMestraDeRecuperacao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.campoSenhaMestraDeRecuperacao',
  );

  /// Ao confirmar, a senha mestra atual deixa de valer para este banco. '             'Os backups feitos até agora continuam
  static const rotuloAoConfirmarASenhaMestraAtualDeixaDe = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloAoConfirmarASenhaMestraAtualDeixaDe',
  );

  /// Cancelar
  static const botaoCancelar6 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoCancelar6',
  );

  /// Anotei, trocar agora
  static const botaoAnoteiTrocarAgora = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoAnoteiTrocarAgora',
  );

  /// _pasta
  static const rotuloPasta = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.rotuloPasta',
  );

  /// Fazer backup…
  static const botaoFazerBackup = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoFazerBackup',
  );

  /// Restaurar backup…
  static const botaoRestaurarBackup = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoRestaurarBackup',
  );

  /// Nova senha mestra…
  static const botaoNovaSenhaMestra = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoNovaSenhaMestra',
  );

  /// Copiar
  static const botaoCopiar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConfiguracoes.botaoCopiar',
  );
}

/// Consultar notas.
abstract final class TamanhosConsultar {
  /// texto
  static const rotuloTexto = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloTexto',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoCancelar',
  );

  /// Cancelar o envio da DPS nº ${p['n_dps']} (série ${p['serie']}) de $nome?
  static const rotuloCancelarOEnvioDaDPSNoPN = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloCancelarOEnvioDaDPSNoPN',
  );

  /// Se o número ainda for o último reservado, ele é liberado e a próxima '               'emissão o reutiliza; senão ele fic
  static const rotuloSeONumeroAindaForOUltimoReservado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloSeONumeroAindaForOUltimoReservado',
  );

  /// Voltar
  static const botaoVoltar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoVoltar',
  );

  /// Cancelar envio
  static const botaoCancelarEnvio = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoCancelarEnvio',
  );

  /// Buscar empresa
  static const campoBuscarEmpresa = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosConsultar.campoBuscarEmpresa',
  );

  /// Marcar todas
  static const botaoMarcarTodas = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoMarcarTodas',
  );

  /// Desmarcar todas
  static const botaoDesmarcarTodas = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoDesmarcarTodas',
  );

  /// ${marcadas.length} de ${docs.length} empresa(s) selecionada(s).
  static const rotuloMarcadasLengthDeDocsLengthEmpresaSSelecionada = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloMarcadasLengthDeDocsLengthEmpresaSSelecionada',
  );

  /// … e mais ${filtrados.length - visiveis.length} empresa(s) — refine a '                       'busca para vê-las.
  static const rotuloEMaisFiltradosLengthVisiveisLengthEmpresaS = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloEMaisFiltradosLengthVisiveisLengthEmpresaS',
  );

  /// Nenhuma empresa encontrada com essa busca.
  static const rotuloNenhumaEmpresaEncontradaComEssaBusca = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloNenhumaEmpresaEncontradaComEssaBusca',
  );

  /// Período
  static const campoPeriodo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.campoPeriodo',
  );

  /// Ambiente
  static const campoAmbiente = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.campoAmbiente',
  );

  /// O que exportar
  static const rotuloOQueExportar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloOQueExportar',
  );

  /// Formatos do relatório:
  static const rotuloFormatosDoRelatorio = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloFormatosDoRelatorio',
  );

  /// Tudo sai num único arquivo .zip, cada tipo na sua pasta (xml, danfse, eventos e '             'Relatorios); você escolhe
  static const rotuloTudoSaiNumUnicoArquivoZipCadaTipo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloTudoSaiNumUnicoArquivoZipCadaTipo',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoCancelar2',
  );

  /// Exportar
  static const botaoExportar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoExportar',
  );

  /// O relatório tem ${milhar(total)} notas. Um PDF com tantas linhas fica '         'pesado e pode demorar bastante para ger
  static const rotuloORelatorioTemMilharTotalNotasUmPDF = Tamanho(
    largura: 440,
    altura: null,
    id: 'TamanhosConsultar.rotuloORelatorioTemMilharTotalNotasUmPDF',
  );

  /// Cancelar
  static const botaoCancelar3 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoCancelar3',
  );

  /// Gerar PDF mesmo assim
  static const botaoGerarPDFMesmoAssim = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoGerarPDFMesmoAssim',
  );

  /// O prazo para cancelamento direto desta NFS-e era até $limite '                 '(dia 15 do mês seguinte ao da emissão).
  static const rotuloOPrazoParaCancelamentoDiretoDestaNFSE = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloOPrazoParaCancelamentoDiretoDestaNFSE',
  );

  /// Depois desse prazo a Sefin Nacional não permite o cancelamento direto: '                 'é necessário solicitar Análise
  static const rotuloDepoisDessePrazoASefinNacionalNaoPermite = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloDepoisDessePrazoASefinNacionalNaoPermite',
  );

  /// Entendi
  static const botaoEntendi = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoEntendi',
  );

  /// AMBIENTE: $amb
  static const rotuloAMBIENTEAmb = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloAMBIENTEAmb',
  );

  /// Cliente: ${_ou(rec['tomador_nome'], _ou(rec['tomador'], '—'))}
  static const rotuloClienteOuRecTomadorNomeOuRecTomador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloClienteOuRecTomadorNomeOuRecTomador',
  );

  /// Prazo de estorno: até $limite.
  static const rotuloPrazoDeEstornoAteLimite = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloPrazoDeEstornoAteLimite',
  );

  /// Motivo do cancelamento
  static const campoMotivoDoCancelamento = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosConsultar.campoMotivoDoCancelamento',
  );

  /// Justificativa (mín. 15 caracteres)
  static const campoJustificativaMin15Caracteres = Tamanho(
    largura: 540,
    altura: null,
    id: 'TamanhosConsultar.campoJustificativaMin15Caracteres',
  );

  /// Esta ação transmite o evento de cancelamento à Sefin e não pode ser desfeita.
  static const rotuloEstaAcaoTransmiteOEventoDeCancelamentoA = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloEstaAcaoTransmiteOEventoDeCancelamentoA',
  );

  /// Cancelar
  static const botaoCancelar4 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoCancelar4',
  );

  /// Confirmar estorno
  static const botaoConfirmarEstorno = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoConfirmarEstorno',
  );

  /// mensagem
  static const rotuloMensagem = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloMensagem',
  );

  /// null
  static const botaoNull = Tamanho(
    largura: null,
    altura: 28,
    id: 'TamanhosConsultar.botaoNull',
  );

  /// Resposta da Sefin
  static const rotuloRespostaDaSefin = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloRespostaDaSefin',
  );

  /// OK
  static const botaoOK = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosConsultar.botaoOK',
  );

  /// texto.length > 8000 ? texto.substring(0, 8000) : texto
  static const rotuloTextoLength8000TextoSubstring08000Texto = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloTextoLength8000TextoSubstring08000Texto',
  );

  /// rotulo
  static const rotuloRotulo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloRotulo',
  );

  /// Enviar por e-mail
  static const rotuloEnviarPorEMail = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloEnviarPorEMail',
  );

  /// Enviar por e-mail
  static const rotuloEnviarPorEMail2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloEnviarPorEMail2',
  );

  /// rotulo
  static const rotuloRotulo2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloRotulo2',
  );

  /// Consultar NFS-e emitidas
  static const rotuloConsultarNFSEEmitidas = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloConsultarNFSEEmitidas',
  );

  /// Exportar dados
  static const botaoExportarDados = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoExportarDados',
  );

  /// Existem NFS-e pendentes de envio: $_pendN pendente(s)
  static const rotuloExistemNFSEPendentesDeEnvioPendNPendente = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloExistemNFSEPendentesDeEnvioPendNPendente',
  );

  /// texto
  static const rotuloTexto2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloTexto2',
  );

  /// Reenviar agora
  static const botaoReenviarAgora = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoReenviarAgora',
  );

  /// rotuloDaBusca
  static const campoRotuloDaBusca = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosConsultar.campoRotuloDaBusca',
  );

  /// Período
  static const campoPeriodo2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.campoPeriodo2',
  );

  /// Ambiente
  static const campoAmbiente2 = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosConsultar.campoAmbiente2',
  );

  /// Empresa
  static const campoEmpresa = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosConsultar.campoEmpresa',
  );

  /// _vazio
  static const rotuloVazio = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.rotuloVazio',
  );

  /// aceita                       ? 'Concluir download (nota já aceita)'                       : 'Reenviar agora
  static const botaoAceitaConcluirDownloadNotaJaAceitaReenviarAgora = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoAceitaConcluirDownloadNotaJaAceitaReenviarAgora',
  );

  /// Baixar DPS (XML assinado)
  static const botaoBaixarDPSXMLAssinado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoBaixarDPSXMLAssinado',
  );

  /// Baixar XML
  static const botaoBaixarXML = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoBaixarXML',
  );

  /// Abrir DANFSe (PDF)
  static const botaoAbrirDANFSePDF = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoAbrirDANFSePDF',
  );

  /// Atualizar a lista
  static const botaoAtualizarALista = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosConsultar.botaoAtualizarALista',
  );
}

/// Emitir NFS-e.
abstract final class TamanhosEmitir {
  /// Trocar… (procurador que assina)
  static const botaoTrocarProcurador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoTrocarProcurador',
  );

  /// Cancelar (escolha do procurador)
  static const botaoCancelarProcurador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoCancelarProcurador',
  );

  /// Exibir assinatura no XML (pré-visualização)
  static const marcarExibirAssinatura = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.marcarExibirAssinatura',
  );

  /// Copiar (XML da pré-visualização)
  static const botaoCopiarXmlDps = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoCopiarXmlDps',
  );

  /// Baixar XML da DPS (pré-visualização)
  static const botaoBaixarXmlDps = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoBaixarXmlDps',
  );

  /// Nome do único procurador, ao lado do "Assinar com certificado de procurador"
  static const rotuloProcuradorUnico = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloProcuradorUnico',
  );

  /// O procurador escolhido antes não está mais cadastrado…
  static const rotuloProcuradorSumiu = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloProcuradorSumiu',
  );

  /// Assinada pelo procurador: … (confirmação da emissão)
  static const rotuloAssinadaPeloProcurador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloAssinadaPeloProcurador',
  );

  /// Cliente: ${_ou(rec['tomador_nome'], _ou(rec['tomador'], '—'))}
  static const rotuloClienteOuRecTomadorNomeOuRecTomador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloClienteOuRecTomadorNomeOuRecTomador',
  );

  /// A substituição emite uma NOTA NOVA vinculada a esta; ao ser aceita, '             'a SEFIN cancela a nota antiga por sub
  static const rotuloASubstituicaoEmiteUmaNOTANOVAVinculadaA = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloASubstituicaoEmiteUmaNOTANOVAVinculadaA',
  );

  /// Motivo da substituição
  static const campoMotivoDaSubstituicao = Tamanho(
    largura: 430,
    altura: null,
    id: 'TamanhosEmitir.campoMotivoDaSubstituicao',
  );

  /// Justificativa (mín. 15 caracteres)
  static const campoJustificativaMin15Caracteres = Tamanho(
    largura: 540,
    altura: null,
    id: 'TamanhosEmitir.campoJustificativaMin15Caracteres',
  );

  /// Ao continuar, você vai para a tela Emitir com o cliente desta nota '             'carregado — corrija o que precisa e cl
  static const rotuloAoContinuarVoceVaiParaATelaEmitir = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloAoContinuarVoceVaiParaATelaEmitir',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoCancelar',
  );

  /// Continuar para a emissão
  static const botaoContinuarParaAEmissao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoContinuarParaAEmissao',
  );

  /// Valor
  static const rotuloValor = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloValor',
  );

  /// AMBIENTE: $amb
  static const rotuloAMBIENTEAmb = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloAMBIENTEAmb',
  );

  /// SUBSTITUIÇÃO da NFS-e nº ${_ou(subst!['nNFSe'], '—')} — '                   'a nota antiga será cancelada por substituiç
  static const rotuloSUBSTITUICAODaNFSENoOuSubstNNFSe = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloSUBSTITUICAODaNFSENoOuSubstNNFSe',
  );

  /// Cliente: $xnome
  static const rotuloClienteXnome = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloClienteXnome',
  );

  /// Serviço: ${form['nome']}
  static const rotuloServicoFormNome = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloServicoFormNome',
  );

  /// Valor do serviço: ${vBrl.isEmpty ? 'R\$ ${form['vServ']}' : vBrl}
  static const rotuloValorDoServicoVBrlIsEmptyRFormVServ = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloValorDoServicoVBrlIsEmptyRFormVServ',
  );

  /// Desconto incondicionado: ${decimalBrl(form['vDescIncond'] as String)}
  static const rotuloDescontoIncondicionadoDecimalBrlFormVDescIncondAsString =
      Tamanho(largura: null, altura: null);

  /// Desconto condicionado: ${decimalBrl(form['vDescCond'] as String)}
  static const rotuloDescontoCondicionadoDecimalBrlFormVDescCondAsString =
      Tamanho(largura: null, altura: null);

  /// Esta ação transmite a DPS à SEFIN e não pode ser desfeita.'               '${producao ? '' : ' É uma emissão de teste.'}
  static const rotuloEstaAcaoTransmiteADPSASEFINE = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloEstaAcaoTransmiteADPSASEFINE',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoCancelar2',
  );

  /// producao ? 'Confirmar e emitir' : 'Confirmar e emitir ($amb)'
  static const botaoProducaoConfirmarEEmitirConfirmarEEmitirAmb = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoProducaoConfirmarEEmitirConfirmarEEmitirAmb',
  );

  /// Motivo: $ex
  static const rotuloMotivoEx = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloMotivoEx',
  );

  /// A DPS nº $nDps (série $serie) já está pronta e assinada. '             'O que deseja fazer?
  static const rotuloADPSNoNDpsSerieSerieJaEsta = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloADPSNoNDpsSerieSerieJaEsta',
  );

  /// • Adicionar à fila: o número fica RESERVADO, a nota aparece na '             'Consulta como PENDENTE (linha laranja) e o
  static const rotuloAdicionarAFilaONumeroFicaRESERVADOA = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloAdicionarAFilaONumeroFicaRESERVADOA',
  );

  /// • Descartar: nada é gravado aqui. Como a SEFIN não respondeu, NÃO '             'há como saber se ela chegou a processar
  static const rotuloDescartarNadaEGravadoAquiComoASEFIN = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloDescartarNadaEGravadoAquiComoASEFIN',
  );

  /// Descartar envio
  static const botaoDescartarEnvio = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoDescartarEnvio',
  );

  /// Adicionar à fila
  static const botaoAdicionarAFila = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoAdicionarAFila',
  );

  /// NFS-e nº $numero emitida!
  static const rotuloNFSENoNumeroEmitida = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloNFSENoNumeroEmitida',
  );

  /// Chave de acesso:\n$chave
  static const rotuloChaveDeAcessoNChave = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloChaveDeAcessoNChave',
  );

  /// Esta NFS-e JÁ EXISTIA na SEFIN com o nº $numero (envio anterior). Os '                   'dados acima vieram do XML ofic
  static const rotuloEstaNFSEJAEXISTIANaSEFINCom = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloEstaNFSEJAEXISTIANaSEFINCom',
  );

  /// danfseIndisponivel
  static const rotuloDanfseIndisponivel = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloDanfseIndisponivel',
  );

  /// Abrir Consulta Pública
  static const botaoAbrirConsultaPublica = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoAbrirConsultaPublica',
  );

  /// Copiar chave
  static const botaoCopiarChave = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoCopiarChave',
  );

  /// E-mail enviado para ${email['to']}.
  static const rotuloEMailEnviadoParaEmailTo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloEMailEnviadoParaEmailTo',
  );

  /// E-mail automático não foi enviado: '                       '${email['error'] ?? 'erro desconhecido'}
  static const rotuloEMailAutomaticoNaoFoiEnviadoEmailError = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloEMailAutomaticoNaoFoiEnviadoEmailError',
  );

  /// OK
  static const botaoOK = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoOK',
  );

  /// A nota nº $numeroEmitida EXISTE na SEFIN e o número já foi '                   'consumido. Emitir de novo geraria uma NO
  static const rotuloANotaNoNumeroEmitidaEXISTENaSEFINE = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloANotaNoNumeroEmitidaEXISTENaSEFINE',
  );

  /// mensagem
  static const rotuloMensagem = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloMensagem',
  );

  /// Detalhes técnicos
  static const rotuloDetalhesTecnicos = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloDetalhesTecnicos',
  );

  /// detalhes!
  static const rotuloDetalhes = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloDetalhes',
  );

  /// Abrir log
  static const botaoAbrirLog = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoAbrirLog',
  );

  /// t
  static const rotuloT = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloT',
  );

  /// Dados da emissão
  static const rotuloDadosDaEmissao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloDadosDaEmissao',
  );

  /// Descrição do serviço
  static const campoDescricaoDoServico = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.campoDescricaoDoServico',
  );

  /// Valor do serviço
  static const campoValorDoServico = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosEmitir.campoValorDoServico',
  );

  /// Desconto incondicionado
  static const campoDescontoIncondicionado = Tamanho(
    largura: 240,
    altura: null,
    id: 'TamanhosEmitir.campoDescontoIncondicionado',
  );

  /// Desconto condicionado
  static const campoDescontoCondicionado = Tamanho(
    largura: 240,
    altura: null,
    id: 'TamanhosEmitir.campoDescontoCondicionado',
  );

  /// Condomínio: o valor e os descontos são a soma das cobranças e dos descontos lançados '               'no cadastro do cli
  static const rotuloCondominioOValorEOsDescontosSaoA = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloCondominioOValorEOsDescontosSaoA',
  );

  /// Emitir NFS-e
  static const rotuloEmitirNFSE = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloEmitirNFSE',
  );

  /// _textoSubst
  static const rotuloTextoSubst = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.rotuloTextoSubst',
  );

  /// Cancelar substituição
  static const botaoCancelarSubstituicao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoCancelarSubstituicao',
  );

  /// Cliente (tomador)
  static const campoClienteTomador = Tamanho(
    largura: 600,
    altura: null,
    id: 'TamanhosEmitir.campoClienteTomador',
  );

  /// Grupo
  static const campoGrupo = Tamanho(
    largura: 220,
    altura: null,
    id: 'TamanhosEmitir.campoGrupo',
  );

  /// Serviço
  static const campoServico = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosEmitir.campoServico',
  );

  /// Pré-visualizar (sem enviar)
  static const botaoPreVisualizarSemEnviar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoPreVisualizarSemEnviar',
  );

  /// Emitir NFS-e
  static const botaoEmitirNFSE = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoEmitirNFSE',
  );

  /// _tribTravado ? 'Editar tributos' : 'Salvar tributos'
  static const botaoTribTravadoEditarTributosSalvarTributos = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosEmitir.botaoTribTravadoEditarTributosSalvarTributos',
  );
}

/// Serviços e tributos - expansão da emissão.
abstract final class TamanhosTributosEmissao {
  /// rotulo
  static const campoRotulo = Tamanho(
    largura: 520,
    altura: null,
    id: 'TamanhosTributosEmissao.campoRotulo',
  );

  /// Mais campos do serviço / tributação
  static const rotuloMaisCamposDoServicoTributacao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosTributosEmissao.rotuloMaisCamposDoServicoTributacao',
  );

  /// Local de prestação (cMun)
  static const campoLocalDePrestacaoCMun = Tamanho(
    largura: 200,
    altura: null,
    id: 'TamanhosTributosEmissao.campoLocalDePrestacaoCMun',
  );

  /// cTribMun
  static const campoCTribMun = Tamanho(
    largura: 210,
    altura: null,
    id: 'TamanhosTributosEmissao.campoCTribMun',
  );

  /// Situação Tributária do PIS/COFINS (CST)
  static const campoSituacaoTributariaDoPISCOFINSCST = Tamanho(
    largura: 430,
    altura: null,
    id: 'TamanhosTributosEmissao.campoSituacaoTributariaDoPISCOFINSCST',
  );

  /// Tipo de retenção do PIS/COFINS/CSLL
  static const campoTipoDeRetencaoDoPISCOFINSCSLL = Tamanho(
    largura: 330,
    altura: null,
    id: 'TamanhosTributosEmissao.campoTipoDeRetencaoDoPISCOFINSCSLL',
  );

  /// Tributação do ISSQN
  static const campoTributacaoDoISSQN = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosTributosEmissao.campoTributacaoDoISSQN',
  );

  /// Retenção do ISSQN
  static const campoRetencaoDoISSQN = Tamanho(
    largura: 250,
    altura: null,
    id: 'TamanhosTributosEmissao.campoRetencaoDoISSQN',
  );

  /// Destinatário é o próprio adquirente?
  static const campoDestinatarioEOProprioAdquirente = Tamanho(
    largura: 370,
    altura: null,
    id: 'TamanhosTributosEmissao.campoDestinatarioEOProprioAdquirente',
  );

  /// Indicador da operação (cIndOp)
  static const campoIndicadorDaOperacaoCIndOp = Tamanho(
    largura: 620,
    altura: null,
    id: 'TamanhosTributosEmissao.campoIndicadorDaOperacaoCIndOp',
  );

  /// Documento do destinatário
  static const campoDocumentoDoDestinatario = Tamanho(
    largura: 200,
    altura: null,
    id: 'TamanhosTributosEmissao.campoDocumentoDoDestinatario',
  );

  /// Número do documento
  static const campoNumeroDoDocumento = Tamanho(
    largura: 230,
    altura: null,
    id: 'TamanhosTributosEmissao.campoNumeroDoDocumento',
  );

  /// Nome do destinatário
  static const campoNomeDoDestinatario = Tamanho(
    largura: 430,
    altura: null,
    id: 'TamanhosTributosEmissao.campoNomeDoDestinatario',
  );

  /// Município (IBGE)
  static const campoMunicipioIBGE = Tamanho(
    largura: 180,
    altura: null,
    id: 'TamanhosTributosEmissao.campoMunicipioIBGE',
  );

  /// CEP
  static const campoCEP = Tamanho(
    largura: 140,
    altura: null,
    id: 'TamanhosTributosEmissao.campoCEP',
  );

  /// Logradouro
  static const campoLogradouro = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosTributosEmissao.campoLogradouro',
  );

  /// Número
  static const campoNumero = Tamanho(
    largura: 130,
    altura: null,
    id: 'TamanhosTributosEmissao.campoNumero',
  );

  /// Complemento
  static const campoComplemento = Tamanho(
    largura: 230,
    altura: null,
    id: 'TamanhosTributosEmissao.campoComplemento',
  );

  /// Bairro
  static const campoBairro = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosTributosEmissao.campoBairro',
  );

  /// Situação tributária IBS/CBS (CST)
  static const campoSituacaoTributariaIBSCBSCST = Tamanho(
    largura: 380,
    altura: null,
    id: 'TamanhosTributosEmissao.campoSituacaoTributariaIBSCBSCST',
  );

  /// Classificação tributária IBS/CBS
  static const campoClassificacaoTributariaIBSCBS = Tamanho(
    largura: 620,
    altura: null,
    id: 'TamanhosTributosEmissao.campoClassificacaoTributariaIBSCBS',
  );

  /// PIS
  static const campoPIS = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoPIS',
  );

  /// COFINS
  static const campoCOFINS = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoCOFINS',
  );

  /// Base (R\$)
  static const campoBaseR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoBaseR',
  );

  /// PIS (R\$)
  static const campoPISR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoPISR',
  );

  /// COFINS (R\$)
  static const campoCOFINSR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoCOFINSR',
  );

  /// IRRF
  static const campoIRRF = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoIRRF',
  );

  /// CSLL
  static const campoCSLL = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoCSLL',
  );

  /// IRRF (R\$)
  static const campoIRRFR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoIRRFR',
  );

  /// CSLL (R\$)
  static const campoCSLLR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoCSLLR',
  );

  /// Contribuições Sociais Retidas (R\$)
  static const campoContribuicoesSociaisRetidasR = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosTributosEmissao.campoContribuicoesSociaisRetidasR',
  );

  /// Federal
  static const campoFederal = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoFederal',
  );

  /// Estadual
  static const campoEstadual = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoEstadual',
  );

  /// Municipal
  static const campoMunicipal = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoMunicipal',
  );

  /// Federal (R\$)
  static const campoFederalR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoFederalR',
  );

  /// Estadual (R\$)
  static const campoEstadualR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoEstadualR',
  );

  /// Municipal (R\$)
  static const campoMunicipalR = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosTributosEmissao.campoMunicipalR',
  );

  /// Endereço e identificação do cliente são editados na aba Clientes.
  static const rotuloEnderecoEIdentificacaoDoClienteSaoEditadosNa = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosTributosEmissao.rotuloEnderecoEIdentificacaoDoClienteSaoEditadosNa',
  );
}

/// Grupos de clientes.
abstract final class TamanhosGrupos {
  /// g
  static const rotuloG = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.rotuloG',
  );

  /// Nenhum grupo cadastrado.
  static const rotuloNenhumGrupoCadastrado = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.rotuloNenhumGrupoCadastrado',
  );

  /// Para adicionar, renomear ou remover grupos, clique em Editar.
  static const rotuloParaAdicionarRenomearOuRemoverGruposCliqueEm = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.rotuloParaAdicionarRenomearOuRemoverGruposCliqueEm',
  );

  /// Adicionar grupo
  static const botaoAdicionarGrupo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoAdicionarGrupo',
  );

  /// Editar
  static const botaoEditar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoEditar',
  );

  /// Nome do grupo
  static const campoNomeDoGrupo = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosGrupos.campoNomeDoGrupo',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoCancelar',
  );

  /// Adicionar
  static const botaoAdicionar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoAdicionar',
  );

  /// Novo nome
  static const campoNovoNome = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosGrupos.campoNovoNome',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoCancelar2',
  );

  /// Salvar
  static const botaoSalvar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoSalvar',
  );

  /// Remover o grupo "$nome"? Os clientes desse grupo ficarão sem grupo.
  static const rotuloRemoverOGrupoNomeOsClientesDesseGrupo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.rotuloRemoverOGrupoNomeOsClientesDesseGrupo',
  );

  /// Cancelar
  static const botaoCancelar3 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoCancelar3',
  );

  /// Remover
  static const botaoRemover = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoRemover',
  );

  /// Renomear
  static const botaoRenomear = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoRenomear',
  );

  /// Remover
  static const botaoRemover2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosGrupos.botaoRemover2',
  );
}

/// Seleção de período.
abstract final class TamanhosPeriodo {
  /// ${widget.dia.day}
  static const rotuloWidgetDiaDay = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPeriodo.rotuloWidgetDiaDay',
  );

  /// titulo
  static const campoTitulo = Tamanho(
    largura: 286,
    altura: null,
    id: 'TamanhosPeriodo.campoTitulo',
  );

  /// ${_meses[m - 1]} $ano
  static const rotuloMesesM1Ano = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosPeriodo.rotuloMesesM1Ano',
  );

  /// x
  static const rotuloX = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPeriodo.rotuloX',
  );

  /// invertido() ? 'A data final é anterior à inicial.' : ''
  static const rotuloInvertidoADataFinalEAnteriorAInicial = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPeriodo.rotuloInvertidoADataFinalEAnteriorAInicial',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPeriodo.botaoCancelar',
  );

  /// Confirmar
  static const botaoConfirmar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPeriodo.botaoConfirmar',
  );

  /// Mês anterior
  static const botaoMesAnterior = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPeriodo.botaoMesAnterior',
  );

  /// Próximo mês
  static const botaoProximoMes = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPeriodo.botaoProximoMes',
  );
}

/// Diálogos gerais.
abstract final class TamanhosDialogos {
  /// Senha de nível $n
  static const rotuloSenhaDeNivelN = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.rotuloSenhaDeNivelN',
  );

  /// Senha
  static const campoSenha = Tamanho(
    largura: 260,
    altura: null,
    id: 'TamanhosDialogos.campoSenha',
  );

  /// erro
  static const rotuloErro = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.rotuloErro',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.botaoCancelar',
  );

  /// OK
  static const botaoOK = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.botaoOK',
  );

  /// Trocar o prestador ativo para:\n$rotulo?
  static const rotuloTrocarOPrestadorAtivoParaNRotulo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.rotuloTrocarOPrestadorAtivoParaNRotulo',
  );

  /// As telas (emissão, clientes, consultas) passam a mostrar os dados '               'do prestador escolhido.
  static const rotuloAsTelasEmissaoClientesConsultasPassamAMostrar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.rotuloAsTelasEmissaoClientesConsultasPassamAMostrar',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.botaoCancelar2',
  );

  /// Trocar
  static const botaoTrocar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.botaoTrocar',
  );

  /// Fechar (Esc)
  static const botaoFecharEsc = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosDialogos.botaoFecharEsc',
  );
}

/// Navegação e barra superior.
abstract final class TamanhosNavegacao {
  /// Nenhum prestador liberado para este usuário
  static const rotuloNenhumPrestadorLiberadoParaEsteUsuario = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.rotuloNenhumPrestadorLiberadoParaEsteUsuario',
  );

  /// Para operar, peça a um usuário de nível 3 para liberar um prestador para você.
  static const rotuloParaOperarPecaAUmUsuarioDeNivel = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.rotuloParaOperarPecaAUmUsuarioDeNivel',
  );

  /// Prestador
  static const campoPrestador = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosNavegacao.campoPrestador',
  );

  /// AMBIENTE: ${producao ? 'PRODUÇÃO' : 'HOMOLOGAÇÃO'}
  static const rotuloAMBIENTEProducaoPRODUCAOHOMOLOGACAO = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.rotuloAMBIENTEProducaoPRODUCAOHOMOLOGACAO',
  );

  /// Configurações
  static const rotuloConfiguracoes = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.rotuloConfiguracoes',
  );

  /// Ajuda (abaixo de Configurações, no trilho)
  static const rotuloAjuda = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.rotuloAjuda',
  );

  /// a.msg
  static const rotuloAMsg = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.rotuloAMsg',
  );

  /// Adicionar prestador
  static const botaoAdicionarPrestador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.botaoAdicionarPrestador',
  );

  /// Usuários
  static const botaoUsuarios = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosNavegacao.botaoUsuarios',
  );
}

/// Menu do usuário.
abstract final class TamanhosMenuUsuario {
  /// texto ?? 'Nível $nivel'
  static const rotuloTextoNivelNivel = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloTextoNivelNivel',
  );

  /// Menu
  static const rotuloMenu = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloMenu',
  );

  /// Sair
  static const rotuloSair = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloSair',
  );

  /// nome.toUpperCase()
  static const rotuloNomeToUpperCase = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloNomeToUpperCase',
  );

  /// Clique para escolher uma imagem
  static const rotuloCliqueParaEscolherUmaImagem = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloCliqueParaEscolherUmaImagem',
  );

  /// textoHover
  static const rotuloTextoHover = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloTextoHover',
  );

  /// Arraste a imagem para posicionar; use o zoom para aproximar.
  static const rotuloArrasteAImagemParaPosicionarUseOZoom = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloArrasteAImagemParaPosicionarUseOZoom',
  );

  /// null
  static const botaoNull = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.botaoNull',
  );

  /// Remover foto
  static const rotuloRemoverFoto = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.rotuloRemoverFoto',
  );

  /// Salvar
  static const botaoSalvar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.botaoSalvar',
  );

  /// Senha atual
  static const campoSenhaAtual = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosMenuUsuario.campoSenhaAtual',
  );

  /// Nova senha
  static const campoNovaSenha = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosMenuUsuario.campoNovaSenha',
  );

  /// Confirmar nova senha
  static const campoConfirmarNovaSenha = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosMenuUsuario.campoConfirmarNovaSenha',
  );

  /// Salvar
  static const botaoSalvar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosMenuUsuario.botaoSalvar2',
  );
}

/// Cadastro de prestadores.
abstract final class TamanhosPrestadores {
  /// Tipo
  static const campoTipo = Tamanho(
    largura: 120,
    altura: null,
    id: 'TamanhosPrestadores.campoTipo',
  );

  /// Documento
  static const campoDocumento = Tamanho(
    largura: 240,
    altura: null,
    id: 'TamanhosPrestadores.campoDocumento',
  );

  /// Razão social / Nome
  static const campoRazaoSocialNome = Tamanho(
    largura: 420,
    altura: null,
    id: 'TamanhosPrestadores.campoRazaoSocialNome',
  );

  /// Certificado digital
  static const rotuloCertificadoDigital = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPrestadores.rotuloCertificadoDigital',
  );

  /// dicaCert()
  static const rotuloDicaCert = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPrestadores.rotuloDicaCert',
  );

  /// Selecionar .pfx
  static const botaoSelecionarPfx = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPrestadores.botaoSelecionarPfx',
  );

  /// caminhoCert.isEmpty ? 'Nenhum certificado selecionado.' : caminhoCert
  static const rotuloCaminhoCertIsEmptyNenhumCertificadoSelecionadoCaminhoCert =
      Tamanho(largura: null, altura: null);

  /// Senha do certificado (.pfx)
  static const campoSenhaDoCertificadoPfx = Tamanho(
    largura: 280,
    altura: null,
    id: 'TamanhosPrestadores.campoSenhaDoCertificadoPfx',
  );

  /// Depois de criar: preencha os tributos do prestador e confira os '           'dados em Configurações › Prestador.
  static const rotuloDepoisDeCriarPreenchaOsTributosDoPrestador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPrestadores.rotuloDepoisDeCriarPreenchaOsTributosDoPrestador',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPrestadores.botaoCancelar',
  );

  /// Criar prestador
  static const botaoCriarPrestador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosPrestadores.botaoCriarPrestador',
  );

  /// Buscar CNPJ
  static const botaoBuscarCNPJ = Tamanho(
    largura: 40,
    altura: 40,
    id: 'TamanhosPrestadores.botaoBuscarCNPJ',
  );
}

/// Registros.
abstract final class TamanhosRegistros {
  /// null
  static const botaoNull = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.botaoNull',
  );

  /// Registros (${app.naoLidos})
  static const rotuloRegistrosAppNaoLidos = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.rotuloRegistrosAppNaoLidos',
  );

  /// _dataHora(r.ts)
  static const rotuloDataHoraRTs = Tamanho(
    largura: 130,
    altura: null,
    id: 'TamanhosRegistros.rotuloDataHoraRTs',
  );

  /// r.msg
  static const rotuloRMsg = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.rotuloRMsg',
  );

  /// null
  static const botaoNull2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.botaoNull2',
  );

  /// Consultar
  static const rotuloConsultar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.rotuloConsultar',
  );

  /// Nenhum registro nesta sessão.
  static const rotuloNenhumRegistroNestaSessao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.rotuloNenhumRegistroNestaSessao',
  );

  /// Período
  static const campoPeriodo = Tamanho(
    largura: 170,
    altura: null,
    id: 'TamanhosRegistros.campoPeriodo',
  );

  /// Buscar no texto
  static const campoBuscarNoTexto = Tamanho(
    largura: 250,
    altura: null,
    id: 'TamanhosRegistros.campoBuscarNoTexto',
  );

  /// Buscar
  static const botaoBuscar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.botaoBuscar',
  );

  /// resumo
  static const rotuloResumo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.rotuloResumo',
  );

  /// Nenhum registro no período.
  static const rotuloNenhumRegistroNoPeriodo = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.rotuloNenhumRegistroNoPeriodo',
  );

  /// quando(r['quando'] as String)
  static const rotuloQuandoRQuandoAsString = Tamanho(
    largura: 130,
    altura: null,
    id: 'TamanhosRegistros.rotuloQuandoRQuandoAsString',
  );

  /// r['msg'] as String
  static const rotuloRMsgAsString = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.rotuloRMsgAsString',
  );

  /// Fechar (Esc)
  static const botaoFecharEsc = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosRegistros.botaoFecharEsc',
  );
}

/// Usuários.
abstract final class TamanhosUsuarios {
  /// t
  static const rotuloT = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloT',
  );

  /// Nenhum usuário cadastrado ainda.
  static const rotuloNenhumUsuarioCadastradoAinda = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloNenhumUsuarioCadastradoAinda',
  );

  /// Página ${pagina + 1} de $paginas — $total usuário(s)
  static const rotuloPaginaPagina1DePaginasTotalUsuarioS = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloPaginaPagina1DePaginasTotalUsuarioS',
  );

  /// Adicionar usuário
  static const botaoAdicionarUsuario = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoAdicionarUsuario',
  );

  /// Login (só letras)
  static const campoLoginSoLetras = Tamanho(
    largura: 180,
    altura: null,
    id: 'TamanhosUsuarios.campoLoginSoLetras',
  );

  /// Nome
  static const campoNome = Tamanho(
    largura: 220,
    altura: null,
    id: 'TamanhosUsuarios.campoNome',
  );

  /// Nível
  static const campoNivel = Tamanho(
    largura: 150,
    altura: null,
    id: 'TamanhosUsuarios.campoNivel',
  );

  /// Senha
  static const campoSenha = Tamanho(
    largura: 160,
    altura: null,
    id: 'TamanhosUsuarios.campoSenha',
  );

  /// Confirmar
  static const campoConfirmar = Tamanho(
    largura: 160,
    altura: null,
    id: 'TamanhosUsuarios.campoConfirmar',
  );

  /// Prestadores que este usuário pode operar:
  static const rotuloPrestadoresQueEsteUsuarioPodeOperar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloPrestadoresQueEsteUsuarioPodeOperar',
  );

  /// Nenhum prestador cadastrado. Crie um prestador antes.
  static const rotuloNenhumPrestadorCadastradoCrieUmPrestadorAntes = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloNenhumPrestadorCadastradoCrieUmPrestadorAntes',
  );

  /// Adicionar usuário
  static const botaoAdicionarUsuario2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoAdicionarUsuario2',
  );

  /// Prestadores que este usuário pode alternar/operar.
  static const rotuloPrestadoresQueEsteUsuarioPodeAlternarOperar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloPrestadoresQueEsteUsuarioPodeAlternarOperar',
  );

  /// nomes[doc] ?? formatarDocumento(doc)
  static const rotuloNomesDocFormatarDocumentoDoc = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloNomesDocFormatarDocumentoDoc',
  );

  /// Este usuário ainda não opera nenhum prestador.
  static const rotuloEsteUsuarioAindaNaoOperaNenhumPrestador = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloEsteUsuarioAindaNaoOperaNenhumPrestador',
  );

  /// Liberar outro prestador
  static const campoLiberarOutroPrestador = Tamanho(
    largura: 380,
    altura: null,
    id: 'TamanhosUsuarios.campoLiberarOutroPrestador',
  );

  /// Liberar
  static const botaoLiberar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoLiberar',
  );

  /// "Apagar DEFINITIVAMENTE o usuário '${alvo.login.toUpperCase()}' "             '(${alvo.nome.toUpperCase()})?'
  static const rotuloApagarDEFINITIVAMENTEOUsuarioAlvoLoginToUpperCaseAlvo =
      Tamanho(largura: null, altura: null);

  /// Isso remove o usuário do sistema (não é apenas desativar) e não pode ser desfeito.
  static const rotuloIssoRemoveOUsuarioDoSistemaNaoE = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.rotuloIssoRemoveOUsuarioDoSistemaNaoE',
  );

  /// Cancelar
  static const botaoCancelar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoCancelar',
  );

  /// Excluir
  static const botaoExcluir = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoExcluir',
  );

  /// Nova senha de ${alvo.login.toUpperCase()}
  static const campoNovaSenhaDeAlvoLoginToUpperCase = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosUsuarios.campoNovaSenhaDeAlvoLoginToUpperCase',
  );

  /// Cancelar
  static const botaoCancelar2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoCancelar2',
  );

  /// Salvar
  static const botaoSalvar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoSalvar',
  );

  /// Promover
  static const botaoPromover = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoPromover',
  );

  /// Rebaixar
  static const botaoRebaixar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoRebaixar',
  );

  /// Ativar/Desativar
  static const botaoAtivarDesativar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoAtivarDesativar',
  );

  /// Redefinir senha
  static const botaoRedefinirSenha = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoRedefinirSenha',
  );

  /// Prestadores que pode operar
  static const botaoPrestadoresQuePodeOperar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoPrestadoresQuePodeOperar',
  );

  /// Excluir (apagar) usuário
  static const botaoExcluirApagarUsuario = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoExcluirApagarUsuario',
  );

  /// Página anterior
  static const botaoPaginaAnterior = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoPaginaAnterior',
  );

  /// Próxima página
  static const botaoProximaPagina = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoProximaPagina',
  );

  /// Remover acesso
  static const botaoRemoverAcesso = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosUsuarios.botaoRemoverAcesso',
  );
}

/// Acesso e recuperação de senha.
abstract final class TamanhosAcesso {
  /// Usuário
  static const campoUsuario = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosAcesso.campoUsuario',
  );

  /// Senha
  static const campoSenha = Tamanho(
    largura: 320,
    altura: null,
    id: 'TamanhosAcesso.campoSenha',
  );

  ///
  static const botaoGeral = Tamanho(
    largura: 320,
    altura: 52,
    id: 'TamanhosAcesso.botaoGeral',
  );

  /// Senha mestra
  static const campoSenhaMestra = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosAcesso.campoSenhaMestra',
  );

  ///
  static const botaoGeral2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosAcesso.botaoGeral2',
  );

  /// Senha mestra
  static const campoSenhaMestra2 = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosAcesso.campoSenhaMestra2',
  );

  /// Novo login do master (opcional, só letras)
  static const campoNovoLoginDoMasterOpcionalSoLetras = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosAcesso.campoNovoLoginDoMasterOpcionalSoLetras',
  );

  /// Novo nome do master (opcional)
  static const campoNovoNomeDoMasterOpcional = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosAcesso.campoNovoNomeDoMasterOpcional',
  );

  /// Nova senha do master
  static const campoNovaSenhaDoMaster = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosAcesso.campoNovaSenhaDoMaster',
  );

  /// Confirmar nova senha
  static const campoConfirmarNovaSenha = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosAcesso.campoConfirmarNovaSenha',
  );

  /// Seu nome
  static const campoSeuNome = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosAcesso.campoSeuNome',
  );

  /// Usuário (login, só letras)
  static const campoUsuarioLoginSoLetras = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosAcesso.campoUsuarioLoginSoLetras',
  );

  /// Senha
  static const campoSenha2 = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosAcesso.campoSenha2',
  );

  /// Confirmar senha
  static const campoConfirmarSenha = Tamanho(
    largura: 340,
    altura: null,
    id: 'TamanhosAcesso.campoConfirmarSenha',
  );

  ///
  static const botaoGeral3 = Tamanho(
    largura: 360,
    altura: null,
    id: 'TamanhosAcesso.botaoGeral3',
  );

  /// Senha mestra de recuperação
  static const campoSenhaMestraDeRecuperacao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosAcesso.campoSenhaMestraDeRecuperacao',
  );

  ///
  static const botaoGeral4 = Tamanho(
    largura: null,
    altura: 46,
    id: 'TamanhosAcesso.botaoGeral4',
  );

  /// Acao
  static const botaoAcao = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosAcesso.botaoAcao',
  );

  /// Voltar
  static const botaoVoltar = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosAcesso.botaoVoltar',
  );

  /// Redefinir
  static const botaoRedefinir = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosAcesso.botaoRedefinir',
  );

  /// Acao
  static const botaoAcao2 = Tamanho(
    largura: null,
    altura: null,
    id: 'TamanhosAcesso.botaoAcao2',
  );
}
