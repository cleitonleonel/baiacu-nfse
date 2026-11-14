//! Leitura dos campos da DANFSe, portada da BrazilFiscalReport local (LGPL-3.0).
use std::collections::HashMap;
use std::sync::OnceLock;

use roxmltree::{Document, Node};
use serde_json::{Value, json};

use crate::erro::{Erro, Res};

type No<'a, 'i> = Option<Node<'a, 'i>>;
const NS: &str = "http://www.sped.fazenda.gov.br/nfse";

pub fn dominios() -> &'static Value {
    static D: OnceLock<Value> = OnceLock::new();
    D.get_or_init(|| {
        serde_json::from_str(include_str!("../recursos/danfse/dominios.json"))
            .unwrap_or(Value::Null)
    })
}

fn filho<'a, 'i>(n: No<'a, 'i>, tag: &str) -> No<'a, 'i> {
    n.and_then(|n| {
        n.children().find(|e| {
            e.is_element() && e.tag_name().name() == tag && e.tag_name().namespace() == Some(NS)
        })
    })
}

fn achar<'a, 'i>(n: No<'a, 'i>, tag: &str) -> No<'a, 'i> {
    n.and_then(|n| {
        n.descendants().skip(1).find(|e| {
            e.is_element() && e.tag_name().name() == tag && e.tag_name().namespace() == Some(NS)
        })
    })
}

fn t(n: No<'_, '_>, tag: &str) -> String {
    achar(n, tag)
        .and_then(|e| e.text())
        .unwrap_or("")
        .to_string()
}

fn um<'a>(xs: &[&'a str]) -> &'a str {
    xs.iter().copied().find(|x| !x.is_empty()).unwrap_or("")
}

fn ou(x: &str) -> String {
    if x.is_empty() { "-".into() } else { x.into() }
}

fn juntos(xs: &[&str]) -> String {
    ou(&xs
        .iter()
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" / "))
}

fn reticencias(s: &str, limite: usize) -> String {
    if s.chars().count() > limite {
        format!("{}...", s.chars().take(limite).collect::<String>())
    } else {
        s.into()
    }
}

pub(crate) fn dominio(nome: &str, valor: &str, padrao: &str) -> String {
    dominios()[nome][valor].as_str().unwrap_or(padrao).into()
}

pub(crate) fn moeda(v: &str) -> String {
    if v.is_empty() {
        "-".into()
    } else {
        format!("R$ {}", numero(v))
    }
}

pub(crate) fn percentual(v: &str) -> String {
    if v.is_empty() {
        "-".into()
    } else {
        format!("{}%", numero(v))
    }
}

pub(crate) fn numero(v: &str) -> String {
    v.parse::<f64>()
        .map(|n| {
            if n == 0.0 {
                if n.is_sign_negative() {
                    "-0,00".into()
                } else {
                    "0,00".into()
                }
            } else {
                crate::texto::fmt_money_br_num(n)
            }
        })
        .unwrap_or_default()
}

fn soma(xs: &[&str]) -> String {
    if xs.iter().all(|x| x.is_empty()) {
        "-".into()
    } else {
        moeda(
            &xs.iter()
                .map(|x| x.parse::<f64>().unwrap_or(0.0))
                .sum::<f64>()
                .to_string(),
        )
    }
}

pub(crate) fn documento(v: &str) -> String {
    let doc = crate::texto::only_doc(v);
    if doc.len() == 14 && doc.chars().any(|c| c.is_ascii_alphabetic()) {
        return crate::texto::format_documento(&doc);
    }
    let mut dig = crate::texto::only_digits(v);
    if dig.is_empty() {
        return String::new();
    }
    let alvo = if dig.len() > 11 { 14 } else { 11 };
    dig.truncate(alvo);
    crate::texto::format_documento(&format!("{dig:0>alvo$}"))
}

pub(crate) fn telefone(v: &str) -> String {
    match phonenumber::parse(Some(phonenumber::country::BR), v) {
        Ok(n) => {
            let modo = if n.country().id() == Some(phonenumber::country::BR) {
                phonenumber::Mode::National
            } else {
                phonenumber::Mode::International
            };
            n.format().mode(modo).to_string()
        }
        Err(_) => v.into(),
    }
}

