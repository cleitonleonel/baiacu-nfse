//! Conversão entre o conteúdo do editor de texto rico (Delta do flutter_quill) e o HTML do
//! e-mail.
//!
//! O corpo do e-mail é guardado e enviado como HTML, mas o editor da tela de Configurações
//! trabalha com Delta: uma lista de operações {"insert": texto, "attributes": {...}}. Este
//! módulo faz as duas pontas:
//!
//!   html_para_delta(html)  — carrega no editor o HTML salvo;
//!   delta_para_html(delta) — gera o HTML do e-mail a partir do que o usuário formatou.
//!
//! Formatos do flutter_quill: bold/italic/underline/strike: true · font: nome da família ·
//! size: número em TEXTO e SEM unidade ("24") · color/background: "#RRGGBB" ou "#AARRGGBB" (alfa
//! PRIMEIRO, ao contrário do CSS) · align/list/indent/header: atributos de BLOCO, gravados no
//! "\n" que fecha a linha.
//!
//! Regras do HTML gerado:
//!   • cada linha vira <p style="margin:0;font-family:…;font-size:16px">…</p> — a fonte/tamanho
//!     PADRÃO vão inline em cada bloco: é o que vale em qualquer programa de e-mail;
//!   • linha vazia vira <p style="…"><br></p>;
//!   • estilos sempre inline; fonte/tamanho iguais ao padrão não viram atributo no Delta;
//!   • sequências de espaços viram &nbsp; alternado com espaço;
//!   • uma {variável} NUNCA sai partida por formatação parcial: o token inteiro recebe o estilo
//!     do 1º caractere.
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::html_preview::{self, Estilo};
use crate::jsonpy;

const NBSP: char = '\u{a0}';
const ATRIBUTOS_DE_BLOCO: [&str; 4] = ["align", "list", "indent", "header"];

/// Fonte e tamanho do texto SEM formatação própria. Os três lados precisam bater: o seletor da
/// barra do editor mostra estes valores, o editor desenha o texto com eles e o e-mail enviado os
/// aplica (`html_com_padrao`).
pub const FONTE_PADRAO: &str = "Arial";
pub const TAMANHO_PADRAO: f64 = 16.0;

fn rx(guarda: &'static OnceLock<Regex>, padrao: &str) -> &'static Regex {
    guarda.get_or_init(|| Regex::new(padrao).expect("expressão regular"))
}

/// Nomes CSS mais comuns -> hex.
fn cor_nomeada(nome: &str) -> Option<&'static str> {
    Some(match nome {
        "black" => "#000000",
        "white" => "#ffffff",
        "red" => "#ff0000",
        "green" => "#008000",
        "blue" => "#0000ff",
        "yellow" => "#ffff00",
        "orange" => "#ffa500",
        "purple" => "#800080",
        "gray" | "grey" => "#808080",
        "silver" => "#c0c0c0",
        "maroon" => "#800000",
        "navy" => "#000080",
        "teal" => "#008080",
        "olive" => "#808000",
        "lime" => "#00ff00",
        "aqua" | "cyan" => "#00ffff",
        "fuchsia" | "magenta" => "#ff00ff",
        _ => return None,
    })
}

/// Pilhas de fontes seguras para e-mail. O editor guarda só o nome da família.
fn pilha_conhecida(nome: &str) -> Option<&'static str> {
    Some(match nome {
        "arial" => "Arial, Helvetica, sans-serif",
        "verdana" => "Verdana, Geneva, sans-serif",
        "tahoma" => "Tahoma, Geneva, sans-serif",
        "georgia" => "Georgia, serif",
        "times new roman" => "'Times New Roman', Times, serif",
        "courier new" => "'Courier New', Courier, monospace",
        "trebuchet ms" => "'Trebuchet MS', Helvetica, sans-serif",
        "segoe ui" => "'Segoe UI', Arial, sans-serif",
        _ => return None,
    })
}

fn aparar(s: &str) -> &str {
    crate::texto::aparar(s)
}

// --------------------------------------------------------------------------------------- //
// Normalização de valores
// --------------------------------------------------------------------------------------- //
/// Cor com transparência -> cor SÓLIDA equivalente sobre fundo branco (alfa não é confiável em
/// cliente de e-mail). Totalmente transparente = sem cor.
fn sobre_branco(r: i64, g: i64, b: i64, alfa: f64) -> Option<String> {
    if alfa <= 0.0 {
        return None;
    }
    let mistura = |c: i64| {
        if alfa < 1.0 {
            (alfa * c as f64 + (1.0 - alfa) * 255.0).round_ties_even() as i64
        } else {
            c
        }
    };
    Some(format!(
        "#{:02x}{:02x}{:02x}",
        mistura(r),
        mistura(g),
        mistura(b)
    ))
}

