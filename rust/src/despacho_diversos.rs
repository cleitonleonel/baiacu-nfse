//! Porta do núcleo: aparência, consultas online, registros e backup (ver `despacho`).
use serde_json::{Value, json};

use crate::despacho::{lista_de_textos, logico, texto, texto_ou};
use crate::erro::Res;
use crate::{aparencia, backup, cadastro, consulta, registros};

fn numero(a: &Value, nome: &str, padrao: f64) -> f64 {
    a.get(nome).and_then(Value::as_f64).unwrap_or(padrao)
}

pub fn executar(metodo: &str, a: &Value, avisar: crate::despacho::Avisar) -> Option<Res<Value>> {
    Some(match metodo {
        "pdf.aquecer_danfse" => {
            crate::danfse::aquecer();
            Ok(Value::Null)
        }
        "pdf.abrir_no_leitor" => (|| {
            Ok(json!(crate::leitor_pdf::abrir(
                texto(a, "arquivo")?,
                a.get("pid").and_then(Value::as_u64).unwrap_or(0) as u32
            )))
        })(),
        "ajuda.info" => Ok(crate::ajuda::info()),
        // ---- doação ---------------------------------------------------------------------- //
        "doacao.info" => crate::doacao::info(),
        "doacao.apos_emissao" => {
            crate::doacao::apos_emissao(logico(a, "producao")).map(Value::Bool)
        }
        // ---- atualização --------------------------------------------------------------- //
        "atualizacao.estado" => crate::atualizacao::estado(),
        "atualizacao.configurar" => crate::atualizacao::configurar(
            a.get("automatica").and_then(Value::as_bool),
            a.get("pular").and_then(Value::as_str),
        ),
        "atualizacao.verificar" => crate::atualizacao::verificar(logico(a, "automatica")),
        "atualizacao.baixar" => crate::atualizacao::baixar(avisar),
        "atualizacao.instalar" => crate::atualizacao::instalar(),
        // ---- aparência ------------------------------------------------------------------ //
        "aparencia.carregar" => {
            let (fundo, cartoes) = aparencia::carregar();
            Ok(json!({ "fundo": fundo, "cartoes": cartoes }))
        }
        "aparencia.salvar" => (|| {
            let (fundo, cartoes) = aparencia::salvar(texto(a, "fundo")?, texto(a, "cartoes")?)?;
            Ok(json!({ "fundo": fundo, "cartoes": cartoes }))
        })(),
        "aparencia.validar" => (|| Ok(json!(aparencia::validar(texto(a, "cor")?)?)))(),
        "aparencia.normalizar" => (|| Ok(json!(aparencia::normalizar(texto(a, "cor")?)?)))(),
        "aparencia.hsv" => (|| {
            let (h, s, v) = aparencia::hsv(texto(a, "cor")?)?;
            Ok(json!([h, s, v]))
        })(),
        "aparencia.de_hsv" => Ok(json!(aparencia::de_hsv(
            numero(a, "matiz", 0.0),
            numero(a, "intensidade", 0.0),
            numero(a, "claridade", 0.0)
        ))),
        "aparencia.escurecer" => (|| {
            Ok(json!(aparencia::escurecer(
                texto(a, "cor")?,
                numero(a, "fator", 1.0)
            )?))
        })(),
        "aparencia.superficies" => {
            (|| aparencia::superficies(texto(a, "fundo")?, texto(a, "cartoes")?))()
        }
        "aparencia.temas" => Ok(json!(
            aparencia::temas()
                .into_iter()
                .map(|(n, f, c)| json!([n, f, c]))
                .collect::<Vec<_>>()
        )),
        "aparencia.limites" => Ok(json!({
            "nativo": { "fundo": aparencia::NATIVO.0, "cartoes": aparencia::NATIVO.1 },
            "padrao": { "fundo": aparencia::PADRAO.0, "cartoes": aparencia::PADRAO.1 },
            "intensidade_max": aparencia::INTENSIDADE_MAX,
            "claridade_min": aparencia::CLARIDADE_MIN,
            "controle_intensidade_max": aparencia::CONTROLE_INTENSIDADE_MAX,
            "controle_claridade_min": aparencia::CONTROLE_CLARIDADE_MIN,
        })),

        // ---- consultas online ----------------------------------------------------------- //
        "consulta.cep" => (|| consulta::consultar_cep(texto(a, "cep")?))(),
        "consulta.cnpj" => (|| consulta::consultar_cnpj(texto(a, "cnpj")?))(),
        "consulta.municipios" => Ok(json!(
            consulta::listar_municipios()
                .into_iter()
                .map(|(c, n, u)| json!([c, n, u]))
                .collect::<Vec<_>>()
        )),
        "consulta.url_nfse" => Ok(json!(consulta::url_consulta_nfse(texto_ou(
            a, "ambiente", ""
        )))),
        "consulta.url_nfse_completa" => (|| {
            Ok(json!(consulta::url_consulta_nfse_completa(
                texto(a, "chave")?,
                texto_ou(a, "ambiente", "")
            )))
        })(),

        // ---- registros ------------------------------------------------------------------ //
        "registros.consultar" => Ok(json!(registros::consultar_registros(
            a.get("dias").and_then(Value::as_i64).unwrap_or(30),
            texto_ou(a, "termo", ""),
            logico(a, "so_erros"),
            a.get("limite").and_then(Value::as_i64).unwrap_or(2000),
        ))),

        // ---- backup --------------------------------------------------------------------- //
        "backup.nome_sugerido" => {
            (|| Ok(json!(backup::nome_sugerido(&lista_de_textos(a, "partes"))?)))()
        }
        "backup.tamanhos" => Ok(backup::tamanhos()),
        "backup.fazer" => (|| {
            backup::fazer_acompanhando(texto(a, "destino")?, &lista_de_textos(a, "partes"), avisar)
        })(),
        "backup.em_andamento" => Ok(json!(backup::em_andamento())),
        "backup.examinar" => {
            (|| backup::examinar(texto(a, "origem")?, texto_ou(a, "senha_mestra", "")))()
        }
        "backup.restaurar" => (|| {
            Ok(json!(backup::restaurar(
                texto(a, "origem")?,
                &lista_de_textos(a, "partes"),
                texto_ou(a, "senha_mestra", "")
            )?))
        })(),

        // ---- prestador ------------------------------------------------------------------ //
        "cadastro.delete_prestador" => (|| {
            cadastro::delete_prestador(texto(a, "documento")?)?;
            Ok(Value::Null)
        })(),

        _ => return None,
    })
}
