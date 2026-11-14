//! E-mail: a configuração de cada prestador, o modelo da mensagem (assunto e corpo com
//! {variáveis}) e o envio da NFS-e ao tomador por SMTP, com o XML e a DANFSe em anexo.
#![allow(non_snake_case)]

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use lettre::message::header::ContentType;
use lettre::message::{Attachment, Mailbox, MultiPart, SinglePart};
use lettre::transport::smtp::PoolConfig;
use lettre::transport::smtp::authentication::Credentials;
use lettre::transport::smtp::client::{Tls, TlsParameters};
use lettre::{Message, SmtpTransport, Transport};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::cadastro::{self, AMBIENTE_HOMOLOGACAO, AMBIENTE_PRODUCAO};
use crate::erro::{Erro, Res};
use crate::ini::Ini;
use crate::texto::{aparar, format_documento, lower_email, only_chave, only_doc};
use crate::{banco, cofre, consulta, email_delta, registro, segredos};

/// Escopo de ambiente das opções de e-mail: "1" = só produção, "2" = só homologação, "ambos".
pub const ESCOPO_AMBOS: &str = "ambos";
const ESCOPOS: [&str; 3] = [AMBIENTE_PRODUCAO, AMBIENTE_HOMOLOGACAO, ESCOPO_AMBOS];
const SEGURANCAS: [&str; 3] = ["starttls", "ssl", "none"];

pub const ASSUNTO_PADRAO: &str = "NFS-e {numero} - {prestador}";
/// O corpo do e-mail é HTML PURO: quebras de linha são <br>, e qualquer tag (cor/fonte/negrito)
/// vale como escrita.
pub const MENSAGEM_PADRAO: &str = "Prezado cliente {tomador},<br><br>Segue em anexo a NFS-e número {numero}.<br>Chave de acesso: {chave}<br><br>\
Consulte a autenticidade em: {url_consulta}<br><br>Atenciosamente,<br>{prestador}<br><br>\
<i style=\"font-style:italic;font-size:12px;color:#c62828\">**Este é um e-mail automático, favor não responder**</i>";

