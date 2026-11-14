//! A DPS montada, em cartões legíveis para a pré-visualização da emissão: cada grupo do XML
//! (prestador, tomador, serviço, valores, ISSQN, tributos federais, IBS/CBS…) vira um cartão com
//! linhas "rótulo: valor", já com códigos traduzidos e valores formatados. Tudo sai do XML que
//! será transmitido; nada é calculado aqui.
use serde_json::{Value, json};

use crate::catalogo;
use crate::danfse_dados::{cep, documento, dominio, moeda, municipio, percentual, telefone, uf};
use crate::erro::{Erro, Res};
use crate::xml::{self, Elemento};

/// Nome legível de um campo da DPS (o nome da tag quando não está na lista).
fn rotulo(tag: &str, pai: &str) -> String {
    let r = match (tag, pai) {
        ("CST", "piscofins") => "CST do PIS/COFINS",
        ("CST", _) => "CST do IBS/CBS",
        ("tpAmb", _) => "Ambiente",
        ("dhEmi", _) => "Data e hora da emissão",
        ("verAplic", _) => "Versão do aplicativo",
        ("serie", _) => "Série",
        ("nDPS", _) => "Número da DPS",
        ("dCompet", _) => "Competência",
        ("tpEmit", _) => "Emitente",
        ("cMotivoEmisTI", _) => "Motivo da emissão pelo tomador/intermediário",
        ("chNFSeRej", _) => "Chave da NFS-e rejeitada",
        ("cLocEmi", _) => "Município emissor",
        ("finNFSe", _) => "Finalidade",
        ("chSubstda", _) => "Chave da NFS-e substituída",
        ("cMotivo", _) => "Motivo da substituição",
        ("xMotivo", _) => "Descrição do motivo",
        ("CNPJ", _) => "CNPJ",
        ("CPF", _) => "CPF",
        ("NIF", _) => "NIF (exterior)",
        ("cNaoNIF", _) => "Motivo de não informar o NIF",
        ("CAEPF", _) => "CAEPF",
        ("IM", _) => "Inscrição municipal",
        ("xNome", _) => "Nome / razão social",
        ("xFant", _) => "Nome fantasia",
        ("fone", _) => "Telefone",
        ("email", _) => "E-mail",
        ("xLgr", _) => "Logradouro",
        ("nro", _) => "Número",
        ("xCpl", _) => "Complemento",
        ("xBairro", _) => "Bairro",
        ("cMun", _) => "Município",
        ("UF", _) => "UF",
        ("CEP", _) => "CEP",
        ("cPais", _) => "País",
        ("cEndPost", _) => "Código postal",
        ("xCidade", _) => "Cidade",
        ("xEstProvReg", _) => "Estado / província",
        ("opSimpNac", _) => "Simples Nacional",
        ("regApTribSN", _) => "Apuração no Simples",
        ("regEspTrib", _) => "Regime especial",
        ("cLocPrestacao", _) => "Município da prestação",
        ("cPaisPrestacao", _) => "País da prestação",
        ("cTribNac", _) => "Tributação nacional",
        ("cTribMun", _) => "Tributação municipal",
        ("cNBS", _) => "NBS",
        ("cIntContrib", _) => "Código interno",
        ("xDescServ", _) => "Descrição do serviço",
        ("mdPrestacao", _) => "Modo de prestação",
        ("vincPrest", _) => "Vínculo entre as partes",
        ("tpMoeda", _) => "Moeda",
        ("vServMoeda", _) => "Valor em moeda estrangeira",
        ("mecAFComexP", _) => "Apoio ao comércio exterior (prestador)",
        ("mecAFComexT", _) => "Apoio ao comércio exterior (tomador)",
        ("movTempBens", _) => "Movimentação temporária de bens",
        ("nDI", _) => "Declaração de importação",
        ("nRE", _) => "Registro de exportação",
        ("mdic", _) => "Compartilhar com o MDIC",
        ("cObra", _) => "Código da obra (CNO/CEI)",
        ("inscImobFisc", _) => "Inscrição imobiliária",
        ("dtIni", _) => "Início",
        ("dtFim", _) => "Fim",
        ("idAtvEvt", _) => "Identificação do evento",
        ("idDocTec", _) => "Documento de responsabilidade técnica",
        ("docRef", _) => "Documento de referência",
        ("xPed", _) => "Pedido / ordem de serviço",
        ("xItemPed", _) => "Item do pedido",
        ("xInfComp", _) => "Informações complementares",
        ("vReceb", _) => "Valor recebido pelo intermediário",
        ("vServ", _) => "Valor do serviço",
        ("vDescIncond", _) => "Desconto incondicionado",
        ("vDescCond", _) => "Desconto condicionado",
        ("pAjusteBCISSQN", _) => "Ajuste da base do ISSQN (%)",
        ("vAjusteBCISSQN", _) => "Ajuste da base do ISSQN",
        ("tpAjusteBC", _) => "Tipo de ajuste",
        ("xTpAjusteBC", _) => "Descrição do ajuste",
        ("vTotDoc", _) => "Valor total do documento",
        ("vAjusteAplic", _) => "Valor usado no ajuste",
        ("dtEmiDoc", _) => "Emissão do documento",
        ("dtCompDoc", _) => "Competência do documento",
        ("tribISSQN", _) => "Tributação do ISSQN",
        ("cPaisResult", _) => "País do resultado",
        ("tpImunidade", _) => "Tipo de imunidade",
        ("tpSusp", _) => "Exigibilidade suspensa",
        ("nProcesso", _) => "Número do processo",
        ("nBM", _) => "Benefício municipal",
        ("vRedBCBM", _) => "Redução da base (benefício)",
        ("pRedBCBM", _) => "Redução da base (benefício, %)",
        ("tpRetISSQN", _) => "Retenção do ISSQN",
        ("pAliq", _) => "Alíquota do ISSQN",
        ("vBCPisCofins", _) => "Base do PIS/COFINS",
        ("pAliqPis", _) => "Alíquota do PIS",
        ("pAliqCofins", _) => "Alíquota da COFINS",
        ("vPis", _) => "Valor do PIS",
        ("vCofins", _) => "Valor da COFINS",
        ("tpRetPisCofins", _) => "Retenção do PIS/COFINS/CSLL",
        ("vRetCP", _) => "Retenção da CP (INSS)",
        ("vRetIRRF", _) => "Retenção do IRRF",
        ("vRetCSLL", _) => "Retenção da CSLL",
        ("vTotTribFed", _) => "Federais",
        ("vTotTribEst", _) => "Estaduais",
        ("vTotTribMun", _) => "Municipais",
        ("pTotTribFed", _) => "Federais",
        ("pTotTribEst", _) => "Estaduais",
        ("pTotTribMun", _) => "Municipais",
        ("indTotTrib", _) => "Total de tributos",
        ("pTotTribSN", _) => "Simples Nacional (%)",
        ("indFinal", _) => "Uso ou consumo pessoal",
        ("cIndOp", _) => "Indicador da operação",
        ("tpOper", _) => "Tipo de operação",
        ("refNFSe", _) => "NFS-e referenciada",
        ("tpEnteGov", _) => "Ente governamental",
        ("indDest", _) => "Destinatário",
        ("pCopropriedade", _) => "Copropriedade",
        ("vTotOper", _) => "Valor total da operação",
        ("vDescIncondTot", _) => "Desconto incondicionado total",
        ("vDescCondTot", _) => "Desconto condicionado total",
        ("dVencOrig", _) => "Vencimento original",
        ("cCIB", _) => "CIB",
        ("tpAjusteBCLocImoveis", _) => "Parcela fora da base",
        ("xTpAjusteBCLocImoveis", _) => "Descrição da parcela",
        ("vAjusteBCLocImoveis", _) => "Valor fora da base",
        ("cNCMBemMovel", _) => "NCM do bem",
        ("xNCMBemMovel", _) => "Descrição do bem",
        ("qtdNCMBemMovel", _) => "Quantidade",
        ("cClassTrib", _) => "Classificação tributária",
        ("CSTReg", _) => "CST da tributação regular",
        ("cClassTribReg", _) => "Classificação da tributação regular",
        ("cCredPres", _) => "Crédito presumido",
        ("pDifUF", _) => "Diferimento do IBS estadual",
        ("pDifMun", _) => "Diferimento do IBS municipal",
        ("pDifCBS", _) => "Diferimento da CBS",
        ("tipoChaveDFe", _) => "Tipo do documento",
        ("xTipoChaveDFe", _) => "Descrição do documento",
        ("chaveDFe", _) => "Chave do documento",
        ("cMunDocFiscal", _) => "Município do documento",
        ("nDocFiscal", _) => "Número do documento",
        ("xDocFiscal", _) => "Descrição do documento",
        ("nDoc", _) => "Número do documento",
        ("xDoc", _) => "Descrição do documento",
        ("cMunNFSeMun", _) => "Município da nota",
        ("nNFSeMun", _) => "Número da nota",
        ("cVerifNFSeMun", _) => "Código de verificação",
        ("nNFS", _) => "Número da nota",
        ("modNFS", _) => "Modelo",
        ("serieNFS", _) => "Série",
        _ => return tag.to_string(),
    };
    r.to_string()
}

