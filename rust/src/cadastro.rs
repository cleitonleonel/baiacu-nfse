//! Cadastros: prestadores (com certificado, tributos, e-mail, numeração), clientes (tomadores),
//! serviços de cada cliente e grupos de clientes.
//!
//! Nada disto é pasta ou arquivo: os "caminhos" abaixo são só os NOMES com que cada cadastro é
//! guardado no banco (`banco`), no formato de sempre.
#![allow(non_snake_case)]

use std::path::Path;

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::erro::{Erro, Res};
use crate::ini::Ini;
use crate::texto::{
    self, aparar, cnpj_valido, cpf_valido, descricao_problemas, documento_valido, format_documento,
    is_decimal, lower_email, norm_decimal, only_digits, only_doc, sort_nome, upper_text,
};
use crate::{banco, caminhos, catalogo, certificado, leiaute, pyfmt, segredos};

pub const AMBIENTE_PRODUCAO: &str = "1";
pub const AMBIENTE_HOMOLOGACAO: &str = "2";

pub fn ambiente_rotulo(ambiente: &str) -> Option<&'static str> {
    match ambiente {
        AMBIENTE_PRODUCAO => Some("Produção"),
        AMBIENTE_HOMOLOGACAO => Some("Homologação"),
        _ => None,
    }
}

pub type Secoes = Vec<(String, Vec<(String, String)>)>;

fn par(k: &str, v: impl Into<String>) -> (String, String) {
    (k.to_string(), v.into())
}

// ------------------------------------------------------------------------------- //
// Chaves dos cadastros
// ------------------------------------------------------------------------------- //
pub fn prestador_dir(prestador: &str) -> String {
    format!("pessoas/prestador/{prestador}")
}

pub fn tomador_dir(prestador: &str, tomador: &str) -> String {
    format!("{}/tomador/{tomador}", prestador_dir(prestador))
}

pub fn config_prestador_file(prestador: &str) -> String {
    format!("{}/config_prestador.ini", prestador_dir(prestador))
}

pub fn config_tomador_file(prestador: &str, tomador: &str) -> String {
    format!("{}/config_tomador.ini", tomador_dir(prestador, tomador))
}

pub fn config_tributos_file(prestador: &str) -> String {
    format!("{}/config_tributos.ini", prestador_dir(prestador))
}

/// Chave do contador de numeração do ambiente: produção e homologação têm cada uma o seu, para
/// que emitir em teste nunca mexa na numeração de produção.
pub fn last_dps_file(prestador: &str, ambiente: Option<&str>) -> String {
    if ambiente == Some(AMBIENTE_HOMOLOGACAO) {
        format!("{}/last_dps_homolog.txt", prestador_dir(prestador))
    } else {
        format!("{}/last_dps.txt", prestador_dir(prestador))
    }
}

/// Série por ambiente: seções [1] (produção) e [2] (homologação).
pub fn numeracao_file(prestador: &str) -> String {
    format!("{}/numeracao.ini", prestador_dir(prestador))
}

/// Garante que o contador do ambiente exista (cria com 0 se faltar) e devolve a chave dele.
pub fn ensure_last_dps(prestador: &str, ambiente: &str) -> Res<String> {
    let caminho = last_dps_file(prestador, Some(ambiente));
    banco::ensure_contador(&caminho, 0)?;
    Ok(caminho)
}

fn ler(caminho: &str) -> Res<Ini> {
    banco::load_ini(caminho, false)
}

/// Valor literal de um campo, ignorando o marcador {auto} ("" nesse caso).
fn valor_explicito(ini: &Ini, secao: &str, opcao: &str) -> String {
    let v = ini.val(secao, opcao, "");
    if v == "{auto}" { String::new() } else { v }
}

fn gravar_secoes(caminho: &str, secoes: &Secoes) -> Res<()> {
    let mut ini = Ini::novo();
    for (secao, opcoes) in secoes {
        ini.adicionar_secao(secao)?;
        for (opcao, valor) in opcoes {
            ini.definir(secao, opcao, valor)?;
        }
    }
    banco::save_ini(caminho, &ini)
}

/// Penúltimo pedaço de uma chave ("…/tomador/123/config_tomador.ini" -> "123").
fn pasta_de(chave: &str) -> String {
    let mut partes = chave.rsplit('/');
    partes.next();
    partes.next().unwrap_or("").to_string()
}

fn lista_de_erros(titulo: &str, erros: &[String]) -> Erro {
    Erro::valor(format!("{titulo}:\n- {}", erros.join("\n- ")))
}

// ------------------------------------------------------------------------------- //
// Prestadores
// ------------------------------------------------------------------------------- //
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct PrestadorInfo {
    pub documento: String,
    pub xNome: String,
    /// Nome de exibição personalizado (só para a lista da tela inicial).
    pub nome_exib: String,
    pub display: String,
}

fn exibicao(nome_exib: &str, x_nome: &str, documento: &str) -> String {
    // Se houver nome de exibição, ele é mostrado exatamente como o usuário definiu.
    if !aparar(nome_exib).is_empty() {
        return aparar(nome_exib).to_string();
    }
    format!(
        "{} — {}",
        if x_nome.is_empty() {
            "Sem nome"
        } else {
            x_nome
        },
        format_documento(documento)
    )
}

pub fn list_prestadores() -> Res<Vec<PrestadorInfo>> {
    let mut docs: Vec<String> = banco::list_keys("pessoas/prestador", "/config_prestador.ini")?
        .iter()
        .map(|k| pasta_de(k))
        .collect();
    docs.sort();
    docs.dedup();
    let mut out = Vec::new();
    for doc in docs {
        let cfg = ler(&config_prestador_file(&doc))?;
        let x_nome = cfg.val("prest", "xNome", "");
        let nome_exib = cfg.val("prest", "xNomeExib", "");
        let display = exibicao(&nome_exib, &x_nome, &doc);
        out.push(PrestadorInfo {
            documento: doc,
            xNome: x_nome,
            nome_exib,
            display,
        });
    }
    // em ordem crescente pelo TEXTO exibido
    out.sort_by_cached_key(|p| (sort_nome(&p.display), p.documento.clone()));
    Ok(out)
}

pub fn ultimo_prestador(usuario_id: i64) -> Res<String> {
    Ok(only_doc(&banco::get_meta(&format!(
        "ui.ultimo_prestador.{usuario_id}"
    ))?))
}

pub fn guardar_ultimo_prestador(usuario_id: i64, documento: &str) -> Res<()> {
    banco::set_meta(
        &format!("ui.ultimo_prestador.{usuario_id}"),
        &only_doc(documento),
    )
}

pub fn escolher_prestador_inicial(disponiveis: &[String], preferido: &str) -> String {
    if disponiveis.iter().any(|d| d == preferido) {
        preferido.to_string()
    } else {
        disponiveis.first().cloned().unwrap_or_default()
    }
}

// ------------------------------------------------------------------------------- //
// Certificados do prestador, guardados no banco:
// - o PRÓPRIO, com o nome = documento do prestador (um só);
// - os de PROCURADORES (procuração eletrônica na Receita ou responsável legal), com o nome
//   "<prestador>@<documento do procurador>" (um por procurador; reimportar o mesmo documento
//   substitui, como na renovação).
// A nota sai sempre com os dados do prestador; o certificado só assina e autentica.
// ------------------------------------------------------------------------------- //
const SEP_PROCURADOR: char = '@';

/// Nome do certificado de um procurador deste prestador.
pub fn nome_cert_procurador(prestador: &str, doc_procurador: &str) -> String {
    format!(
        "{}{SEP_PROCURADOR}{}",
        only_doc(prestador),
        only_doc(doc_procurador)
    )
}

/// Documento do procurador de um nome de certificado ('' = é o certificado próprio).
pub fn doc_do_procurador(cert: &str) -> String {
    cert.split_once(SEP_PROCURADOR)
        .map(|(_, d)| d.to_string())
        .unwrap_or_default()
}

/// O certificado `cert` é deste prestador (o próprio ou de um procurador dele)?
fn cert_pertence(prestador: &str, cert: &str) -> bool {
    let (p, c) = (aparar(prestador), aparar(cert));
    if p.is_empty() || c.is_empty() {
        return false;
    }
    match c.split_once(SEP_PROCURADOR) {
        Some((dono, _)) => dono == only_doc(p),
        None => c == p || c == only_doc(p),
    }
}

/// O nome do certificado pedido, conferido; vazio = o ativo.
fn cert_escolhido(prestador: &str, cert: Option<&str>) -> Res<String> {
    match cert {
        Some(c) if !c.is_empty() => {
            if !cert_pertence(prestador, c) {
                return Err(Erro::valor(format!(
                    "O certificado {c} não pertence ao prestador {}.",
                    format_documento(prestador)
                )));
            }
            Ok(c.to_string())
        }
        _ => active_cert(prestador),
    }
}

/// O certificado próprio do prestador ('' = não tem).
pub fn cert_proprio(prestador: &str) -> Res<String> {
    Ok(
        if !prestador.is_empty() && segredos::tem_cert_pfx(prestador)? {
            prestador.to_string()
        } else {
            String::new()
        },
    )
}

/// Os certificados de procuradores do prestador, em ordem de documento.
pub fn list_procuradores(prestador: &str) -> Res<Vec<String>> {
    if only_doc(prestador).is_empty() {
        return Ok(Vec::new());
    }
    segredos::certs_com_prefixo(&format!("{}{SEP_PROCURADOR}", only_doc(prestador)))
}

/// Todos os certificados do prestador: o próprio primeiro, depois os de procuradores.
pub fn list_certificados(prestador: &str) -> Res<Vec<String>> {
    let mut todos: Vec<String> = Vec::new();
    let proprio = cert_proprio(prestador)?;
    if !proprio.is_empty() {
        todos.push(proprio);
    }
    todos.extend(list_procuradores(prestador)?);
    Ok(todos)
}

/// O certificado usado quando nada foi escolhido (cancelamento, Cofre, telas): o próprio; sem
/// ele, o do primeiro procurador ('' = o prestador não tem certificado nenhum).
pub fn active_cert(prestador: &str) -> Res<String> {
    Ok(list_certificados(prestador)?
        .into_iter()
        .next()
        .unwrap_or_default())
}

/// O certificado de uma emissão: o procurador escolhido no serviço; sem escolha, o próprio
/// (ou, se o prestador só tem procuradores, o primeiro deles).
pub fn cert_da_emissao(prestador: &str, form: &ServicoForm) -> Res<String> {
    let doc = only_doc(&form.cert_procurador);
    if doc.is_empty() {
        return active_cert(prestador);
    }
    let nome = nome_cert_procurador(prestador, &doc);
    if !segredos::tem_cert_pfx(&nome)? {
        return Err(Erro::valor(format!(
            "O serviço está marcado para assinar com o certificado do procurador {}, que não está mais \
             cadastrado neste prestador. Escolha outro certificado na tela Emitir ou importe-o em \
             Configurações > Certificado.",
            format_documento(&doc)
        )));
    }
    Ok(nome)
}

/// Os bytes do .pfx do prestador (vazio se não há).
pub fn cert_pfx(prestador: &str, cert: Option<&str>) -> Res<Vec<u8>> {
    let cert = cert_escolhido(prestador, cert)?;
    if cert.is_empty() {
        Ok(Vec::new())
    } else {
        segredos::get_cert_pfx(&cert)
    }
}

/// A senha do .pfx guardada no banco.
pub fn read_cert_password(prestador: &str, cert: Option<&str>) -> Res<Option<String>> {
    let cert = cert_escolhido(prestador, cert)?;
    if cert.is_empty() {
        return Ok(None);
    }
    let senha = segredos::get_cert_password(&cert)?;
    Ok(if senha.is_empty() { None } else { Some(senha) })
}

/// Exclui um certificado do prestador (o próprio ou o de um procurador). As notas já emitidas
/// não mudam; emissões e consultas passam a usar os certificados que restarem.
pub fn delete_certificate(prestador: &str, cert: &str) -> Res<()> {
    if !cert_pertence(prestador, cert) {
        return Err(Erro::valor(format!(
            "O certificado {cert} não pertence ao prestador {}.",
            format_documento(prestador)
        )));
    }
    segredos::remove_cert_pfx(cert)?;
    segredos::remove_cert_password(cert)?;
    Ok(())
}

/// Extrai o CNPJ (14) ou CPF (11) do nome comum do certificado (e-CNPJ/e-CPF: 'NOME:DOC').
pub fn doc_do_certificado(t: &certificado::Titular) -> String {
    let cn = t.nome_comum.clone().unwrap_or_else(|| t.sujeito.clone());
    // O documento é o que vem depois do último ':' — e um CNPJ ALFANUMÉRICO tem letras, que a
    // varredura por sequências de dígitos (abaixo) não enxerga.
    if let Some((_, fim)) = cn.rsplit_once(':') {
        let fim = only_doc(fim);
        let b = fim.as_bytes();
        if (b.len() == 14 && b[12..].iter().all(u8::is_ascii_digit))
            || (b.len() == 11 && b.iter().all(u8::is_ascii_digit))
        {
            return fim;
        }
    }
    let mut atual = String::new();
    let mut sequencias: Vec<String> = Vec::new();
    for c in cn.chars() {
        if c.is_ascii_digit() {
            atual.push(c);
        } else if !atual.is_empty() {
            sequencias.push(std::mem::take(&mut atual));
        }
    }
    if !atual.is_empty() {
        sequencias.push(atual);
    }
    sequencias
        .into_iter()
        .find(|s| s.len() == 11 || s.len() == 14)
        .unwrap_or_default()
}

/// O documento do certificado é compatível com o do prestador? A NFS-e Nacional valida a
/// assinatura pela RAIZ do CNPJ (8 primeiros): um e-CNPJ da MATRIZ assina para FILIAIS de mesma
/// raiz. Para CPF e demais casos, igualdade exata. Lado vazio: não há o que comparar.
pub fn docs_compativeis(cert_doc: &str, alvo_doc: &str) -> bool {
    let (c, a) = (only_doc(cert_doc), only_doc(alvo_doc));
    if c.is_empty() || a.is_empty() {
        return true;
    }
    if c.len() == 14 && a.len() == 14 {
        return c[..8] == a[..8];
    }
    c == a
}

fn ler_pfx_do_arquivo(caminho: &str, senha: &str) -> Res<(Vec<u8>, certificado::Material)> {
    if aparar(senha).is_empty() {
        return Err(Erro::valor("Informe a senha do certificado."));
    }
    let origem = Path::new(caminho);
    let dados = caminhos::arquivo_usuario(|| std::fs::read(origem))?;
    let material = certificado::carregar_pfx(&dados, senha)?;
    Ok((dados, material))
}

/// Importa um .pfx para o prestador: o arquivo INTEIRO e a senha dele vão para o banco cifrado.
/// Valida a senha abrindo o certificado antes de gravar. Devolve o nome do certificado.
pub fn import_certificate(prestador: &str, caminho_pfx: &str, senha: &str) -> Res<String> {
    if prestador.is_empty() {
        return Err(Erro::valor(
            "Selecione um prestador antes de importar o certificado.",
        ));
    }
    let (dados, material) = ler_pfx_do_arquivo(caminho_pfx, senha)?;
    // O documento do certificado deve ser compatível com o do prestador (CNPJ: mesma raiz).
    let cert_doc = doc_do_certificado(&certificado::titular(&material.cert_der)?);
    let alvo = only_doc(prestador);
    if !docs_compativeis(&cert_doc, &alvo) {
        return Err(Erro::valor(format!(
            "O certificado pertence ao documento {}, mas o prestador selecionado é {}. Para CNPJ, o certificado \
             precisa ser da MESMA raiz (8 primeiros caracteres); para CPF, do mesmo CPF.",
            format_documento(&cert_doc),
            format_documento(&alvo)
        )));
    }
    segredos::set_cert_pfx(prestador, &dados)?;
    segredos::set_cert_password(prestador, senha)?;
    Ok(prestador.to_string())
}

