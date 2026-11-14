//! Atualização do programa pelo GitHub.
//!
//! COMO A VERSÃO NOVA É PUBLICADA (ver `compilar_exe.py --zip`): uma *release* no repositório,
//! com a etiqueta `v<versão>` (ex.: `v0.9.1`) e dois arquivos anexados:
//! - `Baiacu-NFS-e-<versão>-windows.zip`, com a pasta `Baiacu NFS-e/` inteira dentro;
//! - o mesmo nome + `.sha256`, com a impressão digital (SHA-256) do zip.
//!
//! O QUE O PROGRAMA FAZ
//! 1. `verificar`: pergunta à API do GitHub qual é a última release e compara com [`VERSAO`].
//! 2. `baixar`: baixa o zip para `atualizacao/` (ao lado do .exe), confere o SHA-256 publicado
//!    e extrai numa pasta à parte. Nada do programa em uso é tocado nesta etapa.
//! 3. `instalar`: grava um pequeno script que espera ESTE processo fechar, copia a pasta nova
//!    por cima da atual (sem nunca tocar em `database/` nem em `logs/`) e abre o programa de
//!    novo. A tela fecha o programa logo depois.
//!
//! Só funciona no programa empacotado (o `.exe` de [`NOME_EXE`] na raiz). Em desenvolvimento a
//! verificação responde, mas a instalação é recusada.
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::caminhos;
use crate::despacho::Avisar;
use crate::erro::{Erro, Res};
use crate::rede::{Sessao, Tempo};

/// Versão deste programa. `compilar_exe.py` confere que é a mesma do `pubspec.yaml`.
pub const VERSAO: &str = "1.0.0";
/// Repositório onde saem as versões novas (dono/nome).
pub const REPOSITORIO: &str = "williamlala/baiacu-nfse";
/// Nome do executável do programa empacotado.
pub const NOME_EXE: &str = "Baiacu NFS-e.exe";
/// Pasta (sob a raiz) onde a versão nova é baixada e preparada.
const PASTA: &str = "atualizacao";
/// Pastas do programa instalado que a atualização nunca toca.
const PRESERVADAS: [&str; 3] = ["database", "logs", PASTA];
const CHAVE_META: &str = "atualizacao";
const IDENTIFICACAO: &str = "Baiacu-NFS-e (atualizacao)";
/// Verificação automática: no máximo uma por este intervalo.
const INTERVALO_HORAS: i64 = 20;

fn erro(msg: impl Into<String>) -> Erro {
    Erro::valor(msg.into())
}

// --------------------------------------------------------------------------------------------- //
// Versões
// --------------------------------------------------------------------------------------------- //
/// "v0.9.1" / "0.9.1" -> [0, 9, 1]. Partes que não são número valem 0.
pub fn partes(versao: &str) -> Vec<u64> {
    versao
        .trim()
        .trim_start_matches(['v', 'V'])
        .split(['.', '-', '+'])
        .take(3)
        .map(|p| p.parse().unwrap_or(0))
        .collect()
}

/// `nova` é mais recente que `atual`?
pub fn mais_nova(nova: &str, atual: &str) -> bool {
    let (mut a, mut b) = (partes(nova), partes(atual));
    a.resize(3, 0);
    b.resize(3, 0);
    a > b
}

// --------------------------------------------------------------------------------------------- //
// Estado (lembrado no banco)
// --------------------------------------------------------------------------------------------- //
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Estado {
    /// Procurar versão nova sozinho (ao entrar no programa).
    pub automatica: bool,
    /// Última verificação (RFC 3339).
    pub ultima: String,
    /// Versão que o usuário mandou pular.
    pub pular: String,
}

fn ler() -> Estado {
    let t = crate::banco::get_meta(CHAVE_META).unwrap_or_default();
    if t.trim().is_empty() {
        return Estado {
            automatica: true,
            ..Estado::default()
        };
    }
    serde_json::from_str(&t).unwrap_or(Estado {
        automatica: true,
        ..Estado::default()
    })
}

fn gravar(e: &Estado) -> Res<()> {
    crate::banco::set_meta(CHAVE_META, &serde_json::to_string(e)?)
}

pub fn estado() -> Res<Value> {
    let e = ler();
    Ok(json!({
        "versao": VERSAO,
        "automatica": e.automatica,
        "ultima": e.ultima,
        "pular": e.pular,
        "instalavel": instalado().is_some(),
        "pagina_projeto": format!("https://github.com/{REPOSITORIO}"),
    }))
}