/// Qualquer cor aceitável -> '#rrggbb' minúsculo (ou None se não der para entender).
fn cor_normalizada(valor: &str) -> Option<String> {
    static HEX6: OnceLock<Regex> = OnceLock::new();
    static HEX3: OnceLock<Regex> = OnceLock::new();
    static RGB: OnceLock<Regex> = OnceLock::new();
    let v = aparar(valor).to_lowercase().replace("!important", "");
    let v = aparar(&v);
    if v.is_empty() || matches!(v, "inherit" | "transparent" | "initial" | "none") {
        return None;
    }
    if let Some(c) = cor_nomeada(v) {
        return Some(c.to_string());
    }
    if let Some(m) = rx(&HEX6, r"^#([0-9a-fA-F]{6})$").captures(v) {
        return Some(format!("#{}", &m[1]));
    }
    if let Some(m) = rx(&HEX3, r"^#([0-9a-fA-F])([0-9a-fA-F])([0-9a-fA-F])$").captures(v) {
        return Some(format!("#{0}{0}{1}{1}{2}{2}", &m[1], &m[2], &m[3]));
    }
    if let Some(m) = rx(
        &RGB,
        r"(?i)^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([\d.]+)\s*)?\)$",
    )
    .captures(v)
    {
        let n = |i: usize| m[i].parse::<i64>().unwrap_or(0).clamp(0, 255);
        let alfa = match m.get(4) {
            None => 1.0,
            Some(a) => a.as_str().parse::<f64>().ok()?.clamp(0.0, 1.0),
        };
        return sobre_branco(n(1), n(2), n(3), alfa);
    }
    None
}

/// Cor gravada pelo editor ('#RRGGBB' ou '#AARRGGBB', alfa na FRENTE) -> '#rrggbb'.
fn cor_do_delta(valor: Option<&Value>) -> Option<String> {
    static HEX8: OnceLock<Regex> = OnceLock::new();
    let s = valor?.as_str()?;
    if let Some(m) = rx(&HEX8, r"^#([0-9a-fA-F]{2})([0-9a-fA-F]{6})$").captures(aparar(s)) {
        let n = |ini: usize| i64::from_str_radix(&m[2][ini..ini + 2], 16).unwrap_or(0);
        let alfa = i64::from_str_radix(&m[1], 16).unwrap_or(255) as f64 / 255.0;
        return sobre_branco(n(0), n(2), n(4), alfa);
    }
    cor_normalizada(s)
}

/// Número no formato "%g" (6 algarismos significativos, sem zeros à direita).
fn fmt_g(x: f64) -> String {
    if x == 0.0 {
        return "0".into();
    }
    let cientifico = format!("{x:.5e}");
    let (mantissa, expoente) = cientifico.split_once('e').unwrap_or((&cientifico, "0"));
    let e: i32 = expoente.parse().unwrap_or(0);
    let sem_zeros = |s: &str| {
        if s.contains('.') {
            s.trim_end_matches('0').trim_end_matches('.').to_string()
        } else {
            s.to_string()
        }
    };
    if !(-4..6).contains(&e) {
        return format!(
            "{}e{}{:02}",
            sem_zeros(mantissa),
            if e < 0 { '-' } else { '+' },
            e.abs()
        );
    }
    sem_zeros(&format!("{:.*}", (5 - e).max(0) as usize, x))
}

/// px -> texto numérico sem unidade, como o flutter_quill exige ("24", "10.5").
fn tamanho_delta(px: f64) -> String {
    if px.fract() == 0.0 && px.is_finite() {
        format!("{}", px as i64)
    } else {
        fmt_g(px)
    }
}

fn tamanho_px(valor: Option<&Value>) -> Option<f64> {
    let positivo = |f: f64| if f > 0.0 { Some(f) } else { None };
    match valor? {
        Value::Number(n) => positivo(n.as_f64()?),
        Value::String(s) => {
            let v = aparar(s).to_lowercase();
            match v.as_str() {
                "small" => Some(10.0),
                "large" => Some(18.0),
                "huge" => Some(22.0),
                _ => positivo(crate::texto::float_py(v.strip_suffix("px").unwrap_or(&v))?),
            }
        }
        _ => None,
    }
}

