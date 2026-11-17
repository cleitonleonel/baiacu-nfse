//! Portas usadas por Consulta, Cofre e exportações.
use crate::despacho::{self, Avisar, js, texto, texto_ou};
use crate::erro::Res;
use crate::exportacao::{self, Acompanhar, Opcoes};
use serde_json::{Value, json};
use std::path::Path;

fn opcoes(a: &Value) -> Res<Opcoes> {
    let mut v = a.get("opcoes").unwrap_or(a).clone();
    if let Some(m) = v.as_object_mut() {
        for k in ["ini", "fim", "termo", "ambiente", "papel", "situacao"] {
            if m.get(k).is_some_and(Value::is_null) {
                m.insert(k.into(), json!(""));
            }
        }
    }
    Ok(serde_json::from_value(v)?)
}

pub fn executar(metodo: &str, a: &Value, avisar: Avisar) -> Option<Res<Value>> {
    let ficha = texto_ou(a, "ficha", "");
    let cancel = || despacho::cancelada(ficha);
    let ac = Acompanhar {
        avisar,
        cancelar: &cancel,
    };
    let r = match metodo {
        "consulta.page_nfse_index" => (|| {
            let (n, rs) = exportacao::pagina(
                texto_ou(a, "prestador", ""),
                &opcoes(a)?,
                a.get("limit").and_then(Value::as_i64).unwrap_or(25),
                a.get("offset").and_then(Value::as_i64).unwrap_or(0),
            )?;
            Ok(json!([n, rs]))
        })(),
        "consulta.count_nfse_index" => {
            (|| js(exportacao::pagina(texto_ou(a, "prestador", ""), &opcoes(a)?, 1, 0)?.0))()
        }
        "exportacao.xlsx" | "exportacao.csv" | "exportacao.pdf" => (|| {
            js(exportacao::exportar(
                texto(a, "prestador")?,
                Path::new(texto(a, "destino")?),
                metodo.rsplit('.').next().unwrap_or(""),
                &opcoes(a)?,
                &ac,
            )?)
        })(),
        "exportacao.xmls_zip" => (|| {
            let ns = exportacao::exportar_xmls(
                texto(a, "prestador")?,
                Path::new(texto(a, "destino")?),
                &opcoes(a)?,
                &ac,
            )?;
            Ok(json!([ns.0, ns.1, ns.2]))
        })(),
        "exportacao.cofre_zip" => (|| {
            exportacao::exportar_cofre(
                texto(a, "prestador")?,
                Path::new(texto(a, "destino")?),
                &opcoes(a)?,
                &ac,
            )
        })(),
        "exportacao.lotes_zip" => (|| {
            exportacao::exportar_registros_lotes(
                texto(a, "prestador")?,
                &despacho::lista_de_textos(a, "execucoes"),
                Path::new(texto(a, "destino")?),
                &opcoes(a)?,
                &ac,
            )
        })(),
        "exportacao.contar_cofre" => (|| {
            js(exportacao::contar_cofre(
                texto(a, "prestador")?,
                &opcoes(a)?,
            )?)
        })(),
        "exportacao.zip_anexar" => (|| {
            exportacao::zip_anexar(
                Path::new(texto(a, "destino")?),
                Path::new(texto(a, "arquivo")?),
                texto(a, "nome")?,
            )?;
            Ok(Value::Null)
        })(),
        "cofre.gerar_danfse" => (|| {
            let dono = texto(a, "dono")?;
            let chave = texto(a, "chave")?;
            let caminho = crate::cofre::danfse_para_abrir(dono, chave)?;
            js(caminho.to_string_lossy())
        })(),
        _ => return None,
    };
    if !metodo.starts_with("consulta.") {
        despacho::esquecer_ficha(ficha);
    }
    Some(r)
}
