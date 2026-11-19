//! Registro central: grava em logs/nfse_AAAAMMDD.log (rotativo) e, de INFO para cima, no console.
//!
//! Formato de cada linha (é o que a tela "Registros > Consultar" lê de volta do disco):
//!   2026-10-09 06:17:32 | INFO    | nfse.registro  | [op#1] mensagem
//! Carimbo de usuário em TODAS as linhas: [op#N] = operador logado; [aut#M] aparece quando
//! outra pessoa autorizou a ação em andamento (popup de senha de nível).
//!
//! As linhas vão para uma fila e uma thread só grava: quem registra não espera o disco.
//! `sincronizar()` espera a fila esvaziar (antes de ler o arquivo, ao fechar o programa).
//!
//! Espaço: um arquivo por dia (troca à meia-noite, mesmo com o programa aberto), girado em
//! .1, .2… quando passa do tamanho de um arquivo. Ao iniciar, na troca de dia, a cada giro e ao
//! mudar a configuração, os arquivos mais velhos que o prazo saem e, se o total passar do
//! limite, saem os mais antigos até caber (Configurações › Avançado › Logs, gravado em
//! logs/config_logs.json). Arquivos de texto com rotação, e não um banco: resistem a queda de
//! energia, abrem em qualquer editor e uma linha estragada não leva as outras junto.
//!
//! Privacidade: o log não recebe senha, certificado nem XML completo. CPF, CNPJ e e-mail são
//! mascarados ao gravar (desligável) e SEMPRE na exportação para o suporte.
use std::borrow::Cow;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Sender, SyncSender};
use std::sync::{Mutex, OnceLock, RwLock};
use std::time::{Duration, SystemTime};

use chrono::Local;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::caminhos;
use crate::erro::{Erro, Res};

/// Cópias giradas por dia (nfse_AAAAMMDD.log.1 … .15): o .1 é o mais novo.
const COPIAS: u32 = 15;
/// Configuração, dentro da pasta de logs: o banco ainda está trancado quando o registro começa,
/// e na instalação só o serviço de dados grava nesta pasta.
const ARQUIVO_CONFIG: &str = "config_logs.json";
pub const OPCOES_MB: [u64; 6] = [20, 50, 100, 200, 500, 1000];
pub const OPCOES_DIAS: [u32; 6] = [15, 30, 90, 180, 365, 730];

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

// ------------------------------------------------------------------------------------------- //
// Configuração
// ------------------------------------------------------------------------------------------- //
/// O que a tela Configurações › Avançado › Logs ajusta.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct ConfigLogs {
    /// Espaço máximo de todos os logs juntos, em MB.
    pub max_mb: u64,
    /// Prazo em dias: arquivos mais velhos que isto são apagados.
    pub dias: u32,
    /// Mascarar CPF, CNPJ e e-mail nas linhas gravadas.
    pub mascarar: bool,
}

impl Default for ConfigLogs {
    fn default() -> Self {
        ConfigLogs {
            max_mb: 100,
            dias: 90,
            mascarar: true,
        }
    }
}

impl ConfigLogs {
    /// Tamanho de um arquivo antes de girar: 1/20 do total, entre 1 e 10 MB.
    pub fn max_arquivo(&self) -> u64 {
        (self.max_mb * 1_048_576 / 20).clamp(1_048_576, 10 * 1_048_576)
    }

    fn normalizada(mut self) -> Self {
        let padrao = ConfigLogs::default();
        if !OPCOES_MB.contains(&self.max_mb) {
            self.max_mb = padrao.max_mb;
        }
        if !OPCOES_DIAS.contains(&self.dias) {
            self.dias = padrao.dias;
        }
        self
    }
}

static CONFIG: RwLock<Option<ConfigLogs>> = RwLock::new(None);

fn ler_config_do_disco() -> ConfigLogs {
    fs::read_to_string(pasta_logs().join(ARQUIVO_CONFIG))
        .ok()
        .and_then(|t| serde_json::from_str::<ConfigLogs>(&t).ok())
        .unwrap_or_default()
        .normalizada()
}

/// A configuração em vigor (lida do disco uma vez).
pub fn config() -> ConfigLogs {
    if let Some(c) = CONFIG
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
    {
        return c.clone();
    }
    let c = ler_config_do_disco();
    *CONFIG.write().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(c.clone());
    c
}

