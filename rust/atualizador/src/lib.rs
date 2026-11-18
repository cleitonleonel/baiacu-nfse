//! Formato de release v1: Ed25519 assina os bytes exatos do manifesto (base64).
//! O manifesto vincula produto, versão, nome e SHA-256 do ZIP. Não é formato Minisign.
use base64::{Engine, engine::general_purpose::STANDARD};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::OnceLock,
};
#[cfg(windows)]
pub mod client;

// ------------------------------------------------------------------------------------------- //
// Erros do Windows em português claro
// ------------------------------------------------------------------------------------------- //
/// Frase clara para os códigos de erro do Windows que o usuário mais encontra.
pub fn frase_os(codigo: i32) -> Option<&'static str> {
    Some(match codigo {
        2 => "Arquivo não encontrado",
        3 => "Pasta não encontrada",
        5 => "Acesso negado",
        15 => "Unidade de disco não encontrada",
        19 => "O disco está protegido contra gravação",
        21 => "A unidade não está pronta",
        32 => "O arquivo está em uso por outro programa",
        33 => "Parte do arquivo está bloqueada por outro programa",
        39 | 112 => "Não há espaço suficiente no disco",
        53 => "Caminho de rede não encontrado",
        80 | 183 => "O arquivo ou a pasta já existe",
        109 | 232 | 233 => "A comunicação com o serviço de dados foi interrompida",
        123 => "Nome de arquivo ou pasta inválido",
        145 => "A pasta não está vazia",
        206 => "Nome ou caminho do arquivo longo demais",
        225 => "O antivírus bloqueou o arquivo",
        231 => "O serviço de dados está ocupado",
        1053 => "O serviço não respondeu a tempo",
        1060 => "O serviço não está instalado",
        1062 => "O serviço não está em execução",
        1224 => "O arquivo está aberto em outro programa",
        1392 => "O arquivo ou a pasta está corrompido",
        1450 | 1453 | 1455 => "Recursos do sistema insuficientes",
        10054 => "A conexão foi interrompida pelo servidor",
        10060 => "O servidor demorou demais para responder",
        10061 => "O servidor recusou a conexão",
        10065 => "Servidor inacessível (verifique a internet)",
        11001 => "Endereço não encontrado (verifique a internet)",
        _ => return None,
    })
}

/// Troca, dentro de uma mensagem, o texto do Windows de cada "(os error N)" conhecido pela frase
/// clara: "Falha ao gravar: O processo não pode acessar o arquivo porque ele está sendo usado
/// por outro processo. (os error 32)" → "Falha ao gravar: O arquivo está em uso por outro
/// programa (os error 32)". O código fica, para o suporte. Códigos desconhecidos ficam iguais.
pub fn clarear_os(msg: &str) -> String {
    let mut out = msg.to_string();
    let mut resto = msg;
    while let Some(i) = resto.find("(os error ") {
        let depois = &resto[i + 10..];
        let fim = depois.find(')').unwrap_or(0);
        if let Ok(codigo) = depois[..fim].parse::<i32>()
            && let Some(frase) = frase_os(codigo)
        {
            let original = std::io::Error::from_raw_os_error(codigo).to_string();
            out = out.replace(&original, &format!("{frase} (os error {codigo})"));
        }
        resto = &depois[fim.min(depois.len())..];
    }
    out
}

// ------------------------------------------------------------------------------------------- //
// Registro do atualizador (service/atualizador.log)
// ------------------------------------------------------------------------------------------- //
static LOG: OnceLock<PathBuf> = OnceLock::new();
/// Tamanho do registro antes de virar atualizador.log.1 (só uma cópia antiga é guardada).
const LOG_MAX: u64 = 1024 * 1024;

/// Liga o registro próprio do atualizador. Sem isto, `log` não grava nada (testes, --check).
pub fn definir_log(caminho: PathBuf) {
    let _ = LOG.set(caminho);
}

fn carimbo() -> String {
    #[cfg(windows)]
    {
        let mut t: windows_sys::Win32::Foundation::SYSTEMTIME = unsafe { std::mem::zeroed() };
        unsafe { windows_sys::Win32::System::SystemInformation::GetLocalTime(&mut t) };
        format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
            t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
        )
    }
    #[cfg(not(windows))]
    {
        let s = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        format!("unix {s}")
    }
}

