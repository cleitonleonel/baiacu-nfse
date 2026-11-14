//! Assinatura digital XML (XML-DSig) da DPS e do pedido de evento.
//!
//! Assinatura "envelopada" do elemento que tem o atributo Id (infDPS / infPedReg):
//! canonicalização C14N 1.0, resumo SHA-256, RSA-SHA256, certificado em <KeyInfo>. O elemento
//! <Signature> sai com as MESMAS quebras de linha que a biblioteca usada antes (xmlsec)
//! produzia — elas fazem parte do que é assinado, e a SEFIN recebe o mesmo documento de sempre.
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use rsa::pkcs1v15::SigningKey;
use rsa::sha2::Sha256 as Sha256Rsa;
use rsa::signature::{SignatureEncoding, Signer};
use sha2::{Digest, Sha256};

use crate::certificado::Material;
use crate::erro::{Erro, Res};
use crate::xml::{self, Elemento, No};

pub const NS_DS: &str = "http://www.w3.org/2000/09/xmldsig#";
const ALG_C14N: &str = "http://www.w3.org/TR/2001/REC-xml-c14n-20010315";
const ALG_ENVELOPADA: &str = "http://www.w3.org/2000/09/xmldsig#enveloped-signature";
const ALG_RSA_SHA256: &str = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256";
const ALG_SHA256: &str = "http://www.w3.org/2001/04/xmlenc#sha256";

/// base64 em linhas de 64 caracteres.
fn b64_em_linhas(dados: &[u8]) -> String {
    let b = STANDARD.encode(dados);
    b.as_bytes()
        .chunks(64)
        .map(|l| std::str::from_utf8(l).unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n")
}

fn elem(pai: &mut Elemento, nome: &str) -> usize {
    pai.filhos.push(No::Elemento(Elemento::novo(nome, NS_DS)));
    pai.filhos.len() - 1
}

fn no_mut(pai: &mut Elemento, i: usize) -> &mut Elemento {
    match &mut pai.filhos[i] {
        No::Elemento(e) => e,
        No::Texto(_) => unreachable!(),
    }
}

fn algoritmo(pai: &mut Elemento, nome: &str, alg: &str) {
    let i = elem(pai, nome);
    no_mut(pai, i)
        .atributos
        .push(("Algorithm".into(), alg.into()));
    pai.texto("\n");
}

/// Assina `xml`: a raiz tem de ser `raiz_local` (no namespace da NFS-e) e o elemento assinado é
/// o filho `inf_local`, que tem o atributo Id. Devolve (XML assinado, Id assinado).
pub fn assinar(
    xml_bytes: &[u8],
    raiz_local: &str,
    inf_local: &str,
    ns_nfse: &str,
    m: &Material,
) -> Res<(Vec<u8>, String)> {
    let mut raiz = xml::ler(xml_bytes)?;
    if raiz.nome != raiz_local || raiz.ns != ns_nfse {
        return Err(Erro::valor(format!(
            "Raiz inválida: '{{{}}}{}' (esperado {raiz_local}).",
            raiz.ns, raiz.nome
        )));
    }
    // assinatura anterior, se houver, sai
    raiz.filhos
        .retain(|n| !matches!(n, No::Elemento(e) if e.nome == "Signature" && e.ns == NS_DS));

    let Some(inf) = raiz
        .elementos()
        .find(|e| e.nome == inf_local && e.ns == ns_nfse)
    else {
        return Err(Erro::valor(format!("{inf_local} não encontrado.")));
    };
    let id = match inf.attr("Id") {
        Some(id) if !id.is_empty() => id.to_string(),
        _ => return Err(Erro::valor(format!("{inf_local} sem atributo Id."))),
    };
    let resumo = STANDARD.encode(Sha256::digest(xml::canonico(inf)));

    // <SignedInfo>, com as quebras de linha do molde de sempre
    let mut info = Elemento::novo("SignedInfo", NS_DS);
    info.texto("\n");
    algoritmo(&mut info, "CanonicalizationMethod", ALG_C14N);
    algoritmo(&mut info, "SignatureMethod", ALG_RSA_SHA256);
    {
        let i = elem(&mut info, "Reference");
        let referencia = no_mut(&mut info, i);
        referencia.atributos.push(("URI".into(), format!("#{id}")));
        referencia.texto("\n");
        {
            let j = elem(referencia, "Transforms");
            let transformacoes = no_mut(referencia, j);
            transformacoes.texto("\n");
            algoritmo(transformacoes, "Transform", ALG_ENVELOPADA);
            algoritmo(transformacoes, "Transform", ALG_C14N);
        }
        referencia.texto("\n");
        algoritmo(referencia, "DigestMethod", ALG_SHA256);
        let j = elem(referencia, "DigestValue");
        no_mut(referencia, j).texto(&resumo);
        referencia.texto("\n");
    }
    info.texto("\n");

    let chave = SigningKey::<Sha256Rsa>::new(m.chave.clone());
    let assinatura = chave.sign(&xml::canonico(&info)).to_bytes();

    let mut sig = Elemento::novo("Signature", NS_DS);
    sig.texto("\n");
    sig.filhos.push(No::Elemento(info));
    sig.texto("\n");
    let i = elem(&mut sig, "SignatureValue");
    no_mut(&mut sig, i).texto(&b64_em_linhas(&assinatura));
    sig.texto("\n");
    {
        let i = elem(&mut sig, "KeyInfo");
        let chave_info = no_mut(&mut sig, i);
        chave_info.texto("\n");
        let j = elem(chave_info, "X509Data");
        let dados = no_mut(chave_info, j);
        dados.texto("\n");
        let k = elem(dados, "X509Certificate");
        no_mut(dados, k).texto(&format!("{}\n", b64_em_linhas(&m.cert_der)));
        dados.texto("\n");
        chave_info.texto("\n");
    }
    sig.texto("\n");
    raiz.filhos.push(No::Elemento(sig));

    Ok((xml::para_bytes(&raiz, true), id))
}

/// Assina a DPS (elemento infDPS).
pub fn assinar_dps(xml_bytes: &[u8], ns_nfse: &str, m: &Material) -> Res<(Vec<u8>, String)> {
    assinar(xml_bytes, "DPS", "infDPS", ns_nfse, m)
}

/// Assina o pedido de registro de evento (elemento infPedReg).
pub fn assinar_evento(xml_bytes: &[u8], ns_nfse: &str, m: &Material) -> Res<Vec<u8>> {
    Ok(assinar(xml_bytes, "pedRegEvento", "infPedReg", ns_nfse, m)?.0)
}
