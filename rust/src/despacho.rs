//! Porta única do núcleo: `chamar("modulo.funcao", argumentos em JSON) -> JSON`.
//!
//! A tela (Dart, por FFI) entra por aqui. A resposta é sempre
//! `{"ok": valor}` ou `{"erro": {"tipo": ..., "msg": ...}}` — o `tipo` é a classe de exceção que
//! o programa em Python levantava (ver `erro`).
use std::path::Path;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use crate::erro::{Erro, Res};
use crate::usuarios::Usuario;
use crate::{banco, caminhos, chaves, registro, segredos, usuarios};

/// Por onde uma chamada demorada avisa do andamento (cada aviso é um JSON).
pub type Avisar<'a> = &'a dyn Fn(&Value);

/// Chama e embrulha o resultado/erro no envelope; as chamadas demoradas avisam do andamento.
pub fn chamar_avisando(metodo: &str, args: &Value, avisar: Avisar) -> Value {
    match executar(metodo, args, avisar) {
        Ok(v) => json!({ "ok": v }),
        Err(e) => match e.dados {
            Some(d) => json!({ "erro": { "tipo": e.tipo, "msg": e.msg, "dados": d } }),
            None => json!({ "erro": { "tipo": e.tipo, "msg": e.msg } }),
        },
    }
}

// ---- cancelamento ------------------------------------------------------------------ //
// Quem começa uma operação demorada manda uma FICHA (um texto qualquer, único); para cancelar,
// a tela chama `nucleo.cancelar` com a mesma ficha.
fn fichas() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static F: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> =
        std::sync::OnceLock::new();
    F.get_or_init(Default::default)
}

/// A operação desta ficha foi cancelada?
pub fn cancelada(ficha: &str) -> bool {
    !ficha.is_empty() && fichas().lock().map(|f| f.contains(ficha)).unwrap_or(false)
}

pub fn cancelar(ficha: &str) {
    if let Ok(mut f) = fichas().lock() {
        f.insert(ficha.to_string());
    }
}

/// A operação acabou: a ficha não é mais lembrada.
pub fn esquecer_ficha(ficha: &str) {
    if let Ok(mut f) = fichas().lock() {
        f.remove(ficha);
    }
}

// ---- leitura de argumentos --------------------------------------------------------- //
pub(crate) fn texto<'a>(a: &'a Value, nome: &str) -> Res<&'a str> {
    a.get(nome)
        .and_then(Value::as_str)
        .ok_or_else(|| Erro::valor(format!("argumento '{nome}' ausente")))
}

pub(crate) fn texto_ou<'a>(a: &'a Value, nome: &str, padrao: &'a str) -> &'a str {
    a.get(nome).and_then(Value::as_str).unwrap_or(padrao)
}

pub(crate) fn inteiro(a: &Value, nome: &str) -> Res<i64> {
    a.get(nome)
        .and_then(Value::as_i64)
        .ok_or_else(|| Erro::valor(format!("argumento '{nome}' ausente")))
}

pub(crate) fn logico(a: &Value, nome: &str) -> bool {
    a.get(nome).and_then(Value::as_bool).unwrap_or(false)
}

pub(crate) fn usuario(a: &Value, nome: &str) -> Res<Usuario> {
    let v = a
        .get(nome)
        .ok_or_else(|| Erro::valor(format!("argumento '{nome}' ausente")))?;
    Ok(serde_json::from_value(v.clone())?)
}

pub(crate) fn usuario_opcional(a: &Value, nome: &str) -> Res<Option<Usuario>> {
    match a.get(nome) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => Ok(Some(serde_json::from_value(v.clone())?)),
    }
}

