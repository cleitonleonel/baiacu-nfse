//! Backup e restauração em .zip.
//!
//! O .zip leva o banco de dados (dados.db), o banco de notas (notas.db) ou os dois, do jeito que
//! estão em disco — isto é, JÁ cifrados. Por isso é gravado SEM compressão: arquivo cifrado não
//! encolhe. Fazer o backup custa o mesmo que copiar os arquivos; depois de gravado, o .zip é
//! relido e conferido (CRC) antes de valer.
//!
//! - dados.db abre com a SENHA MESTRA de quando o backup foi feito.
//! - notas.db tem chave própria, que mora dentro do dados.db. Para o backup das notas servir
//!   SOZINHO, essa chave vai junto no .zip, embrulhada (AES-256-GCM) com a chave do dados.db:
//!   quem tem a senha mestra abre; quem não tem, não.
//!
//! Restaurar confere tudo ANTES de trocar qualquer arquivo. As notas restauradas são recifradas
//! com a chave desta instalação e os dados entram por `banco::restaurar_de`, que mantém o
//! usuário MASTER e a senha mestra atuais.
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{Aead, KeyInit, Payload};
use serde_json::{Map, Value, json};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::erro::{Erro, Res};
use crate::{banco, caminhos, chaves, cofre, jsonpy, registro};

pub const DADOS: &str = "dados";
pub const NOTAS: &str = "notas";
const PARTES: [&str; 2] = [DADOS, NOTAS];
const MANIFESTO: &str = "backup.json";
/// Identificador gravado no manifesto do backup. Fica o nome antigo do programa de propósito:
/// é por ele que os backups já feitos continuam aceitos.
const APP: &str = "Emissor NFSe";
static TRAVA_BACKUP: Mutex<()> = Mutex::new(());

/// Impede duas gravações simultâneas, inclusive chamadas de API concorrentes.
pub fn em_andamento() -> bool {
    TRAVA_BACKUP.try_lock().is_err()
}

struct CopiaAcompanhada<'a, W> {
    destino: &'a mut W,
    feito: &'a mut u64,
    total: u64,
    inicio: u64,
    faixa: u64,
    ultimo: &'a mut u64,
    etapa: &'a str,
    avisar: &'a dyn Fn(&Value),
}

impl<W: Write> Write for CopiaAcompanhada<'_, W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let n = self.destino.write(bytes)?;
        *self.feito += n as u64;
        let percentual =
            (self.inicio + (*self.feito).min(self.total) * self.faixa / self.total.max(1)).min(99);
        if percentual != *self.ultimo {
            *self.ultimo = percentual;
            (self.avisar)(&json!({"percentual": percentual, "etapa": self.etapa}));
            registro::info("backup", &format!("{} — {percentual}%", self.etapa));
        }
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.destino.flush()
    }
}
const FORMATO: i64 = 1;
const AAD: &[u8] = b"nfse-backup-chave-notas-v1";

/// Falha com mensagem pronta para o usuário.
fn erro(msg: impl Into<String>) -> Erro {
    Erro::novo("BackupErro", msg)
}

fn arquivo_de(parte: &str) -> &'static str {
    if parte == DADOS {
        "dados.db"
    } else {
        "notas.db"
    }
}

fn partes_pedidas(partes: &[String]) -> Res<Vec<&'static str>> {
    if partes.is_empty() || !partes.iter().all(|p| PARTES.contains(&p.as_str())) {
        return Err(erro(
            "Escolha o que entra no backup: os dados, as notas ou os dois.",
        ));
    }
    Ok(PARTES
        .into_iter()
        .filter(|p| partes.iter().any(|x| x == p))
        .collect())
}

pub fn nome_sugerido(partes: &[String]) -> Res<String> {
    Ok(format!(
        "backup_{}_{}.zip",
        partes_pedidas(partes)?.join("_"),
        chrono::Local::now().format("%Y%m%d_%H%M")
    ))
}

/// Tamanho atual de cada banco, em bytes (0 = ainda não existe). Para a tela.
pub fn tamanhos() -> Value {
    let de = |p: PathBuf| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
    json!({ DADOS: de(banco::caminho_db()), NOTAS: de(cofre::caminho_db()) })
}

