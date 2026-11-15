//! Cliente sem privilégios. A reparação é uma operação explícita via UAC.
use crate::{Result, SERVICE};
use std::{os::windows::process::CommandExt, path::Path, time::Duration};
use windows_service::{
    service::{ServiceAccess, ServiceState},
    service_manager::{ServiceManager, ServiceManagerAccess},
};

pub fn check_startup_support(helper: &Path) -> Result<()> {
    let output = std::process::Command::new(helper)
        .arg("--check")
        .creation_flags(0x08000000)
        .output()?;
    if !output.status.success() || output.stdout != b"startup-probe-v1\n" {
        return Err("Atualize o componente de atualização executando o setup atual ou usando o ZIP mais recente.".into());
    }
    Ok(())
}

fn open() -> windows_service::Result<windows_service::service::Service> {
    ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?
        .open_service(SERVICE, ServiceAccess::START | ServiceAccess::QUERY_STATUS)
}
pub fn ensure(helper: &Path) -> Result<()> {
    // query_config requer direito extra: consultar estado do serviço via sc para distinguir disabled.
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
    let reason = match manager.open_service(SERVICE, ServiceAccess::QUERY_CONFIG) {
        Ok(s) => match s.query_config() {
            Ok(c) if c.start_type != windows_service::service::ServiceStartType::Disabled => {
                return Ok(());
            }
            _ => "O serviço de atualização está desativado ou precisa de reparo.",
        },
        Err(_) => "O serviço de atualização não foi encontrado ou não pode ser acessado.",
    };
    if !helper.is_file() {
        return Err(format!("{reason} Reinstale o Baiacu para restaurar o componente.").into());
    }
    // A tela avisa o motivo ANTES de pedir elevação. Sem comando recebido do usuário.
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        IDOK, MB_ICONINFORMATION, MB_OKCANCEL, MessageBoxW,
    };
    let wide = |s: &str| {
        std::ffi::OsStr::new(s)
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>()
    };
    let msg = wide(&format!(
        "{reason}\n\nO Baiacu tentará reparar o serviço. O Windows solicitará autorização de administrador para continuar."
    ));
    if unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            msg.as_ptr(),
            wide("Atualização do Baiacu").as_ptr(),
            MB_OKCANCEL | MB_ICONINFORMATION,
        )
    } != IDOK
    {
        return Err("Reparação do serviço cancelada. Nenhum arquivo foi atualizado.".into());
    }
    use base64::Engine;
    let code = format!(
        "$ErrorActionPreference='Stop'; $p=Start-Process -FilePath '{}' -ArgumentList '--repair' -Verb RunAs -Wait -PassThru -WindowStyle Hidden; exit $p.ExitCode",
        helper.to_string_lossy().replace('\'', "''")
    );
    let bytes: Vec<u8> = code.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let powershell =
        std::path::PathBuf::from(std::env::var_os("SystemRoot").ok_or("Windows ausente")?)
            .join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let status = std::process::Command::new(powershell)
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            &base64::engine::general_purpose::STANDARD.encode(bytes),
        ])
        .creation_flags(0x08000000)
        .status()?;
    if !status.success() {
        return Err(
            "Não foi possível reparar o serviço. Autorize a elevação ou reinstale o Baiacu.".into(),
        );
    }
    open()?;
    Ok(())
}
pub fn start(version: &str, pid: u32, sha256: &str) -> Result<()> {
    crate::version(version)?;
    let service = open()?;
    if service.query_status()?.current_state != ServiceState::Stopped {
        return Err("Já existe uma atualização em andamento.".into());
    }
    service.start(&[version, &pid.to_string(), sha256])?;
    // SCM pode responder ainda em StartPending.
    for _ in 0..100 {
        match service.query_status()?.current_state {
            ServiceState::Running => return Ok(()),
            ServiceState::Stopped => {
                return Err("O serviço encerrou antes de preparar a atualização.".into());
            }
            _ => std::thread::sleep(Duration::from_millis(100)),
        }
    }
    Err("O serviço não iniciou no tempo esperado.".into())
}
