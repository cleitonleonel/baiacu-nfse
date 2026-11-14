//! Converte o HTML do corpo do e-mail em TRECHOS ESTILIZADOS — base da carga do HTML salvo no
//! editor de texto rico (`email_delta`).
//!
//! Escopo do HTML suportado — o mesmo que um cliente de e-mail comum respeita e que a barra de
//! formatação gera: <b>/<strong>, <i>/<em>, <u>, <br>, <p>, <div>, <span style="..."> e <font
//! color size face>. Tag desconhecida é IGNORADA (o texto dentro dela continua aparecendo), que
//! é como os clientes de e-mail se comportam.
//!
//! Cada trecho guarda a faixa que ocupa no HTML de origem (em caracteres), anotada pelo próprio
//! leitor — nunca por busca de texto.
use std::collections::HashMap;

/// Estilo acumulado de um trecho. Campos em None = herda o padrão.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Estilo {
    pub negrito: bool,
    pub italico: bool,
    pub sublinhado: bool,
    pub cor: Option<String>,
    pub fundo: Option<String>,
    pub tamanho: Option<f64>,
    pub fonte: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Trecho {
    pub texto: String,
    pub estilo: Estilo,
    /// Faixa que este trecho ocupa no HTML de ORIGEM. -1 = sem âncora.
    pub ini_fonte: i64,
    pub fim_fonte: i64,
}

/// Elementos de BLOCO: começam e terminam em linha nova no cliente de e-mail.
const BLOCOS: [&str; 21] = [
    "p",
    "div",
    "li",
    "ul",
    "ol",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "blockquote",
    "table",
    "tr",
    "td",
    "th",
    "section",
    "article",
    "header",
    "footer",
    "pre",
];

/// Tamanho padrão dos títulos nos navegadores/clientes (px).
fn tamanho_do_titulo(tag: &str) -> Option<f64> {
    Some(match tag {
        "h1" => 32.0,
        "h2" => 24.0,
        "h3" => 18.72,
        "h4" => 16.0,
        "h5" => 13.28,
        "h6" => 10.72,
        _ => return None,
    })
}

/// Tamanhos do atributo `size` do <font> (HTML 3.2) em pixels aproximados.
fn tamanho_legado(size: &str) -> Option<f64> {
    Some(match size {
        "1" => 10.0,
        "2" => 13.0,
        "3" => 16.0,
        "4" => 18.0,
        "5" => 24.0,
        "6" => 32.0,
        "7" => 48.0,
        _ => return None,
    })
}