/// Grava a configuração e aplica na hora (a limpeza roda antes de responder).
pub fn configurar(max_mb: u64, dias: u32, mascarar: bool) -> Res<Value> {
    if !OPCOES_MB.contains(&max_mb) {
        return Err(Erro::valor("Tamanho máximo dos logs inválido."));
    }
    if !OPCOES_DIAS.contains(&dias) {
        return Err(Erro::valor("Prazo dos logs inválido."));
    }
    let c = ConfigLogs {
        max_mb,
        dias,
        mascarar,
    };
    let pasta = pasta_logs();
    fs::create_dir_all(&pasta)?;
    let tmp = pasta.join(format!("{ARQUIVO_CONFIG}.tmp"));
    fs::write(&tmp, serde_json::to_vec_pretty(&c)?)?;
    fs::rename(&tmp, pasta.join(ARQUIVO_CONFIG))?;
    *CONFIG.write().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(c);
    info(
        "registro",
        &format!(
            "Logs configurados: até {max_mb} MB, prazo de {dias} dias, mascarar dados pessoais: {}.",
            if mascarar { "sim" } else { "não" }
        ),
    );
    let _ = fila().send(Msg::Limpar);
    sincronizar();
    Ok(situacao())
}

/// Configuração, opções e ocupação atual (para a tela). Lê sempre do disco: na instalação quem
/// grava é o serviço de dados, e a tela pode ler isto no próprio processo.
pub fn situacao() -> Value {
    let c = ler_config_do_disco();
    let pasta = pasta_logs();
    let arquivos = arquivos_de_log(&pasta);
    let total: u64 = arquivos.iter().map(|a| a.tamanho).sum();
    let antigo = arquivos.iter().map(|a| a.modificado).min();
    json!({
        "max_mb": c.max_mb,
        "dias": c.dias,
        "mascarar": c.mascarar,
        "opcoes_mb": OPCOES_MB,
        "opcoes_dias": OPCOES_DIAS,
        "total_bytes": total,
        "arquivos": arquivos.len(),
        "mais_antigo": antigo.map(|t| chrono::DateTime::<Local>::from(t).format("%Y-%m-%dT%H:%M:%S").to_string()),
        "pasta": pasta.to_string_lossy(),
    })
}

// ------------------------------------------------------------------------------------------- //
// Máscara de dados pessoais
// ------------------------------------------------------------------------------------------- //
fn regras_mascara() -> &'static [(Regex, &'static str)] {
    static R: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    R.get_or_init(|| {
        [
            // CNPJ formatado (numérico ou alfanumérico): 12.***.***/0001-**
            (
                r"\b([0-9A-Z]{2})\.[0-9A-Z]{3}\.[0-9A-Z]{3}/([0-9A-Z]{4})-\d{2}\b",
                "$1.***.***/$2-**",
            ),
            // CPF formatado: ***.456.789-**
            (r"\b\d{3}\.(\d{3})\.(\d{3})-\d{2}\b", "***.$1.$2-**"),
            // CNPJ só com números: 12******0001**
            (r"\b(\d{2})\d{6}(\d{4})\d{2}\b", "$1******$2**"),
            // CPF (ou celular com DDD) só com números: ***456789**
            (r"\b\d{3}(\d{6})\d{2}\b", "***$1**"),
            // E-mail: j***@dominio.com.br
            (
                r"\b([A-Za-z0-9])[A-Za-z0-9._%+-]*@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b",
                "$1***@$2",
            ),
        ]
        .into_iter()
        .map(|(rx, troca)| (Regex::new(rx).expect("regex da máscara"), troca))
        .collect()
    })
}

/// Esconde CPF, CNPJ e e-mail, deixando o bastante para reconhecer o registro. Números colados
/// em letras ou em outros números (chave de acesso, id da DPS) ficam como estão.
pub fn mascarar(texto: &str) -> String {
    let mut out = Cow::Borrowed(texto);
    for (rx, troca) in regras_mascara() {
        if rx.is_match(&out) {
            out = Cow::Owned(rx.replace_all(&out, *troca).into_owned());
        }
    }
    out.into_owned()
}

