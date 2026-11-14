//! Conferência local do XML da DPS antes do envio: contra o XSD oficial indicado em
//! `configs/paths.ini` e checagens técnicas que a própria SEFIN aponta em rejeições. As regras
//! de negócio continuam por conta da SEFIN, no envio.
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::erro::{Erro, Res};
use crate::ini::Ini;
use crate::leiaute::{self, Leiaute};
use crate::pyfmt::{self, V};
use crate::xml::{self, Elemento, No};
use crate::{caminhos, xsd};

pub const NS_NFSE: &str = "http://www.sped.fazenda.gov.br/nfse";
pub const NS_DS: &str = "http://www.w3.org/2000/09/xmldsig#";

/// Se `mensagem` é "Element '{ns}<tag>': [facet 'pattern'] The value '<valor>' is not accepted by
/// the pattern '<padrao>'.", devolve (tag, valor).
fn erro_de_padrao<'a>(mensagem: &'a str, padrao: &str) -> Option<(&'a str, &'a str)> {
    let resto = mensagem.strip_prefix("Element '{")?;
    let (ns, resto) = resto.split_once('}')?;
    if ns.is_empty() {
        return None;
    }
    let (tag, resto) = resto.split_once("': [facet 'pattern'] The value '")?;
    if tag.is_empty() || !tag.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return None;
    }
    let fim = format!("' is not accepted by the pattern '{padrao}'.");
    let valor = resto.strip_suffix(fim.as_str())?;
    if valor.contains('\'') {
        return None;
    }
    Some((tag, valor))
}

/// CHAVE DE ACESSO com CNPJ ALFANUMÉRICO — falso positivo do XSD oficial v1.01. O tipo
/// TSChaveNFSe só deixa letras nas posições 7 a 20, mas o CNPJ do emitente fica nas posições 10
/// a 23 da chave (é a regra do Id da NFS-e, cujo padrão no MESMO arquivo está certo:
/// 'NFS[0-9]{9}[0-9A-Z]{14}[0-9]{27}'). A conferência local não pode ser mais estreita que a
/// chave que a própria SEFIN gerou: quem decide é ela, no envio.
pub fn chave_falso_positivo_oficial(mensagem: &str) -> bool {
    let Some((_, valor)) = erro_de_padrao(mensagem, "[0-9]{6}([0-9A-Z]{14})[0-9]{30}") else {
        return false;
    };
    let b = valor.as_bytes();
    b.len() == 50
        && b[..9].iter().all(u8::is_ascii_digit)
        && b[9..23]
            .iter()
            .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase())
        && b[23..].iter().all(u8::is_ascii_digit)
}

/// Série de 1 a 5 dígitos recusada pelo padrão '^0{0,4}\d{1,5}$' do XSD oficial (o validador
/// lê `^` e `$` ao pé da letra): falso positivo.
fn serie_falso_positivo_oficial(mensagem: &str) -> bool {
    match erro_de_padrao(mensagem, "^0{0,4}\\d{1,5}$") {
        Some(("serie", valor)) => {
            let n = valor.chars().count();
            (1..=5).contains(&n) && valor.chars().all(|c| c.is_ascii_digit())
        }
        _ => false,
    }
}

pub fn expandir_molde(molde: &str, valores: &[(&str, &str)]) -> String {
    molde
        .replace('\\', "/")
        .split('/')
        .map(|parte| {
            valores
                .iter()
                .find(|(k, _)| *k == parte)
                .map(|(_, v)| *v)
                .unwrap_or(parte)
        })
        .collect::<Vec<_>>()
        .join("/")
}

pub(crate) fn paths_ini() -> Res<(PathBuf, Ini)> {
    let caminho = caminhos::raiz().join("configs").join("paths.ini");
    if !caminho.is_file() {
        return Err(Erro::nao_encontrado(format!(
            "Não foi possivel ler o arquivo: {}",
            caminho.display()
        )));
    }
    let ini = Ini::de_arquivo(&caminho, false)?;
    Ok((caminho, ini))
}