fn branco(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

fn aparar(s: &str) -> &str {
    s.trim_matches(branco)
}

/// Aplica um atributo style="..." sobre o estilo herdado.
fn aplicar_css(css: &str, base: &Estilo) -> Estilo {
    let mut novo = base.clone();
    for parte in css.split(';') {
        let Some((prop, valor)) = parte.split_once(':') else {
            continue;
        };
        let (prop, valor) = (aparar(prop).to_lowercase(), aparar(valor));
        if valor.is_empty() {
            continue;
        }
        match prop.as_str() {
            "color" => novo.cor = Some(valor.to_string()),
            "background-color" | "background" => {
                novo.fundo = valor
                    .split(branco)
                    .find(|p| !p.is_empty())
                    .map(str::to_string)
            }
            "font-weight" => {
                let numero = !valor.is_empty() && valor.chars().all(crate::texto::digito);
                novo.negrito = matches!(valor, "bold" | "bolder")
                    || (numero && valor.parse::<u64>().is_ok_and(|n| n >= 600));
            }
            "font-style" => novo.italico = valor == "italic",
            "text-decoration" => novo.sublinhado = valor.contains("underline"),
            "font-family" => {
                let primeira = aparar(valor.split(',').next().unwrap_or(""));
                novo.fonte = Some(primeira.trim_matches(|c| c == '\'' || c == '"').to_string());
            }
            "font-size" => {
                let num: String = valor
                    .chars()
                    .filter(|c| c.is_ascii_digit() || *c == '.')
                    .collect();
                if !num.is_empty() {
                    if let Ok(mut px) = num.parse::<f64>() {
                        if valor.ends_with("pt") {
                            px *= 4.0 / 3.0; // pt -> px
                        } else if valor.ends_with("em") {
                            px *= 16.0;
                        }
                        novo.tamanho = Some(px);
                    }
                }
            }
            _ => {}
        }
    }
    novo
}

type Atributos = HashMap<String, String>;

/// Contribuição de UMA tag (com seus atributos) sobre o estilo herdado.
fn aplicar_tag(mut e: Estilo, tag: &str, a: &Atributos) -> Estilo {
    let de = |nome: &str| a.get(nome).map(String::as_str).filter(|v| !v.is_empty());
    match tag {
        "b" | "strong" => e.negrito = true,
        "i" | "em" => e.italico = true,
        "u" => e.sublinhado = true,
        "font" => {
            if let Some(c) = de("color") {
                e.cor = Some(c.to_string());
            }
            if let Some(f) = de("face") {
                e.fonte = Some(aparar(f.split(',').next().unwrap_or("")).to_string());
            }
            if let Some(t) = de("size").and_then(tamanho_legado) {
                e.tamanho = Some(t);
            }
        }
        _ => {
            if let Some(t) = tamanho_do_titulo(tag) {
                e.negrito = true;
                e.tamanho = Some(t);
            }
        }
    }
    match de("style") {
        Some(css) => aplicar_css(css, &e),
        None => e,
    }
}

fn nome_de_variavel(s: &str) -> bool {
    let mut c = s.chars();
    matches!(c.next(), Some(p) if p.is_ascii_lowercase() || p == '_')
        && c.all(|x| x.is_ascii_lowercase() || x.is_ascii_digit() || x == '_')
}

/// As {variáveis} de um texto: (início, fim, nome), em caracteres.
pub fn variaveis(texto: &[char]) -> Vec<(usize, usize, String)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < texto.len() {
        if texto[i] == '{' {
            if let Some(d) = texto[i + 1..].iter().position(|c| *c == '}') {
                let nome: String = texto[i + 1..i + 1 + d].iter().collect();
                if nome_de_variavel(&nome) {
                    out.push((i, i + d + 2, nome));
                    i += d + 2;
                    continue;
                }
            }
        }
        i += 1;
    }
    out
}

/// Quebra o texto em pedaços (trecho, nome da variável ou vazio), preservando a ordem e o
/// conteúdo. Sem `valores`, devolve o texto inteiro como um pedaço só.
fn partir_variaveis(
    texto: &str,
    valores: Option<&HashMap<String, String>>,
) -> Vec<(String, String)> {
    let Some(valores) = valores.filter(|v| !v.is_empty() && !texto.is_empty()) else {
        return vec![(texto.to_string(), String::new())];
    };
    let chars: Vec<char> = texto.chars().collect();
    let mut saida = Vec::new();
    let mut pos = 0;
    for (ini, fim, nome) in variaveis(&chars) {
        if !valores.contains_key(&nome) {
            continue;
        }
        if ini > pos {
            saida.push((chars[pos..ini].iter().collect(), String::new()));
        }
        saida.push((chars[ini..fim].iter().collect(), nome));
        pos = fim;
    }
    if pos < chars.len() {
        saida.push((chars[pos..].iter().collect(), String::new()));
    }
    if saida.is_empty() {
        vec![(texto.to_string(), String::new())]
    } else {
        saida
    }
}

/// `&nome;` / `&#N;` -> o caractere (ou o próprio texto, se não é uma referência conhecida).
pub fn desescapar(texto: &str) -> String {
    html_escape::decode_html_entities(texto).into_owned()
}

// ------------------------------------------------------------------------------------------- //
// Leitor de HTML tolerante (o comportamento do leitor que o programa sempre usou)
// ------------------------------------------------------------------------------------------- //
enum Marca {
    Dado {
        ini: usize,
        texto: String,
    },
    Abre {
        ini: usize,
        fim: usize,
        tag: String,
        atributos: Atributos,
        fecha_sozinha: bool,
    },
    Fecha {
        ini: usize,
        tag: String,
    },
    Entidade {
        ini: usize,
        nome: String,
    },
    Caractere {
        ini: usize,
        nome: String,
    },
}

