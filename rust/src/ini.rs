//! "Arquivo .ini" em memória — o `configparser.ConfigParser(interpolation=None, strict=True)`
//! do Python com `optionxform = str` (opções com maiúsculas/minúsculas preservadas), na ordem
//! em que as seções e opções entram.
//!
//! Os cadastros do programa são guardados no banco como (arquivo, seção, opção, valor) e
//! trabalhados assim em memória. A leitura e a escrita em TEXTO seguem o configparser à risca:
//! um valor de várias linhas é escrito com TAB na continuação e, ao ler de volta, cada linha
//! volta aparada — o texto que vai para a nota depende dessa regra.
use std::path::Path;

use crate::erro::{Erro, Res};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Ini {
    secoes: Vec<(String, Vec<(String, String)>)>,
}

impl Ini {
    pub fn novo() -> Self {
        Ini::default()
    }

    pub fn secoes(&self) -> Vec<&str> {
        self.secoes.iter().map(|(n, _)| n.as_str()).collect()
    }

    pub fn tem_secao(&self, secao: &str) -> bool {
        self.secoes.iter().any(|(n, _)| n == secao)
    }

    /// Cria a seção se ainda não existe (o `if not has_section: add_section`).
    pub fn garantir_secao(&mut self, secao: &str) {
        if !self.tem_secao(secao) {
            self.secoes.push((secao.to_string(), Vec::new()));
        }
    }

    /// `add_section`: erro se a seção já existe.
    pub fn adicionar_secao(&mut self, secao: &str) -> Res<()> {
        if self.tem_secao(secao) {
            return Err(Erro::valor(format!("Section {secao:?} already exists")));
        }
        self.secoes.push((secao.to_string(), Vec::new()));
        Ok(())
    }

    pub fn remover_secao(&mut self, secao: &str) -> bool {
        let antes = self.secoes.len();
        self.secoes.retain(|(n, _)| n != secao);
        self.secoes.len() != antes
    }

    fn opcoes(&self, secao: &str) -> Option<&Vec<(String, String)>> {
        self.secoes.iter().find(|(n, _)| n == secao).map(|(_, o)| o)
    }

    fn opcoes_mut(&mut self, secao: &str) -> Option<&mut Vec<(String, String)>> {
        self.secoes
            .iter_mut()
            .find(|(n, _)| n == secao)
            .map(|(_, o)| o)
    }

    pub fn tem_opcao(&self, secao: &str, opcao: &str) -> bool {
        self.opcoes(secao)
            .is_some_and(|o| o.iter().any(|(k, _)| k == opcao))
    }

    /// Valor cru (sem aparar), ou None se a seção/opção não existe.
    pub fn obter(&self, secao: &str, opcao: &str) -> Option<&str> {
        self.opcoes(secao)?
            .iter()
            .find(|(k, _)| k == opcao)
            .map(|(_, v)| v.as_str())
    }

    /// Valor APARADO, ou `padrao` se não existe (o `_val` do serviço).
    pub fn val(&self, secao: &str, opcao: &str, padrao: &str) -> String {
        match self.obter(secao, opcao) {
            Some(v) => v.trim().to_string(),
            None => padrao.to_string(),
        }
    }

    /// `parser.set`: a seção tem de existir.
    pub fn definir(&mut self, secao: &str, opcao: &str, valor: &str) -> Res<()> {
        let Some(opcoes) = self.opcoes_mut(secao) else {
            return Err(Erro::valor(format!("No section: {secao:?}")));
        };
        match opcoes.iter_mut().find(|(k, _)| k == opcao) {
            Some((_, v)) => *v = valor.to_string(),
            None => opcoes.push((opcao.to_string(), valor.to_string())),
        }
        Ok(())
    }

    /// Define criando a seção se preciso.
    pub fn por(&mut self, secao: &str, opcao: &str, valor: &str) {
        self.garantir_secao(secao);
        let _ = self.definir(secao, opcao, valor);
    }

    pub fn remover_opcao(&mut self, secao: &str, opcao: &str) -> bool {
        match self.opcoes_mut(secao) {
            Some(o) => {
                let antes = o.len();
                o.retain(|(k, _)| k != opcao);
                o.len() != antes
            }
            None => false,
        }
    }

    /// (opção, valor) da seção, na ordem. Seção ausente = vazio.
    pub fn itens(&self, secao: &str) -> Vec<(&str, &str)> {
        self.opcoes(secao)
            .map(|o| o.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect())
            .unwrap_or_default()
    }

    // ----------------------------------------------------------------------------- //
    // Texto: escrever e ler como o configparser
    // ----------------------------------------------------------------------------- //
    /// `parser.write(f, space_around_delimiters=True)`.
    pub fn para_texto(&self) -> String {
        let mut out = String::new();
        for (secao, opcoes) in &self.secoes {
            out.push('[');
            out.push_str(secao);
            out.push_str("]\n");
            for (k, v) in opcoes {
                out.push_str(k);
                out.push_str(" = ");
                out.push_str(&v.replace('\n', "\n\t"));
                out.push('\n');
            }
            out.push('\n');
        }
        out
    }