/// Importa o certificado de um PROCURADOR do prestador (quem tem procuração eletrônica dele na
/// Receita, ou o responsável legal com e-CPF). O documento do certificado tem de ser OUTRO: o do
/// próprio prestador vai em `import_certificate`. Quem confere a procuração é a SEFIN, no envio.
/// Devolve o nome do certificado.
pub fn import_certificate_procurador(
    prestador: &str,
    caminho_pfx: &str,
    senha: &str,
) -> Res<String> {
    if prestador.is_empty() {
        return Err(Erro::valor(
            "Selecione um prestador antes de importar o certificado.",
        ));
    }
    let (dados, material) = ler_pfx_do_arquivo(caminho_pfx, senha)?;
    let cert_doc = doc_do_certificado(&certificado::titular(&material.cert_der)?);
    if cert_doc.is_empty() {
        return Err(Erro::valor(
            "Não foi possível identificar o CPF/CNPJ do titular deste certificado.",
        ));
    }
    if docs_compativeis(&cert_doc, prestador) {
        return Err(Erro::valor(format!(
            "Este certificado é do próprio prestador ({}). Importe-o no cartão \"Certificado digital (A1)\".",
            format_documento(&cert_doc)
        )));
    }
    let nome = nome_cert_procurador(prestador, &cert_doc);
    segredos::set_cert_pfx(&nome, &dados)?;
    segredos::set_cert_password(&nome, senha)?;
    Ok(nome)
}

/// Abre um .pfx, valida a senha e devolve (documento, titular por extenso). Não grava nada.
pub fn inspect_certificate(caminho_pfx: &str, senha: &str) -> Res<(String, String)> {
    let (_, material) = ler_pfx_do_arquivo(caminho_pfx, senha)?;
    let t = certificado::titular(&material.cert_der)?;
    Ok((doc_do_certificado(&t), t.sujeito))
}

/// O material (chave + certificado) do prestador, aberto do banco.
pub fn material_do_prestador(
    prestador: &str,
    cert: Option<&str>,
) -> Res<Option<certificado::Material>> {
    let pfx = cert_pfx(prestador, cert)?;
    let Some(senha) = read_cert_password(prestador, cert)? else {
        return Ok(None);
    };
    if pfx.is_empty() {
        return Ok(None);
    }
    Ok(Some(certificado::carregar_pfx(&pfx, &senha)?))
}

/// Titular do certificado ativo, para exibir em Configurações ('' se indisponível).
pub fn cert_subject(prestador: &str, cert: Option<&str>) -> String {
    match material_do_prestador(prestador, cert) {
        Ok(Some(m)) => certificado::titular(&m.cert_der)
            .map(|t| t.sujeito)
            .unwrap_or_default(),
        _ => String::new(),
    }
}

fn iso_utc(segundos: i64) -> Value {
    match chrono::DateTime::from_timestamp(segundos, 0) {
        Some(d) => Value::String(d.format("%Y-%m-%dT%H:%M:%S+00:00").to_string()),
        None => Value::Null,
    }
}

/// Dados do certificado ativo para exibir em Configurações: titular, documento e validade
/// (vencimento + dias restantes). `ok` falso se não houver/abrir.
pub fn cert_info(prestador: &str, cert: Option<&str>) -> Res<Value> {
    let mut nome = cert_escolhido(prestador, cert)?;
    if !nome.is_empty() && !segredos::tem_cert_pfx(&nome)? {
        nome.clear(); // pedido pelo nome, mas não importado
    }
    let procurador = doc_do_procurador(&nome);
    let vazio = json!({
        "cert_name": nome, "subject": "", "titular": "", "documento": procurador,
        "not_before": null, "not_after": null, "dias_restantes": null, "ok": false,
        "procurador": !procurador.is_empty(),
    });
    if nome.is_empty() {
        return Ok(vazio);
    }
    let Ok(Some(m)) = material_do_prestador(prestador, Some(&nome)) else {
        return Ok(vazio);
    };
    let Ok(t) = certificado::titular(&m.cert_der) else {
        return Ok(vazio);
    };
    let agora = chrono::Utc::now();
    let resto = t.ate * 1_000_000 - agora.timestamp_micros();
    let dias = resto.div_euclid(86_400_000_000);
    let nome_titular = t.nome_comum.clone().unwrap_or_else(|| t.sujeito.clone());
    let nome_titular = aparar(nome_titular.split(':').next().unwrap_or("")).to_string();
    Ok(json!({
        "cert_name": nome,
        "subject": t.sujeito,
        "titular": nome_titular,
        "documento": doc_do_certificado(&t),
        "not_before": iso_utc(t.de),
        "not_after": iso_utc(t.ate),
        "dias_restantes": dias,
        "ok": true,
        "procurador": !procurador.is_empty(),
    }))
}

/// Os dados (`cert_info`) de cada certificado de procurador do prestador.
pub fn procuradores_info(prestador: &str) -> Res<Vec<Value>> {
    list_procuradores(prestador)?
        .iter()
        .map(|nome| cert_info(prestador, Some(nome)))
        .collect()
}

// ------------------------------------------------------------------------------- //
// Tributos do prestador
// ------------------------------------------------------------------------------- //
// Percentuais de tributos DO PRESTADOR: valem para todos os clientes e serviços dele; cada
// serviço pode usar outro (seção [gui.tributos] do serviço). (chave, seção oficial?, rótulo).
const TRIB_OFICIAIS: &str = "tags oficiais";
const TRIB_AUXILIARES: [&str; 2] = ["tags nao oficiais", "tags não oficiais"]; // os dois nomes que a emissão lê
pub const TRIBUTOS_PRESTADOR: [(&str, bool, &str); 7] = [
    ("pAliqPis", true, "PIS"),
    ("pAliqCofins", true, "COFINS"),
    ("irrf", false, "IRRF"),
    ("csll", false, "CSLL"),
    ("pTotTribFed", true, "Federal"),
    ("pTotTribEst", true, "Estadual"),
    ("pTotTribMun", true, "Municipal"),
];

fn trib_secao_auxiliar(cfg: &Ini) -> &'static str {
    TRIB_AUXILIARES
        .into_iter()
        .find(|s| cfg.tem_secao(s))
        .unwrap_or(TRIB_AUXILIARES[0])
}

/// Percentuais de tributos do prestador ('' = ainda não preenchido), como estão gravados, na
/// ordem da tela.
pub fn read_tributos(prestador: &str) -> Res<Vec<(String, String)>> {
    let cfg = ler(&config_tributos_file(prestador))?;
    let aux = trib_secao_auxiliar(&cfg);
    Ok(TRIBUTOS_PRESTADOR
        .iter()
        .map(|(chave, oficial, _)| {
            (
                chave.to_string(),
                cfg.val(if *oficial { TRIB_OFICIAIS } else { aux }, chave, ""),
            )
        })
        .collect())
}

/// Rótulos dos percentuais que o prestador ainda não preencheu (0 conta como preenchido).
pub fn tributos_faltando(prestador: &str) -> Res<Vec<String>> {
    let atual = read_tributos(prestador)?;
    Ok(TRIBUTOS_PRESTADOR
        .iter()
        .zip(&atual)
        .filter(|(_, (_, v))| aparar(v).is_empty())
        .map(|((_, _, rotulo), _)| rotulo.to_string())
        .collect())
}

/// Grava os percentuais de tributos do prestador. `valores`: {chave: texto}, com vírgula ou
/// ponto; '' deixa o percentual sem preencher. Erro com o que estiver errado (nada é gravado).
pub fn save_tributos(prestador: &str, valores: &Value) -> Res<Vec<(String, String)>> {
    let mut limpos: Vec<(&str, String)> = Vec::new();
    let mut erros: Vec<String> = Vec::new();
    for (chave, _, rotulo) in TRIBUTOS_PRESTADOR {
        let bruto = match valores.get(chave) {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Null) | None => String::new(),
            Some(outro) => outro.to_string(),
        };
        let bruto = aparar(&aparar(&bruto).replace('%', "")).to_string();
        if bruto.is_empty() {
            limpos.push((chave, String::new()));
        } else {
            match texto::decimal(&bruto) {
                Some(v) if (0.0..=100.0).contains(&v) => limpos.push((chave, norm_decimal(&bruto))),
                _ => erros.push(format!(
                    "Percentual de {rotulo} inválido (use um número de 0 a 100, ex.: 0,65)."
                )),
            }
        }
    }
    if !erros.is_empty() {
        return Err(Erro::valor(erros.join(" ")));
    }
    let caminho = config_tributos_file(prestador);
    let mut cfg = ler(&caminho)?; // o que mais houver ali continua como está
    let aux = trib_secao_auxiliar(&cfg);
    for ((chave, oficial, _), (_, valor)) in TRIBUTOS_PRESTADOR.iter().zip(&limpos) {
        cfg.por(if *oficial { TRIB_OFICIAIS } else { aux }, chave, valor);
    }
    banco::save_ini(&caminho, &cfg)?;
    read_tributos(prestador)
}

// ------------------------------------------------------------------------------- //
// Tomadores (clientes)
// ------------------------------------------------------------------------------- //
/// Identidade/endereço do cliente. Os serviços de cada cliente ficam separados, um por chave.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TipoContato {
    #[default]
    Telefone,
    Email,
    Outros,
}