fn espaco_html(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r' | '\u{0c}' | '\u{0b}') || branco(c)
}

/// Fim (exclusivo) da tag de abertura que começa em `i`, respeitando aspas. None = não fecha.
fn fim_da_abertura(s: &[char], i: usize) -> Option<usize> {
    let mut k = i + 1;
    let mut aspa: Option<char> = None;
    while k < s.len() {
        let c = s[k];
        match aspa {
            Some(a) if c == a => aspa = None,
            Some(_) => {}
            None if c == '>' => return Some(k + 1),
            // só abre aspas logo depois de um '=' (com espaços), como valor de atributo
            None if (c == '"' || c == '\'')
                && s[i..k].iter().rev().find(|x| !espaco_html(**x)) == Some(&'=') =>
            {
                aspa = Some(c)
            }
            None => {}
        }
        k += 1;
    }
    None
}

/// Nome e atributos de uma tag de abertura (`s` = da '<' até o '>' inclusive).
fn ler_abertura(s: &[char]) -> (String, Atributos, bool) {
    let mut k = 1;
    while k < s.len() && !matches!(s[k], '\t' | '\n' | '\r' | '\u{0c}' | ' ' | '/' | '>' | '\0') {
        k += 1;
    }
    let tag: String = s[1..k].iter().collect::<String>().to_lowercase();
    let fim = s.len().saturating_sub(1); // posição do '>'
    let fecha_sozinha = fim >= 1 && s[fim - 1] == '/';
    let mut atributos = Atributos::new();
    let mut ordem: Vec<String> = Vec::new();
    loop {
        while k < fim && (espaco_html(s[k]) || s[k] == '/') {
            k += 1;
        }
        if k >= fim {
            break;
        }
        // nome: até espaço, '/', '=' ou '>'
        let ini = k;
        k += 1;
        while k < fim && !espaco_html(s[k]) && !matches!(s[k], '/' | '=' | '>') {
            k += 1;
        }
        let nome: String = s[ini..k].iter().collect::<String>().to_lowercase();
        let mut j = k;
        while j < fim && espaco_html(s[j]) {
            j += 1;
        }
        let mut valor = String::new();
        if j < fim && s[j] == '=' {
            while j < fim && s[j] == '=' {
                j += 1;
            }
            while j < fim && espaco_html(s[j]) {
                j += 1;
            }
            if j < fim && (s[j] == '"' || s[j] == '\'') {
                let aspa = s[j];
                let ini_v = j + 1;
                let mut f = ini_v;
                while f < fim && s[f] != aspa {
                    f += 1;
                }
                valor = s[ini_v..f].iter().collect();
                j = (f + 1).min(fim);
            } else {
                let ini_v = j;
                while j < fim && !espaco_html(s[j]) && s[j] != '>' {
                    j += 1;
                }
                valor = s[ini_v..j].iter().collect();
            }
            valor = desescapar(&valor);
            k = j;
        }
        if !ordem.contains(&nome) {
            ordem.push(nome.clone());
        }
        atributos.insert(nome, valor);
    }
    (tag, atributos, fecha_sozinha)
}

