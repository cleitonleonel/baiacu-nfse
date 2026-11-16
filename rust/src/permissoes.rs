//! Permissões por nível: catálogo fechado, herança por máximo e sessão autenticada.
use crate::{
    banco,
    erro::{Erro, Res},
    usuarios,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{Mutex, MutexGuard, OnceLock},
    time::{Duration, Instant},
};

pub const META: &str = "seguranca.permissoes_nivel.v1";
const EDITAR_PERFIL: &str = "usuarios.permissoes";
const TROCAR_MESTRA: &str = "config.senha_mestra";
const DURACAO: Duration = Duration::from_secs(300);
static SESSAO: Mutex<Option<Sessao>> = Mutex::new(None);

struct Sessao {
    operador: usuarios::Usuario,
    autorizacoes: Vec<Autorizacao>,
}

struct Autorizacao {
    chave: String,
    usuario: usuarios::Usuario,
    nivel_autorizado: i64,
    inicio: Instant,
}

#[derive(Deserialize, Serialize)]
pub struct Regra {
    pub id: String,
    pub rotulo: String,
    pub pai: String,
    pub padrao: i64,
    pub fixo: bool,
    pub metodos: Vec<String>,
}
pub fn catalogo() -> &'static [Regra] {
    static CATALOGO: OnceLock<Vec<Regra>> = OnceLock::new();
    CATALOGO.get_or_init(|| {
        serde_json::from_str(include_str!("../recursos/permissoes.json"))
            .expect("catálogo compilado inválido")
    })
}

fn sessao() -> Res<MutexGuard<'static, Option<Sessao>>> {
    SESSAO
        .lock()
        .map_err(|_| Erro::runtime("Sessão indisponível"))
}

pub(crate) fn definir_sessao(operador: Option<&usuarios::Usuario>) -> Res<()> {
    *sessao()? = operador.cloned().map(|operador| Sessao {
        operador,
        autorizacoes: Vec::new(),
    });
    Ok(())
}

pub fn limpar_autorizacoes() {
    if let Ok(mut sessao) = sessao() {
        if let Some(sessao) = sessao.as_mut() {
            sessao.autorizacoes.clear();
        }
    }
}

fn usuario_atual(u: &usuarios::Usuario) -> Res<usuarios::Usuario> {
    let atual = usuarios::por_id(u.id)?;
    if atual.login == u.login && atual.ativo {
        Ok(atual)
    } else {
        Err(Erro::valor("Usuário da sessão não está ativo."))
    }
}

fn sessao_ativa(sessao: &Option<Sessao>) -> Res<&Sessao> {
    sessao
        .as_ref()
        .ok_or_else(|| Erro::valor("Entre no programa para continuar."))
}
pub fn validar(v: &Value) -> Res<BTreeMap<String, i64>> {
    if v["formato"] != "baiacu-permissoes" || v["versao"] != 1 {
        return Err(Erro::valor("Formato de permissões incompatível."));
    }
    let valores = v["niveis"]
        .as_object()
        .ok_or_else(|| Erro::valor("Lista de permissões ausente."))?;
    let defs = catalogo();
    let mut result = BTreeMap::new();
    for (key, value) in valores {
        let regra = defs
            .iter()
            .find(|r| r.id == *key)
            .ok_or_else(|| Erro::valor(format!("Permissão desconhecida: {key}")))?;
        let level = value
            .as_i64()
            .filter(|n| (1..=4).contains(n))
            .ok_or_else(|| Erro::valor(format!("Nível inválido em {key}")))?;
        if regra.fixo && level != 4 {
            return Err(Erro::valor(format!("{} exige nível 4.", regra.rotulo)));
        }
        result.insert(key.clone(), level);
    }
    for regra in defs {
        if result.contains_key(&regra.id) {
            continue;
        }
        // Os perfis exportados antes da aba Geral ainda usam o mesmo formato.
        if regra.id == "config.geral" {
            result.insert(regra.id.clone(), regra.padrao);
        } else {
            return Err(Erro::valor(
                "O arquivo não contém todas as permissões desta versão.",
            ));
        }
    }
    Ok(result)
}
pub fn niveis() -> Res<BTreeMap<String, i64>> {
    let raw = banco::get_meta(META)?;
    if raw.is_empty() {
        return Ok(catalogo()
            .iter()
            .map(|r| (r.id.clone(), r.padrao))
            .collect());
    }
    let value: Value = serde_json::from_str(&raw)?;
    if value["formato"] != "baiacu-permissoes" || value["versao"] != 1 {
        return Err(Erro::valor("Perfil de permissões incompatível."));
    }
    let saved = value["niveis"]
        .as_object()
        .ok_or_else(|| Erro::valor("Perfil de permissões inválido."))?;
    let mut merged = BTreeMap::new();
    for r in catalogo() {
        let level = match saved.get(&r.id) {
            Some(v) => v
                .as_i64()
                .filter(|n| (1..=4).contains(n))
                .ok_or_else(|| Erro::valor("Nível salvo inválido."))?,
            None => r.padrao,
        };
        merged.insert(r.id.clone(), if r.fixo { 4 } else { level });
    }
    Ok(merged)
}
pub fn efetivo(key: &str, levels: &BTreeMap<String, i64>) -> Res<i64> {
    let defs = catalogo();
    let mut current = key;
    let mut level = 1;
    loop {
        let d = defs
            .iter()
            .find(|r| r.id == current)
            .ok_or_else(|| Erro::valor(format!("Permissão desconhecida: {current}")))?;
        level = level.max(if d.fixo {
            4
        } else {
            *levels.get(current).unwrap_or(&d.padrao)
        });
        if d.pai.is_empty() {
            break;
        }
        current = &d.pai;
    }
    Ok(level)
}
pub fn minimo(key: &str) -> Res<i64> {
    efetivo(key, &niveis()?)
}

