//! Qual LEIAUTE da DPS vale para uma nota.
//!
//! EM VIGOR: o schema de `[schemas] versao`, em configs/paths.ini — o que a SEFIN valida hoje.
//!
//! NOVO (Reforma Tributária, Nota Técnica 009): o schema de `[schemas] versao_nt009`. Só nele
//! existem a locação de imóveis (códigos de tributação 99.03.xx) e a de bens móveis (99.04.01);
//! por isso uma nota com um desses códigos é SEMPRE montada no leiaute novo. As demais só passam
//! para ele quando `[schemas] nt009_aceito_em` diz que a SEFIN já o aceita no ambiente da nota —
//! até lá saem exatamente como sempre.
//!
//! O cadastro guarda os campos nos caminhos do leiaute em vigor; `para_o_novo` os leva para onde
//! o release 1 os quer: finNFSe sobe para <infDPS>; CST e cClassTrib sobem de <gIBSCBS>
//! para <trib>. indDest e dest continuam em IBSCBS neste release.
use std::str::FromStr;

use rust_decimal::{Decimal, RoundingStrategy};

use crate::erro::{Erro, Res};
use crate::ini::Ini;
use crate::texto::only_digits;
use crate::{validacao, xml};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Leiaute {
    EmVigor,
    Novo,
    /// NT 009 completa, ainda provisória: somente prévia de funcionalidades futuras.
    Futuro,
}

/// Locação, cessão onerosa ou arrendamento de bem imóvel (subitem 99.03).
pub fn e_imovel(ctribnac: &str) -> bool {
    only_digits(ctribnac).starts_with("9903")
}

/// Locação de bem móvel (99.04.01).
pub fn e_bem_movel(ctribnac: &str) -> bool {
    only_digits(ctribnac) == "990401"
}

/// Operações condominiais (subitem 99.05).
pub fn e_condominio(ctribnac: &str) -> bool {
    only_digits(ctribnac).starts_with("9905")
}

/// Código de tributação que só existe no leiaute novo.
pub fn so_no_novo(ctribnac: &str) -> bool {
    only_digits(ctribnac).starts_with("9902")
        || e_imovel(ctribnac)
        || e_bem_movel(ctribnac)
        || e_condominio(ctribnac)
}

fn opcao(nome: &str) -> String {
    validacao::paths_ini()
        .map(|(_, ini)| ini.val("schemas", nome, "").trim().to_string())
        .unwrap_or_default()
}

/// A pasta (versão) do schema do leiaute novo.
pub fn versao_do_novo() -> Res<String> {
    let v = opcao("versao_nt009");
    if v.is_empty() {
        return Err(Erro::valor(
            "O leiaute novo da NFS-e (Nota Técnica 009) não está configurado: falta [schemas] versao_nt009 em \
             configs/paths.ini.",
        ));
    }
    Ok(v)
}

pub fn versao_do_futuro() -> Res<String> {
    let v = opcao("versao_nt009_futuro");
    if v.is_empty() {
        return Err(Erro::valor(
            "Falta [schemas] versao_nt009_futuro para a prévia da NT 009 completa.",
        ));
    }
    Ok(v)
}

/// O release 1 de 20/10/2026 inclui 99.02 a 99.04; condomínio (99.05) ainda não.
pub fn transmissao_liberada(ctribnac: &str, ambiente: &str) -> bool {
    !e_condominio(ctribnac) && aceito_pela_sefin(ambiente)
}

/// A SEFIN já aceita o leiaute novo neste ambiente ("1" produção, "2" homologação)?
pub fn aceito_pela_sefin(ambiente: &str) -> bool {
    match opcao("nt009_aceito_em").to_lowercase().as_str() {
        "ambos" => true,
        "homologacao" | "homologação" => ambiente.trim() == "2",
        "producao" | "produção" => ambiente.trim() == "1",
        _ => false,
    }
}

/// O que dizer quando a nota só existe no leiaute novo e a SEFIN ainda não o aceita no ambiente.
pub fn recusa(ambiente: &str) -> String {
    format!(
        "Esta nota usa o leiaute novo da NFS-e (Nota Técnica 009), que a SEFIN ainda não aceita em {}. \
         Ela pode ser pré-visualizada, mas não transmitida. Quando a SEFIN liberar, ajuste \
         [schemas] nt009_aceito_em em configs/paths.ini.",
        if ambiente.trim() == "1" {
            "Produção"
        } else {
            "Homologação"
        }
    )
}