/// Caminho de um XSD apontado em `[schemas]` de paths.ini pela opção `opcao`, na pasta da versão
/// em vigor (`None`) ou na de outra versão do schema (a do leiaute novo).
pub fn caminho_do_esquema_na(opcao: &str, outra_versao: Option<&str>) -> Res<PathBuf> {
    let (arquivo, ini) = paths_ini()?;
    if !ini.tem_secao("schemas") {
        return Err(Erro::valor(format!(
            "Seção obrigatória ausente em {}: [schemas]",
            arquivo.display()
        )));
    }
    if !ini.tem_opcao("schemas", opcao) {
        return Err(Erro::valor(format!(
            "Campo obrigatório ausente em {}: [schemas] {opcao}",
            arquivo.display()
        )));
    }
    let base = ini
        .val("schemas", "dir", "configs/schemas")
        .trim()
        .to_string();
    let versao = match outra_versao {
        Some(v) => v.to_string(),
        None => ini.val("schemas", "versao", "").trim().to_string(),
    };
    let molde_pasta = ini
        .val("schemas", "ful_dir", "dir/versao")
        .trim()
        .to_string();
    let pasta = expandir_molde(&molde_pasta, &[("dir", &base), ("versao", &versao)]);
    let molde = ini.val("schemas", opcao, "").trim().to_string();
    let valor = expandir_molde(
        &molde,
        &[("dir", &base), ("versao", &versao), ("ful_dir", &pasta)],
    );
    Ok(caminhos::normalizar(&caminhos::absoluto(&valor)))
}

/// O XSD principal da DPS (`[schemas] schema_validacao_xml`), do leiaute em vigor.
pub fn caminho_xsd_validacao() -> Res<PathBuf> {
    caminho_xsd_validacao_do(Leiaute::EmVigor)
}

/// O XSD principal da DPS no leiaute dado.
pub fn caminho_xsd_validacao_do(leiaute: Leiaute) -> Res<PathBuf> {
    let versao = match leiaute {
        Leiaute::EmVigor => None,
        Leiaute::Novo => Some(leiaute::versao_do_novo()?),
        Leiaute::Futuro => Some(leiaute::versao_do_futuro()?),
    };
    let caminho = caminho_do_esquema_na("schema_validacao_xml", versao.as_deref())?;
    if !caminho.exists() {
        return Err(Erro::nao_encontrado(format!(
            "XSD de validação não encontrado: {}",
            caminho.display()
        )));
    }
    if !caminho.is_file() {
        return Err(Erro::nao_encontrado(format!(
            "XSD de validação não é arquivo: {}",
            caminho.display()
        )));
    }
    Ok(caminho)
}

/// Valida a DPS contra o XSD do leiaute em que ela foi montada.
pub fn validar_dps(xml_bytes: &[u8]) -> Res<()> {
    let apontamentos = xsd::validar(
        &caminho_xsd_validacao_do(leiaute::do_xml(xml_bytes))?,
        xml_bytes,
    )?;
    let msgs: Vec<String> = apontamentos
        .iter()
        .filter(|a| {
            !serie_falso_positivo_oficial(&a.mensagem) && !chave_falso_positivo_oficial(&a.mensagem)
        })
        .map(|a| format!("Linha {}: {}", a.linha, a.mensagem))
        .collect();
    if msgs.is_empty() {
        return Ok(());
    }
    Err(Erro::valor(format!(
        "XML não validou contra o XSD da DPS:\n{}",
        msgs.join("\n")
    )))
}

/// Compila de antemão os XSD da DPS (o em vigor e o novo), para a primeira pré-visualização e a
/// primeira emissão não pagarem a leitura dos esquemas. Erros são ignorados: é só preparo.
pub fn aquecer() {
    for l in [Leiaute::EmVigor, Leiaute::Novo] {
        if let Ok(caminho) = caminho_xsd_validacao_do(l) {
            let _ = xsd::validar(&caminho, b"<DPS/>");
        }
    }
}

