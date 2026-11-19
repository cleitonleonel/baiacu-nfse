//! Chaves do banco cifrado: SENHA MESTRA, senha de cada usuário e o arquivo database/dados.key.
//!
//! O banco (database/dados.db) é cifrado por inteiro com UMA chave bruta de 32 bytes. Há dois jeitos
//! de chegar nela, e nenhum depende da máquina:
//!
//! - SENHA MESTRA (aleatória, 20 caracteres, mostrada uma vez para anotar em papel): a chave é
//!   scrypt(senha mestra, sal), e o sal são os 16 primeiros bytes do próprio dados.db. Por isso
//!   o dados.db SOZINHO + a senha mestra sempre abrem o banco, em qualquer computador.
//! - SENHA DE USUÁRIO: cada usuário ativo tem a chave do banco embrulhada (AES-256-GCM) com uma
//!   chave derivada da senha dele (scrypt). Esses embrulhos precisam ser lidos ANTES de o banco
//!   abrir, então ficam fora dele, em database/dados.key.
//!
//! O dados.key NÃO é a origem de nada: é uma cópia. A origem é a tabela chave_usuario, dentro
//! do banco. `sincronizar()` compara os dois e REFAZ o arquivo a partir do banco sempre que
//! estiver ausente, corrompido ou diferente.
//!
//! A tabela guarda também a chave derivada de cada usuário (kek): com o banco já aberto ela não
//! revela nada que quem abriu já não tenha, e permite reembrulhar todo mundo quando a chave do
//! banco muda (troca da senha mestra) sem pedir a senha de ninguém.
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{Aead, KeyInit, Payload};
use hmac::{Hmac, Mac};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::banco;
use crate::erro::{Erro, Res};
use crate::jsonpy::{self, Formato};
use crate::registro;

const AAD: &[u8] = b"nfse-chave-usuario-v1";
// scrypt: cada tentativa de senha custa ~0,2 s e 64 MB (usuário) — encarece a força bruta de
// quem levar os dois arquivos. A senha mestra tem ~99 bits; o custo menor basta.
const LOG_N_USUARIO: u8 = 16;
const LOG_N_MESTRA: u8 = 15;
// Sem 0/O/1/I/L (ambíguos à mão). 20 caracteres ≈ 99 bits de entropia.
const ALFABETO: &str = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

static TRAVA: Mutex<()> = Mutex::new(());

pub fn arquivo() -> PathBuf {
    banco::caminho_db().with_file_name("dados.key")
}

pub fn aleatorio(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    getrandom::fill(&mut buf).expect("gerador de números aleatórios do sistema");
    buf
}

fn scrypt(senha: &[u8], sal: &[u8], log_n: u8) -> Res<Vec<u8>> {
    let params = scrypt::Params::new(log_n, 8, 1)
        .map_err(|e| Erro::valor(format!("parâmetros do scrypt: {e}")))?;
    let mut saida = vec![0u8; 32];
    scrypt::scrypt(senha, sal, &params, &mut saida)
        .map_err(|e| Erro::valor(format!("scrypt: {e}")))?;
    Ok(saida)
}

fn log_n_de(n: i64) -> Res<u8> {
    if n >= 2 && (n & (n - 1)) == 0 {
        Ok(n.trailing_zeros() as u8)
    } else {
        Err(Erro::valor("custo do scrypt inválido"))
    }
}

// ------------------------------------------------------------------------------- //
// Senha mestra
// ------------------------------------------------------------------------------- //
pub fn nova_senha_mestra() -> String {
    let letras: Vec<char> = ALFABETO.chars().collect();
    let mut grupos: Vec<String> = Vec::new();
    for _ in 0..4 {
        let mut g = String::new();
        while g.len() < 5 {
            // Sorteio sem viés: descarta o que passa do último múltiplo do tamanho do alfabeto.
            let b = aleatorio(1)[0] as usize;
            if b < 256 - (256 % letras.len()) {
                g.push(letras[b % letras.len()]);
            }
        }
        grupos.push(g);
    }
    grupos.join("-")
}

