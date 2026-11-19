//! Cofre de NFS-e: TODAS as notas em que o prestador aparece — emitidas e recebidas — guardadas
//! num banco à parte, database/notas.db. Nada fica solto em pastas; a DANFSe não é guardada (é
//! gerada na hora, a partir do XML, quando o usuário pede).
//!
//! DE ONDE VÊM AS NOTAS
//! - Do ADN (Ambiente de Dados Nacional): a distribuição de DF-e por NSU devolve, em lotes, todo
//!   documento em que o CNPJ consultado participa — NFS-e que ele emitiu, NFS-e emitidas CONTRA
//!   ele (recebidas) e os eventos dessas notas. O último NSU fica gravado por prestador e
//!   ambiente: a consulta seguinte continua de onde a anterior parou.
//! - Da EMISSÃO: toda NFS-e que este programa emite é guardada aqui na hora (origem 'local');
//!   são essas que a tela Consultar lista. Quando o ADN devolve a mesma nota, ela é reconhecida
//!   pela chave de acesso e não entra duas vezes.
//!
//! O BANCO
//! - Cifrado (SQLCipher) com chave própria, aleatória, guardada DENTRO do dados.db (tabela
//!   meta). Quem abre o dados.db abre o cofre; trocar a senha mestra não mexe nele.
//! - Cada XML é guardado byte a byte como chegou (a assinatura não pode mudar) e compactado. O
//!   que mais pesa num XML de NFS-e são os dois certificados das assinaturas, iguais de uma nota
//!   para a outra: o texto de cada certificado é guardado UMA vez (tabela cert) e serve de
//!   "dicionário" do compactador para todas as notas que o trazem. Toda gravação é conferida
//!   (descompacta e compara) antes de valer, e toda leitura confere a impressão digital
//!   (SHA-256) do XML.
//!
//! O QUE PROTEGE O BANCO: cada lote e o cursor entram numa transação só; nada do que não chegou
//! inteiro é gravado; `verificar()` confere a assinatura de cada página e a estrutura; há uma
//! cópia de segurança (database/notas.db.bak) refeita depois de conferir; e, se o notas.db sumir,
//! não abrir ou não passar na conferência, o arquivo ruim é guardado com outro nome e a cópia
//! volta para o lugar.
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use flate2::{Compress, Compression, Decompress, FlushCompress, FlushDecompress, Status};
use regex::bytes::Regex;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::caminhos;
use crate::erro::{Erro, Res};
use crate::texto::aparar;
use crate::xml::{self, Elemento};
use crate::{banco, busca, jsonpy, pyfmt, registro, texto};

pub const AMB_PRODUCAO: &str = "1";
pub const AMB_HOMOLOGACAO: &str = "2";

fn host(amb: &str) -> Option<&'static str> {
    match amb {
        AMB_PRODUCAO => Some("adn.nfse.gov.br"),
        AMB_HOMOLOGACAO => Some("adn.producaorestrita.nfse.gov.br"),
        _ => None,
    }
}

// ---- limites e paciência com o ADN -------------------------------------------------------------
pub const TIMEOUT: (f64, f64) = (15.0, 120.0); // segundos para conectar / para o ADN responder um lote
const INTERVALO_LOTES: f64 = 1.0; // pausa entre um lote e o seguinte
const MAX_TENTATIVAS: usize = 5; // por requisição
const ESPERA_429: u64 = 60; // "muitas requisições" sem Retry-After
const ESPERA_429_MAX: u64 = 300; // teto para o Retry-After que o ADN mandar
const ESPERA_FALHA: [u64; 5] = [3, 6, 12, 24, 30]; // falha de rede / HTTP 5xx: intervalo crescente
const MAX_LOTES: usize = 2000; // por execução (cada lote traz até 50 documentos)
const INTERVALO_MIN: f64 = 60.0; // entre duas sincronizações que terminaram "em dia"

pub const PAPEL_EMITIDA: &str = "E";
pub const PAPEL_RECEBIDA: &str = "R";
pub const PAPEL_OUTRO: &str = "I";
/// Eventos que tiram a validade da nota: cancelamento, cancelamento por substituição,
/// cancelamento deferido por análise fiscal e por ofício.
const EVENTOS_CANCELAM: [&str; 4] = ["e101101", "e105102", "e105104", "e305101"];
const EVENTO_SUBSTITUICAO: &str = "e105102";
const MOLDE_MAX: usize = 8000;

fn rx_cert() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"<(?:[A-Za-z0-9_]+:)?X509Certificate>([^<]+)</").expect("regex"))
}

/// O que NUNCA se repete de um XML para outro (assinatura, resumo) e os certificados (que têm
/// tabela própria) saem do molde: só ocupariam espaço nele.
fn rx_unicos() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"(<(?:[A-Za-z0-9_]+:)?(?:X509Certificate|SignatureValue|DigestValue)>)[^<]+(</)",
        )
        .expect("regex")
    })
}

// ---- erros ---------------------------------------------------------------------------------------
/// Falha com mensagem pronta para o usuário.
pub fn erro(msg: impl Into<String>) -> Erro {
    Erro::novo("CofreErro", msg)
}

/// O notas.db existe mas não abre com a chave guardada neste dados.db.
fn ilegivel(msg: impl Into<String>) -> Erro {
    Erro::novo("CofreIlegivel", msg)
}

/// O ADN não respondeu (rede, 5xx, limite de consultas) depois de todas as tentativas.
fn indisponivel(msg: impl Into<String>) -> Erro {
    Erro::novo("CofreIndisponivel", msg)
}

/// A consulta foi recusada AQUI: o ADN acabou de ser consultado e não havia nada novo.
fn recente(msg: impl Into<String>) -> Erro {
    Erro::novo("CofreRecente", msg)
}

/// O erro é do cofre (qualquer um deles)?
pub fn e_do_cofre(e: &Erro) -> bool {
    matches!(
        e.tipo,
        "CofreErro" | "CofreIlegivel" | "CofreIndisponivel" | "CofreRecente"
    )
}

const CANCELADO: &str = "_Cancelado";

fn cancelado() -> Erro {
    Erro::novo(CANCELADO, "cancelado")
}

use crate::erro::{sqlite_msg as msg_sqlite, sqlite_operacional as operacional};

// ---- estado do módulo ------------------------------------------------------------------------------
#[derive(Default)]
struct Estado {
    /// Caminho do banco cujas tabelas já foram conferidas.
    pronto: Option<PathBuf>,
    /// O que foi recuperado NESTA sessão (para avisar).
    recuperacoes: Vec<Value>,
}

fn estado() -> &'static Mutex<Estado> {
    static E: OnceLock<Mutex<Estado>> = OnceLock::new();
    E.get_or_init(|| Mutex::new(Estado::default()))
}

#[derive(Default)]
struct Caches {
    cert: HashMap<i64, Vec<u8>>,
    molde: HashMap<i64, Vec<u8>>,
}

fn caches() -> &'static Mutex<Caches> {
    static C: OnceLock<Mutex<Caches>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(Caches::default()))
}

fn limpar_caches() {
    if let Ok(mut c) = caches().lock() {
        c.cert.clear();
        c.molde.clear();
    }
}

/// Sobe quando um prestador é APAGADO do cofre (`apagar_dono`). Quem grava por um dono anota o
/// número no começo e confere de novo dentro da própria transação: se mudou, o prestador foi
/// deletado no meio do caminho e nada mais entra em nome dele.
fn geracoes() -> &'static Mutex<HashMap<String, u64>> {
    static G: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
    G.get_or_init(|| Mutex::new(HashMap::new()))
}

fn geracao_de(dono: &str) -> u64 {
    geracoes()
        .lock()
        .map(|g| g.get(dono).copied().unwrap_or(0))
        .unwrap_or(0)
}

fn conferir_geracao(dono: &str, geracao: Option<u64>) -> Res<()> {
    match geracao {
        Some(g) if geracao_de(dono) != g => Err(Erro::novo(CANCELADO, "apagado")),
        _ => Ok(()),
    }
}

/// Uma sincronização por vez.
static SINC: AtomicBool = AtomicBool::new(false);

struct TravaSinc;

impl TravaSinc {
    fn pegar() -> Option<TravaSinc> {
        SINC.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .ok()
            .map(|_| TravaSinc)
    }
}

impl Drop for TravaSinc {
    fn drop(&mut self) {
        SINC.store(false, Ordering::SeqCst);
    }
}

// --------------------------------------------------------------------------------------------- //
// Banco
// --------------------------------------------------------------------------------------------- //
const DDL: &str = "
    CREATE TABLE IF NOT EXISTS cert (
        id INTEGER PRIMARY KEY, sha TEXT NOT NULL UNIQUE, texto BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS molde (
        id INTEGER PRIMARY KEY, tipo TEXT NOT NULL, dono TEXT NOT NULL, papel TEXT NOT NULL,
        dados BLOB NOT NULL);
    CREATE INDEX IF NOT EXISTS molde_de ON molde (tipo, dono, papel);
    CREATE TABLE IF NOT EXISTS nota (
        id INTEGER PRIMARY KEY,
        dono TEXT NOT NULL, amb TEXT NOT NULL, chave TEXT NOT NULL, papel TEXT NOT NULL,
        nsu INTEGER, nNFSe TEXT NOT NULL DEFAULT '', nNFSe_int INTEGER NOT NULL DEFAULT 0,
        dhProc TEXT NOT NULL DEFAULT '', dt TEXT NOT NULL DEFAULT '', dCompet TEXT NOT NULL DEFAULT '',
        emit_doc TEXT NOT NULL DEFAULT '', emit_nome TEXT NOT NULL DEFAULT '',
        toma_doc TEXT NOT NULL DEFAULT '', toma_nome TEXT NOT NULL DEFAULT '',
        busca TEXT NOT NULL DEFAULT '',
        vServ REAL NOT NULL DEFAULT 0, vLiq REAL NOT NULL DEFAULT 0, cStat TEXT NOT NULL DEFAULT '',
        cancelada INTEGER NOT NULL DEFAULT 0, subst_por TEXT NOT NULL DEFAULT '',
        origem TEXT NOT NULL, entrou INTEGER NOT NULL,
        UNIQUE (dono, chave));
    CREATE INDEX IF NOT EXISTS nota_dt ON nota (dono, dt);
    CREATE INDEX IF NOT EXISTS nota_processada ON nota (dono, dhProc);
    CREATE INDEX IF NOT EXISTS nota_totais ON nota (dono, dt, amb, papel, origem, cancelada, vServ);
    CREATE TABLE IF NOT EXISTS nota_xml (
        nota INTEGER PRIMARY KEY, sha BLOB NOT NULL, tam INTEGER NOT NULL,
        certs TEXT NOT NULL, molde INTEGER NOT NULL, dados BLOB NOT NULL);
    CREATE INDEX IF NOT EXISTS nota_xml_certs ON nota_xml (certs) WHERE certs <> '';
    CREATE TABLE IF NOT EXISTS evento (
        id INTEGER PRIMARY KEY,
        dono TEXT NOT NULL, amb TEXT NOT NULL, chave TEXT NOT NULL, tipo TEXT NOT NULL,
        descricao TEXT NOT NULL DEFAULT '', dh TEXT NOT NULL DEFAULT '', subst_por TEXT NOT NULL DEFAULT '',
        nsu INTEGER, origem TEXT NOT NULL, entrou INTEGER NOT NULL,
        sha BLOB NOT NULL, tam INTEGER NOT NULL, certs TEXT NOT NULL, molde INTEGER NOT NULL,
        dados BLOB NOT NULL,
        UNIQUE (dono, sha));
    CREATE INDEX IF NOT EXISTS evento_chave ON evento (dono, chave);
    CREATE INDEX IF NOT EXISTS evento_certs ON evento (certs) WHERE certs <> '';
    CREATE TABLE IF NOT EXISTS cursor (
        dono TEXT NOT NULL, amb TEXT NOT NULL, nsu INTEGER NOT NULL DEFAULT 0,
        quando TEXT NOT NULL DEFAULT '', em_dia INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (dono, amb));
    CREATE TABLE IF NOT EXISTS quarentena (
        id INTEGER PRIMARY KEY, dono TEXT NOT NULL, amb TEXT NOT NULL, nsu INTEGER,
        chave TEXT NOT NULL DEFAULT '', erro TEXT NOT NULL, entrou INTEGER NOT NULL, bruto BLOB NOT NULL);
";

/// database/notas.db.
pub fn caminho_db() -> PathBuf {
    banco::caminho_db().with_file_name("notas.db")
}

/// A cópia de segurança (mesma chave).
pub fn caminho_copia() -> PathBuf {
    banco::caminho_db().with_file_name("notas.db.bak")
}

const COPIA_IDADE_H: f64 = 24.0; // refeita, no máximo, uma vez por dia

fn com_sufixo(p: &Path, sufixo: &str) -> PathBuf {
    let mut s = p.as_os_str().to_os_string();
    s.push(sufixo);
    PathBuf::from(s)
}

fn arquivo_com_conteudo(p: &Path) -> bool {
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.len() > 0)
        .unwrap_or(false)
}

pub fn existe() -> bool {
    arquivo_com_conteudo(&caminho_db())
}

/// A chave do notas.db (cria e guarda uma, se ainda não há banco de notas).
fn chave() -> Res<Vec<u8>> {
    let hexa = banco::get_meta(banco::META_CHAVE_NOTAS)?;
    if !hexa.is_empty() {
        return hex::decode(&hexa).map_err(|_| {
            ilegivel("A chave do banco de notas guardada no banco de dados é inválida.")
        });
    }
    if existe() {
        return Err(ilegivel(
            "O banco de notas (database/notas.db) é de outra instalação: a chave que o abre não está neste banco de \
             dados. Restaure o dados.db que acompanha esse arquivo ou retire o notas.db da pasta data para o \
             programa criar outro e sincronizar de novo.",
        ));
    }
    let nova = crate::chaves::aleatorio(32);
    banco::set_meta(banco::META_CHAVE_NOTAS, &hex::encode(&nova))?;
    registro::info("cofre", "Chave do banco de notas criada.");
    Ok(nova)
}

fn ligar(chave: &[u8], caminho: &Path) -> Result<Connection, rusqlite::Error> {
    let con = Connection::open(caminho)?;
    con.busy_timeout(Duration::from_secs(30))?;
    con.execute_batch("PRAGMA cipher_log_level = NONE;")?;
    con.execute_batch(&format!("PRAGMA key = \"x'{}'\";", hex::encode(chave)))?;
    // Durabilidade máxima: cada transação só "vale" depois de estar no disco, e o diário de
    // reversão é um arquivo ao lado (apagado no fim) — em repouso, um arquivo só.
    con.execute_batch("PRAGMA synchronous=FULL;")?;
    con.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
        r.get::<_, i64>(0)
    })?; // a chave abre?
    Ok(con)
}

/// Recuperações feitas nesta sessão que a tela ainda não avisou (esvazia a lista).
pub fn recuperacoes() -> Vec<Value> {
    estado()
        .lock()
        .map(|mut e| std::mem::take(&mut e.recuperacoes))
        .unwrap_or_default()
}

