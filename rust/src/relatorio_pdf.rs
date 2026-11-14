//! Relatórios em A4 paisagem, com as medidas do LongTable/Paragraph do Python.
use std::fmt::Write as FmtWrite;
use std::io::Write;

use flate2::{Compression, write::ZlibEncoder};

use crate::erro::{Erro, Res};
use crate::pdf::{self, K};

const W: f64 = 297.0 * K;
const H: f64 = 210.0 * K;
const MARGEM: f64 = 12.0 * K + 6.0;

/// Precisão do fp_str usado pela ReportLab nos operadores de transformação.
fn fp(n: f64) -> String {
    if n.abs() < 0.0000001 {
        return "0".into();
    }
    let casas = (6.0 - n.abs().log10().floor()).clamp(0.0, 6.0) as usize;
    let s = format!("{n:.casas$}");
    if s.contains('.') {
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    } else {
        s
    }
}

fn comprimento(t: &str, tam: f64, b: bool) -> f64 {
    pdf::largura(t, tam, b) * K
}
fn quebrar(t: &str, w: f64, tam: f64, b: bool) -> Vec<String> {
    let normal = t.split_whitespace().collect::<Vec<_>>().join(" ");
    if normal.is_empty() {
        return vec![String::new()];
    }
    let mut out = Vec::new();
    let mut linha = String::new();
    for palavra in normal.split(' ') {
        let proposta = if linha.is_empty() {
            palavra.to_string()
        } else {
            format!("{linha} {palavra}")
        };
        let espacos = proposta.bytes().filter(|b| *b == b' ').count();
        let folga = espacos as f64 * comprimento(" ", tam, b) * 0.05;
        if comprimento(&proposta, tam, b) <= w + folga {
            linha = proposta;
            continue;
        }
        if !linha.is_empty() {
            out.push(std::mem::take(&mut linha));
        }
        for c in palavra.chars() {
            let proposta = format!("{linha}{c}");
            if comprimento(&proposta, tam, b) > w && !linha.is_empty() {
                out.push(std::mem::take(&mut linha));
            }
            linha.push(c);
        }
    }
    if !linha.is_empty() {
        out.push(linha);
    }
    out
}

fn texto(
    out: &mut String,
    x: f64,
    y: f64,
    t: &str,
    tam: f64,
    fonte: &str,
    cor: &str,
    espaco: f64,
) -> Res<()> {
    let bytes = t
        .chars()
        .map(|c| {
            pdf::cp1252(c).ok_or_else(|| {
                Erro::valor(format!(
                    "A fonte do relatório não contém o caractere '{c}'."
                ))
            })
        })
        .collect::<Res<Vec<_>>>()?;
    let _ = writeln!(
        out,
        "{cor} rg BT /{fonte} {} Tf 1 0 0 1 {} {} Tm {} Tw <{}> Tj ET",
        fp(tam),
        fp(x),
        fp(y),
        fp(espaco),
        hex::encode(bytes)
    );
    Ok(())
}
fn espaco(t: &str, w: f64, tam: f64, bold: bool) -> f64 {
    let n = t.bytes().filter(|b| *b == b' ').count();
    if n > 0 {
        ((w - comprimento(t, tam, bold)) / n as f64).min(0.0)
    } else {
        0.0
    }
}

#[derive(Clone)]
struct Celula {
    linhas: Vec<String>,
    paragraph: bool,
}
fn celulas(valores: &[String], larguras: &[f64], wrap: &[usize], cab: bool) -> Vec<Celula> {
    valores
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let paragraph = !cab && wrap.contains(&i);
            Celula {
                linhas: if paragraph {
                    quebrar(t, larguras[i] - 6.0, 7.0, false)
                } else {
                    t.split('\n').map(str::to_string).collect()
                },
                paragraph,
            }
        })
        .collect()
}
fn altura(cs: &[Celula]) -> f64 {
    cs.iter()
        .map(|c| c.linhas.len() as f64 * if c.paragraph { 8.0 } else { 12.0 })
        .fold(0.0, f64::max)
        + 4.0
}