/// Primeira família de uma pilha CSS, sem aspas ("'Segoe UI', Arial" -> "Segoe UI").
fn familia(nome: &str) -> String {
    let primeira: String = nome
        .split(',')
        .next()
        .unwrap_or("")
        .chars()
        .filter(|c| !matches!(c, '"' | '\'' | '<' | '>' | ';'))
        .collect();
    aparar(&primeira).to_string()
}

fn pilha_fonte(nome: &str) -> String {
    let n = familia(nome);
    if n.is_empty() {
        return String::new();
    }
    if let Some(p) = pilha_conhecida(&n.to_lowercase()) {
        return p.to_string();
    }
    if n.contains(' ') { format!("'{n}'") } else { n }
}

fn duas_casas(x: f64) -> f64 {
    format!("{x:.2}").parse().unwrap_or(x)
}

// --------------------------------------------------------------------------------------- //
// HTML -> Delta
// --------------------------------------------------------------------------------------- //
fn atributos_do_estilo(e: &Estilo) -> Map<String, Value> {
    let mut a = Map::new();
    if e.negrito {
        a.insert("bold".into(), json!(true));
    }
    if e.italico {
        a.insert("italic".into(), json!(true));
    }
    if e.sublinhado {
        a.insert("underline".into(), json!(true));
    }
    // Fonte/tamanho iguais ao padrão NÃO viram atributo: o texto já sai no padrão, e é assim que
    // o editor grava (escolher o padrão no seletor tira o atributo).
    let f = e
        .fonte
        .as_deref()
        .filter(|f| !f.is_empty())
        .map(familia)
        .unwrap_or_default();
    if !f.is_empty() && f.to_lowercase() != FONTE_PADRAO.to_lowercase() {
        a.insert("font".into(), json!(f));
    }
    if let Some(t) = e.tamanho.filter(|t| *t != 0.0) {
        if duas_casas(t) != TAMANHO_PADRAO {
            a.insert("size".into(), json!(tamanho_delta(duas_casas(t))));
        }
    }
    if let Some(c) = e.cor.as_deref().and_then(cor_normalizada) {
        a.insert("color".into(), json!(c));
    }
    if let Some(c) = e.fundo.as_deref().and_then(cor_normalizada) {
        a.insert("background".into(), json!(c));
    }
    a
}

/// Acrescenta um insert juntando com o anterior quando os atributos são iguais (a mesma
/// normalização que o próprio Quill faz — mantém o Delta comparável).
fn anexar(ops: &mut Vec<Value>, texto: &str, atributos: Option<&Map<String, Value>>) {
    if texto.is_empty() {
        return;
    }
    let atributos = atributos.filter(|a| !a.is_empty());
    if let Some(ultimo) = ops.last_mut() {
        let dele = ultimo
            .get("attributes")
            .and_then(Value::as_object)
            .filter(|a| !a.is_empty());
        if dele == atributos {
            if let Some(Value::String(s)) = ultimo.get_mut("insert") {
                s.push_str(texto);
                return;
            }
        }
    }
    let mut op = Map::new();
    op.insert("insert".into(), json!(texto));
    if let Some(a) = atributos {
        op.insert("attributes".into(), Value::Object(a.clone()));
    }
    ops.push(Value::Object(op));
}

/// HTML do e-mail -> lista de operações do Delta (sempre terminando em "\n").
pub fn html_para_delta(html: &str) -> Vec<Value> {
    let mut ops: Vec<Value> = Vec::new();
    for t in html_preview::html_para_trechos(html, None, true) {
        if t.texto.is_empty() {
            continue;
        }
        let atributos = atributos_do_estilo(&t.estilo);
        let texto = t.texto.replace(NBSP, " ");
        let partes: Vec<&str> = texto.split('\n').collect();
        for (i, parte) in partes.iter().enumerate() {
            anexar(&mut ops, parte, Some(&atributos));
            if i < partes.len() - 1 {
                anexar(&mut ops, "\n", None);
            }
        }
    }
    let termina_em_quebra = ops
        .last()
        .and_then(|o| o.get("insert"))
        .and_then(Value::as_str)
        .is_some_and(|s| s.ends_with('\n'));
    if !termina_em_quebra {
        anexar(&mut ops, "\n", None);
    }
    ops
}

