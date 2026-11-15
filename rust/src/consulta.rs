//! Consultas online de CNPJ e CEP, e a lista de municípios do IBGE.
//!
//! - CNPJ: BrasilAPI; se ela falhar, Minha Receita (mesmo formato) e depois ReceitaWS. São dados
//!   públicos da Receita Federal.
//! - CEP: ViaCEP, que também devolve o código IBGE (cMun, 7 dígitos) do município.
//!
//! Devolvem os campos já no vocabulário do cadastro de clientes da NFS-e.
use std::sync::Mutex;

use serde_json::{Map, Value, json};

use crate::erro::{Erro, Res};
use crate::rede::{Resposta, Sessao, Tempo};
use crate::texto::{aparar, only_digits};
use crate::{caminhos, jsonpy};

const TEMPO: Tempo = Tempo {
    conectar: 5.0,
    ler: 12.0,
};
const IDENTIFICACAO: &str = "BaiacuNFSe (consulta de cadastro)";

/// O servidor respondeu com erro (4xx/5xx).
fn erro_http(status: u16, motivo: &str, url: &str) -> Erro {
    let lado = if status < 500 { "Client" } else { "Server" };
    Erro::novo(
        "HTTPError",
        format!("{status} {lado} Error: {motivo} for url: {url}"),
    )
    .com_dados(json!({ "status_code": status }))
}

/// É uma falha de CONEXÃO (não chegou a haver resposta)?
fn de_conexao(e: &Erro) -> bool {
    matches!(
        e.tipo,
        "ConnectionError" | "ConnectTimeout" | "SSLError" | "ProxyError"
    )
}

/// IPv4 PRIMEIRO. Esses serviços publicam endereços IPv6 e, numa rede cujo IPv6 não sai para a
/// internet, cada tentativa esperava o tempo de conexão inteiro antes de cair no IPv4 (a
/// consulta ficava 12-24 s parada). Rede só com IPv6: tenta de novo do jeito padrão.
fn get(url: &str) -> Res<Resposta> {
    let cabecalhos = [("Accept", "application/json")];
    match Sessao::nova(None, TEMPO, IDENTIFICACAO, true)?.get(url, &cabecalhos) {
        Err(e) if de_conexao(&e) => {
            Sessao::nova(None, TEMPO, IDENTIFICACAO, false)?.get(url, &cabecalhos)
        }
        outro => outro,
    }
}

fn conferir(r: &Resposta) -> Res<()> {
    if r.status >= 400 {
        Err(erro_http(r.status, &r.motivo, &r.url))
    } else {
        Ok(())
    }
}

fn json_de(r: &Resposta) -> Res<Value> {
    r.json().ok_or_else(|| {
        Erro::novo(
            "JSONDecodeError",
            "Expecting value: line 1 column 1 (char 0)",
        )
    })
}

fn verdadeiro(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64() != Some(0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(o)) => !o.is_empty(),
    }
}

/// `str(d.get(campo) or "")`.
fn campo(d: &Value, nome: &str) -> String {
    match d.get(nome) {
        v if !verdadeiro(v) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Bool(_)) => "True".into(),
        Some(outro) => jsonpy::dumps(outro, jsonpy::Formato::UTF8),
        None => String::new(),
    }
}

fn ou(a: String, b: String) -> String {
    if a.is_empty() { b } else { a }
}

fn objeto(pares: &[(&str, String)]) -> Value {
    let mut m = Map::new();
    for (k, v) in pares {
        m.insert((*k).to_string(), Value::String(v.clone()));
    }
    Value::Object(m)
}

pub fn consultar_cep(cep: &str) -> Res<Value> {
    let cep = only_digits(cep);
    if cep.chars().count() != 8 {
        return Err(Erro::valor("CEP deve ter 8 dígitos."));
    }
    let r = get(&format!("https://viacep.com.br/ws/{cep}/json/"))?;
    conferir(&r)?;
    let d = json_de(&r)?;
    if verdadeiro(d.get("erro")) {
        return Err(Erro::valor("CEP não encontrado."));
    }
    Ok(objeto(&[
        ("CEP", cep),
        ("xLgr", campo(&d, "logradouro")),
        ("xCpl", campo(&d, "complemento")),
        ("xBairro", campo(&d, "bairro")),
        ("cidade", campo(&d, "localidade")),
        ("uf", campo(&d, "uf")),
        ("cMun", campo(&d, "ibge")),
    ]))
}