// ------------------------------------------------------------------------------------------- //
// Arquivos e limpeza
// ------------------------------------------------------------------------------------------- //
pub fn pasta_logs() -> PathBuf {
    let configurado = std::env::var("NFSE_LOG_DIR").unwrap_or_default();
    let configurado = configurado.trim();
    if !configurado.is_empty() {
        return caminhos::normalizar(&caminhos::absoluto(configurado));
    }
    caminhos::raiz().join("logs")
}

/// Um arquivo de log visto pela limpeza e pela exportação.
#[derive(Debug, Clone)]
pub struct ArquivoLog {
    pub caminho: PathBuf,
    pub tamanho: u64,
    pub modificado: SystemTime,
}

/// Os arquivos que o programa escreve na pasta de logs: nfse_AAAAMMDD.log[.N] e os históricos
/// de emissão (emissoes/*_workflow.json). O resto da pasta não é tocado.
pub fn arquivos_de_log(pasta: &Path) -> Vec<ArquivoLog> {
    fn ver(dir: &Path, aceita: fn(&str) -> bool, out: &mut Vec<ArquivoLog>) {
        let Ok(itens) = fs::read_dir(dir) else { return };
        for e in itens.flatten() {
            let nome = e.file_name().to_string_lossy().into_owned();
            let Ok(m) = e.metadata() else { continue };
            if m.is_file() && aceita(&nome) {
                out.push(ArquivoLog {
                    caminho: e.path(),
                    tamanho: m.len(),
                    modificado: m.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                });
            }
        }
    }
    let mut out = Vec::new();
    ver(
        pasta,
        |n| n.starts_with("nfse_") && (n.ends_with(".log") || n.contains(".log.")),
        &mut out,
    );
    ver(&pasta.join("emissoes"), |n| n.ends_with("_workflow.json"), &mut out);
    out
}

/// O que a limpeza fez.
#[derive(Debug, Default, PartialEq)]
pub struct Limpeza {
    pub apagados: usize,
    pub bytes: u64,
}

/// Apaga o que passou do prazo e, se ainda assim o total passa do limite, os mais antigos até
/// ficar com 90% do limite. `protegido` (o arquivo em uso) nunca sai, mas conta no total.
pub fn limpar_pasta(
    pasta: &Path,
    c: &ConfigLogs,
    protegido: Option<&Path>,
    agora: SystemTime,
) -> Limpeza {
    let mut feito = Limpeza::default();
    let mut arquivos: Vec<ArquivoLog> = arquivos_de_log(pasta)
        .into_iter()
        .filter(|a| protegido != Some(a.caminho.as_path()))
        .collect();
    let prazo = Duration::from_secs(u64::from(c.dias) * 86_400);
    arquivos.retain(|a| {
        let velho = agora
            .duration_since(a.modificado)
            .is_ok_and(|idade| idade > prazo);
        if velho && fs::remove_file(&a.caminho).is_ok() {
            feito.apagados += 1;
            feito.bytes += a.tamanho;
            return false;
        }
        true
    });
    let limite = c.max_mb * 1_048_576;
    let em_uso = protegido
        .and_then(|p| fs::metadata(p).ok())
        .map_or(0, |m| m.len());
    let mut total: u64 = em_uso + arquivos.iter().map(|a| a.tamanho).sum::<u64>();
    if total > limite {
        arquivos.sort_by_key(|a| a.modificado);
        let alvo = limite / 10 * 9;
        for a in arquivos {
            if total <= alvo {
                break;
            }
            if fs::remove_file(&a.caminho).is_ok() {
                total = total.saturating_sub(a.tamanho);
                feito.apagados += 1;
                feito.bytes += a.tamanho;
            }
        }
    }
    feito
}

// ------------------------------------------------------------------------------------------- //
// Gravação
// ------------------------------------------------------------------------------------------- //
enum Msg {
    Linha { texto: String, console: bool },
    Barreira(Sender<()>),
    Limpar,
}

static FILA: OnceLock<SyncSender<Msg>> = OnceLock::new();
thread_local! {
    static OPERADOR: std::cell::Cell<Option<i64>> = const { std::cell::Cell::new(None) };
}

