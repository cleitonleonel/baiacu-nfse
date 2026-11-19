//! Planilhas como linhas de texto: Excel (.xlsx, .xlsm, .xls), OpenDocument (.ods) e CSV.
//!
//! Serve à importação de clientes e às tabelas oficiais (Anexo VIII da NFS-e), que usam
//! células mescladas: com `expandir`, o valor de uma mesclagem vale para todas as suas células.
use std::collections::BTreeMap;
use std::io::Cursor;
use std::path::Path;

use calamine::{Data, Reader};

use crate::erro::{Erro, Res};

pub type Linhas = BTreeMap<usize, BTreeMap<usize, String>>;

const MAX_LINHAS: usize = 1_048_576;
const MAX_COLUNAS: usize = 16_384;
const MAX_CELULAS: usize = 2_000_000;

fn dimensoes_excessivas() -> Erro {
    Erro::valor("A planilha excede o tamanho suportado. Copie a tabela para uma nova aba e divida os dados em arquivos menores.")
}

fn conferir_limites(linha: usize, coluna: usize, total: usize) -> Res<()> {
    if linha >= MAX_LINHAS || coluna >= MAX_COLUNAS || total > MAX_CELULAS {
        return Err(dimensoes_excessivas());
    }
    Ok(())
}

/// Texto de uma célula, como o usuário a vê: números inteiros sem ".0".
pub fn texto_celula(d: &Data) -> String {
    match d {
        Data::Empty | Data::Error(_) => String::new(),
        Data::String(s) => s.trim().to_string(),
        Data::Int(i) => i.to_string(),
        Data::Float(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", *f as i64),
        Data::Float(f) => f.to_string(),
        Data::Bool(b) => if *b { "SIM" } else { "NÃO" }.to_string(),
        Data::DateTime(dt) => dt
            .as_datetime()
            .map(|d| d.format("%d/%m/%Y").to_string())
            .unwrap_or_else(|| dt.as_f64().to_string()),
        Data::DateTimeIso(s) | Data::DurationIso(s) => s.clone(),
    }
}

/// Linhas de uma aba de um .xlsx em memória (`aba` = None: a primeira).
pub fn ler_xlsx(bytes: &[u8], aba: Option<&str>, expandir: bool) -> Res<Linhas> {
    let mut wb = calamine::Xlsx::new(Cursor::new(bytes))
        .map_err(|e| Erro::valor(format!("Planilha ilegível: {e}")))?;
    let nome = match aba {
        Some(a) => a.to_string(),
        None => wb
            .sheet_names()
            .first()
            .cloned()
            .ok_or_else(|| Erro::valor("A planilha não tem abas."))?,
    };
    let ilegivel = |e| Erro::valor(format!("Aba \"{nome}\" ilegível: {e}"));
    let mut linhas = Linhas::new();
    let mut total = 0;
    {
        // worksheet_range materializa o retângulo entre as células extremas.
        let mut leitor = wb.worksheet_cells_reader(&nome).map_err(ilegivel)?;
        while let Some(celula) = leitor.next_cell().map_err(ilegivel)? {
            let (l, c) = celula.get_position();
            let (l, c) = (l as usize, c as usize);
            let valor = texto_celula(&Data::from(celula.get_value().clone()));
            if !valor.is_empty() {
                total += 1;
                conferir_limites(l, c, total)?;
                linhas.entry(l).or_default().insert(c, valor);
            }
        }
    }
    if expandir {
        if let Ok(mesclas) = wb.merge_cells_by_sheet_name(&nome) {
            for m in mesclas {
                let (r0, c0) = (m.start.0 as usize, m.start.1 as usize);
                let valor = linhas
                    .get(&r0)
                    .and_then(|l| l.get(&c0))
                    .cloned()
                    .unwrap_or_default();
                if valor.is_empty() {
                    continue;
                }
                let (r1, c1) = (m.end.0 as usize, m.end.1 as usize);
                conferir_limites(r1, c1, total)?;
                total += (r1.saturating_sub(r0) + 1) * (c1.saturating_sub(c0) + 1);
                conferir_limites(r1, c1, total)?;
                for r in r0..=r1 {
                    let linha = linhas.entry(r).or_default();
                    for c in c0..=c1 {
                        linha.insert(c, valor.clone());
                    }
                }
            }
        }
    }
    Ok(linhas)
}

/// Mantém as coordenadas da aba sem materializar células vazias na prévia.
fn ler_faixa(faixa: &calamine::Range<Data>) -> Res<Linhas> {
    let Some((inicio_l, inicio_c)) = faixa.start() else {
        return Ok(Linhas::new());
    };
    let mut linhas = Linhas::new();
    let mut total = 0;
    for (l, c, d) in faixa.used_cells() {
        let (l, c) = (l + inicio_l as usize, c + inicio_c as usize);
        let valor = texto_celula(d);
        if !valor.is_empty() {
            total += 1;
            conferir_limites(l, c, total)?;
            linhas.entry(l).or_default().insert(c, valor);
        }
    }
    Ok(linhas)
}

/// Linhas da primeira aba de uma planilha em memória; `nome` (do arquivo) decide o formato.
pub fn ler_bytes(nome: &str, bytes: &[u8]) -> Res<Linhas> {
    let ext = Path::new(nome)
        .extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "csv" | "txt" => Ok(ler_csv(&decodificar(bytes))
            .into_iter()
            .enumerate()
            .filter_map(|(i, linha)| {
                let celulas: BTreeMap<_, _> = linha.into_iter().enumerate()
                    .filter(|(_, valor)| !valor.is_empty())
                    .collect();
                (!celulas.is_empty()).then_some((i, celulas))
            })
            .collect()),
        "xlsx" | "xlsm" => ler_xlsx(bytes, None, false),
        "xls" | "ods" => {
            let mut wb = calamine::open_workbook_auto_from_rs(Cursor::new(bytes))
                .map_err(|e| Erro::valor(format!("Planilha ilegível: {e}")))?;
            let aba = wb
                .sheet_names()
                .first()
                .cloned()
                .ok_or_else(|| Erro::valor("A planilha não tem abas."))?;
            let faixa = wb
                .worksheet_range(&aba)
                .map_err(|e| Erro::valor(format!("Aba \"{aba}\" ilegível: {e}")))?;
            ler_faixa(&faixa)
        }
        _ => Err(Erro::valor(
            "Formato não suportado. Use planilha Excel (.xlsx, .xls), OpenDocument (.ods) ou CSV.",
        )),
    }
}

