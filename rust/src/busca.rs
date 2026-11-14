//! Busca das telas de notas — Consultar e Cofre usam ESTA regra, as duas iguais.
//!
//! O que se pode digitar (uma ou mais palavras; TODAS têm de bater na mesma nota):
//! - texto (tem letra): parte do NOME, sem diferenciar maiúsculas nem acentos;
//! - número da nota: "2252" acha a nota 2252 (e as que começam assim, enquanto se digita);
//! - valor, do jeito que vier: "2252", "2.252", "2252,40", "2.252,40" e "2252.40";
//! - CNPJ/CPF, com ou sem pontuação (do começo) — e o CNPJ com letras do mesmo jeito;
//! - data de processamento: "05/06/2026", "05/06", "5/6";
//! - chave de acesso (20 caracteres ou mais; em qualquer parte dela).
//!
//! Cada nota tem um texto de busca já pronto (coluna `busca`), montado por `texto()`:
//! " NOME DOCUMENTO NUMERO VALOR_SERVICO VALOR_LIQUIDO DD/MM/AAAA" — maiúsculas, sem acento,
//! valores sem ponto de milhar e com vírgula, cada campo precedido de UM espaço. Um termo
//! NUMÉRICO bate no INÍCIO de um campo (LIKE '% 2252%'); um termo com letras bate em qualquer
//! parte.
use std::sync::OnceLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

use crate::texto;

/// Rótulo do campo de busca das duas telas.
pub const ROTULO: &str = "Buscar por nome, CNPJ, nº, valor ou data";
/// A partir de quantos caracteres um termo é tratado como chave de acesso.
pub const CHAVE_MIN: usize = 20;

fn rx(guarda: &'static OnceLock<Regex>, padrao: &str) -> &'static Regex {
    guarda.get_or_init(|| Regex::new(padrao).expect("expressão regular"))
}

fn rx_numerico() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    rx(&R, r"^\d[\d.,/\-]*$")
}

fn rx_data() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    rx(&R, r"^(\d{1,2})/(\d{1,2})(?:/(\d{0,4}))?$")
}

fn rx_valor_br() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    rx(&R, r"^\d{1,3}(?:\.\d{3})+(?:,\d{0,2})?$|^\d+(?:,\d{0,2})?$")
}

fn rx_valor_ponto() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    rx(&R, r"^\d+\.\d{1,2}$")
}

fn rx_iso() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    rx(&R, r"^\s*(\d{4})-(\d{2})-(\d{2})")
}

/// Começo de um CNPJ escrito COM a pontuação (XX.XXX[.XXX[/XXXX[-DD]]]), letras ou dígitos.
fn rx_doc_pontuado() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    rx(
        &R,
        r"^[0-9A-Z]{2}\.[0-9A-Z]{3}(?:\.[0-9A-Z]{0,3}(?:/[0-9A-Z]{0,4}(?:-\d{0,2})?)?)?$",
    )
}