impl TipoContato {
    fn nome(self) -> &'static str {
        match self {
            Self::Telefone => "telefone",
            Self::Email => "email",
            Self::Outros => "outros",
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct ContatoTomador {
    pub tipo: TipoContato,
    pub rotulo: String,
    pub valor: String,
    pub observacao: String,
    pub principal: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct TomadorForm {
    pub tipo_doc: String, // "CNPJ" ou "CPF"
    pub documento: String,
    pub IM: String,
    pub xNome: String,
    pub fone: String,
    pub email: String,
    pub telefones: Vec<String>,
    pub emails: Vec<String>,
    pub observacoes_telefones: Vec<String>,
    pub observacoes_emails: Vec<String>,
    pub telefone_principal: usize,
    pub email_principal: usize,
    pub ordem_contatos: Vec<String>,
    /// Ausente nos cadastros antigos; uma lista presente e vazia remove todos os contatos.
    pub contatos: Option<Vec<ContatoTomador>>,
    pub observacoes_gerais: String,
    pub cMun: String,
    pub CEP: String,
    pub xLgr: String,
    pub nro: String,
    pub xCpl: String,
    pub xBairro: String,
    // Cidade/UF de EXIBIÇÃO (o cMun continua sendo a chave oficial no XML): seção auxiliar
    // [gui.endereco], fora da árvore <dps> — não entram na emissão.
    pub xCidade: String,
    pub UF: String,
}

impl Default for TomadorForm {
    fn default() -> Self {
        TomadorForm {
            tipo_doc: "CNPJ".into(),
            documento: String::new(),
            IM: String::new(),
            xNome: String::new(),
            fone: String::new(),
            email: String::new(),
            telefones: Vec::new(),
            emails: Vec::new(),
            observacoes_telefones: Vec::new(),
            observacoes_emails: Vec::new(),
            telefone_principal: 0,
            email_principal: 0,
            ordem_contatos: Vec::new(),
            contatos: None,
            observacoes_gerais: String::new(),
            cMun: String::new(),
            CEP: String::new(),
            xLgr: String::new(),
            nro: String::new(),
            xCpl: String::new(),
            xBairro: String::new(),
            xCidade: String::new(),
            UF: String::new(),
        }
    }
}

/// Remove contatos vazios preservando a associação da observação e do principal.
fn contatos_normalizados(
    valores: &[String],
    legado: &str,
    observacoes: &[String],
    principal: usize,
    email: bool,
) -> (Vec<String>, Vec<String>, usize) {
    let origens: Vec<&str> = if valores.is_empty() {
        vec![legado]
    } else {
        valores.iter().map(String::as_str).collect()
    };
    let mut saida = Vec::new();
    let mut notas = Vec::new();
    let mut escolhido = 0;
    for (i, valor) in origens.into_iter().enumerate() {
        let limpo = if email {
            lower_email(valor)
        } else {
            only_digits(valor)
        };
        if limpo.is_empty() {
            continue;
        }
        if i == principal {
            escolhido = saida.len();
        }
        saida.push(limpo);
        notas.push(
            observacoes
                .get(i)
                .map(|s| aparar(s).to_owned())
                .unwrap_or_default(),
        );
    }
    (saida, notas, escolhido)
}

fn ordem_contatos(desejada: &[String], mut telefones: usize, mut emails: usize) -> Vec<String> {
    let mut ordem = Vec::with_capacity(telefones + emails);
    for tipo in desejada {
        match tipo.as_str() {
            "telefone" if telefones > 0 => {
                ordem.push(tipo.clone());
                telefones -= 1;
            }
            "email" if emails > 0 => {
                ordem.push(tipo.clone());
                emails -= 1;
            }
            _ => {}
        }
    }
    ordem.extend(std::iter::repeat_n("telefone".to_string(), telefones));
    ordem.extend(std::iter::repeat_n("email".to_string(), emails));
    ordem
}

impl TomadorForm {
    pub(crate) fn contatos_para_gravar(&self) -> Vec<ContatoTomador> {
        if let Some(contatos) = &self.contatos {
            let mut saida: Vec<_> = contatos
                .iter()
                .filter_map(|c| {
                    let valor = match c.tipo {
                        TipoContato::Telefone => only_digits(&c.valor),
                        TipoContato::Email => lower_email(&c.valor),
                        TipoContato::Outros => aparar(&c.valor).to_owned(),
                    };
                    if valor.is_empty() {
                        return None;
                    }
                    Some(ContatoTomador {
                        tipo: c.tipo,
                        rotulo: aparar(&c.rotulo).to_owned(),
                        valor,
                        observacao: aparar(&c.observacao).to_owned(),
                        principal: c.tipo != TipoContato::Outros && c.principal,
                    })
                })
                .collect();
            for tipo in [TipoContato::Telefone, TipoContato::Email] {
                let principal = saida
                    .iter()
                    .position(|c| c.tipo == tipo && c.principal)
                    .or_else(|| saida.iter().position(|c| c.tipo == tipo));
                for (i, c) in saida.iter_mut().enumerate().filter(|(_, c)| c.tipo == tipo) {
                    c.principal = Some(i) == principal;
                }
            }
            return saida;
        }
        // Migra o formato anterior preservando a ordem, observações e principais.
        let (fones, obs_fones, principal_fone) = contatos_normalizados(
            &self.telefones,
            &self.fone,
            &self.observacoes_telefones,
            self.telefone_principal,
            false,
        );
        let (emails, obs_emails, principal_email) = contatos_normalizados(
            &self.emails,
            &self.email,
            &self.observacoes_emails,
            self.email_principal,
            true,
        );
        let ordem = ordem_contatos(&self.ordem_contatos, fones.len(), emails.len());
        let criar = |tipo, valores: Vec<String>, notas: Vec<String>, principal| {
            valores
                .into_iter()
                .zip(notas)
                .enumerate()
                .map(move |(i, (valor, observacao))| ContatoTomador {
                    tipo,
                    valor,
                    observacao,
                    principal: i == principal,
                    ..Default::default()
                })
        };
        let mut fones = criar(TipoContato::Telefone, fones, obs_fones, principal_fone);
        let mut emails = criar(TipoContato::Email, emails, obs_emails, principal_email);
        ordem
            .iter()
            .filter_map(|tipo| {
                if tipo == "email" {
                    emails.next()
                } else {
                    fones.next()
                }
            })
            .collect()
    }

    pub fn validate(&self) -> Vec<String> {
        let mut erros = Vec::new();
        let doc = only_doc(&self.documento);
        if self.tipo_doc == "CNPJ" && doc.len() != 14 {
            erros.push("CNPJ deve ter 14 caracteres.".to_string());
        } else if self.tipo_doc == "CPF" && doc.len() != 11 {
            erros.push("CPF deve ter 11 dígitos.".to_string());
        } else if !documento_valido(&doc, &self.tipo_doc) {
            erros.push(format!(
                "{} inválido (dígitos verificadores não conferem) — revise o documento.",
                self.tipo_doc
            ));
        }
        if aparar(&self.xNome).is_empty() {
            erros.push("Nome/Razão social é obrigatório.".to_string());
        }
        if only_digits(&self.cMun).len() != 7 {
            erros.push("Código do município (cMun) deve ter 7 dígitos IBGE.".to_string());
        }
        if self.contatos.as_ref().is_some_and(|contatos| {
            contatos.iter().any(|c| {
                c.tipo == TipoContato::Outros
                    && !aparar(&c.valor).is_empty()
                    && aparar(&c.rotulo).is_empty()
            })
        }) {
            erros.push("Informe o nome do contato personalizado.".into());
        }
        erros
    }

    /// Seções de identidade do cadastro do cliente.
    pub fn to_sections(&self) -> Secoes {
        let contatos = self.contatos_para_gravar();
        let fones: Vec<_> = contatos
            .iter()
            .filter(|c| c.tipo == TipoContato::Telefone)
            .collect();
        let correios: Vec<_> = contatos
            .iter()
            .filter(|c| c.tipo == TipoContato::Email)
            .collect();
        let telefones: Vec<_> = fones.iter().map(|c| c.valor.clone()).collect();
        let emails: Vec<_> = correios.iter().map(|c| c.valor.clone()).collect();
        let obs_telefones: Vec<_> = fones.iter().map(|c| &c.observacao).collect();
        let obs_emails: Vec<_> = correios.iter().map(|c| &c.observacao).collect();
        let telefone_principal = fones.iter().position(|c| c.principal).unwrap_or(0);
        let email_principal = correios.iter().position(|c| c.principal).unwrap_or(0);
        let doc = only_doc(&self.documento);
        let ident = if self.tipo_doc == "CNPJ" {
            par("CNPJ", doc)
        } else {
            par("CPF", doc)
        };
        vec![
            (
                "toma".into(),
                vec![
                    ident,
                    par("IM", upper_text(&self.IM)),
                    par("xNome", upper_text(&self.xNome)),
                    par(
                        "fone",
                        telefones
                            .get(telefone_principal)
                            .cloned()
                            .unwrap_or_default(),
                    ),
                    par(
                        "email",
                        emails.get(email_principal).cloned().unwrap_or_default(),
                    ),
                ],
            ),
            (
                "toma.end.endNac".into(),
                vec![
                    par("cMun", only_digits(&self.cMun)),
                    par("CEP", only_digits(&self.CEP)),
                ],
            ),
            (
                "toma.end".into(),
                vec![
                    par("xLgr", upper_text(&self.xLgr)),
                    par("nro", upper_text(&self.nro)),
                    par("xCpl", upper_text(&self.xCpl)),
                    par("xBairro", upper_text(&self.xBairro)),
                ],
            ),
            (
                "gui.contatos".into(),
                vec![
                    par(
                        "itens",
                        serde_json::to_string(&contatos).unwrap_or_default(),
                    ),
                    par(
                        "telefones",
                        serde_json::to_string(&telefones).unwrap_or_default(),
                    ),
                    par("emails", serde_json::to_string(&emails).unwrap_or_default()),
                    par(
                        "observacoes_telefones",
                        serde_json::to_string(&obs_telefones).unwrap_or_default(),
                    ),
                    par(
                        "observacoes_emails",
                        serde_json::to_string(&obs_emails).unwrap_or_default(),
                    ),
                    par("telefone_principal", telefone_principal.to_string()),
                    par("email_principal", email_principal.to_string()),
                    par(
                        "ordem",
                        serde_json::to_string(
                            &contatos.iter().map(|c| c.tipo.nome()).collect::<Vec<_>>(),
                        )
                        .unwrap_or_default(),
                    ),
                    par("observacoes_gerais", self.observacoes_gerais.clone()),
                ],
            ),
            (
                "gui.endereco".into(),
                vec![
                    par("xCidade", upper_text(&self.xCidade)),
                    par("UF", upper_text(&self.UF)),
                ],
            ),
        ]
    }

    pub fn from_config(ini: &Ini) -> TomadorForm {
        let cnpj = ini.val("toma", "CNPJ", "");
        let cpf = ini.val("toma", "CPF", "");
        let tipo = if !cpf.is_empty() && cnpj.is_empty() {
            "CPF"
        } else {
            "CNPJ"
        };
        TomadorForm {
            tipo_doc: tipo.into(),
            documento: if cnpj.is_empty() { cpf } else { cnpj },
            IM: ini.val("toma", "IM", ""),
            xNome: ini.val("toma", "xNome", ""),
            fone: ini.val("toma", "fone", ""),
            email: ini.val("toma", "email", ""),
            telefones: serde_json::from_str(&ini.val("gui.contatos", "telefones", "[]"))
                .unwrap_or_default(),
            emails: serde_json::from_str(&ini.val("gui.contatos", "emails", "[]"))
                .unwrap_or_default(),
            observacoes_telefones: serde_json::from_str(&ini.val(
                "gui.contatos",
                "observacoes_telefones",
                "[]",
            ))
            .unwrap_or_default(),
            observacoes_emails: serde_json::from_str(&ini.val(
                "gui.contatos",
                "observacoes_emails",
                "[]",
            ))
            .unwrap_or_default(),
            telefone_principal: ini
                .val("gui.contatos", "telefone_principal", "0")
                .parse()
                .unwrap_or(0),
            email_principal: ini
                .val("gui.contatos", "email_principal", "0")
                .parse()
                .unwrap_or(0),
            cMun: ini.val("toma.end.endNac", "cMun", ""),
            ordem_contatos: serde_json::from_str(&ini.val("gui.contatos", "ordem", "[]"))
                .unwrap_or_default(),
            contatos: serde_json::from_str(&ini.val("gui.contatos", "itens", "")).ok(),
            observacoes_gerais: ini.val("gui.contatos", "observacoes_gerais", ""),
            CEP: ini.val("toma.end.endNac", "CEP", ""),
            xLgr: ini.val("toma.end", "xLgr", ""),
            nro: ini.val("toma.end", "nro", ""),
            xCpl: ini.val("toma.end", "xCpl", ""),
            xBairro: ini.val("toma.end", "xBairro", ""),
            xCidade: ini.val("gui.endereco", "xCidade", ""),
            UF: ini.val("gui.endereco", "UF", ""),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct TomadorInfo {
    pub documento: String,
    pub xNome: String,
    pub display: String,
}

/// Clientes CADASTRADOS, em ordem de nome. Excluir um cliente remove o cadastro (some daqui),
/// mas as notas já emitidas para ele continuam no banco de notas.
pub fn list_tomadores(prestador: &str) -> Res<Vec<TomadorInfo>> {
    let base = format!("{}/tomador", prestador_dir(prestador));
    let nomes = banco::read_option_many(&base, "config_tomador.ini", "toma", "xNome")?;
    let mut out = Vec::new();
    for chave in banco::list_keys(&base, "config_tomador.ini")? {
        let x_nome = nomes
            .iter()
            .find(|(k, _)| *k == chave)
            .map(|(_, v)| aparar(v).to_string())
            .unwrap_or_default();
        let documento = pasta_de(&chave);
        let display = format!(
            "{} — {}",
            if x_nome.is_empty() {
                "Sem nome"
            } else {
                &x_nome
            },
            format_documento(&documento)
        );
        out.push(TomadorInfo {
            documento,
            xNome: x_nome,
            display,
        });
    }
    out.sort_by_cached_key(|t| {
        let n = sort_nome(&t.xNome);
        (
            if n.is_empty() { "~".to_string() } else { n },
            t.documento.clone(),
        )
    });
    Ok(out)
}

/// Exclui o CADASTRO do cliente (identidade + serviços + vínculo de grupo). As notas já
/// Contatos em lote para a tabela de clientes, sem abrir um banco por cliente.
pub fn contatos_tomadores(prestador: &str) -> Res<Vec<(String, String, String)>> {
    let base = format!("{}/tomador", prestador_dir(prestador));
    let fones = banco::read_option_many(&base, "config_tomador.ini", "toma", "fone")?;
    let emails = banco::read_option_many(&base, "config_tomador.ini", "toma", "email")?;
    let varios_fones =
        banco::read_option_many(&base, "config_tomador.ini", "gui.contatos", "telefones")?;
    let varios_emails =
        banco::read_option_many(&base, "config_tomador.ini", "gui.contatos", "emails")?;
    let juntar = |lista: &Vec<(String, String)>, chave: &str| -> String {
        lista
            .iter()
            .find(|(k, _)| k == chave)
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    };
    let contato = |varios: String, unico: String| -> String {
        let lista: Vec<String> = serde_json::from_str(&varios).unwrap_or_default();
        if lista.is_empty() {
            unico
        } else {
            lista.join("; ")
        }
    };
    Ok(banco::list_keys(&base, "config_tomador.ini")?
        .iter()
        .map(|chave| {
            (
                pasta_de(chave),
                contato(juntar(&varios_fones, chave), juntar(&fones, chave)),
                contato(juntar(&varios_emails, chave), juntar(&emails, chave)),
            )
        })
        .collect())
}

/// Exclui o CADASTRO do cliente (identidade + serviços + vínculo de grupo). As notas já
/// emitidas para ele permanecem no banco de notas.
pub fn delete_tomador(prestador: &str, tomador: &str) -> Res<()> {
    let doc = only_doc(tomador);
    banco::delete_ini(&config_tomador_file(prestador, &doc))?;
    banco::delete_prefix(&servicos_dir(prestador, &doc))?;
    set_tomador_grupo(prestador, &doc, "")
}

/// O cliente tem cadastro?
pub fn tomador_cadastrado(prestador: &str, tomador: &str) -> Res<bool> {
    banco::exists_ini(&config_tomador_file(prestador, &only_doc(tomador)))
}

pub fn get_tomador_form(prestador: &str, tomador: &str) -> Res<TomadorForm> {
    Ok(TomadorForm::from_config(&ler(&config_tomador_file(
        prestador, tomador,
    ))?))
}

/// Cria/atualiza o cadastro do cliente (só identidade). Devolve a chave gravada.
pub fn save_tomador_form(prestador: &str, form: &TomadorForm) -> Res<String> {
    let erros = form.validate();
    if !erros.is_empty() {
        return Err(lista_de_erros("Cadastro inválido", &erros));
    }
    let caminho = config_tomador_file(prestador, &only_doc(&form.documento));
    gravar_secoes(&caminho, &form.to_sections())?;
    Ok(caminho)
}

// ------------------------------------------------------------------------------- //
// Serviços do cliente
// ------------------------------------------------------------------------------- //
/// Parcela do aluguel que não entra na base do IBS/CBS (IPTU, condomínio…), por unidade.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct AjusteDaLocacao {
    /// 01 tributos, 02 emolumento, 03 condomínio, 04 redutor social, 99 outras.
    pub tipo: String,
    /// Só quando o tipo é 99.
    pub descricao: String,
    pub valor: String,
}

/// Uma unidade imobiliária da locação, identificada pelo código CIB OU pelo endereço.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct UnidadeImob {
    pub inscImobFisc: String,
    pub cCIB: String,
    pub CEP: String,
    pub xLgr: String,
    pub nro: String,
    pub xCpl: String,
    pub xBairro: String,
    pub ajustes: Vec<AjusteDaLocacao>,
}

impl UnidadeImob {
    fn tem_endereco(&self) -> bool {
        [&self.CEP, &self.xLgr, &self.nro, &self.xCpl, &self.xBairro]
            .iter()
            .any(|v| !aparar(v).is_empty())
    }
}

/// Um bem móvel locado.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct BemMovel {
    pub ncm: String,
    pub descricao: String,
    pub quantidade: String,
}

/// Um item do detalhamento (opcional) de uma cobrança do condomínio: energia, água, IPTU…
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct DetalheDaCobranca {
    /// 001 a 036 ou 999 (outro): ver `TIPOS_DE_DETALHE`.
    pub tipo: String,
    /// Só quando o tipo é 999.
    pub descricao: String,
    pub valor: String,
}

/// Uma cobrança do condomínio (taxa ordinária, fundo de reserva…). A soma delas é o valor da nota.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct CobrancaDoCondominio {
    /// 01 ordinário, 02 privativo, 03 fundo de promoção, 04 impostos e taxas, 05 fundo de reserva, 99 outra.
    pub tipo: String,
    /// Só quando o tipo é 99.
    pub descricao: String,
    /// Com detalhamento, o valor da cobrança é a soma dos itens dele.
    pub valor: String,
    pub detalhes: Vec<DetalheDaCobranca>,
}

impl CobrancaDoCondominio {
    /// O valor da cobrança, em texto decimal: a soma do detalhamento, se houver; senão o digitado.
    fn valor_efetivo(&self) -> String {
        if self.detalhes.is_empty() {
            return norm_decimal(&self.valor);
        }
        format!("{:.2}", soma(self.detalhes.iter().map(|d| d.valor.clone())))
    }
}

/// Tipos de detalhamento de cobrança (tpDetCobranca; planilha oficial AnexoVI v1.04.01 da NT 009).
pub const TIPOS_DE_DETALHE: [(&str, &str); 37] = [
    ("001", "Cond. Comum CRD"),
    ("002", "Cond. Comum M2"),
    ("003", "Cond. Comum Fixo"),
    ("004", "Cond. Comum Fração"),
    ("005", "Cond. Comum Percentual"),
    ("006", "Condomínio CMM"),
    ("007", "Energia Elétrica"),
    ("008", "Água"),
    ("009", "Ar Condicionado"),
    ("010", "Telefone"),
    ("011", "Internet"),
    ("012", "Controle de Pragas"),
    ("013", "Exaustão"),
    ("014", "Gás"),
    ("015", "IPTU"),
    ("016", "Taxa Área"),
    ("017", "Manutenção"),
    ("018", "Multa"),
    ("019", "Seguro"),
    ("020", "Taxa Bombeiro"),
    ("021", "Taxa Administração"),
    ("022", "Taxa Foro"),
    ("023", "Limpeza"),
    ("024", "Taxa de Lixo"),
    ("025", "Tapume"),
    ("026", "Instalação Alarme"),
    ("027", "Segurança"),
    ("028", "Fundo de Promoção e Propaganda"),
    ("029", "Análise de Projeto"),
    ("030", "Fundo de Reserva"),
    ("031", "Laudos e Vistorias"),
    ("032", "Detecção de Fumaça"),
    ("033", "Reanálise de Projeto"),
    ("034", "Taxa Extra"),
    ("035", "Área Vaga"),
    ("036", "Condomínio Irrecuperável"),
    ("999", "Outro"),
];

/// Os tipos de cobrança (tpCobranca), na ordem da planilha.
const TIPOS_DE_COBRANCA: [&str; 6] = ["01", "02", "03", "04", "05", "99"];

/// Os tipos de detalhamento que cada tipo de cobrança admite (mesma planilha); a cobrança
/// "99 - outra" admite todos.
pub fn detalhes_admitidos(tipo_da_cobranca: &str) -> Vec<&'static str> {
    let lista: &[&str] = match tipo_da_cobranca {
        "01" => &[
            "001", "002", "003", "004", "005", "006", "018", "035", "036", "999",
        ],
        "02" => &[
            "007", "008", "009", "010", "011", "012", "013", "014", "017", "018", "019", "023",
            "025", "026", "027", "029", "031", "032", "033", "034", "999",
        ],
        "03" => &["018", "028", "999"],
        "04" => &["015", "016", "020", "021", "022", "024", "999"],
        "05" => &["018", "030", "999"],
        "99" => return TIPOS_DE_DETALHE.iter().map(|(codigo, _)| *codigo).collect(),
        _ => &[],
    };
    lista.to_vec()
}

/// Para a tela montar as listas do detalhamento: os tipos (código, rótulo) e, por tipo de
/// cobrança, os códigos admitidos.
pub fn detalhes_de_cobranca() -> Value {
    let admitidos: serde_json::Map<String, Value> = TIPOS_DE_COBRANCA
        .iter()
        .map(|t| (t.to_string(), json!(detalhes_admitidos(t))))
        .collect();
    json!({
        "tipos": TIPOS_DE_DETALHE.iter().map(|(codigo, nome)| [codigo.to_string(), format!("{codigo} - {nome}")]).collect::<Vec<_>>(),
        "admitidos": admitidos,
    })
}

/// Um desconto do condomínio: 1 incondicionado, 2 condicionado. A descrição é obrigatória.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct DescontoDoCondominio {
    pub tipo: String,
    pub descricao: String,
    pub valor: String,
}

