//! Emissão da NFS-e: pré-visualização (monta e valida, sem assinar nem enviar) e o caminho
//! completo — config final → DPS → validação → assinatura → envio → nota autorizada no banco de
//! notas —, a fila de contingência, a substituição e o cancelamento.
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Mutex;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::{Datelike, NaiveDate};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::cadastro::{self, ServicoForm};
use crate::certificado::Material;
use crate::config_dps::{self, Contexto, Forcados};
use crate::erro::{Erro, Res};
use crate::ini::Ini;
use crate::rede::{self, Sessao, Tempo};
use crate::texto::{aparar, only_chave, only_doc, parse_iso_date};
use crate::{assinatura, banco, caminhos, cofre, dps_xml, jsonpy, pyfmt, registro, validacao, xml};

/// Tempo máximo (segundos) de cada chamada à SEFIN.
const TEMPO_SEFIN: f64 = 60.0;
const IDENTIFICACAO: &str = "BaiacuNFSe/1.0";

/// Serializa emissões: evita corrida no contador de numeração (ex.: duplo-clique no botão).
static TRAVA: Mutex<()> = Mutex::new(());

fn travar() -> std::sync::MutexGuard<'static, ()> {
    TRAVA.lock().unwrap_or_else(|e| e.into_inner())
}

// --------------------------------------------------------------------------------------------- //
// Erros da emissão (o `tipo` é o nome de sempre; os detalhes vão em `dados`)
// --------------------------------------------------------------------------------------------- //
/// Erro durante a emissão, com o caminho do registro para diagnóstico.
pub fn erro_de_emissao(
    msg: impl Into<String>,
    log_path: Option<&str>,
    numero_atual: Option<&str>,
) -> Erro {
    Erro::novo("EmissionError", msg)
        .com_dados(json!({ "log_path": log_path, "current_nfse_number": numero_atual }))
}

/// REJEIÇÃO de negócio da SEFIN (HTTP 4xx) — não é reenviável. Leva o corpo para quem chamou
/// inspecionar os códigos de erro (ex.: E0014 = DPS duplicada).
fn rejeitada(msg: String, status: Option<i64>, corpo: &Value) -> Erro {
    Erro::novo("EmissionRejected", msg).com_dados(json!({ "status_code": status, "body": corpo }))
}

/// Falha de TRANSMISSÃO (sem internet / SEFIN indisponível): a DPS foi construída, validada e
/// ASSINADA, mas o envio não foi aceito por indisponibilidade — dá para reenviar depois (fila de
/// contingência). Leva o que a fila precisa. `chave` preenchida = a SEFIN JÁ ACEITOU a nota (só
/// o pós-aceite falhou): o reenvio não retransmite, apenas conclui.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Pendencia {
    pub n_dps: String,
    pub serie: String,
    pub id_dps: String,
    pub tp_amb: String,
    /// A DPS assinada, em base64.
    pub signed_xml: String,
    /// O TEXTO da config final (para reenviar pela fila).
    pub shadow_config: String,
    pub status_code: Option<i64>,
    pub log_path: Option<String>,
    pub chave: String,
    /// A mensagem do erro que a originou.
    pub mensagem: String,
    /// O certificado que assinou a DPS (o próprio ou o de um procurador): o reenvio usa o mesmo.
    pub cert: String,
}

fn pendente(msg: String, p: Pendencia) -> Erro {
    let p = Pendencia {
        mensagem: msg.clone(),
        ..p
    };
    Erro::novo("TransmissionPending", msg).com_dados(serde_json::to_value(p).unwrap_or(Value::Null))
}

// --------------------------------------------------------------------------------------------- //
// Registro de cada emissão (caixa-preta em logs/emissoes, para perícia)
// --------------------------------------------------------------------------------------------- //
const PARTES_SENSIVEIS: [&str; 11] = [
    "senha",
    "password",
    "pass",
    "secret",
    "token",
    "authorization",
    "cookie",
    "pfx_password",
    "private_key",
    "key_pem",
    "cert_pem",
];
/// Os registros de emissão com mais dias que isto são apagados na emissão seguinte.
const RETENCAO_DIAS: u64 = 90;

fn sha_hex(dados: &[u8]) -> String {
    hex::encode(Sha256::digest(dados))
}