    /// `parser.read_string`. `literal`: sem prefixos de comentário ('#' e ';') — arquivo de
    /// passagem escrito pelo próprio programa, em que uma linha de TEXTO pode começar assim.
    pub fn de_texto(texto: &str, literal: bool) -> Res<Ini> {
        let texto = texto.strip_prefix('\u{feff}').unwrap_or(texto);
        let mut ini = Ini::novo();
        // Valor de cada opção ainda em linhas (juntadas no fim, como o configparser).
        let mut valores: Vec<Vec<Vec<String>>> = Vec::new();
        let mut secao_atual: Option<usize> = None;
        let mut opcao_atual: Option<usize> = None;
        let mut nivel_opcao = 0usize;
        let mut erros: Vec<String> = Vec::new();

        for (n, linha) in linhas_universais(texto).into_iter().enumerate() {
            let aparada = linha.trim();
            let comentario = !literal && (aparada.starts_with('#') || aparada.starts_with(';'));
            let limpa = if comentario { "" } else { aparada };
            if limpa.is_empty() {
                // Linha vazia DENTRO de um valor fica no valor (só se não era comentário).
                if !comentario {
                    if let (Some(s), Some(o)) = (secao_atual, opcao_atual) {
                        valores[s][o].push(String::new());
                    }
                }
                continue;
            }
            let nivel = linha.find(|c: char| !c.is_whitespace()).unwrap_or(0);
            if let (Some(s), Some(o)) = (secao_atual, opcao_atual) {
                if nivel > nivel_opcao {
                    valores[s][o].push(limpa.to_string());
                    continue;
                }
            }
            nivel_opcao = nivel;
            if let Some(nome) = cabecalho(limpa) {
                if ini.tem_secao(nome) {
                    return Err(Erro::valor(format!("Section {nome:?} already exists")));
                }
                ini.secoes.push((nome.to_string(), Vec::new()));
                valores.push(Vec::new());
                secao_atual = Some(ini.secoes.len() - 1);
                opcao_atual = None;
                continue;
            }
            let Some(s) = secao_atual else {
                return Err(Erro::valor(format!(
                    "File contains no section headers. linha {}: {linha:?}",
                    n + 1
                )));
            };
            // Opção: tudo até o PRIMEIRO '=' ou ':'.
            let Some(pos) = limpa.find(['=', ':']) else {
                erros.push(format!("linha {}: {linha:?}", n + 1));
                continue;
            };
            let nome = limpa[..pos].trim_end();
            if nome.is_empty() {
                erros.push(format!("linha {}: {linha:?}", n + 1));
            }
            if ini.secoes[s].1.iter().any(|(k, _)| k == nome) {
                return Err(Erro::valor(format!(
                    "Option {nome:?} in section {:?} already exists",
                    ini.secoes[s].0
                )));
            }
            ini.secoes[s].1.push((nome.to_string(), String::new()));
            valores[s].push(vec![limpa[pos + 1..].trim().to_string()]);
            opcao_atual = Some(ini.secoes[s].1.len() - 1);
        }
        if !erros.is_empty() {
            return Err(Erro::valor(format!(
                "Source contains parsing errors: {}",
                erros.join("; ")
            )));
        }
        for (s, opcoes) in valores.into_iter().enumerate() {
            for (o, linhas) in opcoes.into_iter().enumerate() {
                ini.secoes[s].1[o].1 = linhas.join("\n").trim_end().to_string();
            }
        }
        Ok(ini)
    }

    /// Lê um arquivo físico (utf-8, com ou sem BOM). Ausente = Ini vazio.
    pub fn de_arquivo(caminho: &Path, literal: bool) -> Res<Ini> {
        match std::fs::read(caminho) {
            Ok(bytes) => Ini::de_texto(&String::from_utf8_lossy(&bytes), literal),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Ini::novo()),
            Err(e) => Err(e.into()),
        }
    }

    /// O que sobra de um Ini depois de escrito e lido de volta (a "passagem por arquivo" que
    /// a emissão fazia): cada linha de cada valor aparada, linhas vazias do fim retiradas.
    pub fn ida_e_volta(&self, literal: bool) -> Res<Ini> {
        Ini::de_texto(&self.para_texto(), literal)
    }
}

/// `[nome]` no começo da linha (o que vem depois do último ']' é ignorado, como no Python).
fn cabecalho(limpa: &str) -> Option<&str> {
    let resto = limpa.strip_prefix('[')?;
    let fim = resto.rfind(']')?;
    if fim == 0 { None } else { Some(&resto[..fim]) }
}

/// Linhas com as quebras "universais" do Python em modo texto: \n, \r\n e \r sozinho.
fn linhas_universais(texto: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let b = texto.as_bytes();
    let mut ini = 0;
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\n' => {
                out.push(&texto[ini..i]);
                ini = i + 1;
            }
            b'\r' => {
                out.push(&texto[ini..i]);
                if i + 1 < b.len() && b[i + 1] == b'\n' {
                    i += 1;
                }
                ini = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    if ini < b.len() {
        out.push(&texto[ini..]);
    }
    out
}