/// Uma linha no registro do atualizador: cada etapa e, numa falha, o erro original. Melhor
/// esforço: um registro que não grava nunca impede a atualização.
pub fn log(msg: impl AsRef<str>) {
    let Some(caminho) = LOG.get() else { return };
    if fs::metadata(caminho).is_ok_and(|m| m.len() > LOG_MAX) {
        let _ = fs::rename(caminho, caminho.with_extension("log.1"));
    }
    let linha = format!(
        "{} | pid {} | {}\r\n",
        carimbo(),
        std::process::id(),
        msg.as_ref().replace(['\r', '\n'], " ")
    );
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(caminho)
    {
        let _ = f.write_all(linha.as_bytes());
    }
}

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
pub const SERVICE: &str = "BaiacuNFSeUpdate";
pub const EXE: &str = "Baiacu NFS-e.exe";
pub const REPO: &str = "williamlala/baiacu-nfse";
pub const PUBLIC_KEY: &str = include_str!("public-key.hex");
pub const MAX_ZIP: u64 = 512 * 1024 * 1024;
pub const MAX_EXPANDED: u64 = 2 * 1024 * 1024 * 1024;

#[derive(Serialize, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub product: String,
    pub version: String,
    pub file: String,
    pub sha256: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub payload: String,
    pub signature: String,
}

pub fn version(v: &str) -> Result<[u64; 4]> {
    let p: Vec<_> = v.split('.').collect();
    if !(3..=4).contains(&p.len())
        || p.iter()
            .any(|s| s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err("Versão inválida".into());
    }
    Ok([
        p[0].parse()?,
        p[1].parse()?,
        p[2].parse()?,
        if p.len() == 4 { p[3].parse()? } else { 0 },
    ])
}

pub fn verify(envelope: &[u8], key: &str, expected: &str) -> Result<Manifest> {
    if envelope.len() > 16384 {
        return Err("Assinatura muito grande".into());
    }
    let e: Envelope = serde_json::from_slice(envelope)?;
    let payload = STANDARD.decode(e.payload)?;
    let public: [u8; 32] = hex::decode(key.trim())?
        .try_into()
        .map_err(|_| "Chave pública inválida")?;
    let signature = Signature::from_slice(&STANDARD.decode(e.signature)?)?;
    VerifyingKey::from_bytes(&public)?.verify_strict(&payload, &signature)?;
    let m: Manifest = serde_json::from_slice(&payload)?;
    version(&m.version)?;
    if m.product != "baiacu-nfse-windows-x64"
        || m.version != expected
        || m.file != format!("Baiacu-NFS-e-{}-windows.zip", m.version)
        || m.sha256.len() != 64
        || !m.sha256.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("Manifesto não corresponde a esta atualização".into());
    }
    Ok(m)
}

/// Valida o pacote persistido pelo serviço, sempre usando a versão confirmada.
pub fn verify_prepared(stage: &Path, key: &str, version: &str) -> Result<Manifest> {
    no_links(stage)?;
    let manifest = verify(&fs::read(stage.join("release.sig.json"))?, key, version)?;
    if hash(&stage.join("release.zip"))? != manifest.sha256.to_ascii_lowercase() {
        return Err("O pacote preparado foi alterado ou está incompleto".into());
    }
    Ok(manifest)
}

pub fn hash(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut h = Sha256::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex::encode(h.finalize()))
}

/// Valida antes de extrair. Só arquivos regulares, nomes Windows seguros, sem colisões.
pub fn extract(zip: &Path, out: &Path, m: &Manifest) -> Result<PathBuf> {
    if fs::metadata(zip)?.len() > MAX_ZIP || hash(zip)? != m.sha256.to_ascii_lowercase() {
        return Err("ZIP não corresponde ao manifesto assinado".into());
    }
    let mut archive = zip::ZipArchive::new(fs::File::open(zip)?)?;
    if archive.len() > 20000 {
        return Err("ZIP muito grande".into());
    }
    let mut names = std::collections::HashSet::new();
    let mut total = 0u64;
    for i in 0..archive.len() {
        let f = archive.by_index(i)?;
        let file_name = f.name()?;
        let name = file_name.trim_end_matches('/');
        if !name.starts_with("Baiacu NFS-e/") && name != "Baiacu NFS-e" {
            return Err("Raiz do ZIP inválida".into());
        }
        for part in name.split('/') {
            let stem = part.split('.').next().unwrap_or("").to_ascii_uppercase();
            if part.is_empty()
                || part == "."
                || part == ".."
                || part.ends_with([' ', '.'])
                || part
                    .chars()
                    .any(|c| c.is_control() || "\\:*?\"<>|".contains(c))
                || ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
                || (stem.len() == 4
                    && (stem.starts_with("COM") || stem.starts_with("LPT"))
                    && stem.as_bytes()[3].is_ascii_digit())
            {
                return Err("Caminho Windows inválido no ZIP".into());
            }
        }
        if !names.insert(name.to_ascii_lowercase()) {
            return Err("Caminho duplicado no ZIP".into());
        }
        if f.unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err("Link no ZIP".into());
        }
        total = total.checked_add(f.size()).ok_or("ZIP muito grande")?;
        if total > MAX_EXPANDED {
            return Err("ZIP muito grande".into());
        }
    }
    fs::create_dir_all(out)?;
    for i in 0..archive.len() {
        let mut f = archive.by_index(i)?;
        let path = out.join(f.enclosed_name().ok_or("Caminho inválido")?);
        if f.is_dir() {
            fs::create_dir_all(&path)?;
        } else {
            fs::create_dir_all(path.parent().ok_or("Sem pasta")?)?;
            let mut dest = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)?;
            std::io::copy(&mut f, &mut dest)?;
            dest.flush()?;
        }
    }
    let root = out.join("Baiacu NFS-e");
    for required in [
        EXE,
        "data/app.so",
        "data/dll/nucleo.dll",
        "release-version.txt",
    ] {
        if !root.join(required).is_file() {
            return Err(format!("Pacote incompleto: {required}").into());
        }
    }
    if fs::read_to_string(root.join("release-version.txt"))?.trim() != m.version {
        return Err("Versão interna incorreta".into());
    }
    Ok(root)
}

