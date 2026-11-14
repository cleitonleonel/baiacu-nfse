//! Aparência do programa: as duas cores que o usuário personaliza (Configurações >
//! Personalização).
//! - FUNDO: o que fica atrás de tudo (página, trilho lateral, barra do topo).
//! - CARTÕES: os painéis. As janelas, menus e listas suspensas saem dela, um degrau mais escuro
//!   cada — a mesma escada de superfícies do Material 3.
//!
//! As cores são sempre CLARAS e pouco saturadas: o texto do sistema é escuro e não acompanha a
//! personalização. Ficam em `meta` (chave ui.aparencia) dentro do banco — valem para a
//! instalação inteira e viajam junto no backup.
use serde_json::{Value, json};

use crate::banco;
use crate::erro::{Erro, Res};

/// O tema índigo "de fábrica" usa fundo #FBF8FF e cartões #F5F2FA; o padrão daqui é o mesmo
/// lilás, um ponto mais forte.
pub const NATIVO: (&str, &str) = ("#FBF8FF", "#F5F2FA");
pub const PADRAO: (&str, &str) = ("#F8F4FF", "#F1ECFA");
/// Limites do que se ACEITA (campo Código, banco): saturação máxima e brilho mínimo (HSV).
pub const INTENSIDADE_MAX: f64 = 0.40;
pub const CLARIDADE_MIN: f64 = 0.75;
/// Curso das BARRAS da tela: só a faixa dos tons suaves, para o arrasto não ser nervoso.
pub const CONTROLE_INTENSIDADE_MAX: f64 = 0.25;
pub const CONTROLE_CLARIDADE_MIN: f64 = 0.85;
const CHAVE: &str = "ui.aparencia";

fn hex(r: f64, g: f64, b: f64) -> String {
    let c = |x: f64| (x * 255.0).round_ties_even().clamp(0.0, 255.0) as u8;
    format!("#{:02X}{:02X}{:02X}", c(r), c(g), c(b))
}

pub fn de_hsv(matiz: f64, intensidade: f64, claridade: f64) -> String {
    let (h, s, v) = (
        matiz.rem_euclid(360.0) / 360.0,
        intensidade.clamp(0.0, 1.0),
        claridade.clamp(0.0, 1.0),
    );
    if s == 0.0 {
        return hex(v, v, v);
    }
    let i = (h * 6.0) as i64;
    let f = h * 6.0 - i as f64;
    let (p, q, t) = (v * (1.0 - s), v * (1.0 - s * f), v * (1.0 - s * (1.0 - f)));
    let (r, g, b) = match i.rem_euclid(6) {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    };
    hex(r, g, b)
}

/// (fundo, cartões) de um mesmo matiz; intensidade e claridade em %.
fn par(matiz: f64, s_fundo: f64, v_fundo: f64, s_cart: f64, v_cart: f64) -> (String, String) {
    (
        de_hsv(matiz, s_fundo / 100.0, v_fundo / 100.0),
        de_hsv(matiz, s_cart / 100.0, v_cart / 100.0),
    )
}

/// Temas prontos: (nome, fundo, cartões) — pares já harmonizados. Nos "suaves" os cartões são um
/// tom mais escuros que o fundo; nos "painel claro" é o contrário: fundo tingido e cartões quase
/// brancos.
pub fn temas() -> Vec<(String, String, String)> {
    let fixo = |nome: &str, f: &str, c: &str| (nome.to_string(), f.to_string(), c.to_string());
    let de = |nome: &str, p: (String, String)| (nome.to_string(), p.0, p.1);
    let ao_contrario = |nome: &str, p: (String, String)| (nome.to_string(), p.1, p.0);
    vec![
        fixo("Padrão", NATIVO.0, NATIVO.1),
        fixo("Lilás", PADRAO.0, PADRAO.1),
        fixo("Lilás suave", NATIVO.0, NATIVO.1),
        de("Lavanda", par(262.0, 7.0, 100.0, 9.5, 97.0)),
        de("Orquídea", par(300.0, 4.0, 99.5, 6.5, 96.5)),
        fixo("Rosa", "#FDF5F7", "#F6EAEE"),
        de("Coral", par(8.0, 4.5, 100.0, 7.5, 97.5)),
        de("Pêssego", par(25.0, 5.0, 100.0, 8.5, 97.5)),
        fixo("Areia", "#FAF6EE", "#F2ECDF"),
        de("Creme", par(50.0, 5.0, 99.5, 8.0, 96.5)),
        de("Papel", par(34.0, 8.0, 97.0, 11.5, 93.0)),
        de("Folha", par(95.0, 4.0, 98.5, 7.0, 95.5)),
        fixo("Sálvia", "#F3F8F3", "#E8F0E9"),
        de("Menta", par(155.0, 4.5, 98.5, 7.5, 95.5)),
        fixo("Água", "#F1F8F8", "#E5F0F0"),
        de("Turquesa", par(186.0, 5.5, 98.5, 9.0, 95.5)),
        de("Céu", par(205.0, 5.5, 100.0, 9.0, 97.0)),
        fixo("Gelo", "#F2F6FB", "#E8EEF6"),
        de("Azul", par(222.0, 6.0, 100.0, 9.5, 97.0)),
        de("Névoa", par(215.0, 2.5, 96.5, 4.0, 93.0)),
        de("Pérola", par(35.0, 1.8, 97.0, 3.0, 93.5)),
        fixo("Cinza", "#F6F6F7", "#ECECEE"),
        de("Prata", par(220.0, 1.5, 93.5, 2.5, 89.5)),
        fixo("Branco", "#FFFFFF", "#F5F5F6"),
        // painel claro: fundo tingido, cartões quase brancos
        ao_contrario("Lilás, painel claro", par(262.0, 1.6, 99.5, 6.5, 97.0)),
        ao_contrario("Gelo, painel claro", par(213.0, 1.4, 99.5, 6.0, 96.5)),
        ao_contrario("Sálvia, painel claro", par(127.0, 1.2, 99.0, 5.0, 95.5)),
        ao_contrario("Areia, painel claro", par(41.0, 1.6, 99.5, 8.0, 96.0)),
        ao_contrario("Cinza, painel claro", par(240.0, 0.3, 99.0, 0.8, 93.0)),
    ]
}