/// A data (AAAA-MM-DD) de um campo obrigatório: `None` se vazia ou inválida.
fn parse_iso_date_ok(valor: &str) -> Option<NaiveDate> {
    crate::texto::parse_iso_date(aparar(valor))
}

fn soma(valores: impl Iterator<Item = String>) -> f64 {
    valores
        .filter_map(|v| norm_decimal(&v).parse::<f64>().ok())
        .sum()
}

/// Um serviço do cliente: dados do serviço + tributação. Cada serviço é um "pacote" distinto;
/// na emissão o usuário escolhe qual usar.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct ServicoForm {
    pub nome: String,
    pub cLocPrestacao: String,
    pub cTribNac: String,
    pub cTribMun: String,
    pub xDescServ: String,
    pub cNBS: String,
    // Intermediário nacional da operação (ex.: imobiliária administradora), distinto do tomador.
    pub interm_tipo: String,
    pub interm_documento: String,
    pub interm_xNome: String,
    pub interm_IM: String,
    // Grupo IBS/CBS da DPS. Vazio preserva cadastros anteriores até a classificação fiscal ser
    // escolhida; o código da classificação nunca é presumido pelo sistema.
    pub rtc_plataforma_digital: bool,
    pub rtc_indDest: String,
    pub rtc_cIndOp: String,
    pub rtc_CST: String,
    pub rtc_cClassTrib: String,
    pub dest_tipo: String,
    pub dest_documento: String,
    pub dest_xNome: String,
    pub dest_cMun: String,
    pub dest_CEP: String,
    pub dest_xLgr: String,
    pub dest_nro: String,
    pub dest_xCpl: String,
    pub dest_xBairro: String,
    pub vServ: String,
    pub tribISSQN: String,
    pub tpRetISSQN: String,
    // PIS/COFINS — Situação Tributária (CST) e Tipo de retenção
    pub pis_CST: String,
    pub tpRetPisCofins: String,
    // "Incluir contribuições sociais (PIS + COFINS + CSLL)": "0" omite o vRetCSLL da emissão.
    pub incluir_contrib: String,
    // As retenções (IRRF e CSLL/PIS/COFINS) com desconto incondicionado na nota: "1" = sobre o
    // montante a pagar, já sem o desconto (Lei 10.833/2003, art. 31); "0" = sobre o valor cheio do
    // serviço, para o tomador que retém assim. Sem desconto, tanto faz.
    pub ret_abate_desconto: String,
    // Percentuais próprios do serviço ("" = herdar dos tributos do prestador).
    pub ov_pAliqPis: String,
    pub ov_pAliqCofins: String,
    pub ov_pIRRF: String,
    pub ov_pCSLL: String,
    pub ov_pTotTribFed: String,
    pub ov_pTotTribEst: String,
    pub ov_pTotTribMun: String,
    // CST=00 (só retenção): valores diretos em R$ ("" = omitir do XML).
    pub vRetIRRF_manual: String,
    pub vRetCSLL_manual: String,
    // Locação, cessão onerosa ou arrendamento de IMÓVEL (cTribNac 99.03.xx) — só no leiaute novo
    // da NFS-e (ver `leiaute`). O valor total do aluguel não é guardado: sai do valor da nota e do
    // percentual de copropriedade, na config final.
    pub loc_cMun: String,
    pub loc_pCopropriedade: String,
    pub loc_dVencOrig: String,
    pub venc_automatico: bool,
    pub venc_dia: u32,
    pub venc_meses: u32,
    pub loc_unidades: Vec<UnidadeImob>,
    // Locação de BENS MÓVEIS (cTribNac 99.04.01) — também só no leiaute novo.
    pub bens_moveis: Vec<BemMovel>,
    // CONDOMÍNIO (cTribNac 99.05.01) — também só no leiaute novo. O imóvel usa `loc_cMun` e
    // `loc_unidades`; o valor da nota e os descontos saem das listas abaixo.
    pub cond_dVencOrig: String,
    pub cond_cobrancas: Vec<CobrancaDoCondominio>,
    pub cond_descontos: Vec<DescontoDoCondominio>,
    // Descontos da nota, em R$ ("" = sem desconto). Como o valor, são informados a cada emissão.
    // O incondicionado reduz as bases de cálculo; o condicionado, só o valor líquido.
    pub vDescIncond: String,
    pub vDescCond: String,
    /// CPF/CNPJ do procurador cujo certificado assina as notas deste serviço ("" = o certificado
    /// próprio do prestador). Escolhido na tela Emitir e lembrado para as próximas notas.
    pub cert_procurador: String,
}

impl Default for ServicoForm {
    fn default() -> Self {
        let v = String::new;
        ServicoForm {
            nome: "Serviço 1".into(),
            cLocPrestacao: v(),
            cTribNac: v(),
            cTribMun: v(),
            xDescServ: v(),
            cNBS: v(),
            interm_tipo: "CNPJ".into(),
            interm_documento: v(),
            interm_xNome: v(),
            interm_IM: v(),
            rtc_plataforma_digital: false,
            rtc_indDest: v(),
            rtc_cIndOp: v(),
            rtc_CST: v(),
            rtc_cClassTrib: v(),
            loc_cMun: v(),
            loc_pCopropriedade: v(),
            loc_dVencOrig: v(),
            venc_automatico: false,
            venc_dia: 10,
            venc_meses: 1,
            loc_unidades: Vec::new(),
            bens_moveis: Vec::new(),
            cond_dVencOrig: v(),
            cond_cobrancas: Vec::new(),
            cond_descontos: Vec::new(),
            vDescIncond: v(),
            vDescCond: v(),
            cert_procurador: v(),
            dest_tipo: "CNPJ".into(),
            dest_documento: v(),
            dest_xNome: v(),
            dest_cMun: v(),
            dest_CEP: v(),
            dest_xLgr: v(),
            dest_nro: v(),
            dest_xCpl: v(),
            dest_xBairro: v(),
            vServ: v(),
            tribISSQN: "1".into(),
            tpRetISSQN: "1".into(),
            pis_CST: "01".into(),
            tpRetPisCofins: "3".into(),
            incluir_contrib: "1".into(),
            ret_abate_desconto: "1".into(),
            ov_pAliqPis: v(),
            ov_pAliqCofins: v(),
            ov_pIRRF: v(),
            ov_pCSLL: v(),
            ov_pTotTribFed: v(),
            ov_pTotTribEst: v(),
            ov_pTotTribMun: v(),
            vRetIRRF_manual: v(),
            vRetCSLL_manual: v(),
        }
    }
}

impl ServicoForm {
    fn tem_intermediario(&self) -> bool {
        [&self.interm_documento, &self.interm_xNome, &self.interm_IM]
            .iter()
            .any(|v| !aparar(v).is_empty())
    }

    pub fn tem_rtc(&self) -> bool {
        [
            &self.rtc_indDest,
            &self.rtc_cIndOp,
            &self.rtc_CST,
            &self.rtc_cClassTrib,
        ]
        .iter()
        .any(|v| !v.is_empty())
    }

    fn endereco_do_destinatario(&self) -> [&String; 6] {
        [
            &self.dest_cMun,
            &self.dest_CEP,
            &self.dest_xLgr,
            &self.dest_nro,
            &self.dest_xCpl,
            &self.dest_xBairro,
        ]
    }

    /// Regras que dependem do documento do prestador, fora do cadastro do serviço.
    pub fn problemas_com_o_prestador(&self, prestador: &str) -> Vec<String> {
        let mut p = Vec::new();
        let (interm, prest) = (only_doc(&self.interm_documento), only_doc(prestador));
        let mesma_pessoa = match (interm.len(), prest.len()) {
            (14, 14) => interm[..8] == prest[..8],
            _ => !interm.is_empty() && interm == prest,
        };
        if self.tem_intermediario() && mesma_pessoa {
            p.push("Intermediário: não pode ser o próprio prestador nem outro estabelecimento com a mesma raiz de CNPJ (E0262). Numa locação, informe aqui a imobiliária, não o locador.".into());
        }
        p
    }

    pub fn validate(&self, require_rtc: bool) -> Vec<String> {
        let mut erros: Vec<String> = Vec::new();
        let mut erro = |m: &str| erros.push(m.to_string());
        if self.venc_automatico && (!(1..=31).contains(&self.venc_dia) || self.venc_meses > 12) {
            erro(
                "Configuração de vencimento inválida: dia de 1 a 31 e mês de 0 a 12 meses após a competência.",
            );
        }
        if aparar(&self.nome).is_empty() {
            erro("Nome do serviço é obrigatório.");
        }
        if only_digits(&self.cLocPrestacao).is_empty() {
            erro("Código do local de prestação é obrigatório.");
        }
        let trib_nac = only_digits(&self.cTribNac);
        if trib_nac.len() != 6 {
            erro("Código de tributação nacional (cTribNac) deve ter 6 dígitos.");
        } else if !catalogo::valid_tribnac(&trib_nac) {
            erro("Código de tributação nacional (cTribNac) fora da lista de produção.");
        }
        if aparar(&self.xDescServ).is_empty() {
            erro("Descrição do serviço é obrigatória.");
        } else {
            for p in descricao_problemas(&self.xDescServ) {
                erro(&p);
            }
        }
        let nbs = only_digits(&self.cNBS);
        if !nbs.is_empty() && (nbs.len() != 9 || !catalogo::valid_nbs(&nbs)) {
            erro("Item NBS fora da lista de produção.");
        }
        let trib_mun = aparar(&self.cTribMun);
        if !trib_mun.is_empty()
            && (trib_mun.len() != 3
                || !trib_mun.bytes().all(|b| b.is_ascii_digit())
                || trib_mun == "000")
        {
            erro(
                "cTribMun: informe o complemento municipal de 3 dígitos fornecido pela prefeitura ou deixe em branco. Não use 000 (E0315).",
            );
        }
        if ![
            "00", "01", "02", "04", "05", "06", "07", "08", "09", "49", "99",
        ]
        .contains(&self.pis_CST.as_str())
        {
            erro("Selecione uma situação tributária válida para PIS/COFINS.");
        }
        if !(self.tpRetPisCofins.len() == 1
            && self.tpRetPisCofins.bytes().all(|b| b.is_ascii_digit()))
        {
            erro("Selecione um tipo de retenção válido para PIS/COFINS/CSLL.");
        }
        if !["1", "2", "3", "4"].contains(&self.tribISSQN.as_str()) {
            erro("Selecione uma tributação válida do ISSQN.");
        }
        if !["1", "2", "3"].contains(&self.tpRetISSQN.as_str()) {
            erro("Selecione uma retenção válida do ISSQN.");
        }
        if self.tem_intermediario() {
            let doc = only_doc(&self.interm_documento);
            let valido = match self.interm_tipo.as_str() {
                "CPF" => cpf_valido(&doc),
                "CNPJ" => cnpj_valido(&doc),
                _ => false,
            };
            if !valido {
                erro("Intermediário: informe CPF ou CNPJ válido.");
            }
            if aparar(&self.interm_xNome).is_empty() || self.interm_xNome.chars().count() > 150 {
                erro("Intermediário: informe o nome ou razão social (até 150 caracteres).");
            }
            if self.interm_IM.chars().count() > 15 {
                erro("Intermediário: a inscrição municipal deve ter até 15 caracteres.");
            }
        }
        if trib_nac.starts_with("99") && self.tribISSQN != "4" {
            erro("Operações 99.xx.xx: selecione ISSQN 4 - Não Incidência (E0532).");
        }
        if ["2", "3", "4"].contains(&self.tribISSQN.as_str()) && self.tpRetISSQN != "1" {
            erro("ISSQN sem incidência, imune ou exportação: não pode haver retenção (E0580).");
        }
        // Locação só existe como operação do IBS/CBS: o grupo é sempre exigido.
        if require_rtc || self.tem_rtc() || leiaute::so_no_novo(&trib_nac) {
            if !["0", "1"].contains(&self.rtc_indDest.as_str()) {
                erro("IBS/CBS: indique se o destinatário é o próprio adquirente.");
            }
            if !catalogo::valid_indop(&self.rtc_cIndOp) {
                erro("IBS/CBS: selecione um código indicador da operação válido.");
            }
            if !catalogo::valid_classification(&self.rtc_CST, &self.rtc_cClassTrib) {
                erro("IBS/CBS: selecione CST e classificação tributária compatíveis com NFS-e.");
            }
            if nbs.len() != 9 {
                erro("IBS/CBS: informe o item NBS de 9 dígitos do serviço.");
            }
            if self.rtc_indDest == "1" {
                let doc = only_doc(&self.dest_documento);
                if self.dest_tipo == "CPF" {
                    if !cpf_valido(&doc) {
                        erro("Destinatário IBS/CBS: CPF inválido.");
                    }
                } else if self.dest_tipo == "CNPJ" {
                    if !cnpj_valido(&doc) {
                        erro("Destinatário IBS/CBS: CNPJ inválido.");
                    }
                } else {
                    erro("Destinatário IBS/CBS: escolha CPF ou CNPJ.");
                }
                if aparar(&self.dest_xNome).is_empty() {
                    erro("Destinatário IBS/CBS: informe o nome.");
                }
                if self
                    .endereco_do_destinatario()
                    .iter()
                    .any(|v| !v.is_empty())
                    && (only_digits(&self.dest_cMun).len() != 7
                        || only_digits(&self.dest_CEP).len() != 8
                        || aparar(&self.dest_xLgr).is_empty()
                        || aparar(&self.dest_nro).is_empty()
                        || aparar(&self.dest_xBairro).is_empty())
                {
                    erro(
                        "Destinatário IBS/CBS: complete município, CEP, logradouro, número e bairro.",
                    );
                }
            }
        }
        if leiaute::e_imovel(&trib_nac) {
            for p in self.problemas_da_locacao(&nbs) {
                erro(&p);
            }
        }
        if leiaute::e_bem_movel(&trib_nac) {
            for p in self.problemas_dos_bens_moveis() {
                erro(&p);
            }
        }
        if leiaute::e_condominio(&trib_nac) {
            for p in self.problemas_do_condominio() {
                erro(&p);
            }
        }
        for p in self.problemas_dos_descontos() {
            erro(&p);
        }
        // vServ é OPCIONAL no cadastro (o valor é digitado na tela Emitir); se veio, valida.
        if !aparar(&self.vServ).is_empty() && !is_decimal(&self.vServ) {
            erro("Valor do serviço (vServ) deve ser decimal, ex.: 2160.00.");
        }
        for (rotulo, valor) in [
            ("PIS", &self.ov_pAliqPis),
            ("COFINS", &self.ov_pAliqCofins),
            ("IRRF", &self.ov_pIRRF),
            ("CSLL", &self.ov_pCSLL),
            ("Federal", &self.ov_pTotTribFed),
            ("Estadual", &self.ov_pTotTribEst),
            ("Municipal", &self.ov_pTotTribMun),
        ] {
            if !aparar(valor).is_empty() && !is_decimal(valor) {
                erro(&format!(
                    "Percentual de {rotulo} inválido (use número, ex.: 0,65)."
                ));
            }
        }
        if aparar(&self.pis_CST) == "00" {
            for (rotulo, valor) in [
                ("IRRF (R$)", &self.vRetIRRF_manual),
                ("Contribuições Sociais Retidas (R$)", &self.vRetCSLL_manual),
            ] {
                if !aparar(valor).is_empty() && !is_decimal(valor) {
                    erro(&format!("{rotulo}: valor inválido."));
                }
            }
        }
        erros
    }