/// Tira do que vai para o registro o que não deve ficar lá: segredos, o payload e textos longos.
pub fn sanitizar(v: &Value, chave_pai: &str) -> Value {
    let minuscula = chave_pai.to_lowercase();
    if PARTES_SENSIVEIS.iter().any(|p| minuscula.contains(p)) {
        return json!("***REDACTED***");
    }
    match v {
        Value::String(s) if chave_pai == "dpsXmlGZipB64" => {
            let ascii: String = s.chars().filter(char::is_ascii).collect();
            json!({ "__redacted_payload__": true, "length": s.chars().count(), "sha256": sha_hex(ascii.as_bytes()) })
        }
        Value::Object(m) => Value::Object(
            m.iter()
                .map(|(k, x)| (k.clone(), sanitizar(x, k)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.iter().map(|x| sanitizar(x, chave_pai)).collect()),
        Value::String(s) if s.chars().count() > 500 => {
            json!({ "__redacted_large_string__": true, "length": s.chars().count(), "sha256": sha_hex(s.as_bytes()) })
        }
        outro => outro.clone(),
    }
}

fn agora_ms() -> String {
    chrono::Local::now()
        .format("%Y-%m-%dT%H:%M:%S%.3f")
        .to_string()
}

fn agora_s() -> String {
    chrono::Local::now().format("%Y-%m-%dT%H:%M:%S").to_string()
}

struct Registro {
    caminho: PathBuf,
    iniciado: String,
    eventos: Vec<Value>,
    resultado: Option<Value>,
}

impl Registro {
    fn novo() -> Registro {
        let pasta = caminhos::raiz().join("logs").join("emissoes");
        let _ = std::fs::create_dir_all(&pasta);
        // melhor esforço: apaga os registros velhos
        if let Ok(itens) = std::fs::read_dir(&pasta) {
            let limite = std::time::Duration::from_secs(RETENCAO_DIAS * 86400);
            for e in itens.flatten() {
                let velho = e
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .is_some_and(|i| i > limite);
                if velho && e.file_name().to_string_lossy().ends_with("_workflow.json") {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        let nome = format!(
            "{}_workflow.json",
            chrono::Local::now().format("%Y%m%d_%H%M%S_%6f")
        );
        Registro {
            caminho: pasta.join(nome),
            iniciado: agora_ms(),
            eventos: Vec::new(),
            resultado: None,
        }
    }

    fn caminho(&self) -> String {
        self.caminho.to_string_lossy().into_owned()
    }

    fn evento(&mut self, etapa: &str, mensagem: &str, dados: Value) {
        self.eventos.push(json!({ "ts": agora_ms(), "stage": etapa, "message": mensagem, "data": sanitizar(&dados, "") }));
        self.gravar(None, None);
    }

    /// Melhor esforço: o registro é caixa-preta, nunca pode derrubar uma emissão que a SEFIN já
    /// aceitou (disco cheio, antivírus segurando o arquivo…).
    fn gravar(&self, sucesso: Option<bool>, erro: Option<Value>) {
        let mut carga = Map::new();
        carga.insert("started_at".into(), json!(self.iniciado));
        carga.insert("updated_at".into(), json!(agora_ms()));
        carga.insert("success".into(), json!(sucesso));
        carga.insert("events".into(), Value::Array(self.eventos.clone()));
        if let Some(e) = erro {
            carga.insert("error".into(), sanitizar(&e, ""));
        }
        if let Some(r) = &self.resultado {
            carga.insert("final_result".into(), sanitizar(r, ""));
        }
        let texto = jsonpy::dumps(
            &Value::Object(carga),
            jsonpy::Formato {
                ordenar: false,
                recuo: Some(2),
                compacto: false,
                so_ascii: false,
            },
        );
        let _ = std::fs::write(&self.caminho, texto);
    }

    fn falhou(&self, e: &Erro) {
        self.gravar(
            Some(false),
            Some(json!({ "type": e.tipo, "message": e.msg, "traceback": "" })),
        );
    }
}

// --------------------------------------------------------------------------------------------- //
// Config final, pré-visualização
// --------------------------------------------------------------------------------------------- //
/// Os namespaces do XML (endpoints.ini [xml]): (NFS-e, assinatura digital).
pub fn namespaces() -> Res<(String, String)> {
    let cfg = Ini::de_arquivo(
        &caminhos::raiz().join("configs").join("endpoints.ini"),
        false,
    )?;
    let ou = |v: String, padrao: &str| if v.is_empty() { padrao.to_string() } else { v };
    Ok((
        ou(cfg.val("xml", "nfse_ns", ""), validacao::NS_NFSE),
        ou(cfg.val("xml", "xmldsig_ns", ""), validacao::NS_DS),
    ))
}

fn forcado<'a>(lista: &'a Forcados, secao: &str, opcao: &str) -> Option<&'a str> {
    lista
        .iter()
        .find(|((s, o), _)| s == secao && o == opcao)
        .map(|(_, v)| v.as_str())
}

/// Ambiente e série primeiro; depois o que quem chama forçou.
fn forcados_da_emissao(prestador: &str, ambiente: &str, extra: &Forcados) -> Res<Forcados> {
    let mut f: Forcados = Vec::new();
    config_dps::forcar(&mut f, "dps", "tpAmb", ambiente);
    config_dps::forcar(
        &mut f,
        "dps",
        "serie",
        &cadastro::get_serie(prestador, ambiente)?,
    );
    for ((secao, opcao), valor) in extra {
        config_dps::forcar(&mut f, secao, opcao, valor);
    }
    Ok(f)
}

/// A config final de uma emissão: (o texto dela, como é guardado; a config como a emissão a lê).
fn config_final_e_texto(
    prestador: &str,
    tomador: &str,
    servico: &str,
    form: Option<&ServicoForm>,
    ambiente: &str,
    extra: &Forcados,
) -> Res<(String, Ini)> {
    let forcados = forcados_da_emissao(prestador, ambiente, extra)?;
    let last_dps = cadastro::ensure_last_dps(prestador, ambiente)?;
    let tributos = cadastro::config_tributos_file(prestador);
    let ativa = cadastro::compose_active_config(prestador, tomador, servico, form)?;
    let ctx = Contexto {
        last_dps: &last_dps,
        tributos: &tributos,
    };
    let mut limpa = config_dps::parse_configs(
        &cadastro::config_prestador_file(prestador),
        &ativa,
        &ctx,
        &forcados,
    )?;
    crate::vencimento::aplicar(&mut limpa)?;
    crate::leiaute::completar_locacao(&mut limpa)?;
    let texto = limpa.para_texto();
    Ok((texto, limpa.ida_e_volta(true)?))
}

/// A config final de uma emissão, como a emissão a lê (depois de passar por arquivo).
pub fn config_final(
    prestador: &str,
    tomador: &str,
    servico: &str,
    form: Option<&ServicoForm>,
    ambiente: &str,
    extra: &Forcados,
) -> Res<Ini> {
    Ok(config_final_e_texto(prestador, tomador, servico, form, ambiente, extra)?.1)
}

/// Como uma seção aparece na pré-visualização: o último nome dela; nos grupos que se repetem
/// (unidades do imóvel, bens móveis…), a partir do grupo numerado: `gUnidImob[1].end`.
fn rotulo_da_secao(secao: &str) -> String {
    let partes: Vec<&str> = secao.split('.').collect();
    let numero = |p: &str| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit());
    match partes.iter().position(|p| numero(p)) {
        Some(i) if i > 0 => {
            let mut rotulo = String::new();
            for (k, parte) in partes[i - 1..].iter().enumerate() {
                if numero(parte) {
                    rotulo.push_str(&format!("[{parte}]"));
                } else {
                    if k > 0 {
                        rotulo.push('.');
                    }
                    rotulo.push_str(parte);
                }
            }
            rotulo
        }
        _ => partes.last().copied().unwrap_or(secao).to_string(),
    }
}

/// Resolve {auto}, monta a DPS e valida contra o XSD — sem rede, sem assinatura. Não altera a
/// numeração nem guarda nada. Com `form`, usa o serviço EM MEMÓRIA (nada é salvo no cadastro só
/// por pré-visualizar). `extra` entra na config final (ex.: grupo <subst> de uma substituição).
pub fn preview_emissao(
    prestador: &str,
    tomador: &str,
    ambiente: &str,
    servico: &str,
    form: Option<&ServicoForm>,
    extra: &Forcados,
) -> Res<Value> {
    preview_emissao_com(prestador, tomador, ambiente, servico, form, extra, false)
}

/// [preview_emissao], podendo também ASSINAR a DPS com o certificado que a emissão usaria
/// (o próprio ou o procurador escolhido no serviço) — só para mostrar e baixar o XML assinado:
/// nada é enviado nem guardado, e a numeração não anda. A emissão monta e assina de novo (com a
/// data/hora do envio).
pub fn preview_emissao_com(
    prestador: &str,
    tomador: &str,
    ambiente: &str,
    servico: &str,
    form: Option<&ServicoForm>,
    extra: &Forcados,
    assinar: bool,
) -> Res<Value> {
    if cadastro::ambiente_rotulo(ambiente).is_none() {
        return Err(Erro::valor(format!(
            "Ambiente inválido: {}.",
            pyfmt::repr(ambiente)
        )));
    }
    let do_cadastro;
    let form = match form {
        Some(f) => f,
        None => {
            do_cadastro = cadastro::get_servico(prestador, tomador, servico)?;
            &do_cadastro
        }
    };
    let competencia = forcado(extra, "dps", "dCompet").and_then(parse_iso_date);
    let mut erros = form.validate(cadastro::rtc_required(
        prestador,
        form,
        ambiente,
        competencia,
    )?);
    erros.extend(form.problemas_com_o_prestador(prestador));
    if !erros.is_empty() {
        return Err(Erro::valor(format!(
            "Serviço inválido para pré-visualização:\n- {}",
            erros.join("\n- ")
        )));
    }
    let (ns_nfse, ns_ds) = namespaces()?;
    let cfg = config_final(prestador, tomador, servico, Some(form), ambiente, extra)?;
    let montada = dps_xml::montar(&cfg, &ns_nfse)?;
    validacao::validar_dps(&montada.xml)?;
    let varredura = validacao::seguranca_basica(&montada.xml, &ns_nfse, &ns_ds, true)?;

    let mut valores = Map::new();
    for secao in cfg.secoes() {
        if secao.starts_with("valores") || secao.starts_with("IBSCBS") {
            let rotulo = rotulo_da_secao(secao);
            for (k, v) in cfg.itens(secao) {
                valores.insert(format!("{rotulo}.{k}"), Value::String(v.to_string()));
            }
        }
    }
    let mut r = json!({
        "id_dps": montada.id_dps,
        "n_dps": montada.n_dps,
        "serie": montada.serie,
        "tp_amb": ambiente,
        "valores": valores,
        "resumo": crate::resumo_dps::resumo(&montada.xml)?,
        "xml": String::from_utf8_lossy(&montada.bonito),
        "validation_issues": varredura.get("issues_count").cloned().unwrap_or(json!(0)),
    });
    if assinar {
        let cert = cadastro::cert_da_emissao(prestador, form)?;
        if aparar(&cert).is_empty() {
            return Err(Erro::valor(SEM_CERTIFICADO));
        }
        let pfx = cadastro::cert_pfx(prestador, Some(&cert))?;
        let senha = cadastro::read_cert_password(prestador, Some(&cert))?.ok_or_else(|| {
            Erro::valor(
                "A senha do certificado não está salva. Informe-a em Configurações > Certificado (ou emita uma vez, que o programa pede a senha).",
            )
        })?;
        let material = crate::certificado::carregar_pfx(&pfx, &senha)?;
        let (assinado, _) = assinatura::assinar_dps(&montada.xml, &ns_nfse, &material)?;
        let bonito = xml::para_bytes_bonito(&xml::ler(&assinado)?);
        r["cert"] = json!(cert);
        r["xml_assinado"] = json!(String::from_utf8_lossy(&bonito));
        r["xml_assinado_bruto"] = json!(String::from_utf8_lossy(&assinado));
    }
    Ok(r)
}

// --------------------------------------------------------------------------------------------- //
// SEFIN Nacional
// --------------------------------------------------------------------------------------------- //
/// URL base da SEFIN do ambiente (endpoints.ini [ambiente_N] sefin_base_url).
fn url_base(tp_amb: &str) -> Res<String> {
    let caminho = caminhos::raiz().join("configs").join("endpoints.ini");
    if !caminho.is_file() {
        return Err(Erro::nao_encontrado(format!(
            "Não foi possível ler endpoints.ini: {}",
            caminho.display()
        )));
    }
    let ini = Ini::de_arquivo(&caminho, false)?;
    let secao = format!("ambiente_{tp_amb}");
    if !ini.tem_secao(&secao) {
        return Err(Erro::valor(format!(
            "Endpoint ausente em endpoints.ini: [{secao}]"
        )));
    }
    let base = ini.val(&secao, "sefin_base_url", "");
    let base = base.trim_end_matches('/');
    if base.is_empty() {
        return Err(Erro::valor(format!(
            "Campo obrigatório vazio em endpoints.ini: [{secao}] sefin_base_url"
        )));
    }
    Ok(base.to_string())
}

pub fn gzip_b64(dados: &[u8]) -> String {
    let mut z = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(9));
    let _ = z.write_all(dados);
    STANDARD.encode(z.finish().unwrap_or_default())
}

/// base64 + gzip -> bytes (erro com a mensagem de quem leu).
pub fn b64_gunzip(texto: &str) -> Result<Vec<u8>, String> {
    let bruto = STANDARD
        .decode(texto.as_bytes())
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    flate2::read::MultiGzDecoder::new(bruto.as_slice())
        .read_to_end(&mut out)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

/// O ambiente (tpAmb) escrito dentro de um XML.
fn tp_amb_do_xml(xml_bytes: &[u8]) -> Res<String> {
    let raiz = xml::ler(xml_bytes)?;
    raiz.todos()
        .into_iter()
        .find(|e| e.nome == "tpAmb" && !e.texto_inicial().is_empty())
        .map(|e| aparar(e.texto_inicial()).to_string())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| Erro::valor("tpAmb não encontrado no XML dentro do payload."))
}

/// A resposta 2xx?
fn sucesso(registro: &Value) -> bool {
    registro
        .get("status_code")
        .and_then(Value::as_i64)
        .is_some_and(|s| (200..300).contains(&s))
}

/// Procura (em qualquer nível) o primeiro valor não vazio de uma destas chaves.
pub fn achar_valor<'a>(v: &'a Value, chaves: &[&str]) -> Option<&'a Value> {
    let vazio = |x: &Value| x.is_null() || x.as_str() == Some("");
    match v {
        Value::Object(m) => {
            for (k, x) in m {
                if chaves.iter().any(|c| c.eq_ignore_ascii_case(k)) && !vazio(x) {
                    return Some(x);
                }
            }
            m.values()
                .filter_map(|x| achar_valor(x, chaves))
                .find(|x| !vazio(x))
        }
        Value::Array(a) => a
            .iter()
            .filter_map(|x| achar_valor(x, chaves))
            .find(|x| !vazio(x)),
        _ => None,
    }
}

const CHAVES_DA_CHAVE: [&str; 3] = ["chaveAcesso", "chave_acesso", "chave"];

fn texto_py(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        outro => jsonpy::dumps(outro, jsonpy::Formato::UTF8),
    }
}

fn chave_da_resposta(corpo: &Value) -> String {
    achar_valor(corpo, &CHAVES_DA_CHAVE)
        .map(texto_py)
        .unwrap_or_default()
}

/// Coleta os códigos de erro ('Codigo') do corpo de resposta da SEFIN (qualquer nível).
pub fn codigos_erro(corpo: &Value) -> Vec<String> {
    fn andar(v: &Value, achados: &mut Vec<String>) {
        match v {
            Value::Object(m) => {
                for (k, x) in m {
                    match x {
                        Value::String(s) if k.to_lowercase() == "codigo" => {
                            achados.push(aparar(s).to_uppercase())
                        }
                        outro => andar(outro, achados),
                    }
                }
            }
            Value::Array(a) => a.iter().for_each(|x| andar(x, achados)),
            _ => {}
        }
    }
    let mut achados = Vec::new();
    andar(corpo, &mut achados);
    achados
}