fn escopo_atende(escopo: &str, ambiente: &str) -> bool {
    let e = aparar(if escopo.is_empty() {
        ESCOPO_AMBOS
    } else {
        escopo
    })
    .to_lowercase();
    let e = if ESCOPOS.contains(&e.as_str()) {
        e
    } else {
        ESCOPO_AMBOS.to_string()
    };
    e == ESCOPO_AMBOS || e == aparar(ambiente)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct EmailSettings {
    pub ativo: bool,
    /// "1" | "2" | "ambos" — onde o envio vale.
    pub ativo_ambientes: String,
    pub auto_enviar: bool,
    /// "1" | "2" | "ambos" — onde o envio automático vale.
    pub auto_ambientes: String,
    pub smtp_host: String,
    pub smtp_port: String,
    /// starttls, ssl ou none.
    pub seguranca: String,
    pub usuario: String,
    pub remetente: String,
    pub nome_remetente: String,
    pub assunto: String,
    pub mensagem: String,
    pub senha_configurada: bool,
}

impl Default for EmailSettings {
    fn default() -> Self {
        EmailSettings {
            ativo: false,
            ativo_ambientes: ESCOPO_AMBOS.into(),
            auto_enviar: false,
            auto_ambientes: ESCOPO_AMBOS.into(),
            smtp_host: String::new(),
            smtp_port: "587".into(),
            seguranca: "starttls".into(),
            usuario: String::new(),
            remetente: String::new(),
            nome_remetente: String::new(),
            assunto: ASSUNTO_PADRAO.into(),
            mensagem: MENSAGEM_PADRAO.into(),
            senha_configurada: false,
        }
    }
}

impl EmailSettings {
    /// Envio (manual ou automático) habilitado para o ambiente da nota?
    pub fn ativo_para(&self, ambiente: &str) -> bool {
        self.ativo && escopo_atende(&self.ativo_ambientes, ambiente)
    }

    /// Envio AUTOMÁTICO pós-emissão habilitado para o ambiente da nota?
    pub fn auto_para(&self, ambiente: &str) -> bool {
        self.ativo_para(ambiente)
            && self.auto_enviar
            && escopo_atende(&self.auto_ambientes, ambiente)
    }

    pub fn from_config(ini: &Ini, senha_configurada: bool) -> EmailSettings {
        let s = "email";
        let ou = |v: String, padrao: &str| if v.is_empty() { padrao.to_string() } else { v };
        let mut auto_amb = ini.val(s, "auto_ambientes", "");
        if !ESCOPOS.contains(&auto_amb.as_str()) {
            auto_amb = AMBIENTE_PRODUCAO.into(); // ainda não configurado: automático só em produção
        }
        let mut ativo_amb = ini.val(s, "ativo_ambientes", "");
        if !ESCOPOS.contains(&ativo_amb.as_str()) {
            ativo_amb = ESCOPO_AMBOS.into();
        }
        EmailSettings {
            ativo: ini.val(s, "ativo", "0") == "1",
            ativo_ambientes: ativo_amb,
            auto_enviar: ini.val(s, "auto_enviar", "0") == "1",
            auto_ambientes: auto_amb,
            smtp_host: ini.val(s, "smtp_host", ""),
            smtp_port: ini.val(s, "smtp_port", "587"),
            seguranca: ou(ini.val(s, "seguranca", "starttls"), "starttls").to_lowercase(),
            usuario: ini.val(s, "usuario", ""),
            remetente: ini.val(s, "remetente", ""),
            nome_remetente: ini.val(s, "nome_remetente", ""),
            assunto: ou(ini.val(s, "assunto", ASSUNTO_PADRAO), ASSUNTO_PADRAO),
            mensagem: ou(ini.val(s, "mensagem", MENSAGEM_PADRAO), MENSAGEM_PADRAO),
            senha_configurada,
        }
    }

    pub fn validate(&self, senha: Option<&str>) -> Vec<String> {
        let mut erros = Vec::new();
        if !self.ativo {
            return erros;
        }
        if aparar(&self.smtp_host).is_empty() {
            erros.push("Servidor SMTP é obrigatório.".to_string());
        }
        if !aparar(&self.smtp_port)
            .parse::<i64>()
            .is_ok_and(|p| (1..=65535).contains(&p))
        {
            erros.push("Porta SMTP deve ser um número entre 1 e 65535.".to_string());
        }
        if !SEGURANCAS.contains(&self.seguranca.to_lowercase().as_str()) {
            erros.push("Segurança deve ser STARTTLS, SSL ou Nenhuma.".to_string());
        }
        let remetente = if self.remetente.is_empty() {
            &self.usuario
        } else {
            &self.remetente
        };
        if !aparar(remetente).contains('@') {
            erros.push("Informe um e-mail remetente válido.".to_string());
        }
        if !aparar(&self.usuario).is_empty()
            && !(senha.is_some_and(|s| !s.is_empty()) || self.senha_configurada)
        {
            erros.push("Informe a senha/app password do SMTP.".to_string());
        }
        erros
    }
}

pub fn get_email_settings(prestador: &str) -> Res<EmailSettings> {
    let cfg = banco::load_ini(&cadastro::config_prestador_file(prestador), false)?;
    let senha_ok = !segredos::get_smtp_password(&only_doc(prestador))?.is_empty();
    Ok(EmailSettings::from_config(&cfg, senha_ok))
}

pub fn save_email_settings(
    prestador: &str,
    settings: &EmailSettings,
    senha: Option<&str>,
) -> Res<String> {
    let doc = only_doc(prestador);
    let atual = get_email_settings(&doc)?;
    let mut s = settings.clone();
    s.senha_configurada = atual.senha_configurada || senha.is_some_and(|x| !aparar(x).is_empty());
    let erros = s.validate(senha);
    if !erros.is_empty() {
        return Err(Erro::valor(format!(
            "Configuração de e-mail inválida:\n- {}",
            erros.join("\n- ")
        )));
    }
    let caminho = cadastro::config_prestador_file(&doc);
    let mut ini = banco::load_ini(&caminho, false)?;
    let escopo = |v: &str| {
        if ESCOPOS.contains(&v) {
            v.to_string()
        } else {
            ESCOPO_AMBOS.to_string()
        }
    };
    let ou = |v: &str, padrao: &str| {
        if v.is_empty() {
            padrao.to_string()
        } else {
            v.to_string()
        }
    };
    ini.por("email", "ativo", if s.ativo { "1" } else { "0" });
    ini.por("email", "ativo_ambientes", &escopo(&s.ativo_ambientes));
    ini.por(
        "email",
        "auto_enviar",
        if s.auto_enviar { "1" } else { "0" },
    );
    ini.por("email", "auto_ambientes", &escopo(&s.auto_ambientes));
    ini.por("email", "smtp_host", aparar(&s.smtp_host));
    ini.por("email", "smtp_port", &ou(aparar(&s.smtp_port), "587"));
    ini.por(
        "email",
        "seguranca",
        &ou(&s.seguranca, "starttls").to_lowercase(),
    );
    ini.por("email", "usuario", aparar(&s.usuario));
    ini.por(
        "email",
        "remetente",
        &lower_email(if s.remetente.is_empty() {
            &s.usuario
        } else {
            &s.remetente
        }),
    );
    ini.por("email", "nome_remetente", aparar(&s.nome_remetente));
    ini.por("email", "assunto", &ou(&s.assunto, ASSUNTO_PADRAO));
    ini.por("email", "mensagem", &ou(&s.mensagem, MENSAGEM_PADRAO));
    banco::save_ini(&caminho, &ini)?;
    if let Some(x) = senha.map(aparar).filter(|x| !x.is_empty()) {
        segredos::set_smtp_password(&doc, x)?;
    }
    Ok(caminho)
}

// --------------------------------------------------------------------------------------------- //
// Modelo da mensagem
// --------------------------------------------------------------------------------------------- //
pub type Valores = Vec<(String, String)>;

fn rx_variavel() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\{\{|\}\}|\{([a-z_][a-z0-9_]*)\}").expect("expressão regular"))
}

