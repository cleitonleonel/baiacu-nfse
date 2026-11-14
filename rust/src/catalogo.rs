//! Domínios IBS/CBS e listas de serviço publicados para a NFS-e em produção.
//!
//! Os arquivos em configs/ são fotografias das tabelas oficiais. O portal não é consultado
//! durante uma emissão, para que uma indisponibilidade não altere o XML.
use std::sync::OnceLock;

use serde_json::Value;

use crate::caminhos;

fn tabela(arquivo: &str) -> Value {
    std::fs::read(caminhos::recurso(&["configs", arquivo]))
        .ok()
        .and_then(|b| serde_json::from_slice(b.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&b)).ok())
        .unwrap_or(Value::Null)
}

fn lista(
    arquivo: &'static str,
    chave: &'static str,
    guarda: &'static OnceLock<Vec<Value>>,
) -> &'static [Value] {
    guarda.get_or_init(|| {
        tabela(arquivo)
            .get(chave)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    })
}

/// A tabela de produção mais os códigos que só existem no leiaute novo da NFS-e (NT 009), de um
/// arquivo à parte: a fotografia da tabela de produção continua igual à oficial.
fn lista_com_novos(
    arquivo: &'static str,
    novos: &'static str,
    chave: &'static str,
    guarda: &'static OnceLock<Vec<Value>>,
) -> &'static [Value] {
    guarda.get_or_init(|| {
        let ler = |nome: &str| {
            tabela(nome)
                .get(chave)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        };
        let mut itens = ler(arquivo);
        for novo in ler(novos) {
            if !itens.iter().any(|i| t(i, "codigo") == t(&novo, "codigo")) {
                itens.push(novo);
            }
        }
        itens
    })
}

fn operacoes() -> &'static [Value] {
    static T: OnceLock<Vec<Value>> = OnceLock::new();
    lista_com_novos("indic_op.json", "indic_op_nt009.json", "operacoes", &T)
}

fn classificacoes() -> &'static [Value] {
    static T: OnceLock<Vec<Value>> = OnceLock::new();
    lista("rtc_classificacoes.json", "classificacoes", &T)
}

fn tributacao_nacional() -> &'static [Value] {
    static T: OnceLock<Vec<Value>> = OnceLock::new();
    lista_com_novos(
        "cod_tribut_nac.json",
        "cod_tribut_nac_nt009.json",
        "tributacao_nacional",
        &T,
    )
}

fn nbs() -> &'static [Value] {
    static T: OnceLock<Vec<Value>> = OnceLock::new();
    lista("item_nbs.json", "nbs", &T)
}

fn t<'a>(item: &'a Value, campo: &str) -> &'a str {
    item.get(campo).and_then(Value::as_str).unwrap_or("")
}

pub type Opcoes = Vec<(String, String)>;

/// (código, "código - tipo - local") do indicador da operação.
pub fn indop_options() -> &'static Opcoes {
    static O: OnceLock<Opcoes> = OnceLock::new();
    O.get_or_init(|| {
        operacoes()
            .iter()
            .map(|i| {
                (
                    t(i, "codigo").to_string(),
                    format!("{} - {} - {}", t(i, "codigo"), t(i, "tipo"), t(i, "local")),
                )
            })
            .collect()
    })
}

/// (CST, "CST - nome"), em ordem de código.
pub fn cst_options() -> &'static Opcoes {
    static O: OnceLock<Opcoes> = OnceLock::new();
    O.get_or_init(|| {
        let mut nomes: std::collections::BTreeMap<String, String> = Default::default();
        for i in classificacoes() {
            nomes.insert(t(i, "cst").to_string(), t(i, "cst_nome").to_string());
        }
        nomes
            .into_iter()
            .map(|(c, n)| (c.clone(), format!("{c} - {n}")))
            .collect()
    })
}

/// (código, "código - descrição") das classificações de um CST.
pub fn class_options(cst: &str) -> Opcoes {
    classificacoes()
        .iter()
        .filter(|i| t(i, "cst") == cst)
        .map(|i| {
            (
                t(i, "codigo").to_string(),
                format!("{} - {}", t(i, "codigo"), t(i, "descricao")),
            )
        })
        .collect()
}

/// "código - descrição" de uma classificação tributária do IBS/CBS (vazio se não está na tabela).
pub fn classtrib_rotulo(codigo: &str) -> String {
    classificacoes()
        .iter()
        .find(|i| t(i, "codigo") == codigo)
        .map(|i| format!("{} - {}", t(i, "codigo"), t(i, "descricao")))
        .unwrap_or_default()
}

pub fn valid_indop(codigo: &str) -> bool {
    operacoes().iter().any(|i| t(i, "codigo") == codigo)
}

pub fn valid_classification(cst: &str, codigo: &str) -> bool {
    classificacoes()
        .iter()
        .any(|i| t(i, "cst") == cst && t(i, "codigo") == codigo)
}

/// (código, "00.00.00 - descrição") da tributação nacional.
pub fn tribnac_options() -> &'static Opcoes {
    static O: OnceLock<Opcoes> = OnceLock::new();
    O.get_or_init(|| {
        tributacao_nacional()
            .iter()
            .map(|i| {
                let c: Vec<char> = t(i, "codigo").chars().collect();
                let parte = |a: usize, b: usize| {
                    c.iter()
                        .skip(a)
                        .take(b.saturating_sub(a))
                        .collect::<String>()
                };
                let resto: String = c.iter().skip(4).collect();
                (
                    t(i, "codigo").to_string(),
                    format!(
                        "{}.{}.{} - {}",
                        parte(0, 2),
                        parte(2, 4),
                        resto,
                        t(i, "descricao")
                    ),
                )
            })
            .collect()
    })
}

/// (código, "código - descrição") dos itens da NBS.
pub fn nbs_options() -> &'static Opcoes {
    static O: OnceLock<Opcoes> = OnceLock::new();
    O.get_or_init(|| {
        nbs()
            .iter()
            .map(|i| {
                let (c, d) = (t(i, "codigo"), t(i, "descricao"));
                (
                    c.to_string(),
                    if d.is_empty() {
                        c.to_string()
                    } else {
                        format!("{c} - {d}")
                    },
                )
            })
            .collect()
    })
}

/// Deixa tabelas e rótulos prontos para a sessão.
pub fn preload() {
    indop_options();
    cst_options();
    tribnac_options();
    nbs_options();
}

pub fn valid_tribnac(codigo: &str) -> bool {
    tributacao_nacional()
        .iter()
        .any(|i| t(i, "codigo") == codigo)
}

pub fn valid_nbs(codigo: &str) -> bool {
    nbs().iter().any(|i| t(i, "codigo") == codigo)
}
