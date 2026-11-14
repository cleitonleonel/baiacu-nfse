//! JSON escrito como o `json.dumps` do Python — byte a byte.
//!
//! Há arquivos e colunas do banco cujo conteúdo é conferido (soma de verificação do dados.key)
//! ou comparado como texto; o formato tem de ser o mesmo de sempre: não-ASCII como \uXXXX
//! (ensure_ascii), separadores ", " e ": " por padrão, e o recuo de `indent=N`.
use serde_json::Value;

#[derive(Clone, Copy)]
pub struct Formato {
    pub ordenar: bool,        // sort_keys=True
    pub recuo: Option<usize>, // indent=N
    pub compacto: bool,       // separators=(",", ":")
    pub so_ascii: bool,       // ensure_ascii (padrão do Python: True)
}

impl Formato {
    /// `json.dumps(x)`.
    pub const PADRAO: Formato = Formato {
        ordenar: false,
        recuo: None,
        compacto: false,
        so_ascii: true,
    };
    /// `json.dumps(x, sort_keys=True, separators=(",", ":"))`.
    pub const CANONICO: Formato = Formato {
        ordenar: true,
        recuo: None,
        compacto: true,
        so_ascii: true,
    };
    /// `json.dumps(x, ensure_ascii=False)`.
    pub const UTF8: Formato = Formato {
        ordenar: false,
        recuo: None,
        compacto: false,
        so_ascii: false,
    };
}

pub fn dumps(v: &Value, f: Formato) -> String {
    let mut out = String::new();
    escrever(v, f, 0, &mut out);
    out
}

fn escrever(v: &Value, f: Formato, nivel: usize, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&numero(n)),
        Value::String(s) => texto(s, f.so_ascii, out),
        Value::Array(itens) => {
            if itens.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push('[');
            for (i, item) in itens.iter().enumerate() {
                separador(i, f, nivel + 1, out);
                escrever(item, f, nivel + 1, out);
            }
            fecho(f, nivel, out);
            out.push(']');
        }
        Value::Object(mapa) => {
            if mapa.is_empty() {
                out.push_str("{}");
                return;
            }
            let mut chaves: Vec<&String> = mapa.keys().collect();
            if f.ordenar {
                chaves.sort();
            }
            out.push('{');
            for (i, k) in chaves.into_iter().enumerate() {
                separador(i, f, nivel + 1, out);
                texto(k, f.so_ascii, out);
                out.push_str(if f.compacto { ":" } else { ": " });
                escrever(&mapa[k], f, nivel + 1, out);
            }
            fecho(f, nivel, out);
            out.push('}');
        }
    }
}

fn separador(i: usize, f: Formato, nivel: usize, out: &mut String) {
    match f.recuo {
        Some(n) => {
            if i > 0 {
                out.push(',');
            }
            out.push('\n');
            out.push_str(&" ".repeat(n * nivel));
        }
        None => {
            if i > 0 {
                out.push_str(if f.compacto { "," } else { ", " });
            }
        }
    }
}

fn fecho(f: Formato, nivel: usize, out: &mut String) {
    if let Some(n) = f.recuo {
        out.push('\n');
        out.push_str(&" ".repeat(n * nivel));
    }
}

fn numero(n: &serde_json::Number) -> String {
    if let Some(i) = n.as_i64() {
        return i.to_string();
    }
    if let Some(u) = n.as_u64() {
        return u.to_string();
    }
    // float: o repr do Python ("1.0", "0.1", "1e+16", "1e-05").
    let x = n.as_f64().unwrap_or(0.0);
    let s = format!("{x:?}");
    match s.split_once('e') {
        Some((mantissa, exp)) => {
            let mantissa = mantissa.strip_suffix(".0").unwrap_or(mantissa);
            let (sinal, digitos) = match exp.strip_prefix('-') {
                Some(d) => ('-', d),
                None => ('+', exp),
            };
            format!("{mantissa}e{sinal}{digitos:0>2}")
        }
        None => s,
    }
}

fn texto(s: &str, so_ascii: bool, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c if so_ascii && !c.is_ascii() => {
                let mut buf = [0u16; 2];
                for u in c.encode_utf16(&mut buf) {
                    out.push_str(&format!("\\u{:04x}", u));
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
}