/// Valida a DPS ainda sem assinatura: XSD + checagens técnicas. Devolve o resultado da varredura
/// de caracteres (`issues_count`, `issues`).
pub fn validar_dps_sem_assinatura(xml_bytes: &[u8]) -> Res<Value> {
    validar_dps(xml_bytes)?;
    seguranca_basica(xml_bytes, NS_NFSE, NS_DS, true)
}

// ------------------------------------------------------------------------------- //
// Checagens técnicas
// ------------------------------------------------------------------------------- //
/// Caminho de cada elemento como a libxml2 o escreve: `/*/*[2]/*` para elementos com namespace
/// (padrão), `/a/b[2]` para os sem.
fn caminho_do_no(pai: &str, irmaos: &[&Elemento], i: usize) -> String {
    let e = irmaos[i];
    let generico = !e.ns.is_empty();
    let igual = |o: &Elemento| generico || (o.nome == e.nome && o.ns == e.ns);
    let antes = irmaos[..i].iter().filter(|o| igual(o)).count();
    let ocorrencia = if antes == 0 {
        if irmaos[i + 1..].iter().any(|o| igual(o)) {
            1
        } else {
            0
        }
    } else {
        antes + 1
    };
    let nome = if generico { "*" } else { e.nome.as_str() };
    if ocorrencia == 0 {
        format!("{pai}/{nome}")
    } else {
        format!("{pai}/{nome}[{ocorrencia}]")
    }
}

/// Percorre o documento na ordem em que aparece: (caminho, elemento, texto que vem logo depois
/// dele dentro do pai).
fn percorrer<'a>(raiz: &'a Elemento, f: &mut dyn FnMut(&str, &'a Elemento, Option<&'a str>)) {
    fn descer<'a>(
        caminho: &str,
        e: &'a Elemento,
        cauda: Option<&'a str>,
        f: &mut dyn FnMut(&str, &'a Elemento, Option<&'a str>),
    ) {
        f(caminho, e, cauda);
        let irmaos: Vec<&Elemento> = e.elementos().collect();
        let mut i = 0;
        for (pos, no) in e.filhos.iter().enumerate() {
            if let No::Elemento(filho) = no {
                let cauda = match e.filhos.get(pos + 1) {
                    Some(No::Texto(t)) => Some(t.as_str()),
                    _ => None,
                };
                descer(&caminho_do_no(caminho, &irmaos, i), filho, cauda, f);
                i += 1;
            }
        }
    }
    descer(&caminho_do_no("", &[raiz], 0), raiz, None, f);
}

fn nome_qualificado(e: &Elemento) -> String {
    if e.ns.is_empty() {
        e.nome.clone()
    } else {
        format!("{{{}}}{}", e.ns, e.nome)
    }
}

fn conferir_namespaces(raiz: &Elemento, ns_nfse: &str, ns_ds: &str) -> Res<()> {
    let mut fora: Vec<String> = Vec::new();
    percorrer(raiz, &mut |caminho, e, _| {
        if e.ns == ns_nfse || e.ns == ns_ds {
            return;
        }
        let ns = if e.ns.is_empty() {
            "None"
        } else {
            e.ns.as_str()
        };
        fora.push(pyfmt::repr_dict(&[
            ("path", V::T(caminho)),
            ("tag", V::T(&nome_qualificado(e))),
            ("namespace", V::T(ns)),
        ]));
    });
    if fora.is_empty() {
        return Ok(());
    }
    fora.truncate(5);
    Err(Erro::valor(format!(
        "Há elementos fora dos namespaces NFSE/XMLDSIG: [{}]",
        fora.join(", ")
    )))
}

fn sem_xmlns_vazio(xml_bytes: &[u8]) -> Res<()> {
    let alvo = b"xmlns=\"\"";
    if xml_bytes.windows(alvo.len()).any(|j| j == alvo) {
        return Err(Erro::valor(
            "XML contém xmlns=\"\"; isso quebra namespaces/canonicalização.",
        ));
    }
    Ok(())
}