/// Existe cópia de segurança e ela abre com a chave deste banco?
fn copia_serve(chave: &[u8]) -> bool {
    let copia = caminho_copia();
    arquivo_com_conteudo(&copia) && ligar(chave, &copia).is_ok()
}

/// Nome ainda livre para guardar um notas.db estragado (nunca por cima de outro).
fn nome_danificado() -> PathBuf {
    let db = caminho_db();
    let base = format!(
        "notas.db.danificado-{}",
        chrono::Local::now().format("%Y%m%d-%H%M%S")
    );
    let mut destino = db.with_file_name(&base);
    let mut n = 1;
    while destino.exists() {
        n += 1;
        destino = db.with_file_name(format!("{base}-{n}"));
    }
    destino
}

fn data_do_arquivo(p: &Path) -> String {
    std::fs::metadata(p)
        .and_then(|m| m.modified())
        .map(|t| {
            chrono::DateTime::<chrono::Local>::from(t)
                .format("%Y-%m-%dT%H:%M:%S")
                .to_string()
        })
        .unwrap_or_default()
}

fn nome_de(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Troca o notas.db (ausente ou estragado) pela cópia de segurança. O arquivo ruim NÃO é
/// apagado: fica ao lado como notas.db.danificado-<data>. Devolve false se não há cópia boa.
/// Cada passo é uma troca de nome: cair no meio deixa um estado que a próxima abertura resolve.
fn recuperar(est: &mut Estado, chave: &[u8], motivo: &str) -> Res<bool> {
    if !copia_serve(chave) {
        return Ok(false);
    }
    let (db, copia) = (caminho_db(), caminho_copia());
    let novo = com_sufixo(&db, ".recuperando");
    std::fs::copy(&copia, &novo)?;
    let mut guardado = String::new();
    if db.exists() {
        let destino = nome_danificado();
        std::fs::rename(&db, &destino)?;
        guardado = nome_de(&destino);
        for sufixo in ["-journal", "-wal", "-shm"] {
            // diário do arquivo ruim: vai junto
            let resto = com_sufixo(&db, sufixo);
            if resto.exists() {
                let _ = std::fs::rename(&resto, com_sufixo(&destino, sufixo));
            }
        }
    }
    std::fs::rename(&novo, &db)?;
    est.pronto = None;
    limpar_caches();
    let quando = data_do_arquivo(&copia);
    est.recuperacoes
        .push(json!({ "motivo": motivo, "copia_de": quando, "guardado": guardado }));
    registro::erro(
        "cofre",
        &format!(
            "Banco de notas RECUPERADO da cópia de segurança de {quando} ({motivo}). Arquivo anterior: {}",
            if guardado.is_empty() {
                "não existia"
            } else {
                &guardado
            }
        ),
    );
    Ok(true)
}

/// Conexão com o notas.db (cria o arquivo e as tabelas na primeira vez).
pub fn conn() -> Res<Connection> {
    let mut est = estado()
        .lock()
        .map_err(|_| erro("O banco de notas está indisponível."))?;
    let chave = chave()?;
    let db = caminho_db();
    if let Some(pai) = db.parent() {
        std::fs::create_dir_all(pai)?;
    }
    if est.pronto.as_deref() != Some(db.as_path()) || !existe() {
        est.pronto = None;
        limpar_caches();
    }
    if !existe() {
        // O notas.db sumiu (apagado, disco trocado, queda no meio de uma recuperação): havendo
        // cópia de segurança, é dela que o cofre renasce — não de um banco vazio.
        recuperar(&mut est, &chave, "o arquivo notas.db não estava na pasta")?;
    }
    let con = match ligar(&chave, &db) {
        Ok(c) => c,
        Err(e) if operacional(&e) => {
            // Ocupado, sem permissão, disco cheio/com erro: o arquivo pode estar perfeito. NADA
            // de recuperação aqui — trocar um banco bom pela cópia perderia notas.
            return Err(erro(format!(
                "O banco de notas não pôde ser aberto agora ({}). Tente de novo em instantes.",
                msg_sqlite(&e)
            )));
        }
        Err(e) => {
            if recuperar(
                &mut est,
                &chave,
                &format!("o arquivo não abriu ({})", msg_sqlite(&e)),
            )? {
                // A cópia de segurança abre com a chave daqui: o problema era o arquivo.
                ligar(&chave, &db)?
            } else {
                return Err(ilegivel(format!(
                    "O banco de notas (database/notas.db) não abriu com a chave deste banco de dados ({}). Ele pode \
                     ser de outra instalação ou estar danificado, e não há cópia de segurança (notas.db.bak) que \
                     sirva.",
                    msg_sqlite(&e)
                )));
            }
        }
    };
    if est.pronto.is_none() {
        con.execute_batch(DDL)?;
        est.pronto = Some(db);
    }
    Ok(con)
}

/// Roda `f` numa transação de escrita: ou vale tudo, ou nada muda.
fn transacao<T>(con: &Connection, f: impl FnOnce() -> Res<T>) -> Res<T> {
    con.execute_batch("BEGIN IMMEDIATE")?;
    match f() {
        Ok(v) => match con.execute_batch("COMMIT") {
            Ok(()) => Ok(v),
            Err(e) => {
                let _ = con.execute_batch("ROLLBACK");
                Err(e.into())
            }
        },
        Err(e) => {
            let _ = con.execute_batch("ROLLBACK");
            Err(e)
        }
    }
}

/// Texto de busca de uma nota do cofre: a OUTRA parte (o tomador nas emitidas, o emitente nas
/// demais), nº, os dois valores e a data — igual ao da Consulta.
fn texto_busca(papel: &str, i: &InfoNfse) -> String {
    let (doc, nome) = if papel == PAPEL_EMITIDA {
        (&i.toma_doc, &i.toma_nome)
    } else {
        (&i.emit_doc, &i.emit_nome)
    };
    let data = if i.dh_proc.is_empty() {
        &i.d_compet
    } else {
        &i.dh_proc
    };
    busca::texto(nome, doc, &i.n_nfse, &[i.v_serv, i.v_liq], data)
}

fn agora() -> String {
    chrono::Local::now().format("%Y-%m-%dT%H:%M:%S").to_string()
}

fn epoca() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// --------------------------------------------------------------------------------------------- //
// Compactação com os certificados fora da nota
// --------------------------------------------------------------------------------------------- //
fn sha(dados: &[u8]) -> Vec<u8> {
    Sha256::digest(dados).to_vec()
}

/// Compacta (deflate puro, nível máximo) com um dicionário.
fn zd(dados: &[u8], dic: &[u8]) -> Res<Vec<u8>> {
    let mut c = Compress::new_with_window_bits(Compression::new(9), false, 15);
    if !dic.is_empty() {
        c.set_dictionary(dic)
            .map_err(|e| erro(format!("compactação: {e}")))?;
    }
    let mut out = Vec::with_capacity(dados.len() / 4 + 64);
    loop {
        let consumido = c.total_in() as usize;
        out.reserve(4096);
        let st = c
            .compress_vec(&dados[consumido..], &mut out, FlushCompress::Finish)
            .map_err(|e| erro(format!("compactação: {e}")))?;
        if st == Status::StreamEnd {
            return Ok(out);
        }
    }
}

fn unzd(blob: &[u8], dic: &[u8]) -> Result<Vec<u8>, String> {
    let mut d = Decompress::new_with_window_bits(false, 15);
    if !dic.is_empty() {
        d.set_dictionary(dic).map_err(|e| e.to_string())?;
    }
    let mut out = Vec::with_capacity(blob.len() * 6 + 1024);
    loop {
        let consumido = d.total_in() as usize;
        let antes = out.len();
        out.reserve(16 * 1024);
        let st = d
            .decompress_vec(&blob[consumido..], &mut out, FlushDecompress::Finish)
            .map_err(|e| e.to_string())?;
        if st == Status::StreamEnd {
            return Ok(out);
        }
        if d.total_in() as usize == blob.len() && out.len() == antes {
            return Ok(out); // sem mais entrada nem saída: o que há é o que veio
        }
    }
}

struct Compactado {
    sha: Vec<u8>,
    tam: i64,
    certs: String,
    molde: i64,
    dados: Vec<u8>,
}

/// O dicionário do compactador é: os certificados que aparecem NESTE XML (cada um guardado uma
/// vez na tabela cert) + um "molde" — o primeiro documento do mesmo tipo, do mesmo dono e no
/// mesmo papel, sem as partes que nunca se repetem. A volta (`abrir`) remonta o mesmo dicionário.
fn compactar(con: &Connection, xml: &[u8], tipo: &str, dono: &str, papel: &str) -> Res<Compactado> {
    let mut ids: Vec<i64> = Vec::new();
    let mut textos: Vec<&[u8]> = Vec::new();
    for m in rx_cert().captures_iter(xml) {
        let Some(t) = m.get(1).map(|g| g.as_bytes()) else {
            continue;
        };
        if textos.contains(&t) {
            continue; // na ordem, sem repetir
        }
        let sha_hex = hex::encode(sha(t));
        let ja: Option<i64> = con
            .query_row("SELECT id FROM cert WHERE sha=?1", [&sha_hex], |r| r.get(0))
            .optional()?;
        let id = match ja {
            Some(id) => id,
            None => {
                con.execute(
                    "INSERT INTO cert (sha, texto) VALUES (?1, ?2)",
                    params![sha_hex, t],
                )?;
                con.last_insert_rowid()
            }
        };
        ids.push(id);
        textos.push(t);
    }
    let ja: Option<(i64, Vec<u8>)> = con
        .query_row("SELECT id, dados FROM molde WHERE tipo=?1 AND dono=?2 AND papel=?3 ORDER BY id LIMIT 1", params![tipo, dono, papel], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .optional()?;
    let (molde_id, molde) = match ja {
        Some(m) => m,
        None => {
            let sem_unicos = rx_unicos().replace_all(xml, &b"$1$2"[..]);
            let corte = sem_unicos.len().saturating_sub(MOLDE_MAX);
            let molde = sem_unicos[corte..].to_vec();
            con.execute(
                "INSERT INTO molde (tipo, dono, papel, dados) VALUES (?1,?2,?3,?4)",
                params![tipo, dono, papel, molde],
            )?;
            (con.last_insert_rowid(), molde)
        }
    };
    let mut dic: Vec<u8> = textos.concat();
    dic.extend_from_slice(&molde);
    let mut blob = zd(xml, &dic)?;
    let mut certs = ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
    let mut molde_id = molde_id;
    if unzd(&blob, &dic).ok().as_deref() != Some(xml) {
        // nunca deveria: sem dicionário o XML volta sozinho
        registro::erro(
            "cofre",
            "Compactação com dicionário não conferiu; XML guardado sem dicionário.",
        );
        certs = String::new();
        molde_id = 0;
        blob = zd(xml, b"")?;
    }
    Ok(Compactado {
        sha: sha(xml),
        tam: xml.len() as i64,
        certs,
        molde: molde_id,
        dados: blob,
    })
}

/// O XML original, byte a byte. Erro se a impressão digital não conferir.
fn abrir(
    con: &Connection,
    sha_gravado: &[u8],
    certs: &str,
    molde_id: i64,
    dados: &[u8],
) -> Res<Vec<u8>> {
    match abrir_uma_vez(con, sha_gravado, certs, molde_id, dados) {
        Ok(x) => Ok(x),
        Err(_) => {
            // O que estava na memória pode ser de antes de o arquivo mudar por fora (outro
            // programa, cópia trazida de volta): relê do banco e tenta de novo.
            limpar_caches();
            abrir_uma_vez(con, sha_gravado, certs, molde_id, dados)
        }
    }
}

fn abrir_uma_vez(
    con: &Connection,
    sha_gravado: &[u8],
    certs: &str,
    molde_id: i64,
    dados: &[u8],
) -> Res<Vec<u8>> {
    let mut dic: Vec<u8> = Vec::new();
    for id in certs
        .split(',')
        .filter(|x| !x.is_empty())
        .filter_map(|x| x.parse::<i64>().ok())
    {
        let guardado = caches().lock().ok().and_then(|c| c.cert.get(&id).cloned());
        let texto = match guardado {
            Some(t) => t,
            None => {
                let t: Option<Vec<u8>> = con
                    .query_row("SELECT texto FROM cert WHERE id=?1", [id], |r| r.get(0))
                    .optional()?;
                let Some(t) = t else {
                    return Err(erro(
                        "Um certificado necessário para abrir este XML não está mais no banco de notas (tabela cert).",
                    ));
                };
                if let Ok(mut c) = caches().lock() {
                    c.cert.insert(id, t.clone());
                }
                t
            }
        };
        dic.extend_from_slice(&texto);
    }
    if molde_id != 0 {
        let guardado = caches()
            .lock()
            .ok()
            .and_then(|c| c.molde.get(&molde_id).cloned());
        let molde = match guardado {
            Some(m) => m,
            None => {
                let m: Option<Vec<u8>> = con
                    .query_row("SELECT dados FROM molde WHERE id=?1", [molde_id], |r| {
                        r.get(0)
                    })
                    .optional()?;
                let Some(m) = m else {
                    return Err(erro(
                        "O molde necessário para abrir este XML não está mais no banco de notas (tabela molde).",
                    ));
                };
                if let Ok(mut c) = caches().lock() {
                    c.molde.insert(molde_id, m.clone());
                }
                m
            }
        };
        dic.extend_from_slice(&molde);
    }
    let xml = unzd(dados, &dic)
        .map_err(|e| erro(format!("O XML guardado não pôde ser descompactado ({e}).")))?;
    if sha(&xml) != sha_gravado {
        return Err(erro(
            "O XML guardado não confere com a impressão digital registrada na gravação. O banco de notas pode \
             estar danificado.",
        ));
    }
    Ok(xml)
}

// --------------------------------------------------------------------------------------------- //
// Leitura dos XMLs (só para montar o índice — o XML guardado é o original)
// --------------------------------------------------------------------------------------------- //
/// CNPJ/CPF sem pontuação, preservando letras (CNPJ alfanumérico).
pub fn so_doc(valor: &str) -> String {
    valor
        .to_uppercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

fn t(el: Option<&Elemento>, caminho: &[&str]) -> String {
    el.and_then(|e| e.achar_caminho(caminho))
        .map(|a| aparar(a.texto_inicial()).to_string())
        .unwrap_or_default()
}

fn doc_de(el: Option<&Elemento>) -> String {
    for tag in ["CNPJ", "CPF", "NIF"] {
        let v = t(el, &[tag]);
        if !v.is_empty() {
            return so_doc(&v);
        }
    }
    String::new()
}

fn num(valor: &str) -> f64 {
    let v = if valor.is_empty() { "0" } else { valor };
    texto::float_py(&v.replace(',', ".")).unwrap_or(0.0)
}

/// 'nfse', 'evento' ou o nome da raiz em minúsculas ('' se não for XML).
pub fn tipo_do_xml(xml_bytes: &[u8]) -> String {
    xml::ler(xml_bytes)
        .map(|r| r.nome.to_lowercase())
        .unwrap_or_default()
}

/// Campos de índice de uma NFS-e.
#[derive(Debug, Clone, Default, Serialize)]
pub struct InfoNfse {
    pub chave: String,
    #[serde(rename = "nNFSe")]
    pub n_nfse: String,
    #[serde(rename = "dhProc")]
    pub dh_proc: String,
    pub dt: String,
    #[serde(rename = "dCompet")]
    pub d_compet: String,
    pub amb: String,
    #[serde(rename = "cStat")]
    pub c_stat: String,
    pub emit_doc: String,
    pub emit_nome: String,
    pub toma_doc: String,
    pub toma_nome: String,
    pub interm_doc: String,
    pub descricao: String,
    #[serde(rename = "vServ")]
    pub v_serv: f64,
    #[serde(rename = "vLiq")]
    pub v_liq: f64,
}

/// Campos de índice de uma NFS-e (None se o XML não for uma).
pub fn ler_nfse(xml_bytes: &[u8]) -> Option<InfoNfse> {
    let raiz = xml::ler(xml_bytes).ok()?;
    if raiz.nome != "NFSe" {
        return None;
    }
    let inf = raiz.achar("infNFSe")?;
    let id = inf.attr("Id").unwrap_or("");
    let chave = if id.to_uppercase().starts_with("NFS") {
        so_doc(&id.chars().skip(3).collect::<String>())
    } else {
        so_doc(id)
    };
    let emit = inf.achar("emit");
    let dps = inf.achar_caminho(&["DPS", "infDPS"]);
    let toma = dps.and_then(|d| d.achar("toma"));
    let interm = dps.and_then(|d| d.achar("interm"));
    let mut dh = t(Some(inf), &["dhProc"]);
    if dh.is_empty() {
        dh = t(dps, &["dhEmi"]);
    }
    let comp = t(dps, &["dCompet"]);
    let dt = if dh.chars().count() >= 10 {
        dh.chars().take(10).collect()
    } else {
        comp.clone()
    };
    let mut amb = t(dps, &["tpAmb"]);
    if amb.is_empty() {
        amb = t(Some(inf), &["ambGer"]);
    }
    let mut emit_doc = doc_de(emit);
    if emit_doc.is_empty() {
        emit_doc = doc_de(dps.and_then(|d| d.achar("prest")));
    }
    Some(InfoNfse {
        chave,
        n_nfse: t(Some(inf), &["nNFSe"]),
        dh_proc: dh,
        dt,
        d_compet: comp,
        amb,
        c_stat: t(Some(inf), &["cStat"]),
        emit_doc,
        emit_nome: t(emit, &["xNome"]),
        toma_doc: doc_de(toma),
        toma_nome: t(toma, &["xNome"]),
        interm_doc: doc_de(interm),
        descricao: t(dps, &["serv", "cServ", "xDescServ"]),
        v_serv: num(&t(dps, &["valores", "vServPrest", "vServ"])),
        v_liq: num(&t(Some(inf), &["valores", "vLiq"])),
    })
}

/// Campos de um evento de NFS-e.
#[derive(Debug, Clone, Default, Serialize)]
pub struct InfoEvento {
    pub chave: String,
    pub tipo: String,
    pub descricao: String,
    pub dh: String,
    pub amb: String,
    pub subst_por: String,
}

fn nome_de_evento(nome: &str) -> bool {
    // começa por "e" + 6 dígitos
    let b = nome.as_bytes();
    b.len() >= 7
        && b[0] == b'e'
        && nome.chars().skip(1).take(6).all(texto::digito)
        && nome.chars().count() == 7
}

/// Campos de um evento de NFS-e (None se o XML não for um).
pub fn ler_evento(xml_bytes: &[u8]) -> Option<InfoEvento> {
    let raiz = xml::ler(xml_bytes).ok()?;
    if !matches!(raiz.nome.to_lowercase().as_str(), "evento" | "pedregevento") {
        return None;
    }
    let mut i = InfoEvento::default();
    for el in raiz.todos() {
        let texto = aparar(el.texto_inicial());
        match el.nome.as_str() {
            "chNFSe" if i.chave.is_empty() => i.chave = so_doc(texto),
            "dhProc" if i.dh.is_empty() => i.dh = texto.to_string(),
            "dhEvento" if i.dh.is_empty() => i.dh = texto.to_string(),
            "tpAmb" if i.amb.is_empty() => i.amb = texto.to_string(),
            "chSubstituta" if i.subst_por.is_empty() => i.subst_por = so_doc(texto),
            nome if nome_de_evento(nome) && i.tipo.is_empty() => {
                i.tipo = nome.to_string();
                i.descricao = t(Some(el), &["xDesc"]);
            }
            _ => {}
        }
    }
    if i.chave.is_empty() || i.tipo.is_empty() {
        None
    } else {
        Some(i)
    }
}

/// Emitida (o dono é o prestador), recebida (é o tomador) ou outro papel (intermediário).
/// Compara o documento inteiro e, sem acerto, a RAIZ do CNPJ (matriz/filial).
fn papel_de(dono: &str, i: &InfoNfse) -> &'static str {
    let dono = so_doc(dono);
    for (campo, papel) in [(&i.emit_doc, PAPEL_EMITIDA), (&i.toma_doc, PAPEL_RECEBIDA)] {
        if !campo.is_empty() && *campo == dono {
            return papel;
        }
    }
    if dono.chars().count() == 14 {
        let raiz: String = dono.chars().take(8).collect();
        for (campo, papel) in [(&i.emit_doc, PAPEL_EMITIDA), (&i.toma_doc, PAPEL_RECEBIDA)] {
            if campo.chars().count() == 14 && campo.chars().take(8).collect::<String>() == raiz {
                return papel;
            }
        }
    }
    PAPEL_OUTRO
}

// --------------------------------------------------------------------------------------------- //
// Gravação (sempre dentro da transação de quem chama)
// --------------------------------------------------------------------------------------------- //
/// Reflete na nota os eventos já guardados para ela (cancelada / substituída por).
fn estado_por_eventos(con: &Connection, dono: &str, chave: &str) -> Res<()> {
    let (mut cancelada, mut subst) = (0i64, String::new());
    {
        let mut st =
            con.prepare("SELECT tipo, subst_por FROM evento WHERE dono=?1 AND chave=?2")?;
        let linhas = st.query_map(params![dono, chave], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        for l in linhas {
            let (tipo, sp) = l?;
            if EVENTOS_CANCELAM.contains(&tipo.as_str()) {
                cancelada = 1;
            }
            if tipo == EVENTO_SUBSTITUICAO && !sp.is_empty() {
                subst = sp;
            }
        }
    }
    if cancelada != 0 || !subst.is_empty() {
        con.execute(
            "UPDATE nota SET cancelada = max(cancelada, ?1), subst_por = CASE WHEN ?2 <> '' THEN ?2 ELSE subst_por END \
             WHERE dono=?3 AND chave=?4",
            params![cancelada, subst, dono, chave],
        )?;
    }
    Ok(())
}

/// Guarda uma NFS-e. Devolve (resultado, papel): 'nova' | 'repetida' | 'invalida'.
fn gravar_nota(
    con: &Connection,
    dono: &str,
    xml_bytes: &[u8],
    nsu: Option<i64>,
    origem: &str,
) -> Res<(&'static str, &'static str)> {
    let Some(i) = ler_nfse(xml_bytes).filter(|i| !i.chave.is_empty()) else {
        return Ok(("invalida", ""));
    };
    let papel = papel_de(dono, &i);
    let ja: Option<(i64, Option<i64>, String)> = con
        .query_row(
            "SELECT id, nsu, origem FROM nota WHERE dono=?1 AND chave=?2",
            params![dono, i.chave],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    if let Some((id, nsu_ja, origem_ja)) = ja {
        // A mesma nota chegando pela segunda vez (emitida aqui e depois devolvida pelo ADN, ou o
        // contrário): NÃO entra de novo. Só se completa o que faltava saber dela.
        if nsu.unwrap_or(0) != 0 && nsu_ja.unwrap_or(0) == 0 {
            con.execute("UPDATE nota SET nsu=?1 WHERE id=?2", params![nsu, id])?; // o ADN confirmou: guarda o NSU
        }
        if origem == "local" && origem_ja != "local" {
            con.execute("UPDATE nota SET origem='local' WHERE id=?1", [id])?; // o ADN chegou antes da emissão concluir
        }
        return Ok(("repetida", papel));
    }
    let numero_int: i64 = if !i.n_nfse.is_empty() && i.n_nfse.bytes().all(|b| b.is_ascii_digit()) {
        i.n_nfse.parse().unwrap_or(0)
    } else {
        0
    };
    con.execute(
        "INSERT INTO nota (dono, amb, chave, papel, nsu, nNFSe, nNFSe_int, dhProc, dt, dCompet, emit_doc, emit_nome, \
         toma_doc, toma_nome, busca, vServ, vLiq, cStat, origem, entrou) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)",
        params![
            dono, i.amb, i.chave, papel, nsu, i.n_nfse, numero_int, i.dh_proc, i.dt, i.d_compet, i.emit_doc, i.emit_nome,
            i.toma_doc, i.toma_nome, texto_busca(papel, &i), i.v_serv, i.v_liq, i.c_stat, origem, epoca()
        ],
    )?;
    let nota_id = con.last_insert_rowid();
    let c = compactar(con, xml_bytes, "nfse", dono, papel)?;
    con.execute(
        "INSERT INTO nota_xml (nota, sha, tam, certs, molde, dados) VALUES (?1,?2,?3,?4,?5,?6)",
        params![nota_id, c.sha, c.tam, c.certs, c.molde, c.dados],
    )?;
    estado_por_eventos(con, dono, &i.chave)?;
    Ok(("nova", papel))
}

/// Guarda um evento e reflete o efeito dele na nota. 'novo' | 'repetido' | 'invalido'.
fn gravar_evento(
    con: &Connection,
    dono: &str,
    xml_bytes: &[u8],
    nsu: Option<i64>,
    origem: &str,
) -> Res<&'static str> {
    let Some(i) = ler_evento(xml_bytes) else {
        return Ok("invalido");
    };
    let digital = sha(xml_bytes);
    let ja: Option<i64> = con
        .query_row(
            "SELECT 1 FROM evento WHERE dono=?1 AND sha=?2",
            params![dono, digital],
            |r| r.get(0),
        )
        .optional()?;
    if ja.is_some() {
        return Ok("repetido");
    }
    let c = compactar(con, xml_bytes, "evento", dono, "")?;
    con.execute(
        "INSERT INTO evento (dono, amb, chave, tipo, descricao, dh, subst_por, nsu, origem, entrou, sha, tam, certs, \
         molde, dados) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
        params![dono, i.amb, i.chave, i.tipo, i.descricao, i.dh, i.subst_por, nsu, origem, epoca(), c.sha, c.tam, c.certs, c.molde, c.dados],
    )?;
    estado_por_eventos(con, dono, &i.chave)?;
    Ok("novo")
}

// --------------------------------------------------------------------------------------------- //
// Notas que ESTE programa emite: entram na hora, com origem 'local'
// --------------------------------------------------------------------------------------------- //
/// Guarda a NFS-e que este programa acabou de emitir (o XML autorizado, como a SEFIN devolveu).
/// Devolve (chave de acesso, 'nova' | 'repetida'). 'repetida' = a chave já estava no cofre: nada
/// é duplicado e a nota passa a constar como emitida aqui.
pub fn guardar_emitida(dono: &str, xml_bytes: &[u8]) -> Res<(String, &'static str)> {
    let dono = so_doc(dono);
    let Some(i) = ler_nfse(xml_bytes).filter(|i| !i.chave.is_empty()) else {
        return Err(erro(
            "O XML devolvido pela SEFIN não tem os campos de identificação da NFS-e.",
        ));
    };
    let con = conn()?;
    let (resultado, _) = transacao(&con, || gravar_nota(&con, &dono, xml_bytes, None, "local"))?;
    Ok((i.chave, resultado))
}

/// A nota foi cancelada (estorno aceito pela SEFIN): guarda o XML do evento, se veio, e marca a
/// nota. Uma transação.
pub fn marcar_cancelada(dono: &str, chave: &str, evento_xml: Option<&[u8]>) -> Res<()> {
    let dono = so_doc(dono);
    let con = conn()?;
    transacao(&con, || {
        if let Some(x) = evento_xml.filter(|x| !x.is_empty()) {
            // o que vale é a marca; o XML do evento volta do ADN
            if let Err(e) = gravar_evento(&con, &dono, x, None, "local") {
                registro::erro(
                    "cofre",
                    &format!("XML do evento de cancelamento de {chave} não pôde ser guardado: {e}"),
                );
            }
        }
        con.execute(
            "UPDATE nota SET cancelada=1 WHERE dono=?1 AND chave=?2",
            params![dono, chave],
        )?;
        Ok(())
    })
}

/// A nota `chave_antiga` foi substituída por `chave_nova` (a SEFIN a cancela por substituição):
/// fica cancelada e apontando para a substituta. Idempotente.
pub fn marcar_substituida(dono: &str, chave_antiga: &str, chave_nova: &str) -> Res<()> {
    let con = conn()?;
    con.execute(
        "UPDATE nota SET cancelada=1, subst_por=?1 WHERE dono=?2 AND chave=?3",
        params![chave_nova, so_doc(dono), chave_antiga],
    )?;
    Ok(())
}

/// [(chave antiga, chave da substituta)] de todas as notas substituídas do dono.
pub fn pares_substituicao(dono: &str) -> Res<Vec<(String, String)>> {
    let con = conn()?;
    let mut st =
        con.prepare("SELECT chave, subst_por FROM nota WHERE dono=?1 AND subst_por <> ''")?;
    let linhas = st.query_map([so_doc(dono)], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    let mut out = Vec::new();
    for l in linhas {
        out.push(l?);
    }
    Ok(out)
}

// --------------------------------------------------------------------------------------------- //
// ADN: distribuição de DF-e por NSU
// --------------------------------------------------------------------------------------------- //
/// Campo de um objeto JSON, sem diferenciar maiúsculas no nome.
fn ci<'a>(obj: &'a Value, nome: &str) -> Option<&'a Value> {
    let alvo = nome.to_lowercase();
    obj.as_object()?
        .iter()
        .find(|(k, _)| k.to_lowercase() == alvo)
        .map(|(_, v)| v)
}

fn vazio_py(v: &Value) -> bool {
    match v {
        Value::Null => true,
        Value::Bool(b) => !b,
        Value::Number(n) => n.as_f64() == Some(0.0),
        Value::String(s) => s.is_empty(),
        Value::Array(a) => a.is_empty(),
        Value::Object(o) => o.is_empty(),
    }
}

fn texto_py(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        outro => jsonpy::dumps(outro, jsonpy::Formato::UTF8),
    }
}

fn texto_de(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => aparar(s).to_string(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => {
            if *b {
                "True".into()
            } else {
                "False".into()
            }
        }
        Some(o @ Value::Object(_)) => {
            for k in ["#text", "value", "conteudo", "ArquivoXmlGZipB64"] {
                let s = texto_de(ci(o, k));
                if !s.is_empty() {
                    return s;
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}

/// Erro de dado de um documento do lote: (classe, mensagem), para a quarentena.
type Dado<T> = Result<T, (&'static str, String)>;

fn gunzip(bruto: &[u8]) -> Dado<Vec<u8>> {
    let mut out = Vec::new();
    flate2::read::MultiGzDecoder::new(bruto)
        .read_to_end(&mut out)
        .map_err(|e| ("BadGzipFile", e.to_string()))?;
    Ok(out)
}

/// ArquivoXml de um item do lote -> bytes do XML ORIGINAL (GZip+Base64, Base64 ou XML puro).
pub fn decodificar_arquivo(valor: Option<&Value>) -> Dado<Vec<u8>> {
    let s = texto_de(valor);
    if s.is_empty() {
        return Err(("ValueError", "ArquivoXml vazio".into()));
    }
    if s.trim_start().starts_with('<') {
        return Ok(s.into_bytes());
    }
    let limpo: String = s
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '='))
        .collect();
    let bruto = STANDARD
        .decode(limpo.as_bytes())
        .map_err(|_| ("Error", "Incorrect padding".to_string()))?;
    if bruto.starts_with(b"\x1f\x8b") {
        return gunzip(&bruto);
    }
    if bruto.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b'<') {
        return Ok(bruto);
    }
    Err(("ValueError", "ArquivoXml não é XML nem GZip".into()))
}

fn so_az09(s: &str) -> String {
    s.to_uppercase()
        .chars()
        .filter(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        .collect()
}

/// (StatusProcessamento normalizado, itens do lote, mensagens de erro/alerta) — JSON ou XML.
pub fn interpretar_resposta(corpo: &[u8]) -> Res<(String, Vec<Value>, Vec<String>)> {
    let sem_bom = corpo.strip_prefix(b"\xef\xbb\xbf").unwrap_or(corpo);
    let completo = String::from_utf8_lossy(sem_bom);
    let texto = aparar(&completo);
    let mut mensagens: Vec<String> = Vec::new();
    if texto.is_empty() {
        return Ok((String::new(), Vec::new(), mensagens));
    }
    if let Ok(obj @ Value::Object(_)) = serde_json::from_str::<Value>(texto) {
        let status = ci(&obj, "StatusProcessamento")
            .filter(|v| !vazio_py(v))
            .map(texto_py)
            .unwrap_or_default();
        let lotes: Vec<Value> = match ci(&obj, "LoteDFe") {
            Some(Value::Array(a)) => a.clone(),
            Some(o @ Value::Object(m)) if !m.is_empty() => vec![o.clone()],
            _ => Vec::new(),
        };
        for campo in ["Erros", "Alertas"] {
            let itens: Vec<Value> = match ci(&obj, campo) {
                Some(Value::Array(a)) => a.clone(),
                Some(v) if !vazio_py(v) => vec![v.clone()],
                _ => Vec::new(),
            };
            for item in itens {
                if item.is_object() {
                    let campo_de = |nome: &str| ci(&item, nome).map(texto_py).unwrap_or_default();
                    let cod = campo_de("Codigo");
                    let mut desc = ci(&item, "Descricao")
                        .filter(|v| !vazio_py(v))
                        .map(texto_py)
                        .unwrap_or_default();
                    if desc.is_empty() {
                        desc = campo_de("Mensagem");
                    }
                    let junto = format!("{cod} {desc}");
                    let junto = aparar(&junto);
                    mensagens.push(if junto.is_empty() {
                        jsonpy::dumps(&item, jsonpy::Formato::UTF8)
                    } else {
                        junto.to_string()
                    });
                } else {
                    mensagens.push(texto_py(&item));
                }
            }
        }
        return Ok((
            so_az09(&status),
            lotes.into_iter().filter(Value::is_object).collect(),
            mensagens,
        ));
    }
    let raiz = xml::ler(corpo).map_err(|_| {
        erro(format!(
            "O ADN devolveu uma resposta que não é JSON nem XML: {}",
            texto.chars().take(200).collect::<String>()
        ))
    })?;
    let (mut status, mut itens) = (String::new(), Vec::new());
    for el in raiz.todos() {
        match el.nome.as_str() {
            "StatusProcessamento" if status.is_empty() => {
                status = aparar(el.texto_inicial()).to_string()
            }
            "LoteDFe" => {
                let mut item = Map::new();
                for f in el.elementos() {
                    item.insert(
                        f.nome.clone(),
                        Value::String(aparar(&f.textos().concat()).to_string()),
                    );
                }
                itens.push(Value::Object(item));
            }
            "Erros" | "Alertas" => {
                let s = el
                    .textos()
                    .iter()
                    .map(|x| aparar(x))
                    .filter(|x| !x.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ");
                if !s.is_empty() {
                    mensagens.push(s);
                }
            }
            _ => {}
        }
    }
    Ok((so_az09(&status), itens, mensagens))
}

pub fn url_dfe(amb: &str, nsu: i64, dono: &str) -> String {
    let dono = so_doc(dono);
    let consulta = if dono.chars().count() == 14 {
        format!("&cnpjConsulta={dono}")
    } else {
        String::new()
    };
    format!(
        "https://{}/contribuintes/DFe/{nsu}?lote=true{consulta}",
        host(amb).unwrap_or("")
    )
}

/// Uma resposta do ADN: (status HTTP, cabeçalhos, corpo).
pub type RespostaHttp = (u16, Vec<(String, String)>, Vec<u8>);
/// Quem busca uma URL no ADN (a conexão real ou, nos testes, respostas prontas).
pub type Http<'a> = &'a dyn Fn(&str) -> Res<RespostaHttp>;

/// O que acompanha uma sincronização: andamento, cancelamento e espera.
pub struct Acompanhar<'a> {
    pub progresso: Option<&'a dyn Fn(&Value)>,
    pub cancelar: Option<&'a dyn Fn() -> bool>,
    pub dormir: &'a dyn Fn(f64),
}

pub fn dormir_de_verdade(segundos: f64) {
    std::thread::sleep(Duration::from_secs_f64(segundos.max(0.0)));
}

/// Espera em fatias curtas para o cancelamento valer na hora.
fn esperar(segundos: f64, cancelar: &dyn Fn() -> bool, dormir: &dyn Fn(f64)) -> Res<()> {
    let mut resto = segundos;
    while resto > 0.0 {
        if cancelar() {
            return Err(cancelado());
        }
        let fatia = resto.min(0.5);
        dormir(fatia);
        resto -= fatia;
    }
    if cancelar() { Err(cancelado()) } else { Ok(()) }
}

fn inicial_maiuscula(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(p) => format!("{}{}", p.to_uppercase(), c.as_str()),
        None => String::new(),
    }
}

/// Um GET com a paciência combinada: HTTP 429 espera o que o ADN pedir (Retry-After) ou
/// ESPERA_429; falha de rede e 5xx repetem com intervalo crescente; no máximo MAX_TENTATIVAS.
/// Devolve (status, corpo) para quem chamou interpretar — 200 e também 204/400/404, que o ADN
/// usa para "nenhum documento" e para rejeições com mensagem.
fn pedir(
    http: Http,
    url: &str,
    cancelar: &dyn Fn() -> bool,
    dormir: &dyn Fn(f64),
    avisar: &mut dyn FnMut(&str),
) -> Res<(u16, Vec<u8>)> {
    for tentativa in 1..=MAX_TENTATIVAS {
        if cancelar() {
            return Err(cancelado());
        }
        let mut motivo = String::new();
        let (status, cab, corpo) = match http(url) {
            Ok(r) => r,
            Err(e) if crate::rede::erro_de_rede(&e) || e.do_sistema() => {
                motivo = format!("sem resposta do ADN ({})", e.tipo);
                (0, Vec::new(), Vec::new())
            }
            Err(e) => return Err(e),
        };
        if status == 401 || status == 403 {
            return Err(erro(format!(
                "O ADN recusou o certificado deste prestador (HTTP {status}). Confira se o certificado é do mesmo CNPJ \
                 (ou da mesma raiz) e se não está vencido."
            )));
        }
        if status != 0 && ![429, 500, 502, 503, 504].contains(&status) {
            return Ok((status, corpo));
        }
        let espera = if status == 429 {
            let pedido = cab
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("Retry-After"))
                .map(|(_, v)| aparar(v).to_string())
                .unwrap_or_default();
            motivo = "o ADN pediu para reduzir o ritmo (HTTP 429)".into();
            if !pedido.is_empty() && pedido.bytes().all(|b| b.is_ascii_digit()) {
                pedido
                    .parse::<u64>()
                    .unwrap_or(ESPERA_429_MAX)
                    .min(ESPERA_429_MAX)
            } else {
                ESPERA_429
            }
        } else {
            if motivo.is_empty() {
                motivo = format!("o ADN está instável (HTTP {status})");
            }
            ESPERA_FALHA[tentativa.min(ESPERA_FALHA.len()) - 1]
        };
        if tentativa == MAX_TENTATIVAS {
            return Err(indisponivel(format!(
                "Não foi possível consultar o ADN: {motivo}, mesmo depois de {tentativa} tentativas. O que já chegou \
                 está guardado; tente de novo mais tarde."
            )));
        }
        avisar(&format!(
            "{}. Nova tentativa em {espera} s ({tentativa}/{})…",
            inicial_maiuscula(&motivo),
            MAX_TENTATIVAS - 1
        ));
        esperar(espera as f64, cancelar, dormir)?;
    }
    Err(indisponivel("Falha inesperada ao consultar o ADN."))
}

pub fn ultimo_nsu(dono: &str, amb: &str) -> Res<i64> {
    let con = conn()?;
    Ok(con
        .query_row(
            "SELECT nsu FROM cursor WHERE dono=?1 AND amb=?2",
            params![so_doc(dono), amb],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(0))
}

/// As contagens de uma sincronização.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Contagens {
    pub lotes: i64,
    pub documentos: i64,
    pub novas: i64,
    pub emitidas: i64,
    pub recebidas: i64,
    pub outras: i64,
    pub eventos: i64,
    pub repetidos: i64,
    pub quarentena: i64,
    pub nsu: i64,
    /// 'em_dia', 'cancelado' ou 'limite' (teto de lotes atingido — basta sincronizar de novo).
    pub fim: String,
    pub avisos: Vec<String>,
}

fn sem_certificado() -> Erro {
    erro(
        "Este prestador não tem certificado digital. Importe o .pfx em Configurações > Certificado para consultar o ADN.",
    )
}

/// A conexão real com o ADN, autenticada com o certificado do prestador (mTLS). Uma conexão só,
/// reaproveitada entre os lotes.
fn transporte(prestador: &str) -> Res<crate::rede::Sessao> {
    let cert = crate::cadastro::active_cert(prestador)?;
    if cert.is_empty() {
        return Err(sem_certificado());
    }
    let Some(senha) = crate::cadastro::read_cert_password(prestador, Some(&cert))? else {
        return Err(erro(
            "A senha do certificado não está gravada. Atualize o certificado em Configurações > Certificado.",
        ));
    };
    let pfx = crate::cadastro::cert_pfx(prestador, Some(&cert))?;
    let material = crate::certificado::carregar_pfx(&pfx, &senha).map_err(|e| {
        erro(format!(
            "Não foi possível abrir o certificado do prestador: {e}"
        ))
    })?;
    crate::rede::Sessao::nova(
        Some(&material),
        crate::rede::Tempo {
            conectar: TIMEOUT.0,
            ler: TIMEOUT.1,
        },
        "BaiacuNFSe-Cofre/1.0",
        false,
    )
}

/// Traz para o cofre o que há de novo no ADN, a partir do último NSU gravado para (dono,
/// ambiente). O que este programa emitiu já está aqui e não se repete.
///
/// `http` (testes) substitui a conexão real. Devolve as contagens e `fim`. Erro (mensagem para
/// o usuário) em rejeição, certificado recusado ou ADN fora.
pub fn sincronizar(
    dono: &str,
    amb: &str,
    http: Option<Http>,
    a: &Acompanhar,
    forcar: bool,
) -> Res<Contagens> {
    let dono = so_doc(dono);
    if host(amb).is_none() {
        return Err(erro(format!("Ambiente inválido: {}.", pyfmt::repr(amb))));
    }
    let Some(_trava) = TravaSinc::pegar() else {
        return Err(erro("Já há uma sincronização em andamento."));
    };
    let geracao = geracao_de(&dono); // se o prestador for deletado no meio, nada mais entra
    // prestador deletado = sincronização cancelada
    let cancelar = || geracao_de(&dono) != geracao || a.cancelar.is_some_and(|c| c());
    let mut stats = Contagens {
        fim: "em_dia".into(),
        ..Default::default()
    };
    let informar = |stats: &Contagens, fase: &str, texto: &str| {
        if let Some(p) = a.progresso {
            let mut v = serde_json::to_value(stats).unwrap_or(Value::Null);
            if let Some(m) = v.as_object_mut() {
                m.insert("fase".into(), json!(fase));
                m.insert("texto".into(), json!(texto));
            }
            p(&v);
        }
    };

    let corpo = (|| -> Res<()> {
        let linha: Option<(i64, String, i64)> = {
            let con = conn()?;
            con.query_row(
                "SELECT nsu, quando, em_dia FROM cursor WHERE dono=?1 AND amb=?2",
                params![dono, amb],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
        };
        let mut nsu = linha.as_ref().map(|l| l.0).unwrap_or(0);
        stats.nsu = nsu;
        if let Some((_, quando, em_dia)) = &linha {
            if *em_dia != 0 && !quando.is_empty() && !forcar {
                let idade = match chrono::NaiveDateTime::parse_from_str(quando, "%Y-%m-%dT%H:%M:%S")
                {
                    Ok(q) => {
                        (chrono::Local::now().naive_local() - q).num_milliseconds() as f64 / 1000.0
                    }
                    Err(_) => INTERVALO_MIN,
                };
                if (0.0..INTERVALO_MIN).contains(&idade) {
                    return Err(recente(format!(
                        "O ADN foi consultado há {} s e não havia nada novo. Aguarde {} s para consultar de novo (limite de \
                         consultas do ADN).",
                        idade as i64,
                        (INTERVALO_MIN - idade) as i64
                    )));
                }
            }
        }
        let sessao = match http {
            Some(_) => None,
            None => Some(transporte(&dono)?),
        };
        let real = |url: &str| -> Res<RespostaHttp> {
            let r = sessao
                .as_ref()
                .ok_or_else(sem_certificado)?
                .get(url, &[("Accept", "application/json")])?;
            Ok((r.status, r.cabecalhos, r.corpo))
        };
        let pedir_http: Http = match http {
            Some(h) => h,
            None => &real,
        };
        let mut chegou_ao_limite = true;
        for _ in 0..MAX_LOTES {
            informar(
                &stats,
                "adn",
                &format!("Consultando o ADN a partir do NSU {nsu}…"),
            );
            let (status, corpo) = pedir(
                pedir_http,
                &url_dfe(amb, nsu, &dono),
                &cancelar,
                a.dormir,
                &mut |t: &str| {
                    stats.avisos.push(t.to_string());
                    informar(&stats, "espera", t);
                },
            )?;
            if cancelar() {
                return Err(cancelado()); // cancelado enquanto o lote vinha: descartado inteiro
            }
            let (mut situacao, itens, mensagens) = interpretar_resposta(&corpo)?;
            // "Nenhum documento" chega de mais de um jeito: no StatusProcessamento, numa mensagem
            // de erro/alerta, ou só como HTTP 404/204 sem corpo.
            if mensagens
                .iter()
                .any(|m| busca::sem_acento_maiusculo(m).contains("NENHUM DOCUMENTO"))
                && situacao.is_empty()
            {
                situacao = "NENHUMDOCUMENTOLOCALIZADO".into();
            }
            if situacao.contains("REJEI")
                || (status >= 400 && !mensagens.is_empty() && !situacao.contains("NENHUM"))
            {
                let detalhe = if !mensagens.is_empty() {
                    mensagens.join("; ")
                } else if !situacao.is_empty() {
                    situacao.clone()
                } else {
                    "sem detalhes".into()
                };
                return Err(erro(format!(
                    "O ADN rejeitou a consulta{}: {detalhe}.",
                    if status != 200 {
                        format!(" (HTTP {status})")
                    } else {
                        String::new()
                    }
                )));
            }
            if itens.is_empty() {
                if ![200, 204, 404].contains(&status) && !situacao.contains("NENHUM") {
                    return Err(erro(format!(
                        "O ADN respondeu HTTP {status} sem documentos nem explicação. Tente de novo mais tarde."
                    )));
                }
                chegou_ao_limite = false;
                break; // nenhum documento novo: em dia
            }
            let maior = gravar_lote(
                &dono,
                amb,
                &itens,
                &mut stats,
                Some(geracao),
                Some(&cancelar),
            )?;
            stats.lotes += 1;
            if maior <= nsu {
                registro::aviso(
                    "cofre",
                    &format!("ADN devolveu lote que não avança o NSU ({nsu}); encerrando."),
                );
                chegou_ao_limite = false;
                break;
            }
            nsu = maior;
            stats.nsu = maior;
            informar(
                &stats,
                "adn",
                &format!("{} documento(s) recebido(s)…", stats.documentos),
            );
            esperar(INTERVALO_LOTES, &cancelar, a.dormir)?;
        }
        if chegou_ao_limite {
            stats.fim = "limite".into();
        }
        marcar_cursor(&dono, amb, stats.fim == "em_dia", Some(geracao))
    })();
    match corpo {
        Ok(()) => {}
        Err(e) if e.tipo == CANCELADO => stats.fim = "cancelado".into(),
        Err(e) => return Err(e),
    }
    informar(&stats, "fim", "");
    registro::info(
        "cofre",
        &format!(
            "Cofre: sincronização de {dono} (ambiente {amb}): lotes={} documentos={} novas={} emitidas={} recebidas={} \
             outras={} eventos={} repetidos={} quarentena={} nsu={} fim={}",
            stats.lotes,
            stats.documentos,
            stats.novas,
            stats.emitidas,
            stats.recebidas,
            stats.outras,
            stats.eventos,
            stats.repetidos,
            stats.quarentena,
            stats.nsu,
            stats.fim
        ),
    );
    Ok(stats)
}

fn marcar_cursor(dono: &str, amb: &str, em_dia: bool, geracao: Option<u64>) -> Res<()> {
    let con = conn()?;
    transacao(&con, || {
        conferir_geracao(dono, geracao)?;
        con.execute(
            "INSERT INTO cursor (dono, amb, nsu, quando, em_dia) VALUES (?1,?2,0,?3,?4) \
             ON CONFLICT(dono, amb) DO UPDATE SET quando=excluded.quando, em_dia=excluded.em_dia",
            params![dono, amb, agora(), if em_dia { 1 } else { 0 }],
        )?;
        Ok(())
    })
}

/// Grava UM lote e o cursor de NSU na MESMA transação: ou entra tudo e o cursor avança, ou nada
/// muda. Documento que não dá para ler vai para a quarentena (com o conteúdo como chegou) em vez
/// de travar a fila. Devolve o maior NSU do lote.
///
/// Cancelar com o lote pela metade DESCARTA o lote: `cancelar()` é consultado a cada documento
/// e de novo antes de valer. As contagens só somam o lote que valeu.
pub fn gravar_lote(
    dono: &str,
    amb: &str,
    itens: &[Value],
    total: &mut Contagens,
    geracao: Option<u64>,
    cancelar: Option<&dyn Fn() -> bool>,
) -> Res<i64> {
    let mut maior = 0i64;
    let mut s = Contagens::default();
    let con = conn()?;
    transacao(&con, || {
        conferir_geracao(dono, geracao)?; // prestador deletado no meio: o lote não entra
        for item in itens {
            if cancelar.is_some_and(|c| c()) {
                return Err(cancelado());
            }
            s.documentos += 1;
            let nsu_item: i64 = match ci(item, "NSU") {
                Some(v) if !vazio_py(v) => aparar(&texto_py(v)).parse().unwrap_or(0),
                _ => 0,
            };
            maior = maior.max(nsu_item);
            let chave_item = so_doc(&texto_de(ci(item, "ChaveAcesso")));
            let feito: Res<Dado<()>> = (|| {
                let xml_bytes = match decodificar_arquivo(ci(item, "ArquivoXml")) {
                    Ok(x) => x,
                    Err(e) => return Ok(Err(e)),
                };
                let tipo = tipo_do_xml(&xml_bytes);
                if tipo == "nfse" {
                    let (resultado, papel) =
                        gravar_nota(&con, dono, &xml_bytes, Some(nsu_item), "adn")?;
                    match resultado {
                        "invalida" => {
                            return Ok(Err((
                                "ValueError",
                                "XML de NFS-e sem os campos de identificação".into(),
                            )));
                        }
                        "nova" => {
                            s.novas += 1;
                            match papel {
                                PAPEL_EMITIDA => s.emitidas += 1,
                                PAPEL_RECEBIDA => s.recebidas += 1,
                                _ => s.outras += 1,
                            }
                        }
                        _ => s.repetidos += 1,
                    }
                } else if tipo == "evento" || tipo == "pedregevento" {
                    match gravar_evento(&con, dono, &xml_bytes, Some(nsu_item), "adn")? {
                        "invalido" => {
                            return Ok(Err((
                                "ValueError",
                                "evento sem chave da NFS-e ou sem tipo".into(),
                            )));
                        }
                        "novo" => s.eventos += 1,
                        _ => s.repetidos += 1,
                    }
                } else {
                    return Ok(Err((
                        "ValueError",
                        format!(
                            "tipo de documento não previsto ({})",
                            if tipo.is_empty() { "ilegível" } else { &tipo }
                        ),
                    )));
                }
                Ok(Ok(()))
            })();
            let falha = match feito {
                Ok(Ok(())) => None,
                Ok(Err((classe, msg))) => Some((classe, msg)),
                Err(e) => Some((e.tipo, e.msg)),
            };
            if let Some((classe, msg)) = falha {
                // guarda o que chegou e segue a fila
                s.quarentena += 1;
                let bruto = jsonpy::dumps(item, jsonpy::Formato::UTF8);
                let mut z = flate2::write::ZlibEncoder::new(Vec::new(), Compression::new(9));
                z.write_all(bruto.as_bytes())?;
                let compactado = z.finish()?;
                let erro_txt: String = format!("{classe}: {msg}").chars().take(300).collect();
                con.execute(
                    "INSERT INTO quarentena (dono, amb, nsu, chave, erro, entrou, bruto) VALUES (?1,?2,?3,?4,?5,?6,?7)",
                    params![dono, amb, nsu_item, chave_item, erro_txt, epoca(), compactado],
                )?;
                registro::aviso(
                    "cofre",
                    &format!("Cofre: documento do NSU {nsu_item} foi para a quarentena: {msg}"),
                );
            }
        }
        if maior != 0 {
            con.execute(
                "INSERT INTO cursor (dono, amb, nsu, quando, em_dia) VALUES (?1,?2,?3,?4,0) \
                 ON CONFLICT(dono, amb) DO UPDATE SET nsu=max(nsu, excluded.nsu), quando=excluded.quando, em_dia=0",
                params![dono, amb, maior, agora()],
            )?;
        }
        if cancelar.is_some_and(|c| c()) {
            return Err(cancelado());
        }
        Ok(())
    })?;
    total.documentos += s.documentos;
    total.novas += s.novas;
    total.emitidas += s.emitidas;
    total.recebidas += s.recebidas;
    total.outras += s.outras;
    total.eventos += s.eventos;
    total.repetidos += s.repetidos;
    total.quarentena += s.quarentena;
    Ok(maior)
}

// --------------------------------------------------------------------------------------------- //
// Alcance da sincronização e modo automático (Configurações > Avançado)
// --------------------------------------------------------------------------------------------- //
const META_SINC: &str = "cofre.sincronizacao"; // preferências (JSON), valem para a instalação
const META_AUTO_ULTIMA: &str = "cofre.automatica.ultima"; // quando a automática rodou pela última vez (época)
pub const INTERVALOS: [i64; 5] = [15, 30, 60, 120, 360]; // minutos entre sincronizações automáticas

/// Preferências de sincronização.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Config {
    /// "atual" = só o ambiente em uso; "ambos" = produção e homologação.
    pub ambientes: String,
    /// Sincronizar sozinho, de tempos em tempos.
    pub automatica: bool,
    /// "atual", "todos" (existentes permitidos) ou "usuario" (vinculados ao usuário).
    pub prestadores: String,
    /// Minutos (um de INTERVALOS).
    pub intervalo: i64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            ambientes: "atual".into(),
            automatica: false,
            prestadores: "atual".into(),
            intervalo: 60,
        }
    }
}