fn ler_marcas(fonte: &[char]) -> Vec<Marca> {
    let mut out = Vec::new();
    let n = fonte.len();
    let mut i = 0;
    let mut cru: Option<String> = None; // dentro de <script>/<style>: tudo é texto até fechar
    let dado = |out: &mut Vec<Marca>, ini: usize, fim: usize| {
        if fim > ini {
            out.push(Marca::Dado {
                ini,
                texto: fonte[ini..fim].iter().collect(),
            });
        }
    };
    while i < n {
        if let Some(tag) = &cru {
            // procura </tag
            let alvo: Vec<char> = format!("</{tag}").chars().collect();
            let mut j = i;
            let mut achou = None;
            while j + alvo.len() <= n {
                if fonte[j..j + alvo.len()]
                    .iter()
                    .zip(&alvo)
                    .all(|(a, b)| a.to_ascii_lowercase() == *b)
                {
                    achou = Some(j);
                    break;
                }
                j += 1;
            }
            match achou {
                Some(j) => {
                    dado(&mut out, i, j);
                    i = j;
                    cru = None;
                }
                None => {
                    dado(&mut out, i, n);
                    break;
                }
            }
            continue;
        }
        // texto até o próximo '<' ou '&'
        let j = fonte[i..]
            .iter()
            .position(|c| *c == '<' || *c == '&')
            .map(|d| i + d)
            .unwrap_or(n);
        dado(&mut out, i, j);
        i = j;
        if i >= n {
            break;
        }
        if fonte[i] == '<' {
            let prox = fonte.get(i + 1).copied();
            if prox.is_some_and(|c| c.is_ascii_alphabetic()) {
                match fim_da_abertura(fonte, i) {
                    Some(fim) => {
                        let (tag, atributos, fecha_sozinha) = ler_abertura(&fonte[i..fim]);
                        if !fecha_sozinha && (tag == "script" || tag == "style") {
                            cru = Some(tag.clone());
                        }
                        out.push(Marca::Abre {
                            ini: i,
                            fim,
                            tag,
                            atributos,
                            fecha_sozinha,
                        });
                        i = fim;
                    }
                    None => {
                        // HTMLParser.close() entrega o '<' e o nome incompleto em
                        // chamadas separadas; as âncoras do editor preservam essa fronteira.
                        dado(&mut out, i, i + 1);
                        i += 1;
                    }
                }
            } else if prox == Some('/') {
                match fonte[i..].iter().position(|c| *c == '>') {
                    Some(d) => {
                        let dentro: String = fonte[i + 2..i + d].iter().collect();
                        let nome: String = aparar(&dentro)
                            .chars()
                            .take_while(|c| {
                                c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | ':' | '_')
                            })
                            .collect();
                        if nome.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) {
                            out.push(Marca::Fecha {
                                ini: i,
                                tag: nome.to_lowercase(),
                            });
                        }
                        i += d + 1;
                    }
                    None => {
                        dado(&mut out, i, n);
                        i = n;
                    }
                }
            } else if fonte[i..].starts_with(&['<', '!', '-', '-']) {
                // comentário
                let resto = &fonte[i + 4..];
                let fim = resto
                    .windows(3)
                    .position(|w| w == ['-', '-', '>'])
                    .map(|d| i + 4 + d + 3);
                match fim {
                    Some(f) => i = f,
                    None => {
                        dado(&mut out, i, n);
                        i = n;
                    }
                }
            } else if prox == Some('!') || prox == Some('?') {
                match fonte[i..].iter().position(|c| *c == '>') {
                    Some(d) => i += d + 1,
                    None => {
                        dado(&mut out, i, n);
                        i = n;
                    }
                }
            } else {
                dado(&mut out, i, i + 1); // um '<' solto é texto
                i += 1;
            }
        } else {
            // '&'
            let resto = &fonte[i + 1..];
            if resto.first() == Some(&'#') {
                let hexa = matches!(resto.get(1), Some('x' | 'X'));
                let ini_d = if hexa { 2 } else { 1 };
                let mut k = ini_d;
                while k < resto.len()
                    && (if hexa {
                        resto[k].is_ascii_hexdigit()
                    } else {
                        resto[k].is_ascii_digit()
                    })
                {
                    k += 1;
                }
                if k > ini_d && k < resto.len() {
                    let nome: String = resto[1..k].iter().collect();
                    out.push(Marca::Caractere { ini: i, nome });
                    i += 1 + k + usize::from(resto[k] == ';');
                    continue;
                }
                if k > ini_d {
                    // referência cortada no fim do texto
                    let nome: String = resto[1..k].iter().collect();
                    out.push(Marca::Caractere { ini: i, nome });
                    i = n;
                    continue;
                }
                dado(&mut out, i, i + 1);
                i += 1;
            } else if resto.first().is_some_and(|c| c.is_ascii_alphabetic()) {
                let mut k = 1;
                while k < resto.len()
                    && (resto[k].is_ascii_alphanumeric() || matches!(resto[k], '-' | '.'))
                {
                    k += 1;
                }
                let nome: String = resto[..k].iter().collect();
                out.push(Marca::Entidade { ini: i, nome });
                i += 1 + k + usize::from(resto.get(k) == Some(&';'));
            } else {
                dado(&mut out, i, i + 1);
                i += 1;
            }
        }
    }
    out
}