/// Substitui as {variáveis} do assunto/mensagem. {nome} conhecido vira o valor; {nome}
/// desconhecido fica como escrito (o usuário enxerga o erro de digitação no e-mail de teste);
/// "{{"/"}}" valem "{"/"}"; qualquer outra chave fica literal. Com `html`, o valor é escapado —
/// um tomador "A <B> LTDA" não pode virar tag no corpo.
pub fn render_template(modelo: &str, valores: &Valores, html: bool) -> String {
    rx_variavel()
        .replace_all(modelo, |m: &regex::Captures| {
            let ficha = &m[0];
            if ficha == "{{" {
                return "{".to_string();
            }
            if ficha == "}}" {
                return "}".to_string();
            }
            match valores.iter().find(|(k, _)| k == &m[1]) {
                None => ficha.to_string(),
                Some((_, v)) if html => v
                    .replace('&', "&amp;")
                    .replace('<', "&lt;")
                    .replace('>', "&gt;"),
                Some((_, v)) => v.clone(),
            }
        })
        .into_owned()
}

/// A mensagem como HTML PURO, fiel ao que o usuário escreveu: as tags valem como digitadas. O
/// texto sem fonte/tamanho próprios sai na fonte padrão do editor.
pub fn email_html(modelo: &str, valores: &Valores) -> String {
    email_delta::html_com_padrao(&render_template(modelo, valores, true))
}

/// Assunto é texto puro: troca as variáveis e remove eventuais tags HTML.
pub fn email_subject(modelo: &str, valores: &Valores) -> String {
    static TAG: OnceLock<Regex> = OnceLock::new();
    let r = TAG.get_or_init(|| Regex::new(r"<[^>]+>").expect("expressão regular"));
    aparar(&r.replace_all(&render_template(modelo, valores, false), "")).to_string()
}

// --------------------------------------------------------------------------------------------- //
// Conexão SMTP REAPROVEITADA entre envios seguidos
// --------------------------------------------------------------------------------------------- //
// Dos ~6 s de um envio, só 0,7-1,5 s são TCP+TLS+saudação; o resto é AUTH + DATA. Reusar a
// conexão pula TCP, TLS e AUTH inteiros a partir da 2ª nota. Num envio isolado não muda nada,
// por isso a conexão é mantida por pouco tempo e com tetos conservadores.
const OCIOSA_MAX: Duration = Duration::from_secs(60);
const MENSAGENS_MAX: u32 = 20;

struct Conexao {
    transporte: SmtpTransport,
    chave: String,
    ultimo: Instant,
    enviadas: u32,
}

static CONEXAO: Mutex<Option<Conexao>> = Mutex::new(None);