/// Preferências de sincronização (ou o padrão). Nunca falha.
pub fn config() -> Config {
    let mut cfg = Config::default();
    let Ok(texto) = banco::get_meta(META_SINC) else {
        return cfg;
    };
    let Ok(salvo) = serde_json::from_str::<Value>(if texto.is_empty() { "{}" } else { &texto })
    else {
        return cfg;
    };
    let Some(m) = salvo.as_object() else {
        return cfg;
    };
    if let Some(v @ ("atual" | "ambos")) = m.get("ambientes").and_then(Value::as_str) {
        cfg.ambientes = v.into();
    }
    if let Some(v @ ("atual" | "todos" | "usuario")) = m.get("prestadores").and_then(Value::as_str)
    {
        cfg.prestadores = v.into();
    }
    if let Some(v) = m
        .get("intervalo")
        .and_then(Value::as_i64)
        .filter(|v| INTERVALOS.contains(v))
    {
        cfg.intervalo = v;
    }
    cfg.automatica = m.get("automatica").is_some_and(|v| !vazio_py(v));
    cfg
}

pub fn salvar_config(cfg: &Value) -> Res<Config> {
    let texto_de_campo = |nome: &str| cfg.get(nome).and_then(Value::as_str).unwrap_or("");
    let (ambientes, prestadores) = (texto_de_campo("ambientes"), texto_de_campo("prestadores"));
    if !matches!(ambientes, "atual" | "ambos")
        || !matches!(prestadores, "atual" | "todos" | "usuario")
    {
        return Err(Erro::valor("Opção de sincronização inválida."));
    }
    let Some(intervalo) = cfg
        .get("intervalo")
        .and_then(Value::as_i64)
        .filter(|v| INTERVALOS.contains(v))
    else {
        return Err(Erro::valor("Intervalo de sincronização inválido."));
    };
    let limpo = Config {
        ambientes: ambientes.into(),
        automatica: cfg.get("automatica").is_some_and(|v| !vazio_py(v)),
        prestadores: prestadores.into(),
        intervalo,
    };
    banco::set_meta(
        META_SINC,
        &jsonpy::dumps(&serde_json::to_value(&limpo)?, jsonpy::Formato::PADRAO),
    )?;
    Ok(limpo)
}