/// O leiaute em que a nota desta config final é montada.
pub fn da_config(cfg: &Ini) -> Leiaute {
    let codigo = cfg.val("serv.cServ", "cTribNac", "");
    if e_condominio(&codigo) {
        Leiaute::Futuro
    } else if so_no_novo(&codigo) || aceito_pela_sefin(&cfg.val("dps", "tpAmb", "")) {
        Leiaute::Novo
    } else {
        Leiaute::EmVigor
    }
}

/// Distingue produção, release 1 oficial e prévia da NT 009 completa pelos filhos de infDPS.
pub fn do_xml(xml_bytes: &[u8]) -> Leiaute {
    xml::ler(xml_bytes)
        .ok()
        .and_then(|raiz| {
            raiz.achar("infDPS").map(|inf| {
                if inf.achar("indDest").is_some() {
                    Leiaute::Futuro
                } else if inf.achar("finNFSe").is_some() {
                    Leiaute::Novo
                } else {
                    Leiaute::EmVigor
                }
            })
        })
        .unwrap_or(Leiaute::EmVigor)
}

/// Adaptação à especificação completa ainda não implantada, somente para prévia.
pub fn para_o_futuro(cfg: &Ini) -> Ini {
    let mut novo = Ini::novo();
    for secao in cfg.secoes() {
        let destino = match secao.strip_prefix("IBSCBS.dest") {
            Some(resto) if resto.is_empty() || resto.starts_with('.') => format!("dest{resto}"),
            _ => secao.to_string(),
        };
        novo.garantir_secao(&destino);
        for (opcao, valor) in cfg.itens(secao) {
            let onde = match (secao, opcao) {
                ("IBSCBS", "finNFSe" | "indDest") => "dps",
                ("IBSCBS.valores.trib.gIBSCBS", "CST" | "cClassTrib") => "IBSCBS.valores.trib",
                _ => destino.as_str(),
            };
            novo.por(onde, opcao, valor);
        }
    }
    // Obrigatórios em <infDPS> no leiaute novo, com ou sem o grupo IBS/CBS.
    for (opcao, padrao) in [("finNFSe", "0"), ("indDest", "0")] {
        if novo.val("dps", opcao, "").trim().is_empty() {
            novo.por("dps", opcao, padrao);
        }
    }
    novo
}

/// Adaptação ao XSD oficial PRODREST de 20/10/2026, sem alterar o cadastro armazenado.
pub fn para_o_novo(cfg: &Ini) -> Res<Ini> {
    let mut novo = Ini::novo();
    for secao in cfg.secoes() {
        if (secao.starts_with("valores.vDedRed.documentos")
            || secao.starts_with("IBSCBS.valores.gReeRepRes"))
            && !cfg.itens(secao).is_empty()
        {
            // O leiaute antigo não informa necessariamente vTotDoc. Inventá-lo mudaria a base.
            return Err(Erro::valor(
                "NT 009 release 1: recadastre os documentos de dedução/reembolso em valores.vAjusteBC.documentos.docAjusteBC, com vTotDoc e vAjusteAplic. Os valores antigos foram preservados.",
            ));
        }
        for (opcao, valor) in cfg.itens(secao) {
            let (onde, nome) = match (secao, opcao) {
                ("IBSCBS", "finNFSe") => ("dps", opcao),
                ("IBSCBS.valores.trib.gIBSCBS", "CST" | "cClassTrib") => {
                    ("IBSCBS.valores.trib", opcao)
                }
                ("valores.vDedRed", "pDR") => ("valores.vAjusteBC", "pAjusteBCISSQN"),
                ("valores.vDedRed", "vDR") => ("valores.vAjusteBC", "vAjusteBCISSQN"),
                _ => (secao, opcao),
            };
            novo.por(onde, nome, valor);
        }
    }
    if novo.val("dps", "finNFSe", "").is_empty() {
        novo.por("dps", "finNFSe", "0");
    }
    Ok(novo)
}

fn decimal(v: &str) -> Option<Decimal> {
    Decimal::from_str(v.trim()).ok()
}

fn duas_casas(v: Decimal) -> String {
    format!(
        "{:.2}",
        v.round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero)
    )
}