pub fn configurar(automatica: Option<bool>, pular: Option<&str>) -> Res<Value> {
    let mut e = ler();
    if let Some(v) = automatica {
        e.automatica = v;
    }
    if let Some(p) = pular {
        e.pular = p.trim().to_string();
    }
    gravar(&e)?;
    estado()
}

// --------------------------------------------------------------------------------------------- //
// Verificar
// --------------------------------------------------------------------------------------------- //
fn sessao(segundos: f64) -> Res<Sessao> {
    Sessao::nova(
        None,
        Tempo {
            conectar: 8.0,
            ler: segundos,
        },
        IDENTIFICACAO,
        false,
    )
}

/// Os dados da última release publicada.
#[derive(Debug, Clone, PartialEq)]
pub struct Release {
    pub versao: String,
    pub notas: String,
    pub pagina: String,
    pub zip_nome: String,
    pub zip_url: String,
    pub zip_tamanho: u64,
    pub sha_url: String,
}

/// Lê a resposta da API (`/releases/latest`).
pub fn release_de(v: &Value) -> Res<Release> {
    let versao = v["tag_name"].as_str().unwrap_or("").trim().to_string();
    if versao.is_empty() {
        return Err(erro("O GitHub não informou a versão da última publicação."));
    }
    let anexos = v["assets"].as_array().cloned().unwrap_or_default();
    let nome_de = |a: &Value| a["name"].as_str().unwrap_or("").to_string();
    let zip = anexos
        .iter()
        .find(|a| nome_de(a).to_ascii_lowercase().ends_with(".zip"))
        .ok_or_else(|| erro(format!("A versão {versao} foi publicada sem o arquivo .zip.")))?;
    let zip_nome = nome_de(zip);
    let sha = anexos
        .iter()
        .find(|a| nome_de(a).eq_ignore_ascii_case(&format!("{zip_nome}.sha256")))
        .ok_or_else(|| {
            erro(format!(
                "A versão {versao} foi publicada sem a impressão digital ({zip_nome}.sha256). \
                 Por segurança, ela não é instalada automaticamente."
            ))
        })?;
    Ok(Release {
        versao: versao.trim_start_matches(['v', 'V']).to_string(),
        notas: v["body"].as_str().unwrap_or("").trim().to_string(),
        pagina: v["html_url"].as_str().unwrap_or("").to_string(),
        zip_url: zip["browser_download_url"].as_str().unwrap_or("").to_string(),
        zip_tamanho: zip["size"].as_u64().unwrap_or(0),
        zip_nome,
        sha_url: sha["browser_download_url"].as_str().unwrap_or("").to_string(),
    })
}

/// Aviso (não é erro) quando o projeto ainda não publicou nenhuma versão.
pub const SEM_PUBLICACAO: &str = "Ainda não há nenhuma versão publicada para download.";

fn ultima_release() -> Res<Release> {
    ultima_publicada()?.ok_or_else(|| erro(SEM_PUBLICACAO))
}

/// A última release, ou `None` se ainda não há nenhuma publicada.
fn ultima_publicada() -> Res<Option<Release>> {
    let url = format!("https://api.github.com/repos/{REPOSITORIO}/releases/latest");
    let r = sessao(20.0)?.get(
        &url,
        &[
            ("Accept", "application/vnd.github+json"),
            ("X-GitHub-Api-Version", "2022-11-28"),
        ],
    )?;
    match r.status {
        200 => {}
        404 => return Ok(None),
        403 | 429 => {
            return Err(erro(
                "O GitHub limitou as consultas por agora. Tente de novo daqui a uma hora.",
            ));
        }
        s => {
            return Err(erro(format!(
                "O GitHub respondeu {s} ao procurar a versão nova."
            )));
        }
    }
    release_de(&r.json().ok_or_else(|| erro("Resposta do GitHub ilegível."))?).map(Some)
}