    /// O valor da nota e os descontos (incondicionado, condicionado), em texto decimal ("" = não
    /// há). No condomínio saem das listas de cobranças e descontos; nas outras notas, do que foi
    /// digitado.
    fn valores_da_nota(&self) -> (String, String, String) {
        if !leiaute::e_condominio(&self.cTribNac) {
            return (
                norm_decimal(&self.vServ),
                norm_decimal(&self.vDescIncond),
                norm_decimal(&self.vDescCond),
            );
        }
        let dinheiro = |v: f64| {
            if v > 0.0 {
                format!("{v:.2}")
            } else {
                String::new()
            }
        };
        let desconto = |tipo: &str| {
            soma(
                self.cond_descontos
                    .iter()
                    .filter(|d| d.tipo == tipo)
                    .map(|d| d.valor.clone()),
            )
        };
        (
            dinheiro(soma(self.cond_cobrancas.iter().map(|c| c.valor_efetivo()))),
            dinheiro(desconto("1")),
            dinheiro(desconto("2")),
        )
    }

    /// Regras da SEFIN para os descontos: maiores que zero e menores que o valor do serviço.
    fn problemas_dos_descontos(&self) -> Vec<String> {
        let mut p: Vec<String> = Vec::new();
        let (servico, incondicionado, condicionado) = self.valores_da_nota();
        let servico = servico.parse::<f64>().ok();
        let mut total = 0.0;
        for (rotulo, bruto, valor) in [
            ("incondicionado", &self.vDescIncond, incondicionado),
            ("condicionado", &self.vDescCond, condicionado),
        ] {
            if valor.is_empty() && aparar(bruto).is_empty() {
                continue;
            }
            match valor.parse::<f64>() {
                Ok(v) if v > 0.0 => {
                    total += v;
                    if servico.is_some_and(|s| v >= s) {
                        p.push(format!(
                            "Desconto {rotulo}: deve ser menor que o valor do serviço."
                        ));
                    }
                }
                Ok(v) if v == 0.0 => {}
                _ => p.push(format!(
                    "Desconto {rotulo}: valor inválido (use número, ex.: 150,00)."
                )),
            }
        }
        if servico.is_some_and(|s| total > 0.0 && total >= s) {
            p.push("Descontos: a soma deve ser menor que o valor do serviço.".into());
        }
        p
    }

    /// Regras da SEFIN para o imóvel (município e unidades), comuns à locação e ao condomínio.
    fn problemas_do_imovel(&self, de: &str, nbs: &str, com_parcelas: bool) -> Vec<String> {
        let mut p: Vec<String> = Vec::new();
        if !self.rtc_cIndOp.starts_with("02") {
            p.push(format!(
                "{de}: o indicador da operação deve ser um dos 02xxxx (operação com bem imóvel)."
            ));
        }
        if only_digits(&self.loc_cMun).len() != 7 {
            p.push(format!("{de}: informe o município do imóvel."));
        }
        if ["020101", "020201", "020301"].contains(&self.rtc_cIndOp.as_str())
            && self.loc_unidades.is_empty()
        {
            p.push(format!("{de}: informe ao menos uma unidade imobiliária."));
        }
        if self.loc_unidades.len() > 99 {
            p.push(format!(
                "{de}: no máximo 99 unidades imobiliárias por nota."
            ));
        }
        for (i, u) in self.loc_unidades.iter().enumerate() {
            let n = i + 1;
            let cib = aparar(&u.cCIB);
            match (cib.is_empty(), u.tem_endereco()) {
                (true, false) => p.push(format!(
                    "Unidade {n}: informe o código CIB ou o endereço do imóvel."
                )),
                (false, true) => p.push(format!(
                    "Unidade {n}: informe o código CIB ou o endereço, não os dois."
                )),
                (false, false) => {
                    if !crate::texto::cib_valido(cib) {
                        p.push(format!(
                            "Unidade {n}: código CIB inválido. Ele tem 7 caracteres e o dígito verificador (ex.: A3N8Z4F-Y); confira no Sinter (E0933)."
                        ));
                    }
                }
                (true, true) => {
                    if only_digits(&u.CEP).len() != 8
                        || aparar(&u.xLgr).is_empty()
                        || aparar(&u.nro).is_empty()
                    {
                        p.push(format!("Unidade {n}: complete CEP, logradouro e número."));
                    }
                }
            }
            if !com_parcelas {
                continue;
            }
            if u.ajustes.len() > 1000 {
                p.push(format!(
                    "Unidade {n}: no máximo 1000 parcelas fora da base de cálculo."
                ));
            }
            for a in &u.ajustes {
                if !["01", "02", "03", "04", "99"].contains(&a.tipo.as_str()) {
                    p.push(format!(
                        "Unidade {n}: escolha o tipo da parcela fora da base de cálculo."
                    ));
                }
                if a.tipo == "04" && nbs != "110021000" {
                    p.push(format!("Unidade {n}: o redutor social só vale para locação residencial (NBS 1.1002.10.00)."));
                }
                if a.tipo == "99" && aparar(&a.descricao).is_empty() {
                    p.push(format!(
                        "Unidade {n}: descreva a parcela do tipo \"outras\"."
                    ));
                }
                if a.tipo != "99" && !aparar(&a.descricao).is_empty() {
                    p.push(format!("Unidade {n}: a descrição da parcela só deve ser informada no tipo 99 (outras)."));
                }
                if !is_decimal(&a.valor)
                    || norm_decimal(&a.valor)
                        .parse::<f64>()
                        .map(|v| v <= 0.0)
                        .unwrap_or(true)
                {
                    p.push(format!(
                        "Unidade {n}: valor inválido na parcela fora da base de cálculo."
                    ));
                }
            }
        }
        p
    }

    /// As regras da SEFIN para as operações condominiais (NT 009).
    fn problemas_do_condominio(&self) -> Vec<String> {
        let mut p = self.problemas_do_imovel("Condomínio", "", false);
        if !self.venc_automatico && parse_iso_date_ok(&self.cond_dVencOrig).is_none() {
            p.push("Condomínio: informe o vencimento original (AAAA-MM-DD).".into());
        }
        if self.cond_cobrancas.is_empty() {
            p.push("Condomínio: informe ao menos uma cobrança.".into());
        }
        if self.cond_cobrancas.len() > 20 {
            p.push("Condomínio: no máximo 20 cobranças por nota.".into());
        }
        let mut tipos: Vec<&str> = Vec::new();
        for (i, c) in self.cond_cobrancas.iter().enumerate() {
            let n = i + 1;
            if !TIPOS_DE_COBRANCA.contains(&c.tipo.as_str()) {
                p.push(format!("Cobrança {n}: escolha o tipo."));
            } else if c.tipo != "99" && tipos.contains(&c.tipo.as_str()) {
                p.push(format!("Cobrança {n}: o tipo já foi informado em outra cobrança (só \"outra cobrança\" pode repetir)."));
            }
            tipos.push(c.tipo.as_str());
            if c.tipo == "99" && aparar(&c.descricao).is_empty() {
                p.push(format!(
                    "Cobrança {n}: descreva a cobrança do tipo \"outra\"."
                ));
            }
            let positivo = |v: &str| {
                is_decimal(v)
                    && norm_decimal(v)
                        .parse::<f64>()
                        .map(|x| x > 0.0)
                        .unwrap_or(false)
            };
            if c.detalhes.is_empty() {
                if !positivo(&c.valor) {
                    p.push(format!("Cobrança {n}: valor inválido."));
                }
                continue;
            }
            // Detalhamento (opcional): os itens somam o valor da cobrança e têm de ser de um tipo
            // que o tipo da cobrança admite.
            if c.detalhes.len() > 20 {
                p.push(format!("Cobrança {n}: no máximo 20 itens de detalhamento."));
            }
            let admitidos = detalhes_admitidos(&c.tipo);
            for (j, d) in c.detalhes.iter().enumerate() {
                let m = j + 1;
                if !TIPOS_DE_DETALHE.iter().any(|(codigo, _)| *codigo == d.tipo) {
                    p.push(format!("Cobrança {n}, detalhe {m}: escolha o tipo."));
                } else if !admitidos.is_empty() && !admitidos.contains(&d.tipo.as_str()) {
                    p.push(format!("Cobrança {n}, detalhe {m}: esse tipo de detalhe não vale para o tipo da cobrança."));
                }
                if d.tipo == "999" && aparar(&d.descricao).is_empty() {
                    p.push(format!(
                        "Cobrança {n}, detalhe {m}: descreva o detalhe do tipo \"outro\"."
                    ));
                }
                if !positivo(&d.valor) {
                    p.push(format!("Cobrança {n}, detalhe {m}: valor inválido."));
                }
            }
            let digitado = norm_decimal(&c.valor);
            let somado = c.valor_efetivo();
            if !digitado.is_empty() && digitado.parse::<f64>().ok() != somado.parse::<f64>().ok() {
                p.push(format!("Cobrança {n}: com detalhamento, o valor da cobrança é a soma dos itens (R$ {somado})."));
            }
        }
        if self.cond_descontos.len() > 10 {
            p.push("Condomínio: no máximo 10 descontos por nota.".into());
        }
        for (i, d) in self.cond_descontos.iter().enumerate() {
            let n = i + 1;
            if !["1", "2"].contains(&d.tipo.as_str()) {
                p.push(format!(
                    "Desconto {n} do condomínio: escolha se é incondicionado ou condicionado."
                ));
            }
            if aparar(&d.descricao).is_empty() {
                p.push(format!("Desconto {n} do condomínio: informe a descrição."));
            }
            if !is_decimal(&d.valor)
                || norm_decimal(&d.valor)
                    .parse::<f64>()
                    .map(|v| v <= 0.0)
                    .unwrap_or(true)
            {
                p.push(format!("Desconto {n} do condomínio: valor inválido."));
            }
        }
        // O valor da nota e os descontos saem das listas: o que foi digitado à parte tem de bater.
        let (servico, incondicionado, condicionado) = self.valores_da_nota();
        for (rotulo, digitado, calculado) in [
            ("o valor da nota", &self.vServ, &servico),
            (
                "o desconto incondicionado",
                &self.vDescIncond,
                &incondicionado,
            ),
            ("o desconto condicionado", &self.vDescCond, &condicionado),
        ] {
            let digitado = norm_decimal(digitado);
            if !digitado.is_empty()
                && digitado.parse::<f64>().ok() != calculado.parse::<f64>().ok().or(Some(0.0))
            {
                p.push(format!(
                    "Condomínio: {rotulo} é a soma do que está no cadastro do serviço (R$ {}); para mudar, altere as cobranças ou os descontos lá.",
                    if calculado.is_empty() { "0.00" } else { calculado.as_str() }
                ));
            }
        }
        p
    }

    /// As regras da SEFIN para locação, cessão onerosa e arrendamento de imóvel (NT 009).
    fn problemas_da_locacao(&self, nbs: &str) -> Vec<String> {
        let mut p: Vec<String> = Vec::new();
        if !["110021000", "110022000"].contains(&nbs) {
            p.push("Locação de imóvel: o item NBS deve ser 1.1002.10.00 (residencial) ou 1.1002.20.00 (não residencial).".into());
        }
        p.extend(self.problemas_do_imovel("Locação de imóvel", nbs, true));
        if !aparar(&self.loc_pCopropriedade).is_empty()
            && !leiaute::percentual_copropriedade_valido(&self.loc_pCopropriedade)
        {
            p.push("Locação de imóvel: a copropriedade deve estar entre 0 e 100%, com até duas casas decimais.".into());
        }
        if !self.venc_automatico
            && !aparar(&self.loc_dVencOrig).is_empty()
            && crate::texto::parse_iso_date(aparar(&self.loc_dVencOrig)).is_none()
        {
            p.push("Locação de imóvel: vencimento original inválido (use AAAA-MM-DD).".into());
        }
        p
    }

    /// As regras da SEFIN para locação de bens móveis (NT 009).
    fn problemas_dos_bens_moveis(&self) -> Vec<String> {
        let mut p: Vec<String> = Vec::new();
        if self.bens_moveis.is_empty() {
            p.push("Locação de bens móveis: informe ao menos um bem locado.".into());
        }
        if self.bens_moveis.len() > 1000 {
            p.push("Locação de bens móveis: no máximo 1000 bens por nota.".into());
        }
        for (i, b) in self.bens_moveis.iter().enumerate() {
            let n = i + 1;
            if only_digits(&b.ncm).len() != 8 {
                p.push(format!("Bem {n}: o código NCM tem 8 dígitos."));
            }
            let descricao = aparar(&b.descricao);
            if descricao.is_empty() || descricao.chars().count() > 150 {
                p.push(format!(
                    "Bem {n}: informe a descrição (até 150 caracteres)."
                ));
            }
            match only_digits(&b.quantidade).parse::<u32>() {
                Ok(q)
                    if (1..=999).contains(&q)
                        && only_digits(&b.quantidade) == aparar(&b.quantidade) => {}
                _ => p.push(format!(
                    "Bem {n}: a quantidade deve ser um número de 1 a 999."
                )),
            }
        }
        p
    }

    /// Seções da locação (imóvel ou bens móveis), nos caminhos do leiaute novo. Um grupo que se
    /// repete ganha uma seção numerada por ocorrência (ver `dps_xml`).
    fn secoes_da_locacao(&self) -> Secoes {
        let mut secoes: Secoes = Vec::new();
        let locacao = leiaute::e_imovel(&self.cTribNac);
        let condominio = leiaute::e_condominio(&self.cTribNac);
        if locacao || condominio {
            secoes.push((
                "IBSCBS.imovel".into(),
                vec![par("cMun", only_digits(&self.loc_cMun))],
            ));
            if locacao {
                let copropriedade = if aparar(&self.loc_pCopropriedade).is_empty() {
                    "100.00".to_string()
                } else {
                    norm_decimal(&self.loc_pCopropriedade)
                };
                secoes.push((
                    "IBSCBS.imovel.gLocacao".into(),
                    vec![
                        par("pCopropriedade", copropriedade),
                        par("dVencOrig", aparar(&self.loc_dVencOrig)),
                    ],
                ));
            }
            for (i, u) in self.loc_unidades.iter().enumerate() {
                let base = format!("IBSCBS.imovel.gUnidImob.{}", i + 1);
                let cib = crate::texto::cib_normalizado(aparar(&u.cCIB));
                secoes.push((
                    base.clone(),
                    vec![
                        par("inscImobFisc", aparar(&u.inscImobFisc)),
                        par("cCIB", cib.as_str()),
                    ],
                ));
                if cib.is_empty() {
                    secoes.push((
                        format!("{base}.end"),
                        vec![
                            par("CEP", only_digits(&u.CEP)),
                            par("xLgr", aparar(&u.xLgr)),
                            par("nro", aparar(&u.nro)),
                            par("xCpl", aparar(&u.xCpl)),
                            par("xBairro", aparar(&u.xBairro)),
                        ],
                    ));
                }
                // as parcelas fora da base só existem na locação
                for (j, a) in u.ajustes.iter().enumerate().filter(|_| locacao) {
                    secoes.push((
                        format!("{base}.gAjusteBCLocImoveis.{}", j + 1),
                        vec![
                            par("tpAjusteBCLocImoveis", a.tipo.as_str()),
                            par(
                                "xTpAjusteBCLocImoveis",
                                if a.tipo == "99" {
                                    aparar(&a.descricao)
                                } else {
                                    ""
                                },
                            ),
                            par("vAjusteBCLocImoveis", norm_decimal(&a.valor)),
                        ],
                    ));
                }
            }
        }
        if condominio {
            secoes.push((
                "IBSCBS.condominios".into(),
                vec![par("dVencOrig", aparar(&self.cond_dVencOrig))],
            ));
            for (i, c) in self.cond_cobrancas.iter().enumerate() {
                secoes.push((
                    format!("IBSCBS.condominios.gCobranca.{}", i + 1),
                    vec![
                        par("tpCobranca", c.tipo.as_str()),
                        par(
                            "xTpCobranca",
                            if c.tipo == "99" {
                                aparar(&c.descricao)
                            } else {
                                ""
                            },
                        ),
                        par("vCobranca", c.valor_efetivo()),
                    ],
                ));
                for (j, d) in c.detalhes.iter().enumerate() {
                    secoes.push((
                        format!(
                            "IBSCBS.condominios.gCobranca.{}.gDetCobranca.{}",
                            i + 1,
                            j + 1
                        ),
                        vec![
                            par("tpDetCobranca", d.tipo.as_str()),
                            par(
                                "xTpDetCobranca",
                                if d.tipo == "999" {
                                    aparar(&d.descricao)
                                } else {
                                    ""
                                },
                            ),
                            par("vDetCobranca", norm_decimal(&d.valor)),
                        ],
                    ));
                }
            }
            for (i, d) in self.cond_descontos.iter().enumerate() {
                secoes.push((
                    format!("IBSCBS.condominios.gDesconto.{}", i + 1),
                    vec![
                        par("tpDesconto", d.tipo.as_str()),
                        par("vDesconto", norm_decimal(&d.valor)),
                        par("xTpDesconto", aparar(&d.descricao)),
                    ],
                ));
            }
        }
        if leiaute::e_bem_movel(&self.cTribNac) {
            for (i, b) in self.bens_moveis.iter().enumerate() {
                secoes.push((
                    format!("IBSCBS.bensMoveis.{}", i + 1),
                    vec![
                        par("cNCMBemMovel", only_digits(&b.ncm)),
                        par("xNCMBemMovel", aparar(&b.descricao)),
                        par("qtdNCMBemMovel", only_digits(&b.quantidade)),
                    ],
                ));
            }
        }
        secoes
    }