fn embrulhar_chave_notas(chave: &[u8], sal: &[u8]) -> Res<Value> {
    let hexa = banco::get_meta(banco::META_CHAVE_NOTAS)?;
    if hexa.is_empty() {
        return Err(erro(
            "A chave do banco de notas não está no banco de dados.",
        ));
    }
    let claro = hex::decode(&hexa)
        .map_err(|_| erro("A chave do banco de notas não está no banco de dados."))?;
    let nonce = chaves::aleatorio(12);
    let cifra = Aes256Gcm::new_from_slice(chave)
        .map_err(|_| erro("chave do banco inválida"))?
        .encrypt(
            nonce.as_slice().try_into().map_err(|_| erro("nonce"))?,
            Payload {
                msg: &claro,
                aad: AAD,
            },
        )
        .map_err(|_| erro("falha ao embrulhar a chave do banco de notas"))?;
    Ok(json!({ "sal": hex::encode(sal), "nonce": hex::encode(nonce), "cifra": hex::encode(cifra) }))
}

fn abrir_com(chave: &[u8], nonce: &[u8], cifra: &[u8]) -> Option<Vec<u8>> {
    Aes256Gcm::new_from_slice(chave)
        .ok()?
        .decrypt(
            nonce.try_into().ok()?,
            Payload {
                msg: cifra,
                aad: AAD,
            },
        )
        .ok()
}

/// A chave do notas.db que veio no backup. Abre com a chave do banco em uso (backup desta
/// instalação) ou com a senha mestra DO BACKUP.
fn abrir_chave_notas(manifesto: &Value, senha_mestra: &str) -> Res<Vec<u8>> {
    let parte = |nome: &str| {
        manifesto
            .get("chave_notas")
            .and_then(|c| c.get(nome))
            .and_then(Value::as_str)
            .and_then(|h| hex::decode(h).ok())
    };
    let (Some(sal), Some(nonce), Some(cifra)) = (parte("sal"), parte("nonce"), parte("cifra"))
    else {
        return Err(erro("O backup não traz a chave do banco de notas."));
    };
    if let Some((atual, _)) = banco::chave_atual() {
        if let Some(chave) = abrir_com(&atual, &nonce, &cifra) {
            return Ok(chave);
        }
    }
    if !senha_mestra.is_empty() {
        return abrir_com(
            &chaves::chave_da_mestra(senha_mestra, &sal)?,
            &nonce,
            &cifra,
        )
        .ok_or_else(|| Erro::senha_mestra("Senha mestra incorreta para este backup."));
    }
    Err(Erro::senha_mestra(
        "Este backup é de outro banco (outra instalação ou anterior à troca da senha mestra). Informe a SENHA MESTRA dele \
         para restaurar.",
    ))
}

fn zip_erro(e: zip::result::ZipError) -> Erro {
    match e {
        zip::result::ZipError::Io(io) => io.into(),
        outro => Erro::novo("BadZipFile", outro.to_string()),
    }
}

fn agora_zip() -> zip::DateTime {
    use chrono::{Datelike, Timelike};
    let n = chrono::Local::now();
    zip::DateTime::from_date_and_time(
        n.year() as u16,
        n.month() as u8,
        n.day() as u8,
        n.hour() as u8,
        n.minute() as u8,
        n.second() as u8,
    )
    .unwrap_or_default()
}

/// Grava o backup em `destino` (.zip). Devolve {'arquivo', 'partes', 'bytes', 'segundos',
/// 'sem_notas'} — `sem_notas` avisa que as notas foram pedidas junto com os dados mas o banco de
/// notas ainda não existe (o backup saiu só com os dados).
pub fn fazer(destino: &str, partes: &[String]) -> Res<Value> {
    fazer_acompanhando(destino, partes, &|_| {})
}