/// Título de um grupo que aparece dentro de um cartão.
fn titulo_grupo(tag: &str) -> String {
    let r = match tag {
        "subst" => "Substituição",
        "end" | "enderNac" => "Endereço",
        "endNac" | "endExt" => "",
        "regTrib" => "Regime tributário",
        "locPrest" => "Local da prestação",
        "cServ" => "Código do serviço",
        "comExt" => "Comércio exterior",
        "obra" => "Obra",
        "atvEvento" => "Evento",
        "infoCompl" => "Informações complementares",
        "gItemPed" => "Itens do pedido",
        "vServPrest" => "Serviço prestado",
        "vDescCondIncond" => "Descontos",
        "vDedRed" | "vAjusteBC" => "Ajuste da base de cálculo",
        "documentos" => "Documentos",
        "docAjusteBC" | "docDedRed" => "Documento",
        "dFeNacional" => "Documento do repositório nacional",
        "docFiscalOutro" => "Outro documento fiscal",
        "docOutro" => "Documento não fiscal",
        "fornec" => "Fornecedor",
        "exigSusp" => "Exigibilidade suspensa",
        "BM" => "Benefício municipal",
        "piscofins" => "PIS/COFINS",
        "vTotTrib" => "Valores aproximados",
        "pTotTrib" => "Percentuais aproximados",
        "gRefNFSe" => "NFS-e referenciadas",
        "dest" => "Destinatário",
        "imovel" => "Imóvel",
        "gLocacao" => "Locação",
        "gUnidImob" => "Unidade imobiliária",
        "gAjusteBCLocImoveis" => "Parcela fora da base",
        "bensMoveis" => "Bem móvel",
        // Dentro do grupo IBSCBS: CST e classificação ficam sob "Tributação".
        "valores" => "Tributação",
        "trib" => "",
        "gIBSCBS" => "Tributação do IBS/CBS",
        "gTribRegular" => "Tributação regular",
        "gDif" => "Diferimento",
        "gReeRepRes" => "Reembolsos e repasses",
        "documento" => "Documento",
        _ => return tag.to_string(),
    };
    r.to_string()
}