/// '#abc' / 'AABBCC' -> '#AABBCC'. Erro se não for um código de cor.
pub fn normalizar(cor: &str) -> Res<String> {
    let s = crate::texto::aparar(cor);
    let h = s.strip_prefix('#').unwrap_or(s);
    if !(h.len() == 6 || h.len() == 3) || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Erro::valor(
            "Código de cor inválido. Use o formato #RRGGBB (ex.: #F8F4FF).",
        ));
    }
    let h: String = if h.len() == 3 {
        h.chars().flat_map(|c| [c, c]).collect()
    } else {
        h.to_string()
    };
    Ok(format!("#{}", h.to_uppercase()))
}

fn rgb(cor: &str) -> Res<(u8, u8, u8)> {
    let h = normalizar(cor)?;
    let n = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).unwrap_or(0);
    Ok((n(1), n(3), n(5)))
}

/// (matiz 0–360, intensidade 0–1, claridade 0–1).
pub fn hsv(cor: &str) -> Res<(f64, f64, f64)> {
    let (r, g, b) = rgb(cor)?;
    let (r, g, b) = (r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0);
    let (maior, menor) = (r.max(g).max(b), r.min(g).min(b));
    let faixa = maior - menor;
    if menor == maior {
        return Ok((0.0, 0.0, maior));
    }
    let s = faixa / maior;
    let (rc, gc, bc) = (
        (maior - r) / faixa,
        (maior - g) / faixa,
        (maior - b) / faixa,
    );
    let h = if r == maior {
        bc - gc
    } else if g == maior {
        2.0 + rc - bc
    } else {
        4.0 + gc - rc
    };
    Ok(((h / 6.0).rem_euclid(1.0) * 360.0, s, maior))
}

/// Normaliza e confere se a cor serve de fundo para texto escuro.
pub fn validar(cor: &str) -> Res<String> {
    let cor = normalizar(cor)?;
    let (_, s, v) = hsv(&cor)?;
    // folga de 1 ponto: o arredondamento para 8 bits desloca S/V de leve
    if v < CLARIDADE_MIN - 0.01 || s > INTENSIDADE_MAX + 0.01 {
        return Err(Erro::valor(format!(
            "Cor escura ou forte demais para o texto do sistema. Use claridade de pelo menos {:.0}% e intensidade de até {:.0}%.",
            CLARIDADE_MIN * 100.0,
            INTENSIDADE_MAX * 100.0
        )));
    }
    Ok(cor)
}

pub fn escurecer(cor: &str, fator: f64) -> Res<String> {
    let (r, g, b) = rgb(cor)?;
    let c = |x: u8| (x as f64 * fator).round_ties_even().clamp(0.0, 255.0) as u8;
    Ok(format!("#{:02X}{:02X}{:02X}", c(r), c(g), c(b)))
}

/// Papéis de superfície do Material 3 para as duas cores. Os fatores reproduzem os degraus do
/// tema de fábrica (tons 96 > 94 > 92 > 90).
pub fn superficies(fundo: &str, cartoes: &str) -> Res<Value> {
    Ok(json!({
        "surface": fundo,                                           // página, trilho, topo
        "surface_container_low": cartoes,                           // cards
        "surface_container": escurecer(cartoes, 0.976)?,            // menus e listas suspensas
        "surface_container_high": escurecer(cartoes, 0.955)?,       // janelas (diálogos), calendário
        "surface_container_highest": escurecer(cartoes, 0.931)?,
    }))
}

/// Cores salvas (ou o padrão): (fundo, cartões). Nunca falha: aparência não pode impedir o
/// programa de abrir.
pub fn carregar() -> (String, String) {
    let padrao = (PADRAO.0.to_string(), PADRAO.1.to_string());
    let ler = || -> Res<(String, String)> {
        let texto = banco::get_meta(CHAVE)?;
        let salvo: Value = serde_json::from_str(if texto.is_empty() { "{}" } else { &texto })?;
        let de = |nome: &str, padrao: &str| -> Res<String> {
            match salvo
                .get(nome)
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
            {
                Some(v) => validar(v),
                None => Ok(padrao.to_string()),
            }
        };
        if !salvo.is_object() {
            return Err(Erro::valor("aparência ilegível"));
        }
        Ok((de("fundo", PADRAO.0)?, de("cartoes", PADRAO.1)?))
    };
    ler().unwrap_or(padrao)
}

pub fn salvar(fundo: &str, cartoes: &str) -> Res<(String, String)> {
    let cores = (validar(fundo)?, validar(cartoes)?);
    banco::set_meta(
        CHAVE,
        &crate::jsonpy::dumps(
            &json!({ "fundo": cores.0, "cartoes": cores.1 }),
            crate::jsonpy::Formato::PADRAO,
        ),
    )?;
    Ok(cores)
}
