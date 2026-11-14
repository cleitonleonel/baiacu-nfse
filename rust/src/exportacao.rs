//! Consulta e exportações do sistema, com o mesmo filtro e conteúdo do Python.
use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Write};
use std::path::Path;

use rust_xlsxwriter::{Formula, Workbook};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::cofre::{self, Filtro, Nota};
use crate::despacho::Avisar;
use crate::erro::{Erro, Res};
use crate::{cadastro, danfse, texto};

pub const CAB: [&str; 11] = [
    "NFS-e",
    "Cliente",
    "Documento",
    "Grupo",
    "Processada em",
    "Ambiente",
    "Status",
    "vServ",
    "vLíq",
    "Chave de acesso",
    "Cancelada",
];
const ORDENS: [&str; 9] = [
    "numero", "nome", "doc", "grupo", "data", "amb", "cstat", "vserv", "vliq",
];

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct Opcoes {
    pub tomadores: Option<Vec<String>>,
    pub ini: String,
    pub fim: String,
    pub termo: String,
    pub sort_col: Option<usize>,
    pub asc: bool,
    pub ambiente: String,
    pub papel: String,
    pub situacao: String,
    pub incluir_xml: bool,
    pub incluir_danfse: bool,
    pub incluir_eventos: bool,
    pub formatos: Vec<String>,
    pub por_mes: bool,
    pub por_tipo: bool,
}
impl Default for Opcoes {
    fn default() -> Self {
        Self {
            tomadores: None,
            ini: String::new(),
            fim: String::new(),
            termo: String::new(),
            sort_col: None,
            asc: true,
            ambiente: String::new(),
            papel: String::new(),
            situacao: String::new(),
            incluir_xml: true,
            incluir_danfse: false,
            incluir_eventos: false,
            formatos: Vec::new(),
            por_mes: false,
            por_tipo: false,
        }
    }
}

#[derive(Debug, Serialize)]
#[allow(non_snake_case)]
pub struct Registro {
    pub chave: String,
    pub nNFSe: String,
    pub dhProc: String,
    pub ambGer: String,
    pub cStat: String,
    pub vServ: String,
    pub vLiq: String,
    pub vISSQN: String,
    pub tomador_nome: String,
    pub tomador: String,
    pub grupo: String,
    pub nDPS: String,
    pub serie: String,
    pub dCompet: String,
    pub tpAmb: String,
    pub nota_id: i64,
    pub cancelada: bool,
    pub subst_por: String,
    pub ambiente_label: String,
}

fn registro(n: Nota, grupos: &HashMap<String, String>) -> Registro {
    let grupo = grupos
        .get(&texto::only_doc(&n.toma_doc))
        .cloned()
        .unwrap_or_default();
    let ambiente = cadastro::ambiente_rotulo(&n.amb)
        .unwrap_or(if n.amb.is_empty() { "?" } else { &n.amb })
        .to_string();
    Registro {
        chave: n.chave,
        nNFSe: n.nNFSe,
        dhProc: n.dhProc,
        ambGer: String::new(),
        cStat: n.cStat,
        vServ: format!("{:.2}", n.vServ),
        vLiq: format!("{:.2}", n.vLiq),
        vISSQN: String::new(),
        tomador_nome: n.toma_nome,
        tomador: n.toma_doc,
        grupo,
        nDPS: String::new(),
        serie: String::new(),
        dCompet: n.dt,
        tpAmb: n.amb,
        nota_id: n.id,
        cancelada: n.cancelada,
        subst_por: n.subst_por,
        ambiente_label: ambiente,
    }
}

pub fn pagina(prestador: &str, o: &Opcoes, limite: i64, offset: i64) -> Res<(i64, Vec<Registro>)> {
    if prestador.is_empty() {
        return Ok((0, Vec::new()));
    }
    let grupos = cadastro::tomadores_grupos(prestador)?;
    let mapa = grupos.iter().cloned().collect();
    let filtro = Filtro {
        origem: "local".into(),
        docs: o.tomadores.clone(),
        ini: o.ini.clone(),
        fim: o.fim.clone(),
        termo: o.termo.clone(),
        amb: if cadastro::ambiente_rotulo(&o.ambiente).is_some() {
            o.ambiente.clone()
        } else {
            String::new()
        },
        ordem: o
            .sort_col
            .map(|c| (ORDENS.get(c).copied().unwrap_or("numero").into(), o.asc)),
        limite: Some(limite),
        offset,
        grupos,
        ..Default::default()
    };
    let (ns, total, _) = cofre::listar(prestador, &filtro)?;
    Ok((total, ns.into_iter().map(|n| registro(n, &mapa)).collect()))
}

