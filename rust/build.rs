fn main() {
    // Bibliotecas do Windows de que o libcrypto estático depende.
    for lib in ["crypt32", "ws2_32", "user32", "advapi32", "bcrypt"] {
        println!("cargo:rustc-link-lib={lib}");
    }
    // libxml2 2.11.9 estática (validação contra o XSD).
    println!("cargo:rerun-if-env-changed=BAIACU_NATIVE_LIBS");
    let aqui = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    let libs = std::env::var_os("BAIACU_NATIVE_LIBS")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::Path::new(&aqui).join("../../extras/terceiros"));
    let libxml2 = libs.join("libxml2");
    println!(
        "cargo:rerun-if-changed={}",
        libxml2.join("libxml2s.lib").display()
    );
    println!("cargo:rustc-link-search=native={}", libxml2.display());
    println!("cargo:rustc-link-lib=static=libxml2s");
}