/// Grava, confere e publica o backup, avisando o progresso real de cópia e verificação.
pub fn fazer_acompanhando(destino: &str, partes: &[String], avisar: &dyn Fn(&Value)) -> Res<Value> {
    let _trava = TRAVA_BACKUP
        .try_lock()
        .map_err(|_| erro("Já existe um backup em andamento."))?;
    let mut partes = partes_pedidas(partes)?;
    let Some((chave, sal)) = banco::chave_atual() else {
        return Err(Erro::trancado("Só um usuário logado faz backup."));
    };
    let sem_notas = partes.contains(&NOTAS) && !cofre::existe();
    if sem_notas {
        if partes == [NOTAS] {
            return Err(erro(
                "O banco de notas ainda não existe: não há notas para guardar.",
            ));
        }
        partes = vec![DADOS];
    }
    let dest = caminhos::normalizar(Path::new(destino));
    if dest.parent() == caminhos::normalizar(&banco::caminho_db()).parent() {
        return Err(erro(
            "Escolha outra pasta: o backup não deve ficar junto dos bancos que ele guarda.",
        ));
    }
    if let Some(pai) = dest.parent() {
        caminhos::arquivo_usuario(|| std::fs::create_dir_all(pai))?;
    }
    let tmp = {
        let mut s = dest.as_os_str().to_os_string();
        s.push(".tmp");
        PathBuf::from(s)
    };
    let t0 = std::time::Instant::now();
    avisar(&json!({"percentual": 0, "etapa": "Preparando backup"}));
    let total: u64 = partes
        .iter()
        .map(|p| {
            let arquivo = if *p == DADOS {
                banco::caminho_db()
            } else {
                caminhos::raiz().join("database/notas.db")
            };
            std::fs::metadata(arquivo).map(|m| m.len()).unwrap_or(0)
        })
        .sum();
    let gravar = || -> Res<()> {
        let mut manifesto = Map::new();
        manifesto.insert("app".into(), json!(APP));
        manifesto.insert("formato".into(), json!(FORMATO));
        manifesto.insert("partes".into(), json!(partes));
        let mut tamanhos = Map::new();
        let opcoes = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .large_file(true)
            .last_modified_time(agora_zip());
        let mut zf = ZipWriter::new(caminhos::arquivo_usuario(|| std::fs::File::create(&tmp))?);
        let mut feito = 0;
        let mut ultimo = 0;
        for parte in &partes {
            zf.start_file(arquivo_de(parte), opcoes).map_err(zip_erro)?;
            let mut acompanhado = CopiaAcompanhada {
                destino: &mut zf,
                feito: &mut feito,
                total,
                inicio: 0,
                faixa: 80,
                ultimo: &mut ultimo,
                etapa: "Gravando backup",
                avisar,
            };
            let n = if *parte == DADOS {
                banco::gravar_copia(&mut acompanhado)?
            } else {
                cofre::gravar_copia(&mut acompanhado)?
            };
            tamanhos.insert((*parte).to_string(), json!(n));
        }
        manifesto.insert("tamanhos".into(), Value::Object(tamanhos));
        manifesto.insert(
            "feito_em".into(),
            json!(chrono::Local::now().format("%Y-%m-%dT%H:%M:%S").to_string()),
        );
        if partes.contains(&NOTAS) {
            manifesto.insert("chave_notas".into(), embrulhar_chave_notas(&chave, &sal)?);
        }
        zf.start_file(
            MANIFESTO,
            SimpleFileOptions::default()
                .compression_method(CompressionMethod::Stored)
                .last_modified_time(agora_zip()),
        )
        .map_err(zip_erro)?;
        let texto = jsonpy::dumps(
            &Value::Object(manifesto),
            jsonpy::Formato {
                ordenar: false,
                recuo: Some(1),
                compacto: false,
                so_ascii: false,
            },
        );
        zf.write_all(texto.as_bytes())?;
        zf.finish().map_err(zip_erro)?.sync_all()?;
        // relê e confere (CRC) antes de valer
        let mut lido = ZipArchive::new(caminhos::arquivo_usuario(|| std::fs::File::open(&tmp))?).map_err(zip_erro)?;
        let total_verificacao = (0..lido.len())
            .filter_map(|i| lido.by_index(i).ok().map(|e| e.size()))
            .sum();
        let mut conferido = 0;
        let mut ultimo = 80;
        avisar(&json!({"percentual": 80, "etapa": "Conferindo backup"}));
        for i in 0..lido.len() {
            let mut item = lido.by_index(i).map_err(zip_erro)?;
            let nome = item.name().map(|n| n.to_string()).unwrap_or_default();
            let mut sink = std::io::sink();
            let mut acompanhado = CopiaAcompanhada {
                destino: &mut sink,
                feito: &mut conferido,
                total: total_verificacao,
                inicio: 80,
                faixa: 19,
                ultimo: &mut ultimo,
                etapa: "Conferindo backup",
                avisar,
            };
            if std::io::copy(&mut item, &mut acompanhado).is_err() {
                return Err(erro(format!(
                    "O backup não conferiu depois de gravado ({nome}) e foi descartado."
                )));
            }
        }
        drop(lido);
        caminhos::arquivo_usuario(|| std::fs::rename(&tmp, &dest))?;
        Ok(())
    };
    let r = gravar();
    let _ = caminhos::arquivo_usuario(|| std::fs::remove_file(&tmp));
    r?;
    avisar(&json!({"percentual": 100, "etapa": "Backup concluído"}));
    let bytes = caminhos::arquivo_usuario(|| std::fs::metadata(&dest))?.len();
    let segundos = t0.elapsed().as_secs_f64();
    registro::info(
        "backup",
        &format!(
            "Backup ({}) gravado em {}: {} em {segundos:.2} s.",
            partes.join("+"),
            dest.display(),
            crate::texto::tamanho_arquivo(bytes)
        ),
    );
    Ok(
        json!({ "arquivo": dest.to_string_lossy(), "partes": partes, "bytes": bytes, "segundos": segundos, "sem_notas": sem_notas }),
    )
}

