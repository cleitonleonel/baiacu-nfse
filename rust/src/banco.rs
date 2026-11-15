//! Banco ÚNICO de dados do programa (database/dados.db).
//!
//! O ARQUIVO É CIFRADO POR INTEIRO (SQLCipher, AES-256 página a página): sem a chave ele não
//! revela nem o nome das tabelas. A chave bruta sai da SENHA MESTRA (o sal fica nos 16 primeiros
//! bytes do próprio arquivo, então dados.db + senha mestra bastam) e é a mesma que cada usuário
//! libera com a própria senha pelo database/dados.key — ver `chaves`. Aqui só entra a chave pronta:
//! `destrancar()` / `criar()`.
//!
//! O que mora AQUI: cadastro do prestador e tributos, série e contadores de numeração, grupos,
//! clientes e serviços, usuários e a chave embrulhada de cada um, segredos (certificado .pfx,
//! senha dele e do SMTP), a fila de contingência e a chave do banco de notas.
//!
//! Modelo dos cadastros: cada "arquivo .ini" é uma CHAVE lógica (ex.:
//! "pessoas/prestador/123/config_tomador.ini" — só um nome; a pasta não existe) com suas
//! (seção, opção, valor) na tabela `config`. Os módulos trabalham com `Ini` em memória.
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use rusqlite::backup::{Backup, StepResult};
use rusqlite::{Connection, OptionalExtension, params};

use crate::caminhos;
use crate::erro::{Erro, Res};
use crate::ini::Ini;

#[derive(Default)]
struct Estado {
    chave: Option<Vec<u8>>, // chave bruta (32 bytes); None = trancado
    sal: Option<Vec<u8>>,   // sal do cabeçalho do arquivo (16 bytes), par da chave
    iniciado: bool,
}

static ESTADO: Mutex<Estado> = Mutex::new(Estado {
    chave: None,
    sal: None,
    iniciado: false,
});

pub const META_CHAVE_NOTAS: &str = "notas.chave"; // chave do database/notas.db, em hexadecimal
const TABELAS_BACKUP: [&str; 3] = ["arquivo", "config", "contador"];

pub fn caminho_db() -> PathBuf {
    caminhos::raiz().join("database").join("dados.db")
}

// ------------------------------------------------------------------------------- //
// Infra
// ------------------------------------------------------------------------------- //
/// Só dados do usuário sob pessoas/ são gerenciados pelo banco; o resto é arquivo.
pub fn gerenciado(caminho: &str) -> bool {
    let chave = caminhos::chave_logica(caminho);
    if !chave.starts_with("pessoas/") || chave.contains("/.shadow/") {
        return false;
    }
    let nome = chave.rsplit('/').next().unwrap_or("");
    chave.ends_with(".ini") || nome.starts_with("last_dps")
}

fn cabecalho(caminho: &Path) -> Vec<u8> {
    let mut buf = [0u8; 16];
    match fs::File::open(caminho) {
        Ok(mut f) => {
            let mut lidos = 0;
            while lidos < 16 {
                match f.read(&mut buf[lidos..]) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => lidos += n,
                }
            }
            buf[..lidos].to_vec()
        }
        Err(_) => Vec::new(),
    }
}

/// "novo" (o banco ainda não existe) ou "cifrado".
pub fn estado() -> &'static str {
    if cabecalho(&caminho_db()).len() == 16 {
        "cifrado"
    } else {
        "novo"
    }
}

/// Sal do banco cifrado: os 16 primeiros bytes do arquivo, legíveis sem chave.
pub fn sal_do_arquivo(caminho: Option<&Path>) -> Vec<u8> {
    cabecalho(caminho.unwrap_or(&caminho_db()))
}

pub fn destrancado() -> bool {
    ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner).chave.is_some()
}

/// (chave, sal) em uso, ou None se trancado.
pub fn chave_atual() -> Option<(Vec<u8>, Vec<u8>)> {
    let e = ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    match (&e.chave, &e.sal) {
        (Some(c), Some(s)) => Some((c.clone(), s.clone())),
        _ => None,
    }
}

fn pragma_chave(chave: &[u8], sal: &[u8]) -> String {
    // Chave BRUTA + sal: sem derivação por senha a cada conexão (o programa abre uma por
    // operação). Tem de ser o primeiro comando da conexão.
    format!(
        "PRAGMA key = \"x'{}{}'\";",
        hex::encode(chave),
        hex::encode(sal)
    )
}

