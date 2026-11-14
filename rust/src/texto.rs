//! Texto: documentos (CNPJ/CPF, inclusive CNPJ alfanumérico), descrição do serviço, números
//! digitados e ordenação de nomes.
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::canonical_combining_class;

use crate::pyfmt;

/// Espaço em branco para aparar (o mesmo conjunto de sempre: Unicode + separadores 1C–1F).
fn branco(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// Sem espaços nas pontas.
pub fn aparar(s: &str) -> &str {
    s.trim_matches(branco)
}

/// Sem diferença de caixa, para comparar ('Straße' = 'STRASSE').
pub fn casefold(s: &str) -> String {
    let mut r = String::with_capacity(s.len());
    for c in s.to_lowercase().chars() {
        match c {
            'ß' => r.push_str("ss"),
            'ς' => r.push('σ'),
            'ſ' => r.push('s'),
            'ŉ' => r.push_str("ʼn"),
            'ﬀ' => r.push_str("ff"),
            'ﬁ' => r.push_str("fi"),
            'ﬂ' => r.push_str("fl"),
            'ﬃ' => r.push_str("ffi"),
            'ﬄ' => r.push_str("ffl"),
            'ﬅ' | 'ﬆ' => r.push_str("st"),
            c => r.push(c),
        }
    }
    r
}

/// Chave de ordenação de NOMES: sem acento e sem caixa ('Ágata' vem antes de 'Beto').
pub fn sort_nome(s: &str) -> String {
    casefold(
        &s.nfd()
            .filter(|c| canonical_combining_class(*c) == 0)
            .collect::<String>(),
    )
}

/// Dígito, no sentido amplo de sempre: além de 0–9, os dígitos de largura inteira (colados de
/// texto oriental) e os sobrescritos, subscritos e circulados.
pub fn digito(c: char) -> bool {
    c.is_ascii_digit()
        || matches!(c, '\u{ff10}'..='\u{ff19}' | '\u{b2}' | '\u{b3}' | '\u{b9}' | '\u{2070}' | '\u{2074}'..='\u{2079}'
            | '\u{2080}'..='\u{2089}' | '\u{2460}'..='\u{2468}' | '\u{24ea}')
}

pub fn only_digits(valor: &str) -> String {
    valor.chars().filter(|c| digito(*c)).collect()
}

/// Normaliza um CNPJ/CPF PRESERVANDO letras — o CNPJ pode ser ALFANUMÉRICO (as 12 primeiras
/// posições [0-9A-Z]; os 2 dígitos verificadores continuam numéricos). Fica só o que um
/// documento pode ter: dígitos e letras de A a Z, em maiúsculas.
pub fn only_doc(valor: &str) -> String {
    if !valor.is_empty() && valor.bytes().all(|b| b.is_ascii_digit()) {
        return valor.to_string();
    }
    valor
        .to_uppercase()
        .chars()
        .filter(|c| c.is_ascii_digit() || c.is_ascii_uppercase())
        .collect()
}

/// O que um campo de documento aceita enquanto se digita ou cola. CPF: 11 dígitos. CNPJ: 14
/// posições — letras (maiúsculas) ou dígitos nas 12 primeiras, só dígitos nas 2 últimas.
pub fn mascara_documento(texto: &str, tipo_doc: &str) -> String {
    let d = only_doc(texto);
    if tipo_doc == "CPF" {
        return d.chars().filter(char::is_ascii_digit).take(11).collect();
    }
    let d: Vec<char> = d.chars().take(14).collect();
    let mut r: String = d.iter().take(12).collect();
    r.extend(d.iter().skip(12).filter(|c| c.is_ascii_digit()));
    r
}

/// Normaliza a CHAVE DE ACESSO (50) ou a chave da DPS preservando letras.
pub fn only_chave(valor: &str) -> String {
    valor
        .to_uppercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

pub fn upper_text(valor: &str) -> String {
    aparar(valor).to_uppercase()
}

pub fn lower_email(valor: &str) -> String {
    aparar(valor).to_lowercase()
}

// ------------------------------------------------------------------------------- //
// Descrição do serviço (xDescServ): o que pode ir para a NFS-e
// ------------------------------------------------------------------------------- //
pub const DESC_MAX: usize = 2000;

/// Fora do que a NFS-e aceita na descrição (quebra de linha, tabulação e Latin-1).
fn desc_fora(c: char) -> bool {
    !(c == '\n' || c == '\t' || (' '..='~').contains(&c) || ('\u{a0}'..='\u{ff}').contains(&c))
}

/// Pontuação "tipográfica" -> a equivalente simples.
fn desc_troca(c: char) -> char {
    match c {
        '\u{201c}' | '\u{201d}' | '\u{201e}' | '\u{201f}' | '\u{2033}' => '"',
        '\u{2018}' | '\u{2019}' | '\u{201a}' | '\u{201b}' | '\u{2032}' => '\'',
        '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2015}'
        | '\u{2212}' => '-',
        '\u{2022}' | '\u{25cf}' | '\u{25aa}' | '\u{25e6}' | '\u{2023}' | '\u{2219}' => '-',
        '\u{2028}' | '\u{2029}' => '\n',
        outro => outro,
    }
}

/// Descrição do serviço só com o que a NFS-e aceita. Pontuação tipográfica vira a simples,
/// espaços especiais viram espaço, letra com acento fora do Latin-1 perde o acento, e o que não
/// tem equivalente (emoji, símbolos, caracteres de controle) sai. Não apara espaços: é chamada
/// a cada tecla pelo campo da tela.
pub fn limpar_descricao(texto: &str) -> String {
    if !texto.chars().any(desc_fora) {
        return texto.to_string();
    }
    let s: String = texto
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .nfc()
        .map(desc_troca)
        .collect();
    let mut r = String::with_capacity(s.len());
    for ch in s.chars() {
        if !desc_fora(ch) {
            r.push(ch);
        } else {
            r.extend(
                std::iter::once(ch)
                    .nfkd()
                    .filter(|c| *c != '\n' && *c != '\t' && !desc_fora(*c)),
            );
        }
    }
    r
}

/// O que impede a descrição de ir para a NFS-e, em mensagens para o usuário (vazio = nada).
pub fn descricao_problemas(texto: &str) -> Vec<String> {
    let s = texto.replace("\r\n", "\n").replace('\r', "\n");
    let s = aparar(&s);
    let mut erros = Vec::new();
    let n = s.chars().count();
    if n > DESC_MAX {
        erros.push(format!(
            "Descrição do serviço tem {n} caracteres; o máximo da NFS-e é {DESC_MAX}."
        ));
    }
    let mut fora: Vec<char> = Vec::new();
    for c in s.chars().filter(|c| desc_fora(*c)) {
        if !fora.contains(&c) {
            fora.push(c);
        }
    }
    if !fora.is_empty() {
        let mostra: Vec<String> = fora
            .iter()
            .take(8)
            .map(|c| {
                if pyfmt::imprimivel(*c) {
                    c.to_string()
                } else {
                    format!("U+{:04X}", *c as u32)
                }
            })
            .collect();
        erros.push(format!(
            "Descrição do serviço tem caracteres que a NFS-e não aceita ({}). \
             Edite a descrição: no campo eles são trocados ou retirados.",
            mostra.join(" ")
        ));
    }
    erros
}

// ------------------------------------------------------------------------------- //
// CNPJ / CPF
// ------------------------------------------------------------------------------- //
/// Formata CNPJ (00.000.000/0000-00, inclusive ALFANUMÉRICO) ou CPF (000.000.000-00).
pub fn format_documento(valor: &str) -> String {
    let d = only_doc(valor);
    if d.len() == 14 {
        return format!(
            "{}.{}.{}/{}-{}",
            &d[..2],
            &d[2..5],
            &d[5..8],
            &d[8..12],
            &d[12..]
        );
    }
    if d.len() == 11 && d.bytes().all(|b| b.is_ascii_digit()) {
        return format!("{}.{}.{}-{}", &d[..3], &d[3..6], &d[6..9], &d[9..]);
    }
    valor.to_string()
}

fn todos_iguais(d: &str) -> bool {
    let b = d.as_bytes();
    b.iter().all(|c| *c == b[0])
}

/// Valida os dígitos verificadores do CPF (mod 11).
pub fn cpf_valido(valor: &str) -> bool {
    let d = only_doc(valor);
    if d.len() != 11 || !d.bytes().all(|b| b.is_ascii_digit()) || todos_iguais(&d) {
        return false;
    }
    let dv = |nums: &[u8]| -> u8 {
        let n = nums.len() as u32;
        let s: u32 = nums
            .iter()
            .enumerate()
            .map(|(i, x)| (*x - b'0') as u32 * (n + 1 - i as u32))
            .sum();
        let r = (s * 10) % 11;
        if r == 10 { b'0' } else { b'0' + r as u8 }
    };
    let b = d.as_bytes();
    let dv1 = dv(&b[..9]);
    let mut com = b[..9].to_vec();
    com.push(dv1);
    let dv2 = dv(&com);
    b[9] == dv1 && b[10] == dv2
}

/// Valida os dígitos verificadores do CNPJ (mod 11), NUMÉRICO ou ALFANUMÉRICO: o valor de cada
/// caractere é o código ASCII menos 48 ('0'->0 … '9'->9, 'A'->17 … 'Z'->42).
pub fn cnpj_valido(valor: &str) -> bool {
    let d = only_doc(valor);
    if d.len() != 14 || todos_iguais(&d) {
        return false;
    }
    let b = d.as_bytes();
    if !b[12..].iter().all(u8::is_ascii_digit) {
        return false;
    }
    let dv = |base: &[u8], pesos: &[u32]| -> u8 {
        let s: u32 = base
            .iter()
            .zip(pesos)
            .map(|(x, p)| (*x as u32 - 48) * p)
            .sum();
        let r = s % 11;
        if r < 2 { b'0' } else { b'0' + (11 - r) as u8 }
    };
    let dv1 = dv(&b[..12], &[5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
    let mut com = b[..12].to_vec();
    com.push(dv1);
    let dv2 = dv(&com, &[6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
    b[12] == dv1 && b[13] == dv2
}

/// Valor de um caractere do CIB na base 32 de Crockford adotada pela Receita Federal (manual DOI,
/// "Regra de formação e cálculo do dígito verificador do código CIB"): I/L valem 1, O vale 0 e U
/// não existe.
fn valor_cib(c: char) -> Option<u32> {
    let c = c.to_ascii_uppercase();
    match c {
        '0'..='9' => c.to_digit(10),
        'O' => Some(0),
        'I' | 'L' => Some(1),
        _ => "ABCDEFGHJKMNPQRSTVWXYZ".find(c).map(|i| 10 + i as u32),
    }
}

const CODIFICACAO_CIB: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// O CIB como a SEFIN o recebe: 8 caracteres maiúsculos, sem a máscara (AAAAAAA-D) e com I, L e
/// O trocados pelos numerais que representam. Texto que não é um CIB volta só aparado.
pub fn cib_normalizado(valor: &str) -> String {
    let limpo: String = valor
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .collect();
    let valores: Option<Vec<u32>> = limpo.chars().map(valor_cib).collect();
    match valores {
        Some(v) if v.len() == 8 => v
            .iter()
            .map(|x| CODIFICACAO_CIB[*x as usize] as char)
            .collect(),
        _ => valor.trim().to_string(),
    }
}

/// Valida o dígito verificador do CIB (Cadastro Imobiliário Brasileiro): sete caracteres + DV.
/// Só números: módulo 11 com pesos 8..2 (resto 0 ou 1 → DV 0). Com letras: soma dos valores com
/// pesos 4, 3, 9, 5, 7, 1, 8, e o DV é o caractere do resto da divisão por 31.
pub fn cib_valido(valor: &str) -> bool {
    let cib = cib_normalizado(valor);
    let v: Vec<u32> = match cib.chars().map(valor_cib).collect::<Option<Vec<u32>>>() {
        Some(v) if v.len() == 8 => v,
        _ => return false,
    };
    let (base, dv) = (&v[..7], v[7]);
    if cib[..7].bytes().all(|b| b.is_ascii_digit()) {
        let soma: u32 = base
            .iter()
            .zip([8, 7, 6, 5, 4, 3, 2])
            .map(|(x, p)| x * p)
            .sum();
        let resto = soma % 11;
        let esperado = if resto < 2 { 0 } else { 11 - resto };
        return dv == esperado;
    }
    let soma: u32 = base
        .iter()
        .zip([4, 3, 9, 5, 7, 1, 8])
        .map(|(x, p)| x * p)
        .sum();
    dv == soma % 31
}

/// True se o CNPJ/CPF tem dígitos verificadores corretos. `tipo_doc` opcional ('CNPJ'/'CPF');
/// vazio decide pelo tamanho (14 = CNPJ, 11 = CPF).
pub fn documento_valido(valor: &str, tipo_doc: &str) -> bool {
    let d = only_doc(valor);
    let tipo = tipo_doc.to_uppercase();
    if tipo == "CNPJ" || (tipo.is_empty() && d.len() == 14) {
        return cnpj_valido(&d);
    }
    if tipo == "CPF" || (tipo.is_empty() && d.len() == 11) {
        return cpf_valido(&d);
    }
    false
}

/// Extrai a data de um ISO datetime/date ('2026-06-05T14:15:07-03:00' -> 2026-06-05).
pub fn parse_iso_date(valor: &str) -> Option<chrono::NaiveDate> {
    let cabeca: String = aparar(valor).chars().take(10).collect();
    chrono::NaiveDate::parse_from_str(&cabeca, "%Y-%m-%d").ok()
}

// ------------------------------------------------------------------------------- //
// Números digitados
// ------------------------------------------------------------------------------- //
/// O número que o texto representa, com vírgula ou ponto (None se não é número).
pub fn decimal(valor: &str) -> Option<f64> {
    float_py(&aparar(valor).replace(',', "."))
}

/// O número que o texto representa, só com ponto decimal (None se não é número).
pub fn float_py(valor: &str) -> Option<f64> {
    let bruto: String = aparar(valor)
        .chars()
        .map(|c| match c {
            // dígitos de largura inteira valem como os comuns
            '\u{ff10}'..='\u{ff19}' => char::from(b'0' + (c as u32 - 0xff10) as u8),
            c => c,
        })
        .collect();
    let bruto = aparar(&bruto);
    if bruto.is_empty() {
        return None;
    }
    // sublinhado só entre dígitos ("1_000")
    let b = bruto.as_bytes();
    let mut limpo = String::with_capacity(bruto.len());
    for (i, c) in bruto.char_indices() {
        if c == '_' {
            let antes = i > 0 && b[i - 1].is_ascii_digit();
            let depois = i + 1 < b.len() && b[i + 1].is_ascii_digit();
            if !(antes && depois) {
                return None;
            }
        } else {
            limpo.push(c);
        }
    }
    limpo.parse::<f64>().ok()
}

pub fn is_decimal(valor: &str) -> bool {
    decimal(valor).is_some()
}

/// `f"{x:.2f}"`.
pub fn duas_casas(v: f64) -> String {
    if v.is_nan() {
        return "nan".into();
    }
    if v.is_infinite() {
        return if v > 0.0 { "inf".into() } else { "-inf".into() };
    }
    format!("{v:.2}")
}

/// Número com duas casas e ponto ("2160,5" -> "2160.50"); vazio fica vazio; o que não é número
/// volta como veio.
pub fn norm_decimal(valor: &str) -> String {
    let bruto = aparar(valor).replace(',', ".");
    if bruto.is_empty() {
        return String::new();
    }
    match decimal(&bruto) {
        Some(v) => duas_casas(v),
        None => bruto,
    }
}

/// 2160.0 -> '2.160,00' (sem símbolo). Zero -> ''.
pub fn fmt_money_br_num(n: f64) -> String {
    if n == 0.0 || n.is_nan() {
        return String::new();
    }
    let fixo = duas_casas(n.abs());
    let (inteiro, centavos) = fixo.split_once('.').unwrap_or((&fixo, "00"));
    let mut com_pontos = String::new();
    for (i, c) in inteiro.chars().enumerate() {
        if i > 0 && (inteiro.len() - i) % 3 == 0 {
            com_pontos.push('.');
        }
        com_pontos.push(c);
    }
    format!("{}{com_pontos},{centavos}", if n < 0.0 { "-" } else { "" })
}

/// '2160.00' -> '2.160,00' (sem símbolo). Vazio/inválido -> ''.
pub fn fmt_money_br(valor: &str) -> String {
    let bruto = aparar(valor).replace(',', ".");
    if bruto.is_empty() {
        return String::new();
    }
    match float_py(&bruto) {
        Some(n) if n == 0.0 => "0,00".to_string(),
        Some(n) if n.is_finite() => fmt_money_br_num(n),
        _ => String::new(),
    }
}
/// Tamanho de arquivo com unidade curta e separador decimal brasileiro.
pub fn tamanho_arquivo(bytes: u64) -> String {
    let unidades = ["B", "KB", "MB", "GB", "TB"];
    let mut valor = bytes as f64;
    let mut i = 0;
    while valor >= 1024.0 && i < unidades.len() - 1 {
        valor /= 1024.0;
        i += 1;
    }
    let numero = if i == 0 {
        format!("{valor:.0}")
    } else {
        format!("{valor:.1}")
    };
    format!("{} {}", numero.replace('.', ","), unidades[i])
}