fn ibge_do_cep(cep: &str) -> String {
    consultar_cep(cep)
        .ok()
        .and_then(|d| d.get("cMun").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_default()
}

/// O cadastro não existe nesta base (as bases não atualizam juntas: confere na próxima).
const NAO_ENCONTRADO: &str = "_NaoEncontrado";

/// Formato da BrasilAPI — e da Minha Receita, que é a fonte dela.
fn de_brasilapi(d: &Value) -> Res<Value> {
    let ibge = only_digits(&campo(d, "codigo_municipio_ibge"));
    Ok(objeto(&[
        (
            "xNome",
            ou(campo(d, "razao_social"), campo(d, "nome_fantasia")),
        ),
        ("CEP", only_digits(&campo(d, "cep"))),
        ("xLgr", campo(d, "logradouro")),
        ("nro", campo(d, "numero")),
        ("xCpl", campo(d, "complemento")),
        ("xBairro", campo(d, "bairro")),
        ("cidade", campo(d, "municipio")),
        ("uf", campo(d, "uf")),
        (
            "fone",
            only_digits(&ou(campo(d, "ddd_telefone_1"), campo(d, "telefone"))),
        ),
        ("email", campo(d, "email")),
        (
            "cMun",
            if ibge.chars().count() == 7 {
                ibge
            } else {
                String::new()
            },
        ),
    ]))
}

fn de_receitaws(d: &Value) -> Res<Value> {
    if campo(d, "status").to_uppercase() == "ERROR" {
        // A ReceitaWS responde 200 também para "CNPJ inválido"/"não encontrado".
        return Err(Erro::novo(NAO_ENCONTRADO, campo(d, "message")));
    }
    let fone = campo(d, "telefone");
    Ok(objeto(&[
        ("xNome", ou(campo(d, "nome"), campo(d, "fantasia"))),
        ("CEP", only_digits(&campo(d, "cep"))),
        ("xLgr", campo(d, "logradouro")),
        ("nro", campo(d, "numero")),
        ("xCpl", campo(d, "complemento")),
        ("xBairro", campo(d, "bairro")),
        ("cidade", campo(d, "municipio")),
        ("uf", campo(d, "uf")),
        ("fone", only_digits(fone.split('/').next().unwrap_or(""))),
        ("email", campo(d, "email")),
        ("cMun", String::new()),
    ]))
}

type Conversor = fn(&Value) -> Res<Value>;

const FONTES_CNPJ: [(&str, &str, Conversor); 3] = [
    (
        "BrasilAPI",
        "https://brasilapi.com.br/api/cnpj/v1/",
        de_brasilapi,
    ),
    ("Minha Receita", "https://minhareceita.org/", de_brasilapi),
    (
        "ReceitaWS",
        "https://receitaws.com.br/v1/cnpj/",
        de_receitaws,
    ),
];

/// Dados cadastrais do CNPJ. Se um serviço estiver fora do ar, tenta o seguinte; só falha quando
/// nenhum responde.
pub fn consultar_cnpj(cnpj: &str) -> Res<Value> {
    // CNPJ pode ser ALFANUMÉRICO: ficam os dígitos e as letras de A a Z.
    let cnpj: String = cnpj
        .to_uppercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    if cnpj.len() != 14 {
        return Err(Erro::valor("CNPJ deve ter 14 caracteres."));
    }
    let mut falhas: Vec<String> = Vec::new();
    let mut nao_encontrado = false;
    for (nome, url, converter) in FONTES_CNPJ {
        let tentativa = (|| -> Res<Value> {
            let r = get(&format!("{url}{cnpj}"))?;
            if r.status == 400 || r.status == 404 {
                return Err(Erro::novo(NAO_ENCONTRADO, ""));
            }
            conferir(&r)?;
            converter(&json_de(&r)?)
        })();
        let mut out = match tentativa {
            Ok(v) => v,
            Err(e) if e.tipo == NAO_ENCONTRADO => {
                nao_encontrado = true;
                continue;
            }
            Err(e)
                if crate::rede::erro_de_rede(&e)
                    || matches!(e.tipo, "HTTPError" | "JSONDecodeError" | "ValueError") =>
            {
                let status = e.dado("status_code").as_u64();
                falhas.push(format!(
                    "{nome}: {}",
                    status
                        .map(|s| format!("erro {s}"))
                        .unwrap_or_else(|| e.tipo.to_string())
                ));
                continue;
            }
            Err(e) => return Err(e),
        };
        let texto = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        if texto(&out, "cMun").is_empty() && texto(&out, "CEP").chars().count() == 8 {
            let ibge = ibge_do_cep(&texto(&out, "CEP"));
            if let Some(m) = out.as_object_mut() {
                m.insert("cMun".into(), Value::String(ibge));
            }
        }
        return Ok(out);
    }
    if nao_encontrado {
        return Err(Erro::valor("CNPJ não encontrado."));
    }
    Err(Erro::runtime(format!(
        "os serviços de consulta estão indisponíveis no momento ({}). Tente de novo em instantes.",
        falhas.join("; ")
    )))
}

// --------------------------------------------------------------------------------------------- //
// Municípios (IBGE) — lista Cidade/UF do cadastro de clientes
// --------------------------------------------------------------------------------------------- //
static MUNICIPIOS: Mutex<Option<Vec<(String, String, String)>>> = Mutex::new(None);

/// Baixa a lista completa do IBGE. Sem rede/erro, devolve vazio (a tela cai para texto livre na
/// Cidade).
fn baixar_municipios() -> Vec<(String, String, String)> {
    let baixar = || -> Res<Vec<(String, String, String)>> {
        let r = Sessao::nova(None, Tempo::igual(15.0), "BaiacuNFSe", false)?.get(
            "https://servicodados.ibge.gov.br/api/v1/localidades/municipios",
            &[],
        )?;
        conferir(&r)?;
        let lista = json_de(&r)?;
        let mut out = Vec::new();
        for m in lista.as_array().into_iter().flatten() {
            let mut uf = String::new();
            for caminho in [
                ["microrregiao", "mesorregiao", "UF"],
                ["regiao-imediata", "regiao-intermediaria", "UF"],
            ] {
                let mut no = Some(m);
                for chave in caminho {
                    no = no
                        .and_then(|n| n.get(chave))
                        .filter(|n| verdadeiro(Some(n)));
                }
                if let Some(n) = no {
                    uf = campo(n, "sigla");
                    break;
                }
            }
            let (cod, nome) = (campo(m, "id"), campo(m, "nome"));
            if !cod.is_empty() && !nome.is_empty() {
                out.push((cod, nome, uf));
            }
        }
        out.sort_by(|a, b| (&a.1, &a.2).cmp(&(&b.1, &b.2)));
        Ok(out)
    };
    baixar().unwrap_or_default()
}

/// Municípios do IBGE como (código, nome, UF), ordenados por nome. Baixados UMA vez e guardados
/// em configs/municipios.json (+ memória do processo).
pub fn listar_municipios() -> Vec<(String, String, String)> {
    let mut guardado = MUNICIPIOS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(m) = guardado.as_ref() {
        return m.clone();
    }
    let arquivo = caminhos::recurso(&["configs"]).join("municipios.json");
    let do_arquivo = std::fs::read(&arquivo)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| {
            let mut out = Vec::new();
            for item in v.as_array()? {
                let t = |i: usize| {
                    item.get(i).map(|x| {
                        x.as_str()
                            .map(str::to_string)
                            .unwrap_or_else(|| x.to_string())
                    })
                };
                out.push((t(0)?, t(1)?, t(2)?));
            }
            Some(out)
        });
    let dados = match do_arquivo {
        Some(d) => d,
        None => {
            // sem o arquivo (1ª vez) ou arquivo estragado
            let d = baixar_municipios();
            if !d.is_empty() {
                let v: Vec<Value> = d.iter().map(|(c, n, u)| json!([c, n, u])).collect();
                if let Some(pai) = arquivo.parent() {
                    let _ = std::fs::create_dir_all(pai);
                }
                let _ = std::fs::write(
                    &arquivo,
                    jsonpy::dumps(&Value::Array(v), jsonpy::Formato::UTF8),
                );
            }
            d
        }
    };
    // Falhou baixar? NÃO guarda o vazio para sempre — tenta de novo na próxima chamada.
    if !dados.is_empty() {
        *guardado = Some(dados.clone());
    }
    dados
}

/// Link público da consulta de NFS-e, de acordo com o ambiente da emissão. Sem ambiente válido,
/// assume produção.
pub fn url_consulta_nfse(ambiente: &str) -> &'static str {
    if aparar(ambiente) == "2" {
        "https://www.producaorestrita.nfse.gov.br/consultapublica"
    } else {
        "https://www.nfse.gov.br/consultapublica"
    }
}

/// Link da consulta pública que já abre NA NOTA (chave na própria URL).
pub fn url_consulta_nfse_completa(chave: &str, ambiente: &str) -> String {
    let host = if aparar(ambiente) == "2" {
        "www.producaorestrita.nfse.gov.br"
    } else {
        "www.nfse.gov.br"
    };
    format!("https://{host}/ConsultaPublica/?tpc=1&chave={chave}")
}
