//! Desenho PDF local com fontes core; coordenadas em mm como no gerador de referência.
//! Medidas Helvetica derivadas de fpdf2, LGPL-3.0 (recursos/danfse/ORIGEM.md).
use flate2::Compression;
use flate2::write::ZlibEncoder;
use std::fmt::Write;
use std::io::Write as IoWrite;

use crate::erro::{Erro, Res};

mod metricas {
    include!("../recursos/danfse/larguras.rs");
}

pub const K: f64 = 72.0 / 25.4;
pub const LARGURA: f64 = 595.28 / K;
pub const ALTURA: f64 = 841.89 / K;

pub(crate) fn cp1252(c: char) -> Option<u8> {
    if (c as u32) <= 255 {
        return Some(c as u8);
    }
    const EXT: &str = "€\u{0081}‚ƒ„…†‡ˆ‰Š‹Œ\u{008d}Ž\u{008f}\u{0090}‘’“”•–—˜™š›œ\u{009d}žŸ";
    EXT.chars().position(|x| x == c).map(|i| 128 + i as u8)
}

pub fn largura(texto: &str, tamanho: f64, negrito: bool) -> f64 {
    let tabela = if negrito {
        &metricas::NEGRITO
    } else {
        &metricas::NORMAL
    };
    texto
        .chars()
        .map(|c| tabela[cp1252(c).unwrap_or(b'?') as usize] as f64)
        .sum::<f64>()
        * tamanho
        / 1000.0
        / K
}

pub fn cortar(texto: &str, limite: f64, tamanho: f64, negrito: bool) -> String {
    if texto.is_empty() || limite <= 0.0 {
        return String::new();
    }
    let limite = limite - 2.0;
    if largura(texto, tamanho, negrito) <= limite {
        return texto.into();
    }
    let mut palavras: Vec<&str> = texto.split_whitespace().collect();
    while !palavras.is_empty()
        && largura(&format!("{}...", palavras.join(" ")), tamanho, negrito) > limite
    {
        palavras.pop();
    }
    if !palavras.is_empty() {
        return format!("{}...", palavras.join(" "));
    }
    let mut t = texto.to_string();
    while !t.is_empty() && largura(&format!("{t}..."), tamanho, negrito) > limite {
        t.pop();
    }
    if t.is_empty() { t } else { format!("{t}...") }
}

/// Quebra por palavras com as margens internas de 1 mm do FPDF.
pub fn linhas(texto: &str, largura_celula: f64, tamanho: f64, negrito: bool) -> Vec<String> {
    let limite = largura_celula - 2.0;
    let chars: Vec<char> = texto.replace('\r', "").chars().collect();
    let mut out = Vec::new();
    let mut inicio = 0;
    let mut i = 0;
    let mut espaco = None;
    let mut soma = 0.0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\n' {
            out.push(chars[inicio..i].iter().collect());
            i += 1;
            inicio = i;
            soma = 0.0;
            espaco = None;
            continue;
        }
        if c == ' ' {
            espaco = Some(i);
        }
        soma += largura(&c.to_string(), tamanho, negrito);
        if soma > limite {
            let fim = espaco
                .filter(|e| *e >= inicio)
                .unwrap_or_else(|| if i == inicio { i + 1 } else { i });
            out.push(chars[inicio..fim].iter().collect());
            i = if espaco == Some(fim) { fim + 1 } else { fim };
            inicio = i;
            soma = 0.0;
            espaco = None;
        } else {
            i += 1;
        }
    }
    if inicio < chars.len() || out.is_empty() {
        out.push(chars[inicio..].iter().collect());
    }
    out
}

pub struct Pagina {
    conteudo: String,
    erro: Option<Erro>,
    qr: Option<(usize, Vec<u8>)>,
}

impl Pagina {
    pub fn nova() -> Self {
        Self {
            conteudo: "2 J\n0.57 w\n0 G 0 g\n".into(),
            erro: None,
            qr: None,
        }
    }