/// Encerra a conexão SMTP viva (chamar ao fechar o programa).
pub fn encerrar_smtp() {
    if let Ok(mut c) = CONEXAO.lock() {
        *c = None;
    }
}

fn erro_smtp(e: lettre::transport::smtp::Error) -> Erro {
    let codigo = e
        .status()
        .map(|c| c.to_string().parse::<i64>().unwrap_or(0));
    let texto = e.to_string();
    let tipo = if matches!(codigo, Some(530 | 534 | 535 | 538)) {
        "SMTPAuthenticationError"
    } else if e.is_timeout() {
        "TimeoutError"
    } else if e.is_response() {
        "SMTPResponseException"
    } else if e.is_tls() {
        "SSLError"
    } else {
        "SMTPServerDisconnected"
    };
    Erro::novo(tipo, texto.clone()).com_dados(json!({ "smtp_code": codigo, "smtp_error": texto }))
}

fn conectar(s: &EmailSettings, senha: &str) -> Res<SmtpTransport> {
    let host = aparar(&s.smtp_host).to_string();
    let porta: u16 = aparar(&s.smtp_port).parse().map_err(|_| {
        Erro::valor(format!(
            "invalid literal for int() with base 10: '{}'",
            s.smtp_port
        ))
    })?;
    let seguranca = if s.seguranca.is_empty() {
        "starttls".to_string()
    } else {
        s.seguranca.to_lowercase()
    };
    let tls = || TlsParameters::new(host.clone()).map_err(erro_smtp);
    let mut b = SmtpTransport::builder_dangerous(host.clone())
        .port(porta)
        .timeout(Some(Duration::from_secs(30)))
        .pool_config(PoolConfig::new().max_size(1).idle_timeout(OCIOSA_MAX));
    b = match seguranca.as_str() {
        "ssl" => b.tls(Tls::Wrapper(tls()?)),
        "starttls" => b.tls(Tls::Required(tls()?)),
        _ => b.tls(Tls::None),
    };
    let usuario = aparar(&s.usuario);
    if !usuario.is_empty() {
        b = b.credentials(Credentials::new(usuario.to_string(), senha.to_string()));
    }
    Ok(b.build())
}

fn enviar(s: &EmailSettings, senha: &str, msg: &Message) -> Res<()> {
    let chave = format!(
        "{}|{}|{}|{}",
        aparar(&s.smtp_host),
        s.smtp_port,
        s.seguranca,
        aparar(&s.usuario)
    );
    let mut guardada = CONEXAO.lock().unwrap_or_else(|e| e.into_inner());
    // Descarta a conexão se mudou a configuração, se ficou ociosa demais ou se já serviu
    // mensagens suficientes.
    if guardada.as_ref().is_some_and(|c| {
        c.chave != chave || c.ultimo.elapsed() > OCIOSA_MAX || c.enviadas >= MENSAGENS_MAX
    }) {
        *guardada = None;
    }
    if guardada.is_none() {
        *guardada = Some(Conexao {
            transporte: conectar(s, senha)?,
            chave: chave.clone(),
            ultimo: Instant::now(),
            enviadas: 0,
        });
    }
    let reusada = guardada.as_ref().is_some_and(|c| c.enviadas > 0);
    let resultado = guardada.as_ref().map(|c| c.transporte.send(msg));
    match resultado {
        Some(Ok(_)) => {
            if let Some(c) = guardada.as_mut() {
                c.enviadas += 1;
                c.ultimo = Instant::now();
            }
            Ok(())
        }
        Some(Err(e))
            if reusada
                && (e.is_transport_shutdown()
                    || (!e.is_response() && !e.is_timeout() && !e.is_tls())) =>
        {
            // A conexão caiu: uma única retentativa com conexão nova.
            let novo = conectar(s, senha)?;
            let r = novo.send(msg);
            *guardada = match r {
                Ok(_) => Some(Conexao {
                    transporte: novo,
                    chave,
                    ultimo: Instant::now(),
                    enviadas: 1,
                }),
                Err(_) => None,
            };
            r.map(|_| ()).map_err(erro_smtp)
        }
        Some(Err(e)) => {
            *guardada = None; // não deixa conexão suja guardada
            Err(erro_smtp(e))
        }
        None => Err(Erro::runtime("conexão de e-mail indisponível")),
    }
}