/// Abre um arquivo de banco com (chave, sal).
pub fn abrir(caminho: &Path, chave: &[u8], sal: &[u8]) -> Res<Connection> {
    let con = Connection::open(caminho)?;
    con.busy_timeout(Duration::from_secs(30))?;
    con.execute_batch(&pragma_chave(chave, sal))?;
    Ok(con)
}

/// A chave decifra este arquivo? (Não muda o estado do módulo.)
pub fn chave_abre(caminho: &Path, chave: &[u8], sal: Option<&[u8]>) -> bool {
    let sal = match sal {
        Some(s) => s.to_vec(),
        None => sal_do_arquivo(Some(caminho)),
    };
    if sal.len() != 16 || chave.len() != 32 {
        return false;
    }
    let Ok(con) = Connection::open(caminho) else {
        return false;
    };
    let _ = con.busy_timeout(Duration::from_secs(30));
    // Chave errada faz o SQLCipher escrever o erro no stderr; aqui é resposta esperada.
    let _ = con.execute_batch("PRAGMA cipher_log_level = NONE;");
    if con.execute_batch(&pragma_chave(chave, &sal)).is_err() {
        return false;
    }
    con.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
        r.get::<_, i64>(0)
    })
    .is_ok()
}

/// Libera o banco deste processo com a chave bruta. false = a chave não é dele.
pub fn destrancar(chave: &[u8]) -> bool {
    let sal = sal_do_arquivo(None);
    if estado() != "cifrado" || !chave_abre(&caminho_db(), chave, Some(&sal)) {
        return false;
    }
    let mut e = ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    e.chave = Some(chave.to_vec());
    e.sal = Some(sal);
    e.iniciado = false;
    true
}

/// Cria o banco cifrado de uma instalação nova, já com a chave e o sal escolhidos.
pub fn criar(chave: &[u8], sal: &[u8]) -> Res<()> {
    if estado() != "novo" {
        return Err(Erro::runtime("O banco já existe; não será recriado."));
    }
    let db = caminho_db();
    if let Some(pai) = db.parent() {
        fs::create_dir_all(pai)?;
    }
    let _ = fs::remove_file(&db); // sobra de 0 byte de uma tentativa anterior
    {
        let mut e = ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        e.chave = Some(chave.to_vec());
        e.sal = Some(sal.to_vec());
        e.iniciado = false;
    }
    iniciar()
}

pub fn trancar() {
    let mut e = ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    e.chave = None;
    e.sal = None;
    e.iniciado = false;
}

fn abrir_atual() -> Res<Connection> {
    let Some((chave, sal)) = chave_atual() else {
        return Err(Erro::trancado(
            "O banco está trancado: entre com um usuário ou com a senha mestra.",
        ));
    };
    abrir(&caminho_db(), &chave, &sal)
}

/// Conexão pronta (schema garantido). Uma por operação, como sempre foi.
pub fn conn() -> Res<Connection> {
    iniciar()?;
    abrir_atual()
}