struct Leitor<'a> {
    fonte: &'a [char],
    trechos: Vec<Trecho>,
    pilha: Vec<(String, Atributos)>,
}

impl Leitor<'_> {
    /// O estilo atual é RECALCULADO a partir da pilha: um `</b>` fecha só o <b>, mesmo com um
    /// <span> aberto depois dele (HTML cruzado escrito à mão) — é como os clientes de e-mail
    /// desenham.
    fn atual(&self) -> Estilo {
        self.pilha
            .iter()
            .fold(Estilo::default(), |e, (tag, a)| aplicar_tag(e, tag, a))
    }

    fn quebra(&mut self, ini: usize, fim: usize) {
        // Espaço "solto" antes de uma quebra não aparece no cliente de e-mail.
        if self
            .trechos
            .last()
            .is_some_and(|t| t.texto == " " && t.fim_fonte - t.ini_fonte > 0)
        {
            self.trechos.pop();
        }
        // Quebra IMPLÍCITA (fim/início de <p>/<div>) não se acumula com outra quebra: </p><div>
        // é UMA linha nova no cliente. <br> explícito sempre conta.
        if ini == fim && self.trechos.last().is_some_and(|t| t.texto == "\n") {
            return;
        }
        let estilo = self.atual();
        self.trechos.push(Trecho {
            texto: "\n".into(),
            estilo,
            ini_fonte: ini as i64,
            fim_fonte: fim as i64,
        });
    }

    fn dado(&mut self, base: usize, texto: &str) {
        let estilo = self.atual();
        let chars: Vec<char> = texto.chars().collect();
        let ascii_branco = |c: char| matches!(c, ' ' | '\t' | '\r' | '\n');
        let mut i = 0;
        while i < chars.len() {
            let e_branco = ascii_branco(chars[i]);
            let mut j = i + 1;
            while j < chars.len() && ascii_branco(chars[j]) == e_branco {
                j += 1;
            }
            let (ini, fim) = (base + i, base + j);
            // Espaço em branco vira UM espaço, como o cliente de e-mail faz: um Enter digitado
            // no código NÃO é quebra de linha (só <br> é). Só branco ASCII colapsa; &nbsp; não.
            let pedaco: String = if e_branco {
                if self.trechos.last().is_none_or(|t| t.texto == "\n") {
                    i = j;
                    continue; // branco no início ou logo após uma quebra: some
                }
                " ".into()
            } else {
                chars[i..j].iter().collect()
            };
            self.trechos.push(Trecho {
                texto: pedaco,
                estilo: estilo.clone(),
                ini_fonte: ini as i64,
                fim_fonte: fim as i64,
            });
            i = j;
        }
    }

    fn referencia(&mut self, ini: usize, exibido: String) {
        // a referência no código: & + (#)letras/dígitos + ';' opcional
        let mut fim = ini + 1;
        if self.fonte.get(fim) == Some(&'#') {
            fim += 1;
        }
        let comeco = fim;
        while fim < self.fonte.len() && self.fonte[fim].is_ascii_alphanumeric() {
            fim += 1;
        }
        if fim == comeco {
            fim = ini + exibido.chars().count();
        } else if self.fonte.get(fim) == Some(&';') {
            fim += 1;
        }
        let estilo = self.atual();
        self.trechos.push(Trecho {
            texto: exibido,
            estilo,
            ini_fonte: ini as i64,
            fim_fonte: fim as i64,
        });
    }

    fn rodar(&mut self) {
        for marca in ler_marcas(self.fonte) {
            match marca {
                Marca::Dado { ini, texto } => self.dado(ini, &texto),
                Marca::Abre {
                    ini,
                    fim,
                    tag,
                    atributos,
                    fecha_sozinha,
                } => {
                    if tag == "br" {
                        // A quebra ocupa 1 caractere no texto exibido e a tag inteira no código.
                        self.quebra(ini, fim);
                        continue; // <br> não empilha (é vazia)
                    }
                    if fecha_sozinha {
                        continue;
                    }
                    if BLOCOS.contains(&tag.as_str()) && !self.trechos.is_empty() {
                        self.quebra(ini, ini); // quebra IMPLÍCITA: âncora de tamanho zero
                    }
                    self.pilha.push((tag, atributos));
                }
                Marca::Fecha { ini, tag } => {
                    if tag == "br" {
                        continue;
                    }
                    if BLOCOS.contains(&tag.as_str()) && !self.trechos.is_empty() {
                        self.quebra(ini, ini); // fim de bloco = linha nova (se vier mais texto)
                    }
                    if let Some(k) = self.pilha.iter().rposition(|(t, _)| *t == tag) {
                        self.pilha.remove(k); // fecha SÓ esta tag
                    }
                    // fechamento sem abertura: ignorado, como os clientes fazem
                }
                Marca::Entidade { ini, nome } => {
                    let cru = format!("&{nome};");
                    self.referencia(ini, desescapar(&cru));
                }
                Marca::Caractere { ini, nome } => {
                    let numero = match nome.strip_prefix(['x', 'X']) {
                        Some(h) => u32::from_str_radix(h, 16).ok(),
                        None => nome.parse::<u32>().ok(),
                    };
                    let exibido = numero
                        .and_then(char::from_u32)
                        .map(String::from)
                        .unwrap_or_else(|| format!("&#{nome};"));
                    self.referencia(ini, exibido);
                }
            }
        }
    }
}