/// (categoria, mensagem para o usuário). Categorias:
///   'cota'       — limite diário/taxa do Gmail estourado (550 5.4.5 / 550 5.7.1): NÃO adianta
///                  reenviar hoje; o bloqueio dura de 1 a 24 h.
///   'senha'      — 535: a senha de APP foi revogada. Não é caso de nova tentativa.
///   'temporario' — 4.x.x: nova tentativa mais tarde.
///   'outro'      — o resto.
pub fn classificar_erro(tipo: &str, msg: &str, dados: &Value) -> (&'static str, String) {
    if tipo == "SMTPAuthenticationError" {
        return (
            "senha",
            "O servidor recusou a autenticação. Se você trocou a senha da conta Google, a senha de app foi revogada — gere outra e \
             reconfigure na aba E-mail."
                .to_string(),
        );
    }
    let texto = dados
        .get("smtp_error")
        .and_then(Value::as_str)
        .unwrap_or("");
    if texto.contains("5.4.5")
        || texto.contains("5.7.1")
        || texto.to_lowercase().contains("sending limit")
    {
        return (
            "cota",
            "Limite diário de envio do provedor estourado (Gmail gratuito: 500/dia). O bloqueio dura de 1 a 24 horas — os próximos \
             envios vão falhar até lá."
                .to_string(),
        );
    }
    if let Some(codigo) = dados
        .get("smtp_code")
        .and_then(Value::as_i64)
        .filter(|c| (400..500).contains(c))
    {
        return (
            "temporario",
            format!(
                "Falha temporária do servidor de e-mail ({codigo}). Vale tentar de novo em alguns minutos."
            ),
        );
    }
    ("outro", msg.to_string())
}

// --------------------------------------------------------------------------------------------- //
// Montar e enviar
// --------------------------------------------------------------------------------------------- //
fn caixa(email: &str, nome: &str) -> Res<Mailbox> {
    let endereco = lower_email(email)
        .parse()
        .map_err(|_| Erro::valor(format!("E-mail inválido: {email}")))?;
    let nome = aparar(nome);
    Ok(Mailbox::new(
        if nome.is_empty() {
            None
        } else {
            Some(nome.to_string())
        },
        endereco,
    ))
}

struct Carta<'a> {
    de: (&'a str, &'a str),
    para: &'a str,
    assunto: &'a str,
    responder_a: Option<&'a str>,
    html: String,
    anexos: Vec<(String, Vec<u8>)>,
}

fn tipo_do_anexo(nome: &str) -> ContentType {
    let tipo = match nome
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_lowercase()
        .as_str()
    {
        "xml" => "text/xml",
        "pdf" => "application/pdf",
        _ => "application/octet-stream",
    };
    ContentType::parse(tipo).unwrap_or(ContentType::TEXT_PLAIN)
}

fn montar(c: Carta) -> Res<Message> {
    let mut b = Message::builder()
        .from(caixa(c.de.0, c.de.1)?)
        .to(caixa(c.para, "")?)
        .subject(c.assunto);
    if let Some(r) = c.responder_a {
        b = b.reply_to(caixa(r, "")?);
    }
    let corpo = SinglePart::html(c.html);
    let msg = if c.anexos.is_empty() {
        b.singlepart(corpo)
    } else {
        // Corpo 100% HTML (sem parte em texto puro), mais os anexos.
        let mut partes = MultiPart::mixed().singlepart(corpo);
        for (nome, dados) in c.anexos {
            let tipo = tipo_do_anexo(&nome);
            partes = partes.singlepart(Attachment::new(nome).body(dados, tipo));
        }
        b.multipart(partes)
    };
    msg.map_err(|e| Erro::valor(format!("Não foi possível montar o e-mail: {e}")))
}

fn ou<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.is_empty() { b } else { a }
}