/// Resumo curto do corpo de erro da SEFIN para exibir ao usuário.
fn resumo_do_corpo(corpo: &Value) -> String {
    let s = match corpo {
        Value::Object(_) | Value::Array(_) => jsonpy::dumps(corpo, jsonpy::Formato::UTF8),
        outro => texto_py(outro),
    };
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(600)
        .collect()
}

/// O XML que veio numa resposta de download.
fn xml_da_resposta(corpo: &Value) -> Res<Vec<u8>> {
    match corpo {
        Value::String(s) => {
            let t = aparar(s);
            if t.starts_with('<') {
                return Ok(t.as_bytes().to_vec());
            }
        }
        Value::Object(m) => {
            for chave in ["nfseXmlGZipB64", "nfse_xml_gzip_b64"] {
                if let Some(v) = m
                    .get(chave)
                    .filter(|v| !v.is_null() && v.as_str() != Some(""))
                {
                    return b64_gunzip(&texto_py(v)).map_err(|e| {
                        Erro::valor(format!(
                            "Campo {chave} inválido no retorno do download: {e}"
                        ))
                    });
                }
            }
            for chave in ["nfseXml", "nfse_xml", "xml"] {
                if let Some(v) = m
                    .get(chave)
                    .filter(|v| !v.is_null() && v.as_str() != Some(""))
                {
                    let t = texto_py(v);
                    let t = aparar(&t);
                    if t.starts_with('<') {
                        return Ok(t.as_bytes().to_vec());
                    }
                }
            }
        }
        _ => {}
    }
    Err(Erro::valor("Retorno do download não contém XML."))
}

// --------------------------------------------------------------------------------------------- //
// Uma emissão em andamento
// --------------------------------------------------------------------------------------------- //
struct Andamento {
    prestador: String,
    /// Nome do certificado em uso (ver `cadastro::list_certificados`).
    cert: String,
    cfg: Ini,
    config_texto: String,
    material: Material,
    sessao: Option<Sessao>,
    last_dps: String,
    ns_nfse: String,
    ns_ds: String,
    registro: Registro,
    numero_atual: Option<String>,
    /// A SEFIN rejeitou com E0014 (DPS já processada) e a chave foi recuperada por GET /dps: a
    /// nota NÃO foi gerada agora, veio de um envio anterior. A tela precisa avisar.
    recuperada_e0014: bool,
}

impl Andamento {
    /// A conexão com a SEFIN, uma por operação (POST /nfse e os GETs batem no mesmo host).
    fn sessao(&mut self) -> Res<&Sessao> {
        if self.sessao.is_none() {
            self.sessao = Some(Sessao::nova(
                Some(&self.material),
                Tempo::igual(TEMPO_SEFIN),
                IDENTIFICACAO,
                false,
            )?);
        }
        Ok(self.sessao.as_ref().expect("sessão criada"))
    }

    fn tp_amb(&self) -> Res<String> {
        let v = self.cfg.val("dps", "tpAmb", "");
        if v.is_empty() {
            return Err(Erro::valor(
                "tpAmb ausente na config final; não é possível determinar o ambiente de download.",
            ));
        }
        Ok(v)
    }

    fn pendencia(
        &self,
        n_dps: &str,
        serie: &str,
        id_dps: &str,
        assinado: &[u8],
        status: Option<i64>,
        chave: &str,
    ) -> Pendencia {
        Pendencia {
            n_dps: n_dps.to_string(),
            serie: serie.to_string(),
            id_dps: id_dps.to_string(),
            tp_amb: self.tp_amb().unwrap_or_default(),
            signed_xml: STANDARD.encode(assinado),
            shadow_config: self.config_texto.clone(),
            status_code: status,
            log_path: Some(self.registro.caminho()),
            chave: chave.to_string(),
            mensagem: String::new(),
            cert: self.cert.clone(),
        }
    }

    fn enviar(&mut self, payload_b64: &str, xml_assinado: &[u8]) -> Res<Value> {
        self.registro
            .evento("send", "enviando payload para sefin_sender", json!({}));
        let url = format!("{}/nfse", url_base(&tp_amb_do_xml(xml_assinado)?)?);
        let resposta = self.sessao()?.post_json(
            &url,
            &json!({ "dpsXmlGZipB64": payload_b64 }),
            &[("Content-Type", "application/json")],
        )?;
        let r = resposta.registro();
        self.registro.evento(
            "send",
            "retorno recebido da SEFIN",
            json!({ "response_path": "", "status_code": r.get("status_code"), "reason": r.get("reason") }),
        );
        Ok(r)
    }

    /// Envia e CLASSIFICA a falha: sem conexão ou HTTP >= 500 vira pendência (reenviável — fila de
    /// contingência); HTTP 4xx é REJEIÇÃO de negócio (não reenviar). Devolve o registro da
    /// resposta apenas quando a transmissão teve HTTP 2xx.
    fn enviar_ou_classificar(
        &mut self,
        payload_b64: &str,
        n_dps: &str,
        serie: &str,
        id_dps: &str,
        assinado: &[u8],
    ) -> Res<Value> {
        let resposta = match self.enviar(payload_b64, assinado) {
            Ok(r) => r,
            Err(e) if rede::erro_de_rede(&e) => {
                let msg = format!("Sem conexão com a SEFIN: {e}");
                self.registro.evento(
                    "send",
                    "transmissão indisponível — DPS elegível para fila",
                    json!({ "error": msg }),
                );
                return Err(pendente(
                    msg,
                    self.pendencia(n_dps, serie, id_dps, assinado, None, ""),
                ));
            }
            Err(e) => return Err(e),
        };
        if sucesso(&resposta) {
            return Ok(resposta);
        }
        let status = resposta.get("status_code").and_then(Value::as_i64);
        let status_txt = status
            .map(|s| s.to_string())
            .unwrap_or_else(|| "None".into());
        if status.is_none_or(|s| s >= 500) {
            let msg = format!("SEFIN indisponível (HTTP {status_txt}).");
            self.registro.evento(
                "send",
                "transmissão indisponível — DPS elegível para fila",
                json!({ "error": msg }),
            );
            return Err(pendente(
                msg,
                self.pendencia(n_dps, serie, id_dps, assinado, status, ""),
            ));
        }
        let corpo = resposta.get("body").cloned().unwrap_or(Value::Null);
        Err(rejeitada(
            format!(
                "Emissão REJEITADA pela SEFIN (HTTP {status_txt}): {}",
                resumo_do_corpo(&corpo)
            ),
            status,
            &corpo,
        ))
    }

    /// GET /dps/{idDps} — devolve a chave de acesso da NFS-e gerada a partir desta DPS (se
    /// existir). Usado para recuperar envios que a SEFIN processou mas cuja resposta se perdeu.
    fn consultar_dps(&mut self, id_dps: &str, tp_amb: &str) -> Res<Value> {
        let id_dps = aparar(id_dps);
        if id_dps.is_empty() {
            return Err(Erro::valor("idDps vazio na consulta de DPS."));
        }
        let url = format!("{}/dps/{id_dps}", url_base(tp_amb)?);
        Ok(self.sessao()?.get(&url, &[])?.registro())
    }

    /// GET /nfse/{chave}: o XML autorizado. (registro da resposta, url, XML)
    fn baixar(&mut self, ambiente: &str, numero: &str) -> Res<(Value, String, Vec<u8>)> {
        let (ambiente, numero) = (aparar(ambiente), aparar(numero));
        if ambiente.is_empty() {
            return Err(Erro::valor("Ambiente vazio não é permitido."));
        }
        if numero.is_empty() {
            return Err(Erro::valor("Número/chave da NFS-e vazio não é permitido."));
        }
        let url = format!("{}/nfse/{numero}", url_base(ambiente)?);
        let r = self
            .sessao()?
            .get(
                &url,
                &[("Accept", "application/json, application/xml, text/xml, */*")],
            )?
            .registro();
        if !sucesso(&r) {
            let status = r.get("status_code").and_then(Value::as_i64).unwrap_or(0);
            let motivo = r.get("reason").map(texto_py).unwrap_or_default();
            return Err(Erro::valor(format!(
                "Download do XML falhou: HTTP {status} {motivo} em {url}"
            )));
        }
        let xml_bytes = xml_da_resposta(r.get("body").unwrap_or(&Value::Null))?;
        Ok((r, url, xml_bytes))
    }

