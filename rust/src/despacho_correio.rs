//! Porta do núcleo: e-mail e o editor de texto rico (ver `despacho`).
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use crate::correio::{self, EmailSettings, Valores};
use crate::despacho::{js, logico, texto, texto_ou};
use crate::email_delta;
use crate::erro::Res;

fn settings(a: &Value) -> Res<Option<EmailSettings>> {
    match a.get("settings") {
        None | Some(Value::Null) => Ok(None),
        Some(v) => Ok(Some(serde_json::from_value(v.clone())?)),
    }
}

fn valores(a: &Value) -> Valores {
    a.get("valores")
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
        .unwrap_or_default()
}

fn senha(a: &Value) -> Option<&str> {
    a.get("senha").and_then(Value::as_str)
}

pub fn executar(metodo: &str, a: &Value) -> Option<Res<Value>> {
    Some(match metodo {
        "danfse.gerar" => (|| {
            let xml = crate::despacho::bytes_b64(a, "xml")?.unwrap_or_default();
            js(STANDARD.encode(crate::danfse::gerar(
                &xml,
                logico(a, "cancelada"),
                logico(a, "substituida"),
            )?))
        })(),
        // ---- configuração ---------------------------------------------------------------- //
        "correio.padroes" => Ok(json!({
            "assunto": correio::ASSUNTO_PADRAO, "mensagem": correio::MENSAGEM_PADRAO,
            "fonte_padrao": email_delta::FONTE_PADRAO, "tamanho_padrao": email_delta::TAMANHO_PADRAO as i64,
        })),
        "correio.get_settings" => (|| js(correio::get_email_settings(texto(a, "prestador")?)?))(),
        "correio.save_settings" => (|| {
            let s = settings(a)?.unwrap_or_default();
            js(correio::save_email_settings(
                texto(a, "prestador")?,
                &s,
                senha(a),
            )?)
        })(),
        "correio.validate" => (|| js(settings(a)?.unwrap_or_default().validate(senha(a))))(),
        "correio.ativo_para" => (|| {
            js(settings(a)?
                .unwrap_or_default()
                .ativo_para(texto_ou(a, "ambiente", "")))
        })(),
        "correio.auto_para" => (|| {
            js(settings(a)?
                .unwrap_or_default()
                .auto_para(texto_ou(a, "ambiente", "")))
        })(),

        // ---- envio ----------------------------------------------------------------------- //
        "correio.testar" => (|| {
            let s = settings(a)?;
            correio::testar_email_settings(
                texto(a, "prestador")?,
                s.as_ref(),
                senha(a),
                texto_ou(a, "destinatario", ""),
            )
        })(),
        "correio.enviar_nfse" => (|| {
            correio::enviar_nfse_email(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto(a, "chave")?,
                texto_ou(a, "ambiente", ""),
            )
        })(),
        "correio.classificar_erro" => {
            let (categoria, msg) = correio::classificar_erro(
                texto_ou(a, "tipo", ""),
                texto_ou(a, "msg", ""),
                a.get("dados").unwrap_or(&Value::Null),
            );
            Ok(json!([categoria, msg]))
        }
        "correio.encerrar_smtp" => {
            correio::encerrar_smtp();
            Ok(Value::Null)
        }
        "correio.render" => js(correio::render_template(
            texto_ou(a, "modelo", ""),
            &valores(a),
            logico(a, "html"),
        )),
        "correio.email_html" => js(correio::email_html(texto_ou(a, "modelo", ""), &valores(a))),
        "correio.email_subject" => js(correio::email_subject(
            texto_ou(a, "modelo", ""),
            &valores(a),
        )),

        // ---- editor de texto rico ---------------------------------------------------------- //
        "email_delta.html_para_delta" => Ok(Value::Array(email_delta::html_para_delta(texto_ou(
            a, "html", "",
        )))),
        "email_delta.delta_inicial" => js(email_delta::delta_json(&email_delta::html_para_delta(
            texto_ou(a, "html", ""),
        ))),
        "email_delta.delta_para_html" => js(email_delta::delta_para_html(
            a.get("delta").unwrap_or(&Value::Null),
        )),
        "email_delta.delta_json" => js(email_delta::delta_json(
            a.get("ops")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]),
        )),
        "email_delta.elementos_nao_suportados" => js(email_delta::elementos_nao_suportados(
            texto_ou(a, "html", ""),
        )),
        "email_delta.mesmo_documento" => js(email_delta::mesmo_documento(
            a.get("a").unwrap_or(&Value::Null),
            a.get("b").unwrap_or(&Value::Null),
        )),
        "email_delta.html_com_padrao" => js(email_delta::html_com_padrao(texto_ou(a, "corpo", ""))),
        "texto.fmt_money_br" => js(crate::texto::fmt_money_br(texto_ou(a, "valor", ""))),

        _ => return None,
    })
}