/// Procura versão nova. `automatica`: chamada sozinha ao entrar — respeita o intervalo, o
/// "procurar sozinho" desligado e a versão pulada (devolve `{"disponivel": false}` sem ir à
/// internet quando não é hora).
pub fn verificar(automatica: bool) -> Res<Value> {
    let mut e = ler();
    let agora = chrono::Utc::now();
    if automatica {
        let recente = chrono::DateTime::parse_from_rfc3339(&e.ultima)
            .map(|d| agora.signed_duration_since(d) < chrono::Duration::hours(INTERVALO_HORAS))
            .unwrap_or(false);
        if !e.automatica || recente {
            return Ok(json!({ "disponivel": false, "versao_atual": VERSAO, "consultou": false }));
        }
    }
    let resultado = ultima_publicada();
    e.ultima = agora.to_rfc3339();
    let _ = gravar(&e);
    let Some(r) = resultado? else {
        return Ok(json!({
            "disponivel": false,
            "consultou": true,
            "versao_atual": VERSAO,
            "aviso": SEM_PUBLICACAO,
        }));
    };
    let nova = mais_nova(&r.versao, VERSAO);
    let pulada = automatica && !e.pular.is_empty() && e.pular == r.versao;
    Ok(json!({
        "disponivel": nova && !pulada,
        "consultou": true,
        "versao_atual": VERSAO,
        "versao": r.versao,
        "notas": r.notas,
        "pagina": r.pagina,
        "tamanho": r.zip_tamanho,
        "instalavel": instalado().is_some(),
    }))
}

// --------------------------------------------------------------------------------------------- //
// Baixar e preparar
// --------------------------------------------------------------------------------------------- //
/// A pasta do programa instalado (a do .exe), se este processo é o programa empacotado.
pub fn instalado() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let pasta = exe.parent()?.to_path_buf();
    let nome = exe.file_name()?.to_string_lossy().to_string();
    (nome.eq_ignore_ascii_case(NOME_EXE)
        && caminhos::normalizar(&pasta) == caminhos::normalizar(&caminhos::raiz()))
    .then_some(pasta)
}

fn pasta_trabalho() -> PathBuf {
    caminhos::raiz().join(PASTA)
}

/// SHA-256 (hex minúsculo) de um arquivo.
pub fn sha256_arquivo(caminho: &Path) -> Res<String> {
    let mut f = fs::File::open(caminho)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex::encode(h.finalize()))
}

/// O hash de um arquivo `.sha256` ("<hex>  nome" ou só "<hex>").
pub fn hash_publicado(texto: &str) -> Option<String> {
    let h = texto.split_whitespace().next()?.trim().to_ascii_lowercase();
    (h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit())).then_some(h)
}

/// Extrai o zip em `destino`, recusando caminhos que saiam dela.
pub fn extrair(zip: &Path, destino: &Path) -> Res<()> {
    let mut arq = zip::ZipArchive::new(fs::File::open(zip)?)
        .map_err(|e| erro(format!("O arquivo baixado não é um zip válido: {e}")))?;
    for i in 0..arq.len() {
        let mut item = arq
            .by_index(i)
            .map_err(|e| erro(format!("Zip danificado: {e}")))?;
        let Some(relativo) = item.enclosed_name() else {
            return Err(erro("O zip da atualização tem um caminho inválido."));
        };
        let alvo = destino.join(relativo);
        if item.is_dir() {
            fs::create_dir_all(&alvo)?;
            continue;
        }
        if let Some(pai) = alvo.parent() {
            fs::create_dir_all(pai)?;
        }
        let mut saida = fs::File::create(&alvo)?;
        std::io::copy(&mut item, &mut saida)?;
    }
    Ok(())
}

/// A pasta, dentro da extração, que tem o executável (a raiz do zip ou uma subpasta).
pub fn pasta_do_programa(extraido: &Path) -> Option<PathBuf> {
    if extraido.join(NOME_EXE).is_file() {
        return Some(extraido.to_path_buf());
    }
    fs::read_dir(extraido)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .find(|p| p.is_dir() && p.join(NOME_EXE).is_file())
}