    /// Depois do aceite: pega o XML autorizado (o que veio na própria resposta do POST, ou por
    /// GET) e o guarda no banco de notas.
    fn receber_nota(&mut self, corpo: &Value, id_dps: &str) -> Res<Value> {
        // O ambiente de download é o mesmo em que emitimos (tpAmb da DPS), não o que vier no corpo
        // da resposta — nem a 8ª posição da chave, que é o ambiente GERADOR.
        let ambiente = self.tp_amb()?;
        let chave = chave_da_resposta(corpo);
        let chave = aparar(&chave).to_string();
        if chave.is_empty() {
            return Err(Erro::valor(
                "Retorno da transmissão não contém chaveAcesso para baixar o XML transmitido.",
            ));
        }
        // A resposta do POST /nfse JÁ TRAZ a NFS-e autorizada inteira em nfseXmlGZipB64: aproveitar
        // o que já veio poupa uma ida e volta inteira. O GET continua como PLANO B.
        let mut embutido: Option<Vec<u8>> = None;
        if let Some(m) = corpo.as_object() {
            for campo in ["nfseXmlGZipB64", "nfse_xml_gzip_b64"] {
                if let Some(v) = m.get(campo).filter(|v| {
                    !v.is_null() && v.as_str() != Some("") && v.as_bool() != Some(false)
                }) {
                    match b64_gunzip(&texto_py(v)) {
                        Ok(x) => embutido = Some(x),
                        Err(e) => self.registro.evento(
                            "get_nfse",
                            "nfseXmlGZipB64 ilegível — usando o GET",
                            json!({ "error": e }),
                        ),
                    }
                    break;
                }
            }
        }
        let (xml_bytes, baixado) = match embutido {
            Some(x) => {
                self.registro.evento(
                    "get_nfse",
                    "XML da NFS-e veio na resposta do POST (sem GET)",
                    json!({ "tipoAmbiente": ambiente, "number": chave, "bytes": x.len() }),
                );
                (x, None)
            }
            None => {
                self.registro.evento(
                    "get_nfse",
                    "baixando XML da NFS-e",
                    json!({ "tipoAmbiente": ambiente, "number": chave }),
                );
                let (r, url, x) = self.baixar(&ambiente, &chave)?;
                (x, Some((r, url)))
            }
        };
        let raiz = xml::ler(&xml_bytes)?;
        let n_nfse = raiz
            .todos()
            .into_iter()
            .skip(1)
            .find(|e| e.nome == "nNFSe")
            .map(|e| aparar(e.texto_inicial()).to_string())
            .unwrap_or_default();
        if n_nfse.is_empty() {
            return Err(Erro::valor("XML transmitido não contém a tag nNFSe."));
        }
        let oficial = xml::para_bytes(&raiz, true);
        // O XML autorizado vai DIRETO para o banco de notas (origem 'local' = emitida por este
        // programa; é o que a Consulta lista). Chave que já está lá não entra de novo.
        let (_, guardada) = cofre::guardar_emitida(&self.prestador, &oficial)?;
        let resultado = json!({
            "source": if baixado.is_none() { "post_nfse" } else { "download_xml" },
            "chaveAcesso": chave,
            "idDps": id_dps,
            "nNFSe": n_nfse,
            "tipoAmbiente": ambiente,
            "download_request_url": baixado.as_ref().map(|(_, u)| u.as_str()).unwrap_or(""),
            "download_response_path": "",
            "guardada": guardada,
            "official_xml_len": oficial.len(),
            "official_xml_sha256": sha_hex(&oficial),
            "root_tag": raiz.nome,
        });
        self.numero_atual = Some(n_nfse);
        self.registro.evento(
            "get_nfse",
            "XML da NFS-e guardado no banco de notas",
            json!({ "guardada": guardada, "chaveAcesso": chave, "source": resultado["source"] }),
        );
        Ok(resultado)
    }

    /// Avança o contador de numeração do ambiente. Nunca regride.
    fn avancar_numeracao(&mut self, n_dps: i64) -> Res<Value> {
        self.registro.evento(
            "dps_update",
            "atualizando last_dps.txt do prestador",
            json!({ "last_dps_path": self.last_dps }),
        );
        if n_dps <= 0 {
            return Err(Erro::valor(format!("nDPS emitido inválido: {n_dps}")));
        }
        let anterior = banco::get_contador(&self.last_dps)?.unwrap_or(0);
        let r = if anterior >= n_dps {
            json!({ "last_dps_path": self.last_dps, "previous": anterior, "requested": n_dps, "written": anterior, "updated": false,
                    "reason": "last_dps_atual_ja_e_maior_ou_igual" })
        } else {
            banco::set_contador(&self.last_dps, n_dps)?;
            json!({ "last_dps_path": self.last_dps, "previous": anterior, "requested": n_dps, "written": n_dps, "updated": true,
                    "reason": "transmissao_http_2xx" })
        };
        self.registro
            .evento("dps_update", "last_dps.txt atualizado", r.clone());
        Ok(r)
    }

    fn rodar(&mut self) -> Res<Value> {
        self.registro.evento("run", "iniciando workflow", json!({}));
        // montar
        self.registro.evento(
            "build",
            "enviando config final para xml_builder",
            json!({ "config_path": "" }),
        );
        let montada = dps_xml::montar(&self.cfg, &self.ns_nfse)?;
        self.registro.evento(
            "build",
            "xml montado",
            json!({ "idDps": montada.id_dps, "nDPS": montada.n_dps, "serie": montada.serie, "unsigned_xml": "" }),
        );
        // validar
        self.registro
            .evento("validate", "enviando xml para xml_validate", json!({}));
        validacao::validar_dps(&montada.xml)?;
        let validacao_r =
            validacao::seguranca_basica(&montada.xml, &self.ns_nfse, &self.ns_ds, true)?;
        self.registro.evento(
            "validate",
            "xml validado contra XSD e checagens técnicas básicas",
            json!({ "issues_count": validacao_r.get("issues_count") }),
        );
        // assinar
        self.registro
            .evento("sign", "enviando xml validado para xml_signer", json!({}));
        let (assinado, id_assinado) =
            assinatura::assinar_dps(&montada.xml, &self.ns_nfse, &self.material)?;
        let titular = crate::certificado::titular(&self.material.cert_der)
            .map(|t| t.sujeito)
            .unwrap_or_default();
        let assinatura_r = json!({
            "signer": "nucleo",
            "idDps": id_assinado,
            "xmlsec_verify_ok": true,
            "signature_localname": "Signature",
            "signature_namespace": self.ns_ds,
            "signed_xml_sha256": sha_hex(&assinado),
            "cert_subject": titular,
            "cert_sha256": self.material.sha256(),
            "additional_certs_count": self.material.adicionais_der.len(),
        });
        self.registro.evento(
            "sign",
            "xml assinado e assinatura conferida localmente",
            json!({ "idDps": id_assinado, "xmlsec_verify_ok": true, "signed_xml": "" }),
        );
        // payload
        self.registro.evento(
            "payload",
            "enviando xml assinado para payload_builder",
            json!({}),
        );
        let payload_b64 = gzip_b64(&assinado);
        if b64_gunzip(&payload_b64).ok().as_deref() != Some(assinado.as_slice()) {
            return Err(Erro::valor(
                "Payload descompactado nao bate com o XML assinado recebido.",
            ));
        }
        let payload_r = json!({
            "signed_xml_sha256": sha_hex(&assinado),
            "payload_roundtrip_sha256": sha_hex(&assinado),
            "payload_roundtrip_equals_signed_xml": true,
            "signed_xml_len": assinado.len(),
            "dpsXmlGZipB64_len": payload_b64.len(),
        });
        self.registro.evento(
            "payload",
            "json do payload montado e validado localmente",
            json!({ "payload_path": "", "dpsXmlGZipB64_len": payload_b64.len() }),
        );

        // enviar — a falha de transmissão sai CLASSIFICADA (pendência para a fila quando é
        // indisponibilidade; rejeição quando a SEFIN recusou de fato)
        let resposta = match self.enviar_ou_classificar(
            &payload_b64,
            &montada.n_dps,
            &montada.serie,
            &montada.id_dps,
            &assinado,
        ) {
            Ok(r) => r,
            Err(e) if e.tipo == "EmissionRejected" => {
                // E0014 = esta DPS (CNPJ+série+nDPS) já virou NFS-e num envio anterior, ex.: o
                // contador local ficou atrás da SEFIN. Sem este tratamento a emissão fica travada
                // para sempre nesse número. Recupera a chave pelo idDps e segue para o download —
                // SEM retransmitir.
                if !codigos_erro(e.dado("body")).iter().any(|c| c == "E0014") {
                    return Err(e);
                }
                let tp_amb = self.tp_amb()?;
                let consulta = self.consultar_dps(&montada.id_dps, &tp_amb)?;
                let chave_anterior =
                    chave_da_resposta(consulta.get("body").unwrap_or(&Value::Null));
                if chave_anterior.is_empty() {
                    return Err(erro_de_emissao(
                        format!(
                            "A SEFIN informa que a DPS nº {} JÁ gerou NFS-e (E0014), mas o GET /dps não devolveu a chave \
                             (HTTP {}). Ajuste o próximo número em Configurações > Numeração antes de emitir de novo.",
                            montada.n_dps,
                            consulta
                                .get("status_code")
                                .map(texto_py)
                                .unwrap_or_else(|| "None".into())
                        ),
                        Some(&self.registro.caminho()),
                        None,
                    ));
                }
                self.registro.evento(
                    "send",
                    "E0014: DPS já processada — chave recuperada por GET /dps",
                    json!({ "chaveAcesso": chave_anterior, "nDPS": montada.n_dps }),
                );
                self.recuperada_e0014 = true;
                json!({ "status_code": 200, "reason": "recuperado-E0014", "body": { "chaveAcesso": chave_anterior } })
            }
            Err(e) => return Err(e),
        };

        // ------------------------------------------------------------------
        // A PARTIR DAQUI A NFS-e EXISTE NA SEFIN e o número foi consumido lá. NENHUM erro deste
        // trecho pode virar "Falha na emissão": o usuário leria "falhou", reemitiria, e sairia
        // uma nota DUPLICADA.
        // ------------------------------------------------------------------
        let corpo = resposta.get("body").cloned().unwrap_or(Value::Null);
        let chave = chave_da_resposta(&corpo);
        let pos_aceite = (|| -> Res<(Value, Value)> {
            let n: i64 = aparar(&montada.n_dps)
                .parse()
                .map_err(|_| Erro::valor(format!("nDPS emitido inválido: {}", montada.n_dps)))?;
            let numeracao = self.avancar_numeracao(n)?;
            let nota = self.receber_nota(&corpo, &montada.id_dps)?;
            Ok((numeracao, nota))
        })();
        let (numeracao, nota) = match pos_aceite {
            Ok(x) => x,
            Err(e) => {
                self.registro.evento(
                    "get_nfse",
                    "NFS-e ACEITA, mas o pós-aceite falhou",
                    json!({ "chaveAcesso": chave, "nDPS": montada.n_dps, "error": e.msg }),
                );
                if chave.is_empty() {
                    // Sem chave não dá para enfileirar. Erro EXPLÍCITO: nunca sugerir reemissão.
                    return Err(erro_de_emissao(
                        format!(
                            "A NFS-e FOI ACEITA pela SEFIN (HTTP {}) e o número {} JÁ foi consumido, mas o retorno não trouxe \
                             a chave. NÃO REEMITA — confira na Consulta ou no portal da SEFIN. Detalhe: {e}",
                            resposta
                                .get("status_code")
                                .map(texto_py)
                                .unwrap_or_else(|| "None".into()),
                            montada.n_dps
                        ),
                        Some(&self.registro.caminho()),
                        Some(&montada.n_dps),
                    ));
                }
                return Err(pendente(
                    format!(
                        "NFS-e ACEITA pela SEFIN (chave {chave}), mas o pós-aceite falhou: {e}"
                    ),
                    self.pendencia(
                        &montada.n_dps,
                        &montada.serie,
                        &montada.id_dps,
                        &assinado,
                        None,
                        &chave,
                    ),
                ));
            }
        };
        let resultado = json!({
            "build": { "idDps": montada.id_dps, "nDPS": montada.n_dps, "serie": montada.serie, "warnings": [], "unsigned_xml": "" },
            "validate": validacao_r,
            "sign": sanitizar(&assinatura_r, ""),
            "payload": sanitizar(&payload_r, ""),
            "send": { "status_code": resposta.get("status_code"), "reason": resposta.get("reason"), "response_path": "" },
            "official_nfse": nota,
            "dps_update": numeracao,
            "recuperada_e0014": self.recuperada_e0014,
            "log_path": self.registro.caminho(),
        });
        self.registro
            .evento("run", "workflow finalizado", json!({}));
        self.registro.gravar(Some(true), None);
        Ok(resultado)
    }
}