/// Não instala dados, marcadores de instalação, desinstalador nem o próprio serviço.
fn files(root: &Path, at: &Path, list: &mut Vec<PathBuf>) -> Result<()> {
    for e in fs::read_dir(at)? {
        let e = e?;
        let p = e.path();
        let rel = p.strip_prefix(root)?.to_path_buf();
        let first = rel
            .components()
            .next()
            .ok_or("Caminho vazio")?
            .as_os_str()
            .to_string_lossy()
            .to_ascii_lowercase();
        if [
            "database",
            "logs",
            "atualizacao",
            "service",
            "installed.marker",
            "update.pending",
            "update.committed",
        ]
        .contains(&first.as_str())
            || first.starts_with("unins")
        {
            continue;
        }
        if e.file_type()?.is_symlink() {
            return Err("Link recusado".into());
        }
        if e.file_type()?.is_dir() {
            files(root, &p, list)?;
        } else {
            list.push(rel);
        }
    }
    Ok(())
}
pub fn no_links(path: &Path) -> Result<()> {
    for p in path.ancestors() {
        if let Ok(m) = fs::symlink_metadata(p) {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if m.file_attributes() & 0x400 != 0 {
                    return Err("Ponto de redirecionamento recusado".into());
                }
            }
            if m.file_type().is_symlink() {
                return Err("Link recusado".into());
            }
        }
    }
    Ok(())
}
fn sync(path: &Path) -> Result<()> {
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)?
        .sync_all()?;
    Ok(())
}
fn durable_rename(from: &Path, to: &Path) -> Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let a: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
        let b: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
        if unsafe {
            windows_sys::Win32::Storage::FileSystem::MoveFileExW(a.as_ptr(), b.as_ptr(), 0x8 | 0x1)
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    #[cfg(not(windows))]
    fs::rename(from, to)?;
    Ok(())
}
fn copy_atomic(from: &Path, to: &Path) -> Result<()> {
    let mut temporary = tempfile::NamedTempFile::new_in(to.parent().ok_or("Sem pasta")?)?;
    std::io::copy(&mut fs::File::open(from)?, temporary.as_file_mut())?;
    temporary.as_file().sync_all()?;
    let path = temporary.into_temp_path();
    durable_rename(&path, to)
}
/// Guarda os originais e só confirma a versão após validar a partida.
pub fn install(
    source: &Path,
    target: &Path,
    validate_startup: impl FnOnce() -> Result<()>,
) -> Result<()> {
    recover(target)?;
    let backup = target.join("service/rollback");
    if backup.exists() {
        no_links(&backup)?;
        fs::remove_dir_all(&backup)?;
    }
    fs::create_dir_all(&backup)?;
    no_links(target)?;
    let mut list = Vec::new();
    files(source, source, &mut list)?;
    let version_file = PathBuf::from("release-version.txt");
    list.sort();
    let version_index = list
        .binary_search(&version_file)
        .map_err(|_| "Pacote sem versão")?;
    list.remove(version_index);
    list.push(version_file);
    log(format!(
        "Instalação: {} arquivo(s) de {} para {}.",
        list.len(),
        source.display(),
        target.display()
    ));
    let mut existed = Vec::new();
    for rel in &list {
        let dst = target.join(rel);
        no_links(&dst)?;
        if dst.exists() {
            let old = backup.join(rel);
            fs::create_dir_all(old.parent().ok_or("Sem pasta")?)?;
            fs::copy(dst, &old)?;
            sync(&old)?;
            existed.push(rel.clone());
        }
    }
    // Escrito e sincronizado ANTES da primeira substituição; o runner verifica antes de carregar DLLs.
    let journal = Journal {
        files: list.clone(),
        existed,
    };
    let temp_journal = target.join("service/rollback/journal.tmp");
    let mut pending = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_journal)?;
    pending.write_all(&serde_json::to_vec(&journal)?)?;
    pending.sync_all()?;
    drop(pending);
    durable_rename(&temp_journal, &target.join("update.pending"))?;
    let result: Result<()> = (|| {
        #[cfg(all(test, feature = "testes-locais"))]
        let changed = std::cell::Cell::new(0);
        let apply = |rel: &Path| -> Result<()> {
            let dst = target.join(rel);
            fs::create_dir_all(dst.parent().ok_or("Sem pasta")?)?;
            copy_atomic(&source.join(rel), &dst)?;
            if hash(&source.join(rel))? != hash(&dst)? {
                return Err("Falha conferindo o arquivo instalado".into());
            }
            #[cfg(all(test, feature = "testes-locais"))]
            {
                changed.set(changed.get() + 1);
                if std::env::var("BAIACU_TEST_KILL_AT")
                    .ok()
                    .and_then(|v| v.parse::<usize>().ok())
                    == Some(changed.get())
                {
                    std::process::exit(97);
                }
            }
            Ok(())
        };
        let (version_file, binaries) = list.split_last().ok_or("Pacote sem versão")?;
        for rel in binaries {
            apply(rel)?;
        }
        log("Arquivos copiados e conferidos. Conferência de partida da nova versão (código 42)…");
        validate_startup()?;
        log("Conferência de partida aprovada.");
        apply(version_file)?;
        durable_rename(
            &target.join("update.pending"),
            &target.join("update.committed"),
        )
    })();
    match &result {
        Err(original) => {
            log(format!("Falha na instalação: {original}. Voltando para a versão anterior…"));
            // Se a volta também falhar, os DOIS erros seguem juntos: o original explica por
            // que a instalação parou; o segundo, por que a versão anterior não voltou.
            if let Err(volta) = recover(target) {
                log(format!("A volta para a versão anterior também falhou: {volta}"));
                return Err(format!(
                    "{original}. A volta para a versão anterior também falhou: {volta}"
                )
                .into());
            }
            log("Versão anterior restaurada.");
        }
        Ok(()) => {
            let _ = fs::remove_file(target.join("update.committed"));
            let _ = fs::remove_dir_all(backup);
            log("Instalação confirmada.");
        }
    }
    result
}