/// O valor total (de todos os coproprietários) que corresponde à parte desta nota: vale para o
/// aluguel e para os descontos. A SEFIN exige `parte = pCopropriedade × total`, com half-even
/// e tolerância de um centavo no release 1 oficial.
pub fn total_da_operacao(v_serv: &str, p_copropriedade: &str) -> Res<String> {
    let (Some(valor), Some(p)) = (decimal(v_serv), decimal(p_copropriedade)) else {
        return Err(Erro::valor(
            "Locação: informe o valor do serviço e o percentual de copropriedade.",
        ));
    };
    if !percentual_copropriedade_valido(p_copropriedade) {
        return Err(Erro::valor(
            "Locação: a copropriedade deve estar entre 0 e 100%, com até duas casas decimais.",
        ));
    }
    if p == Decimal::ZERO {
        return Err(Erro::valor(
            "Locação: 0% pode ser cadastrado, mas não permite calcular o total do aluguel a partir do valor da nota. Para esta emissão, informe a participação do locador maior que zero.",
        ));
    }
    let total = (valor * Decimal::ONE_HUNDRED / p)
        .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven);
    let parte = (total * p / Decimal::ONE_HUNDRED)
        .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven);
    // LEIAUTE DPS_NFS-e 1.01 (20/10): half-even com tolerância de um centavo.
    if (parte - valor).abs() > Decimal::new(1, 2) {
        return Err(Erro::valor(format!(
            "Locação: com {}% de copropriedade, o valor R$ {} não corresponde a um total de aluguel exato em centavos \
             (a SEFIN exige valor da nota = total × percentual). Ajuste o valor em um centavo.",
            p.normalize(),
            duas_casas(valor)
        )));
    }
    Ok(duas_casas(total))
}

/// Domínio de pCopropriedade no Anexo I PRODREST e no tipo TSDec3V2 (NT 009 release 1).
pub fn percentual_copropriedade_valido(v: &str) -> bool {
    let texto = v.trim().replace(',', ".");
    let (inteiro, fracao) = match texto.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (texto.as_str(), None),
    };
    if inteiro.is_empty()
        || !inteiro.bytes().all(|b| b.is_ascii_digit())
        || fracao
            .is_some_and(|f| f.is_empty() || f.len() > 2 || !f.bytes().all(|b| b.is_ascii_digit()))
    {
        return false;
    }
    decimal(&texto).is_some_and(|p| p >= Decimal::ZERO && p <= Decimal::ONE_HUNDRED)
}

/// Põe na config final da locação o que não vem do cadastro do serviço: no imóvel, o total da
/// operação (sai do valor da nota). Sem efeito nas outras notas.
pub fn completar_locacao(cfg: &mut Ini) -> Res<()> {
    let codigo = cfg.val("serv.cServ", "cTribNac", "");
    // cAtvSN pertence a uma evolução posterior: não existe no XSD do release 1.
    if !e_imovel(&codigo) {
        return Ok(());
    }
    let secao = "IBSCBS.imovel.gLocacao";
    let p = cfg.val(secao, "pCopropriedade", "100.00");
    let total = total_da_operacao(&cfg.val("valores.vServPrest", "vServ", ""), &p)?;
    cfg.por(
        secao,
        "pCopropriedade",
        &duas_casas(decimal(&p).unwrap_or(Decimal::ONE_HUNDRED)),
    );
    cfg.por(secao, "vTotOper", &total);
    let total_decimal = decimal(&total).ok_or_else(|| Erro::valor("Total da locação inválido."))?;
    let mut soma_ajustes = Decimal::ZERO;
    for s in cfg.secoes() {
        if s.starts_with("IBSCBS.imovel.gUnidImob.")
            && s.contains(".gAjusteBCLocImoveis.")
            && let Some(v) = cfg.obter(s, "vAjusteBCLocImoveis")
        {
            let ajuste =
                decimal(v).ok_or_else(|| Erro::valor("Valor do ajuste da locação inválido."))?;
            if ajuste < Decimal::ZERO || ajuste > total_decimal {
                return Err(Erro::valor(
                    "Locação: cada ajuste da base deve estar entre zero e o valor total da operação (E0966).",
                ));
            }
            soma_ajustes += ajuste;
        }
    }
    if soma_ajustes > total_decimal {
        return Err(Erro::valor(
            "Locação: a soma dos ajustes da base excede o valor total da operação (E1547).",
        ));
    }
    // Os descontos da nota também são a PARTE do coproprietário: a SEFIN quer o total deles.
    for (parte, total) in [
        ("vDescIncond", "vDescIncondTot"),
        ("vDescCond", "vDescCondTot"),
    ] {
        let v = cfg.val("valores.vDescCondIncond", parte, "");
        if !v.trim().is_empty() {
            cfg.por(secao, total, &total_da_operacao(&v, &p)?);
        }
    }
    Ok(())
}