fn material_do_certificado(prestador: &str, cert: &str) -> Res<Option<Material>> {
    cadastro::material_do_prestador(prestador, if cert.is_empty() { None } else { Some(cert) })
}

const SEM_CERTIFICADO: &str = "Certificado do prestador (ou a senha dele) não encontrado. Importe o certificado em Configurações.";

/// Emite uma NFS-e para o serviço `servico` do cliente. `ambiente` define o tpAmb ("1" =
/// produção, "2" = homologação). O certificado e a senha dele são lidos do banco; o serviço deve
/// já estar salvo no cadastro do cliente. O XML autorizado vai para o banco de notas.
pub fn emitir(
    prestador: &str,
    tomador: &str,
    servico: &str,
    cert: &str,
    ambiente: &str,
    extra: &Forcados,
) -> Res<Value> {
    if cadastro::ambiente_rotulo(ambiente).is_none() {
        return Err(Erro::valor(format!(
            "Ambiente inválido: {}. Use '1' (produção) ou '2' (homologação).",
            pyfmt::repr(ambiente)
        )));
    }
    let form = cadastro::get_servico(prestador, tomador, servico)?;
    let competencia = forcado(extra, "dps", "dCompet").and_then(parse_iso_date);
    let mut erros = form.validate(cadastro::rtc_required(
        prestador,
        &form,
        ambiente,
        competencia,
    )?);
    erros.extend(form.problemas_com_o_prestador(prestador));
    if !erros.is_empty() {
        return Err(Erro::valor(format!(
            "Serviço inválido para emissão:\n- {}",
            erros.join("\n- ")
        )));
    }
    // Nota que só existe no leiaute novo, num ambiente em que a SEFIN ainda não o aceita: nada é
    // numerado, assinado nem enviado.
    if crate::leiaute::e_condominio(&form.cTribNac) {
        return Err(Erro::valor(
            "Operações condominiais (99.05) ainda não foram liberadas no release 1 da NT 009. O cadastro permite prévia, mas não transmissão.",
        ));
    }
    if crate::leiaute::so_no_novo(&form.cTribNac)
        && !crate::leiaute::transmissao_liberada(&form.cTribNac, ambiente)
    {
        return Err(Erro::valor(crate::leiaute::recusa(ambiente)));
    }
    // O certificado sai do serviço (o próprio ou o de um procurador), não da tela.
    let escolhido = cadastro::cert_da_emissao(prestador, &form)?;
    if escolhido.is_empty() || aparar(cert).is_empty() {
        return Err(Erro::valor(SEM_CERTIFICADO));
    }
    let cert = escolhido.as_str();
    let senha = cadastro::read_cert_password(prestador, Some(cert))?;
    let pfx = cadastro::cert_pfx(prestador, Some(cert))?;
    if senha.is_none() || pfx.is_empty() {
        return Err(Erro::valor(SEM_CERTIFICADO));
    }
    for (nome, valor) in [
        ("prestador", prestador),
        ("tomador", tomador),
        ("cert", cert),
    ] {
        if aparar(valor).is_empty() {
            return Err(Erro::valor(format!(
                "Argumento vazio não permitido: {nome}"
            )));
        }
    }

    let _trava = travar();
    let last_dps = cadastro::ensure_last_dps(prestador, ambiente)?;
    let (config_texto, cfg) =
        match config_final_e_texto(prestador, tomador, servico, None, ambiente, extra) {
            Ok(x) => x,
            // Falta um dado de cadastro; nada foi montado nem enviado. Sai como falha comum de
            // emissão (mensagem limpa), não como "erro inesperado".
            Err(e) if e.tipo == config_dps::TRIBUTOS_INCOMPLETOS => {
                return Err(erro_de_emissao(e.msg, None, None));
            }
            Err(e) => return Err(e),
        };
    let material = crate::certificado::carregar_pfx(&pfx, senha.as_deref().unwrap_or(""))
        .map_err(|e| erro_de_emissao(e.msg, None, None))?;
    let (ns_nfse, ns_ds) = namespaces()?;
    let mut a = Andamento {
        prestador: aparar(prestador).to_string(),
        cert: cert.to_string(),
        cfg,
        config_texto,
        material,
        sessao: None,
        last_dps,
        ns_nfse,
        ns_ds,
        registro: Registro::novo(),
        numero_atual: None,
        recuperada_e0014: false,
    };
    match a.rodar() {
        Ok(mut resultado) => {
            let info = json!({
                "prestador": aparar(prestador),
                "tomador": aparar(tomador),
                "config_prestador": cadastro::config_prestador_file(aparar(prestador)),
                "config_tomador": cadastro::config_tomador_file(aparar(prestador), aparar(tomador)),
            });
            if let Some(m) = resultado.as_object_mut() {
                let mut novo = Map::new();
                novo.insert("parse_config".into(), info);
                novo.extend(std::mem::take(m));
                *m = novo;
            }
            a.registro.resultado = Some(resultado.clone());
            a.registro.gravar(Some(true), None);
            Ok(resultado)
        }
        Err(e) => {
            a.registro.evento(
                "run",
                "workflow interrompido por erro",
                json!({ "error": e.msg }),
            );
            a.registro.falhou(&e);
            match e.tipo {
                // já levam o que quem chamou precisa: não embrulhar
                "TransmissionPending" | "EmissionRejected" => Err(e),
                _ => Err(erro_de_emissao(
                    e.msg,
                    Some(&a.registro.caminho()),
                    a.numero_atual.as_deref(),
                )),
            }
        }
    }
}

// --------------------------------------------------------------------------------------------- //
// Fila de contingência: DPS assinadas que NÃO puderam ser transmitidas (sem internet / SEFIN
// fora). Mora no banco de dados (tabela pendente: a DPS assinada, a config final da emissão e
// os dados da linha) — nada em pasta.
// Enfileirar RESERVA a numeração (o contador do ambiente avança até o nDPS da DPS); cancelar
// devolve o número SÓ se ele ainda for o topo do contador (senão vira lacuna — a NFS-e Nacional
// não tem serviço de inutilização de DPS e tolera pulos de numeração).
// situacao: 'fila' (aguardando envio), 'cancelada' (tirada da fila pelo usuário) ou
// 'descartada' (o usuário não quis enfileirar) — as duas últimas ficam só para auditoria.
// --------------------------------------------------------------------------------------------- //
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct PendenteInfo {
    pub id: String,
    pub tomador: String,
    pub tomador_nome: String,
    pub grupo: String,
    pub servico: String,
    pub n_dps: String,
    pub serie: String,
    pub id_dps: String,
    pub tp_amb: String,
    pub valor: String,
    pub criado_em: String,
    pub ultima_tentativa: String,
    pub ultimo_erro: String,
    /// Preenchida = a SEFIN JÁ aceitou esta DPS: o reenvio NÃO retransmite, só conclui.
    pub chave: String,
    /// Emissão de SUBSTITUIÇÃO enfileirada: chave da nota antiga + motivo.
    pub subst_chave: String,
    pub subst_cmotivo: String,
    pub subst_xmotivo: String,
    /// O certificado que assinou a DPS ("" = fila antiga: o certificado padrão do prestador).
    pub cert: String,
}

fn meta_de(p: &PendenteInfo) -> String {
    jsonpy::dumps(
        &serde_json::to_value(p).unwrap_or(Value::Null),
        jsonpy::Formato::UTF8,
    )
}

fn gravar_meta(prestador: &str, p: &PendenteInfo) -> Res<()> {
    let con = banco::conn()?;
    con.execute(
        "UPDATE pendente SET meta=?1 WHERE prestador=?2 AND id=?3 AND situacao='fila'",
        params![meta_de(p), prestador, p.id],
    )?;
    Ok(())
}

fn gravar_pendente(
    prestador: &str,
    id: &str,
    situacao: &str,
    meta: &str,
    xml_bytes: &[u8],
    config: &str,
) -> Res<()> {
    let con = banco::conn()?;
    con.execute(
        "INSERT OR REPLACE INTO pendente (prestador, id, situacao, meta, xml, config) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![prestador, id, situacao, meta, xml_bytes, config],
    )?;
    Ok(())
}

fn numero_da_dps(texto: &str) -> Res<i64> {
    aparar(texto).parse::<i64>().map_err(|_| {
        Erro::valor(format!(
            "invalid literal for int() with base 10: {}",
            pyfmt::repr(texto)
        ))
    })
}

