//! Apoio ao projeto (doação em cripto) e o agradecimento da primeira nota.
//!
//! Quem recebe fica em [`CARTEIRAS`]: a moeda, a rede e o endereço de cada carteira (as mesmas da
//! seção "Apoie o projeto" do README). O QR de cada endereço é gerado aqui mesmo, sem serviço externo.
//!
//! Sem lembretes: a janela de doação aparece sozinha UMA vez só, com os fogos, logo depois da
//! PRIMEIRA NFS-e emitida em produção. Depois disso, só quem abrir Configurações › Apoie este
//! projeto.
use qrcode::Color;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::erro::Res;
use crate::{banco, qr_danfse};

const CHAVE_META: &str = "doacao";

/// Nome do projeto, como aparece na janela de doação.
pub const PROJETO: &str = "Baiacu NFS-e";

/// Uma carteira: moeda, símbolo, rede, esquema do QR (vazio = só o endereço) e endereço.
pub struct Carteira {
    pub moeda: &'static str,
    pub simbolo: &'static str,
    pub rede: &'static str,
    pub esquema: &'static str,
    pub endereco: &'static str,
}

pub const CARTEIRAS: &[Carteira] = &[
    Carteira { moeda: "Bitcoin", simbolo: "BTC", rede: "Bitcoin", esquema: "bitcoin", endereco: "bc1qs4r3fpdmahvcm6pxd2r7ctn077ndxzqgn8ntvd" },
    Carteira { moeda: "Tron", simbolo: "TRX", rede: "Tron", esquema: "", endereco: "TV1YHohhftEayTmh1L63t5kCUqXgWt58K4" },
    Carteira { moeda: "Ethereum", simbolo: "ETH", rede: "Ethereum", esquema: "ethereum", endereco: "0xaB91d332f687D03EA45537A8c0fB0BcfedDf0fB1" },
    Carteira { moeda: "Solana", simbolo: "SOL", rede: "Solana", esquema: "solana", endereco: "CudVniUfVT5xtihXrDAa7wSr8m9wj416aeLTzD4MweKG" },
    Carteira { moeda: "BNB", simbolo: "BNB", rede: "BNB Smart Chain (BEP-20)", esquema: "", endereco: "0xaB91d332f687D03EA45537A8c0fB0BcfedDf0fB1" },
];

/// Matriz do QR Code: `n` módulos por lado e uma string de '1' (escuro) e '0', linha a linha.
pub fn qr(texto: &str) -> Res<Value> {
    let (n, modulos) = qr_danfse::gerar(texto)?;
    Ok(json!({
        "n": n,
        "modulos": modulos.iter().map(|c| if *c == Color::Dark { '1' } else { '0' }).collect::<String>(),
    }))
}

/// Tudo o que a janela de doação mostra.
pub fn info() -> Res<Value> {
    let mut cripto = Vec::new();
    for c in CARTEIRAS {
        let uri = if c.esquema.is_empty() {
            c.endereco.to_string()
        } else {
            format!("{}:{}", c.esquema, c.endereco)
        };
        cripto.push(json!({
            "moeda": c.moeda,
            "simbolo": c.simbolo,
            "rede": c.rede,
            "endereco": c.endereco,
            "qr": qr(&uri)?,
        }));
    }
    Ok(json!({
        "projeto": PROJETO,
        "cripto": cripto,
        "estado": estado()?,
    }))
}

// --------------------------------------------------------------------------------------------- //
// Agradecimento da primeira nota
// --------------------------------------------------------------------------------------------- //
/// Campos antigos (do lembrete de 30 dias) ficam no banco e são ignorados ao ler.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Estado {
    /// A janela da primeira emissão em produção já apareceu.
    pub primeira_mostrada: bool,
    /// NFS-e emitidas em produção.
    pub emissoes: u64,
}

fn ler() -> Res<Estado> {
    let t = banco::get_meta(CHAVE_META)?;
    if t.trim().is_empty() {
        return Ok(Estado::default());
    }
    Ok(serde_json::from_str(&t).unwrap_or_default())
}

fn gravar(e: &Estado) -> Res<()> {
    banco::set_meta(CHAVE_META, &serde_json::to_string(e)?)
}

pub fn estado() -> Res<Value> {
    Ok(serde_json::to_value(ler()?)?)
}

/// Conta a emissão e diz se é a hora da janela: só na primeira em produção, e uma vez só.
pub fn registrar_emissao(e: &mut Estado, producao: bool) -> bool {
    if !producao {
        return false;
    }
    e.emissoes += 1;
    let mostrar = !e.primeira_mostrada;
    e.primeira_mostrada = true;
    mostrar
}

/// Chamado depois de cada NFS-e emitida.
pub fn apos_emissao(producao: bool) -> Res<bool> {
    if !producao {
        return Ok(false);
    }
    let mut e = ler()?;
    let mostrar = registrar_emissao(&mut e, producao);
    gravar(&e)?;
    Ok(mostrar)
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn so_a_primeira_nota_em_producao() {
        let mut e = Estado::default();
        assert!(!registrar_emissao(&mut e, false)); // homologação não conta
        assert!(registrar_emissao(&mut e, true)); // primeira em produção: mostra
        assert!(!registrar_emissao(&mut e, true)); // depois, nunca mais
        assert!(!registrar_emissao(&mut e, true));
        assert_eq!(e.emissoes, 3);
    }

    #[test]
    fn estado_antigo_continua_lendo() {
        let antigo = r#"{"lembrete":false,"primeira_mostrada":true,"ultimo":"2026-12-01","adiado_ate":"","apoiou_em":"","emissoes":5}"#;
        let e: Estado = serde_json::from_str(antigo).unwrap();
        assert_eq!(e, Estado { primeira_mostrada: true, emissoes: 5 });
    }
}