type Zip = ZipArchive<std::fs::File>;

fn nao_e_backup() -> Erro {
    erro("O arquivo não é um backup deste programa.")
}

fn abrir_zip(origem: &str) -> Res<Zip> {
    let danificado = |e: String| {
        erro(format!(
            "O arquivo não é um backup deste programa ou está danificado ({e})."
        ))
    };
    let f = caminhos::arquivo_usuario(|| std::fs::File::open(origem)).map_err(|e| danificado(e.to_string()))?;
    ZipArchive::new(f).map_err(|e| danificado(e.to_string()))
}

fn manifesto_de(zf: &mut Zip) -> Res<Value> {
    let mut texto = String::new();
    zf.by_name(MANIFESTO)
        .map_err(|_| nao_e_backup())?
        .read_to_string(&mut texto)
        .map_err(|_| nao_e_backup())?;
    let m: Value = serde_json::from_str(&texto).map_err(|_| nao_e_backup())?;
    let partes: Vec<&str> = m
        .get("partes")
        .and_then(Value::as_array)
        .map(|l| l.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let lista_inteira = m
        .get("partes")
        .and_then(Value::as_array)
        .is_some_and(|l| l.len() == partes.len());
    if !m.is_object()
        || m.get("app").and_then(Value::as_str) != Some(APP)
        || partes.is_empty()
        || !lista_inteira
        || !partes.iter().all(|p| PARTES.contains(p))
    {
        return Err(nao_e_backup());
    }
    if m.get("formato").and_then(Value::as_i64).unwrap_or(0) != FORMATO {
        return Err(erro(
            "Este backup foi feito por outra versão do programa e não pode ser lido por esta.",
        ));
    }
    let nomes: Vec<String> = zf
        .file_names()
        .filter_map(|n| n.ok().map(|c| c.to_string()))
        .collect();
    if partes
        .iter()
        .any(|p| !nomes.iter().any(|n| n == arquivo_de(p)))
    {
        return Err(erro(
            "O backup está incompleto: falta um dos bancos que ele diz conter.",
        ));
    }
    Ok(m)
}

fn partes_do(manifesto: &Value) -> Vec<&'static str> {
    let l: Vec<&str> = manifesto
        .get("partes")
        .and_then(Value::as_array)
        .map(|l| l.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    PARTES.into_iter().filter(|p| l.contains(p)).collect()
}

fn extrair(zf: &mut Zip, parte: &str, destino: &Path) -> Res<()> {
    let danificado = |e: String| {
        erro(format!(
            "O arquivo não é um backup deste programa ou está danificado ({e})."
        ))
    };
    let mut origem = zf
        .by_name(arquivo_de(parte))
        .map_err(|e| danificado(e.to_string()))?;
    let mut saida = std::fs::File::create(destino).map_err(|e| danificado(e.to_string()))?;
    std::io::copy(&mut origem, &mut saida).map_err(|e| danificado(e.to_string()))?; // o CRC é conferido ao chegar ao fim
    Ok(())
}

fn limpar(arquivo: &Path) {
    for sufixo in ["", "-journal"] {
        let mut s = arquivo.as_os_str().to_os_string();
        s.push(sufixo);
        let p = PathBuf::from(s);
        if p.exists() && std::fs::remove_file(&p).is_err() {
            registro::erro(
                "backup",
                &format!("Não foi possível apagar {}", p.display()),
            );
        }
    }
}

fn temporario(parte: &str) -> PathBuf {
    banco::caminho_db().with_file_name(format!("{}.restaurando", arquivo_de(parte)))
}

/// O que há no backup: {'partes', 'feito_em', 'tamanhos'}. Erro se o arquivo não serve, e de
/// senha mestra se ele é de outro banco (a senha mestra DELE tem de ser informada). Não muda nada
/// nesta instalação.
pub fn examinar(origem: &str, senha_mestra: &str) -> Res<Value> {
    let _trava = TRAVA_BACKUP
        .try_lock()
        .map_err(|_| erro("Já existe um backup ou uma restauração em andamento."))?;
    if banco::chave_atual().is_none() {
        return Err(Erro::trancado("Só um usuário logado restaura um backup."));
    }
    let mut zf = abrir_zip(origem)?;
    let m = manifesto_de(&mut zf)?;
    let partes = partes_do(&m);
    if partes.contains(&DADOS) {
        let tmp = temporario(DADOS);
        let r =
            extrair(&mut zf, DADOS, &tmp).and_then(|()| banco::validar_banco(&tmp, senha_mestra));
        limpar(&tmp);
        r?;
    }
    if partes.contains(&NOTAS) {
        abrir_chave_notas(&m, senha_mestra)?;
    }
    let feito_em = match m.get("feito_em") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(outro) => outro.to_string(),
    };
    Ok(
        json!({ "partes": partes, "feito_em": feito_em, "tamanhos": m.get("tamanhos").filter(|t| t.is_object()).cloned().unwrap_or(json!({})) }),
    )
}