    /// Seções do serviço (serviço + tributação). `[gui.servico]` fica fora da árvore <dps> (tem
    /// ponto no nome), então não é emitido no XML — guarda só o rótulo.
    pub fn to_sections(&self) -> Secoes {
        let ou = |v: &str, padrao: &str| {
            if v.is_empty() {
                padrao.to_string()
            } else {
                v.to_string()
            }
        };
        let cst = aparar(&ou(&self.pis_CST, "01")).to_string();
        let ret = aparar(&ou(&self.tpRetPisCofins, "0")).to_string();
        let tributado = cst != "00"; // CST 00 = Nenhum → sem cálculo próprio de PIS/COFINS
        let retido = ret != "0"; // "0" = PIS/COFINS/CSLL Não Retidos

        // Bloco piscofins: CST/tpRetPisCofins sempre; cálculo próprio ({auto}) só se tributado.
        let mut piscofins = vec![par("CST", cst.as_str())];
        if tributado {
            for k in ["vBCPisCofins", "pAliqPis", "pAliqCofins", "vPis", "vCofins"] {
                piscofins.push(par(k, "{auto}"));
            }
        }
        piscofins.push(par("tpRetPisCofins", ret.as_str()));

        // tribFed (retenções): tributado+retido → {auto}; CST=00+retido → valores diretos em R$
        // (vazios são omitidos); não retido → omitido. "Incluir contribuições sociais" desligado
        // omite o vRetCSLL — só o IRRF permanece.
        let contrib = aparar(&ou(&self.incluir_contrib, "1")) != "0";
        let mut tribfed: Vec<(String, String)> = Vec::new();
        if retido && tributado {
            tribfed.push(par("vRetIRRF", "{auto}"));
            if contrib {
                tribfed.push(par("vRetCSLL", "{auto}"));
            }
        } else if retido {
            let irrf = norm_decimal(&self.vRetIRRF_manual);
            let csll = if contrib {
                norm_decimal(&self.vRetCSLL_manual)
            } else {
                String::new()
            };
            if !irrf.is_empty() {
                tribfed.push(par("vRetIRRF", irrf));
            }
            if !csll.is_empty() {
                tribfed.push(par("vRetCSLL", csll));
            }
        }

        let (v_servico, v_incondicionado, v_condicionado) = self.valores_da_nota();
        let mut secoes: Secoes = vec![
            ("gui.servico".into(), {
                let mut gui = vec![
                    par("nome", self.nome.as_str()),
                    par("incluir_contrib", if contrib { "1" } else { "0" }),
                ];
                if self.rtc_plataforma_digital {
                    gui.push(par("rtc_plataforma_digital", "1"));
                }
                // só o que foge do padrão é gravado
                if aparar(&self.ret_abate_desconto) == "0" {
                    gui.push(par("ret_abate_desconto", "0"));
                }
                gui
            }),
            (
                "serv.locPrest".into(),
                vec![par("cLocPrestacao", only_digits(&self.cLocPrestacao))],
            ),
            (
                "serv.cServ".into(),
                vec![
                    par("cTribNac", only_digits(&self.cTribNac)),
                    par("cTribMun", only_digits(&self.cTribMun)),
                    // \r\n (texto colado) gravado como está virava uma linha em branco a mais na nota.
                    par(
                        "xDescServ",
                        self.xDescServ.replace("\r\n", "\n").replace('\r', "\n"),
                    ),
                    par("cNBS", only_digits(&self.cNBS)),
                ],
            ),
            ("valores.vServPrest".into(), vec![par("vServ", v_servico)]),
            (
                "valores.trib.tribMun".into(),
                vec![
                    par("tribISSQN", self.tribISSQN.as_str()),
                    par("tpRetISSQN", self.tpRetISSQN.as_str()),
                ],
            ),
            ("valores.trib.tribFed.piscofins".into(), piscofins),
            ("valores.trib.tribFed".into(), tribfed),
            (
                "valores.trib.totTrib.pTotTrib".into(),
                vec![
                    par("pTotTribFed", "{auto}"),
                    par("pTotTribEst", "{auto}"),
                    par("pTotTribMun", "{auto}"),
                ],
            ),
        ];

        if self.venc_automatico {
            secoes.push((
                "gui.vencimento".into(),
                vec![
                    par("automatico", "1"),
                    par("dia", self.venc_dia.to_string()),
                    par("meses", self.venc_meses.to_string()),
                ],
            ));
        }

        if !only_doc(&self.cert_procurador).is_empty() {
            secoes.push((
                "gui.certificado".into(),
                vec![par("procurador", only_doc(&self.cert_procurador))],
            ));
        }

        if self.tem_intermediario() {
            secoes.push((
                "interm".into(),
                vec![
                    par(&self.interm_tipo, only_doc(&self.interm_documento)),
                    par("xNome", aparar(&self.interm_xNome)),
                    par("IM", aparar(&self.interm_IM)),
                ],
            ));
        }

        // Descontos: a seção só existe quando há algum (nota sem desconto fica como sempre foi).
        let descontos: Vec<(String, String)> = [
            ("vDescIncond", v_incondicionado),
            ("vDescCond", v_condicionado),
        ]
        .into_iter()
        .filter(|(_, v)| v.parse::<f64>().is_ok_and(|n| n > 0.0))
        .map(|(k, v)| par(k, v))
        .collect();
        if !descontos.is_empty() {
            secoes.push(("valores.vDescCondIncond".into(), descontos));
        }

        if self.tem_rtc() {
            secoes.push((
                "IBSCBS".into(),
                vec![
                    par("finNFSe", "0"),
                    par("cIndOp", self.rtc_cIndOp.as_str()),
                    par("indDest", self.rtc_indDest.as_str()),
                ],
            ));
            secoes.push((
                "IBSCBS.valores.trib.gIBSCBS".into(),
                vec![
                    par("CST", self.rtc_CST.as_str()),
                    par("cClassTrib", self.rtc_cClassTrib.as_str()),
                ],
            ));
            if self.rtc_indDest == "1" {
                secoes.push((
                    "IBSCBS.dest".into(),
                    vec![
                        par(&self.dest_tipo, only_doc(&self.dest_documento)),
                        par("xNome", aparar(&self.dest_xNome)),
                    ],
                ));
                if self
                    .endereco_do_destinatario()
                    .iter()
                    .any(|v| !v.is_empty())
                {
                    secoes.push((
                        "IBSCBS.dest.end.endNac".into(),
                        vec![
                            par("cMun", only_digits(&self.dest_cMun)),
                            par("CEP", only_digits(&self.dest_CEP)),
                        ],
                    ));
                    secoes.push((
                        "IBSCBS.dest.end".into(),
                        vec![
                            par("xLgr", aparar(&self.dest_xLgr)),
                            par("nro", aparar(&self.dest_nro)),
                            par("xCpl", aparar(&self.dest_xCpl)),
                            par("xBairro", aparar(&self.dest_xBairro)),
                        ],
                    ));
                }
            }
            secoes.extend(self.secoes_da_locacao());
        }

        let proprios: Vec<(String, String)> = [
            ("pAliqPis", &self.ov_pAliqPis),
            ("pAliqCofins", &self.ov_pAliqCofins),
            ("pIRRF", &self.ov_pIRRF),
            ("pCSLL", &self.ov_pCSLL),
            ("pTotTribFed", &self.ov_pTotTribFed),
            ("pTotTribEst", &self.ov_pTotTribEst),
            ("pTotTribMun", &self.ov_pTotTribMun),
        ]
        .into_iter()
        .filter(|(_, v)| !aparar(v).is_empty())
        .map(|(k, v)| par(k, norm_decimal(v)))
        .collect();
        if !proprios.is_empty() {
            secoes.push(("gui.tributos".into(), proprios));
        }
        secoes
    }

    pub fn from_config(ini: &Ini) -> ServicoForm {
        let ou = |v: String, padrao: &str| if v.is_empty() { padrao.to_string() } else { v };
        let dest_cpf = ini.val("IBSCBS.dest", "CPF", "");
        ServicoForm {
            nome: ou(ini.val("gui.servico", "nome", ""), "Serviço 1"),
            cLocPrestacao: ini.val("serv.locPrest", "cLocPrestacao", ""),
            cTribNac: ini.val("serv.cServ", "cTribNac", ""),
            cTribMun: ini.val("serv.cServ", "cTribMun", ""),
            xDescServ: ini.val("serv.cServ", "xDescServ", ""),
            cNBS: ini.val("serv.cServ", "cNBS", ""),
            interm_tipo: if ini.val("interm", "CPF", "").is_empty() {
                "CNPJ".into()
            } else {
                "CPF".into()
            },
            interm_documento: ou(ini.val("interm", "CNPJ", ""), &ini.val("interm", "CPF", "")),
            interm_xNome: ini.val("interm", "xNome", ""),
            interm_IM: ini.val("interm", "IM", ""),
            rtc_plataforma_digital: ini.val("gui.servico", "rtc_plataforma_digital", "0") == "1",
            rtc_indDest: ini.val("IBSCBS", "indDest", ""),
            rtc_cIndOp: ini.val("IBSCBS", "cIndOp", ""),
            rtc_CST: ini.val("IBSCBS.valores.trib.gIBSCBS", "CST", ""),
            rtc_cClassTrib: ini.val("IBSCBS.valores.trib.gIBSCBS", "cClassTrib", ""),
            dest_tipo: if dest_cpf.is_empty() {
                "CNPJ".into()
            } else {
                "CPF".into()
            },
            dest_documento: if dest_cpf.is_empty() {
                ini.val("IBSCBS.dest", "CNPJ", "")
            } else {
                dest_cpf
            },
            dest_xNome: ini.val("IBSCBS.dest", "xNome", ""),
            dest_cMun: ini.val("IBSCBS.dest.end.endNac", "cMun", ""),
            dest_CEP: ini.val("IBSCBS.dest.end.endNac", "CEP", ""),
            dest_xLgr: ini.val("IBSCBS.dest.end", "xLgr", ""),
            dest_nro: ini.val("IBSCBS.dest.end", "nro", ""),
            dest_xCpl: ini.val("IBSCBS.dest.end", "xCpl", ""),
            dest_xBairro: ini.val("IBSCBS.dest.end", "xBairro", ""),
            vServ: ini.val("valores.vServPrest", "vServ", ""),
            tribISSQN: ini.val("valores.trib.tribMun", "tribISSQN", "1"),
            tpRetISSQN: ini.val("valores.trib.tribMun", "tpRetISSQN", "1"),
            pis_CST: ini.val("valores.trib.tribFed.piscofins", "CST", "01"),
            tpRetPisCofins: ini.val("valores.trib.tribFed.piscofins", "tpRetPisCofins", "3"),
            incluir_contrib: ou(ini.val("gui.servico", "incluir_contrib", "1"), "1"),
            ret_abate_desconto: ou(ini.val("gui.servico", "ret_abate_desconto", "1"), "1"),
            ov_pAliqPis: ini.val("gui.tributos", "pAliqPis", ""),
            ov_pAliqCofins: ini.val("gui.tributos", "pAliqCofins", ""),
            ov_pIRRF: ini.val("gui.tributos", "pIRRF", ""),
            ov_pCSLL: ini.val("gui.tributos", "pCSLL", ""),
            ov_pTotTribFed: ini.val("gui.tributos", "pTotTribFed", ""),
            ov_pTotTribEst: ini.val("gui.tributos", "pTotTribEst", ""),
            ov_pTotTribMun: ini.val("gui.tributos", "pTotTribMun", ""),
            vRetIRRF_manual: valor_explicito(ini, "valores.trib.tribFed", "vRetIRRF"),
            vRetCSLL_manual: valor_explicito(ini, "valores.trib.tribFed", "vRetCSLL"),
            loc_cMun: ini.val("IBSCBS.imovel", "cMun", ""),
            loc_pCopropriedade: ini.val("IBSCBS.imovel.gLocacao", "pCopropriedade", ""),
            loc_dVencOrig: ini.val("IBSCBS.imovel.gLocacao", "dVencOrig", ""),
            cert_procurador: ini.val("gui.certificado", "procurador", ""),
            venc_automatico: ini.val("gui.vencimento", "automatico", "0") == "1",
            venc_dia: ini.val("gui.vencimento", "dia", "10").parse().unwrap_or(10),
            venc_meses: ini.val("gui.vencimento", "meses", "1").parse().unwrap_or(1),
            loc_unidades: numeradas(ini, "IBSCBS.imovel.gUnidImob")
                .into_iter()
                .map(|base| UnidadeImob {
                    inscImobFisc: ini.val(&base, "inscImobFisc", ""),
                    cCIB: ini.val(&base, "cCIB", ""),
                    CEP: ini.val(&format!("{base}.end"), "CEP", ""),
                    xLgr: ini.val(&format!("{base}.end"), "xLgr", ""),
                    nro: ini.val(&format!("{base}.end"), "nro", ""),
                    xCpl: ini.val(&format!("{base}.end"), "xCpl", ""),
                    xBairro: ini.val(&format!("{base}.end"), "xBairro", ""),
                    ajustes: numeradas(ini, &format!("{base}.gAjusteBCLocImoveis"))
                        .into_iter()
                        .map(|a| AjusteDaLocacao {
                            tipo: ini.val(&a, "tpAjusteBCLocImoveis", ""),
                            descricao: ini.val(&a, "xTpAjusteBCLocImoveis", ""),
                            valor: ini.val(&a, "vAjusteBCLocImoveis", ""),
                        })
                        .collect(),
                })
                .collect(),
            cond_dVencOrig: ini.val("IBSCBS.condominios", "dVencOrig", ""),
            cond_cobrancas: numeradas(ini, "IBSCBS.condominios.gCobranca")
                .into_iter()
                .map(|c| CobrancaDoCondominio {
                    tipo: ini.val(&c, "tpCobranca", ""),
                    descricao: ini.val(&c, "xTpCobranca", ""),
                    valor: ini.val(&c, "vCobranca", ""),
                    detalhes: numeradas(ini, &format!("{c}.gDetCobranca"))
                        .into_iter()
                        .map(|d| DetalheDaCobranca {
                            tipo: ini.val(&d, "tpDetCobranca", ""),
                            descricao: ini.val(&d, "xTpDetCobranca", ""),
                            valor: ini.val(&d, "vDetCobranca", ""),
                        })
                        .collect(),
                })
                .collect(),
            cond_descontos: numeradas(ini, "IBSCBS.condominios.gDesconto")
                .into_iter()
                .map(|d| DescontoDoCondominio {
                    tipo: ini.val(&d, "tpDesconto", ""),
                    descricao: ini.val(&d, "xTpDesconto", ""),
                    valor: ini.val(&d, "vDesconto", ""),
                })
                .collect(),
            vDescIncond: ini.val("valores.vDescCondIncond", "vDescIncond", ""),
            vDescCond: ini.val("valores.vDescCondIncond", "vDescCond", ""),
            bens_moveis: numeradas(ini, "IBSCBS.bensMoveis")
                .into_iter()
                .map(|b| BemMovel {
                    ncm: ini.val(&b, "cNCMBemMovel", ""),
                    descricao: ini.val(&b, "xNCMBemMovel", ""),
                    quantidade: ini.val(&b, "qtdNCMBemMovel", ""),
                })
                .collect(),
        }
    }
}