/// Ambientes a sincronizar para um prestador cujo ambiente em uso é `ambiente_em_uso`.
pub fn ambientes_de(cfg: &Config, ambiente_em_uso: &str) -> Vec<String> {
    if cfg.ambientes == "ambos" {
        return vec![AMB_PRODUCAO.into(), AMB_HOMOLOGACAO.into()];
    }
    vec![if host(ambiente_em_uso).is_some() {
        ambiente_em_uso.to_string()
    } else {
        AMB_PRODUCAO.to_string()
    }]
}

/// Pares (prestador, ambiente) da sincronização AUTOMÁTICA: o prestador em uso ou todos os que o
/// usuário enxerga, cada um no próprio ambiente em uso ou nos dois.
pub fn alvos(
    cfg: &Config,
    prestador_em_uso: &str,
    prestadores: &[String],
    ambiente_de: &dyn Fn(&str) -> String,
) -> Vec<(String, String)> {
    let quem: Vec<String> = if matches!(cfg.prestadores.as_str(), "todos" | "usuario") {
        prestadores.to_vec()
    } else if prestador_em_uso.is_empty() {
        Vec::new()
    } else {
        vec![prestador_em_uso.to_string()]
    };
    let mut out = Vec::new();
    for p in quem.iter().filter(|p| !p.is_empty()) {
        for amb in ambientes_de(cfg, &ambiente_de(p)) {
            out.push((so_doc(p), amb));
        }
    }
    out
}