pub(crate) fn uf(c: &str) -> &'static str {
    match c.get(..2).unwrap_or("") {
        "11" => "RO",
        "12" => "AC",
        "13" => "AM",
        "14" => "RR",
        "15" => "PA",
        "16" => "AP",
        "17" => "TO",
        "21" => "MA",
        "22" => "PI",
        "23" => "CE",
        "24" => "RN",
        "25" => "PB",
        "26" => "PE",
        "27" => "AL",
        "28" => "SE",
        "29" => "BA",
        "31" => "MG",
        "32" => "ES",
        "33" => "RJ",
        "35" => "SP",
        "41" => "PR",
        "42" => "SC",
        "43" => "RS",
        "50" => "MS",
        "51" => "MT",
        "52" => "GO",
        "53" => "DF",
        _ => "",
    }
}

pub(crate) fn municipio(c: &str) -> (&str, &str) {
    static M: OnceLock<HashMap<&'static str, (&'static str, &'static str)>> = OnceLock::new();
    let tabela = M.get_or_init(|| {
        include_str!("../recursos/danfse/municipios.csv")
            .lines()
            .filter_map(|l| {
                let mut p = l.split(';');
                Some((p.next()?, (p.next()?, p.next()?)))
            })
            .collect()
    });
    tabela.get(c.trim()).copied().unwrap_or(("", ""))
}

/// Prepara os catálogos fixos sem ler dados de clientes ou notas.
pub fn aquecer() {
    dominios();
    municipio("");
}

pub(crate) fn cep(c: &str) -> String {
    let d = crate::texto::only_digits(c);
    if d.len() == 8 {
        format!("{}.{}-{}", &d[..2], &d[2..5], &d[5..])
    } else {
        c.into()
    }
}

fn endereco(n: No<'_, '_>) -> String {
    [t(n, "xLgr"), t(n, "nro"), t(n, "xCpl"), t(n, "xBairro")]
        .into_iter()
        .filter(|x| !x.trim().is_empty())
        .collect::<Vec<_>>()
        .join(", ")
}

fn pessoa(n: No<'_, '_>, inscricao: bool) -> Value {
    if n.is_none() {
        return Value::Null;
    }
    let cmun = t(n, "cMun");
    let (nome, estado) = municipio(&cmun);
    let cidade = juntos(&[
        um(&[nome, &t(n, "xMun"), &t(n, "xCidade")]),
        um(&[estado, uf(&cmun), &t(n, "UF"), &t(n, "xEstProvReg")]),
    ]);
    let postal = t(n, "cEndPost");
    let ibge_cep = if postal.is_empty() {
        juntos(&[&cmun, &cep(&t(n, "CEP"))])
    } else {
        format!("{postal} (ext)")
    };
    let mut p = json!({
        "id": ou(um(&[&documento(&t(n,"CNPJ")), &documento(&t(n,"CPF")), &t(n,"NIF")])),
        "phone": ou(&telefone(&t(n,"fone"))), "name": ou(&reticencias(&t(n,"xNome"),77)),
        "email": ou(&t(n,"email")), "address": ou(&reticencias(&endereco(n),77)), "city": cidade, "ibge_cep": ibge_cep,
    });
    if inscricao {
        p["municipal_registration"] = json!(ou(&t(n, "IM")));
    }
    p
}

fn data(v: &str) -> (String, String) {
    let inicio: String = v.chars().take(10).collect();
    (
        inicio.split('-').rev().collect::<Vec<_>>().join("/"),
        v.chars().skip(11).take(8).collect(),
    )
}

