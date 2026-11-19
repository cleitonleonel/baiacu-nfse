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
    envelope(com_acesso(metodo, || {
        registro::com_operador(crate::permissoes::operador_id(), || executar(metodo, args, avisar))
    }))
}

#[cfg(windows)]
pub(crate) fn chamar_local(metodo: &str, args: &Value, avisar: Avisar) -> Value {
    envelope(executar(metodo, args, avisar))
}

#[cfg(windows)]
pub(crate) fn chamar_servico(
    metodo: &str, args: &Value, avisar: Avisar, autorizar: impl FnOnce() -> Res<()>,
) -> Value {
    envelope(com_acesso(metodo, || {
        autorizar()?;
        registro::com_operador(crate::permissoes::operador_id(), || executar(metodo, args, avisar))
    }))
}

pub(crate) fn com_acesso<T>(metodo: &str, executar: impl FnOnce() -> Res<T>) -> Res<T> {
    use crate::backup::{ACESSO, verificar_recuperacao};
    if metodo == "registro.registrar" {
        return executar();
    }
    if matches!(metodo, "backup.restaurar" | "banco.restaurar_de" | "nucleo.definir_raiz") {
        let _exclusivo = ACESSO.try_write().or_else(|e| match e {
            std::sync::TryLockError::Poisoned(p) => Ok(p.into_inner()),
            std::sync::TryLockError::WouldBlock => Err(Erro::runtime(
                "Há operações em andamento. Aguarde que terminem e tente novamente.",
            )),
        })?;
        if metodo != "nucleo.definir_raiz" {
            verificar_recuperacao()?;
        }
        return executar();
    }
    let _acesso = ACESSO.try_read().or_else(|e| match e {
        std::sync::TryLockError::Poisoned(p) => Ok(p.into_inner()),
        std::sync::TryLockError::WouldBlock => Err(Erro::runtime(
            "A restauração do backup está em andamento. Tente novamente ao concluir.",
        )),
    })?;
    verificar_recuperacao()?;
    executar()
}