/// Traços, espaços e minúsculas não importam ao digitar a senha anotada.
fn normalizar_mestra(senha: &str) -> String {
    senha
        .to_uppercase()
        .chars()
        .filter(|c| ALFABETO.contains(*c))
        .collect()
}

pub fn chave_da_mestra(senha: &str, sal: &[u8]) -> Res<Vec<u8>> {
    scrypt(normalizar_mestra(senha).as_bytes(), sal, LOG_N_MESTRA)
}

/// Instalação nova: cria o banco cifrado e devolve a SENHA MESTRA (exibir UMA vez).
pub fn criar_banco() -> Res<String> {
    let senha = nova_senha_mestra();
    let sal = aleatorio(16);
    banco::criar(&chave_da_mestra(&senha, &sal)?, &sal)?;
    sincronizar()?;
    Ok(senha)
}

/// Só para o primeiro acesso: o banco acabou de nascer, vazio, e o cadastro do master falhou.
/// Sem usuário e com a senha mestra ainda não exibida, ninguém o abriria.
pub fn desfazer_criacao() {
    banco::trancar();
    let _ = fs::remove_file(banco::caminho_db());
    let _ = fs::remove_file(arquivo());
}

pub fn verificar_senha_mestra(senha: &str) -> bool {
    if banco::estado() != "cifrado" || normalizar_mestra(senha).is_empty() {
        return false;
    }
    let sal = banco::sal_do_arquivo(None);
    match chave_da_mestra(senha, &sal) {
        Ok(chave) => banco::chave_abre(&banco::caminho_db(), &chave, Some(&sal)),
        Err(_) => false,
    }
}

/// Abre o banco só com a senha mestra e refaz o dados.key se ele faltar ou divergir.
pub fn destrancar_com_mestra(senha: &str) -> Res<bool> {
    if banco::estado() != "cifrado" || normalizar_mestra(senha).is_empty() {
        return Ok(false);
    }
    let chave = chave_da_mestra(senha, &banco::sal_do_arquivo(None))?;
    if !banco::destrancar(&chave) {
        return Ok(false);
    }
    conferir("entrada com a senha mestra")?;
    Ok(true)
}

// ------------------------------------------------------------------------------- //
// dados.key (cópia) <-> tabela chave_usuario (origem)
// ------------------------------------------------------------------------------- //
/// Identificador do usuário no dados.key sem expor o login em texto.
fn slot(id_sal: &[u8], login: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(id_sal).expect("HMAC aceita qualquer chave");
    mac.update(login.as_bytes());
    hex::encode(mac.finalize().into_bytes())
}

fn id_sal(con: &Connection) -> Res<Vec<u8>> {
    let atual: Option<String> = con
        .query_row(
            "SELECT valor FROM meta WHERE chave = 'chaves.id_sal'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(h) = atual {
        return hex::decode(h).map_err(|_| Erro::valor("chaves.id_sal inválido no banco"));
    }
    let novo = aleatorio(16);
    con.execute(
        "INSERT INTO meta (chave, valor) VALUES ('chaves.id_sal', ?1)",
        [hex::encode(&novo)],
    )?;
    Ok(novo)
}

fn empacotar(dados: &Value) -> Vec<u8> {
    let canonico = jsonpy::dumps(dados, Formato::CANONICO);
    let soma = hex::encode(Sha256::digest(canonico.as_bytes()));
    let doc = json!({ "dados": dados, "sha256": soma });
    jsonpy::dumps(
        &doc,
        Formato {
            ordenar: true,
            recuo: Some(1),
            compacto: false,
            so_ascii: true,
        },
    )
    .into_bytes()
}

/// O dados.key exatamente como deve estar, byte a byte, segundo o banco.
fn conteudo_esperado(con: &Connection) -> Res<Vec<u8>> {
    let tem_usuarios: Option<i64> = con
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='usuarios'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    let mut usuarios: Vec<Value> = Vec::new();
    if tem_usuarios.is_some() {
        let mut st = con.prepare(
            "SELECT c.slot, c.sal, c.n, c.embrulho FROM chave_usuario c \
             JOIN usuarios u ON u.id = c.usuario_id WHERE u.ativo = 1 ORDER BY c.slot",
        )?;
        let linhas = st.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, Vec<u8>>(3)?,
            ))
        })?;
        for l in linhas {
            let (slot, sal, n, embrulho) = l?;
            usuarios.push(json!({
                "slot": slot, "sal": hex::encode(sal), "n": n, "embrulho": hex::encode(embrulho),
            }));
        }
    }
    Ok(empacotar(
        &json!({ "v": 1, "id_sal": hex::encode(id_sal(con)?), "usuarios": usuarios }),
    ))
}

