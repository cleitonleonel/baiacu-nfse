//! Agregados das NFS-e emitidas, em centavos. A receita segue os valores fiscais do Cofre.

use std::collections::{BTreeMap, HashMap};

use chrono::{Datelike, Days, Months, NaiveDate};
use rusqlite::params;
use rust_decimal::{Decimal, prelude::ToPrimitive};
use serde::Serialize;
use serde_json::{Value, json};

use crate::cofre;
use crate::erro::{Erro, Res};

#[derive(Default, Serialize)]
struct Valores {
    bruto: i64,
    liquido: i64,
    notas: u64,
}

impl Valores {
    fn somar(&mut self, bruto: i64, liquido: i64) {
        self.bruto += bruto;
        self.liquido += liquido;
        self.notas += 1;
    }
}

#[derive(Serialize)]
struct Faixa {
    #[serde(serialize_with = "serializar_data")]
    inicio: NaiveDate,
    #[serde(serialize_with = "serializar_data")]
    fim: NaiveDate,
    #[serde(flatten)]
    valores: Valores,
}

fn serializar_data<S: serde::Serializer>(data: &NaiveDate, s: S) -> Result<S::Ok, S::Error> {
    s.collect_str(data)
}

#[derive(Serialize)]
struct Cliente {
    doc: String,
    nome: String,
    #[serde(flatten)]
    valores: Valores,
}

fn data(texto: &str) -> Res<NaiveDate> {
    NaiveDate::parse_from_str(texto, "%Y-%m-%d")
        .map_err(|_| Erro::valor("Informe datas válidas para o período do dashboard."))
}

fn criar_faixas(inicio: NaiveDate, fim: NaiveDate, dias: u64) -> Res<(&'static str, Vec<Faixa>)> {
    let grupo = match dias {
        1..=35 => "dia",
        36..=112 => "semana",
        113..=1830 => "mes",
        _ => "ano",
    };
    let mut faixas = Vec::new();
    let mut inicio = inicio;
    while inicio <= fim {
        let proxima = match grupo {
            "dia" => inicio.succ_opt(),
            "semana" => inicio.checked_add_days(Days::new(7)),
            "mes" => inicio
                .with_day(1)
                .and_then(|d| d.checked_add_months(Months::new(1))),
            _ => NaiveDate::from_ymd_opt(inicio.year() + 1, 1, 1),
        };
        let fim_da_faixa = proxima.and_then(|d| d.pred_opt()).unwrap_or(fim).min(fim);
        faixas.push(Faixa {
            inicio,
            fim: fim_da_faixa,
            valores: Valores::default(),
        });
        if faixas.len() > 100 {
            return Err(Erro::valor(
                "Selecione um período de até 100 anos para o dashboard.",
            ));
        }
        let Some(proxima) = proxima else { break };
        inicio = proxima;
    }
    Ok((grupo, faixas))
}

/// Quantas notas com XML ilegível o resumo aponta de uma vez (a busca vai uma a uma na SEFIN).
const XML_ILEGIVEIS_MAX: usize = 200;

fn ler_retencoes(xml: &[u8]) -> Option<i64> {
    let doc = roxmltree::Document::parse(std::str::from_utf8(xml).ok()?).ok()?;
    let inf = doc
        .root_element()
        .children()
        .find(|n| n.has_tag_name("infNFSe"))?;
    let valores = inf.children().find(|n| n.has_tag_name("valores"))?;
    // vTotalRet é opcional. Ausente em um XML íntegro significa que não foi informado.
    let Some(campo) = valores.children().find(|n| n.has_tag_name("vTotalRet")) else {
        return Some(0);
    };
    let valor = campo.text()?.trim().parse::<Decimal>().ok()?;
    valor.checked_mul(Decimal::from(100))?.round().to_i64()
}

