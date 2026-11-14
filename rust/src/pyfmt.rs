//! Textos no formato que o Python dava: várias mensagens do programa mostram valores como o
//! Python os escreve (`repr`) — `'texto'`, `['a', 'b']`, `{'chave': 1}` — e continuam iguais.

/// Caractere que o `repr` do Python escapa (não "imprimível").
fn escapado(c: char) -> bool {
    let n = c as u32;
    n < 0x20
        || (0x7f..=0xa0).contains(&n)
        || n == 0xad
        || (0x600..=0x605).contains(&n)
        || n == 0x61c
        || n == 0x6dd
        || n == 0x70f
        || n == 0x1680
        || n == 0x180e
        || (0x2000..=0x200f).contains(&n)
        || (0x2028..=0x202f).contains(&n)
        || (0x205f..=0x2064).contains(&n)
        || (0x2066..=0x206f).contains(&n)
        || n == 0x3000
        || (0xe000..=0xf8ff).contains(&n)
        || n == 0xfeff
        || (0xfff9..=0xfffb).contains(&n)
        || (0xf0000..=0x10ffff).contains(&n)
}

/// `str.isprintable()` de um caractere.
pub fn imprimivel(c: char) -> bool {
    !escapado(c)
}

/// `repr(str)` do Python.
pub fn repr(s: &str) -> String {
    let aspa = if s.contains('\'') && !s.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut r = String::with_capacity(s.len() + 2);
    r.push(aspa);
    for c in s.chars() {
        match c {
            '\\' => r.push_str("\\\\"),
            '\n' => r.push_str("\\n"),
            '\r' => r.push_str("\\r"),
            '\t' => r.push_str("\\t"),
            c if c == aspa => {
                r.push('\\');
                r.push(c);
            }
            c if escapado(c) => {
                let n = c as u32;
                if n <= 0xff {
                    r.push_str(&format!("\\x{n:02x}"));
                } else if n <= 0xffff {
                    r.push_str(&format!("\\u{n:04x}"));
                } else {
                    r.push_str(&format!("\\U{n:08x}"));
                }
            }
            c => r.push(c),
        }
    }
    r.push(aspa);
    r
}

/// Um valor de dicionário para `repr_dict`.
pub enum V<'a> {
    T(&'a str),
    I(i64),
}

/// `repr` de um dicionário de textos/inteiros, na ordem dada: `{'a': 'x', 'n': 1}`.
pub fn repr_dict(pares: &[(&str, V)]) -> String {
    let itens: Vec<String> = pares
        .iter()
        .map(|(k, v)| match v {
            V::T(t) => format!("{}: {}", repr(k), repr(t)),
            V::I(n) => format!("{}: {n}", repr(k)),
        })
        .collect();
    format!("{{{}}}", itens.join(", "))
}