/// Baixa e prepara a última versão (sem instalar). Devolve a versão preparada.
pub fn baixar(avisar: Avisar) -> Res<Value> {
    let r = ultima_release()?;
    if !mais_nova(&r.versao, VERSAO) {
        return Err(erro(format!(
            "Você já está na versão mais recente ({VERSAO})."
        )));
    }
    let pasta = pasta_trabalho();
    let _ = fs::remove_dir_all(&pasta);
    fs::create_dir_all(&pasta)?;
    avisar(&json!({"percentual": 0, "etapa": format!("Baixando a versão {}", r.versao)}));

    let sha = sessao(30.0)?.get(&r.sha_url, &[])?;
    if sha.status != 200 {
        return Err(erro("Não foi possível baixar a impressão digital da versão nova."));
    }
    let esperado = hash_publicado(&sha.texto())
        .ok_or_else(|| erro("A impressão digital publicada está em formato inválido."))?;

    let zip = pasta.join(&r.zip_nome);
    let total = r.zip_tamanho;
    let mut ultimo = -1i64;
    sessao(120.0)?.baixar(&r.zip_url, &zip, &mut |lidos| {
        if total > 0 {
            let p = (lidos.saturating_mul(90) / total) as i64;
            if p != ultimo {
                ultimo = p;
                avisar(&json!({
                    "percentual": p,
                    "etapa": format!("Baixando a versão {} ({} de {} MB)", r.versao, lidos / 1_048_576, total / 1_048_576),
                }));
            }
        }
    })?;

    avisar(&json!({"percentual": 92, "etapa": "Conferindo o arquivo baixado"}));
    let obtido = sha256_arquivo(&zip)?;
    if obtido != esperado {
        let _ = fs::remove_file(&zip);
        return Err(erro(
            "O arquivo baixado não confere com a impressão digital publicada (pode ter vindo \
             corrompido). Nada foi alterado; tente de novo.",
        ));
    }

    avisar(&json!({"percentual": 95, "etapa": "Preparando a instalação"}));
    let extraido = pasta.join("novo");
    extrair(&zip, &extraido)?;
    let programa = pasta_do_programa(&extraido)
        .ok_or_else(|| erro(format!("O pacote da versão {} não tem o {NOME_EXE}.", r.versao)))?;
    for essencial in ["data/app.so", "data/dll/nucleo.dll"] {
        if !programa.join(essencial).is_file() {
            return Err(erro(format!(
                "O pacote da versão {} está incompleto (falta {essencial}).",
                r.versao
            )));
        }
    }
    fs::write(pasta.join("versao.txt"), &r.versao)?;
    avisar(&json!({"percentual": 100, "etapa": "Pronto para instalar"}));
    Ok(json!({ "versao": r.versao, "pasta": programa.to_string_lossy() }))
}

// --------------------------------------------------------------------------------------------- //
// Instalar
// --------------------------------------------------------------------------------------------- //
/// O script que espera o programa fechar, copia a versão nova e reabre.
pub fn script(pid: u32, novo: &Path, programa: &Path, trabalho: &Path) -> String {
    let novo = novo.display();
    let programa_s = programa.display();
    let exclusoes = PRESERVADAS.join(" ");
    let log = programa.join("logs").join("atualizacao.log");
    let log = log.display();
    format!(
        "@echo off\r\n\
         chcp 65001 >nul\r\n\
         rem Atualização do {NOME_EXE}: espera o programa fechar, copia e reabre.\r\n\
         set /a tentativas=0\r\n\
         :esperar\r\n\
         tasklist /FI \"PID eq {pid}\" /NH 2>nul | find \"{pid}\" >nul\r\n\
         if not errorlevel 1 (\r\n\
         \x20 set /a tentativas+=1\r\n\
         \x20 if %tentativas% GEQ 120 goto falhou\r\n\
         \x20 timeout /t 1 /nobreak >nul\r\n\
         \x20 goto esperar\r\n\
         )\r\n\
         robocopy \"{novo}\" \"{programa_s}\" /E /XD {exclusoes} /R:10 /W:1 /NFL /NDL /NJH /NJS /NP >> \"{log}\" 2>&1\r\n\
         if errorlevel 8 goto falhou\r\n\
         echo %date% %time% atualizacao instalada >> \"{log}\"\r\n\
         set NFSE_REABRIR=1\r\n\
         start \"\" \"{programa_s}\\{NOME_EXE}\"\r\n\
         rmdir /s /q \"{trabalho}\"\r\n\
         exit /b 0\r\n\
         :falhou\r\n\
         echo %date% %time% atualizacao FALHOU >> \"{log}\"\r\n\
         start \"\" \"{programa_s}\\{NOME_EXE}\"\r\n\
         exit /b 1\r\n",
        trabalho = trabalho.display(),
    )
}