fn branco(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// Maiúsculas e sem acentos.
pub fn sem_acento_maiusculo(s: &str) -> String {
    s.to_uppercase()
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect()
}

/// Maiúsculas, sem acentos, espaços simples.
pub fn normalizar(s: &str) -> String {
    sem_acento_maiusculo(s)
        .split(branco)
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn so_alnum(s: &str) -> String {
    s.to_uppercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// 2252.4 -> '2252,40'.
pub fn valor_num(n: f64) -> String {
    texto::duas_casas(n).replace('.', ",")
}

/// '2026-06-05T14:15:07-03:00' -> '05/06/2026' ('' se não começar por uma data ISO).
pub fn data_br(iso: &str) -> String {
    match rx_iso().captures(iso) {
        Some(m) => format!("{}/{}/{}", &m[3], &m[2], &m[1]),
        None => String::new(),
    }
}

/// Texto de busca de UMA nota (o que vai na coluna `busca`).
pub fn texto(nome: &str, documento: &str, numero: &str, valores: &[f64], data: &str) -> String {
    let mut partes = vec![normalizar(nome), so_alnum(documento), so_alnum(numero)];
    partes.extend(valores.iter().map(|v| valor_num(*v)));
    partes.push(data_br(data));
    format!(
        " {}",
        partes
            .into_iter()
            .filter(|p| !p.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    )
}

#[derive(Debug, Clone, PartialEq)]
pub enum Tipo {
    /// Bate em qualquer parte.
    Txt,
    /// Bate no início de um campo, em qualquer das formas.
    Num,
    /// Bate em qualquer parte da chave de acesso.
    Chave,
    /// CNPJ com letras digitado com a pontuação: [como foi digitado, sem a pontuação].
    Doc,
}

/// O que foi digitado -> [(tipo, formas)], uma entrada por palavra.
pub fn termos(consulta: &str) -> Vec<(Tipo, Vec<String>)> {
    let mut out = Vec::new();
    let limpa = normalizar(consulta).replace("R$", " ");
    for t in limpa.split(branco).filter(|p| !p.is_empty()) {
        // Centavos digitados sem a parte inteira: ',59' encontra 195,59.
        if t.starts_with([',', '.']) && t.len() > 1 && t[1..].chars().all(texto::digito) {
            out.push((Tipo::Txt, vec![t.replace('.', ",")]));
            continue;
        }
        let alnum = so_alnum(t);
        if alnum.is_empty() {
            continue;
        }
        if alnum.chars().count() >= CHAVE_MIN {
            out.push((Tipo::Chave, vec![alnum]));
            continue;
        }
        if !rx_numerico().is_match(t) {
            if alnum != t && rx_doc_pontuado().is_match(t) {
                out.push((Tipo::Doc, vec![t.to_string(), alnum]));
            } else {
                out.push((Tipo::Txt, vec![t.to_string()]));
            }
            continue;
        }
        let mut formas: Vec<String> = Vec::new();
        if let Some(m) = rx_data().captures(t) {
            let dia: u32 = m[1].parse().unwrap_or(0);
            let mes: u32 = m[2].parse().unwrap_or(0);
            let ano = m.get(3).map(|a| {
                if a.as_str().chars().count() == 2 {
                    format!("20{}", a.as_str())
                } else {
                    a.as_str().to_string()
                }
            });
            formas.push(format!(
                "{dia:02}/{mes:02}{}",
                ano.map(|a| format!("/{a}")).unwrap_or_default()
            ));
        } else {
            if rx_valor_br().is_match(t) {
                formas.push(t.replace('.', "")); // 2.252,40 -> 2252,40 ; 2.252 -> 2252
            } else if rx_valor_ponto().is_match(t) {
                formas.push(t.replace('.', ",")); // 2252.40 -> 2252,40
            }
            if !t.contains(',') {
                formas.push(alnum); // número ou documento, sem a pontuação
            }
        }
        let mut unicas: Vec<String> = Vec::new();
        for f in formas {
            if !f.is_empty() && !unicas.contains(&f) {
                unicas.push(f);
            }
        }
        if !unicas.is_empty() {
            out.push((Tipo::Num, unicas));
        }
    }
    out
}

fn like(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// Inclui os valores reais da nota: índices de busca antigos ou gerados em lote
/// podem não conter os valores. Mantém a regra de início de campo para números.
pub fn sql_notas(consulta: &str, coluna: &str, chave: &str) -> (String, Vec<String>) {
    let mut condicoes = Vec::new();
    let mut parametros = Vec::new();
    for palavra in normalizar(consulta).replace("R$", " ").split_whitespace() {
        let (condicao, mut args) = sql(palavra, coluna, chave);
        if condicao.is_empty() {
            continue;
        }
        let mut alternativas = vec![condicao];
        for (tipo, formas) in termos(palavra) {
            let centavos = tipo == Tipo::Txt
                && formas
                    .first()
                    .is_some_and(|s| s.starts_with(',') && s[1..].chars().all(texto::digito));
            if tipo != Tipo::Num && !centavos {
                continue;
            }
            for forma in formas {
                let padrao = if centavos {
                    format!("%{}%", like(&forma))
                } else {
                    format!("{}%", like(&forma))
                };
                for valor in ["vServ", "vLiq"] {
                    alternativas.push(format!(
                        "replace(printf('%.2f', {valor}), '.', ',') LIKE ? ESCAPE '\\'"
                    ));
                    args.push(padrao.clone());
                }
            }
        }
        condicoes.push(format!("({})", alternativas.join(" OR ")));
        parametros.extend(args);
    }
    (condicoes.join(" AND "), parametros)
}

/// (condição SQL, parâmetros) para o que foi digitado — '' e [] se não há o que filtrar. A
/// condição já vem entre parênteses, pronta para um AND.
pub fn sql(consulta: &str, coluna: &str, coluna_chave: &str) -> (String, Vec<String>) {
    let mut conds: Vec<String> = Vec::new();
    let mut params: Vec<String> = Vec::new();
    for (tipo, formas) in termos(consulta) {
        match tipo {
            Tipo::Chave => {
                conds.push(format!("{coluna_chave} LIKE ? ESCAPE '\\'"));
                params.push(format!("%{}%", like(&formas[0])));
            }
            Tipo::Num => {
                let um = format!("{coluna} LIKE ? ESCAPE '\\'");
                conds.push(format!("({})", vec![um; formas.len()].join(" OR ")));
                params.extend(formas.iter().map(|f| format!("% {}%", like(f))));
            }
            Tipo::Doc => {
                conds.push(format!(
                    "({coluna} LIKE ? ESCAPE '\\' OR {coluna} LIKE ? ESCAPE '\\')"
                ));
                params.push(format!("%{}%", like(&formas[0])));
                params.push(format!("% {}%", like(&formas[1])));
            }
            Tipo::Txt => {
                conds.push(format!("{coluna} LIKE ? ESCAPE '\\'"));
                params.push(format!("%{}%", like(&formas[0])));
            }
        }
    }
    (
        if conds.is_empty() {
            String::new()
        } else {
            format!("({})", conds.join(" AND "))
        },
        params,
    )
}

/// A mesma regra de `sql()`, em memória.
pub fn casa(consulta: &str, texto_busca: &str, chave: &str) -> bool {
    for (tipo, formas) in termos(consulta) {
        let ok = match tipo {
            Tipo::Chave => so_alnum(chave).contains(&formas[0]),
            Tipo::Num => formas
                .iter()
                .any(|f| texto_busca.contains(&format!(" {f}"))),
            Tipo::Doc => {
                texto_busca.contains(&formas[0]) || texto_busca.contains(&format!(" {}", formas[1]))
            }
            Tipo::Txt => texto_busca.contains(&formas[0]),
        };
        if !ok {
            return false;
        }
    }
    true
}

/// Se o que foi digitado é SÓ um número de nota (só dígitos, até 15), devolve-o: as telas põem a
/// nota com exatamente esse número no topo da lista. Senão, ''.
pub fn numero_exato(consulta: &str) -> String {
    let s = texto::aparar(consulta);
    if !s.is_empty() && s.chars().all(texto::digito) && s.chars().count() <= 15 {
        s.to_string()
    } else {
        String::new()
    }
}
