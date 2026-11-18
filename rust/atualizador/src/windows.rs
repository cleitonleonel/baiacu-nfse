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
        ServiceAccess, ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState,
        ServiceStatus, ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
    service_manager::{ServiceManager, ServiceManagerAccess},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, ERROR_FILE_NOT_FOUND, GetLastError, LocalFree, WAIT_OBJECT_0},
    Security::{
        Authorization::{
            ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        },
        DACL_SECURITY_INFORMATION, LookupAccountNameW, OWNER_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION, SetFileSecurityW, TOKEN_ASSIGN_PRIMARY,
        TOKEN_DUPLICATE, TOKEN_QUERY,
    },
    Storage::FileSystem::{BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle},
    System::Threading::{
        OpenMutexW, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
        QueryFullProcessImageNameW, WaitForSingleObject,
    },
    UI::WindowsAndMessaging::{MB_ICONERROR, MB_ICONINFORMATION, MB_OK, MessageBoxW},
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
pub fn show_info(message: &str) {
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(std::ffi::OsStr::new(message)).as_ptr(),
            wide(std::ffi::OsStr::new("Atualização do Baiacu")).as_ptr(),
            MB_OK | MB_ICONINFORMATION,
        );
    }
}

pub fn show_error(message: &str) {
    let message = update::clarear_os(message);
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(std::ffi::OsStr::new(&message)).as_ptr(),
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
const SERVICO_DADOS: &str = "BaiacuNFSeDados";
const CONTA_DADOS: &str = r"NT SERVICE\BaiacuNFSeDados";
const EXE_DADOS: &str = "data/dll/baiacu-dados.exe";
const NOME_DADOS: &str = "Baiacu NFSe - Dados";

fn servico_dados(acesso: ServiceAccess) -> Result<Option<windows_service::service::Service>> {
    let scm = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
    match scm.open_service(SERVICO_DADOS, acesso) {
        Ok(servico) => Ok(Some(servico)),
        Err(windows_service::Error::Winapi(e)) if e.raw_os_error() == Some(1060) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

fn parar_dados(remover: bool) -> Result<()> {
    let mut acesso = ServiceAccess::QUERY_STATUS | ServiceAccess::STOP;
    if remover {
        acesso |= ServiceAccess::DELETE;
    }
    let Some(servico) = servico_dados(acesso)? else {
        return Ok(());
    };
    let estado = servico.query_status()?.current_state;
    if estado != ServiceState::Stopped && estado != ServiceState::StopPending {
        if let Err(e) = servico.stop()
            && servico.query_status()?.current_state != ServiceState::Stopped
        {
            return Err(e.into());
        }
    }
    let limite = Instant::now() + Duration::from_secs(45);
    while servico.query_status()?.current_state != ServiceState::Stopped {
        if Instant::now() >= limite {
            return Err("O serviço de dados ainda está concluindo uma tarefa. Tente novamente em instantes.".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    if remover {
        servico.delete()?;
    }
    Ok(())
}

fn sid_dados() -> Result<String> {
    use std::ptr::{null, null_mut};
    let conta = wide(std::ffi::OsStr::new(CONTA_DADOS));
    let mut sid_len = 0;
    let mut dominio_len = 0;
    let mut tipo = 0;
    unsafe {
        LookupAccountNameW(
            null(),
            conta.as_ptr(),
            null_mut(),
            &mut sid_len,
            null_mut(),
            &mut dominio_len,
            &mut tipo,
        );
    }
    if sid_len == 0 {
        return Err(io::Error::last_os_error().into());
    }
    // SID deve ter alinhamento de DWORD.
    let mut sid = vec![0u32; (sid_len as usize).div_ceil(4)];
    let mut dominio = vec![0u16; dominio_len as usize];
    let mut texto = null_mut();
    unsafe {
        if LookupAccountNameW(
            null(),
            conta.as_ptr(),
            sid.as_mut_ptr().cast(),
            &mut sid_len,
            dominio.as_mut_ptr(),
            &mut dominio_len,
            &mut tipo,
        ) == 0
            || ConvertSidToStringSidW(sid.as_mut_ptr().cast(), &mut texto) == 0
        {
            return Err(io::Error::last_os_error().into());
        }
        let mut len = 0;
        while *texto.add(len) != 0 {
            len += 1;
        }
        let convertido = String::from_utf16_lossy(std::slice::from_raw_parts(texto, len));
        LocalFree(texto.cast());
        Ok(convertido)
    }
}

fn aplicar_acl(pasta: &Path, aces: &str) -> Result<()> {
    use std::ptr::null_mut;
    let sddl = wide(std::ffi::OsStr::new(&format!(
        "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA){aces}"
    )));
    let mut descritor = null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descritor,
            null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error().into());
    }
    let resultado = unsafe {
        SetFileSecurityW(
            wide(pasta.as_os_str()).as_ptr(),
            OWNER_SECURITY_INFORMATION
                | DACL_SECURITY_INFORMATION
                | PROTECTED_DACL_SECURITY_INFORMATION,
            descritor,
        )
    };
    let erro = (resultado == 0).then(io::Error::last_os_error);
    unsafe { LocalFree(descritor) };
    if let Some(erro) = erro {
        return Err(format!("Falha ao proteger {}: {erro}", pasta.display()).into());
    }
    Ok(())
}

fn legados_sem_links(pasta: &Path) -> Result<()> {
    update::no_links(pasta)?;
    for item in fs::read_dir(pasta)? {
        let item = item?;
        let caminho = item.path();
        update::no_links(&caminho)?;
        if item.file_type()?.is_dir() {
            legados_sem_links(&caminho)?;
        } else {
            let arquivo = fs::File::open(&caminho)?;
            let mut info = BY_HANDLE_FILE_INFORMATION::default();
            if unsafe { GetFileInformationByHandle(arquivo.as_raw_handle(), &mut info) } == 0 {
                return Err(io::Error::last_os_error().into());
            }
            if info.nNumberOfLinks != 1 {
                return Err(format!("Vínculo físico recusado em {}", caminho.display()).into());
            }
        }
    }
    Ok(())
}

fn icacls(pasta: &Path, args: &[&str]) -> Result<()> {
    let status = std::process::Command::new(system("icacls.exe")?)
        .arg(pasta)
        .args(args)
        .creation_flags(0x08000000)
        .status()?;
    if !status.success() {
        return Err(format!("Falha ao proteger {} ({status}).", pasta.display()).into());
    }
    Ok(())
}

fn preparar_dados(root: &Path) -> Result<()> {
    let exe = root.join(EXE_DADOS);
    update::no_links(&exe)?;
    if !exe.is_file() {
        return Err("Executável do serviço de dados ausente.".into());
    }
    parar_dados(false)?;
    let comando = format!("\"{}\"", exe.display());
    let acao = if servico_dados(ServiceAccess::QUERY_STATUS)?.is_some() {
        "config"
    } else {
        "create"
    };
    sc(&[
        acao,
        SERVICO_DADOS,
        "binPath=",
        &comando,
        "start=",
        "demand",
        "obj=",
        CONTA_DADOS,
        "DisplayName=",
        NOME_DADOS,
    ])?;
    sc(&[
        "description",
        SERVICO_DADOS,
        "Serviço responsável por proteger e acessar os bancos do Baiacu NFSe.",
    ])?;
    sc(&[
        "sdset",
        SERVICO_DADOS,
        "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWRPLO;;;BU)",
    ])?;

    let dados = PathBuf::from(std::env::var_os("ProgramData").ok_or("ProgramData ausente")?)
        .join("Baiacu NFS-e");
    update::no_links(&dados)?;
    fs::create_dir_all(&dados)?;
    let sid = sid_dados()?;
    // Usuários comuns precisam atravessar a raiz, sem poder trocar seus subdiretórios.
    aplicar_acl(&dados, &format!("(A;;0x1200a9;;;BU)(A;;0x1200a9;;;{sid})"))?;
    for (nome, leitores) in [("database", ""), ("logs", "(A;OICI;0x1200a9;;;BU)")] {
        let pasta = dados.join(nome);
        update::no_links(&pasta)?;
        fs::create_dir_all(&pasta)?;
        aplicar_acl(&pasta, &format!("(A;OICI;0x1301bf;;;{sid}){leitores}"))?;
        legados_sem_links(&pasta)?;
        // Retira DACLs e proprietários explícitos dos arquivos das instalações antigas.
        for filho in fs::read_dir(&pasta)? {
            let filho = filho?.path();
            icacls(&filho, &["/reset", "/T", "/L", "/Q"])?;
            icacls(&filho, &["/setowner", "*S-1-5-32-544", "/T", "/L", "/Q"])?;
        }
    }
    let legado = root.join("database-legado");
    if legado.is_dir() {
        legados_sem_links(&legado)?;
        aplicar_acl(&legado, "")?;
        for filho in fs::read_dir(&legado)? {
            let filho = filho?.path();
            icacls(&filho, &["/reset", "/T", "/L", "/Q"])?;
            icacls(&filho, &["/setowner", "*S-1-5-32-544", "/T", "/L", "/Q"])?;
        }
    }
    let servico = servico_dados(ServiceAccess::START | ServiceAccess::QUERY_STATUS)?
        .ok_or("Serviço de dados ausente")?;
    servico.start::<&str>(&[])?;
    let limite = Instant::now() + Duration::from_secs(10);
    loop {
        match servico.query_status()?.current_state {
            ServiceState::Running => return Ok(()),
            ServiceState::Stopped => return Err("O serviço de dados não conseguiu iniciar.".into()),
            _ if Instant::now() >= limite => {
                return Err("O serviço de dados não respondeu ao instalador.".into());
            }
            _ => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

fn repair() -> Result<()> {
    let root = installed()?;
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
            "Baiacu NFSe - Atualização",
        ])?;
    }
    sc(&[
        "config",
        SERVICE,
        "DisplayName=",
        "Baiacu NFSe - Atualização",
    ])?;
    sc(&[
        "description",
        SERVICE,
        "Serviço responsável por cuidar das atualizações do Baiacu NFSe.",
    ])?;
    // Usuários podem consultar/iniciar; não podem mudar configuração, parar ou remover.
    sc(&[
        "sdset",
        SERVICE,
        "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWRPLO;;;BU)",
    ])?;
    preparar_dados(&root)
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
    update::log(format!(
        "Pedido do Baiacu (pid {pid}): {action} da versão {desired}; instalada {}.",
        old.trim()
    ));
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
        update::log("Aguardando o Baiacu fechar…");
        wait_app(&process)?;
        update::log("Baiacu fechado. Conferindo e extraindo o pacote preparado.");
        let install_area = tempfile::Builder::new()
            .prefix("apply-")
            .tempdir_in(root.join("service"))?;
        update::verify_prepared(&prepared, update::PUBLIC_KEY, desired)?;
        let source = update::extract(
            &prepared.join("release.zip"),
            &install_area.path().join("novo"),
            &manifest,
        )?;
        update::log("Parando o serviço de dados (se houver).");
        parar_dados(false)?;
        let result = update::install(&source, &root, || {
            crate::startup_probe::check(&root, Some(&token))
        });
        if result.is_ok() {
            let _ = fs::remove_dir_all(&prepared);
        }
        return result;
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
    // O .sha256 publicado vem primeiro: um pacote já preparado só é reaproveitado se for
    // exatamente o publicado agora (a mesma versão pode ter sido republicada).
    let sha_file = temp.path().join("release.sha256");
    download(
        &agent,
        &url(&format!("{file}.sha256"))?,
        &sha_file,
        1024,
        |_, _| Ok(()),
    )?;
    let publicado = fs::read_to_string(&sha_file)?
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    match update::verify_prepared(&prepared, update::PUBLIC_KEY, desired) {
        Ok(m) if m.sha256.to_ascii_lowercase() == publicado => {
            update::log("Pacote já preparado confere com o .sha256 publicado: reaproveitado.");
            progress(
                &root,
                desired,
                pid,
                action,
                100,
                "Pacote já preparado e verificado",
                true,
            )?;
            return Ok(());
        }
        Ok(_) => update::log(
            "Pacote preparado difere do .sha256 publicado (versão republicada): baixando de novo.",
        ),
        Err(e) if prepared.exists() => {
            update::log(format!("Pacote preparado inválido ({e}): baixando de novo."))
        }
        Err(_) => {}
    }
    update::log("Baixando assinatura e pacote.");
    let signature = temp.path().join("release.sig.json");
    download(
        &agent,
        &url(&format!("{file}.sig.json"))?,
        &signature,
        16384,
        |_, _| Ok(()),
    )?;
    let manifest = update::verify(&fs::read(signature)?, update::PUBLIC_KEY, desired)?;
    if publicado != manifest.sha256.to_ascii_lowercase() {
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
    let candidato = update::extract(&zip, &temp.path().join("novo"), &manifest)?;
    if candidato.join(EXE_DADOS).is_file() && servico_dados(ServiceAccess::QUERY_STATUS)?.is_none()
    {
        return Err(
            "Execute o instalador da nova versão para registrar o serviço de dados.".into(),
        );
    }
    if prepared.exists() {
        update::no_links(&prepared)?;
        fs::remove_dir_all(&prepared)?;
    }
    let stage = temp.keep();
    fs::rename(&stage, &prepared)?;
    update::log("Pacote baixado, verificado e pronto para instalar.");
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
    match &result {
        Ok(()) => update::log("Serviço de atualização concluído sem erros."),
        Err(e) => update::log(format!("Serviço de atualização terminou com erro: {e}")),
    }
    if let Ok(root) = root() {
        let _ = fs::write(
            root.join("service/last-result.txt"),
            match &result {
                Ok(_) => "Atualização concluída.".to_owned(),
                Err(e) => update::clarear_os(&format!("Falha na atualização: {e}")),
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
    update::log(if failed {
        "Atualização terminou com falha; reabrindo o Baiacu."
    } else {
        "Atualização terminou; reabrindo o Baiacu."
    });
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
    // --check e --verify são consultas rápidas da tela: não poluem o registro.
    if !matches!(args.get(1).map(String::as_str), None | Some("--check" | "--verify"))
        && let Ok(raiz) = root()
    {
        update::definir_log(raiz.join("service/atualizador.log"));
    }
    let resultado = executar(&args);
    if let Err(e) = &resultado {
        update::log(format!("{}: erro: {e}", args.get(1).map_or("", String::as_str)));
    }
    resultado
}

fn executar(args: &[String]) -> Result<()> {
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
        Some("--dados-parar" | "--dados-remover") => {
            installed()?;
            parar_dados(args[1] == "--dados-remover")
        }
        Some("--recover") => {
            let root = root()?;
            let _guard = UpdateGuard::acquire(&root)?;
            if root.join("installed.marker").is_file() {
                parar_dados(false)?;
            }
            // O programa que pediu a recuperação acabou de sair; o Windows pode levar um instante
            // para soltar o executável dele. Tenta por até ~10 s antes de desistir.
            update::log("Recuperação pedida (--recover).");
            let mut tentativa = 0;
            loop {
                match update::recover(&root) {
                    Ok(()) => break,
                    Err(e) if tentativa < 20 => {
                        tentativa += 1;
                        update::log(format!("Recuperação, tentativa {tentativa}: {e}"));
                        std::thread::sleep(Duration::from_millis(500));
                    }
                    Err(e) => return Err(e),
                }
            }
            update::log("Recuperação concluída: versão anterior restaurada.");
            // Chamado pelo programa (que já saiu), avisa; pelo instalador (--silencioso), não.
            if args.get(2).map(String::as_str) != Some("--silencioso") {
                show_info("A versão anterior do Baiacu foi restaurada. Pode abrir o programa de novo.");
            }
            Ok(())
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
            update::log(format!("Atualização portátil para {desired}: aguardando o Baiacu fechar."));
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