/// Envia uma mensagem simples para validar SMTP, login e remetente. Usa o ASSUNTO e a MENSAGEM
/// que o usuário configurou, para ele ver exatamente como o e-mail vai sair.
pub fn testar_email_settings(
    prestador: &str,
    settings: Option<&EmailSettings>,
    senha: Option<&str>,
    destinatario: &str,
) -> Res<Value> {
    let prestador = only_doc(prestador);
    if prestador.is_empty() {
        return Err(Erro::valor("Selecione um prestador para testar o e-mail."));
    }
    let do_banco;
    let settings = match settings {
        Some(s) => s,
        None => {
            do_banco = get_email_settings(&prestador)?;
            &do_banco
        }
    };
    let digitada = aparar(senha.unwrap_or("")).to_string();
    let mut cfg = settings.clone();
    cfg.ativo = true;
    cfg.senha_configurada = settings.senha_configurada || !digitada.is_empty();
    let erros = cfg.validate(if digitada.is_empty() {
        None
    } else {
        Some(&digitada)
    });
    if !erros.is_empty() {
        return Err(Erro::valor(format!(
            "Configuração de e-mail inválida:\n- {}",
            erros.join("\n- ")
        )));
    }
    let senha_final = if digitada.is_empty() {
        segredos::get_smtp_password(&prestador)?
    } else {
        digitada
    };
    if !aparar(&cfg.usuario).is_empty() && senha_final.is_empty() {
        return Err(Erro::valor(
            "Informe a senha/app password do SMTP para testar.",
        ));
    }
    let prest = cadastro::get_prestador_form(&prestador)?;
    let documento = format_documento(&prestador);
    let prest_nome = ou(ou(&prest.xNome, &prest.nome_exib), &documento).to_string();
    let remetente = lower_email(ou(ou(&cfg.remetente, &cfg.usuario), &prest.email));
    if !remetente.contains('@') {
        return Err(Erro::valor(
            "Informe um e-mail remetente válido na aba E-mail.",
        ));
    }
    let destino = lower_email(ou(destinatario, &remetente));
    if !destino.contains('@') {
        return Err(Erro::valor("Informe um e-mail de teste válido."));
    }
    // As variáveis que ainda não existem numa emissão real (numero/chave/valor) viram 'xxxx'; as
    // que dá para preencher recebem valores de exemplo.
    let nome_no_email = ou(&cfg.nome_remetente, &prest_nome).to_string();
    let valores: Valores = vec![
        ("numero".into(), "xxxx".into()),
        ("chave".into(), "xxxx".into()),
        ("tomador".into(), "CLIENTE DE TESTE".into()),
        ("prestador".into(), nome_no_email.clone()),
        ("valor".into(), "xxxx".into()),
        (
            "url_consulta".into(),
            consulta::url_consulta_nfse(AMBIENTE_PRODUCAO).to_string(),
        ),
        (
            "url_consulta_full".into(),
            consulta::url_consulta_nfse_completa("xxxx", AMBIENTE_PRODUCAO),
        ),
    ];
    let assunto = format!(
        "[TESTE] {}",
        email_subject(ou(&cfg.assunto, ASSUNTO_PADRAO), &valores)
    );
    let responder = lower_email(&prest.email);
    let msg = montar(Carta {
        de: (&remetente, &nome_no_email),
        para: &destino,
        assunto: &assunto,
        responder_a: if !prest.email.is_empty() && responder != remetente {
            Some(&responder)
        } else {
            None
        },
        html: email_html(ou(&cfg.mensagem, MENSAGEM_PADRAO), &valores), // idêntico ao do envio real
        anexos: Vec::new(),
    })?;
    enviar(&cfg, &senha_final, &msg)?;
    Ok(json!({ "sent": true, "to": destino, "from": remetente, "subject": assunto }))
}

