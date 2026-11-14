fn main() {
    // Bibliotecas do Windows de que o libcrypto estático depende.
    for lib in ["crypt32", "ws2_32", "user32", "advapi32", "bcrypt"] {
        println!("cargo:rustc-link-lib={lib}");
    }
    // libxml2 2.11.9 estática (validação contra o XSD).
    let aqui = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    println!("cargo:rustc-link-search=native={aqui}/terceiros/libxml2");
    println!("cargo:rustc-link-lib=static=libxml2s");
}
