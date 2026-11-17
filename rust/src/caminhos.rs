//! Raiz gravável dos bancos e logs. Recursos distribuídos são resolvidos por `programa()`.
//!
//! Instalação: ProgramData; portátil: pasta do executável. Em desenvolvimento: pasta informada em
//! `definir_raiz()` (a tela passa a raiz do projeto).
//!
//! A raiz não pode mudar de forma: o banco usa o caminho RELATIVO a ela como CHAVE das tabelas
//! `config` e `contador` (ex.: "pessoas/prestador/123/config_tomador.ini" — só um nome de
//! chave; a pasta pessoas/ não existe em disco).
use std::path::{Component, Path, PathBuf};
use std::sync::RwLock;

static PROGRAMA: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

#[cfg(windows)]
pub(crate) fn definir_programa(pasta: PathBuf) {
    let _ = PROGRAMA.set(pasta);
}

static RAIZ: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Define a raiz. Chamar uma vez, antes de qualquer outra coisa do núcleo.
pub fn definir_raiz(raiz: impl AsRef<Path>) {
    *RAIZ.write().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(normalizar(raiz.as_ref()));
}

/// A raiz gravável. Sem `definir_raiz()`, a pasta do executável.
pub fn raiz() -> PathBuf {
    if let Some(r) = RAIZ.read().unwrap_or_else(std::sync::PoisonError::into_inner).as_ref() {
        return r.clone();
    }
    let padrao = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."));
    normalizar(&padrao)
}

/// Caminho de um recurso somente-leitura (configs/, assets/) sob a pasta do programa.
pub fn recurso(partes: &[&str]) -> PathBuf {
    let mut p = programa();
    for parte in partes {
        p.push(parte);
    }
    p
}

/// Recursos ficam junto do executável instalado; no desenvolvimento, na raiz informada.
pub fn programa() -> PathBuf {
    if let Some(pasta) = PROGRAMA.get() {
        return pasta.clone();
    }
    let exe = std::env::current_exe().unwrap_or_default();
    if exe.file_name().is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case("Baiacu NFS-e.exe")) {
        exe.parent().unwrap_or(Path::new(".")).to_path_buf()
    } else { raiz() }
}

pub fn instalado_compartilhado() -> bool { programa().join("installed.marker").is_file() }

/// Absoluto e sem "." / "..", SEM tocar no disco (o `Path.resolve()` do Python para caminhos
/// que podem não existir).
pub fn normalizar(p: &Path) -> PathBuf {
    let abs = if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir().unwrap_or_default().join(p)
    };
    let mut out = PathBuf::new();
    for c in abs.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            outro => out.push(outro.as_os_str()),
        }
    }
    out
}

/// Chave lógica de um arquivo: caminho relativo à raiz, com '/'. (Um caminho fora da raiz
/// vira o absoluto com '/' — não acontece no programa.)
pub fn chave_logica(caminho: &str) -> String {
    let limpo = caminho.replace('\\', "/");
    let p = Path::new(&limpo);
    let abs = if p.is_absolute() {
        normalizar(p)
    } else {
        normalizar(&raiz().join(p))
    };
    let raiz = raiz();
    match abs.strip_prefix(&raiz) {
        Ok(rel) => rel.to_string_lossy().replace('\\', "/"),
        Err(_) => abs.to_string_lossy().replace('\\', "/"),
    }
}

/// Caminho absoluto de um caminho que pode vir relativo à raiz.
pub fn absoluto(caminho: &str) -> PathBuf {
    let limpo = caminho.replace('\\', "/");
    let p = Path::new(&limpo);
    if p.is_absolute() {
        p.to_path_buf()
    } else if limpo.starts_with("configs/") || limpo.starts_with("bin/") || limpo.starts_with("docs/") {
        programa().join(p)
    } else {
        raiz().join(p)
    }
}

/// Executa operações em arquivos escolhidos pelo operador com a identidade dele.
pub(crate) fn arquivo_usuario<T, E: From<std::io::Error>>(
    acao: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    #[cfg(windows)]
    return crate::dados_windows::arquivo_usuario(acao);
    #[cfg(not(windows))]
    acao()
}

pub(crate) fn temporarios_usuario() -> PathBuf {
    #[cfg(windows)]
    if let Some(pasta) = crate::dados_windows::temporarios_usuario() {
        return pasta;
    }
    std::env::temp_dir()
}