pub(crate) fn preparar_arquivo_acesso(con: &Connection, destino: &Path) -> Res<()> {
    use std::io::Write;
    let conteudo = conteudo_esperado(con)?;
    let mut arquivo = fs::File::create(destino)?;
    arquivo.write_all(&conteudo)?;
    arquivo.sync_all()?;
    Ok(())
}

/// Conteúdo do dados.key, ou None se ausente/corrompido (soma de verificação não bate).
fn ler_arquivo() -> Option<Value> {
    let bytes = fs::read(arquivo()).ok()?;
    let doc: Value = serde_json::from_slice(&bytes).ok()?;
    let dados = doc.get("dados")?;
    let canonico = jsonpy::dumps(dados, Formato::CANONICO);
    if hex::encode(Sha256::digest(canonico.as_bytes())) != doc.get("sha256")?.as_str()? {
        return None;
    }
    hex::decode(dados.get("id_sal")?.as_str()?).ok()?;
    dados.get("usuarios")?.as_array()?;
    Some(dados.clone())
}

pub fn arquivo_integro() -> bool {
    ler_arquivo().is_some()
}

/// Deixa o dados.key IDÊNTICO ao que o banco diz. true = já estava; false = foi refeito.
/// Exige o banco destrancado.
pub fn sincronizar() -> Res<bool> {
    let _g = TRAVA.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    sincronizar_travado()
}

fn sincronizar_travado() -> Res<bool> {
    let esperado = {
        let con = banco::conn()?;
        conteudo_esperado(&con)?
    };
    let arq = arquivo();
    if fs::read(&arq).is_ok_and(|atual| atual == esperado) {
        return Ok(true);
    }
    let tmp = PathBuf::from(format!("{}.tmp", arq.display()));
    fs::write(&tmp, &esperado)?;
    fs::rename(&tmp, &arq)?;
    if fs::read(&arq)? != esperado {
        return Err(Erro::os(
            "Não foi possível gravar dados.key igual ao banco.",
        ));
    }
    Ok(false)
}

/// Validação de rotina (login, fechamento): se o arquivo local não bate com o banco, refaz e
/// registra — alguém apagou, editou ou trouxe um dados.key de outro lugar.
pub fn conferir(motivo: &str) -> Res<()> {
    if !sincronizar()? {
        registro::aviso(
            "chaves",
            &format!(
                "dados.key ausente ou diferente da cópia do banco ({motivo}): refeito a partir do banco."
            ),
        );
    }
    Ok(())
}

// ------------------------------------------------------------------------------- //
// Senha de usuário
// ------------------------------------------------------------------------------- //
fn embrulhar(kek: &[u8], chave: &[u8]) -> Res<Vec<u8>> {
    let nonce = aleatorio(12);
    let cifra =
        Aes256Gcm::new_from_slice(kek).map_err(|_| Erro::valor("chave derivada inválida"))?;
    let cifrado = cifra
        .encrypt(
            nonce
                .as_slice()
                .try_into()
                .map_err(|_| Erro::valor("nonce"))?,
            Payload {
                msg: chave,
                aad: AAD,
            },
        )
        .map_err(|_| Erro::valor("falha ao embrulhar a chave"))?;
    Ok([nonce, cifrado].concat())
}

fn desembrulhar(kek: &[u8], embrulho: &[u8]) -> Option<Vec<u8>> {
    if embrulho.len() < 12 + 16 {
        return None;
    }
    let cifra = Aes256Gcm::new_from_slice(kek).ok()?;
    cifra
        .decrypt(
            embrulho[..12].try_into().ok()?,
            Payload {
                msg: &embrulho[12..],
                aad: AAD,
            },
        )
        .ok()
}

