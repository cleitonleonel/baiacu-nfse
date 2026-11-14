//! XML do tamanho do que a NFS-e usa: documentos SEM prefixo de namespace (só o `xmlns`
//! padrão), sem comentários nem instruções de processamento.
//!
//! Três coisas dependem de sair IGUAL, byte a byte, ao que o programa sempre produziu:
//! - o texto do documento (`para_bytes`: a serialização da lxml/libxml2 — declaração com aspas
//!   simples, elemento vazio como `<a/>`);
//! - a forma CANÔNICA (C14N 1.0, sem comentários) de um pedaço dele (`canonico`): é sobre ela que
//!   se calculam o resumo e a assinatura digital;
//! - a ordem dos atributos e os espaços, que nenhuma das duas pode mexer.
use crate::erro::{Erro, Res};

#[derive(Debug, Clone, PartialEq)]
pub enum No {
    Elemento(Elemento),
    Texto(String),
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Elemento {
    pub nome: String,
    /// Namespace em vigor neste elemento ("" = nenhum). Vira `xmlns="…"` só onde muda.
    pub ns: String,
    pub atributos: Vec<(String, String)>,
    pub filhos: Vec<No>,
    /// Num elemento LIDO de um documento: as declarações de namespace que estavam na tag dele
    /// — (prefixo ou "", endereço), na ordem. São reescritas como estavam, mesmo as que repetem
    /// a do pai (a NFS-e autorizada vem assim e é guardada como veio).
    pub declaracoes: Vec<(String, String)>,
}

impl Elemento {
    pub fn novo(nome: &str, ns: &str) -> Self {
        Elemento {
            nome: nome.to_string(),
            ns: ns.to_string(),
            atributos: Vec::new(),
            filhos: Vec::new(),
            declaracoes: Vec::new(),
        }
    }

    pub fn attr(&self, nome: &str) -> Option<&str> {
        self.atributos
            .iter()
            .find(|(k, _)| k == nome)
            .map(|(_, v)| v.as_str())
    }

    pub fn definir_attr(&mut self, nome: &str, valor: &str) {
        match self.atributos.iter_mut().find(|(k, _)| k == nome) {
            Some((_, v)) => *v = valor.to_string(),
            None => self.atributos.push((nome.to_string(), valor.to_string())),
        }
    }

    /// Acrescenta um filho com o MESMO namespace e devolve uma referência a ele.
    pub fn filho(&mut self, nome: &str) -> &mut Elemento {
        let ns = self.ns.clone();
        self.filhos.push(No::Elemento(Elemento::novo(nome, &ns)));
        match self.filhos.last_mut() {
            Some(No::Elemento(e)) => e,
            _ => unreachable!(),
        }
    }

    /// Acrescenta `<nome>texto</nome>` (mesmo namespace).
    pub fn filho_texto(&mut self, nome: &str, texto: &str) -> &mut Elemento {
        let e = self.filho(nome);
        e.filhos.push(No::Texto(texto.to_string()));
        e
    }

    pub fn texto(&mut self, texto: &str) {
        self.filhos.push(No::Texto(texto.to_string()));
    }

    pub fn elementos(&self) -> impl Iterator<Item = &Elemento> {
        self.filhos.iter().filter_map(|n| match n {
            No::Elemento(e) => Some(e),
            No::Texto(_) => None,
        })
    }

    /// Primeiro filho direto com esse nome (em qualquer namespace).
    pub fn achar(&self, nome: &str) -> Option<&Elemento> {
        self.elementos().find(|e| e.nome == nome)
    }

    /// O texto que vem logo depois da abertura do elemento, antes do primeiro filho ("" se não
    /// há) — o `.text` de sempre.
    pub fn texto_inicial(&self) -> &str {
        match self.filhos.first() {
            Some(No::Texto(t)) => t.as_str(),
            _ => "",
        }
    }

    /// Todos os pedaços de texto do elemento e dos descendentes, na ordem do documento.
    pub fn textos(&self) -> Vec<&str> {
        fn juntar<'a>(e: &'a Elemento, out: &mut Vec<&'a str>) {
            for f in &e.filhos {
                match f {
                    No::Texto(t) => out.push(t.as_str()),
                    No::Elemento(x) => juntar(x, out),
                }
            }
        }
        let mut out = Vec::new();
        juntar(self, &mut out);
        out
    }

    /// O primeiro elemento que casa com o caminho de nomes (em qualquer namespace), como
    /// `find("{*}a/{*}b")`.
    pub fn achar_caminho(&self, caminho: &[&str]) -> Option<&Elemento> {
        let Some((primeiro, resto)) = caminho.split_first() else {
            return Some(self);
        };
        for e in self.elementos().filter(|e| e.nome == *primeiro) {
            if let Some(achado) = e.achar_caminho(resto) {
                return Some(achado);
            }
        }
        None
    }

