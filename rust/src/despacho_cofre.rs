//! Porta do núcleo: banco de notas (Cofre) e busca (ver `despacho`).
use std::path::Path;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use crate::cofre::{self, Acompanhar, Filtro, Nota};
use crate::despacho::{self, Avisar, bytes_b64, inteiro, js, logico, texto, texto_ou};
use crate::erro::Res;
use crate::{busca, cadastro};

fn nota_js(n: &Nota) -> Value {
    let mut v = serde_json::to_value(n).unwrap_or(Value::Null);
    if let Some(m) = v.as_object_mut() {
        m.insert("papel_rotulo".into(), json!(n.papel_rotulo()));
        m.insert("outro_doc".into(), json!(n.outro_doc()));
        m.insert("outro_nome".into(), json!(n.outro_nome()));
    }
    v
}

fn b64(dados: &[u8]) -> Value {
    Value::String(STANDARD.encode(dados))
}

fn pares(a: &Value, nome: &str) -> Vec<(String, String)> {
    a.get(nome)
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

pub fn executar(metodo: &str, a: &Value, avisar: Avisar) -> Option<Res<Value>> {
    Some(match metodo {
        // ---- busca --------------------------------------------------------------------- //
        "busca.rotulo" => js(busca::ROTULO),
        "busca.numero_exato" => js(busca::numero_exato(texto_ou(a, "consulta", ""))),
        "busca.casa" => js(busca::casa(
            texto_ou(a, "consulta", ""),
            texto_ou(a, "texto", ""),
            texto_ou(a, "chave", ""),
        )),

        // ---- notas ----------------------------------------------------------------------- //
        "cofre.existe" => js(cofre::existe()),
        "cofre.guardar_emitida" => (|| {
            let (chave, resultado) = cofre::guardar_emitida(
                texto(a, "dono")?,
                &bytes_b64(a, "xml")?.unwrap_or_default(),
            )?;
            Ok(json!([chave, resultado]))
        })(),
        "cofre.marcar_cancelada" => (|| {
            cofre::marcar_cancelada(
                texto(a, "dono")?,
                texto(a, "chave")?,
                bytes_b64(a, "evento_xml")?.as_deref(),
            )?;
            Ok(Value::Null)
        })(),
        "cofre.marcar_substituida" => (|| {
            cofre::marcar_substituida(
                texto(a, "dono")?,
                texto(a, "chave_antiga")?,
                texto(a, "chave_nova")?,
            )?;
            Ok(Value::Null)
        })(),
        "cofre.pares_substituicao" => (|| {
            Ok(json!(
                cofre::pares_substituicao(texto(a, "dono")?)?
                    .into_iter()
                    .map(|(x, y)| json!([x, y]))
                    .collect::<Vec<_>>()
            ))
        })(),
        "cofre.listar" => (|| {
            let f: Filtro = match a.get("filtro") {
                None | Some(Value::Null) => Filtro::default(),
                Some(v) => serde_json::from_value(v.clone())?,
            };
            let (notas, total, soma) = cofre::listar(texto(a, "dono")?, &f)?;
            Ok(
                json!({ "notas": notas.iter().map(nota_js).collect::<Vec<_>>(), "total": total, "soma": soma }),
            )
        })(),
        "cofre.nota_por_id" => (|| {
            Ok(cofre::nota_por_id(inteiro(a, "nota_id")?)?
                .as_ref()
                .map(nota_js)
                .unwrap_or(Value::Null))
        })(),
        "cofre.nota_por_chave" => (|| {
            Ok(
                cofre::nota_por_chave(texto(a, "dono")?, texto(a, "chave")?)?
                    .as_ref()
                    .map(nota_js)
                    .unwrap_or(Value::Null),
            )
        })(),
        "cofre.xml_por_chave" => (|| {
            Ok(b64(&cofre::xml_por_chave(
                texto(a, "dono")?,
                texto(a, "chave")?,
            )?))
        })(),
        "cofre.xml_da_nota" => (|| Ok(b64(&cofre::xml_da_nota(inteiro(a, "nota_id")?)?)))(),
        "cofre.eventos_da_nota" => (|| {
            let eventos = cofre::eventos_da_nota(texto(a, "dono")?, texto(a, "chave")?)?;
            Ok(json!(
                eventos.iter().map(|e| json!({ "tipo": e.tipo, "descricao": e.descricao, "dh": e.dh, "xml": b64(&e.xml) })).collect::<Vec<_>>()
            ))
        })(),
        "cofre.resumo" => (|| cofre::resumo(texto(a, "dono")?))(),
        "cofre.vazio" => (|| js(cofre::vazio(texto(a, "dono")?)?))(),
        "cofre.ultimo_nsu" => (|| js(cofre::ultimo_nsu(texto(a, "dono")?, texto(a, "amb")?)?))(),

        // ---- sincronização com o ADN ------------------------------------------------------- //
        "cofre.config" => js(cofre::config()),
        "cofre.salvar_config" => {
            (|| js(cofre::salvar_config(a.get("cfg").unwrap_or(&Value::Null))?))()
        }
        "cofre.intervalos" => js(cofre::INTERVALOS),
        "cofre.ambientes_de" => js(cofre::ambientes_de(
            &cofre::config(),
            texto_ou(a, "ambiente_em_uso", ""),
        )),
        "cofre.alvos" => (|| {
            let cfg = cofre::config();
            let mut prestadores = despacho::lista_de_textos(a, "prestadores");
            if let Some(id) = a
                .get("usuario")
                .and_then(|u| u.get("id"))
                .and_then(Value::as_i64)
            {
                let usuario = crate::usuarios::por_id(id)?;
                let existentes = cadastro::list_prestadores()?;
                let vinculados = crate::usuarios::prestadores_vinculados(id)?;
                prestadores = existentes
                    .into_iter()
                    .filter(|p| {
                        usuario.ativo && (usuario.is_master() || vinculados.contains(&p.documento))
                    })
                    .filter(|p| {
                        cfg.prestadores != "usuario"
                            || usuario.is_master()
                            || vinculados.contains(&p.documento)
                    })
                    .map(|p| p.documento)
                    .collect();
            }
            let atual = texto_ou(a, "prestador_em_uso", "");
            let atual = if prestadores.iter().any(|p| p == atual) {
                atual
            } else {
                ""
            };
            let ambiente = |p: &str| {
                cadastro::get_ambiente(p).unwrap_or_else(|_| cofre::AMB_PRODUCAO.to_string())
            };
            let alvos = cofre::alvos(&cfg, atual, &prestadores, &ambiente);
            Ok(json!(
                alvos
                    .into_iter()
                    .map(|(p, amb)| json!([p, amb]))
                    .collect::<Vec<_>>()
            ))
        })(),
        "cofre.ultima_automatica" => js(cofre::ultima_automatica()),
        "cofre.marcar_automatica" => {
            cofre::marcar_automatica(a.get("quando").and_then(Value::as_i64));
            Ok(Value::Null)
        }
        "cofre.sincronizar" | "cofre.sincronizar_varios" => (|| {
            let ficha = texto_ou(a, "ficha", "").to_string();
            let cancelar = || despacho::cancelada(&ficha);
            let acompanhar = Acompanhar {
                progresso: Some(avisar),
                cancelar: Some(&cancelar),
                dormir: &cofre::dormir_de_verdade,
            };
            let resultado = if metodo.ends_with("_varios") {
                cofre::sincronizar_varios(
                    &pares(a, "pares"),
                    None,
                    &acompanhar,
                    logico(a, "forcar"),
                )
            } else {
                cofre::sincronizar(
                    texto(a, "dono")?,
                    texto(a, "amb")?,
                    None,
                    &acompanhar,
                    logico(a, "forcar"),
                )
                .and_then(js)
            };
            despacho::esquecer_ficha(&ficha);
            resultado
        })(),

        // ---- proteção do arquivo ------------------------------------------------------------- //
        "cofre.verificar" => js(cofre::verificar(
            a.get("caminho").and_then(Value::as_str).map(Path::new),
        )),
        "cofre.copiar_seguranca" => (|| {
            js(cofre::copiar_seguranca(logico(a, "forcar"))?
                .map(|p| p.to_string_lossy().into_owned()))
        })(),
        "cofre.manutencao" => cofre::manutencao(),
        "cofre.compactar_arquivo" => cofre::compactar_arquivo(logico(a, "forcar")),
        "cofre.situacao_protecao" => Ok(cofre::situacao_protecao()),
        "cofre.recuperacoes" => js(cofre::recuperacoes()),
        "cofre.apagar_dono" => (|| js(cofre::apagar_dono(texto(a, "dono")?)?))(),
        "cofre.limpar_temporarios" => js(cofre::limpar_temporarios(
            a.get("mais_velhos_que_s")
                .and_then(Value::as_f64)
                .unwrap_or(86400.0),
        )),

        _ => return None,
    })
}