/// HTML -> lista de trechos estilizados, já com as {variáveis} substituídas. `com_fonte` NÃO
/// junta trechos vizinhos de mesmo estilo — modo usado na carga do HTML no editor.
pub fn html_para_trechos(
    html: &str,
    valores: Option<&HashMap<String, String>>,
    com_fonte: bool,
) -> Vec<Trecho> {
    let fonte: Vec<char> = html.chars().collect();
    let mut leitor = Leitor {
        fonte: &fonte,
        trechos: Vec::new(),
        pilha: Vec::new(),
    };
    leitor.rodar();
    let mut trechos = leitor.trechos;
    // Fim de bloco no FIM do documento (…</p>) não abre linha em branco no cliente.
    while trechos
        .last()
        .is_some_and(|t| t.texto == "\n" && t.ini_fonte == t.fim_fonte)
    {
        trechos.pop();
    }
    let mut ancorados: Vec<Trecho> = Vec::new();
    for t in trechos {
        // QUEBRA nas fronteiras das {variáveis}: os pedaços LITERAIS mantêm a faixa caractere a
        // caractere do HTML, e só o pedaço da variável fica ancorado ao token inteiro.
        let pedacos = partir_variaveis(&t.texto, valores);
        if pedacos.len() == 1 && pedacos[0].1.is_empty() {
            ancorados.push(t);
            continue;
        }
        let mut base = t.ini_fonte;
        for (pedaco, variavel) in pedacos {
            let (ini, fim) = (base, base + pedaco.chars().count() as i64);
            base = fim;
            let exibido = match valores
                .filter(|_| !variavel.is_empty())
                .and_then(|v| v.get(&variavel))
            {
                Some(v) => v.clone(),
                None => pedaco,
            };
            ancorados.push(Trecho {
                texto: exibido,
                estilo: t.estilo.clone(),
                ini_fonte: ini,
                fim_fonte: fim,
            });
        }
    }
    let vazio = || {
        vec![Trecho {
            texto: String::new(),
            estilo: Estilo::default(),
            ini_fonte: -1,
            fim_fonte: -1,
        }]
    };
    if com_fonte {
        return if ancorados.is_empty() {
            vazio()
        } else {
            ancorados
        };
    }
    // Junta trechos vizinhos de mesmo estilo.
    let mut saida: Vec<Trecho> = Vec::new();
    for t in ancorados {
        match saida.last_mut() {
            Some(a) if a.estilo == t.estilo => {
                a.texto.push_str(&t.texto);
                a.fim_fonte = t.fim_fonte;
            }
            _ => saida.push(t),
        }
    }
    if saida.is_empty() { vazio() } else { saida }
}