/// Envia a NFS-e ao e-mail cadastrado do tomador, com o XML (do banco de notas) e a DANFSe
/// (gerada na hora a partir dele) em anexo.
pub fn enviar_nfse_email(
    prestador: &str,
    tomador: &str,
    chave: &str,
    ambiente: &str,
) -> Res<Value> {
    let (prestador, tomador, chave) = (only_doc(prestador), only_doc(tomador), only_chave(chave));
    if prestador.is_empty() || tomador.is_empty() || chave.is_empty() {
        return Err(Erro::valor(
            "Prestador, tomador e chave da NFS-e são obrigatórios para enviar e-mail.",
        ));
    }
    let settings = get_email_settings(&prestador)?;
    if !settings.ativo {
        return Err(Erro::valor(
            "Envio de e-mail não está habilitado. Configure o E-mail em Configurações.",
        ));
    }
    let erros = settings.validate(None);
    if !erros.is_empty() {
        return Err(Erro::valor(format!(
            "Configuração de e-mail inválida:\n- {}",
            erros.join("\n- ")
        )));
    }
    let tom = cadastro::get_tomador_form(&prestador, &tomador)?;
    let destinatario = lower_email(&tom.email);
    if !destinatario.contains('@') {
        return Err(Erro::valor("O tomador não tem e-mail válido cadastrado."));
    }
    let Some(nota) = cofre::nota_por_chave(&prestador, &chave)? else {
        return Err(Erro::nao_encontrado(
            "O XML desta NFS-e não está no banco de notas.",
        ));
    };
    let xml = cofre::xml_da_nota(nota.id)?;

    // Ambiente REAL da nota: parâmetro, senão o tpAmb do XML (a chave NÃO carrega tpAmb).
    let mut env_nota = aparar(ambiente).to_string();
    if cadastro::ambiente_rotulo(&env_nota).is_none() {
        env_nota = if cadastro::ambiente_rotulo(&nota.amb).is_some() {
            nota.amb.clone()
        } else {
            String::new()
        };
    }
    if let Some(rotulo) = cadastro::ambiente_rotulo(&env_nota) {
        if !settings.ativo_para(&env_nota) {
            return Err(Erro::valor(format!(
                "Envio de e-mail está desabilitado para o ambiente {rotulo} (veja o E-mail em Configurações)."
            )));
        }
    }
    // sem o PDF o e-mail ainda sai, com o XML
    let (pdf, erro_danfse) =
        match crate::danfse::gerar(&xml, nota.cancelada, !nota.subst_por.is_empty()) {
            Ok(p) => (p, String::new()),
            Err(e) => {
                registro::aviso(
                    "service",
                    &format!("DANFSe não pôde ser gerada para a chave {chave}: {e}"),
                );
                (Vec::new(), e.msg)
            }
        };
    let prest = cadastro::get_prestador_form(&prestador)?;
    let doc_prestador = format_documento(&prestador);
    let nome_cadastro = ou(ou(&prest.xNome, &prest.nome_exib), &doc_prestador).to_string();
    let nome_no_email = ou(&settings.nome_remetente, &nome_cadastro).to_string();
    let amb_url = ou(&env_nota, &nota.amb).to_string();
    let doc_tomador = format_documento(&tomador);
    let valores: Valores = vec![
        ("numero".into(), ou(&nota.nNFSe, &chave).to_string()),
        ("chave".into(), chave.clone()),
        ("tomador".into(), ou(&tom.xNome, &doc_tomador).to_string()),
        ("prestador".into(), nome_no_email.clone()),
        (
            "valor".into(),
            crate::texto::fmt_money_br_num(if nota.vLiq != 0.0 {
                nota.vLiq
            } else {
                nota.vServ
            }),
        ),
        // url pública conforme o ambiente REAL; nunca da chave
        (
            "url_consulta".into(),
            consulta::url_consulta_nfse(&amb_url).to_string(),
        ),
        (
            "url_consulta_full".into(),
            consulta::url_consulta_nfse_completa(&chave, &amb_url),
        ),
    ];
    let remetente = lower_email(ou(ou(&settings.remetente, &settings.usuario), &prest.email));
    if !remetente.contains('@') {
        return Err(Erro::valor(
            "Informe um e-mail remetente válido no E-mail das Configurações.",
        ));
    }
    let assunto = email_subject(ou(&settings.assunto, ASSUNTO_PADRAO), &valores);
    let responder = lower_email(&prest.email);
    let mut anexos = vec![(format!("{chave}.xml"), xml)];
    let tem_pdf = !pdf.is_empty();
    if tem_pdf {
        anexos.push((format!("{chave}.pdf"), pdf));
    }
    let nomes: Vec<String> = anexos.iter().map(|(n, _)| n.clone()).collect();
    let msg = montar(Carta {
        de: (&remetente, &nome_no_email),
        para: &destinatario,
        assunto: &assunto,
        responder_a: if !prest.email.is_empty() && responder != remetente {
            Some(&responder)
        } else {
            None
        },
        html: email_html(ou(&settings.mensagem, MENSAGEM_PADRAO), &valores),
        anexos,
    })?;
    enviar(&settings, &segredos::get_smtp_password(&prestador)?, &msg)?;
    Ok(json!({
        "sent": true, "to": destinatario, "subject": assunto, "attachments": nomes,
        "danfse_anexado": tem_pdf, "danfse_error": erro_danfse,
    }))
}