    /// Este elemento e todos os descendentes, na ordem do documento.
    pub fn todos(&self) -> Vec<&Elemento> {
        fn juntar<'a>(e: &'a Elemento, out: &mut Vec<&'a Elemento>) {
            out.push(e);
            for f in e.elementos() {
                juntar(f, out);
            }
        }
        let mut out = Vec::new();
        juntar(self, &mut out);
        out
    }
}

// ------------------------------------------------------------------------------- //
// Ler
// ------------------------------------------------------------------------------- //
/// Lê um documento. Comentários e instruções de processamento são ignorados.
pub fn ler(xml: &[u8]) -> Res<Elemento> {
    let texto = std::str::from_utf8(xml).map_err(|_| Erro::valor("XML não está em UTF-8."))?;
    let texto = texto.strip_prefix('\u{feff}').unwrap_or(texto);
    let opcoes = roxmltree::ParsingOptions {
        allow_dtd: false,
        ..Default::default()
    };
    let doc = roxmltree::Document::parse_with_options(texto, opcoes)
        .map_err(|e| Erro::valor(format!("XML inválido: {e}")))?;
    Ok(converter(doc.root_element()))
}

/// As declarações de namespace escritas na tag de abertura que começa em `fonte` ("<nome …>").
fn declaracoes_da_tag(fonte: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let b = fonte.as_bytes();
    let mut i = 1;
    while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'>' && b[i] != b'/' {
        i += 1; // o nome da tag
    }
    loop {
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= b.len() || b[i] == b'>' || b[i] == b'/' {
            return out;
        }
        let ini = i;
        while i < b.len() && b[i] != b'=' && !b[i].is_ascii_whitespace() {
            i += 1;
        }
        let nome = &fonte[ini..i];
        while i < b.len() && (b[i] == b'=' || b[i].is_ascii_whitespace()) {
            i += 1;
        }
        if i >= b.len() || (b[i] != b'"' && b[i] != b'\'') {
            return out;
        }
        let aspa = b[i];
        i += 1;
        let ini_valor = i;
        while i < b.len() && b[i] != aspa {
            i += 1;
        }
        let valor = &fonte[ini_valor..i.min(b.len())];
        i += 1;
        let prefixo = if nome == "xmlns" {
            Some("")
        } else {
            nome.strip_prefix("xmlns:")
        };
        if let Some(p) = prefixo {
            let valor = valor
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&apos;", "'")
                .replace("&amp;", "&");
            out.push((p.to_string(), valor));
        }
    }
}

fn converter(n: roxmltree::Node) -> Elemento {
    let mut e = Elemento::novo(n.tag_name().name(), n.tag_name().namespace().unwrap_or(""));
    if let Some(fonte) = n.document().input_text().get(n.range().start..) {
        e.declaracoes = declaracoes_da_tag(fonte);
    }
    for a in n.attributes() {
        e.atributos
            .push((a.name().to_string(), a.value().to_string()));
    }
    for f in n.children() {
        if f.is_element() {
            e.filhos.push(No::Elemento(converter(f)));
        } else if f.is_text() {
            let t = f.text().unwrap_or("");
            // pedaços de texto vizinhos (texto + CDATA) ficam num nó só
            if let Some(No::Texto(anterior)) = e.filhos.last_mut() {
                anterior.push_str(t);
            } else {
                e.filhos.push(No::Texto(t.to_string()));
            }
        }
    }
    e
}

// ------------------------------------------------------------------------------- //
// Escrever como a lxml (libxml2)
// ------------------------------------------------------------------------------- //
/// `etree.tostring(raiz, xml_declaration=True, encoding="utf-8")`.
pub fn para_bytes(raiz: &Elemento, declaracao: bool) -> Vec<u8> {
    let mut s = String::new();
    if declaracao {
        s.push_str("<?xml version='1.0' encoding='utf-8'?>\n");
    }
    escrever(raiz, "", &mut s);
    s.into_bytes()
}

/// `<nome` + declarações de namespace + atributos (nessa ordem, como a libxml2 escreve).
fn abertura(e: &Elemento, ns_pai: &str, s: &mut String) {
    s.push('<');
    s.push_str(&e.nome);
    if !e.declaracoes.is_empty() {
        // elemento lido de um documento: as declarações voltam como estavam
        for (prefixo, endereco) in &e.declaracoes {
            s.push_str(" xmlns");
            if !prefixo.is_empty() {
                s.push(':');
                s.push_str(prefixo);
            }
            s.push_str("=\"");
            escapar(endereco, true, false, s);
            s.push('"');
        }
    } else if e.ns != ns_pai {
        s.push_str(" xmlns=\"");
        escapar(&e.ns, true, false, s);
        s.push('"');
    }
    for (k, v) in &e.atributos {
        s.push(' ');
        s.push_str(k);
        s.push_str("=\"");
        escapar(v, true, false, s);
        s.push('"');
    }
}