/// Abre o banco com login (já normalizado) + senha, pelo dados.key. false = login sem chave no
/// arquivo, senha errada ou dados.key de outro banco.
pub fn destrancar_com_usuario(login: &str, senha: &str) -> Res<bool> {
    let Some(dados) = ler_arquivo() else {
        return Ok(false);
    };
    if senha.is_empty() {
        return Ok(false);
    }
    let chave = (|| -> Option<Vec<u8>> {
        let s = slot(&hex::decode(dados.get("id_sal")?.as_str()?).ok()?, login);
        let entrada = dados
            .get("usuarios")?
            .as_array()?
            .iter()
            .find(|u| u.get("slot").and_then(Value::as_str) == Some(s.as_str()))?;
        let sal = hex::decode(entrada.get("sal")?.as_str()?).ok()?;
        let log_n = log_n_de(entrada.get("n")?.as_i64()?).ok()?;
        let kek = scrypt(senha.as_bytes(), &sal, log_n).ok()?;
        desembrulhar(&kek, &hex::decode(entrada.get("embrulho")?.as_str()?).ok()?)
    })();
    let Some(chave) = chave else { return Ok(false) };
    if !banco::destrancar(&chave) {
        return Ok(false);
    }
    conferir("login")?;
    Ok(true)
}

fn exigir_chave() -> Res<Vec<u8>> {
    match banco::chave_atual() {
        Some((chave, _)) => Ok(chave),
        None => Err(Erro::trancado(
            "O banco precisa estar aberto para alterar chaves.",
        )),
    }
}

/// Cria/troca a chave do usuário a partir da senha nova e regrava o dados.key.
pub fn definir_senha(usuario_id: i64, login: &str, senha: &str) -> Res<()> {
    let chave = exigir_chave()?;
    let sal = aleatorio(16);
    let kek = scrypt(senha.as_bytes(), &sal, LOG_N_USUARIO)?;
    let _g = TRAVA.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    {
        let con = banco::conn()?;
        let s = slot(&id_sal(&con)?, login);
        con.execute(
            "INSERT OR REPLACE INTO chave_usuario (usuario_id, slot, sal, n, kek, embrulho) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                usuario_id,
                s,
                sal,
                1i64 << LOG_N_USUARIO,
                kek,
                embrulhar(&kek, &chave)?
            ],
        )?;
    }
    sincronizar_travado()?;
    Ok(())
}

pub fn remover(usuario_id: i64) -> Res<()> {
    exigir_chave()?;
    let _g = TRAVA.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    {
        let con = banco::conn()?;
        con.execute(
            "DELETE FROM chave_usuario WHERE usuario_id = ?1",
            [usuario_id],
        )?;
    }
    sincronizar_travado()?;
    Ok(())
}

// ------------------------------------------------------------------------------- //
// Trocar a chave do banco (nova senha mestra)
// ------------------------------------------------------------------------------- //
/// Copia TODO o banco da conexão `con` para um arquivo novo, cifrado com (chave, sal).
pub fn exportar(con: &Connection, destino: &Path, chave: &[u8], sal: &[u8]) -> Res<()> {
    let _ = fs::remove_file(destino);
    con.execute(
        "ATTACH DATABASE ?1 AS novo KEY ?2",
        params![
            destino.to_string_lossy(),
            format!("x'{}{}'", hex::encode(chave), hex::encode(sal))
        ],
    )?;
    con.execute_batch("BEGIN IMMEDIATE")?; // ninguém grava na origem durante a cópia
    let copia = con.query_row("SELECT sqlcipher_export('novo')", [], |_| Ok(()));
    let fim = con.execute_batch("COMMIT");
    let solta = con.execute_batch("DETACH DATABASE novo");
    copia?;
    fim?;
    solta?;
    Ok(())
}

