//! Certificado A1 (.pfx): abrir com a senha e separar a chave privada, o certificado dela e os
//! demais da cadeia. O .pfx e a senha vêm sempre do banco cifrado (`segredos`) — não existe
//! arquivo de certificado em disco.
use p12_keystore::Pkcs12Archive;
use rsa::RsaPrivateKey;
use rsa::pkcs1::EncodeRsaPrivateKey;
use rsa::pkcs8::DecodePrivateKey;
use sha2::{Digest, Sha256};
use x509_parser::prelude::*;

use crate::erro::{Erro, Res};

/// O que sai de um .pfx aberto.
#[derive(Clone)]
pub struct Material {
    pub chave: RsaPrivateKey,
    /// Certificado da chave (DER).
    pub cert_der: Vec<u8>,
    /// Os outros certificados do arquivo (cadeia), na ordem em que estão nele.
    pub adicionais_der: Vec<Vec<u8>>,
}

impl Material {
    /// Impressão digital SHA-256 do certificado, em hexadecimal.
    pub fn sha256(&self) -> String {
        hex::encode(Sha256::digest(&self.cert_der))
    }

    /// Chave privada em PEM (para o TLS). Fica só na memória e é apagada ao sair de uso.
    pub fn chave_pkcs1_pem(&self) -> Res<rsa::pkcs8::der::zeroize::Zeroizing<String>> {
        self.chave
            .to_pkcs1_pem(rsa::pkcs1::LineEnding::LF)
            .map_err(|e| Erro::valor(format!("chave privada: {e}")))
    }
}

fn chave_publica_do(cert_der: &[u8]) -> Option<Vec<u8>> {
    let (_, cert) = X509Certificate::from_der(cert_der).ok()?;
    Some(cert.public_key().subject_public_key.data.to_vec())
}

/// Abre o .pfx. Erro "Senha incorreta ou arquivo .pfx inválido." se não abrir.
pub fn carregar_pfx(pfx: &[u8], senha: &str) -> Res<Material> {
    let arquivo = Pkcs12Archive::from_pkcs12(pfx, senha)
        .map_err(|_| Erro::valor("Senha incorreta ou arquivo .pfx inválido."))?;
    let Some(bolsa) = arquivo.keys.first() else {
        return Err(Erro::valor(
            "O .pfx não contém chave privada + certificado válidos.",
        ));
    };
    let chave = RsaPrivateKey::from_pkcs8_der(bolsa.key.as_der())
        .map_err(|_| Erro::valor("O .pfx não contém uma chave privada RSA válida."))?;
    // O certificado DA chave: o que tem a mesma chave pública.
    let publica = {
        use rsa::pkcs1::EncodeRsaPublicKey;
        rsa::RsaPublicKey::from(&chave)
            .to_pkcs1_der()
            .map_err(|e| Erro::valor(format!("chave pública: {e}")))?
            .as_bytes()
            .to_vec()
    };
    let certs: Vec<Vec<u8>> = arquivo
        .certs
        .iter()
        .map(|c| c.cert.as_der().to_vec())
        .collect();
    let pos = certs
        .iter()
        .position(|c| chave_publica_do(c).is_some_and(|p| p == publica))
        .ok_or_else(|| {
            Erro::valor("PFX carregado, mas não encontrei chave privada + certificado.")
        })?;
    let mut adicionais = certs.clone();
    let cert_der = adicionais.remove(pos);
    Ok(Material {
        chave,
        cert_der,
        adicionais_der: adicionais,
    })
}

// ------------------------------------------------------------------------------- //
// O que se lê de um certificado
// ------------------------------------------------------------------------------- //
/// Nome curto de cada atributo do titular (os demais saem pelo número do OID).
fn nome_do_atributo(oid: &str) -> Option<&'static str> {
    Some(match oid {
        "2.5.4.3" => "CN",
        "2.5.4.7" => "L",
        "2.5.4.8" => "ST",
        "2.5.4.10" => "O",
        "2.5.4.11" => "OU",
        "2.5.4.6" => "C",
        "2.5.4.9" => "STREET",
        "0.9.2342.19200300.100.1.25" => "DC",
        "0.9.2342.19200300.100.1.1" => "UID",
        _ => return None,
    })
}

fn escapar_dn(valor: &str) -> String {
    if valor.is_empty() {
        return String::new();
    }
    let mut r = String::with_capacity(valor.len() + 4);
    for c in valor.chars() {
        match c {
            '\\' | '"' | '+' | ',' | ';' | '<' | '>' => {
                r.push('\\');
                r.push(c);
            }
            '\0' => r.push_str("\\00"),
            c => r.push(c),
        }
    }
    if r.starts_with('#') || r.starts_with(' ') {
        r.insert(0, '\\');
    }
    if r.ends_with(' ') {
        r.insert(r.len() - 1, '\\');
    }
    r
}

/// Dados de um certificado para mostrar e conferir.
#[derive(Debug, Clone, Default)]
pub struct Titular {
    /// O titular por extenso, no formato RFC 4514 ("CN=…,OU=…,O=…,C=BR").
    pub sujeito: String,
    /// O nome comum (CN), se houver.
    pub nome_comum: Option<String>,
    /// Validade: início e fim, em segundos desde 1970 (UTC).
    pub de: i64,
    pub ate: i64,
}

pub fn titular(cert_der: &[u8]) -> Res<Titular> {
    let (_, cert) =
        X509Certificate::from_der(cert_der).map_err(|_| Erro::valor("Certificado inválido."))?;
    let mut partes: Vec<String> = Vec::new();
    let mut nome_comum = None;
    for rdn in cert.subject().iter_rdn() {
        let mut atributos: Vec<String> = Vec::new();
        for a in rdn.iter() {
            let oid = a.attr_type().to_id_string();
            let valor = a
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|_| String::from_utf8_lossy(a.attr_value().data).into_owned());
            if oid == "2.5.4.3" && nome_comum.is_none() {
                nome_comum = Some(valor.clone());
            }
            let nome = nome_do_atributo(&oid).map(str::to_string).unwrap_or(oid);
            atributos.push(format!("{nome}={}", escapar_dn(&valor)));
        }
        partes.push(atributos.join("+"));
    }
    partes.reverse();
    Ok(Titular {
        sujeito: partes.join(","),
        nome_comum,
        de: cert.validity().not_before.timestamp(),
        ate: cert.validity().not_after.timestamp(),
    })
}