/// As seções numeradas de um grupo que se repete (`base.1`, `base.2`…), em ordem.
fn numeradas(ini: &Ini, base: &str) -> Vec<String> {
    let prefixo = format!("{base}.");
    let mut numeros: Vec<u32> = ini
        .secoes()
        .into_iter()
        .filter_map(|s| {
            s.strip_prefix(&prefixo)?
                .split('.')
                .next()?
                .parse::<u32>()
                .ok()
        })
        .collect();
    numeros.sort_unstable();
    numeros.dedup();
    numeros.into_iter().map(|n| format!("{base}.{n}")).collect()
}

/// Prazo do Ato Conjunto RFB/CGIBS 4/2026, com as alterações do Ato nº 7/2026.
/// O grupo continua opcional antes do prazo e na homologação.
pub fn rtc_required(
    prestador: &str,
    form: &ServicoForm,
    ambiente: &str,
    competencia: Option<NaiveDate>,
) -> Res<bool> {
    if ambiente != AMBIENTE_PRODUCAO {
        return Ok(false);
    }
    let simples = get_prestador_form(prestador)?.opSimpNac != "1";
    let codigo = only_digits(&form.cTribNac);
    let Some(subitem) = codigo.get(..4) else { return Ok(false) };
    let sujeito_iss = matches!(form.tribISSQN.trim(), "" | "1");
    let inicio = if form.rtc_plataforma_digital
        || sujeito_iss && matches!(subitem, "0103" | "0105" | "0109" | "1601")
    {
        NaiveDate::from_ymd_opt(2027, 3, 1)
    } else if codigo.starts_with("99") || simples || !sujeito_iss {
        NaiveDate::from_ymd_opt(2027, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(2026, 10, 1)
    }.ok_or_else(|| Erro::valor("Data de início do IBS/CBS inválida."))?;
    let hoje = chrono::Local::now().date_naive();
    Ok(competencia.unwrap_or(hoje) >= inicio)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct ServicoInfo {
    pub slug: String,
    pub nome: String,
    pub vServ: String,
}

pub fn servicos_dir(prestador: &str, tomador: &str) -> String {
    format!("{}/servicos", tomador_dir(prestador, &only_doc(tomador)))
}

pub fn servico_file(prestador: &str, tomador: &str, servico: &str) -> String {
    format!("{}/{servico}.ini", servicos_dir(prestador, tomador))
}

fn slug_num(slug: &str) -> u64 {
    slug.chars()
        .filter(char::is_ascii_digit)
        .collect::<String>()
        .parse()
        .unwrap_or(0)
}

/// Slugs de serviço existentes do cliente.
pub fn servico_slugs(prestador: &str, tomador: &str) -> Res<Vec<String>> {
    let mut slugs: Vec<String> = banco::list_keys(&servicos_dir(prestador, tomador), "")?
        .iter()
        .filter_map(|k| {
            let nome = k.rsplit('/').next().unwrap_or("");
            if !nome.starts_with("serv") {
                return None;
            }
            Some(match nome.rsplit_once('.') {
                Some((radical, _)) if !radical.is_empty() => radical.to_string(),
                _ => nome.to_string(),
            })
        })
        .collect();
    slugs.sort();
    slugs.dedup();
    Ok(slugs)
}

/// Serviços cadastrados do cliente, em ordem de número.
pub fn list_servicos(prestador: &str, tomador: &str) -> Res<Vec<ServicoInfo>> {
    let mut slugs = servico_slugs(prestador, tomador)?;
    slugs.sort_by_key(|s| slug_num(s));
    let mut out = Vec::new();
    for slug in slugs {
        let cfg = ler(&servico_file(prestador, tomador, &slug))?;
        let nome = cfg.val("gui.servico", "nome", "");
        out.push(ServicoInfo {
            nome: if nome.is_empty() { slug.clone() } else { nome },
            vServ: cfg.val("valores.vServPrest", "vServ", ""),
            slug,
        });
    }
    Ok(out)
}

pub fn get_servico(prestador: &str, tomador: &str, servico: &str) -> Res<ServicoForm> {
    let cfg = ler(&servico_file(prestador, tomador, servico))?;
    form_do_servico(&cfg)
}

pub fn formularios_servicos(prestador: &str, tomador: &str) -> Res<Vec<(String, ServicoForm)>> {
    let dir = servicos_dir(prestador, tomador);
    let mut servicos = Vec::new();
    for (arquivo, cfg) in banco::load_inis(&dir)? {
        let Some(slug) = arquivo.rsplit('/').next().and_then(|nome| nome.strip_suffix(".ini"))
        else {
            continue;
        };
        if slug.starts_with("serv") && arquivo == servico_file(prestador, tomador, slug) {
            servicos.push((slug.to_string(), form_do_servico(&cfg)?));
        }
    }
    servicos.sort_by_key(|(slug, _)| slug_num(slug));
    Ok(servicos)
}

fn form_do_servico(cfg: &Ini) -> Res<ServicoForm> {
    match cfg.obter("gui.servico", "form_cadastro") {
        Some(form) => Ok(serde_json::from_str(form)?),
        None => Ok(ServicoForm::from_config(cfg)),
    }
}

pub fn save_servico(
    prestador: &str,
    tomador: &str,
    servico: &str,
    form: &ServicoForm,
) -> Res<String> {
    // Cadastro pode ser parcial. A prévia e a emissão continuam validando o formulário inteiro.
    let caminho = servico_file(prestador, tomador, servico);
    let mut secoes = form.to_sections();
    // Preserva também campos ainda sem o grupo fiscal selecionado, sem inferir valores ao reabrir.
    if let Some((_, opcoes)) = secoes.iter_mut().find(|(s, _)| s == "gui.servico") {
        opcoes.push(par("form_cadastro", serde_json::to_string(form)?));
    }
    gravar_secoes(&caminho, &secoes)?;
    Ok(caminho)
}

pub fn delete_servico(prestador: &str, tomador: &str, servico: &str) -> Res<()> {
    banco::delete_ini(&servico_file(prestador, tomador, servico))
}

const TOMADOR_EM_MAIUSCULAS: [(&str, &str); 8] = [
    ("toma", "IM"),
    ("toma", "xNome"),
    ("toma.end", "xLgr"),
    ("toma.end", "nro"),
    ("toma.end", "xCpl"),
    ("toma.end", "xBairro"),
    ("gui.endereco", "xCidade"),
    ("gui.endereco", "UF"),
];

/// Mescla identidade (cadastro do cliente) + o serviço escolhido na config que a emissão lê
/// como "config do tomador". Com `form`, usa o serviço EM MEMÓRIA no lugar do cadastrado —
/// permite pré-visualizar sem gravar nada no cadastro.
pub fn compose_active_config(
    prestador: &str,
    tomador: &str,
    servico: &str,
    form: Option<&ServicoForm>,
) -> Res<Ini> {
    let ident = ler(&config_tomador_file(prestador, tomador))?;
    let serv = match form {
        Some(f) => {
            let mut ini = Ini::novo();
            for (secao, opcoes) in f.to_sections() {
                ini.adicionar_secao(&secao)?;
                for (opcao, valor) in opcoes {
                    ini.definir(&secao, &opcao, &valor)?;
                }
            }
            ini
        }
        None => ler(&servico_file(prestador, tomador, servico))?,
    };
    let mut junto = Ini::novo();
    for origem in [&ident, &serv] {
        for secao in origem.secoes() {
            junto.garantir_secao(secao);
            for (opcao, valor) in origem.itens(secao) {
                junto.por(secao, opcao, valor);
            }
        }
    }
    // texto do tomador em maiúsculas na config usada para emitir
    for (secao, opcao) in TOMADOR_EM_MAIUSCULAS {
        if let Some(v) = junto.obter(secao, opcao).map(upper_text) {
            junto.por(secao, opcao, &v);
        }
    }
    if let Some(v) = junto.obter("toma", "email").map(lower_email) {
        junto.por("toma", "email", &v);
    }
    Ok(junto)
}

// ------------------------------------------------------------------------------- //
// Prestador (dados editáveis em Configurações)
// ------------------------------------------------------------------------------- //
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct PrestadorForm {
    pub tipo_doc: String, // "CNPJ" ou "CPF"
    pub documento: String,
    pub nome_exib: String, // nome de exibição (só para a lista da tela inicial)
    pub IM: String,
    pub xNome: String,
    pub fone: String,
    pub email: String,
    pub cLocEmi: String, // [dps] cLocEmi (município de emissão, IBGE 7 díg.)
    pub opSimpNac: String,
    pub regApTribSN: String,
    pub regEspTrib: String,
}

impl Default for PrestadorForm {
    fn default() -> Self {
        PrestadorForm {
            tipo_doc: "CNPJ".into(),
            documento: String::new(),
            nome_exib: String::new(),
            IM: String::new(),
            xNome: String::new(),
            fone: String::new(),
            email: String::new(),
            cLocEmi: String::new(),
            opSimpNac: "1".into(),
            regApTribSN: String::new(),
            regEspTrib: "0".into(),
        }
    }
}

impl PrestadorForm {
    pub fn validate(&self) -> Vec<String> {
        let mut erros = Vec::new();
        let doc = only_doc(&self.documento);
        if self.tipo_doc == "CNPJ" && doc.len() != 14 {
            erros.push("CNPJ do prestador deve ter 14 caracteres.".to_string());
        }
        if self.tipo_doc == "CPF" && doc.len() != 11 {
            erros.push("CPF do prestador deve ter 11 dígitos.".to_string());
        }
        if !self.cLocEmi.is_empty() && only_digits(&self.cLocEmi).len() != 7 {
            erros.push("cLocEmi (município de emissão) deve ter 7 dígitos IBGE.".to_string());
        }
        erros
    }

    pub fn from_config(ini: &Ini) -> PrestadorForm {
        let cnpj = ini.val("prest", "CNPJ", "");
        let cpf = ini.val("prest", "CPF", "");
        let tipo = if !cpf.is_empty() && cnpj.is_empty() {
            "CPF"
        } else {
            "CNPJ"
        };
        PrestadorForm {
            tipo_doc: tipo.into(),
            documento: if cnpj.is_empty() { cpf } else { cnpj },
            nome_exib: ini.val("prest", "xNomeExib", ""),
            IM: ini.val("prest", "IM", ""),
            xNome: ini.val("prest", "xNome", ""),
            fone: ini.val("prest", "fone", ""),
            email: ini.val("prest", "email", ""),
            cLocEmi: ini.val("dps", "cLocEmi", ""),
            opSimpNac: ini.val("prest.regTrib", "opSimpNac", "1"),
            regApTribSN: ini.val("prest.regTrib", "regApTribSN", ""),
            regEspTrib: ini.val("prest.regTrib", "regEspTrib", "0"),
        }
    }
}

const DPS_PADRAO: [(&str, &str); 10] = [
    ("versao", "{auto}"),
    ("tpAmb", AMBIENTE_PRODUCAO),
    ("dhEmi", "{auto}"),
    ("verAplic", "emissor-proprio-1.0"),
    ("serie", "00001"),
    ("nDPS", "{auto}"),
    ("dCompet", "{auto}"),
    ("tpEmit", "1"),
    ("cLocEmi", ""),
    ("Id", "{auto}"),
];

fn garantir_secao_dps(ini: &mut Ini) {
    if !ini.tem_secao("dps") {
        for (opcao, valor) in DPS_PADRAO {
            ini.por("dps", opcao, valor);
        }
    }
}

pub fn get_prestador_form(prestador: &str) -> Res<PrestadorForm> {
    Ok(PrestadorForm::from_config(&ler(&config_prestador_file(
        prestador,
    ))?))
}

/// Atualiza o cadastro do prestador preservando as demais chaves de [dps].
pub fn save_prestador_form(prestador: &str, form: &PrestadorForm) -> Res<String> {
    let erros = form.validate();
    if !erros.is_empty() {
        return Err(lista_de_erros("Cadastro do prestador inválido", &erros));
    }
    // O documento É a identidade do prestador (nome com que o cadastro, o certificado, a
    // numeração e as notas estão guardados): não muda.
    if only_doc(&form.documento) != only_doc(prestador) {
        return Err(Erro::valor(
            "O documento do prestador não pode ser alterado. Para outro CNPJ/CPF, adicione um novo prestador.",
        ));
    }
    let caminho = config_prestador_file(prestador);
    let mut ini = ler(&caminho)?;
    garantir_secao_dps(&mut ini);
    let doc = only_doc(&form.documento);
    ini.por(
        "prest",
        "CNPJ",
        if form.tipo_doc == "CNPJ" { &doc } else { "" },
    );
    ini.por(
        "prest",
        "CPF",
        if form.tipo_doc == "CPF" { &doc } else { "" },
    );
    ini.por("prest", "xNomeExib", aparar(&form.nome_exib));
    ini.por("prest", "IM", &form.IM);
    ini.por("prest", "xNome", &form.xNome);
    ini.por("prest", "fone", &only_digits(&form.fone));
    ini.por("prest", "email", &form.email);
    ini.por("prest.regTrib", "opSimpNac", &form.opSimpNac);
    ini.por("prest.regTrib", "regApTribSN", &form.regApTribSN);
    ini.por("prest.regTrib", "regEspTrib", &form.regEspTrib);
    ini.por("dps", "cLocEmi", &only_digits(&form.cLocEmi));
    banco::save_ini(&caminho, &ini)?;
    Ok(caminho)
}

/// Cria o cadastro de um novo prestador. O certificado e os percentuais de tributos são
/// configurados depois: cada prestador tem os seus, nada é copiado de outro.
pub fn create_prestador(documento: &str, x_nome: &str, tipo_doc: &str) -> Res<String> {
    let doc = only_doc(documento);
    if tipo_doc == "CNPJ" && doc.len() != 14 {
        return Err(Erro::valor("CNPJ deve ter 14 caracteres."));
    }
    if tipo_doc == "CPF" && doc.len() != 11 {
        return Err(Erro::valor("CPF deve ter 11 dígitos."));
    }
    if !documento_valido(&doc, tipo_doc) {
        return Err(Erro::valor(format!(
            "{tipo_doc} inválido (dígitos verificadores não conferem) — revise o documento."
        )));
    }
    if banco::exists_ini(&config_prestador_file(&doc))? {
        return Err(Erro::valor(format!(
            "Já existe um prestador com o documento {}.",
            format_documento(&doc)
        )));
    }
    let mut ini = Ini::novo();
    for (opcao, valor) in DPS_PADRAO {
        ini.por("dps", opcao, valor);
    }
    ini.por("prest", "CNPJ", if tipo_doc == "CNPJ" { &doc } else { "" });
    ini.por("prest", "CPF", if tipo_doc == "CPF" { &doc } else { "" });
    ini.por("prest", "IM", "");
    ini.por("prest", "xNome", x_nome);
    ini.por("prest", "fone", "");
    ini.por("prest", "email", "");
    ini.por("prest.regTrib", "opSimpNac", "1");
    ini.por("prest.regTrib", "regApTribSN", "");
    ini.por("prest.regTrib", "regEspTrib", "0");
    banco::save_ini(&config_prestador_file(&doc), &ini)?;
    Ok(doc)
}

/// Cria o prestador JÁ com o certificado importado. O documento do certificado precisa bater com
/// o informado (CNPJ: mesma raiz). Se a importação falhar, o cadastro recém-criado é desfeito,
/// para não deixar um prestador sem certificado.
pub fn create_prestador_com_certificado(
    documento: &str,
    x_nome: &str,
    tipo_doc: &str,
    caminho_pfx: &str,
    senha: &str,
    procurador: bool,
) -> Res<String> {
    let doc = only_doc(documento);
    if tipo_doc == "CNPJ" && doc.len() != 14 {
        return Err(Erro::valor("CNPJ deve ter 14 caracteres."));
    }
    if tipo_doc == "CPF" && doc.len() != 11 {
        return Err(Erro::valor("CPF deve ter 11 dígitos."));
    }
    // Valida a senha + confere o documento ANTES de criar qualquer coisa.
    let (cert_doc, _) = inspect_certificate(caminho_pfx, senha)?;
    // Procurador marcado com o certificado do próprio prestador: é o certificado dele mesmo.
    let de_procurador = procurador && !docs_compativeis(&cert_doc, &doc);
    if de_procurador && cert_doc.is_empty() {
        return Err(Erro::valor(
            "Não foi possível identificar o CPF/CNPJ do titular deste certificado.",
        ));
    }
    if !de_procurador && !docs_compativeis(&cert_doc, &doc) {
        let tipo_cert = if cert_doc.len() == 11 {
            "e-CPF (pessoa física)"
        } else {
            "e-CNPJ"
        };
        let extra = if tipo_doc == "CNPJ" {
            "Para CNPJ, basta a MESMA raiz (8 primeiros caracteres) — um e-CNPJ da matriz serve para as filiais.".to_string()
        } else {
            format!("Selecione um certificado do mesmo {tipo_doc}.")
        };
        return Err(Erro::valor(format!(
            "O certificado é um {tipo_cert} do documento {}, mas o prestador informado é {}. {extra} Se for o certificado de um procurador do prestador, marque \"Adicionar certificado digital como procurador do prestador\".",
            format_documento(&cert_doc),
            format_documento(&doc)
        )));
    }
    create_prestador(documento, x_nome, tipo_doc)?;
    let importado = if de_procurador {
        import_certificate_procurador(&doc, caminho_pfx, senha)
    } else {
        import_certificate(&doc, caminho_pfx, senha)
    };
    if let Err(e) = importado {
        // desfaz: nada de prestador pela metade
        for nome in [doc.clone(), nome_cert_procurador(&doc, &cert_doc)] {
            let _ = segredos::remove_cert_pfx(&nome);
            let _ = segredos::remove_cert_password(&nome);
        }
        let _ = banco::delete_prefix(&prestador_dir(&doc));
        return Err(e);
    }
    Ok(doc)
}

/// Remove TODOS os dados do prestador: o que é dele no banco de notas (Cofre) e no banco de dados
/// (cadastro, clientes, serviços, numeração, grupos, certificado, senhas, fila de contingência,
/// vínculos de usuários). Irreversível.
pub fn delete_prestador(documento: &str) -> Res<()> {
    let doc = only_doc(documento);
    if !banco::exists_ini(&config_prestador_file(&doc))? {
        return Err(Erro::valor(format!(
            "Prestador {} não encontrado.",
            format_documento(&doc)
        )));
    }
    // Banco de notas PRIMEIRO: notas emitidas e recebidas, eventos, posição no ADN — no arquivo e
    // na cópia de segurança. Se ele estiver ocupado, o erro sai daqui antes de qualquer outra
    // coisa ser apagada: nada de prestador "meio deletado" com as notas ainda guardadas. Só um
    // banco de notas que NÃO ABRE nesta instalação não impede: dele nada se lê nem se apaga.
    match crate::cofre::apagar_dono(&doc) {
        Ok(_) => {}
        Err(e) if e.tipo == "CofreIlegivel" => crate::registro::aviso(
            "service",
            &format!(
                "Prestador {}: o banco de notas não abre, nada foi apagado nele ({e})",
                format_documento(&doc)
            ),
        ),
        Err(e) => return Err(e),
    }
    segredos::remove_cert_pfx(&doc)?;
    segredos::remove_cert_password(&doc)?;
    for nome in list_procuradores(&doc)? {
        segredos::remove_cert_pfx(&nome)?;
        segredos::remove_cert_password(&nome)?;
    }
    segredos::remove_smtp_password(&doc)?;
    // Cadastros e contadores (tudo o que está sob a chave do prestador), a fila de contingência
    // dele e o "último prestador" lembrado pelos usuários.
    banco::delete_prefix(&prestador_dir(&doc))?;
    {
        let con = banco::conn()?;
        con.execute("DELETE FROM pendente WHERE prestador=?1", [&doc])?;
        con.execute(
            "DELETE FROM meta WHERE chave LIKE 'ui.ultimo\\_prestador.%' ESCAPE '\\' AND valor=?1",
            [&doc],
        )?;
    }
    crate::usuarios::esquecer_prestador(&doc)
}

// ------------------------------------------------------------------------------- //
// Ambiente, série e numeração
// ------------------------------------------------------------------------------- //
pub fn get_ambiente(prestador: &str) -> Res<String> {
    let cfg = ler(&config_prestador_file(prestador))?;
    let amb = cfg.val("dps", "tpAmb", AMBIENTE_PRODUCAO);
    Ok(if ambiente_rotulo(&amb).is_some() {
        amb
    } else {
        AMBIENTE_PRODUCAO.to_string()
    })
}

fn definir_opcao_dps(prestador: &str, opcao: &str, valor: &str) -> Res<()> {
    let caminho = config_prestador_file(prestador);
    let mut ini = ler(&caminho)?;
    garantir_secao_dps(&mut ini);
    ini.por("dps", opcao, valor);
    banco::save_ini(&caminho, &ini)
}

pub fn set_ambiente(prestador: &str, ambiente: &str) -> Res<()> {
    if ambiente_rotulo(ambiente).is_none() {
        return Err(Erro::valor(format!(
            "Ambiente inválido: {}.",
            pyfmt::repr(ambiente)
        )));
    }
    definir_opcao_dps(prestador, "tpAmb", ambiente)
}

/// Série do ambiente; na falta, a de [dps] e por fim '00001'.
pub fn get_serie(prestador: &str, ambiente: &str) -> Res<String> {
    let s = ler(&numeracao_file(prestador))?.val(ambiente, "serie", "");
    if !s.is_empty() {
        return Ok(s);
    }
    Ok(ler(&config_prestador_file(prestador))?.val("dps", "serie", "00001"))
}

/// TSSerieDPS do XSD v1.01: de 1 a 5 dígitos, até 89999.
fn serie_valida(s: &str) -> bool {
    let b = s.as_bytes();
    b.iter().all(u8::is_ascii_digit)
        && ((1..=4).contains(&b.len()) || (b.len() == 5 && b[0] <= b'8'))
}

pub fn set_serie(prestador: &str, ambiente: &str, serie: &str) -> Res<()> {
    let serie = aparar(serie);
    if serie.is_empty() {
        return Err(Erro::valor("Série não pode ser vazia."));
    }
    if !serie_valida(serie) {
        return Err(Erro::valor(
            "Série inválida: use só números, de 1 a 5 dígitos (até 89999). Ex.: 00001.",
        ));
    }
    let caminho = numeracao_file(prestador);
    let mut ini = ler(&caminho)?;
    ini.por(ambiente, "serie", serie);
    banco::save_ini(&caminho, &ini)
}

pub fn get_last_dps(prestador: &str, ambiente: Option<&str>) -> Res<i64> {
    Ok(banco::get_contador(&last_dps_file(prestador, ambiente))?.unwrap_or(0))
}

/// Próximo número de DPS que será emitido no ambiente (último + 1).
pub fn get_proximo_dps(prestador: &str, ambiente: Option<&str>) -> Res<i64> {
    Ok(get_last_dps(prestador, ambiente)? + 1)
}

/// Define o próximo nº de DPS do ambiente (grava último = próximo - 1).
pub fn set_proximo_dps(prestador: &str, ambiente: &str, proximo: i64) -> Res<()> {
    if proximo < 1 {
        return Err(Erro::valor("O próximo nº de DPS deve ser >= 1."));
    }
    banco::set_contador(&last_dps_file(prestador, Some(ambiente)), proximo - 1)
}

// ------------------------------------------------------------------------------- //
// Grupos de clientes
// ------------------------------------------------------------------------------- //
pub const SEM_GRUPO: &str = "(Sem grupo)";
pub const GRUPO_MAX: usize = 20; // comprimento máximo do nome de um grupo

pub fn grupos_file(prestador: &str) -> String {
    format!("{}/grupos.ini", prestador_dir(prestador))
}

fn ler_grupos(prestador: &str) -> Res<Ini> {
    let mut ini = ler(&grupos_file(prestador))?;
    ini.garantir_secao("grupos");
    ini.garantir_secao("membros");
    Ok(ini)
}

fn gravar_grupos(prestador: &str, ini: &Ini) -> Res<()> {
    banco::save_ini(&grupos_file(prestador), ini)
}

fn nomes_dos_grupos(ini: &Ini) -> Vec<String> {
    ini.itens("grupos")
        .into_iter()
        .map(|(_, v)| aparar(v).to_string())
        .filter(|v| !v.is_empty())
        .collect()
}

/// Mapa documento -> grupo de todos os tomadores.
pub fn tomadores_grupos(prestador: &str) -> Res<Vec<(String, String)>> {
    let ini = ler_grupos(prestador)?;
    Ok(ini
        .itens("membros")
        .into_iter()
        .filter(|(_, g)| !aparar(g).is_empty())
        .map(|(doc, g)| (only_doc(doc), aparar(g).to_string()))
        .collect())
}

/// Grupos em ordem crescente (sem acento/caixa).
pub fn list_grupos(prestador: &str) -> Res<Vec<String>> {
    if prestador.is_empty() {
        return Ok(Vec::new());
    }
    let mut nomes = nomes_dos_grupos(&ler_grupos(prestador)?);
    nomes.sort_by_cached_key(|n| sort_nome(n));
    Ok(nomes)
}

fn regravar_grupos(ini: &mut Ini, nomes: &[String]) {
    ini.remover_secao("grupos");
    ini.garantir_secao("grupos");
    for (i, nome) in nomes.iter().enumerate() {
        ini.por("grupos", &format!("g{}", i + 1), nome);
    }
}

fn mesma_caixa(a: &str, b: &str) -> bool {
    texto::casefold(a) == texto::casefold(b)
}

pub fn add_grupo(prestador: &str, nome: &str) -> Res<()> {
    let nome = aparar(nome);
    if nome.is_empty() {
        return Err(Erro::valor("Nome do grupo não pode ser vazio."));
    }
    if nome.chars().count() > GRUPO_MAX {
        return Err(Erro::valor(format!(
            "O grupo deve ter no máximo {GRUPO_MAX} caracteres."
        )));
    }
    let mut ini = ler_grupos(prestador)?;
    let mut nomes = nomes_dos_grupos(&ini);
    if nomes.iter().any(|n| mesma_caixa(n, nome)) {
        return Err(Erro::valor(format!(
            "Já existe um grupo chamado {}.",
            pyfmt::repr(nome)
        )));
    }
    nomes.push(nome.to_string());
    regravar_grupos(&mut ini, &nomes);
    gravar_grupos(prestador, &ini)
}

pub fn rename_grupo(prestador: &str, antigo: &str, novo: &str) -> Res<()> {
    let novo = aparar(novo);
    if novo.is_empty() {
        return Err(Erro::valor("Nome do grupo não pode ser vazio."));
    }
    if novo.chars().count() > GRUPO_MAX {
        return Err(Erro::valor(format!(
            "O grupo deve ter no máximo {GRUPO_MAX} caracteres."
        )));
    }
    let mut ini = ler_grupos(prestador)?;
    let nomes = nomes_dos_grupos(&ini);
    if !nomes.iter().any(|n| n == antigo) {
        return Err(Erro::valor(format!(
            "Grupo {} não encontrado.",
            pyfmt::repr(antigo)
        )));
    }
    if nomes.iter().any(|n| mesma_caixa(n, novo) && n != antigo) {
        return Err(Erro::valor(format!(
            "Já existe um grupo chamado {}.",
            pyfmt::repr(novo)
        )));
    }
    let nomes: Vec<String> = nomes
        .into_iter()
        .map(|n| if n == antigo { novo.to_string() } else { n })
        .collect();
    regravar_grupos(&mut ini, &nomes);
    let membros: Vec<String> = ini
        .itens("membros")
        .into_iter()
        .filter(|(_, g)| aparar(g) == antigo)
        .map(|(d, _)| d.to_string())
        .collect();
    for doc in membros {
        ini.por("membros", &doc, novo);
    }
    gravar_grupos(prestador, &ini)
}

pub fn remove_grupo(prestador: &str, nome: &str) -> Res<()> {
    let mut ini = ler_grupos(prestador)?;
    let nomes: Vec<String> = nomes_dos_grupos(&ini)
        .into_iter()
        .filter(|n| n != nome)
        .collect();
    regravar_grupos(&mut ini, &nomes);
    let membros: Vec<String> = ini
        .itens("membros")
        .into_iter()
        .filter(|(_, g)| aparar(g) == nome)
        .map(|(d, _)| d.to_string())
        .collect();
    for doc in membros {
        ini.remover_opcao("membros", &doc);
    }
    gravar_grupos(prestador, &ini)
}

pub fn get_tomador_grupo(prestador: &str, tomador: &str) -> Res<String> {
    if prestador.is_empty() || tomador.is_empty() {
        return Ok(String::new());
    }
    Ok(ler_grupos(prestador)?.val("membros", &only_doc(tomador), ""))
}

pub fn set_tomador_grupo(prestador: &str, tomador: &str, grupo: &str) -> Res<()> {
    let tomador = only_doc(tomador);
    if tomador.is_empty() {
        return Ok(());
    }
    let mut ini = ler_grupos(prestador)?;
    let grupo = aparar(grupo);
    if !grupo.is_empty() && grupo != SEM_GRUPO {
        ini.por("membros", &tomador, grupo);
    } else if ini.tem_opcao("membros", &tomador) {
        ini.remover_opcao("membros", &tomador);
    }
    gravar_grupos(prestador, &ini)
}

/// Move o cadastro do cliente quando o documento (CNPJ/CPF) é editado: as chaves dele no banco
/// (cadastro/serviços) e a associação de grupo. Erro se já existir um cliente com o novo
/// documento. As notas já emitidas não mudam.
pub fn rename_tomador(prestador: &str, doc_antigo: &str, doc_novo: &str) -> Res<()> {
    let (antigo, novo) = (only_doc(doc_antigo), only_doc(doc_novo));
    if antigo.is_empty() || antigo == novo {
        return Ok(());
    }
    if !tomador_cadastrado(prestador, &antigo)? {
        return Ok(()); // cliente ainda não salvo
    }
    if tomador_cadastrado(prestador, &novo)? {
        return Err(Erro::valor(format!(
            "Já existe um cliente com o documento {}.",
            format_documento(&novo)
        )));
    }
    let grupo = get_tomador_grupo(prestador, &antigo)?;
    banco::rename_prefix(
        &tomador_dir(prestador, &antigo),
        &tomador_dir(prestador, &novo),
    )?;
    if !grupo.is_empty() {
        set_tomador_grupo(prestador, &antigo, "")?; // remove vínculo antigo
        set_tomador_grupo(prestador, &novo, &grupo)?; // recria no novo documento
    }
    Ok(())
}
