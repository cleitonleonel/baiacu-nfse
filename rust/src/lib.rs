//! Núcleo do Baiacu NFS-e: as regras do programa (banco cifrado, cadastros, emissão, Cofre…),
//! sem tela. A tela (Flutter) entra pelo `ffi`.
pub mod ajuda;
pub mod aparencia;
pub mod assinatura;
pub mod atualizacao;
pub mod backup;
pub mod banco;
pub mod busca;
pub mod cadastro;
pub mod caminhos;
#[cfg(windows)]
pub mod dados_windows;
pub mod catalogo;
pub mod certificado;
pub mod chaves;
pub mod clientes_planilha;
pub mod cofre;
pub mod config_dps;
pub mod consulta;
pub mod correio;
pub mod danfse;
pub mod danfse_dados;
pub mod despacho;
pub mod despacho_cadastro;
pub mod despacho_cofre;
pub mod despacho_correio;
pub mod despacho_diversos;
pub mod despacho_emissao;
pub mod despacho_exportacao;
pub mod doacao;
pub mod dps_xml;
pub mod email_delta;
pub mod emissao;
pub mod erro;
pub mod exportacao;
pub mod ffi;
pub mod html_preview;
pub mod ini;
pub mod jsonpy;
pub mod leiaute;
pub mod lotes;
pub mod leitor_pdf;
pub mod pdf;
pub mod planilha;
pub mod pyfmt;
pub mod qr_danfse;
pub mod rede;
pub mod rede_tls;
pub mod registro;
pub mod registros;
pub mod relatorio_pdf;
pub mod resumo_dps;
pub mod segredos;
pub mod texto;
pub mod usuarios;
pub mod permissoes;
pub mod validacao;
pub mod vencimento;
pub mod xml;
pub mod xsd;

pub fn versao() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