pub(crate) fn com_operador<T>(id: Option<i64>, acao: impl FnOnce() -> T) -> T {
    struct Restaurar(Option<i64>);
    impl Drop for Restaurar {
        fn drop(&mut self) {
            OPERADOR.set(self.0);
        }
    }
    let _restaurar = Restaurar(OPERADOR.replace(id));
    acao()
}
static INICIO: Mutex<()> = Mutex::new(());

struct Gravador {
    pasta: PathBuf,
    dia: String,
    arquivo: Option<File>,
    tamanho: u64,
}

impl Gravador {
    fn caminho(&self) -> PathBuf {
        self.pasta.join(format!("nfse_{}.log", self.dia))
    }

    fn abrir(&mut self) {
        if self.arquivo.is_some() {
            return;
        }
        let _ = fs::create_dir_all(&self.pasta);
        if let Ok(f) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.caminho())
        {
            self.tamanho = f.metadata().map(|m| m.len()).unwrap_or(0);
            self.arquivo = Some(f);
        }
    }

    /// Rotação do RotatingFileHandler: .1 é o mais novo; o .15 é descartado.
    fn rodar(&mut self) {
        self.arquivo = None;
        let base = self.caminho();
        let nome = |i: u32| PathBuf::from(format!("{}.{}", base.display(), i));
        let _ = fs::remove_file(nome(COPIAS));
        for i in (1..COPIAS).rev() {
            let _ = fs::rename(nome(i), nome(i + 1));
        }
        let _ = fs::rename(&base, nome(1));
        self.tamanho = 0;
    }

    /// Limpeza da pasta; o que saiu fica registrado no próprio log.
    fn limpar(&mut self) {
        let atual = self.caminho();
        let feito = limpar_pasta(&self.pasta, &config(), Some(&atual), SystemTime::now());
        if feito.apagados > 0 {
            let linha = formatar(
                "nfse.registro",
                Nivel::Info,
                &format!(
                    "Limpeza dos logs: {} arquivo(s) antigo(s) apagado(s), {:.1} MB liberados.",
                    feito.apagados,
                    feito.bytes as f64 / 1_048_576.0
                ),
            );
            self.escrever(&linha);
        }
    }

    fn escrever(&mut self, linha: &str) {
        self.abrir();
        if let Some(f) = self.arquivo.as_mut() {
            if writeln!(f, "{linha}").is_ok() {
                self.tamanho += linha.len() as u64 + 1;
            }
            let _ = f.flush();
        }
    }

    fn gravar(&mut self, linha: &str) {
        // Virou o dia com o programa aberto: arquivo novo (a tela de Registros lê pelo nome).
        let hoje = Local::now().format("%Y%m%d").to_string();
        if hoje != self.dia {
            self.arquivo = None;
            self.dia = hoje;
            self.limpar();
        }
        self.abrir();
        if self.tamanho > 0 && self.tamanho + linha.len() as u64 + 1 >= config().max_arquivo() {
            self.rodar();
            self.limpar();
        }
        self.escrever(linha);
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
    let pasta = pasta_logs();
    let (tx, rx) = mpsc::sync_channel::<Msg>(1024);
    std::thread::Builder::new()
        .name("registro".into())
        .spawn(move || {
            let mut g = Gravador {
                pasta,
                dia: Local::now().format("%Y%m%d").to_string(),
                arquivo: None,
                tamanho: 0,
            };
            g.limpar();
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
                    Msg::Limpar => g.limpar(),
                }
            }
        })
        .expect("thread do registro");
    let _ = FILA.set(tx);
    let f = FILA.get().unwrap();
    enviar(f, "nfse", Nivel::Info, "==== Log iniciado ====");
    f
}

fn formatar(nome: &str, nivel: Nivel, msg: &str) -> String {
    let msg = if config().mascarar {
        mascarar(msg)
    } else {
        msg.to_string()
    };
    let operador = OPERADOR.get().map_or_else(String::new, |id| format!(" [op#{id}]"));
    format!(
        "{} | {:<7} | {:<14} |{} {}",
        Local::now().format("%Y-%m-%d %H:%M:%S"),
        nivel.nome(),
        nome,
        operador,
        msg
    )
}

