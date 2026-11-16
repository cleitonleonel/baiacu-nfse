use baiacu_atualizador::{self as update, EXE, Result, SERVICE};
use std::os::windows::{
    ffi::OsStrExt,
    io::{AsRawHandle, FromRawHandle, OwnedHandle},
    process::CommandExt,
};
use std::{
    ffi::OsString,
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use windows_service::{
    define_windows_service,
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, ERROR_FILE_NOT_FOUND, GetLastError, WAIT_OBJECT_0},
    Security::{TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_QUERY},
    System::Threading::{
        OpenMutexW, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
        QueryFullProcessImageNameW, WaitForSingleObject,
    },
    UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW},
};

define_windows_service!(entry, service_main);
fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(Some(0)).collect()
}
struct UpdateGuard(windows_sys::Win32::Foundation::HANDLE);
impl UpdateGuard {
    fn acquire(root: &Path) -> Result<Self> {
        let mut hash = 14695981039346656037u64;
        for c in root.join(EXE).as_os_str().encode_wide() {
            let folded = if (65..=90).contains(&c) { c + 32 } else { c };
            hash ^= folded as u64;
            hash = hash.wrapping_mul(1099511628211);
        }
        Self::named(&format!("Global\\BaiacuNFSe.Update.{hash}"))
    }
    fn named(name: &str) -> Result<Self> {
        let name = wide(std::ffi::OsStr::new(name));
        unsafe {
            let handle = windows_sys::Win32::System::Threading::CreateMutexW(
                std::ptr::null(),
                0,
                name.as_ptr(),
            );
            if handle.is_null() {
                return Err(std::io::Error::last_os_error().into());
            }
            if windows_sys::Win32::Foundation::GetLastError() == 183 {
                CloseHandle(handle);
                return Err("Já existe uma atualização ou recuperação em andamento.".into());
            }
            Ok(Self(handle))
        }
    }
}
impl Drop for UpdateGuard {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
pub fn show_error(message: &str) {
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(std::ffi::OsStr::new(message)).as_ptr(),
            wide(std::ffi::OsStr::new("Atualização do Baiacu")).as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}
fn root() -> Result<PathBuf> {
    let exe = std::env::current_exe()?;
    Ok(exe
        .parent()
        .and_then(Path::parent)
        .ok_or("Pasta do atualizador inválida")?
        .to_path_buf())
}
fn installed() -> Result<PathBuf> {
    let root = root()?;
    update::no_links(&root)?;
    // Local fixo: nunca recebe pasta de destino, URL ou comando do cliente.
    let pf = std::env::var_os("ProgramW6432")
        .or_else(|| std::env::var_os("ProgramFiles"))
        .ok_or("Program Files ausente")?;
    let expected = PathBuf::from(pf).join("Baiacu NFS-e");
    if !root
        .to_string_lossy()
        .eq_ignore_ascii_case(&expected.to_string_lossy())
        || !root.join("installed.marker").is_file()
    {
        return Err("Serviço permitido apenas na instalação em Program Files".into());
    }
    Ok(root)
}
fn sc(args: &[&str]) -> Result<()> {
    let status = std::process::Command::new(system("sc.exe")?)
        .args(args)
        .creation_flags(0x08000000)
        .status()?;
    if !status.success() {
        return Err(format!("Falha ao configurar o serviço ({status}).").into());
    }
    Ok(())
}
fn system(name: &str) -> Result<PathBuf> {
    Ok(
        PathBuf::from(std::env::var_os("SystemRoot").ok_or("Windows ausente")?)
            .join("System32")
            .join(name),
    )
}
fn repair() -> Result<()> {
    installed()?;
    let bin = format!("\"{}\" --service", std::env::current_exe()?.display());
    let exists = std::process::Command::new(system("sc.exe")?)
        .args(["query", SERVICE])
        .creation_flags(0x08000000)
        .status()?
        .success();
    if exists {
        sc(&[
            "config",
            SERVICE,
            "binPath=",
            &bin,
            "start=",
            "demand",
            "obj=",
            "LocalSystem",
        ])?;
    } else {
        sc(&[
            "create",
            SERVICE,
            "binPath=",
            &bin,
            "start=",
            "demand",
            "obj=",
            "LocalSystem",
            "DisplayName=",
            "Atualização do Baiacu NFS-e",
        ])?;
    }
    // Usuários podem consultar/iniciar; não podem mudar configuração, parar ou remover.
    sc(&[
        "sdset",
        SERVICE,
        "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWRPLO;;;BU)",
    ])?;
    Ok(())
}
fn open_app(pid: u32, root: &Path) -> Result<OwnedHandle> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | 0x00100000, 0, pid);
        if process.is_null() {
            return Err("Não foi possível confirmar o processo do Baiacu".into());
        }
        let process = OwnedHandle::from_raw_handle(process);
        let mut name = vec![0u16; 32768];
        let mut len = name.len() as u32;
        let valid =
            QueryFullProcessImageNameW(process.as_raw_handle(), 0, name.as_mut_ptr(), &mut len)
                != 0
                && String::from_utf16_lossy(&name[..len as usize])
                    .eq_ignore_ascii_case(&root.join(EXE).to_string_lossy());
        if !valid {
            return Err("Processo solicitante inválido".into());
        }
        Ok(process)
    }
}
fn user_token(process: &OwnedHandle) -> Result<OwnedHandle> {
    let mut token = std::ptr::null_mut();
    unsafe {
        if OpenProcessToken(
            process.as_raw_handle(),
            TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY,
            &mut token,
        ) == 0
        {
            return Err(io::Error::last_os_error().into());
        }
        Ok(OwnedHandle::from_raw_handle(token))
    }
}
fn wait_app(process: &OwnedHandle) -> Result<()> {
    if unsafe { WaitForSingleObject(process.as_raw_handle(), 120_000) } != WAIT_OBJECT_0 {
        return Err("O Baiacu não fechou em dois minutos".into());
    }
    Ok(())
}
fn progress(
    root: &Path,
    version: &str,
    pid: u32,
    action: &str,
    percent: u64,
    stage: &str,
    ready: bool,
) -> Result<()> {
    let value = serde_json::json!({"versao":version,"pid":pid,"acao":action,"percentual":percent,"etapa":stage,"pronto":ready});
    let temp = root.join("service/progress.tmp");
    fs::write(&temp, serde_json::to_vec(&value)?)?;
    fs::rename(temp, root.join("service/progress.json"))?;
    Ok(())
}
fn download(
    agent: &ureq::Agent,
    url: &str,
    dest: &Path,
    limit: u64,
    mut report: impl FnMut(u64, u64) -> Result<()>,
) -> Result<()> {
    use std::io::Read;
    if !url.starts_with("https://github.com/williamlala/baiacu-nfse/releases/download/") {
        return Err("URL de release inválida".into());
    }
    let mut response = agent.get(url).call()?;
    let total = response
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let mut input = response.body_mut().as_reader().take(limit + 1);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dest)?;
    let mut buf = [0u8; 65536];
    let mut read = 0;
    let mut last = Instant::now();
    loop {
        let n = input.read(&mut buf)?;
        if n == 0 {
            break;
        }
        read += n as u64;
        if read > limit {
            return Err("Download maior que o limite".into());
        }
        file.write_all(&buf[..n])?;
        if last.elapsed() >= Duration::from_millis(200) {
            report(read, total)?;
            last = Instant::now();
        }
    }
    file.sync_all()?;
    report(read, total)?;
    Ok(())
}
fn service_update(args: Vec<OsString>, running: impl FnOnce() -> Result<()>) -> Result<()> {
    let root = installed()?;
    let _installed = UpdateGuard::named("Global\\BaiacuNFSe.InstalledUpdate")?;
    let setup = wide(std::ffi::OsStr::new("Global\\BaiacuNFSe.Setup"));
    unsafe {
        let handle = OpenMutexW(0x00100000, 0, setup.as_ptr());
        if !handle.is_null() {
            CloseHandle(handle);
            return Err("Feche o instalador do Baiacu antes de atualizar pelo programa.".into());
        }
        if GetLastError() != ERROR_FILE_NOT_FOUND {
            return Err(io::Error::last_os_error().into());
        }
    }
    let _guard = UpdateGuard::acquire(&root)?;
    let desired = args
        .get(1)
        .and_then(|s| s.to_str())
        .ok_or("Versão ausente")?;
    let pid: u32 = args
        .get(2)
        .and_then(|s| s.to_str())
        .ok_or("Processo ausente")?
        .parse()?;
    let process = open_app(pid, &root)?;
    let action = args
        .get(3)
        .and_then(|v| v.to_str())
        .ok_or("Operação ausente")?;
    if !["prepare", "install"].contains(&action) {
        return Err("Operação inválida".into());
    }
    let old = fs::read_to_string(root.join("release-version.txt"))?;
    if update::version(desired)? <= update::version(old.trim())? {
        return Err("Versão antiga recusada".into());
    }
    let prepared = root.join("service/prepared");
    if action == "install" {
        update::no_links(&prepared)?;
        let manifest = update::verify(
            &fs::read(prepared.join("release.sig.json"))?,
            update::PUBLIC_KEY,
            desired,
        )?;
        // Confirma o processo antes de pedir seu encerramento. O pacote já foi autenticado
        // na preparação; a extração abaixo reconfere seu hash, sem novo download.
        let token = user_token(&process)?;
        running()?;
        wait_app(&process)?;
        let install_area = tempfile::Builder::new()
            .prefix("apply-")
            .tempdir_in(root.join("service"))?;
        update::verify_prepared(&prepared, update::PUBLIC_KEY, desired)?;
        let source = update::extract(
            &prepared.join("release.zip"),
            &install_area.path().join("novo"),
            &manifest,
        )?;
        let result = update::install(&source, &root, || {
            crate::startup_probe::check(&root, Some(&token))
        });
        if result.is_ok() {
            let _ = fs::remove_dir_all(&prepared);
        }
        return result;
    }
    if update::verify_prepared(&prepared, update::PUBLIC_KEY, desired).is_ok() {
        progress(
            &root,
            desired,
            pid,
            action,
            100,
            "Pacote já preparado e verificado",
            true,
        )?;
        running()?;
        return Ok(());
    }
    progress(
        &root,
        desired,
        pid,
        action,
        0,
        "Consultando a release",
        false,
    )?;
    running()?;
    let agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(300)))
        .build()
        .new_agent();
    let release: serde_json::Value = agent
        .get(&format!(
            "https://api.github.com/repos/{}/releases/latest",
            update::REPO
        ))
        .header("User-Agent", "Baiacu-Updater")
        .call()?
        .body_mut()
        .read_json()?;
    if release["tag_name"].as_str() != Some(&format!("v{desired}")) {
        return Err("A release mudou. Abra o Baiacu e procure novamente.".into());
    }
    let file = format!("Baiacu-NFS-e-{desired}-windows.zip");
    let url = |name: &str| -> Result<String> {
        release["assets"]
            .as_array()
            .and_then(|a| a.iter().find(|x| x["name"].as_str() == Some(name)))
            .and_then(|a| a["browser_download_url"].as_str())
            .map(str::to_owned)
            .ok_or_else(|| format!("Release sem {name}").into())
    };
    // Dentro de Program Files (ACL protegida), jamais em ProgramData gravável ou TEMP do cliente.
    let temp = tempfile::Builder::new()
        .prefix("stage-")
        .tempdir_in(root.join("service"))?;
    let signature = temp.path().join("release.sig.json");
    download(
        &agent,
        &url(&format!("{file}.sig.json"))?,
        &signature,
        16384,
        |_, _| Ok(()),
    )?;
    let manifest = update::verify(&fs::read(signature)?, update::PUBLIC_KEY, desired)?;
    let sha_file = temp.path().join("release.sha256");
    download(
        &agent,
        &url(&format!("{file}.sha256"))?,
        &sha_file,
        1024,
        |_, _| Ok(()),
    )?;
    if fs::read_to_string(sha_file)?.split_whitespace().next() != Some(manifest.sha256.as_str()) {
        return Err("SHA-256 publicado diverge do manifesto assinado".into());
    }
    let zip = temp.path().join("release.zip");
    download(
        &agent,
        &url(&file)?,
        &zip,
        update::MAX_ZIP,
        |read, total| {
            progress(
                &root,
                desired,
                pid,
                action,
                (read.min(total) * 90).checked_div(total).unwrap_or(0),
                "Baixando o pacote na área protegida",
                false,
            )
        },
    )?;
    progress(
        &root,
        desired,
        pid,
        action,
        92,
        "Verificando e extraindo o pacote",
        false,
    )?;
    update::extract(&zip, &temp.path().join("novo"), &manifest)?;
    if prepared.exists() {
        update::no_links(&prepared)?;
        fs::remove_dir_all(&prepared)?;
    }
    let stage = temp.keep();
    fs::rename(&stage, &prepared)?;
    progress(
        &root,
        desired,
        pid,
        action,
        100,
        "Pacote verificado e pronto para instalar",
        true,
    )
}
fn service_main(args: Vec<OsString>) {
    let Ok(handle) = service_control_handler::register(SERVICE, |control| match control {
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    }) else {
        return;
    };
    let status = |state, code| ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: state,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(code),
        checkpoint: 0,
        wait_hint: Duration::ZERO,
        process_id: None,
    };
    let result = service_update(args, || {
        handle.set_service_status(status(ServiceState::Running, 0))?;
        Ok(())
    });
    if let Ok(root) = root() {
        let _ = fs::write(
            root.join("service/last-result.txt"),
            match &result {
                Ok(_) => "Atualização concluída.".to_owned(),
                Err(e) => format!("Falha na atualização: {e}"),
            },
        );
    }
    let _ = handle.set_service_status(status(
        ServiceState::Stopped,
        if result.is_ok() { 0 } else { 1 },
    ));
}
fn watch() -> Result<()> {
    use windows_service::{
        service::ServiceAccess,
        service_manager::{ServiceManager, ServiceManagerAccess},
    };
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
    let service = manager.open_service(SERVICE, ServiceAccess::QUERY_STATUS)?;
    let started = Instant::now();
    let failed = loop {
        let state = service.query_status()?;
        if state.current_state == ServiceState::Stopped {
            break state.exit_code != ServiceExitCode::Win32(0);
        }
        if started.elapsed() > Duration::from_secs(720) {
            return Err(
                "A atualização está demorando. Consulte o serviço antes de abrir o Baiacu.".into(),
            );
        }
        std::thread::sleep(Duration::from_millis(500));
    };
    let root = root()?;
    std::process::Command::new(root.join(EXE))
        .current_dir(&root)
        .env("NFSE_REABRIR", "1")
        .spawn()?;
    if failed {
        show_error(
            &fs::read_to_string(root.join("service/last-result.txt")).unwrap_or_else(|_| {
                "A atualização falhou. Abra o Baiacu e tente novamente.".into()
            }),
        );
    }
    Ok(())
}
pub fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--check") => {
            if hex::decode(update::PUBLIC_KEY.trim())?.len() != 32 {
                return Err("Chave pública não configurada".into());
            }
            let _ = io::stdout().write_all(b"protected-download-v2\n");
            Ok(())
        }
        Some("--verify") => {
            let signature = args.get(2).ok_or("Assinatura ausente")?;
            let version = args.get(3).ok_or("Versão ausente")?;
            let zip = args.get(4).ok_or("ZIP ausente")?;
            let m = update::verify(&fs::read(signature)?, update::PUBLIC_KEY, version)?;
            if update::hash(Path::new(zip))? != m.sha256 {
                return Err("ZIP não corresponde à assinatura".into());
            }
            Ok(())
        }
        Some("--service") => {
            service_dispatcher::start(SERVICE, entry)?;
            Ok(())
        }
        Some("--repair") => repair(),
        Some("--recover") => {
            let root = root()?;
            let _guard = UpdateGuard::acquire(&root)?;
            update::recover(&root)
        }
        Some("--remove") => {
            installed()?;
            use windows_service::{
                service::ServiceAccess,
                service_manager::{ServiceManager, ServiceManagerAccess},
            };
            let manager =
                ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
            match manager.open_service(SERVICE, ServiceAccess::QUERY_STATUS | ServiceAccess::DELETE)
            {
                Ok(service) => {
                    if service.query_status()?.current_state != ServiceState::Stopped {
                        return Err("Aguarde a atualização terminar antes de desinstalar.".into());
                    }
                    service.delete()?;
                }
                Err(windows_service::Error::Winapi(e)) if e.raw_os_error() == Some(1060) => {}
                Err(e) => return Err(e.into()),
            }
            Ok(())
        }
        Some("--watch") => watch(),
        Some("--portable" | "--portable-ack") => {
            let root = root()?;
            let desired = args.get(2).ok_or("Versão ausente")?;
            let pid = args.get(3).ok_or("Processo ausente")?.parse()?;
            let work = PathBuf::from(args.get(4).ok_or("Pasta temporária ausente")?);
            let prepare = || -> Result<_> {
                let guard = UpdateGuard::acquire(&root)?;
                if root.join("installed.marker").exists() {
                    return Err("Modo portátil recusado na instalação".into());
                }
                let old = fs::read_to_string(root.join("release-version.txt"))?;
                if update::version(desired)? <= update::version(old.trim())? {
                    return Err("Versão antiga recusada".into());
                }
                Ok((guard, open_app(pid, &root)?))
            };
            let (guard, process) = if args[1] == "--portable-ack" {
                let mut stdout = io::stdout().lock();
                match prepare() {
                    Ok(pair) => {
                        stdout.write_all(b"READY\n")?;
                        stdout.flush()?;
                        pair
                    }
                    Err(error) => {
                        writeln!(stdout, "{error}")?;
                        stdout.flush()?;
                        return Ok(());
                    }
                }
            } else {
                prepare()?
            };
            wait_app(&process)?;
            let result: Result<()> = (|| {
                let m = update::verify(
                    &fs::read(work.join("release.sig.json"))?,
                    update::PUBLIC_KEY,
                    desired,
                )?;
                let source =
                    update::extract(&work.join("release.zip"), &work.join("instalar"), &m)?;
                update::install(&source, &root, || crate::startup_probe::check(&root, None))
            })();
            // Uma falha de cópia recuperável também reabre a versão anterior.
            if root.join("update.pending").exists() {
                return result;
            }
            drop(guard);
            std::process::Command::new(root.join(EXE))
                .current_dir(&root)
                .env("NFSE_REABRIR", "1")
                .spawn()?;
            result
        }
        _ => Err("Este componente é chamado pelo Baiacu para atualizar o programa.".into()),
    }
}
