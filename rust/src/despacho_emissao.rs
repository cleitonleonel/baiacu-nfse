//! Porta do núcleo: emissão (ver `despacho`).
use serde_json::{Value, json};

use crate::cadastro::ServicoForm;
use crate::config_dps::Forcados;
use crate::despacho::{bytes_b64, js, logico, texto, texto_ou};
use crate::emissao;
use crate::erro::{Erro, Res};

/// `[[seção, opção, valor], …]` -> valores forçados.
fn forcados(a: &Value, nome: &str) -> Res<Forcados> {
    let mut out: Forcados = Vec::new();
    for item in a.get(nome).and_then(Value::as_array).into_iter().flatten() {
        let t = |i: usize| item.get(i).and_then(Value::as_str);
        match (t(0), t(1), t(2)) {
            (Some(s), Some(o), Some(v)) => crate::config_dps::forcar(&mut out, s, o, v),
            _ => {
                return Err(Erro::valor(format!(
                    "Override inválido (esperado (secao, opcao)): {item}"
                )));
            }
        }
    }
    Ok(out)
}

fn form_opcional(a: &Value) -> Res<Option<ServicoForm>> {
    match a.get("form") {
        None | Some(Value::Null) => Ok(None),
        Some(v) => Ok(Some(serde_json::from_value(v.clone())?)),
    }
}

pub fn executar(metodo: &str, a: &Value) -> Option<Res<Value>> {
    Some(match metodo {
        "emissao.preview" => (|| {
            let f = form_opcional(a)?;
            emissao::preview_emissao_com(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto(a, "ambiente")?,
                texto_ou(a, "servico", ""),
                f.as_ref(),
                &forcados(a, "extra_overrides")?,
                logico(a, "assinar"),
            )
        })(),
        "emissao.aquecer" => {
            crate::validacao::aquecer();
            Ok(Value::Null)
        }
        "emissao.namespaces" => emissao::namespaces().map(|(n, d)| json!([n, d])),
        "emissao.emitir" => (|| {
            emissao::emitir(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto(a, "servico")?,
                texto_ou(a, "cert", ""),
                texto(a, "ambiente")?,
                &forcados(a, "extra_overrides")?,
            )
        })(),

        // ---- fila de contingência ------------------------------------------------------- //
        "emissao.enqueue_pendente" => (|| {
            let exc: emissao::Pendencia =
                serde_json::from_value(a.get("exc").cloned().unwrap_or(Value::Null))?;
            js(emissao::enqueue_pendente(
                texto(a, "prestador")?,
                texto_ou(a, "tomador", ""),
                texto_ou(a, "servico", ""),
                texto_ou(a, "tomador_nome", ""),
                texto_ou(a, "valor", ""),
                &exc,
                a.get("subst").unwrap_or(&Value::Null),
            )?)
        })(),
        "emissao.arquivar_dps_descartada" => (|| {
            let exc: emissao::Pendencia =
                serde_json::from_value(a.get("exc").cloned().unwrap_or(Value::Null))?;
            js(emissao::arquivar_dps_descartada(
                texto(a, "prestador")?,
                &exc,
                texto_ou(a, "tomador", ""),
                texto_ou(a, "tomador_nome", ""),
            ))
        })(),
        "emissao.list_pendentes" => {
            (|| js(emissao::list_pendentes(texto_ou(a, "prestador", ""))?))()
        }
        "emissao.count_pendentes" => {
            (|| js(emissao::count_pendentes(texto_ou(a, "prestador", ""))?))()
        }
        "emissao.pendente_xml" => (|| {
            let x = emissao::pendente_xml(texto(a, "prestador")?, texto(a, "id")?)?;
            js(base64::Engine::encode(
                &base64::engine::general_purpose::STANDARD,
                x,
            ))
        })(),
        "emissao.cancelar_pendente" => (|| {
            let p: emissao::PendenteInfo =
                serde_json::from_value(a.get("p").cloned().unwrap_or(Value::Null))?;
            emissao::cancelar_pendente(
                texto(a, "prestador")?,
                &p,
                crate::despacho::logico(a, "forcar"),
            )
        })(),
        "emissao.reenviar_pendente" => (|| {
            let p: emissao::PendenteInfo =
                serde_json::from_value(a.get("p").cloned().unwrap_or(Value::Null))?;
            let prestador = texto(a, "prestador")?;
            // O núcleo conclui a fila e faz o único envio automático de e-mail.
            // Repetir aqui duplicaria a mensagem para chamadas vindas do Dart/CLI.
            emissao::reenviar_pendente(prestador, &p, texto_ou(a, "cert", ""))
        })(),

        // ---- substituição ---------------------------------------------------------------- //
        "emissao.subst_motivos" => Ok(json!(
            emissao::SUBST_MOTIVOS
                .iter()
                .map(|(c, r)| json!([c, r]))
                .collect::<Vec<_>>()
        )),
        "emissao.subst_campos_imutaveis" => (|| {
            let campos = emissao::subst_campos_imutaveis(&bytes_b64(a, "xml")?.unwrap_or_default());
            Ok(json!(
                campos
                    .into_iter()
                    .map(|(k, v)| json!([k, v]))
                    .collect::<Vec<_>>()
            ))
        })(),
        "emissao.subst_overrides" => (|| {
            let imutaveis: Vec<(String, String)> = a
                .get("imutaveis")
                .and_then(Value::as_array)
                .map(|l| {
                    l.iter()
                        .filter_map(|p| {
                            Some((
                                p.get(0)?.as_str()?.to_string(),
                                p.get(1)?.as_str()?.to_string(),
                            ))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let f = emissao::subst_overrides(
                texto(a, "chave")?,
                texto(a, "c_motivo")?,
                texto_ou(a, "x_motivo", ""),
                &imutaveis,
            )?;
            Ok(json!(
                f.into_iter()
                    .map(|((s, o), v)| json!([s, o, v]))
                    .collect::<Vec<_>>()
            ))
        })(),
        "emissao.subst_pairs" => (|| {
            Ok(json!(
                emissao::subst_pairs(texto(a, "prestador")?)?
                    .into_iter()
                    .map(|(x, y)| json!([x, y]))
                    .collect::<Vec<_>>()
            ))
        })(),
        "emissao.marcar_substituida" => (|| {
            emissao::marcar_substituida(
                texto(a, "prestador")?,
                texto(a, "chave_antiga")?,
                texto(a, "chave_nova")?,
            )?;
            Ok(Value::Null)
        })(),

        // ---- cancelamento ---------------------------------------------------------------- //
        "emissao.canc_motivos" => Ok(json!(
            emissao::CANC_MOTIVOS
                .iter()
                .map(|(c, r)| json!([c, r]))
                .collect::<Vec<_>>()
        )),
        "emissao.cancelar_nfse" => (|| {
            emissao::cancelar_nfse(
                texto(a, "prestador")?,
                texto(a, "chave")?,
                texto(a, "c_motivo")?,
                texto_ou(a, "x_motivo", ""),
                texto_ou(a, "ambiente", ""),
            )
        })(),
        "emissao.ambiente_from_xml" => (|| {
            js(emissao::ambiente_from_xml(
                texto(a, "chave")?,
                texto_ou(a, "prestador", ""),
            )?)
        })(),
        "emissao.cancelamento_status" => {
            let (pode, limite) = emissao::cancelamento_status(
                a.get("data")
                    .and_then(Value::as_str)
                    .and_then(crate::texto::parse_iso_date),
            );
            Ok(json!([
                pode,
                limite.map(|d| d.format("%Y-%m-%d").to_string())
            ]))
        }

        _ => return None,
    })
}