pub(crate) fn lista_de_textos(a: &Value, nome: &str) -> Vec<String> {
    a.get(nome)
        .and_then(Value::as_array)
        .map(|v| {
            v.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

pub(crate) fn bytes_b64(a: &Value, nome: &str) -> Res<Option<Vec<u8>>> {
    match a.get(nome) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => {
            let s = v
                .as_str()
                .ok_or_else(|| Erro::valor(format!("argumento '{nome}' inválido")))?;
            Ok(Some(STANDARD.decode(s).map_err(|_| {
                Erro::valor(format!("argumento '{nome}' inválido"))
            })?))
        }
    }
}

pub(crate) fn js<T: serde::Serialize>(v: T) -> Res<Value> {
    Ok(serde_json::to_value(v)?)
}

fn executar(metodo: &str, a: &Value, avisar: Avisar) -> Res<Value> {
    match metodo {
        "nucleo.cancelar" => {
            cancelar(texto(a, "ficha")?);
            Ok(Value::Null)
        }
        // ---- núcleo --------------------------------------------------------------- //
        "nucleo.versao" => js(crate::versao()),
        "nucleo.definir_raiz" => {
            caminhos::definir_raiz(texto(a, "raiz")?);
            js(caminhos::raiz().to_string_lossy())
        }
        "nucleo.raiz" => js(caminhos::raiz().to_string_lossy()),

        // ---- registro -------------------------------------------------------------- //
        "registro.registrar" => {
            let nivel = match texto_ou(a, "nivel", "info") {
                "debug" => registro::Nivel::Debug,
                "warning" => registro::Nivel::Warning,
                "error" => registro::Nivel::Error,
                "critical" => registro::Nivel::Critical,
                _ => registro::Nivel::Info,
            };
            registro::registrar(texto(a, "nome")?, nivel, texto(a, "msg")?);
            Ok(Value::Null)
        }
        "registro.sincronizar" => {
            registro::sincronizar();
            Ok(Value::Null)
        }
        "registro.definir_usuario" => {
            registro::definir_usuario(
                a.get("operador_id").and_then(Value::as_i64),
                a.get("autorizador_id").and_then(Value::as_i64),
            );
            Ok(Value::Null)
        }

        // ---- banco ----------------------------------------------------------------- //
        "banco.estado" => js(banco::estado()),
        "banco.destrancado" => js(banco::destrancado()),
        "banco.trancar" => {
            banco::trancar();
            Ok(Value::Null)
        }
        "banco.get_meta" => js(banco::get_meta(texto(a, "chave")?)?),
        "banco.set_meta" => {
            banco::set_meta(texto(a, "chave")?, texto(a, "valor")?)?;
            Ok(Value::Null)
        }
        "banco.validar_banco" => {
            banco::validar_banco(
                Path::new(texto(a, "caminho")?),
                texto_ou(a, "senha_mestra", ""),
            )?;
            Ok(Value::Null)
        }
        "banco.restaurar_de" => {
            banco::restaurar_de(
                Path::new(texto(a, "origem")?),
                texto_ou(a, "senha_mestra", ""),
            )?;
            Ok(Value::Null)
        }

        // ---- chaves ---------------------------------------------------------------- //
        "chaves.nova_senha_mestra" => js(chaves::nova_senha_mestra()),
        "chaves.criar_banco" => js(chaves::criar_banco()?),
        "chaves.desfazer_criacao" => {
            chaves::desfazer_criacao();
            Ok(Value::Null)
        }
        "chaves.verificar_senha_mestra" => js(chaves::verificar_senha_mestra(texto(a, "senha")?)),
        "chaves.destrancar_com_mestra" => js(chaves::destrancar_com_mestra(texto(a, "senha")?)?),
        "chaves.arquivo_integro" => js(chaves::arquivo_integro()),
        "chaves.sincronizar" => js(chaves::sincronizar()?),
        "chaves.conferir" => {
            chaves::conferir(texto(a, "motivo")?)?;
            Ok(Value::Null)
        }
        "chaves.trocar_senha_mestra" => {
            chaves::trocar_senha_mestra(texto(a, "nova")?)?;
            Ok(Value::Null)
        }

        // ---- usuários -------------------------------------------------------------- //
        "usuarios.normalizar_login" => js(usuarios::normalizar_login(texto(a, "login")?)),
        "usuarios.normalizar_nome" => js(usuarios::normalizar_nome(texto(a, "nome")?)),
        "usuarios.validar_senha" => js(usuarios::validar_senha(texto(a, "senha")?)),
        "usuarios.validar_credenciais_novas" => js(usuarios::validar_credenciais_novas(
            texto(a, "login")?,
            texto(a, "senha")?,
            texto(a, "confirma")?,
            texto_ou(a, "nome", ""),
        )),
        "usuarios.tem_usuarios" => js(usuarios::tem_usuarios()?),
        "usuarios.autenticar" => js(usuarios::autenticar(
            texto(a, "login")?,
            texto(a, "senha")?,
        )?),
        "usuarios.entrar" => js(usuarios::entrar(texto(a, "login")?, texto(a, "senha")?)?),
        "usuarios.autenticar_por_senha" => {
            let (u, ambiguo) = usuarios::autenticar_por_senha(
                texto(a, "senha")?,
                a.get("nivel_minimo").and_then(Value::as_i64).unwrap_or(1),
            )?;
            Ok(json!({ "usuario": u, "ambiguo": ambiguo }))
        }
        "usuarios.por_login" => js(usuarios::por_login(texto(a, "login")?)?),
        "usuarios.prestadores_vinculados" => {
            js(usuarios::prestadores_vinculados(inteiro(a, "usuario_id")?)?)
        }
        "usuarios.prestadores_permitidos" => {
            js(usuarios::prestadores_permitidos(&usuario(a, "usuario")?)?)
        }
        "usuarios.vincular_prestador" => {
            usuarios::vincular_prestador(
                inteiro(a, "usuario_id")?,
                texto(a, "prestador")?,
                usuario_opcional(a, "por")?.as_ref(),
            )?;
            Ok(Value::Null)
        }
        "usuarios.desvincular_prestador" => {
            usuarios::desvincular_prestador(
                inteiro(a, "usuario_id")?,
                texto(a, "prestador")?,
                usuario_opcional(a, "por")?.as_ref(),
            )?;
            Ok(Value::Null)
        }
        "usuarios.esquecer_prestador" => {
            usuarios::esquecer_prestador(texto(a, "prestador")?)?;
            Ok(Value::Null)
        }
        "usuarios.criar" => js(usuarios::criar(
            texto(a, "login")?,
            texto(a, "nome")?,
            inteiro(a, "nivel")?,
            texto(a, "senha")?,
            &lista_de_textos(a, "prestadores"),
            usuario_opcional(a, "criado_por")?.as_ref(),
        )?),
        "usuarios.listar" => js(usuarios::listar()?),
        "usuarios.definir_ativo" => {
            usuarios::definir_ativo(
                inteiro(a, "usuario_id")?,
                logico(a, "ativo"),
                &usuario(a, "por")?,
            )?;
            Ok(Value::Null)
        }
        "usuarios.promover" => js(usuarios::promover(
            inteiro(a, "usuario_id")?,
            &usuario(a, "por")?,
        )?),
        "usuarios.rebaixar" => js(usuarios::rebaixar(
            inteiro(a, "usuario_id")?,
            &usuario(a, "por")?,
        )?),
        "usuarios.excluir" => {
            usuarios::excluir(inteiro(a, "usuario_id")?, &usuario(a, "por")?)?;
            Ok(Value::Null)
        }
        "usuarios.redefinir_senha" => {
            usuarios::redefinir_senha(
                inteiro(a, "usuario_id")?,
                texto(a, "nova_senha")?,
                &usuario(a, "por")?,
            )?;
            Ok(Value::Null)
        }
        "usuarios.trocar_propria_senha" => {
            usuarios::trocar_propria_senha(
                &usuario(a, "usuario")?,
                texto(a, "senha_atual")?,
                texto(a, "nova_senha")?,
            )?;
            Ok(Value::Null)
        }
        "usuarios.master_login" => js(usuarios::master_login()?),
        "usuarios.redefinir_senha_master" => js(usuarios::redefinir_senha_master(
            texto(a, "nova_senha")?,
            texto_ou(a, "novo_login", ""),
            texto_ou(a, "novo_nome", ""),
        )?),
        "usuarios.get_foto" => {
            js(usuarios::get_foto(inteiro(a, "usuario_id")?)?.map(|b| STANDARD.encode(b)))
        }
        "usuarios.set_foto" => {
            usuarios::set_foto(inteiro(a, "usuario_id")?, bytes_b64(a, "dados")?.as_deref())?;
            Ok(Value::Null)
        }
        // A tela entrega o recorte já no tamanho final, em RGBA; aqui ele vira o JPEG
        // (qualidade 90) que sempre foi guardado.
        "usuarios.set_foto_rgba" => {
            let rgba = bytes_b64(a, "rgba")?.unwrap_or_default();
            let (largura, altura) = (inteiro(a, "largura")?, inteiro(a, "altura")?);
            if largura <= 0
                || altura <= 0
                || largura > 4096
                || altura > 4096
                || rgba.len() != (largura * altura * 4) as usize
            {
                return Err(Erro::valor("Imagem inválida."));
            }
            let mut jpeg = Vec::new();
            let mut codificador = jpeg_encoder::Encoder::new(&mut jpeg, 90);
            codificador.set_sampling_factor(jpeg_encoder::SamplingFactor::F_2_2);
            codificador
                .encode(
                    &rgba,
                    largura as u16,
                    altura as u16,
                    jpeg_encoder::ColorType::Rgba,
                )
                .map_err(|e| Erro::valor(format!("Não foi possível gravar a imagem: {e}")))?;
            usuarios::set_foto(inteiro(a, "usuario_id")?, Some(&jpeg))?;
            Ok(Value::Null)
        }

        // ---- validação --------------------------------------------------------------- //
        "validacao.caminho_xsd" => js(crate::validacao::caminho_xsd_validacao()?.to_string_lossy()),
        "validacao.validar_dps" => {
            crate::validacao::validar_dps(&bytes_b64(a, "xml")?.unwrap_or_default())?;
            Ok(Value::Null)
        }
        "validacao.validar_dps_sem_assinatura" => {
            crate::validacao::validar_dps_sem_assinatura(&bytes_b64(a, "xml")?.unwrap_or_default())
        }

        // ---- segredos -------------------------------------------------------------- //
        "segredos.tem_cert_pfx" => js(segredos::tem_cert_pfx(texto(a, "cert")?)?),

        _ => crate::despacho_cadastro::executar(metodo, a)
            .or_else(|| crate::despacho_emissao::executar(metodo, a))
            .or_else(|| crate::despacho_cofre::executar(metodo, a, avisar))
            .or_else(|| crate::despacho_diversos::executar(metodo, a, avisar))
            .or_else(|| crate::despacho_correio::executar(metodo, a))
            .or_else(|| crate::despacho_exportacao::executar(metodo, a, avisar))
            .unwrap_or_else(|| Err(Erro::valor(format!("método desconhecido: {metodo}")))),
    }
}