/// Schema atual (o que faltar é criado) — do banco em uso ou de um a ser restaurado.
pub fn criar_tabelas(con: &Connection) -> Res<()> {
    con.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS arquivo (
            nome TEXT PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS config (
            arquivo TEXT NOT NULL,
            secao   TEXT NOT NULL,
            opcao   TEXT NOT NULL,
            valor   TEXT NOT NULL,
            PRIMARY KEY (arquivo, secao, opcao)
        );
        CREATE TABLE IF NOT EXISTS contador (
            arquivo TEXT PRIMARY KEY,
            valor   TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta (
            chave TEXT PRIMARY KEY,
            valor TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS segredo (
            tipo  TEXT NOT NULL,
            chave TEXT NOT NULL,
            valor TEXT NOT NULL,
            PRIMARY KEY (tipo, chave)
        );
        CREATE TABLE IF NOT EXISTS chave_usuario (
            usuario_id INTEGER PRIMARY KEY,
            slot     TEXT NOT NULL,
            sal      BLOB NOT NULL,
            n        INTEGER NOT NULL,
            kek      BLOB NOT NULL,
            embrulho BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pendente (
            prestador TEXT NOT NULL,
            id        TEXT NOT NULL,
            situacao  TEXT NOT NULL DEFAULT 'fila',
            meta      TEXT NOT NULL,
            xml       BLOB NOT NULL,
            config    TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (prestador, id, situacao)
        );
        ",
    )?;
    Ok(())
}

/// Garante o arquivo do banco e o schema (uma vez por processo).
fn iniciar() -> Res<()> {
    if ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner).iniciado {
        return Ok(());
    }
    if let Some(pai) = caminho_db().parent() {
        fs::create_dir_all(pai)?;
    }
    let con = abrir_atual()?;
    criar_tabelas(&con)?;
    drop(con);
    ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner).iniciado = true;
    Ok(())
}

pub(crate) fn reiniciar_schema() {
    ESTADO.lock().unwrap_or_else(std::sync::PoisonError::into_inner).iniciado = false;
}

pub fn get_meta(chave: &str) -> Res<String> {
    let con = conn()?;
    let v: Option<String> = con
        .query_row("SELECT valor FROM meta WHERE chave = ?1", [chave], |r| {
            r.get(0)
        })
        .optional()?;
    Ok(v.unwrap_or_default())
}

pub fn set_meta(chave: &str, valor: &str) -> Res<()> {
    let con = conn()?;
    con.execute(
        "INSERT OR REPLACE INTO meta (chave, valor) VALUES (?1, ?2)",
        params![chave, valor],
    )?;
    Ok(())
}

// ------------------------------------------------------------------------------- //
// Configs (.ini lógicos)
// ------------------------------------------------------------------------------- //
/// O "arquivo" lógico. Chave GERENCIADA (dados do usuário): só o banco. Não gerenciada
/// (configs): lê o arquivo físico. Ausente em ambos: Ini VAZIO.
pub fn load_ini(caminho: &str, literal: bool) -> Res<Ini> {
    if gerenciado(caminho) {
        let con = conn()?;
        let mut st = con.prepare("SELECT secao, opcao, valor FROM config WHERE arquivo = ?1")?;
        let mut ini = Ini::novo();
        let linhas = st.query_map([caminhos::chave_logica(caminho)], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        for linha in linhas {
            let (secao, opcao, valor) = linha?;
            ini.por(&secao, &opcao, &valor);
        }
        return Ok(ini);
    }
    Ini::de_arquivo(&caminhos::absoluto(caminho), literal)
}

pub fn exists_ini(caminho: &str) -> Res<bool> {
    if gerenciado(caminho) {
        let con = conn()?;
        let achou: Option<i64> = con
            .query_row(
                "SELECT 1 FROM arquivo WHERE nome = ?1",
                [caminhos::chave_logica(caminho)],
                |r| r.get(0),
            )
            .optional()?;
        return Ok(achou.is_some());
    }
    Ok(caminhos::absoluto(caminho).exists())
}

/// Grava o Ini: no BANCO (chaves gerenciadas) ou no arquivo (demais).
pub fn save_ini(caminho: &str, ini: &Ini) -> Res<()> {
    if !gerenciado(caminho) {
        let p = caminhos::absoluto(caminho);
        if let Some(pai) = p.parent() {
            fs::create_dir_all(pai)?;
        }
        fs::write(&p, ini.para_texto())?;
        return Ok(());
    }
    let chave = caminhos::chave_logica(caminho);
    let mut con = conn()?;
    let tx = con.transaction()?;
    tx.execute(
        "INSERT OR REPLACE INTO arquivo (nome) VALUES (?1)",
        [&chave],
    )?;
    tx.execute("DELETE FROM config WHERE arquivo = ?1", [&chave])?;
    for secao in ini.secoes() {
        for (opcao, valor) in ini.itens(secao) {
            tx.execute(
                "INSERT OR REPLACE INTO config (arquivo, secao, opcao, valor) VALUES (?1, ?2, ?3, ?4)",
                params![chave, secao, opcao, valor.trim()],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub fn delete_ini(caminho: &str) -> Res<()> {
    let chave = caminhos::chave_logica(caminho);
    let con = conn()?;
    con.execute("DELETE FROM config WHERE arquivo = ?1", [&chave])?;
    con.execute("DELETE FROM arquivo WHERE nome = ?1", [&chave])?;
    Ok(())
}

/// Escapa % e _ literais do CAMINHO (o % final do chamador continua curinga).
fn like(padrao: &str) -> String {
    let (corpo, curinga) = match padrao.strip_suffix('%') {
        Some(c) => (c, "%"),
        None => (padrao, ""),
    };
    format!(
        "{}{}",
        corpo
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_"),
        curinga
    )
}

fn prefixo(caminho: &str) -> String {
    format!("{}/", caminhos::chave_logica(caminho).trim_end_matches('/'))
}

/// Remove TODAS as chaves (configs e contadores) sob um diretório lógico — usado ao excluir
/// prestador/cliente.
pub fn delete_prefix(caminho: &str) -> Res<()> {
    let padrao = like(&format!("{}%", prefixo(caminho)));
    let con = conn()?;
    con.execute(
        "DELETE FROM config WHERE arquivo LIKE ?1 ESCAPE '\\'",
        [&padrao],
    )?;
    con.execute(
        "DELETE FROM arquivo WHERE nome LIKE ?1 ESCAPE '\\'",
        [&padrao],
    )?;
    con.execute(
        "DELETE FROM contador WHERE arquivo LIKE ?1 ESCAPE '\\'",
        [&padrao],
    )?;
    Ok(())
}

/// Move todas as chaves (configs e contadores) de um diretório lógico para outro — usado
/// quando o documento do cliente é editado (a chave muda de nome).
pub fn rename_prefix(antigo: &str, novo: &str) -> Res<()> {
    let (op, np) = (prefixo(antigo), prefixo(novo));
    if op == np {
        return Ok(());
    }
    let mut con = conn()?;
    let tx = con.transaction()?;
    for (tabela, coluna) in [
        ("arquivo", "nome"),
        ("config", "arquivo"),
        ("contador", "arquivo"),
    ] {
        let chaves: Vec<String> = {
            let mut st = tx.prepare(&format!(
                "SELECT DISTINCT {coluna} FROM {tabela} WHERE {coluna} LIKE ?1 ESCAPE '\\'"
            ))?;
            let linhas = st.query_map([like(&format!("{op}%"))], |r| r.get::<_, String>(0))?;
            linhas.collect::<Result<_, _>>()?
        };
        for antiga in chaves {
            tx.execute(
                &format!("UPDATE {tabela} SET {coluna} = ?1 WHERE {coluna} = ?2"),
                params![format!("{np}{}", &antiga[op.len()..]), antiga],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// Chaves gerenciadas sob um diretório lógico, opcionalmente filtradas por sufixo
/// (ex.: sufixo "config_tomador.ini" lista os clientes cadastrados).
pub fn list_keys(caminho: &str, sufixo: &str) -> Res<Vec<String>> {
    let con = conn()?;
    let mut st =
        con.prepare("SELECT nome FROM arquivo WHERE nome LIKE ?1 ESCAPE '\\' ORDER BY nome")?;
    let linhas = st.query_map([like(&format!("{}%", prefixo(caminho)))], |r| {
        r.get::<_, String>(0)
    })?;
    let mut out = Vec::new();
    for l in linhas {
        let k = l?;
        if sufixo.is_empty() || k.ends_with(sufixo) {
            out.push(k);
        }
    }
    Ok(out)
}

/// [(chave lógica, valor)] de UMA opção, para TODOS os .ini sob o prefixo que terminem em
/// `sufixo` — numa única consulta (em ordem de chave).
pub fn read_option_many(
    caminho: &str,
    sufixo: &str,
    secao: &str,
    opcao: &str,
) -> Res<Vec<(String, String)>> {
    let con = conn()?;
    let mut st = con.prepare(
        "SELECT arquivo, valor FROM config WHERE arquivo LIKE ?1 ESCAPE '\\' AND secao = ?2 \
         AND opcao = ?3 ORDER BY arquivo",
    )?;
    let linhas = st.query_map(
        params![like(&format!("{}%", prefixo(caminho))), secao, opcao],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
    )?;
    let mut out = Vec::new();
    for l in linhas {
        let (k, v) = l?;
        if sufixo.is_empty() || k.ends_with(sufixo) {
            out.push((k, v));
        }
    }
    Ok(out)
}

// ------------------------------------------------------------------------------- //
// Contadores de numeração
// ------------------------------------------------------------------------------- //
/// Valor do contador, ou None se ele ainda não existe no banco.
pub fn get_contador(caminho: &str) -> Res<Option<i64>> {
    let con = conn()?;
    let v: Option<String> = con
        .query_row(
            "SELECT valor FROM contador WHERE arquivo = ?1",
            [caminhos::chave_logica(caminho)],
            |r| r.get(0),
        )
        .optional()?;
    Ok(v.map(|s| {
        let s = s.trim();
        if s.is_empty() {
            0
        } else {
            s.parse::<i64>().unwrap_or(0)
        }
    }))
}

pub fn set_contador(caminho: &str, valor: i64) -> Res<()> {
    let con = conn()?;
    con.execute(
        "INSERT OR REPLACE INTO contador (arquivo, valor) VALUES (?1, ?2)",
        params![caminhos::chave_logica(caminho), valor.to_string()],
    )?;
    Ok(())
}

pub fn ensure_contador(caminho: &str, padrao: i64) -> Res<()> {
    if get_contador(caminho)?.is_none() {
        set_contador(caminho, padrao)?;
    }
    Ok(())
}

// ------------------------------------------------------------------------------- //
// Backup / restauração
// ------------------------------------------------------------------------------- //
/// Troca database/dados.db pelo arquivo `novo` de uma vez. Outra conexão aberta neste instante
/// impede a troca no Windows — tenta de novo por alguns segundos antes de desistir.
pub fn substituir_banco(novo: &Path) -> Res<()> {
    let db = caminho_db();
    for tentativa in 0..25 {
        match fs::rename(novo, &db) {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied && tentativa < 24 => {
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

/// Escreve uma cópia cifrada e consistente do dados.db. Arquivos pequenos são copiados sob
/// trava; acima da região de travas do SQLite usa-se um snapshot pela API de backup.
pub(crate) const REGIAO_TRAVA_SQLITE: u64 = 1 << 30;

/// Cópia pela API SQLite: não lê a região de travas do Windows como um arquivo comum.
pub(crate) fn copiar_paginas(origem: &Connection, destino: &mut Connection) -> Res<()> {
    origem.execute_batch("BEGIN")?;
    let resultado = (|| -> Res<()> {
        origem.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
            r.get::<_, i64>(0)
        })?;
        let copia = Backup::new(origem, destino)?;
        match copia.step(-1)? {
            StepResult::Done => Ok(()),
            _ => Err(Erro::runtime(
                "O banco está ocupado e a cópia não foi concluída.",
            )),
        }
    })();
    let _ = origem.execute_batch("ROLLBACK");
    resultado
}

pub(crate) struct ArquivoCopia(pub PathBuf);
impl ArquivoCopia {
    pub(crate) fn novo(prefixo: &str) -> Res<Self> {
        let pasta = std::env::temp_dir().join("BaiacuNFSe").join("copias");
        fs::create_dir_all(&pasta)?;
        let nome = format!(
            "{prefixo}_{}_{}.db",
            std::process::id(),
            hex::encode(crate::chaves::aleatorio(12))
        );
        Ok(Self(pasta.join(nome)))
    }
}
impl Drop for ArquivoCopia {
    fn drop(&mut self) {
        for s in ["", "-journal", "-wal", "-shm"] {
            let mut p = self.0.as_os_str().to_os_string();
            p.push(s);
            let _ = fs::remove_file(PathBuf::from(p));
        }
    }
}

pub fn gravar_copia(saida: &mut dyn Write) -> Res<u64> {
    let con = conn()?;
    con.execute_batch("BEGIN IMMEDIATE")?;
    if fs::metadata(caminho_db())?.len() > REGIAO_TRAVA_SQLITE {
        con.execute_batch("ROLLBACK")?;
        let copia = ArquivoCopia::novo("dados")?;
        let (chave, sal) = chave_atual().ok_or_else(|| Erro::trancado("O banco está trancado."))?;
        {
            let mut destino = abrir(&copia.0, &chave, &sal)?;
            copiar_paginas(&con, &mut destino)?;
        }
        return Ok(std::io::copy(&mut fs::File::open(&copia.0)?, saida)?);
    }
    let resultado = (|| -> Res<u64> {
        let mut f = fs::File::open(caminho_db())?;
        Ok(std::io::copy(&mut f, saida)?)
    })();
    let _ = con.execute_batch("ROLLBACK");
    resultado
}

/// (chave, sal) que abrem uma cópia do dados.db: a desta instalação, se a cópia é dela; senão
/// a que sai da senha mestra informada.
pub fn chave_do_backup(caminho: &Path, senha_mestra: &str) -> Res<(Vec<u8>, Vec<u8>)> {
    let sal = sal_do_arquivo(Some(caminho));
    if let Some((chave, _)) = chave_atual() {
        if chave_abre(caminho, &chave, Some(&sal)) {
            return Ok((chave, sal));
        }
    }
    if !senha_mestra.is_empty() {
        let chave = crate::chaves::chave_da_mestra(senha_mestra, &sal)?;
        if chave_abre(caminho, &chave, Some(&sal)) {
            return Ok((chave, sal));
        }
        return Err(Erro::senha_mestra(
            "Senha mestra incorreta para este backup.",
        ));
    }
    Err(Erro::senha_mestra(
        "Este backup é de outro banco (outra instalação ou anterior à troca da senha \
         mestra). Informe a SENHA MESTRA dele para restaurar.",
    ))
}

/// Confere se o arquivo é uma cópia do dados.db deste programa.
pub fn validar_banco(caminho: &Path, senha_mestra: &str) -> Res<()> {
    if cabecalho(caminho).len() < 16 {
        return Err(Erro::valor("O arquivo está vazio ou não pôde ser lido."));
    }
    let (chave, sal) = chave_do_backup(caminho, senha_mestra)?;
    let con = abrir(caminho, &chave, &sal)?;
    let mut st = con.prepare("SELECT name FROM sqlite_master WHERE type='table'")?;
    let nomes: Vec<String> = st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?;
    if !TABELAS_BACKUP.iter().all(|t| nomes.iter().any(|n| n == t)) {
        return Err(Erro::valor(
            "O arquivo não parece ser um backup do banco deste aplicativo \
             (tabelas esperadas ausentes).",
        ));
    }
    Ok(())
}

/// Troca os DADOS do banco pelos de uma cópia do dados.db (a que vem dentro do .zip de backup).
///
/// O ACESSO continua sendo o desta instalação: a SENHA MESTRA e o usuário MASTER atuais são
/// mantidos — o master que veio no backup é descartado. Os demais usuários passam a ser os do
/// backup, com as senhas deles. `senha_mestra` é a do BACKUP e só é precisa para ABRIR um
/// backup de outro banco. A chave do banco de notas que vale depois é a DESTA instalação.
///
/// O banco novo é montado num arquivo à parte, já cifrado com a chave atual, e trocado de uma
/// vez: falhando antes da troca, nada muda. O processo deve REINICIAR em seguida.
pub fn restaurar_de(origem: &Path, senha_mestra: &str) -> Res<()> {
    let db = caminho_db();
    if caminhos::normalizar(origem) == caminhos::normalizar(&db) {
        return Err(Erro::valor(
            "Este arquivo já é o banco em uso por esta instalação. Escolha um arquivo de backup.",
        ));
    }
    let Some((chave, sal)) = chave_atual() else {
        return Err(Erro::trancado("Só um usuário logado restaura um backup."));
    };
    validar_banco(origem, senha_mestra)?;
    let chave_notas = get_meta(META_CHAVE_NOTAS)?;
    let copia = PathBuf::from(format!("{}.origem", db.display()));
    let novo = PathBuf::from(format!("{}.novo", db.display()));
    let resultado = (|| -> Res<()> {
        fs::copy(origem, &copia)?;
        let (chave_b, sal_b) = chave_do_backup(&copia, senha_mestra)?;
        {
            let fonte = abrir(&copia, &chave_b, &sal_b)?;
            crate::chaves::exportar(&fonte, &novo, &chave, &sal)?;
        }
        {
            let mut con = abrir(&novo, &chave, &sal)?;
            criar_tabelas(&con)?;
            crate::usuarios::levar_master_para(&mut con)?;
            crate::chaves::reembrulhar(&mut con, &chave)?;
            if chave_notas.is_empty() {
                con.execute("DELETE FROM meta WHERE chave = ?1", [META_CHAVE_NOTAS])?;
            } else {
                con.execute(
                    "INSERT OR REPLACE INTO meta (chave, valor) VALUES (?1, ?2)",
                    params![META_CHAVE_NOTAS, chave_notas],
                )?;
            }
        }
        substituir_banco(&novo)
    })();
    for sufixo in ["", "-journal"] {
        let _ = fs::remove_file(format!("{}{}", copia.display(), sufixo));
    }
    let _ = fs::remove_file(&novo);
    resultado?;
    reiniciar_schema();
    crate::chaves::sincronizar()?;
    Ok(())
}