fn enviar(f: &SyncSender<Msg>, nome: &str, nivel: Nivel, msg: &str) {
    let texto = formatar(nome, nivel, msg);
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

/// Faz os panics (erros internos do núcleo, em qualquer thread) chegarem ao log em disco, e não
/// só ao console. O comportamento padrão continua (mensagem no console). Instalar uma vez.
pub fn registrar_panicos() {
    static FEITO: OnceLock<()> = OnceLock::new();
    FEITO.get_or_init(|| {
        let anterior = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let thread = std::thread::current();
            let onde = info
                .location()
                .map(|l| format!(" em {}:{}", l.file(), l.line()))
                .unwrap_or_default();
            let msg = info
                .payload()
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| info.payload().downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "erro interno".into());
            // A thread do registro não pode registrar o próprio pânico (a fila seria ela mesma).
            if thread.name() != Some("registro") {
                critico(
                    "nucleo",
                    &format!(
                        "Falha interna (panic) na thread {}{onde}: {msg}",
                        thread.name().unwrap_or("sem nome")
                    ),
                );
            }
            anterior(info);
        }));
    });
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

// ------------------------------------------------------------------------------------------- //
// Exportação para o suporte
// ------------------------------------------------------------------------------------------- //
/// Arquivos do atualizador que vão junto (ficam na pasta do programa, em service/).
const ARQUIVOS_ATUALIZADOR: [&str; 4] = [
    "atualizador.log",
    "atualizador.log.1",
    "last-result.txt",
    "progress.json",
];

/// Gera um .zip com os logs dos últimos `dias` (todos se 0), o log do atualizador e um resumo
/// do sistema, para mandar ao suporte. CPF, CNPJ e e-mail saem SEMPRE mascarados. Roda no
/// serviço e cria o arquivo de destino com a identidade de quem solicitou.
pub fn exportar_suporte(destino: &Path, dias: u32) -> Res<Value> {
    use zip::write::SimpleFileOptions;
    sincronizar();
    let pasta = pasta_logs();
    let corte = (dias > 0).then(|| {
        SystemTime::now()
            .checked_sub(Duration::from_secs(u64::from(dias) * 86_400))
            .unwrap_or(SystemTime::UNIX_EPOCH)
    });
    let mut arquivos: Vec<ArquivoLog> = arquivos_de_log(&pasta)
        .into_iter()
        .filter(|a| corte.is_none_or(|c| a.modificado >= c))
        .collect();
    arquivos.sort_by(|a, b| a.caminho.cmp(&b.caminho));

    let tmp = destino.with_extension("zip.tmp");
    let mut zip = zip::ZipWriter::new(caminhos::arquivo_usuario(|| File::create(&tmp))?);
    let opcoes = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    let mut incluir = |nome: &str, bytes: &[u8]| -> Res<()> {
        zip.start_file(nome, opcoes)
            .map_err(|e| Erro::os(format!("Não foi possível montar o .zip: {e}")))?;
        let texto = String::from_utf8_lossy(bytes);
        zip.write_all(mascarar(&texto).as_bytes())?;
        Ok(())
    };
    let mut incluidos = 0usize;
    for a in &arquivos {
        let Ok(bytes) = fs::read(&a.caminho) else { continue };
        let rel = a
            .caminho
            .strip_prefix(&pasta)
            .unwrap_or(&a.caminho)
            .to_string_lossy()
            .replace('\\', "/");
        incluir(&format!("logs/{rel}"), &bytes)?;
        incluidos += 1;
    }
    let servico = caminhos::programa().join("service");
    for nome in ARQUIVOS_ATUALIZADOR {
        if let Ok(bytes) = fs::read(servico.join(nome)) {
            incluir(&format!("atualizador/{nome}"), &bytes)?;
            incluidos += 1;
        }
    }
    incluir("sistema.txt", resumo_sistema().as_bytes())?;
    zip.finish()
        .map_err(|e| Erro::os(format!("Não foi possível concluir o .zip: {e}")))?;
    caminhos::arquivo_usuario(|| fs::rename(&tmp, destino))?;
    let tamanho = caminhos::arquivo_usuario(|| fs::metadata(destino)).map(|m| m.len()).unwrap_or(0);
    info(
        "registro",
        &format!("Logs exportados para o suporte: {incluidos} arquivo(s)."),
    );
    Ok(json!({ "arquivo": destino.to_string_lossy(), "arquivos": incluidos, "tamanho": tamanho }))
}