pub fn ultima_automatica() -> f64 {
    banco::get_meta(META_AUTO_ULTIMA)
        .ok()
        .and_then(|v| texto::float_py(if v.is_empty() { "0" } else { &v }))
        .unwrap_or(0.0)
}

pub fn marcar_automatica(quando: Option<i64>) {
    if let Err(e) = banco::set_meta(META_AUTO_ULTIMA, &quando.unwrap_or_else(epoca).to_string()) {
        registro::erro(
            "cofre",
            &format!("Falha ao registrar o horário da sincronização automática: {e}"),
        );
    }
}

/// Sincroniza vários (prestador, ambiente), um de cada vez. Um erro num deles (sem certificado,
/// consulta rejeitada) é anotado e a fila segue; ADN fora do ar ou sem internet PARA a fila.
/// Nunca falha com erro do cofre: devolve o resumo.
pub fn sincronizar_varios(
    pares: &[(String, String)],
    http: Option<Http>,
    a: &Acompanhar,
    forcar: bool,
) -> Res<Value> {
    let (mut feitos, mut erros): (Vec<Value>, Vec<Value>) = (Vec::new(), Vec::new());
    let (mut recentes, mut sem_rede, mut foi_cancelado, mut limite) =
        (0i64, String::new(), false, false);
    let mut soma = Contagens::default();
    for (prestador, amb) in pares {
        if a.cancelar.is_some_and(|c| c()) {
            foi_cancelado = true;
            break;
        }
        let com_dono = |v: &Value| {
            if let Some(p) = a.progresso {
                let mut v = v.clone();
                if let Some(m) = v.as_object_mut() {
                    m.insert("prestador".into(), json!(prestador));
                    m.insert("amb".into(), json!(amb));
                }
                p(&v);
            }
        };
        let acompanhar = Acompanhar {
            progresso: a.progresso.map(|_| &com_dono as &dyn Fn(&Value)),
            cancelar: a.cancelar,
            dormir: a.dormir,
        };
        let st = match sincronizar(prestador, amb, http, &acompanhar, forcar) {
            Ok(st) => st,
            Err(e) if e.tipo == "CofreRecente" => {
                recentes += 1;
                continue;
            }
            Err(e) if e.tipo == "CofreIndisponivel" => {
                sem_rede = e.msg;
                break;
            }
            Err(e) if e_do_cofre(&e) => {
                erros.push(json!([prestador, amb, e.msg]));
                continue;
            }
            Err(e) => return Err(e),
        };
        soma.novas += st.novas;
        soma.emitidas += st.emitidas;
        soma.recebidas += st.recebidas;
        soma.outras += st.outras;
        soma.eventos += st.eventos;
        soma.quarentena += st.quarentena;
        if st.fim == "limite" {
            limite = true;
        }
        let parou = st.fim == "cancelado";
        feitos.push(json!([prestador, amb, st]));
        if parou {
            foi_cancelado = true;
            break;
        }
    }
    Ok(json!({
        "feitos": feitos, "erros": erros, "recentes": recentes, "sem_rede": sem_rede, "cancelado": foi_cancelado,
        "novas": soma.novas, "emitidas": soma.emitidas, "recebidas": soma.recebidas, "outras": soma.outras,
        "eventos": soma.eventos, "quarentena": soma.quarentena, "limite": limite,
    }))
}

