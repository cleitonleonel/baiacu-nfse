//! Segredos guardados pelo programa, por prestador: o certificado A1 (.pfx), a senha dele e a
//! senha do SMTP.
//!
//! Moram na tabela `segredo` do banco (database/dados.db), que é cifrado POR INTEIRO: só ficam
//! legíveis depois que um usuário ou a senha mestra abrem o banco. O .pfx é guardado inteiro
//! (em base64) — não existe arquivo de certificado em disco.
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use rusqlite::{OptionalExtension, params};

use crate::banco;
use crate::erro::{Erro, Res};

fn ler(tipo: &str, chave: &str) -> Res<String> {
    let con = banco::conn()?;
    let v: Option<String> = con
        .query_row(
            "SELECT valor FROM segredo WHERE tipo = ?1 AND chave = ?2",
            params![tipo, chave],
            |r| r.get(0),
        )
        .optional()?;
    Ok(v.unwrap_or_default())
}

fn gravar(tipo: &str, chave: &str, valor: Option<&str>) -> Res<()> {
    let con = banco::conn()?;
    match valor {
        None => con.execute(
            "DELETE FROM segredo WHERE tipo = ?1 AND chave = ?2",
            params![tipo, chave],
        )?,
        Some(v) => con.execute(
            "INSERT OR REPLACE INTO segredo (tipo, chave, valor) VALUES (?1, ?2, ?3)",
            params![tipo, chave, v],
        )?,
    };
    Ok(())
}

/// As chaves de um tipo que começam por `prefixo`, em ordem.
fn chaves(tipo: &str, prefixo: &str) -> Res<Vec<String>> {
    let con = banco::conn()?;
    let mut st = con.prepare(
        "SELECT chave FROM segredo WHERE tipo = ?1 AND substr(chave, 1, ?2) = ?3 ORDER BY chave",
    )?;
    let linhas = st.query_map(
        params![tipo, prefixo.chars().count() as i64, prefixo],
        |r| r.get::<_, String>(0),
    )?;
    Ok(linhas.collect::<Result<Vec<_>, _>>()?)
}

/// Nomes dos certificados guardados que começam por `prefixo`.
pub fn certs_com_prefixo(prefixo: &str) -> Res<Vec<String>> {
    chaves("pfx", prefixo)
}

pub fn get_cert_password(cert: &str) -> Res<String> {
    ler("cert", cert)
}

pub fn set_cert_password(cert: &str, senha: &str) -> Res<()> {
    gravar("cert", cert, Some(senha))
}

pub fn remove_cert_password(cert: &str) -> Res<()> {
    gravar("cert", cert, None)
}

/// O arquivo .pfx do certificado, byte a byte (vazio se não há).
pub fn get_cert_pfx(cert: &str) -> Res<Vec<u8>> {
    let valor = ler("pfx", cert)?;
    if valor.is_empty() {
        return Ok(Vec::new());
    }
    STANDARD
        .decode(valor.trim())
        .map_err(|_| Erro::valor("Certificado guardado está corrompido."))
}

pub fn tem_cert_pfx(cert: &str) -> Res<bool> {
    Ok(!ler("pfx", cert)?.is_empty())
}

pub fn set_cert_pfx(cert: &str, pfx: &[u8]) -> Res<()> {
    gravar("pfx", cert, Some(&STANDARD.encode(pfx)))
}

pub fn remove_cert_pfx(cert: &str) -> Res<()> {
    gravar("pfx", cert, None)
}

pub fn get_smtp_password(prestador: &str) -> Res<String> {
    ler("smtp", prestador)
}

pub fn set_smtp_password(prestador: &str, senha: &str) -> Res<()> {
    gravar("smtp", prestador, Some(senha))
}

pub fn remove_smtp_password(prestador: &str) -> Res<()> {
    gravar("smtp", prestador, None)
}