fn escrever(e: &Elemento, ns_pai: &str, s: &mut String) {
    abertura(e, ns_pai, s);
    if e.filhos.is_empty() {
        s.push_str("/>");
        return;
    }
    s.push('>');
    for f in &e.filhos {
        match f {
            No::Texto(t) => escapar(t, false, false, s),
            No::Elemento(x) => escrever(x, &e.ns, s),
        }
    }
    s.push_str("</");
    s.push_str(&e.nome);
    s.push('>');
}

/// `etree.tostring(raiz, xml_declaration=True, encoding="utf-8", pretty_print=True)`: cada
/// elemento numa linha, recuo de dois espaços; elemento que tem texto fica numa linha só.
pub fn para_bytes_bonito(raiz: &Elemento) -> Vec<u8> {
    let mut s = String::from("<?xml version='1.0' encoding='utf-8'?>\n");
    escrever_bonito(raiz, "", 0, true, &mut s);
    s.push('\n');
    s.into_bytes()
}

fn escrever_bonito(e: &Elemento, ns_pai: &str, nivel: usize, formatar: bool, s: &mut String) {
    let formatar = formatar && !e.filhos.iter().any(|f| matches!(f, No::Texto(_)));
    if !formatar {
        escrever(e, ns_pai, s);
        return;
    }
    abertura(e, ns_pai, s);
    if e.filhos.is_empty() {
        s.push_str("/>");
        return;
    }
    s.push_str(">\n");
    for f in e.elementos() {
        s.push_str(&"  ".repeat(nivel + 1));
        escrever_bonito(f, &e.ns, nivel + 1, true, s);
        s.push('\n');
    }
    s.push_str(&"  ".repeat(nivel));
    s.push_str("</");
    s.push_str(&e.nome);
    s.push('>');
}

/// Escapes de texto e de atributo. `canonico`: as regras do C14N (referências em hexadecimal
/// maiúsculo, `>` de atributo sem escape); senão, as da libxml2.
fn escapar(t: &str, atributo: bool, canonico: bool, s: &mut String) {
    for c in t.chars() {
        match c {
            '&' => s.push_str("&amp;"),
            '<' => s.push_str("&lt;"),
            '>' if !(canonico && atributo) => s.push_str("&gt;"),
            '"' if atributo => s.push_str("&quot;"),
            '\r' => s.push_str(if canonico { "&#xD;" } else { "&#13;" }),
            '\n' if atributo => s.push_str(if canonico { "&#xA;" } else { "&#10;" }),
            '\t' if atributo => s.push_str(if canonico { "&#x9;" } else { "&#9;" }),
            outro => s.push(outro),
        }
    }
}

// ------------------------------------------------------------------------------- //
// Forma canônica (C14N 1.0 inclusiva, sem comentários)
// ------------------------------------------------------------------------------- //
/// Forma canônica do elemento tomado como PEDAÇO de um documento: o namespace que ele herda
/// aparece nele (`<infDPS xmlns="…" Id="…">`), os atributos saem em ordem alfabética e elemento
/// vazio sai como `<a></a>`.
pub fn canonico(e: &Elemento) -> Vec<u8> {
    let mut s = String::new();
    canonizar(e, "", &[], &mut s);
    s.into_bytes()
}

fn canonizar(
    e: &Elemento,
    ns_emitido: &str,
    prefixos_emitidos: &[(String, String)],
    s: &mut String,
) {
    s.push('<');
    s.push_str(&e.nome);
    if e.ns != ns_emitido {
        s.push_str(" xmlns=\"");
        escapar(&e.ns, true, true, s);
        s.push('"');
    }
    // namespaces com prefixo declarados aqui e ainda não escritos por um ancestral, por prefixo
    let mut em_vigor: Vec<(String, String)> = prefixos_emitidos.to_vec();
    let mut novos: Vec<&(String, String)> = Vec::new();
    for d in e.declaracoes.iter().filter(|(p, _)| !p.is_empty()) {
        if !em_vigor.contains(d) {
            em_vigor.retain(|(p, _)| *p != d.0);
            em_vigor.push(d.clone());
            novos.push(d);
        }
    }
    novos.sort_by(|a, b| a.0.cmp(&b.0));
    for (prefixo, endereco) in novos {
        s.push_str(" xmlns:");
        s.push_str(prefixo);
        s.push_str("=\"");
        escapar(endereco, true, true, s);
        s.push('"');
    }
    let mut attrs: Vec<&(String, String)> = e.atributos.iter().collect();
    attrs.sort_by(|a, b| a.0.cmp(&b.0));
    for (k, v) in attrs {
        s.push(' ');
        s.push_str(k);
        s.push_str("=\"");
        escapar(v, true, true, s);
        s.push('"');
    }
    s.push('>');
    for f in &e.filhos {
        match f {
            No::Texto(t) => escapar(t, false, true, s),
            No::Elemento(x) => canonizar(x, &e.ns, &em_vigor, s),
        }
    }
    s.push_str("</");
    s.push_str(&e.nome);
    s.push('>');
}