fn tabela(
    out: &mut String,
    linhas: &[(Vec<Celula>, f64, bool, usize)],
    larguras: &[f64],
    topo: f64,
    parte: usize,
    partida: bool,
) -> Res<f64> {
    let w: f64 = larguras.iter().sum();
    let h: f64 = linhas.iter().map(|r| r.1).sum();
    let x = (W - w) / 2.0;
    let base = H - topo - h;
    let _ = writeln!(out, "q 1 0 0 1 {} {} cm", fp(x), fp(base));
    let mut y = h;
    for (local, (cs, hr, cab, _indice)) in linhas.iter().enumerate() {
        let cor = if *cab {
            ".215686 .278431 .309804"
        } else if local % 2 == 1 {
            "1 1 1"
        } else {
            ".94902 .956863 .960784"
        };
        let _ = writeln!(out, "{cor} rg n 0 {} {} {} re f*", fp(y), fp(w), fp(-hr));
        let fonte = if *cab { "F2" } else { "F1" };
        let cor = if *cab { "1 1 1" } else { "0 0 0" };
        let mut colx = 0.0;
        for (c, cw) in cs.iter().zip(larguras) {
            let leading = if c.paragraph { 8.0 } else { 12.0 };
            let inicio = if c.paragraph {
                (*hr - 4.0 - leading * c.linhas.len() as f64) / 2.0 + 2.0 + 7.0
            } else {
                (*hr - leading * c.linhas.len() as f64) / 2.0 + 7.0
            };
            for (i, t) in c.linhas.iter().enumerate() {
                texto(
                    out,
                    colx + 3.0,
                    y - inicio - i as f64 * leading,
                    t,
                    7.0,
                    fonte,
                    cor,
                    if c.paragraph {
                        espaco(t, cw - 6.0, 7.0, false)
                    } else {
                        0.0
                    },
                )?;
            }
            colx += cw;
        }
        y -= hr;
    }
    out.push_str("q 1 J 1 j .690196 .745098 .772549 RG .25 w\n");
    let hl = |out: &mut String, y: f64| {
        let _ = writeln!(out, "n 0 {} m {} {} l S", fp(y), fp(w), fp(y));
    };
    let vl = |out: &mut String, x: f64, y0: f64, y1: f64| {
        let _ = writeln!(out, "n {} {} m {} {} l S", fp(x), fp(y0), fp(x), fp(y1));
    };
    let verticais = |out: &mut String, y0: f64, y1: f64| {
        let mut x = 0.0;
        for cw in larguras.iter().take(larguras.len().saturating_sub(1)) {
            x += cw;
            vl(out, x, y0, y1);
        }
    };
    hl(out, h);
    if parte > 0 {
        let corpo = h - linhas[0].1;
        vl(out, 0.0, corpo, h);
        vl(out, 0.0, 0.0, corpo);
        vl(out, w, corpo, h);
        vl(out, w, 0.0, corpo);
        if partida {
            if parte == 1 {
                hl(out, corpo);
                verticais(out, corpo, h);
            } else {
                verticais(out, corpo, h);
                hl(out, corpo);
            }
            hl(out, 0.0);
        } else {
            // Última parte: na primeira continuação a linha sob o cabeçalho ainda vem antes
            // das verticais dele (LINEABOVE herdado da divisão); daí em diante vem depois.
            hl(out, 0.0);
            if parte == 1 {
                hl(out, corpo);
                verticais(out, corpo, h);
            } else {
                verticais(out, corpo, h);
                hl(out, corpo);
            }
        }
        let mut y = corpo;
        for (_, hr, _, _) in linhas.iter().skip(1).take(linhas.len().saturating_sub(2)) {
            y -= hr;
            hl(out, y);
        }
        verticais(out, 0.0, corpo);
    } else {
        if !partida {
            hl(out, 0.0);
        }
        vl(out, 0.0, 0.0, h);
        vl(out, w, 0.0, h);
        if partida {
            hl(out, 0.0);
        }
        let mut y = h;
        for (_, hr, _, _) in linhas.iter().take(linhas.len().saturating_sub(1)) {
            y -= hr;
            hl(out, y);
        }
        verticais(out, 0.0, h);
    }
    out.push_str("Q Q\n");
    Ok(topo + h)
}