/// Restaura do .zip as `partes` pedidas (as que ele tiver). Confere TUDO antes de trocar qualquer
/// arquivo; troca primeiro as notas, depois os dados. Devolve o que restaurou. Restaurando os
/// dados, o processo deve REINICIAR em seguida (quem chama cuida disso).
pub fn restaurar(origem: &str, partes: &[String], senha_mestra: &str) -> Res<Vec<String>> {
    let _trava = TRAVA_BACKUP
        .try_lock()
        .map_err(|_| erro("Já existe um backup ou uma restauração em andamento."))?;
    let pedidas = partes_pedidas(partes)?;
    let mut extraidos: Vec<(&str, PathBuf)> = Vec::new();
    let feito = (|| -> Res<()> {
        let mut zf = abrir_zip(origem)?;
        let m = manifesto_de(&mut zf)?;
        let do_backup = partes_do(&m);
        let fazer: Vec<&str> = pedidas
            .iter()
            .copied()
            .filter(|p| do_backup.contains(p))
            .collect();
        if fazer.is_empty() {
            return Err(erro(
                "Este backup não contém o que foi pedido para restaurar.",
            ));
        }
        for parte in fazer {
            let destino = temporario(parte);
            extraidos.push((parte, destino.clone()));
            extrair(&mut zf, parte, &destino)?;
        }
        drop(zf);
        let de = |parte: &str| {
            extraidos
                .iter()
                .find(|(p, _)| *p == parte)
                .map(|(_, c)| c.clone())
        };
        let mut chave_notas = Vec::new();
        if let Some(d) = de(DADOS) {
            banco::validar_banco(&d, senha_mestra)?;
        }
        if let Some(n) = de(NOTAS) {
            chave_notas = abrir_chave_notas(&m, senha_mestra)?;
            cofre::conferir_arquivo(&n, &chave_notas)?;
        }
        if let Some(n) = de(NOTAS) {
            cofre::substituir_por(&n, &chave_notas)?;
        }
        if let Some(d) = de(DADOS) {
            banco::restaurar_de(&d, senha_mestra)?;
        }
        Ok(())
    })();
    for (_, arquivo) in &extraidos {
        limpar(arquivo);
    }
    feito?;
    let nomes: Vec<String> = extraidos.iter().map(|(p, _)| (*p).to_string()).collect();
    registro::aviso(
        "backup",
        &format!("Backup restaurado de {origem}: {}.", nomes.join("+")),
    );
    Ok(nomes)
}