fn autorizador(key: &str, informado: Option<i64>) -> Res<Option<usuarios::Usuario>> {
    let sessao = sessao()?;
    let sessao = sessao_ativa(&sessao)?;
    let operador = usuario_atual(&sessao.operador)?;
    let need = minimo(key)?;
    if key != TROCAR_MESTRA
        && operador.nivel >= need
        && informado.is_none_or(|id| id == operador.id)
    {
        return Ok(Some(operador));
    }
    if key == EDITAR_PERFIL {
        return Ok(None);
    }
    for auth in sessao.autorizacoes.iter().rev() {
        let cobre_acao = key == auth.chave
            || key != TROCAR_MESTRA
                && key
                    .strip_prefix(&auth.chave)
                    .is_some_and(|s| s.starts_with('.'));
        if cobre_acao
            && auth.nivel_autorizado >= need
            && auth.inicio.elapsed() < DURACAO
            && informado.is_none_or(|id| id == auth.usuario.id)
        {
            if let Ok(atual) = usuario_atual(&auth.usuario) {
                if atual.nivel >= need {
                    return Ok(Some(atual));
                }
            }
        }
    }
    Ok(None)
}

pub fn permitido(key: &str) -> Res<bool> {
    Ok(autorizador(key, None)?.is_some())
}
pub fn exigir(key: &str) -> Res<()> {
    if permitido(key)? {
        Ok(())
    } else {
        Err(Erro::novo(
            "PermissaoNegada",
            format!("Esta ação exige nível {} ou superior.", minimo(key)?),
        ))
    }
}
pub(crate) fn autenticar_autorizacao(
    key: &str,
    senha: &str,
) -> Res<(Option<usuarios::Usuario>, bool)> {
    if key == EDITAR_PERFIL {
        exigir(key)?;
    }
    let mut sessao = sessao()?;
    let sessao = sessao
        .as_mut()
        .ok_or_else(|| Erro::valor("Entre no programa para continuar."))?;
    usuario_atual(&sessao.operador)?;
    let nivel_autorizado = minimo(key)?;
    let (usuario, ambiguo) = usuarios::autenticar_por_senha(senha, nivel_autorizado)?;
    if let Some(usuario) = &usuario {
        sessao
            .autorizacoes
            .retain(|a| a.chave != key && a.inicio.elapsed() < DURACAO);
        sessao.autorizacoes.push(Autorizacao {
            chave: key.into(),
            usuario: usuario.clone(),
            nivel_autorizado,
            inicio: Instant::now(),
        });
    }
    Ok((usuario, ambiguo))
}
pub fn documento(levels: BTreeMap<String, i64>) -> Value {
    json!({"formato":"baiacu-permissoes","versao":1,"niveis":levels})
}
pub fn executar(method: &str, args: &Value) -> Res<Value> {
    match method {
        "permissoes.carregar" => {
            let sessao = sessao()?;
            usuario_atual(&sessao_ativa(&sessao)?.operador)?;
            Ok(json!({"catalogo":catalogo(),"perfil":documento(niveis()?)}))
        }
        "permissoes.pode" => Ok(json!(permitido(args["chave"].as_str().unwrap_or(""))?)),
        "permissoes.autorizador" => Ok(json!(autorizador(
            args["chave"].as_str().unwrap_or(""),
            None
        )?)),
        "permissoes.limpar_autorizacoes" => {
            limpar_autorizacoes();
            Ok(Value::Null)
        }
        "permissoes.validar" | "permissoes.salvar" => {
            let mut sessao = sessao()?;
            let sessao = sessao
                .as_mut()
                .ok_or_else(|| Erro::valor("Entre no programa para continuar."))?;
            if usuario_atual(&sessao.operador)?.nivel != 4 {
                return Err(Erro::valor(
                    "Somente o usuário nível 4 logado pode gerir permissões.",
                ));
            }
            let levels = validar(&args["perfil"])?;
            let doc = documento(levels);
            if method == "permissoes.salvar" {
                banco::set_meta(META, &serde_json::to_string(&doc)?)?;
                sessao.autorizacoes.clear();
                crate::registro::info(
                    "permissoes",
                    "Perfil de permissões por nível alterado pelo master.",
                );
            }
            Ok(doc)
        }
        _ => Err(Erro::valor("Operação de permissões desconhecida.")),
    }
}
pub fn checar_metodo(method: &str, args: &Value) -> Res<()> {
    let origem = args["origem"].as_str().unwrap_or("");
    let regra = match (method, origem) {
        ("usuarios.criar", _) if args.get("criado_por").is_none_or(Value::is_null) => return Ok(()),
        ("banco.set_meta", _) => match args["chave"].as_str() {
            Some("ui.pdf_nativo") => "config.pdf",
            Some("ui.animacao_login") => "config.personalizacao",
            Some("ui.minimizar_ao_fechar") => "config.geral",
            _ => {
                return Err(Erro::valor(
                    "Esta preferência não pode ser alterada diretamente.",
                ));
            }
        },
        ("cadastro.save_tomador_form", _) => {
            let prest = crate::despacho::texto(args, "prestador")?;
            let doc = crate::despacho::texto(&args["form"], "documento")?;
            if crate::cadastro::tomador_cadastrado(prest, doc)? {
                "clientes.editar"
            } else {
                "clientes.adicionar"
            }
        }
        ("cofre.xml_por_chave", "substituir") => "consultar.substituir",
        ("cofre.gerar_danfse", "consultar") => "consultar.pdf",
        ("correio.enviar_nfse", "emitir") => "emitir.email",
        ("consulta.cnpj", "prestadores") => "prestadores.consulta",
        ("cadastro.save_servico", "emitir") => "emitir.tributos",
        _ => {
            let Some(regra) = catalogo()
                .iter()
                .find(|r| r.metodos.iter().any(|m| m == method))
            else {
                return Ok(());
            };
            &regra.id
        }
    };
    exigir(regra)?;
    if (method == "cofre.gerar_danfse" && origem == "consultar") || method == "cofre.xml_por_chave"
    {
        let dono = crate::despacho::texto(args, "dono")?;
        let chave = crate::despacho::texto(args, "chave")?;
        if crate::cofre::nota_por_chave(dono, chave)?.is_some_and(|nota| nota.papel != "E") {
            return Err(Erro::valor(
                "Esta ação é exclusiva para notas emitidas pelo prestador.",
            ));
        }
    }
    Ok(())
}

pub fn validar_actor(chave: &str, actor: usuarios::Usuario) -> Res<usuarios::Usuario> {
    autorizador(chave, Some(actor.id))?
        .ok_or_else(|| Erro::valor("O usuário informado não autenticou esta operação."))
}

pub fn usuario_alvo(alvo: usuarios::Usuario) -> Res<usuarios::Usuario> {
    let operador = {
        let sessao = sessao()?;
        usuario_atual(&sessao_ativa(&sessao)?.operador)?
    };
    if alvo.id != operador.id {
        exigir("usuarios.prestadores")?;
    }
    usuarios::por_id(alvo.id)
}