/// Coloca a DPS assinada na fila e RESERVA o número dela no contador do ambiente (a próxima
/// emissão usa o número seguinte). `subst` (opcional): {"chave","cMotivo","xMotivo"} de uma
/// emissão de SUBSTITUIÇÃO — a nota antiga é marcada quando o reenvio conclui.
pub fn enqueue_pendente(
    prestador: &str,
    tomador: &str,
    servico: &str,
    tomador_nome: &str,
    valor: &str,
    exc: &Pendencia,
    subst: &Value,
) -> Res<PendenteInfo> {
    let assinado = STANDARD
        .decode(exc.signed_xml.as_bytes())
        .unwrap_or_default();
    if assinado.is_empty() {
        return Err(Erro::valor(
            "DPS assinada indisponível — não dá para enfileirar este envio.",
        ));
    }
    let n = numero_da_dps(&exc.n_dps)?;
    let id = format!("{}_{}_{n:09}", exc.tp_amb, exc.serie);
    let campo = |nome: &str| {
        subst
            .get(nome)
            .filter(|v| !v.is_null() && v.as_str() != Some(""))
            .map(texto_py)
            .unwrap_or_default()
    };
    let p = PendenteInfo {
        id: id.clone(),
        tomador: only_doc(tomador),
        tomador_nome: tomador_nome.to_string(),
        grupo: cadastro::get_tomador_grupo(prestador, tomador)?,
        servico: servico.to_string(),
        n_dps: n.to_string(),
        serie: exc.serie.clone(),
        id_dps: exc.id_dps.clone(),
        tp_amb: exc.tp_amb.clone(),
        valor: valor.to_string(),
        criado_em: agora_s(),
        ultima_tentativa: String::new(),
        ultimo_erro: exc.mensagem.clone(),
        chave: exc.chave.clone(),
        subst_chave: campo("chave"),
        subst_cmotivo: campo("cMotivo"),
        subst_xmotivo: campo("xMotivo"),
        cert: exc.cert.clone(),
    };
    gravar_pendente(
        prestador,
        &id,
        "fila",
        &meta_de(&p),
        &assinado,
        &exc.shadow_config,
    )?;
    // Reserva a numeração (nunca regride).
    let caminho = cadastro::ensure_last_dps(prestador, &exc.tp_amb)?;
    if n > cadastro::get_last_dps(prestador, Some(&exc.tp_amb))? {
        banco::set_contador(&caminho, n)?;
    }
    Ok(p)
}

/// Guarda a DPS ASSINADA que o usuário optou por descartar — FORA da fila (não é reenviada, o
/// número não é reservado). Existe porque, num timeout, o programa não sabe se a SEFIN processou
/// o envio: se processou, a única forma de recuperar a nota depois é consultar pelo idDps.
/// Melhor esforço: nunca falha.
pub fn arquivar_dps_descartada(
    prestador: &str,
    exc: &Pendencia,
    tomador: &str,
    tomador_nome: &str,
) -> bool {
    let arquivar = || -> Res<bool> {
        let assinado = STANDARD
            .decode(exc.signed_xml.as_bytes())
            .unwrap_or_default();
        if assinado.is_empty() {
            return Ok(false);
        }
        let n = numero_da_dps(&exc.n_dps)?;
        let id = format!("{}_{}_{n:09}", exc.tp_amb, exc.serie);
        let meta = json!({
            "id": id, "n_dps": n.to_string(), "serie": exc.serie, "id_dps": exc.id_dps, "tp_amb": exc.tp_amb,
            "tomador": only_doc(tomador), "tomador_nome": tomador_nome, "descartado_em": agora_s(), "motivo": exc.mensagem,
        });
        gravar_pendente(
            prestador,
            &id,
            "descartada",
            &jsonpy::dumps(&meta, jsonpy::Formato::UTF8),
            &assinado,
            &exc.shadow_config,
        )?;
        Ok(true)
    };
    arquivar().unwrap_or(false)
}