/// Agenda a instalação da versão já baixada: o script começa a esperar este processo fechar.
/// A tela fecha o programa em seguida.
pub fn instalar() -> Res<Value> {
    let programa = instalado().ok_or_else(|| {
        erro("A atualização automática só funciona no programa instalado (não em desenvolvimento).")
    })?;
    let trabalho = pasta_trabalho();
    let novo = pasta_do_programa(&trabalho.join("novo"))
        .ok_or_else(|| erro("Nenhuma versão baixada para instalar. Baixe de novo."))?;
    let versao = fs::read_to_string(trabalho.join("versao.txt")).unwrap_or_default();
    fs::create_dir_all(programa.join("logs"))?;
    // Fora da pasta de trabalho: o próprio script a apaga no fim.
    let arquivo = std::env::temp_dir().join(format!("baiacu_atualizar_{}.cmd", std::process::id()));
    let mut f = fs::File::create(&arquivo)?;
    f.write_all(script(std::process::id(), &novo, &programa, &trabalho).as_bytes())?;
    drop(f);
    iniciar_script(&arquivo)?;
    crate::registro::info("atualizacao", &format!(
        "Atualização para a versão {} agendada: o programa fecha e abre de novo.",
        versao.trim()
    ));
    Ok(json!({ "versao": versao.trim() }))
}

#[cfg(windows)]
fn iniciar_script(arquivo: &Path) -> Res<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    std::process::Command::new("cmd")
        .arg("/c")
        .arg(arquivo)
        .creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS)
        .spawn()
        .map_err(|e| erro(format!("Não foi possível iniciar a instalação: {e}")))?;
    Ok(())
}

#[cfg(not(windows))]
fn iniciar_script(_arquivo: &Path) -> Res<()> {
    Err(erro("A atualização automática só existe no Windows."))
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn compara_versoes() {
        assert!(mais_nova("v0.9.1", "0.9.0"));
        assert!(mais_nova("1.0.0", "0.9.9"));
        assert!(mais_nova("0.10.0", "0.9.0"));
        assert!(!mais_nova("v0.9.0", "0.9.0"));
        assert!(!mais_nova("0.8.5", "0.9.0"));
        assert_eq!(partes("v1.2"), vec![1, 2]);
    }

    #[test]
    fn le_release_do_github() {
        let v = json!({
            "tag_name": "v0.9.1",
            "body": "Correções",
            "html_url": "https://github.com/x/y/releases/tag/v0.9.1",
            "assets": [
                {"name": "Baiacu-NFS-e-0.9.1-windows.zip", "size": 1000,
                 "browser_download_url": "https://exemplo/zip"},
                {"name": "Baiacu-NFS-e-0.9.1-windows.zip.sha256", "size": 90,
                 "browser_download_url": "https://exemplo/sha"}
            ]
        });
        let r = release_de(&v).unwrap();
        assert_eq!(r.versao, "0.9.1");
        assert_eq!(r.zip_url, "https://exemplo/zip");
        assert_eq!(r.sha_url, "https://exemplo/sha");
        // Sem o .sha256 não instala.
        let mut sem = v.clone();
        sem["assets"].as_array_mut().unwrap().pop();
        assert!(release_de(&sem).is_err());
    }

    #[test]
    fn hash_e_extracao() {
        let h = "a".repeat(64);
        assert_eq!(hash_publicado(&format!("{h}  arquivo.zip\n")), Some(h.clone()));
        assert_eq!(hash_publicado("xyz"), None);

        let base = std::env::temp_dir().join(format!("baiacu_teste_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        let zip_path = base.join("p.zip");
        {
            let mut w = zip::ZipWriter::new(fs::File::create(&zip_path).unwrap());
            let o = zip::write::SimpleFileOptions::default();
            w.start_file(format!("Baiacu NFS-e/{NOME_EXE}"), o).unwrap();
            w.write_all(b"exe").unwrap();
            w.start_file("Baiacu NFS-e/data/dll/nucleo.dll", o).unwrap();
            w.write_all(b"dll").unwrap();
            w.finish().unwrap();
        }
        let destino = base.join("novo");
        extrair(&zip_path, &destino).unwrap();
        let p = pasta_do_programa(&destino).unwrap();
        assert!(p.ends_with("Baiacu NFS-e"));
        assert!(p.join("data/dll/nucleo.dll").is_file());
        assert_eq!(sha256_arquivo(&p.join(NOME_EXE)).unwrap().len(), 64);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn script_preserva_dados() {
        let s = script(
            42,
            Path::new(r"C:\App\atualizacao\novo\Baiacu NFS-e"),
            Path::new(r"C:\App"),
            Path::new(r"C:\App\atualizacao"),
        );
        assert!(s.contains("/XD database logs atualizacao"));
        assert!(s.contains("PID eq 42"));
        assert!(s.contains(r#"start "" "C:\App\Baiacu NFS-e.exe""#));
    }
}