/// "Nome/UF (código)" de um município do IBGE.
fn com_municipio(c: &str) -> String {
    let (nome, estado) = municipio(c);
    if nome.is_empty() {
        return c.to_string();
    }
    let estado = if estado.is_empty() { uf(c) } else { estado };
    format!("{nome}/{estado} ({c})")
}

/// "texto da tabela (código)", ou só o código quando a tabela não o conhece.
fn de_tabela(tabela: &str, c: &str) -> String {
    let t = dominio(tabela, c, "");
    if t.is_empty() { c.to_string() } else { t }
}

/// O rótulo de uma lista de opções ("código - descrição") para o código.
fn de_opcoes(opcoes: &catalogo::Opcoes, c: &str) -> String {
    opcoes
        .iter()
        .find(|(k, _)| k == c)
        .map(|(_, r)| r.split_whitespace().collect::<Vec<_>>().join(" "))
        .unwrap_or_else(|| c.to_string())
}

fn data_br(v: &str) -> Option<String> {
    let b = v.as_bytes();
    let ok = b.len() >= 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b[..4]
            .iter()
            .chain(&b[5..7])
            .chain(&b[8..10])
            .all(u8::is_ascii_digit);
    ok.then(|| format!("{}/{}/{}", &v[8..10], &v[5..7], &v[..4]))
}

fn numerico(v: &str) -> bool {
    !v.is_empty() && v.parse::<f64>().is_ok()
}

/// Começa por `letra` seguida de maiúscula (vServ, pAliq…): convenção do leiaute para valores
/// e percentuais.
fn prefixo(tag: &str, letra: char) -> bool {
    let mut cs = tag.chars();
    cs.next() == Some(letra) && cs.next().is_some_and(|c| c.is_ascii_uppercase())
}

