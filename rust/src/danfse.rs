//! DANFSe v2.0 local, portada da BrazilFiscalReport usada no Python (LGPL-3.0).
//! Ver recursos/danfse/ORIGEM.md para a origem dos textos e das medidas.
use std::sync::OnceLock;

use serde_json::Value;

use crate::danfse_dados::{self, dominios};
use crate::erro::Res;
use crate::pdf::{self, ALTURA, LARGURA, Pagina};

const LINHA: f64 = 6.4;
const FAIXA: f64 = 3.4;
const BX: f64 = 3.0;
const BW: f64 = LARGURA - 6.0;
const COL: f64 = BW / 4.0;

fn campos() -> &'static Value {
    static C: OnceLock<Value> = OnceLock::new();
    C.get_or_init(|| {
        serde_json::from_str(include_str!("../recursos/danfse/campos.json")).unwrap_or(Value::Null)
    })
}

/// Inicializa somente recursos fixos antes da primeira DANFSe.
pub fn aquecer() {
    campos();
    danfse_dados::aquecer();
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

struct Desenho {
    pagina: Pagina,
    dados: Value,
    y: f64,
}

impl Desenho {
    fn sombra(&mut self, x: f64, y: f64, w: f64, h: f64) {
        self.pagina
            .retangulo(x, y + 0.15, w, h - 0.15, Some(242), 0.0);
    }

    fn horizontal(&mut self) {
        self.pagina.linha(BX, self.y, BX + BW, self.y, 0.176);
    }

    fn titulo(&mut self, t: &str) {
        self.sombra(BX, self.y, COL, LINHA);
        self.pagina.celula(
            BX + 0.8,
            self.y,
            COL - 1.6,
            LINHA,
            t,
            7.0,
            true,
            false,
            false,
        );
    }

    fn campo(
        &mut self,
        col: usize,
        span: usize,
        rotulo: &str,
        valor: &str,
        sombra: bool,
        id: bool,
    ) {
        let x = BX + col as f64 * COL;
        let w = span as f64 * COL;
        if sombra {
            self.sombra(x, self.y, w, if id { 6.9 } else { LINHA });
        }
        let (tam, dy, hr, dyv, hv) = if id {
            (7.0, 0.6, 2.4, 3.6, 2.8)
        } else {
            (6.0, 0.5, 2.2, 3.0, 2.6)
        };
        let rotulo = pdf::cortar(rotulo, w - 1.6, tam, true);
        let valor = pdf::cortar(
            if valor.is_empty() { "-" } else { valor },
            w - 1.6,
            7.0,
            false,
        );
        self.pagina.celula(
            x + 0.8,
            self.y + dy,
            w - 1.6,
            hr,
            &rotulo,
            tam,
            true,
            false,
            false,
        );
        self.pagina.celula(
            x + 0.8,
            self.y + dyv,
            w - 1.6,
            hv,
            &valor,
            7.0,
            false,
            false,
            false,
        );
    }

    fn faixa(&mut self, t: &str) {
        self.pagina
            .celula(BX, self.y, BW, FAIXA, t, 7.0, true, true, false);
        self.y += FAIXA;
        self.horizontal();
    }

    fn grupo(&mut self, nome: &str) {
        let campos = campos();
        let v = self.dados[nome].clone();
        let mut ativo = true;
        if let Some(comandos) = campos[nome].as_array() {
            for c in comandos {
                match c[0].as_str().unwrap_or("") {
                    "se" => ativo = v[c[1].as_str().unwrap_or("")].as_bool().unwrap_or(false),
                    "fim_se" => ativo = true,
                    "titulo" if ativo => self.titulo(c[1].as_str().unwrap_or("")),
                    "linha" if ativo => self.y += LINHA,
                    "campo" if ativo => self.campo(
                        c[1].as_u64().unwrap_or(0) as usize,
                        c[2].as_u64().unwrap_or(1) as usize,
                        c[3].as_str().unwrap_or(""),
                        s(&v, c[4].as_str().unwrap_or("")),
                        c[5].as_bool().unwrap_or(false),
                        false,
                    ),
                    _ => {}
                }
            }
        }
        self.horizontal();
    }

    fn pessoa(&mut self, nome: &str, titulo: &str, inscricao: bool, vazio: &str) {
        let p = self.dados[nome].clone();
        if p.is_null() {
            self.faixa(dominios()[vazio].as_str().unwrap_or(""));
            return;
        }
        self.titulo(titulo);
        self.campo(1, 1, "CNPJ / CPF / NIF", s(&p, "id"), false, false);
        if inscricao {
            self.campo(
                2,
                1,
                "Indicador Municipal (Inscrição)",
                s(&p, "municipal_registration"),
                false,
                false,
            );
        }
        self.campo(3, 1, "Telefone", s(&p, "phone"), false, false);
        self.y += LINHA;
        self.campo(0, 2, "Nome / Nome Empresarial", s(&p, "name"), false, false);
        self.campo(2, 1, "Município / Sigla UF", s(&p, "city"), false, false);
        self.campo(3, 1, "Código IBGE / CEP", s(&p, "ibge_cep"), false, false);
        self.y += LINHA;
        self.campo(0, 2, "Endereço", s(&p, "address"), false, false);
        self.campo(2, 2, "E-mail", s(&p, "email"), false, false);
        self.y += LINHA;
        self.horizontal();
    }

    fn cabecalho(&mut self) {
        self.y = 3.0;
        self.sombra(BX, self.y, BW, 11.6);
        self.pagina.logo(BX + 2.0, self.y + 1.8, 8.0);
        self.pagina.varias(
            BX + COL,
            self.y + 1.6,
            COL * 2.0,
            3.6,
            "DANFSe v2.0\nDocumento Auxiliar da NFS-e",
            9.0,
            true,
            true,
        );
        if s(&self.dados, "environment") == "2" {
            self.pagina.celula(
                BX + COL,
                self.y + 8.8,
                COL * 2.0,
                2.6,
                dominios()["TXT_NO_LEGAL_VALIDITY"].as_str().unwrap_or(""),
                9.0,
                true,
                true,
                true,
            );
        }
        let cab = &self.dados["header"];
        let x = BX + 3.0 * COL + 0.8;
        let w = COL - 1.6;
        if !s(cab, "city").is_empty() {
            self.pagina.celula(
                x,
                self.y + 1.2,
                w,
                3.0,
                &pdf::cortar(&format!("Município: {}", s(cab, "city")), w, 8.0, false),
                8.0,
                false,
                false,
                false,
            );
        }
        self.pagina.celula(
            x,
            self.y + 6.4,
            w,
            2.2,
            &format!("Ambiente Gerador: {}", s(cab, "amb_ger")),
            6.0,
            false,
            false,
            false,
        );
        self.pagina.celula(
            x,
            self.y + 9.0,
            w,
            2.2,
            &format!("Tipo de Ambiente: {}", s(cab, "tp_amb")),
            6.0,
            false,
            false,
            false,
        );
        self.y += 11.6;
        self.horizontal();
    }

    fn identificacao(&mut self) -> Res<()> {
        let d = self.dados.clone();
        let y0 = self.y;
        self.pagina.celula(
            BX + 0.8,
            y0 + 0.8,
            COL * 3.0,
            2.4,
            "CHAVE DE ACESSO DA NFS-e",
            7.0,
            true,
            false,
            false,
        );
        self.pagina.celula(
            BX + 0.8,
            y0 + 3.8,
            COL * 3.0,
            2.8,
            s(&d, "key_nfse"),
            7.0,
            false,
            false,
            false,
        );
        self.y = y0 + 7.9;
        self.campo(0, 1, "NÚMERO DA NFS-e", s(&d, "nfse_number"), false, true);
        self.campo(
            1,
            1,
            "COMPETÊNCIA DA NFS-e",
            s(&d, "compet_fmt"),
            false,
            true,
        );
        self.campo(
            2,
            1,
            "DATA E HORA DA EMISSÃO DA NFS-e",
            format!("{} {}", s(&d, "dt_nfse"), s(&d, "hr_nfse")).trim(),
            false,
            true,
        );
        self.y += 6.9;
        self.campo(0, 1, "NÚMERO DA DPS", s(&d, "dps_number"), false, true);
        self.campo(1, 1, "SÉRIE DA DPS", s(&d, "dps_serie"), false, true);
        self.campo(
            2,
            1,
            "DATA E HORA DA EMISSÃO DA DPS",
            format!("{} {}", s(&d, "dt_dps"), s(&d, "hr_dps")).trim(),
            false,
            true,
        );
        self.y += 6.9;
        self.campo(0, 1, "EMITENTE DA NFS-e", s(&d, "emitter_type"), true, true);
        self.campo(1, 1, "SITUAÇÃO DA NFS-e", s(&d, "status"), false, true);
        self.campo(2, 1, "FINALIDADE", s(&d, "purpose"), false, true);
        let url = format!(
            "https://www.nfse.gov.br/ConsultaPublica/?tpc=1&chave={}",
            s(&d, "key_nfse")
        );
        let (largura, matriz) = crate::qr_danfse::gerar(&url)?;
        self.pagina.qr(&matriz, largura)?;
        self.pagina.varias(
            158.0,
            34.3,
            49.0,
            2.1,
            dominios()["TXT_QR_CODE"].as_str().unwrap_or(""),
            6.0,
            false,
            false,
        );
        self.y += 6.9;
        self.horizontal();
        Ok(())
    }

    fn servico(&mut self) {
        let v = self.dados["service"].clone();
        self.titulo("SERVIÇO PRESTADO");
        self.campo(
            1,
            1,
            "Código de Tributação Nacional / Municipal",
            s(&v, "tax_code"),
            false,
            false,
        );
        self.campo(2, 1, "Código da NBS", s(&v, "nbs"), false, false);
        self.campo(
            3,
            1,
            "Local da Prestação / Sigla UF / País",
            s(&v, "place_of_provision"),
            false,
            false,
        );
        self.y += LINHA;
        self.pagina.celula(
            BX + 0.8,
            self.y + 0.5,
            BW - 1.6,
            2.8,
            &pdf::cortar(
                if s(&v, "tax_code_description").is_empty() {
                    "-"
                } else {
                    s(&v, "tax_code_description")
                },
                BW - 1.6,
                7.0,
                false,
            ),
            7.0,
            false,
            false,
            false,
        );
        self.y += 3.8;
        self.pagina.celula(
            BX + 0.8,
            self.y + 0.5,
            BW - 1.6,
            2.2,
            "Descrição do Serviço",
            6.0,
            true,
            false,
            false,
        );
        let mun = if self.dados["municipal_taxes"]["suppressed"]
            .as_bool()
            .unwrap_or(false)
        {
            FAIXA
        } else {
            4.0 * LINHA
        };
        let fed = LINHA
            + if self.dados["federal_taxes"]["show_pis_cofins"]
                .as_bool()
                .unwrap_or(false)
            {
                LINHA
            } else {
                0.0
            };
        let reservado = mun + fed + 6.0 * LINHA + FAIXA + 0.5 + 6.0 + 1.0;
        let maximo = ((ALTURA - 2.0 - reservado - (self.y + 3.0)) / 2.6)
            .floor()
            .max(1.0) as usize;
        let mut ls = pdf::linhas(s(&v, "description"), BW - 1.6, 7.0, false);
        if ls.len() > maximo {
            ls.truncate(maximo);
            if let Some(ultima) = ls.last_mut() {
                *ultima = format!(
                    "{}...",
                    ultima
                        .chars()
                        .take(ultima.chars().count().saturating_sub(4))
                        .collect::<String>()
                );
            }
        }
        let fim = self.pagina.varias(
            BX + 0.8,
            self.y + 3.0,
            BW - 1.6,
            2.6,
            &ls.join("\n"),
            7.0,
            false,
            false,
        );
        self.y = fim.max(self.y + 5.6) + 0.6;
        self.horizontal();
    }

    fn complementos(&mut self) {
        self.pagina.celula(
            BX + 0.8,
            self.y,
            BW - 1.6,
            FAIXA + 0.5,
            "INFORMAÇÕES COMPLEMENTARES",
            7.0,
            true,
            false,
            false,
        );
        self.y += FAIXA + 0.5;
        let info = &self.dados["complementary_info"];
        let variavel = info["segments"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" | ")
            })
            .unwrap_or_default();
        let aprox = s(info, "approx_taxes");
        let maximo = ((ALTURA - 2.0 - self.y - 1.0) / 2.6).floor().max(1.0) as usize;
        let mut limite = 1997;
        let texto = loop {
            let var = if variavel.chars().count() > limite {
                format!("{}...", variavel.chars().take(limite).collect::<String>())
            } else {
                variavel.clone()
            };
            let texto = if var.is_empty() {
                aprox.to_string()
            } else {
                format!("{var} | {aprox}")
            };
            if pdf::linhas(&texto, BW - 1.6, 7.0, false).len() <= maximo || limite <= 100 {
                break texto;
            }
            limite = limite.saturating_sub(200).max(100);
        };
        self.pagina.varias(
            BX + 0.8,
            self.y + 0.5,
            BW - 1.6,
            2.6,
            &texto,
            7.0,
            false,
            false,
        );
    }
}