    pub fn linha(&mut self, x1: f64, y1: f64, x2: f64, y2: f64, espessura: f64) {
        let _ = writeln!(
            self.conteudo,
            "{:.2} w {:.2} {:.2} m {:.2} {:.2} l S",
            espessura * K,
            x1 * K,
            (ALTURA - y1) * K,
            x2 * K,
            (ALTURA - y2) * K
        );
    }

    pub fn retangulo(&mut self, x: f64, y: f64, w: f64, h: f64, cinza: Option<u8>, espessura: f64) {
        if let Some(c) = cinza {
            let _ = writeln!(
                self.conteudo,
                "q {0:.3} {0:.3} {0:.3} rg {1:.2} {2:.2} {3:.2} {4:.2} re f Q",
                c as f64 / 255.0,
                x * K,
                (ALTURA - y) * K,
                w * K,
                -h * K
            );
        } else {
            let _ = writeln!(
                self.conteudo,
                "{:.2} w {:.2} {:.2} {:.2} {:.2} re S",
                espessura * K,
                x * K,
                (ALTURA - y) * K,
                w * K,
                -h * K
            );
        }
    }

    pub fn texto(&mut self, x: f64, y: f64, t: &str, tamanho: f64, negrito: bool, vermelho: bool) {
        let mut bytes = Vec::new();
        for c in t.chars() {
            match cp1252(c) {
                Some(b) => bytes.push(b),
                None => {
                    self.erro = Some(Erro::valor(format!(
                        "A fonte Helvetica da DANFSe não contém o caractere '{c}'."
                    )));
                    return;
                }
            }
        }
        let fonte = if negrito { "F2" } else { "F1" };
        let cor = if vermelho { "1 0 0 rg" } else { "0 g" };
        let _ = writeln!(
            self.conteudo,
            "q {cor} BT /{fonte} {tamanho:.2} Tf {:.2} {:.2} Td <{}> Tj ET Q",
            x * K,
            (ALTURA - y) * K,
            hex::encode(bytes)
        );
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "primitiva de desenho com as medidas do FPDF"
    )]
    pub fn celula(
        &mut self,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        t: &str,
        tamanho: f64,
        negrito: bool,
        centro: bool,
        vermelho: bool,
    ) {
        let dx = if centro {
            (w - largura(t, tamanho, negrito)) / 2.0
        } else {
            1.0
        };
        self.texto(
            x + dx,
            y + h / 2.0 + 0.3 * tamanho / K,
            t,
            tamanho,
            negrito,
            vermelho,
        );
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "primitiva de desenho com as medidas do FPDF"
    )]
    pub fn varias(
        &mut self,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        t: &str,
        tamanho: f64,
        negrito: bool,
        centro: bool,
    ) -> f64 {
        let ls = linhas(t, w, tamanho, negrito);
        for (i, linha) in ls.iter().enumerate() {
            self.celula(
                x,
                y + i as f64 * h,
                w,
                h,
                linha,
                tamanho,
                negrito,
                centro,
                false,
            );
        }
        y + ls.len() as f64 * h
    }

    pub fn logo(&mut self, x: f64, y: f64, h: f64) {
        let w = h * 1920.0 / 389.0;
        let _ = writeln!(
            self.conteudo,
            "q {:.2} 0 0 {:.2} {:.2} {:.2} cm /Logo Do Q",
            w * K,
            h * K,
            x * K,
            (ALTURA - y - h) * K
        );
    }

    pub fn marca(&mut self, t: &str) {
        let tamanho = 60.0;
        let w = largura(t, tamanho, false);
        let h = tamanho * 0.25;
        let x = (LARGURA - w) / 2.0;
        let y = (ALTURA + h) / 2.0;
        let cx = LARGURA * K / 2.0;
        let cy = ALTURA * K / 2.0;
        let angulo = 55.0_f64.to_radians();
        let (s, c) = angulo.sin_cos();
        let tx = cx - c * cx + s * cy;
        let ty = cy - s * cx - c * cy;
        let _ = writeln!(
            self.conteudo,
            "q /GS1 gs {c:.4} {s:.4} {:.4} {c:.4} {tx:.4} {ty:.4} cm",
            -s
        );
        self.texto(x, y, t, tamanho, false, false);
        self.conteudo.push_str("Q\n");
    }

    pub fn terminar(self) -> Res<Vec<u8>> {
        if let Some(e) = self.erro {
            return Err(e);
        }
        let stream = |cab: &str, bytes: &[u8]| {
            let mut obj = format!("<< {cab} /Length {} >>\nstream\n", bytes.len()).into_bytes();
            obj.extend_from_slice(bytes);
            obj.extend_from_slice(b"\nendstream");
            obj
        };
        let mut compressor = ZlibEncoder::new(Vec::new(), Compression::default());
        compressor.write_all(self.conteudo.as_bytes())?;
        let conteudo = compressor.finish()?;
        let mut objetos = vec![
            b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec(),
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> /XObject << /Logo 6 0 R /QR 11 0 R >> /ExtGState << /GS1 9 0 R >> >> /Contents 8 0 R >>".to_vec(),
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".to_vec(),
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>".to_vec(),
            stream("/Type /XObject /Subtype /Image /Width 1920 /Height 389 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 7 0 R", include_bytes!("../recursos/danfse/logo.rgb.z")),
            stream("/Type /XObject /Subtype /Image /Width 1920 /Height 389 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", include_bytes!("../recursos/danfse/logo.alfa.z")),
            stream("/Filter /FlateDecode", &conteudo),
            b"<< /Type /ExtGState /ca 0.35 /CA 0.35 >>".to_vec(),
            b"<< /Title (DANFSE) /Producer (Baiacu NFS-e) >>".to_vec(),
        ];
        if let Some((pixels, dados)) = self.qr {
            objetos.push(stream(&format!("/Type /XObject /Subtype /Image /Width {pixels} /Height {pixels} /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode"), &dados));
        } else {
            objetos.push(b"<< >>".to_vec());
        }
        let mut pdf = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n".to_vec();
        let mut offsets = Vec::new();
        for (i, obj) in objetos.iter().enumerate() {
            offsets.push(pdf.len());
            pdf.extend_from_slice(format!("{} 0 obj\n", i + 1).as_bytes());
            pdf.extend_from_slice(obj);
            pdf.extend_from_slice(b"\nendobj\n");
        }
        let xref = pdf.len();
        pdf.extend_from_slice(
            format!("xref\n0 {}\n0000000000 65535 f \n", objetos.len() + 1).as_bytes(),
        );
        for o in offsets {
            pdf.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
        }
        pdf.extend_from_slice(
            format!(
                "trailer\n<< /Size {} /Root 1 0 R /Info 10 0 R >>\nstartxref\n{xref}\n%%EOF\n",
                objetos.len() + 1
            )
            .as_bytes(),
        );
        Ok(pdf)
    }

    /// Bitmap com margem de dois módulos e escala 19, como o qrcode Python.
    pub fn qr(&mut self, matriz: &[qrcode::Color], modulos: usize) -> Res<()> {
        let pixels = (modulos + 4) * 19;
        let por_linha = pixels.div_ceil(8);
        let mut bytes = vec![255_u8; por_linha * pixels];
        for y in 0..pixels {
            for x in 0..pixels {
                let mx = x / 19;
                let my = y / 19;
                if mx >= 2
                    && my >= 2
                    && mx < modulos + 2
                    && my < modulos + 2
                    && matriz[(my - 2) * modulos + mx - 2] == qrcode::Color::Dark
                {
                    bytes[y * por_linha + x / 8] &= !(1 << (7 - x % 8));
                }
            }
        }
        let mut compressor = ZlibEncoder::new(Vec::new(), Compression::default());
        compressor.write_all(&bytes)?;
        self.qr = Some((pixels, compressor.finish()?));
        let _ = writeln!(
            self.conteudo,
            "q {:.2} 0 0 {:.2} {:.2} {:.2} cm /QR Do Q",
            19.0 * K,
            19.0 * K,
            173.87 * K,
            (ALTURA - 15.77 - 19.0) * K
        );
        Ok(())
    }
}
