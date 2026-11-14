//! A visão PERSISTENTE da tela de Registros: lê os logs em disco (logs/nfse_AAAAMMDD.log) e
//! devolve os registros do período, do mais recente para o mais antigo. O histórico da tela vive
//! em memória e morre com a sessão; estes são os mesmos arquivos que já servem de perícia.
use std::sync::OnceLock;

use chrono::{Duration, NaiveDate, NaiveDateTime};
use regex::Regex;
use serde_json::{Value, json};

use crate::texto::{aparar, sort_nome};

// 2026-09-09 11:20:02 | INFO    | nfse.gui       | [op#1] Emissão iniciada: ...
fn rx_linha() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s*\|\s*(\w+)\s*\|\s*([\w.]+)\s*\|\s*(.*)$",
        )
        .expect("regex")
    })
}

fn rx_carimbo() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^\s*\[[^\]]*\]\s*").expect("regex"))
}

/// Mensagem sem o carimbo [op#N] e sem pontuação, para reconhecer o mesmo fato gravado duas
/// vezes: pelo código e pelo aviso da tela.
fn essencia(texto: &str) -> String {
    sort_nome(&rx_carimbo().replace(texto, ""))
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// As linhas de um texto, com todas as quebras que contam como fim de linha.
fn linhas(texto: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut ini = 0;
    let mut it = texto.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        let quebra = matches!(
            c,
            '\n' | '\r'
                | '\u{0b}'
                | '\u{0c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if !quebra {
            continue;
        }
        out.push(&texto[ini..i]);
        let mut fim = i + c.len_utf8();
        if c == '\r' {
            if let Some(&(j, '\n')) = it.peek() {
                it.next();
                fim = j + 1;
            }
        }
        ini = fim;
    }
    if ini < texto.len() {
        out.push(&texto[ini..]);
    }
    out
}

/// Registros do período. `dias` é limitado a 31 para não varrer o diretório inteiro.
pub fn consultar_registros(dias: i64, termo: &str, so_erros: bool, limite: i64) -> Vec<Value> {
    let dias = (if dias == 0 { 30 } else { dias }).clamp(1, 31);
    let limite = (if limite == 0 { 2000 } else { limite }).max(1) as usize;
    let termo_n = if termo.is_empty() {
        String::new()
    } else {
        sort_nome(aparar(termo))
    };
    let corte = chrono::Local::now().naive_local() - Duration::days(dias);
    let pasta = crate::caminhos::raiz().join("logs");
    let Ok(itens) = std::fs::read_dir(&pasta) else {
        return Vec::new();
    };

    // Só os arquivos do período (o nome carrega a data) e do mais novo para o mais velho.
    let mut arquivos: Vec<(NaiveDate, std::path::PathBuf)> = Vec::new();
    for e in itens.flatten() {
        let nome = e.file_name().to_string_lossy().into_owned();
        let Some(radical) = nome.strip_suffix(".log").filter(|r| r.starts_with("nfse_")) else {
            continue;
        };
        let Ok(d) = NaiveDate::parse_from_str(&radical.replace("nfse_", ""), "%Y%m%d") else {
            continue;
        };
        if d >= corte.date() {
            arquivos.push((d, e.path()));
        }
    }
    arquivos.sort_by(|a, b| b.cmp(a));

    let mut out: Vec<Value> = Vec::new();
    let mut ultimo: Option<(NaiveDateTime, String)> = None;
    for (_, arquivo) in arquivos {
        let Ok(bytes) = std::fs::read(&arquivo) else {
            continue;
        };
        let texto = String::from_utf8_lossy(&bytes);
        for linha in linhas(&texto).into_iter().rev() {
            let Some(m) = rx_linha().captures(linha) else {
                continue;
            }; // continuação de traceback: não vira registro próprio
            let (ts, nivel, origem, msg) = (&m[1], &m[2], &m[3], &m[4]);
            let erro = matches!(nivel, "ERROR" | "CRITICAL" | "WARNING");
            if so_erros && !erro {
                continue;
            }
            if !termo_n.is_empty() && !sort_nome(msg).contains(&termo_n) {
                continue;
            }
            let Ok(quando) = NaiveDateTime::parse_from_str(ts, "%Y-%m-%d %H:%M:%S") else {
                continue;
            };
            if quando < corte {
                continue;
            }
            if let Some((antes, essencia_antes)) = &ultimo {
                if (*antes - quando).num_seconds().abs() <= 1 && *essencia_antes == essencia(msg) {
                    continue; // o mesmo fato, dito pelo código e pelo aviso da tela
                }
            }
            ultimo = Some((quando, essencia(msg)));
            out.push(json!({
                "quando": quando.format("%Y-%m-%dT%H:%M:%S").to_string(),
                "nivel": nivel, "origem": origem, "msg": aparar(msg), "erro": erro,
            }));
            if out.len() >= limite {
                return out;
            }
        }
    }
    out
}