/// O valor como o usuário lê: códigos traduzidos, moeda, percentual, documento, data.
fn formatar(tag: &str, pai: &str, v: &str) -> String {
    match tag {
        "CNPJ" | "CPF" => documento(v),
        "fone" => telefone(v),
        "CEP" => cep(v),
        "cMun" | "cLocEmi" | "cLocPrestacao" | "cMunNFSeMun" | "cMunDocFiscal" => com_municipio(v),
        "tpAmb" => de_tabela("TP_AMB", v),
        "tpEmit" => de_tabela("TP_EMIT", v),
        "finNFSe" => de_tabela("FIN_NFSE", v),
        "tribISSQN" => de_tabela("TRIB_ISSQN", v),
        "tpImunidade" => de_tabela("TP_IMUNIDADE", v),
        "tpSusp" => de_tabela("TP_SUSP", v),
        "tpRetISSQN" => de_tabela("TP_RET_ISSQN", v),
        "tpRetPisCofins" => de_tabela("TP_RET_PIS_COFINS", v),
        "opSimpNac" => de_tabela("SIMPLES_OP", v),
        "regApTribSN" => de_tabela("REG_AP_TRIB_SN", v),
        "regEspTrib" => de_tabela("REG_ESP_TRIB", v),
        "cTribNac" => de_opcoes(catalogo::tribnac_options(), v),
        "cNBS" => de_opcoes(catalogo::nbs_options(), v),
        "cIndOp" => de_opcoes(catalogo::indop_options(), v),
        "CST" if pai != "piscofins" => de_opcoes(catalogo::cst_options(), v),
        "CSTReg" => de_opcoes(catalogo::cst_options(), v),
        "cClassTrib" | "cClassTribReg" => {
            let r = catalogo::classtrib_rotulo(v);
            if r.is_empty() { v.to_string() } else { r }
        }
        "indFinal" => match v {
            "0" => "Não".into(),
            "1" => "Sim".into(),
            _ => v.into(),
        },
        "indDest" => match v {
            "0" => "O próprio tomador".into(),
            "1" => "Outra pessoa (grupo Destinatário)".into(),
            _ => v.into(),
        },
        "cMotivo" => match v {
            "01" => "Desenquadramento do Simples Nacional".into(),
            "02" => "Enquadramento no Simples Nacional".into(),
            "03" => "Inclusão retroativa de imunidade/isenção".into(),
            "04" => "Exclusão retroativa de imunidade/isenção".into(),
            "05" => "Rejeição pelo tomador ou intermediário".into(),
            "99" => "Outros".into(),
            _ => v.into(),
        },
        "mdic" => match v {
            "0" => "Não".into(),
            "1" => "Sim".into(),
            _ => v.into(),
        },
        "dhEmi" => {
            let hora: String = v.chars().skip(11).take(8).collect();
            match data_br(v) {
                Some(d) if !hora.is_empty() => format!("{d} {hora}"),
                Some(d) => d,
                None => v.into(),
            }
        }
        _ if prefixo(tag, 'v') && numerico(v) => moeda(v),
        _ if prefixo(tag, 'p') && numerico(v) => percentual(v),
        _ => data_br(v)
            .filter(|_| v.len() == 10)
            .unwrap_or_else(|| v.to_string()),
    }
}

/// Textos longos ocupam a largura do cartão, com o rótulo em cima.
fn longo(tag: &str) -> bool {
    matches!(tag, "xDescServ" | "xInfComp" | "xMotivo") || tag.starts_with("ch")
}

fn tem_elementos(e: &Elemento) -> bool {
    e.elementos().next().is_some()
}

fn texto(e: &Elemento) -> String {
    e.textos().concat().trim().to_string()
}

/// As linhas de um grupo: campos simples viram "rótulo: valor"; subgrupos abrem uma seção
/// (numerada quando o grupo se repete) e seguem dentro dela.
fn linhas(e: &Elemento, pular: &[&str], out: &mut Vec<Value>) {
    let filhos: Vec<&Elemento> = e
        .elementos()
        .filter(|f| !pular.contains(&f.nome.as_str()))
        .collect();
    for f in filhos.iter().filter(|f| !tem_elementos(f)) {
        let v = texto(f);
        if v.is_empty() {
            continue;
        }
        let mut l =
            json!({ "rotulo": rotulo(&f.nome, &e.nome), "valor": formatar(&f.nome, &e.nome, &v) });
        if longo(&f.nome) {
            l["longo"] = json!(true);
        }
        out.push(l);
    }
    let mut vistos: Vec<&str> = Vec::new();
    for f in filhos.iter().filter(|f| tem_elementos(f)) {
        let iguais = filhos.iter().filter(|g| g.nome == f.nome).count();
        let ordem = vistos.iter().filter(|n| **n == f.nome).count() + 1;
        vistos.push(&f.nome);
        let mut titulo = titulo_grupo(&f.nome);
        if iguais > 1 {
            titulo = format!("{titulo} {ordem}");
        }
        let antes = out.len();
        // Grupo logo abaixo de outro título (a unidade imobiliária e o endereço dela): um
        // título só.
        let logo_apos_titulo = out.last().is_some_and(|l| l.get("secao").is_some());
        if !titulo.trim().is_empty() && !logo_apos_titulo {
            out.push(json!({ "secao": titulo.trim() }));
        }
        let depois_titulo = out.len();
        linhas(f, &[], out);
        // Seção sem nenhum campo preenchido: some.
        if out.len() == depois_titulo {
            out.truncate(antes);
        }
    }
}