pub fn gerar(
    cab: &[&str],
    linhas: &[Vec<String>],
    larguras: &[f64],
    topo: &[(String, String)],
    wrap: &[usize],
    titulo: &str,
    cancelar: &dyn Fn() -> bool,
) -> Res<Vec<u8>> {
    let cancel = || {
        if cancelar() {
            Err(Erro::novo("ExportCancelled", ""))
        } else {
            Ok(())
        }
    };
    cancel()?;
    let mut paginas = Vec::new();
    let mut out = String::new();
    let mut y = MARGEM;
    for (t, estilo) in topo {
        if estilo == "espaco" {
            y += t.parse::<f64>().unwrap_or(0.0);
            continue;
        }
        let (tam, leading, fonte, cor) = match estilo.as_str() {
            "titulo" => (12.0, 14.0, "F2", "0 0 0"),
            "obs" => (8.0, 10.0, "F3", ".380392 .380392 .380392"),
            _ => (9.0, 12.0, "F1", "0 0 0"),
        };
        let ls = quebrar(t, W - 20.0 * K - 12.0, tam, estilo == "titulo");
        let altura = ls.len() as f64 * leading;
        if y + altura > H - MARGEM {
            paginas.push(std::mem::take(&mut out));
            y = MARGEM;
        }
        let _ = writeln!(
            out,
            "q 1 0 0 1 {} {} cm",
            fp(10.0 * K + 6.0),
            fp(H - y - altura)
        );
        for (i, t) in ls.iter().enumerate() {
            texto(
                &mut out,
                0.0,
                altura - tam - i as f64 * leading,
                t,
                tam,
                fonte,
                cor,
                espaco(t, W - 20.0 * K - 12.0, tam, estilo == "titulo"),
            )?;
        }
        out.push_str("Q\n");
        y += altura;
    }
    y += 6.0;
    let cab = celulas(
        &cab.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        larguras,
        wrap,
        true,
    );
    let hc = altura(&cab);
    let cs = linhas
        .iter()
        .map(|l| {
            let c = celulas(l, larguras, wrap, false);
            let h = altura(&c);
            (c, h)
        })
        .collect::<Vec<_>>();
    let mut i = 0;
    let mut parte = 0;
    loop {
        cancel()?;
        let mut lote = vec![(cab.clone(), hc, true, 0)];
        let mut h = hc;
        while i < cs.len() && y + h + cs[i].1 <= H - MARGEM + 0.00001 {
            lote.push((cs[i].0.clone(), cs[i].1, false, i));
            h += cs[i].1;
            i += 1;
        }
        if lote.len() == 1 && i < cs.len() {
            if y > MARGEM + 0.00001 {
                paginas.push(std::mem::take(&mut out));
                y = MARGEM;
                continue;
            }
            return Err(Erro::novo(
                "LayoutError",
                "Uma linha do relatório excede a altura da página.",
            ));
        }
        tabela(&mut out, &lote, larguras, y, parte, i < cs.len())?;
        parte += 1;
        paginas.push(std::mem::take(&mut out));
        if i >= cs.len() {
            break;
        }
        y = MARGEM;
    }
    finalizar(&paginas, titulo)
}

fn finalizar(paginas: &[String], titulo: &str) -> Res<Vec<u8>> {
    let mut objetos=vec![b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),Vec::new(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".to_vec(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>".to_vec(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >>".to_vec(),
        format!("<< /Title <feff{}> /Producer (Baiacu NFS-e) >>",hex::encode(titulo.encode_utf16().flat_map(u16::to_be_bytes).collect::<Vec<_>>())).into_bytes()];
    let mut kids = Vec::new();
    for pagina in paginas {
        let id = objetos.len() + 1;
        kids.push(format!("{id} 0 R"));
        objetos.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {} {}] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents {} 0 R >>",fp(W),fp(H),id+1).into_bytes());
        let mut compressor = ZlibEncoder::new(Vec::new(), Compression::default());
        compressor.write_all(pagina.as_bytes())?;
        let bytes = compressor.finish()?;
        let mut stream = format!(
            "<< /Filter /FlateDecode /Length {} >>\nstream\n",
            bytes.len()
        )
        .into_bytes();
        stream.extend(bytes);
        stream.extend(b"\nendstream");
        objetos.push(stream);
    }
    objetos[1] = format!(
        "<< /Type /Pages /Kids [{}] /Count {} >>",
        kids.join(" "),
        kids.len()
    )
    .into_bytes();
    let mut pdf = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n".to_vec();
    let mut offsets = Vec::new();
    for (i, obj) in objetos.iter().enumerate() {
        offsets.push(pdf.len());
        pdf.extend(format!("{} 0 obj\n", i + 1).as_bytes());
        pdf.extend(obj);
        pdf.extend(b"\nendobj\n");
    }
    let inicio = pdf.len();
    pdf.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objetos.len() + 1).as_bytes());
    for pos in offsets {
        pdf.extend(format!("{pos:010} 00000 n \n").as_bytes());
    }
    pdf.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R /Info 6 0 R >>\nstartxref\n{inicio}\n%%EOF\n",
            objetos.len() + 1
        )
        .as_bytes(),
    );
    Ok(pdf)
}