// --------------------------------------------------------------------------------------------- //
// Integridade e cópia de segurança
// --------------------------------------------------------------------------------------------- //
pub const DANIFICADO: &str = "danificado: "; // prefixo do resultado de verificar() que aciona a recuperação
pub const INDISPONIVEL: &str = "indisponível: "; // não deu para conferir AGORA (ocupado, disco): não é dano

fn conferir_conexao(con: &Connection) -> String {
    let conferir = || -> Result<String, rusqlite::Error> {
        let paginas: Vec<String> = {
            let mut st = con.prepare("PRAGMA cipher_integrity_check")?;
            let l = st.query_map([], |r| r.get::<_, String>(0))?;
            l.collect::<Result<_, _>>()?
        };
        if let Some(primeira) = paginas.first() {
            return Ok(format!(
                "{DANIFICADO}{} página(s) do arquivo com a assinatura errada (ex.: {primeira})",
                paginas.len()
            ));
        }
        let estrutura: Vec<String> = {
            let mut st = con.prepare("PRAGMA quick_check")?;
            let l = st.query_map([], |r| r.get::<_, String>(0))?;
            l.collect::<Result<_, _>>()?
        };
        Ok(if estrutura == ["ok"] {
            "ok".to_string()
        } else {
            format!(
                "{DANIFICADO}estrutura com problema: {}",
                estrutura
                    .iter()
                    .take(3)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("; ")
            )
        })
    };
    match conferir() {
        Ok(r) => r,
        Err(e) if operacional(&e) => format!("{INDISPONIVEL}{}", msg_sqlite(&e)),
        Err(e) => format!("{DANIFICADO}{}", msg_sqlite(&e)),
    }
}

/// Confere o banco de notas (ou a cópia em `caminho`): a assinatura de CADA página do arquivo
/// cifrado e a estrutura do SQLite. Devolve 'ok', 'danificado: …' (o arquivo está estragado) ou
/// 'indisponível: …' (não deu para conferir agora — NÃO quer dizer que esteja estragado).
pub fn verificar(caminho: Option<&Path>) -> String {
    verificar_arquivo(caminho, false)
}

pub(crate) fn verificar_copia_usuario(caminho: &Path) -> String {
    verificar_arquivo(Some(caminho), true)
}

fn verificar_arquivo(caminho: Option<&Path>, externo: bool) -> String {
    let con = match caminho {
        Some(p) => {
            let chave = match chave() {
                Ok(c) => c,
                Err(e) if e.tipo == "CofreIlegivel" => return format!("{DANIFICADO}{e}"),
                Err(e) => return format!("{INDISPONIVEL}{e}"),
            };
            if externo {
                return caminhos::arquivo_usuario(|| ligar(&chave, p).map(|c| conferir_conexao(&c)).map_err(crate::erro::Erro::from))
                    .unwrap_or_else(|e| format!("{INDISPONIVEL}{e}"));
            }
            match ligar(&chave, p) {
                Ok(c) => c,
                Err(e) if operacional(&e) => return format!("{INDISPONIVEL}{}", msg_sqlite(&e)),
                Err(e) => return format!("{DANIFICADO}não abre ({})", msg_sqlite(&e)),
            }
        }
        None => match conn() {
            Ok(c) => c,
            Err(e) if e.tipo == "CofreIlegivel" => return format!("{DANIFICADO}{e}"),
            Err(e) if e.tipo == "DatabaseError" => return format!("{DANIFICADO}não abre ({e})"),
            Err(e) => return format!("{INDISPONIVEL}{e}"),
        },
    };
    conferir_conexao(&con)
}

fn idade_em_segundos(p: &Path) -> Option<f64> {
    let m = std::fs::metadata(p).ok()?;
    if !m.is_file() {
        return None;
    }
    Some(
        SystemTime::now()
            .duration_since(m.modified().ok()?)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0),
    )
}

/// Refaz a cópia de segurança (database/notas.db.bak) se ela não existe ou tem mais de COPIA_IDADE_H
/// horas. Só copia um banco CONFERIDO — nunca põe um arquivo ruim por cima de uma cópia boa — e
/// a cópia também é conferida antes de valer. Devolve o caminho se copiou.
pub fn copiar_seguranca(forcar: bool) -> Res<Option<PathBuf>> {
    if !existe() {
        return Ok(None);
    }
    let copia = caminho_copia();
    if !forcar && idade_em_segundos(&copia).is_some_and(|i| i < COPIA_IDADE_H * 3600.0) {
        return Ok(None);
    }
    let est = verificar(None);
    if est != "ok" {
        return Err(erro(format!(
            "O banco de notas não passou na conferência ({est}); a cópia de segurança anterior foi mantida."
        )));
    }
    let tmp = com_sufixo(&copia, ".tmp");
    {
        let con = conn()?;
        con.execute_batch("BEGIN IMMEDIATE")?; // ninguém grava até a cópia terminar
        if std::fs::metadata(caminho_db())?.len() > banco::REGIAO_TRAVA_SQLITE {
            con.execute_batch("ROLLBACK")?;
            let _ = std::fs::remove_file(&tmp);
            let mut chave_sal = chave()?;
            chave_sal.extend(banco::sal_do_arquivo(Some(&caminho_db())));
            let mut destino = ligar(&chave_sal, &tmp)?;
            banco::copiar_paginas(&con, &mut destino)?;
        } else {
            let copiou = std::fs::copy(caminho_db(), &tmp);
            let _ = con.execute_batch("ROLLBACK");
            copiou?;
        }
    }
    let est = verificar(Some(&tmp));
    if est != "ok" {
        let _ = std::fs::remove_file(&tmp);
        return Err(erro(format!(
            "A cópia de segurança não conferiu ({est}) e foi descartada."
        )));
    }
    std::fs::rename(&tmp, &copia)?;
    let mb = std::fs::metadata(&copia)
        .map(|m| m.len() as f64 / 1_048_576.0)
        .unwrap_or(0.0);
    registro::info(
        "cofre",
        &format!("Cópia de segurança do banco de notas refeita ({mb:.1} MB)."),
    );
    Ok(Some(copia))
}

/// Escreve uma cópia cifrada e consistente do notas.db. A API de backup atende arquivos acima
/// de 1 GiB sem ler como dados a região que o SQLite bloqueia no Windows.
pub fn gravar_copia(saida: &mut dyn Write) -> Res<u64> {
    let con = conn()?;
    con.execute_batch("BEGIN IMMEDIATE").map_err(|e| {
        if operacional(&e) {
            erro(format!(
                "O banco de notas está ocupado ({}); tente de novo em instantes.",
                msg_sqlite(&e)
            ))
        } else {
            e.into()
        }
    })?;
    if std::fs::metadata(caminho_db())?.len() > banco::REGIAO_TRAVA_SQLITE {
        con.execute_batch("ROLLBACK")?;
        let copia = banco::ArquivoCopia::novo("notas")?;
        {
            let mut chave_sal = chave()?;
            chave_sal.extend(banco::sal_do_arquivo(Some(&caminho_db())));
            let mut destino = ligar(&chave_sal, &copia.0)?;
            banco::copiar_paginas(&con, &mut destino)?;
        }
        return Ok(std::io::copy(&mut std::fs::File::open(&copia.0)?, saida)?);
    }
    let mut copiar = || -> Res<u64> {
        let mut f = std::fs::File::open(caminho_db())?;
        Ok(std::io::copy(&mut f, saida)?)
    };
    let r = copiar();
    let _ = con.execute_batch("ROLLBACK");
    r
}

/// Erro se `arquivo` não é um banco de notas deste programa, inteiro, que abre com `chave`
/// (confere a assinatura de cada página e a estrutura).
pub fn conferir_arquivo(arquivo: &Path, chave: &[u8]) -> Res<()> {
    let con = ligar(chave, arquivo).map_err(|e| {
        erro(format!(
            "O banco de notas do backup não abre com a chave que veio com ele ({}).",
            msg_sqlite(&e)
        ))
    })?;
    let ler = || -> Result<(bool, Vec<String>), rusqlite::Error> {
        let estado = conferir_conexao(&con);
        let mut st = con.prepare("SELECT name FROM sqlite_master WHERE type='table'")?;
        let tabelas = st
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok((estado == "ok", tabelas))
    };
    let (bom, tabelas) = ler().map_err(|e| {
        erro(format!(
            "O banco de notas do backup está danificado ({}).",
            msg_sqlite(&e)
        ))
    })?;
    if !bom {
        return Err(erro(
            "O banco de notas do backup está danificado e não será restaurado.",
        ));
    }
    if !["nota", "nota_xml", "evento", "cursor"]
        .iter()
        .all(|t| tabelas.iter().any(|x| x == t))
    {
        return Err(erro(
            "O arquivo de notas do backup não é um banco de notas deste programa.",
        ));
    }
    Ok(())
}

/// Recifra a cópia já validada e a deixa pronta para a troca coordenada pelo backup.
pub(crate) fn preparar_restauracao(arquivo: &Path, chave_dele: &[u8], chave_local: &[u8]) -> Res<()> {
    if chave_local != chave_dele {
        let con = ligar(chave_dele, arquivo)?;
        con.execute_batch(&format!("PRAGMA rekey = \"x'{}'\";", hex::encode(chave_local)))?;
    }
    drop(ligar(chave_local, arquivo)?);
    std::fs::OpenOptions::new().write(true).open(arquivo)?.sync_all()?;
    // Resolve um possível diário antigo antes de trocar arquivos. Um banco ilegível pode
    // ser substituído desde que não tenha um diário pendente ao lado (verificado pelo backup).
    if existe() {
        let _ = ligar(chave_local, &caminho_db());
    }
    Ok(())
}

pub(crate) fn finalizar_restauracao() {
    if let Ok(mut est) = estado().lock() {
        est.pronto = None;
    }
    limpar_caches();
    let mb = std::fs::metadata(caminho_db())
        .map(|m| m.len() as f64 / 1_048_576.0)
        .unwrap_or(0.0);
    registro::aviso(
        "cofre",
        &format!("Banco de notas SUBSTITUÍDO pelo de um backup ({mb:.1} MB)."),
    );
    if let Err(e) = copiar_seguranca(true) {
        registro::erro(
            "cofre",
            &format!(
                "Cópia de segurança não refeita depois da restauração; a antiga foi apagada. ({e})"
            ),
        );
        let copia = caminho_copia();
        let _ = std::fs::remove_file(&copia);
        let _ = std::fs::remove_file(com_sufixo(&copia, "-journal"));
    }
}

/// Cuidado periódico do banco de notas (uma vez por sessão e depois de sincronizar): confere; se
/// não passar, recupera da cópia de segurança (ou, sem cópia boa, guarda o arquivo ruim e
/// recomeça vazio — as notas voltam do ADN ao sincronizar); se passar, refaz a cópia quando ela
/// está velha. Devolve {'estado', 'recuperado', 'copiou', 'aviso'}.
pub fn manutencao() -> Res<Value> {
    let (mut recuperado, mut copiou, mut aviso) = (false, false, String::new());
    let copia = caminho_copia();
    if !existe() && !copia.is_file() {
        return Ok(json!({ "estado": "vazio", "recuperado": false, "copiou": false, "aviso": "" }));
    }
    let recuperou = "O banco de notas estava danificado e foi recuperado da cópia de segurança. Sincronize o Cofre para trazer o que falta.";
    let quantas = || estado().lock().map(|e| e.recuperacoes.len()).unwrap_or(0);
    let antes = quantas();
    let mut est = verificar(None);
    if quantas() > antes {
        // O arquivo nem abria: a recuperação aconteceu na própria abertura (ver conn).
        recuperado = true;
        aviso = recuperou.to_string();
    }
    if let Some(motivo) = est.strip_prefix(DANIFICADO).map(str::to_string) {
        {
            let chave = chave()?;
            let mut e = estado()
                .lock()
                .map_err(|_| erro("O banco de notas está indisponível."))?;
            if recuperar(
                &mut e,
                &chave,
                &format!("não passou na conferência: {motivo}"),
            )? {
                recuperado = true;
                aviso = recuperou.to_string();
            } else if existe() {
                let destino = nome_danificado();
                std::fs::rename(caminho_db(), &destino)?;
                e.pronto = None;
                limpar_caches();
                let nome = nome_de(&destino);
                e.recuperacoes
                    .push(json!({ "motivo": motivo, "copia_de": "", "guardado": nome }));
                registro::erro(
                    "cofre",
                    &format!(
                        "Banco de notas danificado ({est}) e SEM cópia de segurança boa: guardado como {nome}; o cofre recomeça vazio."
                    ),
                );
                recuperado = true;
                aviso = format!(
                    "O banco de notas estava danificado e não havia cópia de segurança. O arquivo foi guardado como {nome} \
                     e o Cofre recomeçou vazio: sincronize para trazer as notas de novo."
                );
            }
        }
        est = if existe() {
            verificar(None)
        } else {
            "vazio".to_string()
        };
    }
    if est == "ok" {
        // Cópia que não confere não serve para nada: é refeita já, mesmo sendo recente.
        let copia_boa = copia.is_file() && verificar(Some(&copia)) == "ok";
        match copiar_seguranca(!copia_boa) {
            Ok(c) => copiou = c.is_some(),
            Err(e) if e_do_cofre(&e) => {
                if aviso.is_empty() {
                    aviso = e.msg;
                }
            }
            Err(e) if e.do_sistema() => {
                if aviso.is_empty() {
                    aviso = format!("Não foi possível gravar a cópia de segurança: {e}");
                }
            }
            Err(e) => return Err(e),
        }
    }
    Ok(json!({ "estado": est, "recuperado": recuperado, "copiou": copiou, "aviso": aviso }))
}