// --------------------------------------------------------------------------------------- //
// Delta -> HTML
// --------------------------------------------------------------------------------------- //
/// Aceita a lista de ops, {"ops": [...]} ou o JSON de qualquer um dos dois.
pub fn ler_delta(delta: &Value) -> Vec<Value> {
    let lido;
    let delta = match delta {
        Value::String(s) => {
            lido = if aparar(s).is_empty() {
                json!([])
            } else {
                serde_json::from_str::<Value>(s).unwrap_or(Value::Null)
            };
            &lido
        }
        outro => outro,
    };
    let lista = match delta {
        Value::Object(m) => m
            .get("ops")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        Value::Array(a) => a.clone(),
        _ => Vec::new(),
    };
    lista.into_iter().filter(Value::is_object).collect()
}

type Pedaco = (String, Map<String, Value>);

/// Ops -> [(trechos da linha, atributos de bloco)]. O "\n" que fecha a linha carrega os
/// atributos de bloco; atributos inline presos a ele são descartados.
fn linhas(ops: &[Value]) -> Vec<(Vec<Pedaco>, Map<String, Value>)> {
    let mut out = Vec::new();
    let mut atual: Vec<Pedaco> = Vec::new();
    for op in ops {
        let Some(ins) = op.get("insert").and_then(Value::as_str) else {
            continue;
        }; // embeds não entram no e-mail
        let vazio = Map::new();
        let attrs = op
            .get("attributes")
            .and_then(Value::as_object)
            .unwrap_or(&vazio);
        let partes: Vec<&str> = ins.split('\n').collect();
        for (i, parte) in partes.iter().enumerate() {
            if !parte.is_empty() {
                let inline: Map<String, Value> = attrs
                    .iter()
                    .filter(|(k, _)| !ATRIBUTOS_DE_BLOCO.contains(&k.as_str()))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                atual.push(((*parte).to_string(), inline));
            }
            if i < partes.len() - 1 {
                let bloco: Map<String, Value> = attrs
                    .iter()
                    .filter(|(k, _)| ATRIBUTOS_DE_BLOCO.contains(&k.as_str()))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                out.push((std::mem::take(&mut atual), bloco));
            }
        }
    }
    if !atual.is_empty() {
        out.push((atual, Map::new()));
    }
    out
}

fn unificar_variaveis(trechos: Vec<Pedaco>) -> Vec<Pedaco> {
    let texto: Vec<char> = trechos.iter().flat_map(|(t, _)| t.chars()).collect();
    if !texto.contains(&'{') {
        return trechos;
    }
    let mut por_char: Vec<&Map<String, Value>> = Vec::with_capacity(texto.len());
    for (t, a) in &trechos {
        por_char.extend(std::iter::repeat_n(a, t.chars().count()));
    }
    let mut mudou = false;
    for (ini, fim, _) in html_preview::variaveis(&texto) {
        let a0 = por_char[ini];
        for item in por_char.iter_mut().take(fim).skip(ini + 1) {
            if *item != a0 {
                *item = a0;
                mudou = true;
            }
        }
    }
    if !mudou {
        return trechos;
    }
    let mut saida: Vec<Pedaco> = Vec::new();
    for (ch, a) in texto.iter().zip(&por_char) {
        match saida.last_mut() {
            Some((t, antes)) if antes == *a => t.push(*ch),
            _ => saida.push((ch.to_string(), (*a).clone())),
        }
    }
    saida
}

