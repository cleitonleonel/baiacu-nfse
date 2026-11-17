#[cfg(windows)]
fn main() -> windows_service::Result<()> {
    nucleo::dados_windows::iniciar()
}

#[cfg(not(windows))]
fn main() {}
