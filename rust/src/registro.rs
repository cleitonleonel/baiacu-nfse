//! Registro central: grava em logs/nfse_AAAAMMDD.log (rotativo) e, de INFO para cima, no console.
//!
//! Formato de cada linha (é o que a tela "Registros > Consultar" lê de volta do disco):
//!   2026-10-09 06:17:32 | INFO    | nfse.registro  | [op#1] mensagem
//! Carimbo de usuário em TODAS as linhas: [op#N] = operador logado; [aut#M] aparece quando
//! outra pessoa autorizou a ação em andamento (popup de senha de nível).
//!
//! As linhas vão para uma fila e uma thread só grava: quem registra não espera o disco.
//! `sincronizar()` espera a fila esvaziar (antes de ler o arquivo, ao fechar o programa).
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::{self, Sender, SyncSender};
use std::sync::{Mutex, OnceLock, RwLock};

use chrono::Local;

use crate::caminhos;

const MAX_BYTES: u64 = 3_000_000;
const COPIAS: u32 = 15;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Nivel {
    Debug,
    Info,
    Warning,
    Error,
    Critical,
}

impl Nivel {
    fn nome(self) -> &'static str {
        match self {
            Nivel::Debug => "DEBUG",
            Nivel::Info => "INFO",
            Nivel::Warning => "WARNING",
            Nivel::Error => "ERROR",
            Nivel::Critical => "CRITICAL",
        }
    }
}

enum Msg {
    Linha { texto: String, console: bool },
    Barreira(Sender<()>),
}

static FILA: OnceLock<SyncSender<Msg>> = OnceLock::new();
static CARIMBO: RwLock<String> = RwLock::new(String::new());
static INICIO: Mutex<()> = Mutex::new(());

pub fn pasta_logs() -> PathBuf {
    let configurado = std::env::var("NFSE_LOG_DIR").unwrap_or_default();
    let configurado = configurado.trim();
    if !configurado.is_empty() {
        return caminhos::normalizar(&caminhos::absoluto(configurado));
    }
    caminhos::raiz().join("logs")
}

struct Gravador {
    caminho: PathBuf,
    arquivo: Option<File>,
    tamanho: u64,
}

impl Gravador {
    fn abrir(&mut self) {
        if self.arquivo.is_some() {
            return;
        }
        if let Some(pai) = self.caminho.parent() {
            let _ = fs::create_dir_all(pai);
        }
        if let Ok(f) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.caminho)
        {
            self.tamanho = f.metadata().map(|m| m.len()).unwrap_or(0);
            self.arquivo = Some(f);
        }
    }

    /// Rotação do RotatingFileHandler: .1 é o mais novo; o .15 é descartado.
    fn rodar(&mut self) {
        self.arquivo = None;
        let nome = |i: u32| PathBuf::from(format!("{}.{}", self.caminho.display(), i));
        let _ = fs::remove_file(nome(COPIAS));
        for i in (1..COPIAS).rev() {
            let _ = fs::rename(nome(i), nome(i + 1));
        }
        let _ = fs::rename(&self.caminho, nome(1));
        self.tamanho = 0;
    }

    fn gravar(&mut self, linha: &str) {
        self.abrir();
        if self.tamanho > 0 && self.tamanho + linha.len() as u64 + 1 >= MAX_BYTES {
            self.rodar();
            self.abrir();
        }
        if let Some(f) = self.arquivo.as_mut() {
            if writeln!(f, "{linha}").is_ok() {
                self.tamanho += linha.len() as u64 + 1;
            }
            let _ = f.flush();
        }
    }
}

fn fila() -> &'static SyncSender<Msg> {
    if let Some(f) = FILA.get() {
        return f;
    }
    let _guarda = INICIO.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(f) = FILA.get() {
        return f;
    }
    let arquivo = pasta_logs().join(format!("nfse_{}.log", Local::now().format("%Y%m%d")));
    let (tx, rx) = mpsc::sync_channel::<Msg>(1024);
    std::thread::Builder::new()
        .name("registro".into())
        .spawn(move || {
            let mut g = Gravador {
                caminho: arquivo,
                arquivo: None,
                tamanho: 0,
            };
            for msg in rx {
                match msg {
                    Msg::Linha { texto, console } => {
                        g.gravar(&texto);
                        if console {
                            eprintln!("{texto}");
                        }
                    }
                    Msg::Barreira(pronto) => {
                        let _ = pronto.send(());
                    }
                }
            }
        })
        .expect("thread do registro");
    let _ = FILA.set(tx);
    let f = FILA.get().unwrap();
    enviar(f, "nfse", Nivel::Info, "==== Log iniciado ====");
    f
}

fn enviar(f: &SyncSender<Msg>, nome: &str, nivel: Nivel, msg: &str) {
    let texto = format!(
        "{} | {:<7} | {:<14} |{} {}",
        Local::now().format("%Y-%m-%d %H:%M:%S"),
        nivel.nome(),
        nome,
        CARIMBO.read().unwrap_or_else(std::sync::PoisonError::into_inner),
        msg
    );
    let _ = f.send(Msg::Linha {
        texto,
        console: nivel >= Nivel::Info,
    });
}

/// Registra uma linha. `nome` sem o prefixo: "gui", "cofre", "registro"...
pub fn registrar(nome: &str, nivel: Nivel, msg: &str) {
    enviar(fila(), &format!("nfse.{nome}"), nivel, msg);
}

pub fn info(nome: &str, msg: &str) {
    registrar(nome, Nivel::Info, msg);
}

pub fn aviso(nome: &str, msg: &str) {
    registrar(nome, Nivel::Warning, msg);
}

pub fn erro(nome: &str, msg: &str) {
    registrar(nome, Nivel::Error, msg);
}

pub fn critico(nome: &str, msg: &str) {
    registrar(nome, Nivel::Critical, msg);
}

/// Espera tudo o que já foi registrado chegar ao arquivo.
pub fn sincronizar() {
    if let Some(f) = FILA.get() {
        let (tx, rx) = mpsc::channel();
        if f.send(Msg::Barreira(tx)).is_ok() {
            let _ = rx.recv();
        }
    }
}

/// Define o usuário carimbado nas linhas (a tela chama no login e nas autorizações).
pub fn definir_usuario(operador_id: Option<i64>, autorizador_id: Option<i64>) {
    let mut partes: Vec<String> = Vec::new();
    if let Some(op) = operador_id.filter(|v| *v != 0) {
        partes.push(format!("op#{op}"));
    }
    if let Some(aut) = autorizador_id.filter(|v| *v != 0) {
        if Some(aut) != operador_id {
            partes.push(format!("aut#{aut}"));
        }
    }
    *CARIMBO.write().unwrap_or_else(std::sync::PoisonError::into_inner) = if partes.is_empty() {
        String::new()
    } else {
        format!(" [{}]", partes.join(" "))
    };
}