pub fn list_pendentes(prestador: &str) -> Res<Vec<PendenteInfo>> {
    if prestador.is_empty() {
        return Ok(Vec::new());
    }
    let con = banco::conn()?;
    let mut st = con.prepare(
        "SELECT id, meta FROM pendente WHERE prestador=?1 AND situacao='fila' ORDER BY id",
    )?;
    let linhas = st
        .query_map([prestador], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut out = Vec::new();
    for (id, meta) in linhas {
        // metadado estragado não derruba a fila
        let lido = serde_json::from_str::<Value>(&meta).ok().and_then(|v| {
            let m = v.as_object()?;
            m.get("id")?;
            let texto: Map<String, Value> = m
                .iter()
                .map(|(k, x)| (k.clone(), Value::String(texto_py(x))))
                .collect();
            serde_json::from_value::<PendenteInfo>(Value::Object(texto)).ok()
        });
        out.push(lido.unwrap_or_else(|| PendenteInfo {
            id,
            ultimo_erro: "metadado ilegível".into(),
            ..Default::default()
        }));
    }
    Ok(out)
}

pub fn count_pendentes(prestador: &str) -> Res<i64> {
    if prestador.is_empty() {
        return Ok(0);
    }
    let con = banco::conn()?;
    Ok(con.query_row(
        "SELECT count(*) FROM pendente WHERE prestador=?1 AND situacao='fila'",
        [prestador],
        |r| r.get(0),
    )?)
}

/// A DPS assinada de um envio da fila (vazio se ele não está mais lá).
pub fn pendente_xml(prestador: &str, id: &str) -> Res<Vec<u8>> {
    let con = banco::conn()?;
    Ok(con
        .query_row(
            "SELECT xml FROM pendente WHERE prestador=?1 AND id=?2 AND situacao='fila'",
            params![prestador, id],
            |r| r.get::<_, Vec<u8>>(0),
        )
        .optional()?
        .unwrap_or_default())
}

/// Tira a DPS da fila (ela fica guardada como 'cancelada', para auditoria) e tenta devolver o
/// número: se o nDPS ainda é o TOPO do contador, o contador volta 1 e a próxima emissão
/// REAPROVEITA o número; senão o número fica como lacuna.
///
/// RECUSA pendentes com `chave`: ali a SEFIN JÁ aceitou a nota e o número está consumido LÁ.
pub fn cancelar_pendente(prestador: &str, p: &PendenteInfo, forcar: bool) -> Res<Value> {
    let _trava = travar(); // serializa com reenviar_pendente
    let chave;
    {
        let con = banco::conn()?;
        let meta: Option<String> = con
            .query_row(
                "SELECT meta FROM pendente WHERE prestador=?1 AND id=?2 AND situacao='fila'",
                params![prestador, p.id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(meta) = meta else {
            return Ok(json!({ "numero": p.n_dps, "reaproveitado": false, "ja_enviada": true }));
        };
        // relê a chave do BANCO, não do objeto da linha
        chave = match serde_json::from_str::<Value>(&meta) {
            Ok(v) if v.is_object() => {
                let c = v
                    .get("chave")
                    .filter(|c| !c.is_null() && c.as_str() != Some(""))
                    .map(texto_py)
                    .unwrap_or_default();
                aparar(&c).to_string()
            }
            _ => aparar(&p.chave).to_string(), // meta ilegível: usa o da linha
        };
        if !chave.is_empty() && !forcar {
            return Err(Erro::valor(format!(
                "Esta NFS-e JÁ foi aceita pela SEFIN (chave {chave}). O envio não pode ser cancelado — use Reenviar para \
                 concluir apenas o download do XML."
            )));
        }
        con.execute_batch("BEGIN")?;
        let r = (|| -> Res<()> {
            con.execute(
                "DELETE FROM pendente WHERE prestador=?1 AND id=?2 AND situacao='cancelada'",
                params![prestador, p.id],
            )?;
            con.execute("UPDATE pendente SET situacao='cancelada' WHERE prestador=?1 AND id=?2 AND situacao='fila'", params![prestador, p.id])?;
            Ok(())
        })();
        match r {
            Ok(()) => con.execute_batch("COMMIT")?,
            Err(e) => {
                let _ = con.execute_batch("ROLLBACK");
                return Err(e);
            }
        }
    }
    let mut reaproveitado = false;
    if chave.is_empty() {
        // com chave o número está consumido na SEFIN
        if let Ok(n) = aparar(&p.n_dps).parse::<i64>() {
            if cadastro::get_last_dps(prestador, Some(&p.tp_amb))? == n {
                banco::set_contador(&cadastro::last_dps_file(prestador, Some(&p.tp_amb)), n - 1)?;
                reaproveitado = true;
            }
        }
    }
    Ok(json!({ "numero": p.n_dps, "reaproveitado": reaproveitado }))
}

fn marcar_falha(prestador: &str, p: &mut PendenteInfo, erro: &str) {
    p.ultima_tentativa = agora_s();
    p.ultimo_erro = erro.to_string();
    let _ = gravar_meta(prestador, p); // anotar a falha não pode esconder a falha em si
}

/// Reenvia uma DPS da fila usando o XML ASSINADO + a config final guardados na hora do
/// enfileiramento (payload → envio → XML oficial; sem remontar nem reassinar).
///
/// À prova de duplicidade (E0014):
/// - chave já conhecida → NÃO retransmite; só conclui o download do XML oficial;
/// - rejeição E0014 no envio (a SEFIN processou uma tentativa anterior) → recupera a chave via
///   GET /dps/{id} e conclui o download;
/// - 2xx → a chave é gravada ANTES do download: se o download falhar, a próxima tentativa vira
///   só download.
/// Sucesso remove da fila. Indisponibilidade volta como pendência (fica na fila); outras
/// rejeições 4xx voltam como rejeição (o usuário decide cancelar).
pub fn reenviar_pendente(prestador: &str, p: &PendenteInfo, cert: &str) -> Res<Value> {
    let mut p = p.clone();
    // A DPS já está assinada: o reenvio autentica com o MESMO certificado que a assinou.
    let cert = if p.cert.is_empty() {
        cert.to_string()
    } else if cadastro::list_certificados(prestador)?.contains(&p.cert) {
        p.cert.clone()
    } else {
        return Err(Erro::valor(format!(
            "Esta DPS foi assinada com um certificado que não está mais cadastrado ({}). Importe-o de novo em Configurações > Certificado para reenviar, ou cancele o envio na fila.",
            p.cert
        )));
    };
    let cert = cert.as_str();
    let Some(senha) = cadastro::read_cert_password(prestador, Some(cert))? else {
        return Err(Erro::valor("Senha do certificado não encontrada no banco."));
    };
    let linha: Option<(Vec<u8>, Option<String>)> = {
        let con = banco::conn()?;
        con.query_row(
            "SELECT xml, config FROM pendente WHERE prestador=?1 AND id=?2 AND situacao='fila'",
            params![prestador, p.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
    };
    let Some((assinado, config_final)) = linha else {
        return Err(Erro::valor("Este envio não está mais na fila."));
    };
    let config_final = config_final.unwrap_or_default();
    if config_final.is_empty() {
        return Err(Erro::valor(
            "A config da emissão pendente não foi guardada com ela.",
        ));
    }
    for (nome, valor) in [
        ("prestador", prestador),
        ("tomador", p.tomador.as_str()),
        ("cert", cert),
    ] {
        if aparar(valor).is_empty() {
            return Err(Erro::valor(format!(
                "Argumento vazio não permitido: {nome}"
            )));
        }
    }
    let pfx = cadastro::cert_pfx(prestador, Some(cert))?;
    if pfx.is_empty() {
        return Err(Erro::nao_encontrado(
            "Certificado do prestador não encontrado. Importe o .pfx em Configurações > Certificado.",
        ));
    }
    let material = crate::certificado::carregar_pfx(&pfx, &senha)?;
    let (ns_nfse, ns_ds) = namespaces()?;
    let mut a = Andamento {
        prestador: aparar(prestador).to_string(),
        cert: cert.to_string(),
        cfg: Ini::de_texto(&config_final, true)?,
        config_texto: config_final,
        material,
        sessao: None,
        last_dps: cadastro::ensure_last_dps(prestador, &p.tp_amb)?,
        ns_nfse,
        ns_ds,
        registro: Registro::novo(),
        numero_atual: None,
        recuperada_e0014: false,
    };
    let (oficial, chave) = {
        let _trava = travar();
        let feito = (|| -> Res<(Value, String)> {
            let mut chave = aparar(&p.chave).to_string();
            if chave.is_empty() {
                a.registro.evento(
                    "payload",
                    "enviando xml assinado para payload_builder",
                    json!({}),
                );
                let payload_b64 = gzip_b64(&assinado);
                a.registro.evento(
                    "payload",
                    "json do payload montado e validado localmente",
                    json!({ "payload_path": "", "dpsXmlGZipB64_len": payload_b64.len() }),
                );
                match a.enviar_ou_classificar(
                    &payload_b64,
                    &p.n_dps,
                    &p.serie,
                    &p.id_dps,
                    &assinado,
                ) {
                    Ok(r) => chave = chave_da_resposta(r.get("body").unwrap_or(&Value::Null)),
                    Err(e)
                        if e.tipo == "EmissionRejected"
                            && codigos_erro(e.dado("body")).iter().any(|c| c == "E0014") =>
                    {
                        // E0014: esta DPS JÁ virou NFS-e numa tentativa anterior (ex.: timeout
                        // depois do aceite). Recupera a chave pelo idDps e vai para o download.
                        let consulta = a.consultar_dps(&p.id_dps, &p.tp_amb)?;
                        chave = chave_da_resposta(consulta.get("body").unwrap_or(&Value::Null));
                        if chave.is_empty() {
                            return Err(Erro::valor(format!(
                                "A SEFIN informa que esta DPS já gerou NFS-e (E0014), mas a consulta GET /dps não devolveu a chave \
                                 (HTTP {}).",
                                consulta
                                    .get("status_code")
                                    .map(texto_py)
                                    .unwrap_or_else(|| "None".into())
                            )));
                        }
                    }
                    Err(e) => return Err(e),
                }
            }
            // Nota ACEITA na SEFIN: persiste a chave ANTES do download — se ele falhar, a próxima
            // tentativa NÃO retransmite (senão daria E0014 de novo).
            if !chave.is_empty() && chave != p.chave {
                p.chave = chave.clone();
                gravar_meta(prestador, &p)?;
            }
            let oficial = a.receber_nota(&json!({ "chaveAcesso": chave }), &p.id_dps)?;
            // o contador já foi reservado no enfileiramento; a atualização nunca regride
            a.avancar_numeracao(numero_da_dps(&p.n_dps)?)?;
            Ok((oficial, chave))
        })();
        match feito {
            Ok(x) => x,
            Err(e) => {
                marcar_falha(prestador, &mut p, &e.msg);
                return Err(e);
            }
        }
    };
    {
        let con = banco::conn()?;
        con.execute(
            "DELETE FROM pendente WHERE prestador=?1 AND id=?2 AND situacao='fila'",
            params![prestador, p.id],
        )?;
    }
    // Emissão de substituição concluída: marca a nota ANTIGA como substituída pela nova.
    if !p.subst_chave.is_empty() {
        let _ = marcar_substituida(prestador, &p.subst_chave, &chave); // não pode desfazer o sucesso do envio
    }
    let mut resultado = json!({ "official_nfse": oficial, "log_path": a.registro.caminho(), "chave": chave, "tp_amb": p.tp_amb, "tomador": p.tomador });
    // SMTP fora da trava de emissão: a nota já foi concluída e retirada da fila.
    // A falha do e-mail é informada sem transformar uma emissão aceita em pendência.
    let email = (|| -> Res<Option<Value>> {
        if crate::correio::get_email_settings(prestador)?.auto_para(&p.tp_amb) {
            Ok(Some(crate::correio::enviar_nfse_email(
                prestador, &p.tomador, &chave, &p.tp_amb,
            )?))
        } else {
            Ok(None)
        }
    })();
    match email {
        Ok(Some(envio)) => resultado["email"] = envio,
        Ok(None) => {}
        Err(e) => {
            crate::registro::aviso(
                "service",
                &format!("Fila concluiu a NFS-e {chave} mas o e-mail falhou: {e}"),
            );
            resultado["email"] = json!({ "sent": false, "error": e.msg });
        }
    }
    Ok(resultado)
}

// --------------------------------------------------------------------------------------------- //
// Substituição de NFS-e (grupo DPS/infDPS/subst)
// --------------------------------------------------------------------------------------------- //
// A substituição NÃO é um evento transmitido à parte: é uma EMISSÃO normal de DPS que carrega o
// grupo <subst> (chave da nota antiga + motivo). Ao aceitar, a SEFIN gera a NFS-e substituta E
// registra sozinha o evento e105102 na nota antiga.
pub const SUBST_MOTIVOS: [(&str, &str); 6] = [
    ("01", "Desenquadramento de NFS-e do Simples Nacional"),
    ("02", "Enquadramento de NFS-e no Simples Nacional"),
    ("03", "Inclusão Retroativa de Imunidade/Isenção"),
    ("04", "Exclusão Retroativa de Imunidade/Isenção"),
    ("05", "Rejeição da NFS-e pelo tomador/intermediário"),
    ("99", "Outros"),
];

/// Campos que a SEFIN NÃO permite alterar numa substituição (rejeição E0060): data de
/// competência, subitem da lista nacional, código complementar municipal e local da prestação.
/// Lidos da NFS-e substituída para serem FORÇADOS na emissão substituta. Vazio se o XML não
/// puder ser lido.
pub fn subst_campos_imutaveis(xml_bytes: &[u8]) -> Vec<(String, String)> {
    let Ok(raiz) = xml::ler(xml_bytes) else {
        return Vec::new();
    };
    let Some(inf) = raiz
        .achar_caminho(&["infNFSe", "DPS", "infDPS"])
        .or_else(|| raiz.achar("infDPS"))
    else {
        return Vec::new();
    };
    let serv = inf.achar("serv");
    let t = |el: Option<&xml::Elemento>, caminho: &[&str]| {
        el.and_then(|e| e.achar_caminho(caminho))
            .map(|a| aparar(a.texto_inicial()).to_string())
            .unwrap_or_default()
    };
    let d_compet = t(Some(inf), &["dCompet"]);
    // dCompet é obrigatório na DPS: se não veio, a leitura não achou a estrutura esperada.
    if d_compet.is_empty() {
        return Vec::new();
    }
    vec![
        ("dCompet".into(), d_compet),
        (
            "cLocPrestacao".into(),
            t(serv, &["locPrest", "cLocPrestacao"]),
        ),
        ("cTribNac".into(), t(serv, &["cServ", "cTribNac"])),
        ("cTribMun".into(), t(serv, &["cServ", "cTribMun"])),
    ]
}

/// Valores forçados que acrescentam o grupo <subst> à emissão. Com `imutaveis`, FORÇA na nota
/// substituta os campos que a SEFIN não deixa mudar (E0060) — inclusive removendo cTribMun se a
/// nota original não o tinha (valor vazio some da config final).
pub fn subst_overrides(
    chave: &str,
    c_motivo: &str,
    x_motivo: &str,
    imutaveis: &[(String, String)],
) -> Res<Forcados> {
    if !SUBST_MOTIVOS.iter().any(|(c, _)| *c == c_motivo) {
        return Err(Erro::valor(format!(
            "Motivo de substituição inválido: {}.",
            pyfmt::repr(c_motivo)
        )));
    }
    let mut f: Forcados = Vec::new();
    config_dps::forcar(&mut f, "subst", "chSubstda", &only_chave(chave));
    config_dps::forcar(&mut f, "subst", "cMotivo", c_motivo);
    if !aparar(x_motivo).is_empty() {
        config_dps::forcar(&mut f, "subst", "xMotivo", aparar(x_motivo));
    }
    let de = |nome: &str| {
        imutaveis
            .iter()
            .find(|(k, _)| k == nome)
            .map(|(_, v)| v.as_str())
            .unwrap_or("")
    };
    if !de("dCompet").is_empty() {
        config_dps::forcar(&mut f, "dps", "dCompet", de("dCompet"));
        config_dps::forcar(
            &mut f,
            "serv.locPrest",
            "cLocPrestacao",
            de("cLocPrestacao"),
        );
        config_dps::forcar(&mut f, "serv.cServ", "cTribNac", de("cTribNac"));
        config_dps::forcar(&mut f, "serv.cServ", "cTribMun", de("cTribMun"));
    }
    Ok(f)
}

/// Todos os vínculos de substituição: (chave antiga, chave nova).
pub fn subst_pairs(prestador: &str) -> Res<Vec<(String, String)>> {
    Ok(cofre::pares_substituicao(prestador)?
        .into_iter()
        .filter(|(_, n)| !n.is_empty() && n != "?")
        .collect())
}

/// Registra que `chave_antiga` foi substituída por `chave_nova`: no banco de notas ela passa a
/// constar cancelada e apontando para a substituta. Idempotente.
pub fn marcar_substituida(prestador: &str, chave_antiga: &str, chave_nova: &str) -> Res<()> {
    cofre::marcar_substituida(prestador, chave_antiga, chave_nova)
}

// --------------------------------------------------------------------------------------------- //
// Estorno / cancelamento de NFS-e (evento e101101)
// --------------------------------------------------------------------------------------------- //
pub const TIPO_EVENTO_CANCELAMENTO: &str = "101101";
/// Código de justificativa de cancelamento.
pub const CANC_MOTIVOS: [(&str, &str); 3] = [
    ("1", "Erro na Emissão"),
    ("2", "Serviço não Prestado"),
    ("9", "Outros"),
];

/// Ambiente REAL (tpAmb: 1 = produção, 2 = homologação) de uma NFS-e guardada, lido do que o
/// banco de notas tirou do XML (a chave de acesso NÃO carrega o tpAmb). "" se não achar.
pub fn ambiente_from_xml(chave: &str, prestador: &str) -> Res<String> {
    let chave = only_chave(chave);
    if chave.is_empty() || prestador.is_empty() {
        return Ok(String::new());
    }
    Ok(cofre::nota_por_chave(prestador, &chave)?
        .map(|n| n.amb)
        .filter(|a| cadastro::ambiente_rotulo(a).is_some())
        .unwrap_or_default())
}

/// Prazo para cancelamento DIRETO pelo emitente: 15º dia do mês seguinte ao da emissão. Cada
/// município pode ter regra própria e a SEFIN valida no envio — esta é uma verificação prévia.
pub fn cancelamento_limite(data_de_emissao: Option<NaiveDate>) -> Option<NaiveDate> {
    let d = data_de_emissao?;
    let (ano, mes) = if d.month() == 12 {
        (d.year() + 1, 1)
    } else {
        (d.year(), d.month() + 1)
    };
    NaiveDate::from_ymd_opt(ano, mes, 15)
}

/// (pode cancelar?, data limite). Sem data de emissão, deixa tentar (a SEFIN valida).
pub fn cancelamento_status(data_de_emissao: Option<NaiveDate>) -> (bool, Option<NaiveDate>) {
    match cancelamento_limite(data_de_emissao) {
        None => (true, None),
        Some(limite) => (chrono::Local::now().date_naive() <= limite, Some(limite)),
    }
}

/// Monta o XML (não assinado) do evento de cancelamento. Devolve (XML, Id). O Id é "PRE" + chave
/// (50) + tipo do evento (6).
pub fn montar_cancelamento(
    ns_nfse: &str,
    chave: &str,
    tp_amb: &str,
    autor_doc: &str,
    autor_e_cnpj: bool,
    c_motivo: &str,
    x_motivo: &str,
    ver_aplic: &str,
    versao: &str,
    quando: &str,
) -> Res<(Vec<u8>, String)> {
    let chave = only_chave(chave);
    if chave.chars().count() != 50 {
        return Err(Erro::valor(format!(
            "Chave de acesso deve ter 50 caracteres para o evento: {}",
            pyfmt::repr(&chave)
        )));
    }
    let id = format!("PRE{chave}{TIPO_EVENTO_CANCELAMENTO}");
    if !CANC_MOTIVOS.iter().any(|(c, _)| *c == c_motivo) {
        return Err(Erro::valor(format!(
            "Código de motivo inválido: {}. Use 1, 2 ou 9.",
            pyfmt::repr(c_motivo)
        )));
    }
    let x_motivo = aparar(x_motivo);
    let n = x_motivo.chars().count();
    if n < 15 {
        return Err(Erro::valor(
            "A justificativa (xMotivo) deve ter ao menos 15 caracteres.",
        ));
    }
    if n > 255 {
        return Err(Erro::valor(
            "A justificativa (xMotivo) deve ter no máximo 255 caracteres.",
        ));
    }
    // o CNPJ do autor pode ser ALFANUMÉRICO
    let autor = only_chave(autor_doc);
    if autor_e_cnpj && autor.chars().count() != 14 {
        return Err(Erro::valor(
            "CNPJ do autor do evento deve ter 14 caracteres.",
        ));
    }
    if !autor_e_cnpj && autor.chars().count() != 11 {
        return Err(Erro::valor("CPF do autor do evento deve ter 11 dígitos."));
    }
    let mut raiz = xml::Elemento::novo("pedRegEvento", ns_nfse);
    raiz.definir_attr("versao", versao);
    {
        let inf = raiz.filho("infPedReg");
        inf.definir_attr("Id", &id);
        inf.filho_texto("tpAmb", tp_amb);
        inf.filho_texto("verAplic", ver_aplic);
        inf.filho_texto("dhEvento", quando);
        inf.filho_texto(
            if autor_e_cnpj {
                "CNPJAutor"
            } else {
                "CPFAutor"
            },
            &autor,
        );
        inf.filho_texto("chNFSe", &chave);
        let ev = inf.filho("e101101");
        ev.filho_texto("xDesc", "Cancelamento de NFS-e");
        ev.filho_texto("cMotivo", c_motivo);
        ev.filho_texto("xMotivo", x_motivo);
    }
    Ok((xml::para_bytes(&raiz, true), id))
}

fn pasta_dos_esquemas() -> Res<(PathBuf, String)> {
    let cfg = Ini::de_arquivo(&caminhos::raiz().join("configs").join("paths.ini"), false)?;
    let base = cfg.val("schemas", "dir", "schemas");
    let versao = cfg.val("schemas", "versao", "1.01");
    Ok((
        caminhos::normalizar(&caminhos::absoluto(&base)).join(&versao),
        versao,
    ))
}

fn validar_evento(xml_bytes: &[u8]) -> Res<()> {
    let (pasta, versao) = pasta_dos_esquemas()?;
    let apontamentos = crate::xsd::validar(
        &pasta.join(format!("pedRegEvento_v{versao}.xsd")),
        xml_bytes,
    )?;
    let msgs: Vec<&str> = apontamentos
        .iter()
        .map(|a| a.mensagem.as_str())
        .filter(|m| !validacao::chave_falso_positivo_oficial(m))
        .collect();
    if msgs.is_empty() {
        Ok(())
    } else {
        Err(Erro::valor(format!(
            "Evento de cancelamento inválido contra o XSD: {}",
            msgs.join("; ")
        )))
    }
}

/// Monta, valida, assina e transmite o evento de cancelamento (e101101). Em caso de HTTP 2xx,
/// guarda o evento no banco de notas e marca a nota como cancelada. `ambiente` é o tpAmb REAL
/// (1/2) da nota; sem ele, vem do banco de notas. NUNCA derivar da chave.
pub fn cancelar_nfse(
    prestador: &str,
    chave: &str,
    c_motivo: &str,
    x_motivo: &str,
    ambiente: &str,
) -> Res<Value> {
    let chave = only_chave(chave);
    let mut tp_amb = aparar(ambiente).to_string();
    if cadastro::ambiente_rotulo(&tp_amb).is_none() {
        tp_amb = ambiente_from_xml(&chave, prestador)?;
    }
    if cadastro::ambiente_rotulo(&tp_amb).is_none() {
        return Err(Erro::valor(
            "Não foi possível determinar o ambiente (produção/homologação) da NFS-e para o cancelamento.",
        ));
    }
    let (ns_nfse, _) = namespaces()?;
    let (_, versao) = pasta_dos_esquemas()?;
    let ver_aplic = banco::load_ini(&cadastro::config_prestador_file(prestador), false)?.val(
        "dps",
        "verAplic",
        "emissor-proprio-1.0",
    );
    let autor = only_doc(prestador);
    let (xml_bytes, id) = montar_cancelamento(
        &ns_nfse,
        &chave,
        &tp_amb,
        &autor,
        autor.chars().count() == 14,
        c_motivo,
        x_motivo,
        &ver_aplic,
        &versao,
        &config_dps::agora_iso(),
    )?;
    validar_evento(&xml_bytes)?;
    let Some(material) = material_do_certificado(prestador, "")? else {
        return Err(Erro::valor(SEM_CERTIFICADO));
    };
    let assinado = assinatura::assinar_evento(&xml_bytes, &ns_nfse, &material)?;

    // a chave de acesso leva o CNPJ do emitente, que pode ter letras
    let chave_envio: String = chave
        .to_uppercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect();
    if chave_envio.chars().count() != 50 {
        return Err(Erro::valor(format!(
            "Chave de acesso inválida para registrar evento: {}",
            pyfmt::repr(&chave_envio)
        )));
    }
    let url = format!("{}/nfse/{chave_envio}/eventos", url_base(&tp_amb)?);
    let registro_r = {
        let sessao = Sessao::nova(
            Some(&material),
            Tempo::igual(TEMPO_SEFIN),
            IDENTIFICACAO,
            false,
        )?;
        sessao
            .post_json(
                &url,
                &json!({ "pedidoRegistroEventoXmlGZipB64": gzip_b64(&assinado) }),
                &[("Content-Type", "application/json")],
            )?
            .registro()
    };

    // A PARTIR DAQUI a SEFIN já respondeu. Uma falha ao registrar no banco de notas NÃO pode
    // virar "Falha no estorno": o evento pode ter sido registrado, e o usuário tentaria de novo.
    let ok = sucesso(&registro_r);
    let mut aviso = Value::Null;
    if ok {
        // O evento como a SEFIN o registrou, se veio na resposta; senão, o pedido assinado.
        let mut evento_xml = assinado.clone();
        if let Some(v) = registro_r
            .get("body")
            .and_then(|c| c.get("eventoXmlGZipB64"))
            .filter(|v| !v.is_null() && v.as_str() != Some(""))
        {
            if let Ok(x) = b64_gunzip(&texto_py(v)) {
                evento_xml = x;
            }
        }
        if let Err(e) = cofre::marcar_cancelada(prestador, &chave, Some(&evento_xml)) {
            aviso = json!(format!(
                "Cancelamento ACEITO pela SEFIN, mas o registro no banco de notas falhou: {e}. A NFS-e {chave} pode continuar \
                 aparecendo como ativa — use Sincronizar, no Cofre, para trazer o evento do ADN."
            ));
            registro::erro(
                "service",
                &format!("Falha ao registrar o cancelamento de {chave} no banco de notas: {e}"),
            );
        }
    }
    Ok(json!({
        "ok": ok,
        "aviso": aviso,
        "status_code": registro_r.get("status_code"),
        "reason": registro_r.get("reason"),
        "body": registro_r.get("body"),
        "id": id,
    }))
}
