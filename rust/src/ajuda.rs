//! A janela "Ajuda": onde está o manual no disco e o contato de suporte.
//!
//! O manual vai DENTRO do pacote (docs/Manual-Baiacu-NFS-e.pdf, ao lado do .exe), então a
//! atualização automática também o renova. Em desenvolvimento, a raiz é o projeto, que tem o
//! mesmo docs/.
use serde_json::{Value, json};

use crate::caminhos;

/// E-mail de suporte, pedidos de melhoria e relato de erros.
pub const EMAIL: &str = "emissorbaiacu@gmail.com";

/// O manual, relativo à raiz do programa.
pub const MANUAL: &[&str] = &["docs", "Manual-Baiacu-NFS-e.pdf"];

pub fn info() -> Value {
    let manual = caminhos::recurso(MANUAL);
    json!({
        "manual": manual.display().to_string(),
        "manual_existe": manual.is_file(),
        "email": EMAIL,
        "versao": crate::atualizacao::VERSAO,
        "pagina_projeto": format!("https://github.com/{}", crate::atualizacao::REPOSITORIO),
    })
}
