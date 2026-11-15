#![cfg_attr(windows, windows_subsystem = "windows")]
#[cfg(windows)]
mod startup_probe;
#[cfg(windows)]
mod windows;
fn main() {
    #[cfg(windows)]
    if let Err(e) = windows::run() {
        windows::show_error(&e.to_string());
        std::process::exit(1);
    }
}