fn registros(prestador: &str, o: &Opcoes) -> Res<Vec<Registro>> {
    Ok(pagina(prestador, o, 10_000_000, 0)?.1)
}
fn status(cancelada: bool, subst: &str, cstat: &str) -> String {
    if !subst.is_empty() {
        "SUBSTITUÍDA".into()
    } else if cancelada {
        "CANCELADA".into()
    } else {
        cstat.into()
    }
}
fn datahora(d: &str) -> String {
    d.replace('T', " ").chars().take(19).collect()
}

pub fn linha(r: &Registro) -> Vec<String> {
    vec![
        r.nNFSe.clone(),
        if r.tomador_nome.is_empty() {
            r.tomador.clone()
        } else {
            r.tomador_nome.clone()
        },
        texto::format_documento(&r.tomador),
        r.grupo.clone(),
        datahora(&r.dhProc),
        r.ambiente_label.clone(),
        status(r.cancelada, &r.subst_por, &r.cStat),
        texto::fmt_money_br(&r.vServ),
        texto::fmt_money_br(&r.vLiq),
        r.chave.clone(),
        if r.cancelada {
            "Sim".into()
        } else {
            "Não".into()
        },
    ]
}

pub struct Acompanhar<'a> {
    pub avisar: Avisar<'a>,
    pub cancelar: &'a dyn Fn() -> bool,
}
impl Acompanhar<'_> {
    fn verificar(&self) -> Res<()> {
        if (self.cancelar)() {
            Err(Erro::novo("ExportCancelled", ""))
        } else {
            Ok(())
        }
    }
    fn passo(&self, i: usize, total: usize) -> Res<()> {
        if i & 63 == 0 {
            self.verificar()?;
        }
        if i % 200.max(total / 100) == 0 {
            (self.avisar)(&json!({"feito":i,"total":total}));
        }
        Ok(())
    }
    fn fim(&self, total: usize) {
        (self.avisar)(&json!({"feito":total,"total":total}));
    }
    fn etapa(&self, t: &str, indeterminada: bool) {
        (self.avisar)(&json!({"etapa":t,"indeterminada":indeterminada}));
    }
}