/// Texto de um CSV: UTF-8 (com ou sem BOM) ou, se não for, Windows-1252 (o "CSV" do Excel
/// em português).
pub fn decodificar(bytes: &[u8]) -> String {
    let sem_bom = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    match std::str::from_utf8(sem_bom) {
        Ok(s) => s.to_string(),
        Err(_) => sem_bom.iter().map(|&b| cp1252(b)).collect(),
    }
}

fn cp1252(b: u8) -> char {
    const ALTOS: [char; 32] = [
        '€', '\u{81}', '‚', 'ƒ', '„', '…', '†', '‡', 'ˆ', '‰', 'Š', '‹', 'Œ', '\u{8d}', 'Ž',
        '\u{8f}', '\u{90}', '‘', '’', '“', '”', '•', '–', '—', '˜', '™', 'š', '›', 'œ', '\u{9d}',
        'ž', 'Ÿ',
    ];
    if (0x80..0xa0).contains(&b) {
        ALTOS[(b - 0x80) as usize]
    } else {
        b as char
    }
}

/// CSV com separador ";" (Excel em português) ou "," — o da primeira linha que tiver mais.
/// Aceita campos entre aspas, com aspas dobradas e quebras de linha dentro.
pub fn ler_csv(texto: &str) -> Vec<Vec<String>> {
    let primeira = texto.lines().next().unwrap_or("");
    let sep = if primeira.matches(';').count() >= primeira.matches(',').count() {
        ';'
    } else {
        ','
    };
    let mut linhas = Vec::new();
    let mut linha = Vec::new();
    let mut campo = String::new();
    let mut aspas = false;
    let mut it = texto.chars().peekable();
    while let Some(c) = it.next() {
        if aspas {
            match c {
                '"' if it.peek() == Some(&'"') => {
                    campo.push('"');
                    it.next();
                }
                '"' => aspas = false,
                _ => campo.push(c),
            }
            continue;
        }
        match c {
            '"' => aspas = true,
            '\r' => {}
            '\n' => {
                linha.push(std::mem::take(&mut campo).trim().to_string());
                linhas.push(std::mem::take(&mut linha));
            }
            c if c == sep => linha.push(std::mem::take(&mut campo).trim().to_string()),
            _ => campo.push(c),
        }
    }
    if !campo.is_empty() || !linha.is_empty() {
        linha.push(campo.trim().to_string());
        linhas.push(linha);
    }
    linhas
}

/// Um campo de CSV, entre aspas quando precisa.
pub fn campo_csv(s: &str) -> String {
    if s.contains([';', '"', '\n', '\r', ',']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

/// CSV para o Excel em português: UTF-8 com BOM, ";" e quebras CRLF.
pub fn escrever_csv(linhas: &[Vec<String>]) -> Vec<u8> {
    let mut out = String::from("\u{feff}");
    for l in linhas {
        out.push_str(&l.iter().map(|c| campo_csv(c)).collect::<Vec<_>>().join(";"));
        out.push_str("\r\n");
    }
    out.into_bytes()
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn csv_com_aspas_e_separadores() {
        let t = "Nome;Doc\r\n\"Silva; Ltda\";\"12.345\"\n\"Maria \"\"M\"\"\";1\n";
        let l = ler_csv(t);
        assert_eq!(l[0], vec!["Nome", "Doc"]);
        assert_eq!(l[1], vec!["Silva; Ltda", "12.345"]);
        assert_eq!(l[2], vec!["Maria \"M\"", "1"]);
        assert_eq!(ler_csv("a,b\n1,2")[1], vec!["1", "2"]);
        let ida = escrever_csv(&[vec!["a;b".into(), "c".into()]]);
        assert_eq!(ler_csv(&decodificar(&ida))[0], vec!["a;b", "c"]);
    }

    #[test]
    fn csv_do_excel_em_windows_1252() {
        let bytes = b"Munic\xedpio;UF\r\nS\xe3o Paulo;SP\r\n";
        let l = ler_csv(&decodificar(bytes));
        assert_eq!(l[1], vec!["São Paulo", "SP"]);
    }
}