#[derive(Serialize, Deserialize)]
struct Journal {
    files: Vec<PathBuf>,
    existed: Vec<PathBuf>,
}

/// Idempotente: uma interrupção na própria recuperação permite repetir a operação.
pub fn recover(target: &Path) -> Result<()> {
    no_links(target)?;
    let path = target.join("update.pending");
    if !path.exists() {
        return Ok(());
    }
    no_links(&path)?;
    let bytes = fs::read(&path)?;
    let journal: Journal = serde_json::from_slice(&bytes).map_err(|_| "Registro de atualização incompleto. Reinstale o pacote para reparar; os bancos foram preservados.")?;
    if journal.files.len() > 20000 {
        return Err("Registro de atualização inválido".into());
    }
    let backup = target.join("service/rollback");
    no_links(&backup)?;
    log(format!(
        "Recuperação: restaurando {} arquivo(s) da cópia em service/rollback.",
        journal.files.len()
    ));
    for rel in &journal.files {
        if rel.as_os_str().is_empty()
            || rel
                .components()
                .any(|c| !matches!(c, std::path::Component::Normal(_)))
            || rel.to_string_lossy().contains(':')
        {
            return Err("Caminho inválido no registro de atualização".into());
        }
        let dst = target.join(rel);
        no_links(&dst)?;
        if journal.existed.contains(rel) {
            let old = backup.join(rel);
            no_links(&old)?;
            copy_atomic(&old, &dst)?;
        } else if dst.is_file() {
            fs::remove_file(dst)?;
        }
    }
    durable_rename(&path, &target.join("update.committed"))?;
    let _ = fs::remove_file(target.join("update.committed"));
    // O backup fica até a próxima atualização, permitindo auditoria/recuperação manual.
    Ok(())
}

// A suíte local é copiada de NFSe/temp/testes pelo roteiro rodar_testes_atualizador.py.
// A compilação normal e os testes públicos não dependem de arquivos externos.
#[cfg(all(test, feature = "testes-locais"))]
#[path = "../testes_locais/regressao.rs"]
mod tests;
