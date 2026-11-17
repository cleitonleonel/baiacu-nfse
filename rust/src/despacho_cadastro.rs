//! Porta do núcleo: texto, catálogos e cadastros (ver `despacho`).
use serde_json::{Value, json};

use crate::cadastro::{self, PrestadorForm, ServicoForm, TomadorForm};
use crate::despacho::{inteiro, js, lista_de_textos, logico, texto, texto_ou};
use crate::erro::{Erro, Res};
use crate::{catalogo, texto as tx};

fn form<T: serde::de::DeserializeOwned>(a: &Value, nome: &str) -> Res<T> {
    let v = a
        .get(nome)
        .ok_or_else(|| Erro::valor(format!("argumento '{nome}' ausente")))?;
    Ok(serde_json::from_value(v.clone())?)
}

fn opcional<'a>(a: &'a Value, nome: &str) -> Option<&'a str> {
    a.get(nome)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
}

fn pares(v: &[(String, String)]) -> Value {
    json!(v.iter().map(|(a, b)| json!([a, b])).collect::<Vec<_>>())
}

fn secoes(s: &cadastro::Secoes) -> Value {
    json!(
        s.iter()
            .map(|(nome, opcoes)| json!([
                nome,
                opcoes
                    .iter()
                    .map(|(k, v)| json!([k, v]))
                    .collect::<Vec<_>>()
            ]))
            .collect::<Vec<_>>()
    )
}