/// Espaço único entre palavras fica espaço; sequências, início e fim de linha viram NBSP
/// alternado — no editor todos os espaços aparecem, no HTML eles colapsariam.
fn tratar_espacos(trechos: Vec<Pedaco>) -> Vec<Pedaco> {
    let limpo = |t: &str| t.replace(NBSP, " ").replace('\t', "    ");
    let texto: String = trechos.iter().map(|(t, _)| limpo(t)).collect();
    if !texto.contains("  ") && !texto.starts_with(' ') && !texto.ends_with(' ') {
        return trechos.into_iter().map(|(t, a)| (limpo(&t), a)).collect();
    }
    let mut chars: Vec<char> = texto.chars().collect();
    let n = chars.len();
    let mut i = 0;
    while i < n {
        if chars[i] != ' ' {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < n && chars[j] == ' ' {
            j += 1;
        }
        if !(j - i == 1 && i > 0 && j < n) {
            for (k, c) in chars.iter_mut().enumerate().take(j).skip(i) {
                *c = if (k - i) % 2 == 0 { NBSP } else { ' ' };
            }
            if j == n {
                chars[j - 1] = NBSP;
            }
        }
        i = j;
    }
    let mut saida = Vec::new();
    let mut pos = 0;
    for (t, a) in trechos {
        let tam = t.replace('\t', "    ").chars().count();
        saida.push((
            chars[pos.min(n)..(pos + tam).min(n)]
                .iter()
                .collect::<String>(),
            a,
        ));
        pos += tam;
    }
    saida
}

fn escapar(texto: &str) -> String {
    texto
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace(NBSP, "&nbsp;")
}

fn escapar_attr(valor: &str) -> String {
    valor
        .replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
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

fn html_trecho(texto: &str, a: &Map<String, Value>) -> String {
    let mut s = escapar(texto);
    let mut estilos: Vec<String> = Vec::new();
    if let Some(f) = a
        .get("font")
        .and_then(Value::as_str)
        .filter(|f| !aparar(f).is_empty())
    {
        estilos.push(format!("font-family:{}", pilha_fonte(f)));
    }
    if let Some(px) = tamanho_px(a.get("size")) {
        estilos.push(format!("font-size:{}px", tamanho_delta(px)));
    }
    if let Some(c) = cor_do_delta(a.get("color")) {
        estilos.push(format!("color:{c}"));
    }
    if let Some(c) = cor_do_delta(a.get("background")) {
        estilos.push(format!("background-color:{c}"));
    }
    if !estilos.is_empty() {
        s = format!(
            "<span style=\"{}\">{s}</span>",
            escapar_attr(&estilos.join(";"))
        );
    }
    if verdadeiro(a.get("strike")) {
        s = format!("<s>{s}</s>");
    }
    if verdadeiro(a.get("underline")) {
        s = format!("<u>{s}</u>");
    }
    if verdadeiro(a.get("italic")) {
        s = format!("<em>{s}</em>");
    }
    if verdadeiro(a.get("bold")) {
        s = format!("<strong>{s}</strong>");
    }
    if let Some(l) = a
        .get("link")
        .and_then(Value::as_str)
        .filter(|l| !aparar(l).is_empty())
    {
        s = format!("<a href=\"{}\">{s}</a>", escapar_attr(aparar(l)));
    }
    s
}

fn estilo_padrao() -> String {
    format!(
        "font-family:{};font-size:{}px",
        pilha_fonte(FONTE_PADRAO),
        TAMANHO_PADRAO as i64
    )
}

/// Padrão INLINE em cada bloco: o Outlook para Windows nem sempre herda a fonte de um elemento
/// pai, e estilo inline vale em qualquer programa de e-mail.
fn estilo_bloco(bloco: &Map<String, Value>) -> String {
    let mut estilo = format!("margin:0;{}", estilo_padrao());
    if let Some(a @ ("center" | "right" | "justify")) = bloco.get("align").and_then(Value::as_str) {
        estilo.push_str(&format!(";text-align:{a}"));
    }
    estilo
}

/// Corpo do e-mail pronto para enviar, com a fonte/tamanho padrão (Arial 16) valendo para o texto
/// sem formatação própria. Documento completo (com <html> ou <body> próprios) vai como está.
pub fn html_com_padrao(corpo: &str) -> String {
    static DOC: OnceLock<Regex> = OnceLock::new();
    if rx(&DOC, r"(?i)<(?:html|body)\b").is_match(corpo) {
        return corpo.to_string();
    }
    format!("<div style=\"{}\">{corpo}</div>", estilo_padrao())
}

/// Delta do editor -> HTML pronto para o corpo do e-mail.
pub fn delta_para_html(delta: &Value) -> String {
    let mut blocos: Vec<String> = Vec::new();
    let mut lista_aberta: Option<&'static str> = None;
    for (trechos, bloco) in linhas(&ler_delta(delta)) {
        let trechos = tratar_espacos(unificar_variaveis(trechos));
        let mut conteudo: String = trechos
            .iter()
            .filter(|(t, _)| !t.is_empty())
            .map(|(t, a)| html_trecho(t, a))
            .collect();
        if conteudo.is_empty() {
            conteudo = "<br>".into();
        }
        let tag_lista = match bloco.get("list").and_then(Value::as_str) {
            Some("bullet") => Some("ul"),
            Some("ordered") => Some("ol"),
            _ => None,
        };
        if tag_lista != lista_aberta {
            if let Some(aberta) = lista_aberta {
                blocos.push(format!("</{aberta}>"));
            }
            if let Some(nova) = tag_lista {
                blocos.push(format!("<{nova} style=\"margin-top:0;margin-bottom:0\">"));
            }
            lista_aberta = tag_lista;
        }
        if tag_lista.is_some() {
            let estilo = estilo_bloco(&bloco).replace("margin:0", "");
            let estilo = estilo.trim_start_matches(';');
            let atributo = if estilo.is_empty() {
                String::new()
            } else {
                format!(" style=\"{estilo}\"")
            };
            blocos.push(format!("<li{atributo}>{conteudo}</li>"));
        } else {
            blocos.push(format!(
                "<p style=\"{}\">{conteudo}</p>",
                estilo_bloco(&bloco)
            ));
        }
    }
    if let Some(aberta) = lista_aberta {
        blocos.push(format!("</{aberta}>"));
    }
    // Linhas vazias no FIM não carregam nada e só crescem a cada salvamento.
    let vazia = format!("<p style=\"{}\"><br></p>", estilo_bloco(&Map::new()));
    while blocos.last() == Some(&vazia) {
        blocos.pop();
    }
    blocos.concat()
}

pub fn delta_json(ops: &[Value]) -> String {
    jsonpy::dumps(
        &Value::Array(ops.to_vec()),
        jsonpy::Formato {
            ordenar: false,
            recuo: None,
            compacto: true,
            so_ascii: false,
        },
    )
}

/// Elementos do HTML salvo que o editor visual não representa — para avisar o usuário ANTES de
/// uma edição reescrever a mensagem sem eles.
pub fn elementos_nao_suportados(html: &str) -> Vec<&'static str> {
    static RXS: OnceLock<Vec<(&'static str, Regex)>> = OnceLock::new();
    let lista = RXS.get_or_init(|| {
        [
            ("links", r"(?i)<a\b"),
            ("listas", r"(?i)<(?:ul|ol|li)\b"),
            ("imagens", r"(?i)<img\b"),
            ("tabelas", r"(?i)<table\b"),
            ("títulos", r"(?i)<h[1-6]\b"),
            ("texto tachado", r"(?i)<(?:s|strike|del)\b|line-through"),
            (
                "alinhamento",
                r"(?i)text-align\s*:\s*(?:center|right|justify)",
            ),
        ]
        .into_iter()
        .map(|(nome, padrao)| (nome, Regex::new(padrao).expect("expressão regular")))
        .collect()
    });
    lista
        .iter()
        .filter(|(_, r)| r.is_match(html))
        .map(|(nome, _)| *nome)
        .collect()
}

/// Forma canônica para comparar documentos independentemente de quem escreveu o JSON: junta
/// inserts vizinhos de mesmos atributos e normaliza tamanho ("12" x 12.0), cor e fonte.
fn normalizar_ops(ops: &[Value]) -> Vec<(String, Vec<(String, Value)>)> {
    let mut saida: Vec<(String, Vec<(String, Value)>)> = Vec::new();
    for op in ops {
        let Some(ins) = op.get("insert").and_then(Value::as_str) else {
            continue;
        };
        let mut norm: Vec<(String, Value)> = Vec::new();
        for (k, v) in op
            .get("attributes")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
        {
            if v.is_null() {
                continue;
            }
            let v = match k.as_str() {
                "size" => tamanho_px(Some(v)).map(|px| json!(tamanho_delta(px))),
                "color" | "background" => cor_do_delta(Some(v)).map(|c| json!(c)),
                "font" => Some(familia(&match v {
                    Value::String(s) => s.clone(),
                    outro => outro.to_string(),
                }))
                .filter(|f| !f.is_empty())
                .map(|f| json!(f)),
                _ => Some(v.clone()),
            };
            if let Some(v) = v {
                norm.push((k.clone(), v));
            }
        }
        norm.sort_by(|a, b| a.0.cmp(&b.0));
        match saida.last_mut() {
            Some((texto, chave)) if *chave == norm => texto.push_str(ins),
            _ => saida.push((ins.to_string(), norm)),
        }
    }
    saida
}

/// Os dois Deltas (lista, objeto ou JSON) têm o mesmo conteúdo e formatação?
pub fn mesmo_documento(a: &Value, b: &Value) -> bool {
    normalizar_ops(&ler_delta(a)) == normalizar_ops(&ler_delta(b))
}
