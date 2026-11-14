//! Mesma segmentação e escolha de máscara do python-qrcode (BSD), sem Python em runtime.
//! Codificação e Reed-Solomon fornecidos pela crate qrcode.
use qrcode::bits::Bits;
use qrcode::canvas::{Canvas, MaskPattern};
use qrcode::{Color, EcLevel, Version};

use crate::erro::{Erro, Res};

fn partes(dados: &[u8], predicado: fn(u8) -> bool, modo: u8) -> Vec<(&[u8], u8)> {
    let mut out = Vec::new();
    let mut inicio = 0;
    let mut i = 0;
    while i < dados.len() {
        if !predicado(dados[i]) {
            i += 1;
            continue;
        }
        let comeco = i;
        while i < dados.len() && predicado(dados[i]) {
            i += 1;
        }
        if i - comeco >= 20 {
            if comeco > inicio {
                out.push((&dados[inicio..comeco], 4));
            }
            out.push((&dados[comeco..i], modo));
            inicio = i;
        }
    }
    if inicio < dados.len() {
        out.push((&dados[inicio..], 4));
    }
    out
}

fn penalidade(m: &[Color], n: usize) -> usize {
    let preto = |x: usize, y: usize| m[y * n + x] == Color::Dark;
    let mut pontos = 0;
    for vertical in [false, true] {
        for fixo in 0..n {
            let cor = |i| {
                if vertical {
                    preto(fixo, i)
                } else {
                    preto(i, fixo)
                }
            };
            let mut anterior = cor(0);
            let mut comprimento = 0;
            for i in 0..n {
                let atual = cor(i);
                if atual == anterior {
                    comprimento += 1;
                } else {
                    if comprimento >= 5 {
                        pontos += comprimento - 2;
                    }
                    anterior = atual;
                    comprimento = 1;
                }
            }
            if comprimento >= 5 {
                pontos += comprimento - 2;
            }
            for i in 0..n.saturating_sub(10) {
                let padrao: [bool; 11] = std::array::from_fn(|j| cor(i + j));
                if padrao
                    == [
                        true, false, true, true, true, false, true, false, false, false, false,
                    ]
                    || padrao
                        == [
                            false, false, false, false, true, false, true, true, true, false, true,
                        ]
                {
                    pontos += 40;
                }
            }
        }
    }
    for y in 0..n - 1 {
        for x in 0..n - 1 {
            let c = preto(x, y);
            if preto(x + 1, y) == c && preto(x, y + 1) == c && preto(x + 1, y + 1) == c {
                pontos += 3;
            }
        }
    }
    let escuros = m.iter().filter(|c| **c == Color::Dark).count();
    pontos + (((escuros as f64 / (n * n) as f64 * 100.0 - 50.0).abs() / 5.0) as usize) * 10
}

pub fn gerar(url: &str) -> Res<(usize, Vec<Color>)> {
    let mut segmentos = Vec::new();
    for (dados, modo) in partes(url.as_bytes(), |b| b.is_ascii_digit(), 1) {
        if modo == 1 {
            segmentos.push((dados, modo));
        } else {
            segmentos.extend(partes(
                dados,
                |b| b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".contains(&b),
                2,
            ));
        }
    }
    let mut encontrado = None;
    for numero in 1..=40 {
        let versao = Version::Normal(numero);
        let mut bits = Bits::new(versao);
        let tentativa = (|| {
            for (dados, modo) in &segmentos {
                match modo {
                    1 => bits.push_numeric_data(dados)?,
                    2 => bits.push_alphanumeric_data(dados)?,
                    _ => bits.push_byte_data(dados)?,
                }
            }
            bits.push_terminator(EcLevel::L)
        })();
        if tentativa.is_ok() {
            encontrado = Some((versao, bits));
            break;
        }
    }
    let (versao, bits) =
        encontrado.ok_or_else(|| Erro::valor("Dados grandes demais para o QR Code da DANFSe."))?;
    let n = versao.width() as usize;
    let (dados, ec) = qrcode::ec::construct_codewords(&bits.into_bytes(), versao, EcLevel::L)
        .map_err(|e| Erro::valor(e.to_string()))?;
    let mut base = Canvas::new(versao, EcLevel::L);
    base.draw_all_functional_patterns();
    base.draw_data(&dados, &ec);
    let mut menor = usize::MAX;
    let mut melhor = Vec::new();
    for mascara in [
        MaskPattern::Checkerboard,
        MaskPattern::HorizontalLines,
        MaskPattern::VerticalLines,
        MaskPattern::DiagonalLines,
        MaskPattern::LargeCheckerboard,
        MaskPattern::Fields,
        MaskPattern::Diamonds,
        MaskPattern::Meadow,
    ] {
        let mut canvas = base.clone();
        canvas.apply_mask(mascara);
        let final_ = canvas.into_colors();
        let mut teste = final_.clone();
        // makeImpl(test=True) do Python reserva os campos mas os deixa brancos
        // durante a pontuação; a versão final escreve os bits de formato reais.
        for i in 0..15 {
            let y = if i < 6 {
                i
            } else if i < 8 {
                i + 1
            } else {
                n - 15 + i
            };
            teste[y * n + 8] = Color::Light;
            let x = if i < 8 {
                n - i - 1
            } else if i < 9 {
                15 - i
            } else {
                15 - i - 1
            };
            teste[8 * n + x] = Color::Light;
        }
        teste[(n - 8) * n + 8] = Color::Light;
        if n >= 45 {
            for i in 0..18 {
                teste[(i / 3) * n + (i % 3 + n - 11)] = Color::Light;
                teste[(i % 3 + n - 11) * n + i / 3] = Color::Light;
            }
        }
        let p = penalidade(&teste, n);
        if p < menor {
            menor = p;
            melhor = final_;
        }
    }
    Ok((n, melhor))
}