/// Versão, modo de instalação e configuração dos logs, para o suporte saber onde olhar.
fn resumo_sistema() -> String {
    let c = config();
    #[cfg(windows)]
    let servico_dados = crate::dados_windows::servico_registrado();
    #[cfg(not(windows))]
    let servico_dados = false;
    let instalado = caminhos::instalado_compartilhado();
    let versao_programa = fs::read_to_string(caminhos::programa().join("release-version.txt"))
        .unwrap_or_default();
    [
        format!("Baiacu NFS-e {}", crate::atualizacao::VERSAO),
        format!("Versão do pacote: {}", versao_programa.trim()),
        format!("Gerado em: {}", Local::now().format("%d/%m/%Y %H:%M:%S")),
        format!(
            "Modo: {}",
            if instalado { "instalado" } else { "portátil/desenvolvimento" }
        ),
        format!(
            "Serviço de dados: {}",
            if servico_dados {
                "registrado"
            } else if instalado {
                "AUSENTE (atualizado pelo botão; execute o instalador)"
            } else {
                "não se aplica"
            }
        ),
        format!(
            "Sistema: {} {}",
            std::env::consts::OS,
            std::env::consts::ARCH
        ),
        format!(
            "Logs: até {} MB, prazo de {} dias, mascarar ao gravar: {}",
            c.max_mb,
            c.dias,
            if c.mascarar { "sim" } else { "não" }
        ),
        String::new(),
    ]
    .join("\r\n")
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn mascara_documentos_e_email() {
        assert_eq!(
            mascarar("Prestador 12.345.678/0001-90 ok"),
            "Prestador 12.***.***/0001-** ok"
        );
        assert_eq!(mascarar("CPF 123.456.789-09."), "CPF ***.456.789-**.");
        assert_eq!(mascarar("doc=12345678000190;"), "doc=12******0001**;");
        assert_eq!(mascarar("tomador 12345678909"), "tomador ***456789**");
        assert_eq!(
            mascarar("enviado a fulano.tal@empresa.com.br"),
            "enviado a f***@empresa.com.br"
        );
        // Chave de acesso (50 dígitos) e id da DPS ficam como estão.
        let chave = "35503082123456780001900000000000000012345678901234";
        assert_eq!(mascarar(chave), chave);
        let dps = "DPS355030821234567800019000001000000000000123";
        assert_eq!(mascarar(dps), dps);
        // Código IBGE e números curtos também.
        assert_eq!(mascarar("município 3550308, nota 123"), "município 3550308, nota 123");
    }

    #[test]
    fn limpeza_por_prazo_e_por_tamanho() {
        let base = std::env::temp_dir().join(format!("baiacu_logs_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(base.join("emissoes")).unwrap();
        let agora = SystemTime::now();
        let escrever = |nome: &str, bytes: usize, idade_dias: u64| {
            let p = base.join(nome);
            fs::write(&p, vec![b'x'; bytes]).unwrap();
            let quando = agora - Duration::from_secs(idade_dias * 86_400);
            File::options()
                .write(true)
                .open(&p)
                .unwrap()
                .set_modified(quando)
                .unwrap();
            p
        };
        escrever("nfse_20250101.log", 10, 400);
        escrever("emissoes/20250101_000000_000000_workflow.json", 10, 400);
        escrever("outro.txt", 10, 400); // não é do programa: fica
        let c = ConfigLogs {
            max_mb: 20,
            dias: 30,
            mascarar: true,
        };
        let feito = limpar_pasta(&base, &c, None, agora);
        assert_eq!(feito.apagados, 2);
        assert!(base.join("outro.txt").is_file());

        // Tamanho: 25 MB em três dias; o limite é 20 MB → o mais velho sai.
        let mb = 1_048_576;
        let velho = escrever("nfse_20261101.log", 10 * mb, 3);
        let meio = escrever("nfse_20261102.log", 10 * mb, 2);
        let atual = escrever("nfse_20261103.log", 5 * mb, 0);
        let feito = limpar_pasta(&base, &c, Some(&atual), agora);
        assert_eq!(feito.apagados, 1);
        assert!(!velho.exists() && meio.exists() && atual.exists());
        let _ = fs::remove_dir_all(&base);
    }
}