/// Regrava o embrulho de TODOS os usuários de `con` para a chave de banco `chave`, usando a
/// chave derivada (kek) guardada de cada um — sem precisar da senha de ninguém.
pub fn reembrulhar(con: &mut Connection, chave: &[u8]) -> Res<()> {
    let tx = con.transaction()?;
    let linhas: Vec<(i64, Vec<u8>)> = {
        let mut st = tx.prepare("SELECT usuario_id, kek FROM chave_usuario")?;
        let it = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        it.collect::<Result<_, _>>()?
    };
    for (uid, kek) in linhas {
        tx.execute(
            "UPDATE chave_usuario SET embrulho = ?1 WHERE usuario_id = ?2",
            params![embrulhar(&kek, chave)?, uid],
        )?;
    }
    tx.commit()?;
    Ok(())
}

/// Identificador do login no dados.key do banco `con` (cada banco tem o seu sal).
pub fn slot_de(con: &Connection, login: &str) -> Res<String> {
    Ok(slot(&id_sal(con)?, login))
}

/// {tabela: linhas ordenadas} do banco inteiro, para comparar original e cópia.
fn tabelas(con: &Connection) -> Res<Vec<(String, Vec<String>)>> {
    let nomes: Vec<String> = {
        let mut st =
            con.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")?;
        let it = st.query_map([], |r| r.get(0))?;
        it.collect::<Result<_, _>>()?
    };
    let mut out = Vec::new();
    for nome in nomes {
        let mut st = con.prepare(&format!("SELECT * FROM \"{nome}\""))?;
        let colunas = st.column_count();
        let mut linhas: Vec<String> = Vec::new();
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let mut partes: Vec<String> = Vec::with_capacity(colunas);
            for i in 0..colunas {
                partes.push(match r.get_ref(i)? {
                    rusqlite::types::ValueRef::Null => "N".into(),
                    rusqlite::types::ValueRef::Integer(v) => format!("I{v}"),
                    rusqlite::types::ValueRef::Real(v) => format!("R{v:?}"),
                    rusqlite::types::ValueRef::Text(t) => format!("T{}", hex::encode(t)),
                    rusqlite::types::ValueRef::Blob(b) => format!("B{}", hex::encode(b)),
                });
            }
            linhas.push(partes.join("|"));
        }
        linhas.sort();
        out.push((nome, linhas));
    }
    Ok(out)
}

/// A cópia cifrada tem de ter exatamente as mesmas tabelas e linhas do banco atual.
fn conferir_copia(destino: &Path, chave: &[u8], sal: &[u8]) -> Res<()> {
    let atual = banco::conn()?;
    let novo = banco::abrir(destino, chave, sal)?;
    if tabelas(&atual)? != tabelas(&novo)? {
        return Err(Erro::os(
            "A cópia cifrada do banco não conferiu com o original; nada foi alterado.",
        ));
    }
    Ok(())
}

/// Passa a chave do banco para a derivada de `nova` (gerada por `nova_senha_mestra()` e JÁ
/// anotada pelo usuário — só então chame isto) e reembrulha todos os usuários.
///
/// O banco é regravado num arquivo novo e trocado de uma vez: se algo falhar antes da troca,
/// tudo continua como estava, com a senha mestra antiga.
pub fn trocar_senha_mestra(nova: &str) -> Res<()> {
    exigir_chave()?;
    if normalizar_mestra(nova).len() < 20 {
        return Err(Erro::valor("Senha mestra inválida."));
    }
    let sal = aleatorio(16);
    let chave = chave_da_mestra(nova, &sal)?;
    let destino = PathBuf::from(format!("{}.novo", banco::caminho_db().display()));
    let _g = TRAVA.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let troca = (|| -> Res<()> {
        {
            let con = banco::conn()?;
            exportar(&con, &destino, &chave, &sal)?;
        }
        conferir_copia(&destino, &chave, &sal)?;
        {
            let mut con = banco::abrir(&destino, &chave, &sal)?;
            reembrulhar(&mut con, &chave)?;
        }
        banco::substituir_banco(&destino)
    })();
    let _ = fs::remove_file(&destino);
    troca?;
    if !banco::destrancar(&chave) {
        return Err(Erro::os("O banco regravado não abriu com a nova chave."));
    }
    sincronizar_travado()?;
    registro::aviso(
        "chaves",
        "Senha mestra TROCADA: o banco foi regravado com a nova chave.",
    );
    Ok(())
}