/// O que saiu de um arquivo ao apagar um prestador.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct Apagado {
    pub notas: i64,
    pub eventos: i64,
    pub quarentena: i64,
    pub certificados: i64,
}

/// Tira de UM arquivo (o banco ou a cópia de segurança) tudo o que é de `dono`, numa transação.
fn apagar_dono_em(con: &Connection, dono: &str) -> Result<Apagado, rusqlite::Error> {
    con.execute_batch("PRAGMA secure_delete = ON;")?; // o que sai é sobrescrito no arquivo
    con.execute_batch("BEGIN IMMEDIATE")?;
    let apagar = || -> Result<Apagado, rusqlite::Error> {
        let notas: i64 = con.query_row("SELECT count(*) FROM nota WHERE dono=?1", [dono], |r| {
            r.get(0)
        })?;
        con.execute(
            "DELETE FROM nota_xml WHERE nota IN (SELECT id FROM nota WHERE dono=?1)",
            [dono],
        )?;
        con.execute("DELETE FROM nota WHERE dono=?1", [dono])?;
        let eventos = con.execute("DELETE FROM evento WHERE dono=?1", [dono])? as i64;
        let quarentena = con.execute("DELETE FROM quarentena WHERE dono=?1", [dono])? as i64;
        con.execute("DELETE FROM cursor WHERE dono=?1", [dono])?;
        // Os moldes são por dono: só os documentos dele os usavam. Os certificados são
        // compartilhados (o da SEFIN está em quase todas as notas): sai só o que nenhuma nota ou
        // evento que FICA ainda usa.
        con.execute("DELETE FROM molde WHERE dono=?1", [dono])?;
        let mut usados: Vec<i64> = Vec::new();
        {
            let mut st = con.prepare("SELECT DISTINCT certs FROM nota_xml WHERE certs <> '' UNION SELECT DISTINCT certs FROM evento WHERE certs <> ''")?;
            for certs in st.query_map([], |r| r.get::<_, String>(0))? {
                usados.extend(certs?.split(',').filter_map(|x| x.parse::<i64>().ok()));
            }
        }
        let todos: Vec<i64> = {
            let mut st = con.prepare("SELECT id FROM cert")?;
            st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?
        };
        let mut certificados = 0;
        for id in todos.into_iter().filter(|id| !usados.contains(id)) {
            con.execute("DELETE FROM cert WHERE id=?1", [id])?;
            certificados += 1;
        }
        Ok(Apagado {
            notas,
            eventos,
            quarentena,
            certificados,
        })
    };
    match apagar() {
        Ok(a) => {
            con.execute_batch("COMMIT")?;
            Ok(a)
        }
        Err(e) => {
            let _ = con.execute_batch("ROLLBACK");
            Err(e)
        }
    }
}

/// Apaga do banco de notas TUDO o que é de um prestador — é chamado quando o prestador é
/// deletado do programa: as notas e os XMLs, os eventos, a posição no ADN (NSU), a quarentena e
/// os moldes de compactação dele; os certificados que só as notas dele usavam saem junto.
///
/// A cópia de segurança passa pela MESMA limpeza na hora — senão as notas apagadas continuariam
/// nela e voltariam numa recuperação; se a cópia não aceitar a limpeza, ela é apagada e refeita
/// na próxima manutenção. Uma sincronização em curso desse prestador para sozinha. Banco ocupado
/// dá erro: quem chama deve desistir de apagar o resto do prestador e tentar de novo.
pub fn apagar_dono(dono: &str) -> Res<Apagado> {
    let dono = so_doc(dono);
    if dono.is_empty() {
        return Ok(Apagado::default());
    }
    if let Ok(mut g) = geracoes().lock() {
        *g.entry(dono.clone()).or_insert(0) += 1;
    }
    let copia = caminho_copia();
    if !existe() && !copia.is_file() {
        return Ok(Apagado::default()); // nunca houve banco de notas nesta instalação
    }
    let out = {
        let con = conn()?;
        apagar_dono_em(&con, &dono).map_err(|e| {
            if operacional(&e) {
                erro(format!(
                    "O banco de notas está ocupado ({}) e as notas do prestador não puderam ser apagadas. Tente de novo em instantes.",
                    msg_sqlite(&e)
                ))
            } else {
                e.into()
            }
        })?
    };
    limpar_caches();
    if copia.is_file() {
        let limpar = || -> Res<()> {
            let chave = chave()?;
            let con = ligar(&chave, &copia)?;
            apagar_dono_em(&con, &dono)?;
            Ok(())
        };
        if let Err(e) = limpar() {
            registro::aviso(
                "cofre",
                &format!(
                    "A cópia de segurança do banco de notas não aceitou a limpeza do prestador {dono} ({e}); ela foi apagada e será refeita."
                ),
            );
            let _ = std::fs::remove_file(&copia);
            let _ = std::fs::remove_file(com_sufixo(&copia, "-journal"));
        }
    }
    if out != Apagado::default() {
        registro::aviso(
            "cofre",
            &format!(
                "Banco de notas: prestador {dono} apagado — {} nota(s), {} evento(s), {} em quarentena, {} certificado(s) sem uso.",
                out.notas, out.eventos, out.quarentena, out.certificados
            ),
        );
    }
    Ok(out)
}

const COMPACTAR_LIVRE_MIN: f64 = 0.05; // fração do arquivo que precisa estar livre para valer um VACUUM...
const COMPACTAR_LIVRE_MB: f64 = 4.0; // ...ou este tanto, em MB

fn tamanho_mb(p: &Path) -> f64 {
    std::fs::metadata(p)
        .map(|m| m.len() as f64 / 1_048_576.0)
        .unwrap_or(0.0)
}

/// Devolve ao disco o espaço que notas apagadas deixaram no arquivo (o banco é reescrito enxuto,
/// numa operação que ou vale inteira ou não muda nada) e refaz a cópia de segurança a partir
/// dele. Só mexe se houver espaço livre que compense. Devolve {'antes_mb', 'depois_mb',
/// 'compactou', 'copiou'}.
pub fn compactar_arquivo(forcar: bool) -> Res<Value> {
    if !existe() {
        return Ok(
            json!({ "antes_mb": 0.0, "depois_mb": 0.0, "compactou": false, "copiou": false }),
        );
    }
    let antes = tamanho_mb(&caminho_db());
    {
        let con = conn()?;
        // o SQLCipher devolve alguns destes como texto
        let n = |pragma: &str| -> Result<i64, rusqlite::Error> {
            con.query_row(&format!("PRAGMA {pragma}"), [], |r| {
                Ok(match r.get::<_, rusqlite::types::Value>(0)? {
                    rusqlite::types::Value::Integer(i) => i,
                    rusqlite::types::Value::Text(t) => t.trim().parse().unwrap_or(0),
                    rusqlite::types::Value::Real(f) => f as i64,
                    _ => 0,
                })
            })
        };
        let ocupado = |e: rusqlite::Error| {
            if operacional(&e) {
                erro(format!(
                    "O banco de notas não pôde ser compactado agora ({}).",
                    msg_sqlite(&e)
                ))
            } else {
                e.into()
            }
        };
        let (paginas, livres, tamanho) = (
            n("page_count").map_err(ocupado)?,
            n("freelist_count").map_err(ocupado)?,
            n("page_size").map_err(ocupado)?,
        );
        let compensa = livres != 0
            && (livres as f64 / paginas.max(1) as f64 >= COMPACTAR_LIVRE_MIN
                || (livres * tamanho) as f64 >= COMPACTAR_LIVRE_MB * 1_048_576.0);
        if !(forcar || compensa) {
            return Ok(
                json!({ "antes_mb": antes, "depois_mb": antes, "compactou": false, "copiou": false }),
            );
        }
        con.execute_batch("VACUUM").map_err(ocupado)?;
    }
    let depois = tamanho_mb(&caminho_db());
    registro::info(
        "cofre",
        &format!("Banco de notas compactado: {antes:.1} MB -> {depois:.1} MB."),
    );
    let copiou = copiar_seguranca(true)?.is_some();
    Ok(json!({ "antes_mb": antes, "depois_mb": depois, "compactou": true, "copiou": copiou }))
}

/// Para a tela: tamanho do banco e data da cópia de segurança (sem abrir o banco).
pub fn situacao_protecao() -> Value {
    let copia = caminho_copia();
    json!({ "banco_mb": tamanho_mb(&caminho_db()), "copia_mb": tamanho_mb(&copia), "copia_em": data_do_arquivo(&copia) })
}

// --------------------------------------------------------------------------------------------- //
// Consulta
// --------------------------------------------------------------------------------------------- //
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[allow(non_snake_case)]
pub struct Nota {
    pub id: i64,
    pub chave: String,
    pub papel: String,
    pub amb: String,
    pub nNFSe: String,
    pub dhProc: String,
    pub dt: String,
    pub dCompet: String,
    pub emit_doc: String,
    pub emit_nome: String,
    pub toma_doc: String,
    pub toma_nome: String,
    pub vServ: f64,
    pub vLiq: f64,
    pub cStat: String,
    pub cancelada: bool,
    pub subst_por: String,
    pub origem: String,
}

impl Nota {
    pub fn papel_rotulo(&self) -> &'static str {
        match self.papel.as_str() {
            PAPEL_EMITIDA => "Emitida",
            PAPEL_RECEBIDA => "Recebida",
            _ => "Outro papel",
        }
    }

    /// A outra parte da nota: o tomador nas emitidas, o emitente nas recebidas e demais.
    pub fn outro_doc(&self) -> &str {
        if self.papel == PAPEL_EMITIDA {
            &self.toma_doc
        } else {
            &self.emit_doc
        }
    }

    pub fn outro_nome(&self) -> &str {
        if self.papel == PAPEL_EMITIDA {
            &self.toma_nome
        } else {
            &self.emit_nome
        }
    }
}

const COLUNAS: [&str; 18] = [
    "id",
    "chave",
    "papel",
    "amb",
    "nNFSe",
    "dhProc",
    "dt",
    "emit_doc",
    "emit_nome",
    "toma_doc",
    "toma_nome",
    "vServ",
    "vLiq",
    "cStat",
    "cancelada",
    "subst_por",
    "origem",
    "dCompet",
];
const OUTRO_DOC: &str = "(CASE papel WHEN 'E' THEN toma_doc ELSE emit_doc END)";

/// Última nota emitida de cada cliente, em uma consulta por prestador.
pub fn ultimas_por_tomador(dono: &str) -> Res<Vec<(String, String, String)>> {
    if !existe() {
        return Ok(Vec::new());
    }
    let con = conn()?;
    let mut stmt = con.prepare("SELECT toma_doc, nNFSe, dhProc FROM (SELECT toma_doc, nNFSe, dhProc, ROW_NUMBER() OVER (PARTITION BY toma_doc ORDER BY dhProc DESC, nNFSe_int DESC, id DESC) AS pos FROM nota WHERE dono=?1 AND papel='E') WHERE pos=1")?;
    Ok(stmt
        .query_map([dono], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<Result<Vec<_>, _>>()?)
}

fn ordem_sql(coluna: &str) -> &'static str {
    match coluna {
        "tipo" => "papel",
        "numero" => "nNFSe_int",
        "cstat" => "cStat",
        "nome" => "(CASE papel WHEN 'E' THEN toma_nome ELSE emit_nome END) COLLATE NOCASE",
        "doc" => "(CASE papel WHEN 'E' THEN toma_doc ELSE emit_doc END)",
        "amb" => "amb",
        "status" => "cancelada",
        "vserv" => "vServ",
        "vliq" => "vLiq",
        _ => "dhProc",
    }
}

fn nota_da_linha(r: &rusqlite::Row) -> rusqlite::Result<Nota> {
    Ok(Nota {
        id: r.get(0)?,
        chave: r.get(1)?,
        papel: r.get(2)?,
        amb: r.get(3)?,
        nNFSe: r.get(4)?,
        dhProc: r.get(5)?,
        dt: r.get(6)?,
        emit_doc: r.get(7)?,
        emit_nome: r.get(8)?,
        toma_doc: r.get(9)?,
        toma_nome: r.get(10)?,
        vServ: r.get(11)?,
        vLiq: r.get(12)?,
        cStat: r.get(13)?,
        cancelada: r.get::<_, i64>(14)? != 0,
        subst_por: r.get(15)?,
        origem: r.get(16)?,
        dCompet: r.get(17)?,
    })
}

/// Os filtros de uma listagem.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Filtro {
    pub papel: String,
    pub amb: String,
    /// Datas ISO ('AAAA-MM-DD'); vazio = sem limite.
    pub por_competencia: bool,
    pub ini: String,
    pub fim: String,
    /// A busca das telas de notas — regra única em `busca`.
    pub termo: String,
    /// '' todas, 'ativas' ou 'canceladas'.
    pub situacao: String,
    /// (coluna, crescente?); None = data, da mais nova para a mais antiga.
    pub ordem: Option<(String, bool)>,
    pub limite: Option<i64>,
    pub offset: i64,
    /// 'local' = só as que ESTE programa emitiu (é a tela Consultar).
    pub origem: String,
    /// Só as notas cuja outra parte está na lista; lista vazia = nenhuma.
    pub docs: Option<Vec<String>>,
    /// [(documento, grupo)] — só para ordenar por grupo (o grupo é do cadastro de clientes).
    pub grupos: Vec<(String, String)>,
}