pub fn executar(metodo: &str, a: &Value) -> Option<Res<Value>> {
    Some(match metodo {
        "cadastro.ultimas_nfse_clientes" => {
            (|| js(crate::cofre::ultimas_por_tomador(texto(a, "prestador")?)?))()
        }
        "cadastro.contatos_tomadores" => {
            (|| js(cadastro::contatos_tomadores(texto(a, "prestador")?)?))()
        }
        // ---- texto ------------------------------------------------------------------ //
        "texto.only_digits" => texto(a, "valor").and_then(|v| js(tx::only_digits(v))),
        "texto.only_doc" => texto(a, "valor").and_then(|v| js(tx::only_doc(v))),
        "texto.only_chave" => texto(a, "valor").and_then(|v| js(tx::only_chave(v))),
        "texto.mascara_documento" => texto(a, "valor")
            .and_then(|v| js(tx::mascara_documento(v, texto_ou(a, "tipo_doc", "CNPJ")))),
        "texto.limpar_descricao" => texto(a, "valor").and_then(|v| js(tx::limpar_descricao(v))),
        "texto.descricao_problemas" => {
            texto(a, "valor").and_then(|v| js(tx::descricao_problemas(v)))
        }
        "texto.format_documento" => texto(a, "valor").and_then(|v| js(tx::format_documento(v))),
        "texto.cpf_valido" => texto(a, "valor").and_then(|v| js(tx::cpf_valido(v))),
        "texto.cnpj_valido" => texto(a, "valor").and_then(|v| js(tx::cnpj_valido(v))),
        "texto.documento_valido" => {
            texto(a, "valor").and_then(|v| js(tx::documento_valido(v, texto_ou(a, "tipo_doc", ""))))
        }
        "texto.norm_decimal" => texto(a, "valor").and_then(|v| js(tx::norm_decimal(v))),
        "texto.is_decimal" => texto(a, "valor").and_then(|v| js(tx::is_decimal(v))),
        "texto.sort_nome" => texto(a, "valor").and_then(|v| js(tx::sort_nome(v))),
        "texto.upper_text" => texto(a, "valor").and_then(|v| js(tx::upper_text(v))),
        "texto.lower_email" => texto(a, "valor").and_then(|v| js(tx::lower_email(v))),

        // ---- catálogos ---------------------------------------------------------------- //
        "catalogo.preload" => {
            catalogo::preload();
            Ok(Value::Null)
        }
        "catalogo.indop_options" => Ok(pares(catalogo::indop_options())),
        "catalogo.cst_options" => Ok(pares(catalogo::cst_options())),
        "catalogo.class_options" => texto(a, "cst").map(|c| pares(&catalogo::class_options(c))),
        "catalogo.tribnac_options" => Ok(pares(catalogo::tribnac_options())),
        "catalogo.nbs_options" => Ok(pares(catalogo::nbs_options())),
        "catalogo.valid_indop" => texto(a, "codigo").and_then(|c| js(catalogo::valid_indop(c))),
        "catalogo.valid_tribnac" => texto(a, "codigo").and_then(|c| js(catalogo::valid_tribnac(c))),
        "catalogo.valid_nbs" => texto(a, "codigo").and_then(|c| js(catalogo::valid_nbs(c))),
        "catalogo.valid_classification" => (|| {
            js(catalogo::valid_classification(
                texto(a, "cst")?,
                texto(a, "codigo")?,
            ))
        })(),

        // ---- prestadores -------------------------------------------------------------- //
        "cadastro.list_prestadores" => cadastro::list_prestadores().and_then(js),
        "cadastro.ultimo_prestador" => {
            (|| js(cadastro::ultimo_prestador(inteiro(a, "usuario_id")?)?))()
        }
        "cadastro.guardar_ultimo_prestador" => (|| {
            cadastro::guardar_ultimo_prestador(inteiro(a, "usuario_id")?, texto(a, "documento")?)?;
            Ok(Value::Null)
        })(),
        "cadastro.escolher_prestador_inicial" => js(cadastro::escolher_prestador_inicial(
            &lista_de_textos(a, "disponiveis"),
            texto_ou(a, "preferido", ""),
        )),
        "cadastro.get_prestador_form" => {
            (|| js(cadastro::get_prestador_form(texto(a, "prestador")?)?))()
        }
        "cadastro.save_prestador_form" => (|| {
            let f: PrestadorForm = form(a, "form")?;
            js(cadastro::save_prestador_form(texto(a, "prestador")?, &f)?)
        })(),
        "cadastro.prestador_validate" => (|| {
            let f: PrestadorForm = form(a, "form")?;
            js(f.validate())
        })(),
        "cadastro.create_prestador" => (|| {
            js(cadastro::create_prestador(
                texto(a, "documento")?,
                texto_ou(a, "xNome", ""),
                texto_ou(a, "tipo_doc", "CNPJ"),
            )?)
        })(),
        "cadastro.create_prestador_com_certificado" => (|| {
            js(cadastro::create_prestador_com_certificado(
                texto(a, "documento")?,
                texto_ou(a, "xNome", ""),
                texto_ou(a, "tipo_doc", "CNPJ"),
                texto(a, "caminho")?,
                texto(a, "senha")?,
                logico(a, "procurador"),
            )?)
        })(),

        // ---- certificado -------------------------------------------------------------- //
        "cadastro.cert_proprio" => (|| js(cadastro::cert_proprio(texto(a, "prestador")?)?))(),
        "cadastro.list_procuradores" => {
            (|| js(cadastro::list_procuradores(texto(a, "prestador")?)?))()
        }
        "cadastro.procuradores_info" => {
            (|| js(cadastro::procuradores_info(texto(a, "prestador")?)?))()
        }
        "cadastro.import_certificate_procurador" => (|| {
            js(cadastro::import_certificate_procurador(
                texto(a, "prestador")?,
                texto(a, "caminho")?,
                texto(a, "senha")?,
            )?)
        })(),
        "cadastro.delete_certificate" => (|| {
            cadastro::delete_certificate(texto(a, "prestador")?, texto(a, "cert")?)?;
            Ok(Value::Null)
        })(),
        "cadastro.cert_da_emissao" => (|| {
            let f: ServicoForm = form(a, "form")?;
            js(cadastro::cert_da_emissao(texto(a, "prestador")?, &f)?)
        })(),
        "cadastro.list_certificados" => {
            (|| js(cadastro::list_certificados(texto(a, "prestador")?)?))()
        }
        "cadastro.active_cert" => (|| js(cadastro::active_cert(texto(a, "prestador")?)?))(),
        "cadastro.tem_senha_do_certificado" => (|| {
            js(
                cadastro::read_cert_password(texto(a, "prestador")?, opcional(a, "cert"))?
                    .is_some(),
            )
        })(),
        "cadastro.import_certificate" => (|| {
            js(cadastro::import_certificate(
                texto(a, "prestador")?,
                texto(a, "caminho")?,
                texto(a, "senha")?,
            )?)
        })(),
        "cadastro.inspect_certificate" => (|| {
            let (documento, sujeito) =
                cadastro::inspect_certificate(texto(a, "caminho")?, texto(a, "senha")?)?;
            Ok(json!([documento, sujeito]))
        })(),
        "cadastro.cert_subject" => (|| {
            js(cadastro::cert_subject(
                texto(a, "prestador")?,
                opcional(a, "cert"),
            ))
        })(),
        "cadastro.cert_info" => {
            (|| cadastro::cert_info(texto(a, "prestador")?, opcional(a, "cert")))()
        }
        "cadastro.docs_compativeis" => (|| {
            js(cadastro::docs_compativeis(
                texto(a, "cert_doc")?,
                texto(a, "alvo_doc")?,
            ))
        })(),

        // ---- tributos ----------------------------------------------------------------- //
        "cadastro.read_tributos" => {
            (|| Ok(pares(&cadastro::read_tributos(texto(a, "prestador")?)?)))()
        }
        "cadastro.tributos_faltando" => {
            (|| js(cadastro::tributos_faltando(texto(a, "prestador")?)?))()
        }
        "cadastro.save_tributos" => (|| {
            Ok(pares(&cadastro::save_tributos(
                texto(a, "prestador")?,
                a.get("valores").unwrap_or(&Value::Null),
            )?))
        })(),

        // ---- clientes ----------------------------------------------------------------- //
        "cadastro.list_tomadores" => (|| js(cadastro::list_tomadores(texto(a, "prestador")?)?))(),
        "cadastro.delete_tomador" => (|| {
            cadastro::delete_tomador(texto(a, "prestador")?, texto(a, "tomador")?)?;
            Ok(Value::Null)
        })(),
        "cadastro.tomador_cadastrado" => (|| {
            js(cadastro::tomador_cadastrado(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
            )?)
        })(),
        "cadastro.get_tomador_form" => (|| {
            js(cadastro::get_tomador_form(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
            )?)
        })(),
        "cadastro.save_tomador_form" => (|| {
            let f: TomadorForm = form(a, "form")?;
            js(cadastro::save_tomador_form(texto(a, "prestador")?, &f)?)
        })(),
        "cadastro.tomador_validate" => (|| {
            let f: TomadorForm = form(a, "form")?;
            js(f.validate())
        })(),
        "cadastro.tomador_sections" => (|| {
            let f: TomadorForm = form(a, "form")?;
            Ok(secoes(&f.to_sections()))
        })(),
        "cadastro.rename_tomador" => (|| {
            cadastro::rename_tomador(
                texto(a, "prestador")?,
                texto(a, "antigo")?,
                texto(a, "novo")?,
            )?;
            Ok(Value::Null)
        })(),

        // ---- serviços ----------------------------------------------------------------- //
        "cadastro.servico_padroes" => js(ServicoForm::default()),
        "cadastro.list_servicos" => (|| {
            js(cadastro::list_servicos(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
            )?)
        })(),
        "cadastro.servico_slugs" => (|| {
            js(cadastro::servico_slugs(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
            )?)
        })(),
        "cadastro.get_servico" => (|| {
            js(cadastro::get_servico(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto(a, "servico")?,
            )?)
        })(),
        "cadastro.save_servico" => (|| {
            let f: ServicoForm = form(a, "form")?;
            js(cadastro::save_servico(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto(a, "servico")?,
                &f,
            )?)
        })(),
        "cadastro.delete_servico" => (|| {
            cadastro::delete_servico(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto(a, "servico")?,
            )?;
            Ok(Value::Null)
        })(),
        "cadastro.servico_validate" => (|| {
            let f: ServicoForm = form(a, "form")?;
            let mut erros = f.validate(logico(a, "require_rtc"));
            erros.extend(f.problemas_com_o_prestador(texto_ou(a, "prestador", "")));
            js(erros)
        })(),
        "cadastro.servico_sections" => (|| {
            let f: ServicoForm = form(a, "form")?;
            Ok(secoes(&f.to_sections()))
        })(),
        "cadastro.servico_padrao" => js(ServicoForm::default()),
        "cadastro.calcular_vencimento" => (|| {
            let referencia = tx::parse_iso_date(texto(a, "referencia")?)
                .ok_or_else(|| Erro::valor("Data de referência inválida."))?;
            let dia =
                u32::try_from(inteiro(a, "dia")?).map_err(|_| Erro::valor("Dia inválido."))?;
            let meses =
                u32::try_from(inteiro(a, "meses")?).map_err(|_| Erro::valor("Mês inválido."))?;
            js(crate::vencimento::calcular(referencia, dia, meses)?
                .format("%Y-%m-%d")
                .to_string())
        })(),
        "cadastro.detalhes_de_cobranca" => Ok(cadastro::detalhes_de_cobranca()),
        "cadastro.rtc_required" => (|| {
            let f: ServicoForm = form(a, "form")?;
            let competencia = opcional(a, "competencia")
                .map(|data| tx::parse_iso_date(data).ok_or_else(|| Erro::valor("Data de competência inválida.")))
                .transpose()?;
            js(cadastro::rtc_required(
                texto(a, "prestador")?,
                &f,
                texto(a, "ambiente")?,
                competencia,
            )?)
        })(),
        "cadastro.compose_active_config" => (|| {
            let f: Option<ServicoForm> = match a.get("form") {
                None | Some(Value::Null) => None,
                Some(v) => Some(serde_json::from_value(v.clone())?),
            };
            let ini = cadastro::compose_active_config(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto_ou(a, "servico", ""),
                f.as_ref(),
            )?;
            js(ini.para_texto())
        })(),

        // ---- ambiente, série, numeração ------------------------------------------------- //
        "cadastro.get_ambiente" => (|| js(cadastro::get_ambiente(texto(a, "prestador")?)?))(),
        "cadastro.set_ambiente" => (|| {
            cadastro::set_ambiente(texto(a, "prestador")?, texto(a, "ambiente")?)?;
            Ok(Value::Null)
        })(),
        "cadastro.get_serie" => (|| {
            js(cadastro::get_serie(
                texto(a, "prestador")?,
                texto(a, "ambiente")?,
            )?)
        })(),
        "cadastro.set_serie" => (|| {
            cadastro::set_serie(
                texto(a, "prestador")?,
                texto(a, "ambiente")?,
                texto(a, "serie")?,
            )?;
            Ok(Value::Null)
        })(),
        "cadastro.get_last_dps" => (|| {
            js(cadastro::get_last_dps(
                texto(a, "prestador")?,
                opcional(a, "ambiente"),
            )?)
        })(),
        "cadastro.get_proximo_dps" => (|| {
            js(cadastro::get_proximo_dps(
                texto(a, "prestador")?,
                opcional(a, "ambiente"),
            )?)
        })(),
        "cadastro.set_proximo_dps" => (|| {
            cadastro::set_proximo_dps(
                texto(a, "prestador")?,
                texto(a, "ambiente")?,
                inteiro(a, "proximo")?,
            )?;
            Ok(Value::Null)
        })(),

        // ---- grupos ------------------------------------------------------------------- //
        "cadastro.list_grupos" => (|| js(cadastro::list_grupos(texto_ou(a, "prestador", ""))?))(),
        "cadastro.add_grupo" => (|| {
            cadastro::add_grupo(texto(a, "prestador")?, texto_ou(a, "nome", ""))?;
            Ok(Value::Null)
        })(),
        "cadastro.rename_grupo" => (|| {
            cadastro::rename_grupo(
                texto(a, "prestador")?,
                texto(a, "antigo")?,
                texto_ou(a, "novo", ""),
            )?;
            Ok(Value::Null)
        })(),
        "cadastro.remove_grupo" => (|| {
            cadastro::remove_grupo(texto(a, "prestador")?, texto(a, "nome")?)?;
            Ok(Value::Null)
        })(),
        "cadastro.get_tomador_grupo" => (|| {
            js(cadastro::get_tomador_grupo(
                texto_ou(a, "prestador", ""),
                texto_ou(a, "tomador", ""),
            )?)
        })(),
        "cadastro.set_tomador_grupo" => (|| {
            cadastro::set_tomador_grupo(
                texto(a, "prestador")?,
                texto(a, "tomador")?,
                texto_ou(a, "grupo", ""),
            )?;
            Ok(Value::Null)
        })(),
        "cadastro.tomadores_grupos" => {
            (|| Ok(pares(&cadastro::tomadores_grupos(texto(a, "prestador")?)?)))()
        }

        _ => return None,
    })
}