pub(crate) fn envelope(resultado: Res<Value>) -> Value {
    match resultado {
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
static FICHAS: crate::contexto_cliente::PorCliente<std::collections::HashSet<String>> =
    crate::contexto_cliente::PorCliente::novo();

/// A operação desta ficha foi cancelada?
pub fn cancelada(ficha: &str) -> bool {
    !ficha.is_empty() && FICHAS.lock().is_ok_and(|f| f.contains(ficha))
}

pub fn cancelar(ficha: &str) {
    if let Ok(mut f) = FICHAS.lock() {
        f.insert(ficha.into());
    }
}

/// A operação acabou: a ficha não é mais lembrada.
pub fn esquecer_ficha(ficha: &str) {
    if let Ok(mut f) = FICHAS.lock() {
        f.remove(ficha);
    }
}

#[cfg(windows)]
pub(crate) fn esquecer_cliente(pid: u32) {
    FICHAS.esquecer(pid);
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
    crate::permissoes::usuario_alvo(serde_json::from_value(v.clone())?)
}

fn autorizador(a: &Value, nome: &str, chave: &str) -> Res<Usuario> {
    let valor = a
        .get(nome)
        .ok_or_else(|| Erro::valor("Informe o usuário responsável."))?;
    crate::permissoes::validar_actor(chave, serde_json::from_value(valor.clone())?)
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

fn chave_preferencia(a: &Value, gravar: bool) -> Res<String> {
    let chave = texto(a, "chave")?;
    match chave {
        "ui.animacao_login" => Ok(chave.into()),
        "ui.pdf_nativo" | "ui.minimizar_ao_fechar" => {
            match a["prestador"].as_str().filter(|p| !p.is_empty()) {
                Some(p) => Ok(format!("{chave}.{}", crate::cofre::so_doc(p))),
                None if !gravar => Ok(chave.into()),
                None => Err(Erro::valor("Selecione um prestador.")),
            }
        }
        _ => Err(Erro::valor("Esta preferência não pode ser acessada diretamente.")),
    }
}

fn executar(metodo: &str, a: &Value, avisar: Avisar) -> Res<Value> {
    if metodo.starts_with("permissoes.") {
        return crate::permissoes::executar(metodo, a);
    }
    crate::permissoes::checar_escopo(metodo, a)?;
    crate::permissoes::checar_metodo(metodo, a)?;
    if metodo.starts_with("lotes.") { return crate::lotes::executar(metodo,a); }
    match metodo {
        "nucleo.cancelar" => {
            cancelar(texto(a, "ficha")?);
            Ok(Value::Null)
        }
        // ---- núcleo --------------------------------------------------------------- //
        "nucleo.versao" => js(crate::versao()),
        "nucleo.definir_raiz" => {
            crate::permissoes::definir_sessao(None)?;
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
            let nome = texto(a, "nome")?;
            if !nome.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
                || nome.eq_ignore_ascii_case("autorizacao")
            {
                return Err(Erro::valor("Categoria de registro inválida."));
            }
            registro::registrar(nome, nivel, &texto(a, "msg")?.replace(['\r', '\n'], " "));
            Ok(Value::Null)
        }
        "registro.sincronizar" => {
            registro::sincronizar();
            Ok(Value::Null)
        }
        "registro.situacao" => Ok(registro::situacao()),
        "registro.configurar" => registro::configurar(
            a.get("max_mb").and_then(Value::as_u64).unwrap_or(0),
            a.get("dias").and_then(Value::as_u64).unwrap_or(0) as u32,
            a.get("mascarar").and_then(Value::as_bool).unwrap_or(true),
        ),
        "registro.exportar_suporte" => registro::exportar_suporte(
            Path::new(texto(a, "destino")?),
            a.get("dias").and_then(Value::as_u64).unwrap_or(30) as u32,
        ),
        // Compatibilidade com clientes antigos. A autoria vem da sessão no núcleo.
        "registro.definir_usuario" => Ok(Value::Null),

        // ---- banco ----------------------------------------------------------------- //
        "banco.estado" => js(banco::estado()),
        "banco.destrancado" => js(banco::destrancado()),
        "banco.trancar" => {
            crate::permissoes::definir_sessao(None)?;
            banco::trancar();
            Ok(Value::Null)
        }
        "banco.get_meta" => {
            let chave = chave_preferencia(a, false)?;
            let valor = banco::get_meta(&chave)?;
            if valor.is_empty() && chave != texto(a, "chave")? {
                return js(banco::get_meta(texto(a, "chave")?)?);
            }
            js(valor)
        }
        "banco.set_meta" => {
            banco::set_meta(&chave_preferencia(a, true)?, texto(a, "valor")?)?;
            Ok(Value::Null)
        }
        "banco.validar_banco" => {
            caminhos::arquivo_usuario(|| banco::validar_banco(
                Path::new(texto(a, "caminho")?),
                texto_ou(a, "senha_mestra", ""),
            ))?;
            Ok(Value::Null)
        }
        "banco.restaurar_de" => {
            banco::restaurar_externo(
                Path::new(texto(a, "origem")?),
                texto_ou(a, "senha_mestra", ""),
            )?;
            Ok(Value::Null)
        }

        // ---- chaves ---------------------------------------------------------------- //
        "chaves.nova_senha_mestra" => js(chaves::nova_senha_mestra()),
        "chaves.criar_banco" => js(chaves::criar_banco()?),
        "chaves.desfazer_criacao" => {
            if !banco::destrancado() || usuarios::tem_usuarios()? {
                return Err(Erro::valor("O banco já está protegido ou possui usuários."));
            }
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
            let senha = texto(a, "senha")?;
            let (u, ambiguo) = match a.get("permissao").and_then(Value::as_str) {
                Some(chave) => crate::permissoes::autenticar_autorizacao(chave, senha)?,
                None => {
                    usuarios::autenticar_por_senha(senha, a["nivel_minimo"].as_i64().unwrap_or(1))?
                }
            };
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
                &autorizador(a, "por", "usuarios.prestadores")?,
            )?;
            Ok(Value::Null)
        }
        "usuarios.desvincular_prestador" => {
            usuarios::desvincular_prestador(
                inteiro(a, "usuario_id")?,
                texto(a, "prestador")?,
                &autorizador(a, "por", "usuarios.prestadores")?,
            )?;
            Ok(Value::Null)
        }
        "usuarios.esquecer_prestador" => {
            usuarios::esquecer_prestador(texto(a, "prestador")?)?;
            Ok(Value::Null)
        }
        "usuarios.criar" => {
            let prestadores = lista_de_textos(a, "prestadores");
            let por = if a.get("criado_por").is_none_or(Value::is_null) {
                None
            } else {
                if prestadores.iter().any(|p| !p.trim().is_empty()) {
                    crate::permissoes::exigir("usuarios.prestadores")?;
                }
                Some(autorizador(a, "criado_por", "usuarios.adicionar")?)
            };
            js(usuarios::criar_com_codigo(
                texto(a, "login")?,
                texto(a, "nome")?,
                inteiro(a, "nivel")?,
                texto(a, "senha")?,
                &prestadores,
                por.as_ref(),
                Some(texto_ou(a, "codigo", "")),
            )?)
        }
        // Código de autorização: a conta em uso consulta e troca o PRÓPRIO; o cadastro de uma
        // conta nova confere a disponibilidade antes de criar.
        "usuarios.codigo_proprio" => {
            js(usuarios::codigo_de(crate::permissoes::operador_atual()?.id)?)
        }
        "usuarios.conferir_codigo" => {
            let operador = crate::permissoes::operador_atual()?;
            let proprio = logico(a, "proprio");
            js(usuarios::conferir_codigo(
                texto(a, "codigo")?,
                proprio.then_some(operador.id),
            )?)
        }
        "usuarios.definir_codigo_proprio" => {
            let operador = crate::permissoes::operador_atual()?;
            let codigo = usuarios::definir_codigo(operador.id, texto(a, "codigo")?)?;
            crate::registro::info(
                "usuarios",
                &format!("Código de autorização definido pela conta #{}.", operador.id),
            );
            js(codigo)
        }
        "usuarios.redefinir_codigo" => {
            let alvo = inteiro(a, "usuario_id")?;
            let por = crate::permissoes::autorizador("usuarios.senha", None)?
                .ok_or_else(|| Erro::valor("Autorize a redefinição do código."))?;
            let codigo = usuarios::redefinir_codigo(alvo, texto(a, "codigo")?, &por)?;
            crate::registro::info("usuarios", &format!(
                "Código de autorização da conta #{alvo} redefinido pela conta #{}.", por.id
            ));
            js(codigo)
        }
        "usuarios.listar" => js(usuarios::listar()?),
        "usuarios.definir_ativo" => {
            usuarios::definir_ativo(
                inteiro(a, "usuario_id")?,
                logico(a, "ativo"),
                &autorizador(a, "por", "usuarios.ativar")?,
            )?;
            Ok(Value::Null)
        }
        "usuarios.promover" => js(usuarios::promover(
            inteiro(a, "usuario_id")?,
            &autorizador(a, "por", "usuarios.promover")?,
        )?),
        "usuarios.rebaixar" => js(usuarios::rebaixar(
            inteiro(a, "usuario_id")?,
            &autorizador(a, "por", "usuarios.rebaixar")?,
        )?),
        "usuarios.excluir" => {
            usuarios::excluir(
                inteiro(a, "usuario_id")?,
                &autorizador(a, "por", "usuarios.excluir")?,
            )?;
            Ok(Value::Null)
        }
        "usuarios.redefinir_senha" => {
            usuarios::redefinir_senha(
                inteiro(a, "usuario_id")?,
                texto(a, "nova_senha")?,
                &autorizador(a, "por", "usuarios.senha")?,
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
        "usuarios.redefinir_senha_master" => {
            if !chaves::destrancar_com_mestra(texto(a, "senha_mestra")?)? {
                return Err(Erro::valor("Senha mestra incorreta."));
            }
            crate::permissoes::definir_sessao(None)?;
            js(usuarios::redefinir_senha_master(
                texto(a, "nova_senha")?,
                texto_ou(a, "novo_login", ""),
                texto_ou(a, "novo_nome", ""),
            )?)
        }
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