pub(crate) fn resumo(
    dono: &str,
    ini: &str,
    fim: &str,
    competencia: bool,
    movimento: bool,
    anteriores: &[[String; 2]],
) -> Res<Value> {
    let (inicio, fim) = (data(ini)?, data(fim)?);
    if fim < inicio {
        return Err(Erro::valor(
            "A data final precisa ser igual ou posterior à inicial.",
        ));
    }
    let dias = (fim - inicio).num_days() as u64 + 1;
    let anterior_ini = inicio
        .checked_sub_days(Days::new(dias))
        .ok_or_else(|| Erro::valor("O período anterior está fora do calendário suportado."))?;
    let anterior_fim = inicio - Days::new(1);
    let (grupo, mut faixas) = criar_faixas(inicio, fim, dias)?;
    if anteriores.len() > 3 {
        return Err(Erro::valor("Selecione até três períodos anteriores."));
    }
    let mut periodos = Vec::new();
    for [de, ate] in anteriores {
        let (de, ate) = (data(de)?, data(ate)?);
        if ate < de || de >= inicio || ate >= fim || (ate - de).num_days() > 36_600 {
            return Err(Erro::valor("Informe um período anterior válido."));
        }
        periodos.push((de.to_string(), ate.to_string()));
    }
    let passo = if dias == 1 && (!competencia || movimento) {
        "hora"
    } else if dias > 1830 {
        "mes"
    } else {
        "dia"
    };
    let mut pontos = BTreeMap::<String, Valores>::new();
    let mut historico = vec![Vec::<(String, i64, i64, i64)>::new(); periodos.len()];
    let mut total = Valores::default();
    let mut anterior = Valores::default();
    let mut retencoes = 0;
    let mut xml_indisponiveis = 0;
    // As notas cujo XML guardado não abre (ou sumiu): a tela oferece buscar de novo na SEFIN.
    let mut xml_ilegiveis: Vec<i64> = Vec::new();
    let mut clientes = HashMap::new();
    let dono = cofre::so_doc(dono);
    if dono.is_empty() {
        return Err(Erro::valor("Selecione um prestador."));
    }
    if cofre::existe() {
        // Uma leitura ordenada garante o mesmo conjunto de notas para os totais e os gráficos.
        let mut con = cofre::conn()?;
        let con = con.transaction()?;
        let coluna = cofre::coluna_de_data(competencia, movimento);
        let chave = match passo {
            "hora" if movimento => "COALESCE(strftime('%H', NULLIF(entrou, 0), 'unixepoch', 'localtime'), '')".to_string(),
            "hora" => "CASE WHEN substr(dhProc, 12, 2) GLOB '[0-2][0-9]'
                         AND substr(dhProc, 12, 2) < '24' THEN substr(dhProc, 12, 2)
                         ELSE '' END"
                .to_string(),
            "mes" => format!("substr({coluna}, 1, 7) || '-01'"),
            _ => coluna.to_string(),
        };
        let filtro = format!(
            "dono = ?1 AND emit_doc = ?1 AND amb = '1' AND papel = 'E'
             AND cancelada = 0 AND subst_por = '' AND {coluna} BETWEEN ?2 AND ?3"
        );
        let mut st = con.prepare(&format!(
            "SELECT id, {coluna}, toma_doc, toma_nome,
                    CAST(round(vServ * 100) AS INTEGER), CAST(round(vLiq * 100) AS INTEGER),
                    {chave}
             FROM nota WHERE {filtro}
             ORDER BY {coluna}, id"
        ))?;
        let desde = if periodos.is_empty() {
            anterior_ini
        } else {
            inicio
        };
        let mut linhas = st.query(params![dono, desde.to_string(), fim.to_string()])?;
        let mut faixa = 0;
        while let Some(nota) = linhas.next()? {
            let dia: String = nota.get(1)?;
            let Ok(dia) = data(&dia) else { continue };
            if dia > fim {
                continue;
            }
            let (bruto, liquido) = (nota.get(4)?, nota.get(5)?);
            if dia < inicio {
                anterior.somar(bruto, liquido);
                continue;
            }
            total.somar(bruto, liquido);
            pontos
                .entry(nota.get(6)?)
                .or_default()
                .somar(bruto, liquido);
            while dia > faixas[faixa].fim {
                faixa += 1;
            }
            faixas[faixa].valores.somar(bruto, liquido);
            let doc: String = nota.get(2)?;
            if !doc.is_empty() {
                let nome: String = nota.get(3)?;
                let c = clientes.entry(doc.clone()).or_insert_with(|| Cliente {
                    doc,
                    nome: String::new(),
                    valores: Valores::default(),
                });
                if !nome.trim().is_empty() {
                    c.nome = nome;
                }
                c.valores.somar(bruto, liquido);
            }
            let id: i64 = nota.get(0)?;
            let xml = match cofre::xml_disponivel_em(&con, id) {
                Ok(Some(xml)) => Some(xml),
                Ok(None) => None,
                Err(e) if cofre::e_xml_ilegivel(&e) => None,
                Err(_) => {
                    xml_indisponiveis += 1;
                    continue;
                }
            };
            if xml.is_none() && xml_ilegiveis.len() < XML_ILEGIVEIS_MAX {
                xml_ilegiveis.push(id);
            }
            match xml.and_then(|xml| ler_retencoes(&xml)) {
                Some(valor) => retencoes += valor,
                None => xml_indisponiveis += 1,
            }
        }
        if !periodos.is_empty() {
            let mut st = con.prepare(&format!(
                "SELECT {chave}, sum(CAST(round(vServ * 100) AS INTEGER)),
                        sum(CAST(round(vLiq * 100) AS INTEGER)), count(*)
                 FROM nota WHERE {filtro}
                 GROUP BY 1 ORDER BY 1"
            ))?;
            for ((de, ate), valores) in periodos.iter().zip(&mut historico) {
                *valores = st
                    .query_map(params![dono, de, ate], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                    })?
                    .collect::<Result<_, _>>()?;
            }
        }
    }
    let (anterior_ini, anterior_fim) = match periodos.first() {
        Some((de, ate)) => {
            for &(_, bruto, liquido, notas) in &historico[0] {
                anterior.bruto += bruto;
                anterior.liquido += liquido;
                anterior.notas += notas as u64;
            }
            (de.clone(), ate.clone())
        }
        None => (anterior_ini.to_string(), anterior_fim.to_string()),
    };
    let clientes = clientes.values().collect::<Vec<_>>();
    let ordenar = |liquido: bool| {
        let valor = |c: &Cliente| {
            if liquido {
                c.valores.liquido
            } else {
                c.valores.bruto
            }
        };
        let mut ranking = clientes.clone();
        ranking.sort_unstable_by(|a, b| valor(b).cmp(&valor(a)).then_with(|| a.doc.cmp(&b.doc)));
        ranking.truncate(5);
        ranking
    };
    Ok(json!({
        "total": total, "anterior": anterior, "grupo": grupo, "faixas": faixas,
        "anterior_ini": anterior_ini, "anterior_fim": anterior_fim,
        "retencoes": retencoes, "xml_indisponiveis": xml_indisponiveis, "xml_ilegiveis": xml_ilegiveis,
        "clientes": clientes.len(), "ranking_bruto": ordenar(false), "ranking_liquido": ordenar(true),
        "passo": passo,
        "series": std::iter::once(pontos.into_iter().map(|(chave, v)|
            (chave, v.bruto, v.liquido, v.notas as i64)).collect::<Vec<_>>())
            .chain(historico).collect::<Vec<_>>()
    }))
}