/// PDF da nota autorizada; cancelada tem precedência sobre substituída.
pub fn gerar(xml: &[u8], cancelada: bool, substituida: bool) -> Res<Vec<u8>> {
    let mut d = Desenho {
        pagina: Pagina::nova(),
        dados: danfse_dados::ler(xml)?,
        y: 3.0,
    };
    d.cabecalho();
    d.identificacao()?;
    d.grupo("issuer");
    d.pessoa(
        "taker",
        "TOMADOR / ADQUIRENTE",
        true,
        "TXT_TAKER_NOT_IDENTIFIED",
    );
    let semdest = if d.dados["taker"].is_null() {
        "TXT_DEST_NOT_IDENTIFIED"
    } else {
        "TXT_DEST_IS_TAKER"
    };
    d.pessoa("dest", "DESTINATÁRIO DA OPERAÇÃO", false, semdest);
    d.pessoa(
        "intermed",
        "INTERMEDIÁRIO DA OPERAÇÃO",
        true,
        "TXT_INTERM_NOT_IDENTIFIED",
    );
    d.servico();
    if d.dados["municipal_taxes"]["suppressed"]
        .as_bool()
        .unwrap_or(false)
    {
        d.faixa(dominios()["TXT_NO_ISSQN"].as_str().unwrap_or(""));
    } else {
        d.grupo("municipal_taxes");
    }
    d.grupo("federal_taxes");
    d.grupo("ibscbs");
    d.grupo("total_value");
    d.complementos();
    d.pagina
        .retangulo(2.0, 2.0, LARGURA - 4.0, ALTURA - 4.0, None, 0.353);
    if cancelada {
        d.pagina.marca("CANCELADA");
    } else if substituida {
        d.pagina.marca("SUBSTITUÍDA");
    }
    d.pagina.terminar()
}