fn cartao(titulo: &str, icone: &str, e: Option<&Elemento>, pular: &[&str]) -> Option<Value> {
    let e = e?;
    let mut ls = Vec::new();
    linhas(e, pular, &mut ls);
    (!ls.is_empty()).then(|| json!({ "titulo": titulo, "icone": icone, "linhas": ls }))
}

fn valor_em(raiz: &Elemento, caminho: &[&str]) -> String {
    raiz.achar_caminho(caminho).map(texto).unwrap_or_default()
}

/// Lê a DPS (assinada ou não) e devolve `{destaques: [...], cartoes: [...]}`.
pub fn resumo(xml_dps: &[u8]) -> Res<Value> {
    let raiz = xml::ler(xml_dps)?;
    let inf = if raiz.nome == "infDPS" {
        &raiz
    } else {
        raiz.achar("infDPS")
            .ok_or_else(|| Erro::valor("XML sem o grupo infDPS."))?
    };
    let valores = inf.achar("valores");
    let trib = valores.and_then(|v| v.achar("trib"));

    let mut cartoes: Vec<Value> = Vec::new();
    // Em pares, lado a lado na tela: prestador | tomador, identificação | serviço,
    // valores | ISSQN, federais | total, IBS/CBS | intermediário.
    // Identificação: os campos soltos do infDPS e a substituição.
    let soltos = ["prest", "toma", "interm", "serv", "valores", "IBSCBS"];
    let sub = |nome: &str| trib.and_then(|t| t.achar(nome));
    for c in [
        cartao("Prestador", "prestador", inf.achar("prest"), &[]),
        cartao("Tomador", "tomador", inf.achar("toma"), &[]),
        cartao("Identificação da DPS", "dps", Some(inf), &soltos),
        cartao("Serviço", "servico", inf.achar("serv"), &[]),
        cartao("Valores", "valores", valores, &["trib"]),
        cartao("ISSQN (municipal)", "issqn", sub("tribMun"), &[]),
        cartao("Tributos federais", "federais", sub("tribFed"), &[]),
        cartao("Total aproximado de tributos", "total", sub("totTrib"), &[]),
        cartao("IBS e CBS", "ibscbs", inf.achar("IBSCBS"), &[]),
        cartao("Intermediário", "intermediario", inf.achar("interm"), &[]),
    ] {
        cartoes.extend(c);
    }
    // Algum grupo novo do leiaute que esta lista ainda não conhece: aparece com o nome da tag.
    let conhecidos = [
        "prest", "toma", "interm", "serv", "valores", "IBSCBS", "subst",
    ];
    for g in inf
        .elementos()
        .filter(|g| tem_elementos(g) && !conhecidos.contains(&g.nome.as_str()))
    {
        cartoes.extend(cartao(&titulo_grupo(&g.nome), "outro", Some(g), &[]));
    }
    if let Some(t) = trib {
        for g in t
            .elementos()
            .filter(|g| !["tribMun", "tribFed", "totTrib"].contains(&g.nome.as_str()))
        {
            cartoes.extend(cartao(&titulo_grupo(&g.nome), "outro", Some(g), &[]));
        }
    }

    let tomador = valor_em(inf, &["toma", "xNome"]);
    let ctrib = valor_em(inf, &["serv", "cServ", "cTribNac"]);
    let destaques = json!([
        { "rotulo": "Valor do serviço", "valor": formatar("vServ", "", &valor_em(inf, &["valores", "vServPrest", "vServ"])) },
        { "rotulo": "Competência", "valor": formatar("dCompet", "", &valor_em(inf, &["dCompet"])) },
        { "rotulo": "Tomador", "valor": if tomador.is_empty() { "Não identificado".to_string() } else { tomador } },
        { "rotulo": "Tributação nacional", "valor": if ctrib.len() >= 6 {
            format!("{}.{}.{}", &ctrib[..2], &ctrib[2..4], &ctrib[4..])
        } else { ctrib } },
    ]);
    Ok(json!({ "destaques": destaques, "cartoes": cartoes }))
}