fn sem_prefixos(xml_bytes: &[u8]) -> Res<()> {
    let alvo = b"xmlns:";
    let mut achou = xml_bytes.windows(alvo.len()).any(|j| j == alvo);
    // <nome:  (nome = letra ou _, depois letras, dígitos, _ . -)
    let mut i = 0;
    while !achou && i < xml_bytes.len() {
        if xml_bytes[i] == b'<' {
            let mut j = i + 1;
            if j < xml_bytes.len() && (xml_bytes[j].is_ascii_alphabetic() || xml_bytes[j] == b'_') {
                j += 1;
                while j < xml_bytes.len()
                    && (xml_bytes[j].is_ascii_alphanumeric()
                        || matches!(xml_bytes[j], b'_' | b'.' | b'-'))
                {
                    j += 1;
                }
                achou = j < xml_bytes.len() && xml_bytes[j] == b':';
            }
        }
        i += 1;
    }
    if achou {
        return Err(Erro::valor(
            "XML contém prefixo de namespace. A SEFIN rejeitou esse formato.",
        ));
    }
    Ok(())
}

/// Procura caracteres que o layout não aceita (fora do XML 1.0 ou além do Latin-1).
pub fn varrer_texto(raiz: &Elemento) -> Value {
    let mut problemas: Vec<Value> = Vec::new();
    let mut conferir = |caminho: &str, tipo: String, valor: Option<&str>| {
        let Some(valor) = valor else { return };
        for (indice, c) in valor.chars().enumerate() {
            let n = c as u32;
            let xml10 = matches!(c, '\t' | '\n' | '\r') || n >= 0x20;
            let latin1 = n <= 0xff;
            if !xml10 || !latin1 {
                problemas.push(json!({
                    "path": caminho,
                    "kind": tipo,
                    "index": indice,
                    "char": c.to_string(),
                    "codepoint_dec": n,
                    "codepoint_hex": format!("{n:#x}"),
                    "reason": if !xml10 { "invalid_xml10" } else { "outside_latin1_layout_range" },
                    "value_preview": valor.chars().take(300).collect::<String>(),
                }));
            }
        }
    };
    percorrer(raiz, &mut |caminho, e, cauda| {
        let texto = match e.filhos.first() {
            Some(No::Texto(t)) => Some(t.as_str()),
            _ => None,
        };
        conferir(caminho, format!("text:{}", e.nome), texto);
        conferir(caminho, format!("tail:{}", e.nome), cauda);
        for (k, v) in &e.atributos {
            conferir(caminho, format!("attr:{k}"), Some(v));
        }
    });
    json!({ "issues_count": problemas.len(), "issues": problemas })
}

fn repr_problema(p: &Value) -> String {
    let t = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("");
    let n = |k: &str| p.get(k).and_then(Value::as_i64).unwrap_or(0);
    pyfmt::repr_dict(&[
        ("path", V::T(t("path"))),
        ("kind", V::T(t("kind"))),
        ("index", V::I(n("index"))),
        ("char", V::T(t("char"))),
        ("codepoint_dec", V::I(n("codepoint_dec"))),
        ("codepoint_hex", V::T(t("codepoint_hex"))),
        ("reason", V::T(t("reason"))),
        ("value_preview", V::T(t("value_preview"))),
    ])
}

/// Namespaces, `xmlns=""`, prefixos e caracteres suspeitos.
pub fn seguranca_basica(
    xml_bytes: &[u8],
    ns_nfse: &str,
    ns_ds: &str,
    recusar_prefixos: bool,
) -> Res<Value> {
    let raiz = xml::ler(xml_bytes)?;
    conferir_namespaces(&raiz, ns_nfse, ns_ds)?;
    sem_xmlns_vazio(xml_bytes)?;
    if recusar_prefixos {
        sem_prefixos(xml_bytes)?;
    }
    let varredura = varrer_texto(&raiz);
    let problemas = varredura
        .get("issues")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if !problemas.is_empty() {
        let primeiros: Vec<String> = problemas.iter().take(5).map(repr_problema).collect();
        return Err(Erro::valor(format!(
            "XML contém caracteres suspeitos: [{}]",
            primeiros.join(", ")
        )));
    }
    Ok(varredura)
}
