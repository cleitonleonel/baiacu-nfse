//! Erro único do núcleo. O `tipo` espelha a classe de exceção que o programa em Python
//! levantava — é por ele que a tela decide o que fazer (ex.: "ValueError" é mensagem para o
//! usuário; "BancoTrancado" volta para a tela de acesso).
use std::fmt;

#[derive(Debug, Clone)]
pub struct Erro {
    pub tipo: &'static str,
    pub msg: String,
    /// O que mais o erro carrega para quem vai tratá-lo (ex.: a DPS assinada de um envio que
    /// não saiu, o corpo de uma rejeição da SEFIN).
    pub dados: Option<Box<serde_json::Value>>,
}

pub type Res<T> = Result<T, Erro>;

impl Erro {
    pub fn novo(tipo: &'static str, msg: impl Into<String>) -> Self {
        Erro {
            tipo,
            msg: msg.into(),
            dados: None,
        }
    }

    /// O mesmo erro, levando dados para quem vai tratá-lo.
    pub fn com_dados(mut self, dados: serde_json::Value) -> Self {
        self.dados = Some(Box::new(dados));
        self
    }

    /// Um dado que o erro carrega (Null se não há).
    pub fn dado(&self, nome: &str) -> &serde_json::Value {
        static NULO: serde_json::Value = serde_json::Value::Null;
        self.dados
            .as_ref()
            .and_then(|d| d.get(nome))
            .unwrap_or(&NULO)
    }

    /// Mensagem para o usuário (o `ValueError` do Python).
    pub fn valor(msg: impl Into<String>) -> Self {
        Erro::novo("ValueError", msg)
    }

    pub fn trancado(msg: impl Into<String>) -> Self {
        Erro::novo("BancoTrancado", msg)
    }

    pub fn senha_mestra(msg: impl Into<String>) -> Self {
        Erro::novo("SenhaMestraNecessaria", msg)
    }

    pub fn os(msg: impl Into<String>) -> Self {
        Erro::novo("OSError", msg)
    }

    /// Arquivo que não existe (é também um erro do sistema: ver `do_sistema`).
    pub fn nao_encontrado(msg: impl Into<String>) -> Self {
        Erro::novo("FileNotFoundError", msg)
    }

    /// É erro do sistema operacional (arquivo, disco, permissão)?
    pub fn do_sistema(&self) -> bool {
        matches!(
            self.tipo,
            "OSError" | "FileNotFoundError" | "PermissionError"
        )
    }

    pub fn runtime(msg: impl Into<String>) -> Self {
        Erro::novo("RuntimeError", msg)
    }
}

impl fmt::Display for Erro {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.msg)
    }
}

impl std::error::Error for Erro {}

/// Erro do SQLite em que o arquivo pode estar perfeito (ocupado, sem permissão, disco) — o
/// contrário de "não é um banco" / "estragado".
pub fn sqlite_operacional(e: &rusqlite::Error) -> bool {
    use rusqlite::ErrorCode as C;
    match e {
        rusqlite::Error::SqliteFailure(f, _) => !matches!(
            f.code,
            C::NotADatabase
                | C::DatabaseCorrupt
                | C::ConstraintViolation
                | C::TypeMismatch
                | C::TooBig
                | C::ApiMisuse
                | C::ParameterOutOfRange
                | C::InternalMalfunction
                | C::NotFound
                | C::OutOfMemory
        ),
        _ => false,
    }
}

/// A mensagem do SQLite, sem enfeite.
pub fn sqlite_msg(e: &rusqlite::Error) -> String {
    match e {
        rusqlite::Error::SqliteFailure(_, Some(m)) => m.clone(),
        outro => outro.to_string(),
    }
}

impl From<rusqlite::Error> for Erro {
    fn from(e: rusqlite::Error) -> Self {
        Erro::novo(
            if sqlite_operacional(&e) {
                "OperationalError"
            } else {
                "DatabaseError"
            },
            sqlite_msg(&e),
        )
    }
}

impl From<std::io::Error> for Erro {
    fn from(e: std::io::Error) -> Self {
        Erro::os(baiacu_atualizador::clarear_os(&e.to_string()))
    }
}

impl From<serde_json::Error> for Erro {
    fn from(e: serde_json::Error) -> Self {
        Erro::valor(e.to_string())
    }
}

/// `valor!("texto {x}")` — atalho de `Erro::valor(format!(...))`.
#[macro_export]
macro_rules! valor {
    ($($arg:tt)*) => { $crate::erro::Erro::valor(format!($($arg)*)) };
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn erros_do_windows_em_portugues_claro() {
        let e: Erro = std::io::Error::from_raw_os_error(5).into();
        assert_eq!(e.msg, "Acesso negado (os error 5)");
        let original = std::io::Error::from_raw_os_error(32).to_string();
        let msg = format!("Falha ao gravar o backup: {original}");
        assert_eq!(
            baiacu_atualizador::clarear_os(&msg),
            "Falha ao gravar o backup: O arquivo está em uso por outro programa (os error 32)"
        );
        // Código sem frase conhecida: a mensagem fica como está.
        let raro = std::io::Error::from_raw_os_error(4390).to_string();
        assert_eq!(baiacu_atualizador::clarear_os(&raro), raro);
        assert_eq!(baiacu_atualizador::clarear_os("sem código"), "sem código");
    }
}