/// Página de notas do dono com os filtros dados. Devolve (notas, total, soma dos serviços das
/// notas NÃO canceladas).
pub fn listar(dono: &str, f: &Filtro) -> Res<(Vec<Nota>, i64, f64)> {
    let mut onde: Vec<String> = vec!["dono = ?".into()];
    let mut args: Vec<Value> = vec![json!(so_doc(dono))];
    for (campo, valor) in [("papel", &f.papel), ("origem", &f.origem), ("amb", &f.amb)] {
        if !valor.is_empty() {
            onde.push(format!("{campo} = ?"));
            args.push(json!(valor));
        }
    }
    let data = if f.por_competencia { "dCompet" } else { "dt" };
    if !f.ini.is_empty() {
        onde.push(format!("{data} >= ?"));
        args.push(json!(f.ini));
    }
    if !f.fim.is_empty() {
        onde.push(format!("{data} <= ?"));
        args.push(json!(f.fim));
    }
    match f.situacao.as_str() {
        "ativas" => onde.push("cancelada = 0".into()),
        "canceladas" => onde.push("cancelada = 1".into()),
        _ => {}
    }
    if let Some(docs) = &f.docs {
        let docs: Vec<String> = docs
            .iter()
            .map(|d| so_doc(d))
            .filter(|d| !d.is_empty())
            .collect();
        if docs.is_empty() {
            return Ok((Vec::new(), 0, 0.0));
        }
        onde.push(format!(
            "{OUTRO_DOC} IN ({})",
            vec!["?"; docs.len()].join(",")
        ));
        args.extend(docs.into_iter().map(|d| json!(d)));
    }
    let (cond, ps) = busca::sql_notas(&f.termo, "busca", "chave");
    if !cond.is_empty() {
        onde.push(cond);
        args.extend(ps.into_iter().map(|p| json!(p)));
    }
    let filtro = onde.join(" AND ");
    let (coluna, crescente) = f.ordem.clone().unwrap_or(("data".into(), false));
    let (juncao, expr) = if coluna == "grupo" {
        (
            format!(" LEFT JOIN temp.grupo_doc g ON g.doc = {OUTRO_DOC}"),
            "coalesce(g.nome, '') COLLATE NOCASE",
        )
    } else {
        (String::new(), if coluna == "data" && f.por_competencia { "dCompet" } else { ordem_sql(&coluna) })
    };
    let mut ordenar = format!(
        "{expr} {}, nota.id DESC",
        if crescente { "ASC" } else { "DESC" }
    );
    let mut args_ordem: Vec<Value> = Vec::new();
    let exato = busca::numero_exato(&f.termo);
    if !exato.is_empty() {
        // Quem digita só um número quer, antes de tudo, a nota com esse número.
        ordenar = format!("(nNFSe = ?) DESC, {ordenar}");
        args_ordem.push(json!(exato));
    }
    let con = conn()?;
    if !juncao.is_empty() {
        con.execute_batch("CREATE TEMP TABLE grupo_doc (doc TEXT PRIMARY KEY, nome TEXT)")?;
        for (d, g) in f.grupos.iter().filter(|(_, g)| !g.is_empty()) {
            con.execute(
                "INSERT OR REPLACE INTO temp.grupo_doc VALUES (?1, ?2)",
                params![so_doc(d), g],
            )?;
        }
    }
    let ligar_args = |lista: &[Value]| -> Vec<rusqlite::types::Value> {
        lista
            .iter()
            .map(|v| match v {
                Value::String(s) => rusqlite::types::Value::Text(s.clone()),
                Value::Number(n) => n
                    .as_i64()
                    .map(rusqlite::types::Value::Integer)
                    .unwrap_or(rusqlite::types::Value::Null),
                _ => rusqlite::types::Value::Null,
            })
            .collect()
    };
    let (total, soma): (i64, f64) = con.query_row(
        &format!("SELECT count(*), coalesce(sum(CASE WHEN cancelada = 0 THEN vServ ELSE 0 END), 0) FROM nota WHERE {filtro}"),
        params_from_iter(ligar_args(&args)),
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let colunas = COLUNAS
        .iter()
        .map(|c| format!("nota.{c}"))
        .collect::<Vec<_>>()
        .join(", ");
    let mut todos = args.clone();
    todos.extend(args_ordem);
    todos.push(json!(f.limite.unwrap_or(25)));
    todos.push(json!(f.offset));
    let mut st = con.prepare(&format!(
        "SELECT {colunas} FROM nota{juncao} WHERE {filtro} ORDER BY {ordenar} LIMIT ? OFFSET ?"
    ))?;
    let notas = st
        .query_map(params_from_iter(ligar_args(&todos)), nota_da_linha)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok((notas, total, soma))
}

pub fn nota_por_id(nota_id: i64) -> Res<Option<Nota>> {
    let con = conn()?;
    Ok(con
        .query_row(
            &format!("SELECT {} FROM nota WHERE id=?1", COLUNAS.join(", ")),
            [nota_id],
            nota_da_linha,
        )
        .optional()?)
}

pub fn nota_por_chave(dono: &str, chave: &str) -> Res<Option<Nota>> {
    let con = conn()?;
    nota_por_chave_em(&con, dono, chave)
}

fn nota_por_chave_em(con: &Connection, dono: &str, chave: &str) -> Res<Option<Nota>> {
    Ok(con
        .query_row(
            &format!(
                "SELECT {} FROM nota WHERE dono=?1 AND chave=?2",
                COLUNAS.join(", ")
            ),
            params![so_doc(dono), chave],
            nota_da_linha,
        )
        .optional()?)
}

/// Abertura pela tela: uma conexão, XML sempre conferido e PDF já gerado reutilizado
/// somente se o XML/estado e os bytes do arquivo continuarem os mesmos.
pub fn danfse_para_abrir(dono: &str, chave: &str) -> Res<PathBuf> {
    use std::collections::VecDeque;
    type Marca = ([u8; 32], [u8; 32]);
    static CACHE: std::sync::Mutex<VecDeque<Marca>> = std::sync::Mutex::new(VecDeque::new());
    let leitor = LeitorXml::novo()?;
    leitor.con.execute_batch("BEGIN")?;
    let nota = nota_por_chave_em(&leitor.con, dono, chave)?.ok_or_else(|| Erro::nao_encontrado(
        "O XML desta NFS-e não está no banco de notas. Use Sincronizar, no Cofre, para trazê-lo do ADN."))?;
    let xml = leitor.xml(nota.id)?;
    let mut digest = Sha256::new();
    digest.update(&xml);
    digest.update([
        u8::from(nota.cancelada),
        u8::from(!nota.subst_por.is_empty()),
    ]);
    let identidade: [u8; 32] = digest.finalize().into();
    let caminho = pasta_temporaria()?.join(format!("{}.pdf", crate::texto::only_chave(chave)));
    let esperado = CACHE.lock().ok().and_then(|c| {
        c.iter()
            .find(|(k, _)| k == &identidade)
            .map(|(_, hash)| *hash)
    });
    if let Some(hash) = esperado
        && let Ok(bytes) = caminhos::arquivo_usuario(|| std::fs::read(&caminho))
        && <[u8; 32]>::from(Sha256::digest(&bytes)) == hash
    {
        leitor.conferir_sessao()?;
        return Ok(caminho);
    }
    let pdf = crate::danfse::gerar(&xml, nota.cancelada, !nota.subst_por.is_empty())?;
    leitor.conferir_sessao()?;
    caminhos::arquivo_usuario(|| std::fs::write(&caminho, &pdf))?;
    if let Ok(mut cache) = CACHE.lock() {
        cache.retain(|(k, _)| k != &identidade);
        cache.push_back((identidade, Sha256::digest(&pdf).into()));
        if cache.len() > 64 {
            cache.pop_front();
        }
    }
    Ok(caminho)
}

/// O XML original da nota do dono com esta chave de acesso. Erro se o banco de notas não a tem
/// (ex.: backup só dos dados restaurado numa instalação nova — Sincronizar no Cofre a traz).
pub fn xml_por_chave(dono: &str, chave: &str) -> Res<Vec<u8>> {
    match nota_por_chave(dono, chave)? {
        Some(n) => xml_da_nota(n.id),
        None => Err(erro(
            "O XML desta NFS-e não está no banco de notas. Use Sincronizar, no Cofre, para trazê-lo do ADN.",
        )),
    }
}

/// O XML original da nota, byte a byte.
pub fn xml_da_nota(nota_id: i64) -> Res<Vec<u8>> {
    let con = conn()?;
    xml_da_nota_em(&con, nota_id)
}

/// Uma conexão por exportação, com as mesmas verificações de integridade por XML.
pub(crate) struct LeitorXml {
    con: Connection,
    caminho: PathBuf,
}

impl LeitorXml {
    pub(crate) fn novo() -> Res<Self> {
        Ok(Self {
            con: conn()?,
            caminho: caminho_db(),
        })
    }

    fn conferir_sessao(&self) -> Res<()> {
        if !banco::destrancado() || self.caminho != caminho_db() {
            return Err(Erro::trancado(
                "A sessão foi encerrada durante a exportação.",
            ));
        }
        Ok(())
    }

    pub(crate) fn xml(&self, nota_id: i64) -> Res<Vec<u8>> {
        self.conferir_sessao()?;
        xml_da_nota_em(&self.con, nota_id)
    }

    pub(crate) fn nota(&self, dono: &str, chave: &str) -> Res<Option<Nota>> {
        self.conferir_sessao()?;
        nota_por_chave_em(&self.con, dono, chave)
    }

    pub(crate) fn xml_disponivel(&self, nota_id: i64) -> Res<Option<Vec<u8>>> {
        self.conferir_sessao()?;
        xml_disponivel_em(&self.con, nota_id)
    }

    pub(crate) fn eventos(&self, dono: &str, chave: &str) -> Res<Vec<Evento>> {
        self.conferir_sessao()?;
        eventos_da_nota_em(&self.con, dono, chave)
    }
}

fn xml_da_nota_em(con: &Connection, nota_id: i64) -> Res<Vec<u8>> {
    xml_disponivel_em(con, nota_id)?
        .ok_or_else(|| erro("O XML desta nota não está no banco de notas."))
}

pub(crate) fn xml_disponivel_em(con: &Connection, nota_id: i64) -> Res<Option<Vec<u8>>> {
    let linha: Option<(Vec<u8>, String, i64, Vec<u8>)> = con
        .query_row(
            "SELECT sha, certs, molde, dados FROM nota_xml WHERE nota=?1",
            [nota_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    linha
        .map(|(sha_gravado, certs, molde, dados)| abrir(con, &sha_gravado, &certs, molde, &dados))
        .transpose()
}

/// Um evento guardado de uma nota.
pub struct Evento {
    pub tipo: String,
    pub descricao: String,
    pub dh: String,
    pub xml: Vec<u8>,
}

/// Eventos guardados da nota, do mais antigo para o mais novo (com o XML original).
pub fn eventos_da_nota(dono: &str, chave: &str) -> Res<Vec<Evento>> {
    let con = conn()?;
    eventos_da_nota_em(&con, dono, chave)
}

fn eventos_da_nota_em(con: &Connection, dono: &str, chave: &str) -> Res<Vec<Evento>> {
    let linhas: Vec<(String, String, String, Vec<u8>, String, i64, Vec<u8>)> = {
        let mut st = con.prepare("SELECT tipo, descricao, dh, sha, certs, molde, dados FROM evento WHERE dono=?1 AND chave=?2 ORDER BY dh, id")?;
        st.query_map(params![so_doc(dono), chave], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
            ))
        })?
        .collect::<Result<_, _>>()?
    };
    let mut out = Vec::new();
    for (tipo, descricao, dh, sha_gravado, certs, molde, dados) in linhas {
        out.push(Evento {
            tipo,
            descricao,
            dh,
            xml: abrir(con, &sha_gravado, &certs, molde, &dados)?,
        });
    }
    Ok(out)
}

/// Totais do dono e a situação da sincronização por ambiente.
pub fn resumo(dono: &str) -> Res<Value> {
    let dono = so_doc(dono);
    let con = conn()?;
    let mut tot: HashMap<String, i64> = HashMap::new();
    {
        let mut st =
            con.prepare("SELECT papel, count(*) FROM nota WHERE dono=?1 GROUP BY papel")?;
        for l in st.query_map([&dono], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })? {
            let (papel, n) = l?;
            tot.insert(papel, n);
        }
    }
    let mut cursores = Map::new();
    {
        let mut st = con.prepare("SELECT amb, nsu, quando, em_dia FROM cursor WHERE dono=?1")?;
        for l in st.query_map([&dono], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })? {
            let (amb, nsu, quando, em_dia) = l?;
            cursores.insert(
                amb,
                json!({ "nsu": nsu, "quando": quando, "em_dia": em_dia != 0 }),
            );
        }
    }
    let quarentena: i64 = con.query_row(
        "SELECT count(*) FROM quarentena WHERE dono=?1",
        [&dono],
        |r| r.get(0),
    )?;
    let de = |papel: &str| tot.get(papel).copied().unwrap_or(0);
    Ok(json!({
        "total": tot.values().sum::<i64>(), "emitidas": de(PAPEL_EMITIDA), "recebidas": de(PAPEL_RECEBIDA),
        "outras": de(PAPEL_OUTRO), "cursores": cursores, "quarentena": quarentena,
    }))
}

pub fn vazio(dono: &str) -> Res<bool> {
    let con = conn()?;
    Ok(con
        .query_row(
            "SELECT 1 FROM nota WHERE dono=?1 LIMIT 1",
            [so_doc(dono)],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
        .is_none())
}

// --------------------------------------------------------------------------------------------- //
// DANFSe na hora (nada é guardado: o PDF vai para a pasta temporária do sistema)
// --------------------------------------------------------------------------------------------- //
pub fn pasta_temporaria() -> Res<PathBuf> {
    let pasta = caminhos::temporarios_usuario().join("BaiacuNFSe").join("cofre");
    caminhos::arquivo_usuario(|| std::fs::create_dir_all(&pasta))?;
    Ok(pasta)
}

/// Apaga as DANFSe temporárias antigas (as abertas agora ficam). Devolve quantas saíram.
pub fn limpar_temporarios(mais_velhos_que_s: f64) -> usize {
    let Ok(pasta) = pasta_temporaria() else {
        return 0;
    };
    let mut n = 0;
    for e in std::fs::read_dir(pasta).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_file()
            && idade_em_segundos(&p).is_some_and(|i| i > mais_velhos_que_s)
            && std::fs::remove_file(&p).is_ok()
        {
            n += 1;
        }
    }
    n
}

#[cfg(test)]
mod testes_desempenho {
    use super::*;

    #[test]
    fn leitura_reutilizada_preserva_xml_e_certificados_compartilhados() -> Res<()> {
        let con = Connection::open_in_memory()?;
        con.execute_batch(DDL)?;
        let xml = b"<NFSe><Signature><X509Certificate>QUFBQQ==</X509Certificate></Signature><valor>123.45</valor></NFSe>";
        for (id, dono) in [(1, "11111111000191"), (2, "22222222000191")] {
            con.execute("INSERT INTO nota(id,dono,amb,chave,papel,origem,entrou) VALUES (?1,?2,'2',?3,'E','local',1)", params![id,dono,format!("{id:050}")])?;
            let c = compactar(&con, xml, "nfse", dono, "E")?;
            con.execute(
                "INSERT INTO nota_xml(nota,sha,tam,certs,molde,dados) VALUES (?1,?2,?3,?4,?5,?6)",
                params![id, c.sha, c.tam, c.certs, c.molde, c.dados],
            )?;
        }
        for _ in 0..5 {
            assert_eq!(xml_da_nota_em(&con, 1)?, xml);
        }
        let removido = apagar_dono_em(&con, "11111111000191")?;
        assert_eq!(removido.notas, 1);
        assert_eq!(removido.certificados, 0);
        assert_eq!(xml_da_nota_em(&con, 2)?, xml);
        con.execute("UPDATE nota_xml SET sha=zeroblob(32) WHERE nota=2", [])?;
        assert!(xml_da_nota_em(&con, 2).is_err());
        let removido = apagar_dono_em(&con, "22222222000191")?;
        assert_eq!(removido.certificados, 1);
        assert_eq!(
            con.query_row("SELECT count(*) FROM cert", [], |r| r.get::<_, i64>(0))?,
            0
        );
        Ok(())
    }
}