/// O arquivo anterior só é substituído depois de concluir a exportação.
fn gravar<T>(destino: &Path, f: impl FnOnce(&Path) -> Res<T>) -> Res<T> {
    let nome = destino.file_name().unwrap_or_default().to_string_lossy();
    let tmp = destino.with_file_name(format!(
        ".{nome}.export-{}-{}",
        std::process::id(),
        chrono::Local::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    let r = f(&tmp).and_then(|v| {
        std::fs::rename(&tmp, destino)?;
        Ok(v)
    });
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r
}

fn csv(cab: &[&str], linhas: &[Vec<String>]) -> Vec<u8> {
    let mut out = String::from("\u{feff}");
    for valores in std::iter::once(cab.iter().map(|s| s.to_string()).collect::<Vec<_>>())
        .chain(linhas.iter().cloned())
    {
        let campos = valores
            .into_iter()
            .map(|v| {
                if v.contains([';', '"', '\r', '\n']) {
                    format!("\"{}\"", v.replace('"', "\"\""))
                } else {
                    v
                }
            })
            .collect::<Vec<_>>();
        out.push_str(&campos.join(";"));
        out.push_str("\r\n");
    }
    out.into_bytes()
}

fn erro_xlsx(e: rust_xlsxwriter::XlsxError) -> Erro {
    Erro::valor(e.to_string())
}
fn xlsx(
    cab: &[&str],
    linhas: &[Vec<String>],
    numeros: &[(usize, Vec<f64>)],
    larguras: &[f64],
) -> Res<Vec<u8>> {
    let mut wb = Workbook::new();
    let ws = wb.add_worksheet();
    ws.set_name("NFS-e").map_err(erro_xlsx)?;
    for (c, w) in larguras.iter().enumerate() {
        ws.set_column_width(c as u16, (w * 7.0 - 5.0) / 7.0)
            .map_err(erro_xlsx)?;
    }
    ws.set_freeze_panes(1, 0).map_err(erro_xlsx)?;
    for (c, t) in cab.iter().enumerate() {
        ws.write_string(0, c as u16, *t).map_err(erro_xlsx)?;
    }
    for (i, linha) in linhas.iter().enumerate() {
        for (c, t) in linha.iter().enumerate() {
            let r = (i + 1) as u32;
            if let Some((_, ns)) = numeros.iter().find(|(col, _)| *col == c) {
                ws.write_number(r, c as u16, ns[i]).map_err(erro_xlsx)?;
            } else if t.starts_with('=') && t.len() > 1 {
                ws.write_formula(r, c as u16, Formula::new(t).set_result(""))
                    .map_err(erro_xlsx)?;
            } else if !t.is_empty() {
                ws.write_string(r, c as u16, t).map_err(erro_xlsx)?;
            }
        }
    }
    wb.save_to_buffer().map_err(erro_xlsx)
}

fn coletar(rs: &[Registro], a: &Acompanhar) -> Res<Vec<Vec<String>>> {
    let mut out = Vec::with_capacity(rs.len());
    for (i, r) in rs.iter().enumerate() {
        a.passo(i, rs.len())?;
        out.push(linha(r));
    }
    a.fim(rs.len());
    Ok(out)
}

pub fn exportar(
    prestador: &str,
    destino: &Path,
    formato: &str,
    o: &Opcoes,
    a: &Acompanhar,
) -> Res<usize> {
    let rs = registros(prestador, o)?;
    let linhas = coletar(&rs, a)?;
    let dados = match formato {
        "csv" => csv(&CAB, &linhas),
        "xlsx" => xlsx(
            &CAB,
            &linhas,
            &[
                (
                    7,
                    rs.iter().map(|r| r.vServ.parse().unwrap_or(0.0)).collect(),
                ),
                (
                    8,
                    rs.iter().map(|r| r.vLiq.parse().unwrap_or(0.0)).collect(),
                ),
            ],
            &[
                12.0, 36.0, 20.0, 16.0, 20.0, 14.0, 10.0, 14.0, 14.0, 52.0, 10.0,
            ],
        )?,
        "pdf" => {
            let pf = cadastro::get_prestador_form(prestador)?;
            let prest = [pf.xNome, texto::format_documento(prestador)]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" — ");
            let mut topo = vec![
                (
                    format!("NFS-e emitidas — {} nota(s)", rs.len()),
                    "titulo".into(),
                ),
                ("4".into(), "espaco".into()),
                (format!("Prestador: {prest}"), "sub".into()),
                (
                    format!(
                        "Período: {} a {}",
                        data_br(&o.ini, "início"),
                        data_br(&o.fim, "hoje")
                    ),
                    "sub".into(),
                ),
            ];
            let mut filtros = Vec::new();
            if o.tomadores.is_some() {
                filtros.push("Por cliente".to_string());
            }
            if !o.ambiente.is_empty() {
                filtros.push(format!(
                    "Por ambiente ({})",
                    cadastro::ambiente_rotulo(&o.ambiente).unwrap_or(&o.ambiente)
                ));
            }
            if !o.termo.trim().is_empty() {
                filtros.push(format!("Por busca (“{}”)", o.termo.trim()));
            }
            let sem_filtros = Opcoes {
                ini: o.ini.clone(),
                fim: o.fim.clone(),
                ..Default::default()
            };
            if !filtros.is_empty() && rs.len() as i64 != pagina(prestador, &sem_filtros, 1, 0)?.0 {
                topo.push(("Filtros aplicados:".into(), "sub".into()));
                topo.extend(
                    filtros
                        .into_iter()
                        .map(|f| (format!("• {f}"), "sub".into())),
                );
                topo.push(("2".into(), "espaco".into()));
                topo.push(("Obs.: nem todas as notas do período estão presentes neste relatório devido aos filtros aplicados.".into(),"obs".into()));
            }
            crate::relatorio_pdf::gerar(
                &CAB,
                &linhas,
                &[
                    36.0, 136.0, 76.0, 70.0, 74.0, 56.0, 46.0, 56.0, 56.0, 126.0, 46.0,
                ],
                &topo,
                &[1, 3, 9],
                "NFS-e emitidas",
                a.cancelar,
            )?
        }
        _ => {
            return Err(Erro::valor(format!(
                "Formato de relatório desconhecido: {formato}"
            )));
        }
    };
    a.verificar()?;
    gravar(destino, |p| {
        std::fs::write(p, dados)?;
        Ok(rs.len())
    })
}

fn data_br(s: &str, padrao: &str) -> String {
    texto::parse_iso_date(s)
        .map(|d| d.format("%d/%m/%Y").to_string())
        .unwrap_or_else(|| padrao.into())
}
fn erro_zip(e: zip::result::ZipError) -> Erro {
    Erro::runtime(e.to_string())
}
fn anexar<W: Write + std::io::Seek>(zf: &mut ZipWriter<W>, nome: &str, dados: &[u8]) -> Res<()> {
    zf.start_file(
        nome,
        SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
    )
    .map_err(erro_zip)?;
    zf.write_all(dados)?;
    Ok(())
}

pub fn exportar_xmls(
    prestador: &str,
    destino: &Path,
    o: &Opcoes,
    a: &Acompanhar,
) -> Res<(usize, usize, usize)> {
    let simples = Opcoes {
        ini: o.ini.clone(),
        fim: o.fim.clone(),
        ambiente: o.ambiente.clone(),
        ..Default::default()
    };
    let rs = registros(prestador, &simples)?;
    gravar(destino, |p| {
        let leitor = cofre::LeitorXml::novo()?;
        let mut zf = ZipWriter::new(std::fs::File::create(p)?);
        let mut ns = (0, 0, 0);
        for (i, r) in rs.iter().enumerate() {
            a.passo(i, rs.len())?;
            let xml = if o.incluir_xml || o.incluir_danfse {
                leitor.xml(r.nota_id)?
            } else {
                Vec::new()
            };
            if o.incluir_xml {
                anexar(&mut zf, &format!("xml/{}.xml", r.chave), &xml)?;
                ns.0 += 1;
            }
            if o.incluir_danfse {
                anexar(
                    &mut zf,
                    &format!("danfse/{}.pdf", r.chave),
                    &danfse::gerar(&xml, r.cancelada, !r.subst_por.is_empty())?,
                )?;
                ns.1 += 1;
            }
            if o.incluir_eventos {
                for (j, e) in leitor.eventos(prestador, &r.chave)?.iter().enumerate() {
                    anexar(
                        &mut zf,
                        &format!("eventos/{}_{}_{}.xml", r.chave, e.tipo, j + 1),
                        &e.xml,
                    )?;
                    ns.2 += 1;
                }
            }
        }
        a.fim(rs.len());
        a.verificar()?;
        zf.finish().map_err(erro_zip)?;
        Ok(ns)
    })
}

fn filtro_cofre(o: &Opcoes, limite: i64) -> Filtro {
    Filtro {
        papel: o.papel.clone(),
        amb: o.ambiente.clone(),
        ini: o.ini.clone(),
        fim: o.fim.clone(),
        termo: o.termo.clone(),
        situacao: o.situacao.clone(),
        ordem: Some(("data".into(), true)),
        limite: Some(limite),
        ..Default::default()
    }
}
pub fn contar_cofre(prestador: &str, o: &Opcoes) -> Res<i64> {
    Ok(cofre::listar(prestador, &filtro_cofre(o, 1))?.1)
}
fn pasta(n: &Nota, o: &Opcoes) -> (String, String) {
    (
        if o.por_tipo {
            match n.papel.as_str() {
                "E" => "emitidas",
                "R" => "recebidas",
                _ => "outras",
            }
            .into()
        } else {
            String::new()
        },
        if o.por_mes {
            if n.dt.len() >= 7 {
                n.dt[..7].into()
            } else {
                "sem-data".into()
            }
        } else {
            String::new()
        },
    )
}
fn prefixo(tipo: &str, mes: &str) -> String {
    [tipo, mes]
        .into_iter()
        .filter(|s| !s.is_empty())
        .map(|s| format!("{s}/"))
        .collect()
}
fn cab_cofre(tipo: &str) -> [&str; 10] {
    [
        "Tipo",
        "NFS-e",
        match tipo {
            "emitidas" => "Tomador",
            "recebidas" => "Emitente",
            _ => "Emitente / Tomador",
        },
        "CNPJ / CPF",
        "Processada em",
        "Ambiente",
        "Status",
        "vServ",
        "vLíq",
        "Chave de acesso",
    ]
}
fn linha_cofre(n: &Nota) -> Vec<String> {
    vec![
        n.papel_rotulo().into(),
        n.nNFSe.clone(),
        n.outro_nome().into(),
        texto::format_documento(n.outro_doc()),
        datahora(&n.dhProc),
        cadastro::ambiente_rotulo(&n.amb).unwrap_or(&n.amb).into(),
        status(n.cancelada, &n.subst_por, &n.cStat),
        texto::fmt_money_br(&format!("{:.2}", n.vServ)),
        texto::fmt_money_br(&format!("{:.2}", n.vLiq)),
        n.chave.clone(),
    ]
}

pub fn exportar_cofre(prestador: &str, destino: &Path, o: &Opcoes, a: &Acompanhar) -> Res<Value> {
    let notas = cofre::listar(prestador, &filtro_cofre(o, 10_000_000))?.0;
    let mut grupos: BTreeMap<(String, String), Vec<&Nota>> = BTreeMap::new();
    for n in &notas {
        grupos.entry(pasta(n, o)).or_default().push(n);
    }
    let mut out = json!({"notas":notas.len(),"xml":0,"danfse":0,"eventos":0,"relatorios":0,"pastas":grupos.len()});
    let mut filtros = Vec::new();
    if !o.ini.is_empty() || !o.fim.is_empty() {
        filtros.push(format!(
            "Período: {} a {}",
            data_br(&o.ini, "início"),
            data_br(&o.fim, "hoje")
        ));
    }
    if !o.papel.is_empty() && !o.por_tipo {
        filtros.push(format!(
            "Só as {}",
            match o.papel.as_str() {
                "E" => "emitidas",
                "R" => "recebidas",
                _ => "de outro papel",
            }
        ));
    }
    if !o.ambiente.is_empty() {
        filtros.push(format!(
            "Ambiente: {}",
            cadastro::ambiente_rotulo(&o.ambiente).unwrap_or(&o.ambiente)
        ));
    }
    if !o.situacao.is_empty() {
        filtros.push(format!(
            "Só as {}",
            if o.situacao == "canceladas" {
                "canceladas"
            } else {
                "ativas"
            }
        ));
    }
    if !o.termo.trim().is_empty() {
        filtros.push(format!("Busca: “{}”", o.termo.trim()));
    }
    let doc = texto::only_doc(prestador);
    gravar(destino, |p| {
        let mut zf = ZipWriter::new(std::fs::File::create(p)?);
        if o.incluir_xml || o.incluir_danfse || o.incluir_eventos {
            let leitor = cofre::LeitorXml::novo()?;
            let tipos = [
                ("XMLs", o.incluir_xml),
                ("DANFSe", o.incluir_danfse),
                ("eventos", o.incluir_eventos),
            ]
            .into_iter()
            .filter(|(_, on)| *on)
            .map(|(t, _)| t)
            .collect::<Vec<_>>()
            .join(", ");
            a.etapa(&format!("Exportando {tipos}…"), false);
            for (i, n) in notas.iter().enumerate() {
                a.passo(i, notas.len())?;
                let (tipo, mes) = pasta(n, o);
                let pre = prefixo(&tipo, &mes);
                let xml = if o.incluir_xml || o.incluir_danfse {
                    leitor.xml(n.id)?
                } else {
                    Vec::new()
                };
                if o.incluir_xml {
                    anexar(&mut zf, &format!("{pre}xml/{}.xml", n.chave), &xml)?;
                    out["xml"] = json!(out["xml"].as_u64().unwrap_or(0) + 1);
                }
                if o.incluir_danfse {
                    anexar(
                        &mut zf,
                        &format!("{pre}danfse/{}.pdf", n.chave),
                        &danfse::gerar(&xml, n.cancelada, !n.subst_por.is_empty())?,
                    )?;
                    out["danfse"] = json!(out["danfse"].as_u64().unwrap_or(0) + 1);
                }
                if o.incluir_eventos {
                    for (j, e) in leitor.eventos(prestador, &n.chave)?.iter().enumerate() {
                        anexar(
                            &mut zf,
                            &format!("{pre}eventos/{}_{}_{}.xml", n.chave, e.tipo, j + 1),
                            &e.xml,
                        )?;
                        out["eventos"] = json!(out["eventos"].as_u64().unwrap_or(0) + 1);
                    }
                }
            }
            a.fim(notas.len());
        }
        for fmt in &o.formatos {
            if !["xlsx", "csv", "pdf"].contains(&fmt.as_str()) {
                return Err(Erro::valor(format!(
                    "Formato de relatório desconhecido: {fmt}"
                )));
            }
            a.etapa(
                &if fmt == "pdf" {
                    "Gerando PDF… isso pode demorar.".into()
                } else {
                    format!("Gerando relatório (.{fmt})…")
                },
                true,
            );
            for ((tipo, mes), ns) in &grupos {
                a.verificar()?;
                let linhas = ns.iter().map(|n| linha_cofre(n)).collect::<Vec<_>>();
                let cab = cab_cofre(tipo);
                let dados = match fmt.as_str() {
                    "csv" => csv(&cab, &linhas),
                    "xlsx" => xlsx(
                        &cab,
                        &linhas,
                        &[
                            (7, ns.iter().map(|n| n.vServ).collect()),
                            (8, ns.iter().map(|n| n.vLiq).collect()),
                        ],
                        &[11.0, 12.0, 40.0, 20.0, 20.0, 14.0, 13.0, 14.0, 14.0, 52.0],
                    )?,
                    _ => {
                        let pf = cadastro::get_prestador_form(prestador)?;
                        let prest = [pf.xNome, texto::format_documento(prestador)]
                            .into_iter()
                            .filter(|s| !s.is_empty())
                            .collect::<Vec<_>>()
                            .join(" — ");
                        let qual = match tipo.as_str() {
                            "emitidas" => " emitidas",
                            "recebidas" => " recebidas",
                            "outras" => " em outro papel",
                            _ => "",
                        };
                        let mut topo = vec![
                            (
                                format!("NFS-e{qual} — {} nota(s)", ns.len()),
                                "titulo".into(),
                            ),
                            ("4".into(), "espaco".into()),
                            (format!("Prestador: {prest}"), "sub".into()),
                        ];
                        if !mes.is_empty() {
                            topo.push((
                                if mes.len() == 7 {
                                    format!("Mês: {}/{}", &mes[5..7], &mes[..4])
                                } else {
                                    "Sem data".into()
                                },
                                "sub".into(),
                            ));
                        }
                        topo.extend(filtros.iter().map(|f| (f.clone(), "sub".into())));
                        crate::relatorio_pdf::gerar(
                            &cab,
                            &linhas,
                            &[44.0, 36.0, 170.0, 78.0, 74.0, 56.0, 56.0, 56.0, 56.0, 152.0],
                            &topo,
                            &[2, 9],
                            "NFS-e do Cofre",
                            a.cancelar,
                        )?
                    }
                };
                let nome = ["notas", &doc, tipo, mes]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("_")
                    + "."
                    + fmt;
                anexar(
                    &mut zf,
                    &format!("{}Relatorios/{nome}", prefixo(tipo, mes)),
                    &dados,
                )?;
                out["relatorios"] = json!(out["relatorios"].as_u64().unwrap_or(0) + 1);
            }
        }
        a.verificar()?;
        zf.finish().map_err(erro_zip)?;
        Ok(out)
    })
}

pub fn zip_anexar(destino: &Path, arquivo: &Path, nome: &str) -> Res<()> {
    gravar(destino, |tmp| {
        let mut zf = ZipWriter::new(std::fs::File::create(tmp)?);
        if destino.exists() {
            let mut anterior = ZipArchive::new(std::fs::File::open(destino)?).map_err(erro_zip)?;
            for i in 0..anterior.len() {
                let mut arq = anterior.by_index(i).map_err(erro_zip)?;
                let nome = arq.name().map(|n| n.to_string()).unwrap_or_default();
                let mut bytes = Vec::new();
                arq.read_to_end(&mut bytes)?;
                anexar(&mut zf, &nome, &bytes)?;
            }
        }
        anexar(&mut zf, nome, &std::fs::read(arquivo)?)?;
        zf.finish().map_err(erro_zip)?;
        Ok(())
    })
}