pub fn ler(xml: &[u8]) -> Res<Value> {
    let texto = std::str::from_utf8(xml).map_err(|e| Erro::valor(e.to_string()))?;
    let doc = Document::parse(texto).map_err(|e| Erro::valor(e.to_string()))?;
    let raiz = Some(doc.root_element());
    let inf = achar(raiz, "infNFSe");
    let dps = achar(raiz, "DPS");
    if inf.is_none() || dps.is_none() {
        return Err(Erro::valor(
            "XML inválido para o DANFSe: os grupos NFSe/infNFSe e NFSe/infNFSe/DPS são obrigatórios.",
        ));
    }
    let infd = achar(dps, "infDPS");
    let emit = achar(raiz, "emit");
    let prest = achar(dps, "prest");
    let reg = achar(prest, "regTrib");
    let serv = achar(dps, "serv");
    let val = filho(inf, "valores");
    let ibsd = filho(infd, "IBSCBS");
    let ibsn = filho(inf, "IBSCBS");
    let tribmun = achar(dps, "tribMun");
    let tpemit = t(dps, "tpEmit");
    let fb = if tpemit.is_empty() || tpemit == "1" {
        emit
    } else {
        None
    };
    let prest_end = achar(prest, "end");
    let end = prest_end.or_else(|| {
        if fb.is_some() {
            achar(emit, "enderNac")
        } else {
            None
        }
    });
    let cmun = t(end, "cMun");
    let (munnome, munuf) = municipio(&cmun);
    let mun = um(&[
        munnome,
        &t(end, "xMun"),
        &t(end, "xCidade"),
        &t(inf, "xLocEmi"),
    ])
    .to_string();
    let estado = um(&[munuf, uf(&cmun), &t(end, "UF"), &t(fb, "UF")]).to_string();
    let postal = t(end, "cEndPost");
    let ibge_cep = if prest_end.is_some() && !postal.is_empty() {
        format!("{postal} (ext)")
    } else {
        juntos(&[&cmun, &cep(&t(end, "CEP"))])
    };
    let compet = t(dps, "dCompet");
    let (compet_fmt, _) = data(&compet);
    let (dt_nfse, hr_nfse) = data(&t(inf, "dhProc"));
    let (dt_dps, hr_dps) = data(&t(dps, "dhEmi"));
    let nacional = t(serv, "cTribNac");
    let nacional_format = if nacional.len() >= 6 {
        format!("{}.{}.{}", &nacional[..2], &nacional[2..4], &nacional[4..])
    } else {
        nacional.clone()
    };
    let nbs = t(serv, "cNBS");
    let nbs_format = if nbs.len() == 9 {
        format!("{}.{}.{}.{}", &nbs[..1], &nbs[1..5], &nbs[5..7], &nbs[7..])
    } else {
        nbs
    };
    let bm = achar(dps, "BM");
    let p_red = t(bm, "pRedBCBM");
    let v_red = t(bm, "vRedBCBM");
    let beneficio = match t(val, "tpBM").as_str() {
        "1" => "Isenção".into(),
        "2" if !p_red.is_empty() => format!("Redução da BC em {}%", numero(&p_red)),
        "3" if !v_red.is_empty() => format!("Redução da BC em R$ {}", numero(&v_red)),
        "2" | "3" => "Redução da Base de Cálculo".into(),
        "4" => "Alíquota Diferenciada".into(),
        _ => "-".into(),
    };
    let ded = um(&[
        &t(achar(dps, "vAjusteBC"), "vAjusteBCISSQN"),
        &t(achar(dps, "vDedRed"), "vDR"),
    ])
    .to_string();
    let ded_calculada = um(&[&t(val, "vCalcAjusteBCISSQN"), &t(val, "vCalcDR")]).to_string();
    let ded_anterior = um(&[&ded, &ded_calculada]);
    let ree = um(&[&t(ibsn, "vCalcAjusteBCIBSCBS"), &t(ibsn, "vCalcReeRepRes")]).to_string();
    let ajuste_imovel = t(ibsn, "vCalcAjusteBCLocImoveis");
    let iss = t(val, "vISSQN");
    let vserv = t(dps, "vServ");
    let inc = t(dps, "vDescIncond");
    let cond = t(dps, "vDescCond");
    let status = t(inf, "cStat");
    let fin = um(&[&t(dps, "finNFSe"), &t(ibsd, "finNFSe")]).to_string();
    let amb = t(dps, "tpAmb");
    let mut dados = json!({
        "environment": amb, "key_nfse": inf.and_then(|n|n.attribute("Id")).unwrap_or("").chars().skip(3).collect::<String>(),
        "nfse_number":t(inf,"nNFSe"),"compet":compet,"compet_fmt":compet_fmt,"dt_nfse":dt_nfse,"hr_nfse":hr_nfse,"dt_dps":dt_dps,"hr_dps":hr_dps,
        "dps_number":t(dps,"nDPS"),"dps_serie":t(dps,"serie"),
        "header": {"city": if nacional.starts_with("99") {String::new()} else {juntos(&[&t(inf,"xLocEmi"),&t(emit,"UF")])},
            "amb_ger":ou(&dominio("AMB_GER",&t(inf,"ambGer"),&t(inf,"ambGer"))),"tp_amb":ou(&dominio("TP_AMB",&amb,&amb))},
        "emitter_type":dominio("TP_EMIT",&tpemit,"-"),"status":ou(&reticencias(&dominio("C_STAT",&status,&status),37)),"purpose":ou(&reticencias(&dominio("FIN_NFSE",&fin,&fin),37)),
        "issuer": {
            "id":ou(um(&[&documento(&t(prest,"CNPJ")),&documento(&t(prest,"CPF")),&t(prest,"NIF"),&documento(&t(fb,"CNPJ")),&documento(&t(fb,"CPF"))])),
            "municipal_registration":ou(um(&[&t(prest,"IM"),&t(fb,"IM")])),"phone":ou(&telefone(um(&[&t(prest,"fone"),&t(fb,"fone")]))),
            "name":ou(&reticencias(um(&[&t(prest,"xNome"),&t(fb,"xNome")]),77)),"email":ou(um(&[&t(prest,"email"),&t(fb,"email")])),
            "address":ou(&reticencias(&endereco(end),77)),"city":juntos(&[&mun,&estado]),"ibge_cep":ibge_cep,
            "simples":reticencias(&dominio("SIMPLES_OP",&t(reg,"opSimpNac"),"-"),37),"tax_regim":ou(&reticencias(&dominio("REG_AP_TRIB_SN",&t(reg,"regApTribSN"),""),77)),
        },
        "service":{"tax_code":juntos(&[&nacional_format,&t(serv,"cTribMun")]),"nbs":ou(&nbs_format),
            "place_of_provision":juntos(&[&t(inf,"xLocPrestacao"),uf(&t(serv,"cLocPrestacao")),um(&[&t(serv,"cPaisPrestacao"),"BR"])]),
            "tax_code_description":reticencias(um(&[&t(inf,"xTribMun"),&t(inf,"xTribNac")]),167),"description":ou(&reticencias(&t(serv,"xDescServ"),1297))},
        "municipal_taxes":{
            "suppressed":tribmun.is_none(),"issqn_tax":dominio("TRIB_ISSQN",&t(dps,"tribISSQN"),"-"),
            "city":juntos(&[&t(inf,"xLocIncid"),uf(&t(inf,"cLocIncid")),um(&[&t(dps,"cPaisResult"),"BR"])]),
            "special_tax_regim":dominio("REG_ESP_TRIB",&t(reg,"regEspTrib"),"-"),"immunity_type":ou(&reticencias(&dominio("TP_IMUNIDADE",&t(dps,"tpImunidade"),&t(dps,"tpImunidade")),37)),
            "suspension_issqn":"-","suspension_number":"-","municipal_benefit":reticencias(&beneficio,37),"municipal_benefit_math":moeda(um(&[&t(val,"vCalcBM"),&v_red])),
            "deduct_reduc_amount":if filho(infd,"finNFSe").is_some() {soma(&[&ded,&ded_calculada])} else {soma(&[ded_anterior,&ree])},"discount_unconditioned":"-","calculation_basis":moeda(&t(val,"vBC")),"aliq_applied":percentual(&t(val,"pAliqAplic")),
            "issqn_retention":dominio("TP_RET_ISSQN",&t(dps,"tpRetISSQN"),"-"),"issqn_cleared":moeda(&iss)},
        "total_value":{"service_amount":moeda(&vserv),"discount_conditioned":"-","discount_unconditioned":"-","total_retentions":moeda(&t(val,"vTotalRet")),"net_value":moeda(&t(val,"vLiq")),"total_ibscbs":"-","net_value_ibscbs":"-"},
        "taker":pessoa(achar(dps,"toma"),true),"intermed":pessoa(achar(dps,"interm"),true),"dest":pessoa(achar(ibsd,"dest"),false),
    });
    let susp = achar(dps, "exigSusp");
    let tiposusp = dominio("TP_SUSP", &t(susp, "tpSusp"), "");
    if !tiposusp.is_empty() {
        dados["municipal_taxes"]["suspension_issqn"] = json!(reticencias(&tiposusp, 37));
    }
    let processo = t(susp, "nProcesso");
    if !processo.is_empty() {
        dados["municipal_taxes"]["suspension_number"] = json!(processo);
    }
    if achar(dps, "vDescCondIncond").is_some() {
        dados["municipal_taxes"]["discount_unconditioned"] = json!(moeda(&inc));
        dados["total_value"]["discount_unconditioned"] = json!(moeda(&inc));
        dados["total_value"]["discount_conditioned"] = json!(moeda(&cond));
    }
    let fed = achar(dps, "tribFed");
    let pis = t(fed, "vPis");
    let cofins = t(fed, "vCofins");
    dados["federal_taxes"] = json!({"irrf":moeda(&t(fed,"vRetIRRF")),"previdenciary_contribution":moeda(&t(fed,"vRetCP")),"social_contribution":moeda(&t(fed,"vRetCSLL")),
        "social_description":reticencias(&dominio("TP_RET_PIS_COFINS",&t(fed,"tpRetPisCofins"),"-"),35),"pis_debit":moeda(&pis),"cofins_debit":moeda(&cofins),
        "show_pis_cofins":um(&[&compet.chars().take(4).collect::<String>(),"0000"]) <= "2026"});
    let iv = filho(ibsn, "valores");
    let iuf = achar(iv, "uf");
    let imun = achar(iv, "mun");
    let ifed = achar(iv, "fed");
    let tot = achar(ibsn, "totCIBS");
    let loc = t(ibsn, "cLocalidadeIncid");
    let ibst = t(tot, "vIBSTot");
    let cbs = t(tot, "vCBS");
    dados["total_value"]["total_ibscbs"] = json!(soma(&[&ibst, &cbs]));
    dados["total_value"]["net_value_ibscbs"] = json!(moeda(&t(tot, "vTotNF")));
    let reds = [
        t(iuf, "pRedAliqUF"),
        t(imun, "pRedAliqMun"),
        t(ifed, "pRedAliqCBS"),
    ];
    let aliqs = [t(iuf, "pIBSUF"), t(imun, "pIBSMun")];
    dados["ibscbs"] = json!({"cst_cclasstrib":juntos(&[&t(ibsd,"CST"),&t(ibsd,"cClassTrib")]),"ind_op":juntos(&[&t(ibsd,"cIndOp"),&loc,&t(ibsn,"xLocalidadeIncid"),uf(&loc)]),
        "exclusions":soma(&[&inc,&ree,&ajuste_imovel,&iss,&pis,&cofins]),"bc_after":moeda(&t(iv,"vBC")),
        "red_aliq":if reds.iter().all(String::is_empty) {"-".into()} else {juntos(&[&percentual(&reds[0]),&percentual(&reds[1]),&percentual(&reds[2])])},
        "aliq_ibs":if aliqs.iter().all(String::is_empty) {"-".into()} else {juntos(&[&percentual(&aliqs[0]),&percentual(&aliqs[1])])},
        "aliq_efet_mun":percentual(&t(imun,"pAliqEfetMun")),"v_ibs_mun":moeda(&t(tot,"vIBSMun")),"aliq_efet_uf":percentual(&t(iuf,"pAliqEfetUF")),"v_ibs_uf":moeda(&t(tot,"vIBSUF")),
        "v_ibs_tot":moeda(&ibst),"aliq_cbs":percentual(&t(ifed,"pCBS")),"aliq_efet_cbs":percentual(&t(ifed,"pAliqEfetCBS")),"v_cbs":moeda(&cbs)});
    let info = achar(serv, "infoCompl");
    let mut segmentos = Vec::new();
    for (rotulo, valor) in [
        ("Inf. Cont.:", t(info, "xInfComp")),
        ("NFS-e Subst.:", t(dps, "chSubstda")),
        ("Doc. Ref.:", t(info, "docRef")),
        ("Cod. Obra:", t(serv, "cObra")),
        ("Insc. Imob.:", t(ibsd, "inscImobFisc")),
        ("Cod. Evt.:", t(serv, "idAtvEvt")),
        ("Doc. Tec.:", t(info, "idDocTec")),
        ("Núm. Ped.:", t(info, "xPed")),
        (
            "Item Ped.:",
            info.map(|n| {
                n.descendants()
                    .filter(|n| {
                        n.is_element()
                            && n.tag_name().name() == "xItemPed"
                            && n.tag_name().namespace() == Some(NS)
                    })
                    .filter_map(|n| n.text())
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("; ")
            })
            .unwrap_or_default(),
        ),
        ("Inf. A. T. Mun.:", t(inf, "xOutInf")),
    ] {
        if !valor.is_empty() {
            segmentos.push(format!("{rotulo} {valor}"));
        }
    }
    let tributo = |valor: &str, pct: &str| {
        if !valor.is_empty() {
            moeda(valor)
        } else {
            percentual(pct)
        }
    };
    dados["complementary_info"] = json!({"segments":segmentos,"approx_taxes":format!("Totais Aproximados dos Tributos cfe. Lei nº 12.741/2012: Federais: {} ; Estaduais: {} ; Municipais: {}",
        tributo(&t(dps,"vTotTribFed"),&t(dps,"pTotTribFed")),tributo(&t(dps,"vTotTribEst"),&t(dps,"pTotTribEst")),tributo(&t(dps,"vTotTribMun"),&t(dps,"pTotTribMun")))});
    Ok(dados)
}
