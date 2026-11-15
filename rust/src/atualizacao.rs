//! Atualização autenticada por manifesto Ed25519 e SHA-256.
//! Downloads em TEMP por usuário. Instalação compartilhada pelo serviço sob demanda;
//! ZIP portátil pelo helper sem elevação. Nenhuma URL/comando do cliente é executado pelo serviço.
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::caminhos;
use crate::despacho::Avisar;
use crate::erro::{Erro, Res};
use crate::rede::{Sessao, Tempo};

/// Versão deste programa. `compilar_exe.py` confere que é a mesma do `pubspec.yaml`.
pub const VERSAO: &str = "1.0.0.1";
/// Repositório onde saem as versões novas (dono/nome).
pub const REPOSITORIO: &str = "williamlala/baiacu-nfse";
/// Nome do executável do programa empacotado.
pub const NOME_EXE: &str = "Baiacu NFS-e.exe";
/// Pasta (sob a raiz) onde a versão nova é baixada e preparada.
const PASTA: &str = "atualizacao";
/// Pastas do programa instalado que a atualização nunca toca.

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
        .take(4)
        .map(|p| p.parse().unwrap_or(0))
        .collect()
}

/// `nova` é mais recente que `atual`?
pub fn mais_nova(nova: &str, atual: &str) -> bool {
    let (mut a, mut b) = (partes(nova), partes(atual));
    a.resize(4, 0);
    b.resize(4, 0);
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
    pub assinatura_url: String,
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
        .ok_or_else(|| {
            erro(format!(
                "A versão {versao} foi publicada sem o arquivo .zip."
            ))
        })?;
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
    let assinatura = anexos
        .iter()
        .find(|a| nome_de(a) == format!("{zip_nome}.sig.json"))
        .ok_or_else(|| erro("A release não tem assinatura Ed25519. Atualização recusada."))?;
    Ok(Release {
        versao: versao.trim_start_matches(['v', 'V']).to_string(),
        notas: v["body"].as_str().unwrap_or("").trim().to_string(),
        pagina: v["html_url"].as_str().unwrap_or("").to_string(),
        zip_url: zip["browser_download_url"]
            .as_str()
            .unwrap_or("")
            .to_string(),
        zip_tamanho: zip["size"].as_u64().unwrap_or(0),
        assinatura_url: assinatura["browser_download_url"]
            .as_str()
            .unwrap_or("")
            .to_string(),
        zip_nome,
        sha_url: sha["browser_download_url"]
            .as_str()
            .unwrap_or("")
            .to_string(),
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
    release_de(
        &r.json()
            .ok_or_else(|| erro("Resposta do GitHub ilegível."))?,
    )
    .map(Some)
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
        && caminhos::normalizar(&pasta) == caminhos::normalizar(&caminhos::programa()))
    .then_some(pasta)
}

fn pasta_trabalho() -> PathBuf {
    // Isola instalações portáteis diferentes, sem gravar no diretório do programa.
    let id = hex::encode(Sha256::digest(
        caminhos::programa().to_string_lossy().as_bytes(),
    ));
    std::env::temp_dir()
        .join("BaiacuNFSe")
        .join(&id[..24])
        .join(PASTA)
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
pub fn baixar(versao_exibida: Option<&str>, avisar: Avisar) -> Res<Value> {
    #[cfg(windows)]
    {
        let helper = caminhos::programa().join("service/baiacu-atualizador.exe");
        baiacu_atualizador::client::check_startup_support(&helper)
            .map_err(|e| erro(e.to_string()))?;
        if caminhos::instalado_compartilhado() {
            baiacu_atualizador::client::ensure(&helper).map_err(|e| erro(e.to_string()))?;
        }
    }
    let r = ultima_release()?;
    if versao_exibida.is_some_and(|versao| versao != r.versao) {
        return Err(erro(
            "A última versão mudou. Procure por atualizações para ver as notas mais recentes.",
        ));
    }
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
        return Err(erro(
            "Não foi possível baixar a impressão digital da versão nova.",
        ));
    }
    let esperado = hash_publicado(&sha.texto())
        .ok_or_else(|| erro("A impressão digital publicada está em formato inválido."))?;

    let assinatura = sessao(30.0)?.get(&r.assinatura_url, &[])?;
    if assinatura.status != 200 {
        return Err(erro("Não foi possível baixar a assinatura."));
    }
    let manifesto =
        baiacu_atualizador::verify(&assinatura.corpo, baiacu_atualizador::PUBLIC_KEY, &r.versao)
            .map_err(|e| erro(format!("Assinatura inválida: {e}")))?;
    if manifesto.sha256.to_ascii_lowercase() != esperado {
        return Err(erro("O hash publicado diverge do manifesto assinado."));
    }
    fs::write(pasta.join("release.sig.json"), &assinatura.corpo)?;
    let zip = pasta.join("release.zip");
    let total = r.zip_tamanho;
    if total == 0 {
        avisar(&json!({"percentual": null, "etapa": format!("Baixando a versão {}", r.versao)}));
    }
    let mut ultimo = -1i64;
    sessao(120.0)?.baixar(&r.zip_url, &zip, &mut |lidos| {
        if total > 0 {
            let p = (lidos.min(total).saturating_mul(90) / total) as i64;
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
    let programa = baiacu_atualizador::extract(&zip, &pasta.join("novo"), &manifesto)
        .map_err(|e| erro(e.to_string()))?;
    fs::write(pasta.join("versao.txt"), &r.versao)?;
    avisar(&json!({"percentual": 100, "etapa": "Pronto para instalar"}));
    Ok(json!({ "versao": r.versao, "pasta": programa.to_string_lossy() }))
}

// --------------------------------------------------------------------------------------------- //
// Instalar
// --------------------------------------------------------------------------------------------- //
/// A instalação compartilhada usa SCM; a portátil usa o mesmo verificador sem privilégios.
pub fn instalar(versao_confirmada: Option<&str>) -> Res<Value> {
    let programa =
        instalado().ok_or_else(|| erro("Atualização disponível apenas no pacote Windows."))?;
    let trabalho = pasta_trabalho();
    let versao = fs::read_to_string(trabalho.join("versao.txt"))?;
    if versao_confirmada.is_some_and(|confirmada| confirmada != versao.trim()) {
        return Err(erro(
            "O pacote preparado mudou. Baixe novamente a versão que deseja instalar.",
        ));
    }
    let manifesto = baiacu_atualizador::verify(
        &fs::read(trabalho.join("release.sig.json"))?,
        baiacu_atualizador::PUBLIC_KEY,
        versao.trim(),
    )
    .map_err(|e| erro(e.to_string()))?;
    #[cfg(windows)]
    {
        use std::io::{BufRead, BufReader};
        use std::os::windows::process::CommandExt;
        use std::process::Stdio;
        let helper = programa.join("service/baiacu-atualizador.exe");
        baiacu_atualizador::client::check_startup_support(&helper)
            .map_err(|e| erro(e.to_string()))?;
        let mut cmd = std::process::Command::new(&helper);
        cmd.creation_flags(0x08000000 | 0x00000008);
        if caminhos::instalado_compartilhado() {
            baiacu_atualizador::client::ensure(&helper).map_err(|e| erro(e.to_string()))?;
            baiacu_atualizador::client::start(versao.trim(), std::process::id(), &manifesto.sha256)
                .map_err(|e| erro(e.to_string()))?;
            cmd.arg("--watch").current_dir(&programa).spawn()?;
        } else {
            // Falha antes de fechar se o ZIP foi extraído numa pasta sem permissão de escrita.
            let probe = programa.join(format!(".update-probe-{}", std::process::id()));
            fs::File::create(&probe).map_err(|_| erro("A pasta portátil não permite atualização. Mova o Baiacu para uma pasta sua ou use o instalador."))?;
            fs::remove_file(probe)?;
            let mut filho = cmd
                .arg("--portable-ack")
                .arg(versao.trim())
                .arg(std::process::id().to_string())
                .arg(&trabalho)
                .stdout(Stdio::piped())
                .spawn()?;
            let stdout = filho
                .stdout
                .take()
                .ok_or_else(|| erro("Atualizador sem canal de confirmação."))?;
            let mut resposta = String::new();
            BufReader::new(stdout).read_line(&mut resposta)?;
            let resposta = resposta.trim();
            if resposta != "READY" {
                let _ = filho.wait();
                return Err(erro(if resposta.is_empty() {
                    "O atualizador fechou antes de preparar a instalação."
                } else {
                    resposta
                }));
            }
        }
        Ok(json!({"versao": versao.trim()}))
    }
    #[cfg(not(windows))]
    {
        let _ = (programa, manifesto);
        Err(erro("Atualização disponível somente no Windows."))
    }
}

#[cfg(test)]
mod testes {
    use super::*;
    use std::io::Write;

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
                 "browser_download_url": "https://exemplo/sha"},
                {"name": "Baiacu-NFS-e-0.9.1-windows.zip.sig.json", "browser_download_url": "https://exemplo/sig"}
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
        assert_eq!(
            hash_publicado(&format!("{h}  arquivo.zip\n")),
            Some(h.clone())
        );
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
}
