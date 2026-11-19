//! Domínios IBS/CBS e listas de serviço publicados para a NFS-e em produção.
//!
//! Os arquivos em configs/ são fotografias das tabelas oficiais. O portal não é consultado
//! durante uma emissão, para que uma indisponibilidade não altere o XML.
//!
//! Duas tabelas podem ser atualizadas pelo botão "Atualizar tabelas tributárias" (Configurações ›
//! Avançado › Emissão), sem esperar uma versão nova do programa:
//! - cClassTrib (CST × classificação tributária) do portal Conformidade Fácil da SVRS
//!   (dfe-portal.svrs.rs.gov.br/CFF/ClassificacaoTributaria): a página traz a tabela inteira em
//!   JSON público; ficam as classificações com IndNfse e vigentes hoje. A API oficial
//!   (cff.svrs.rs.gov.br/api/v1/consultas/classTrib) exige certificado ICP-Brasil e não é usada.
//! - Anexo VIII da NFS-e (correlação Item LC 116 × NBS × cIndOp × cClassTrib), planilha .xlsx
//!   publicada em gov.br/nfse › Documentação técnica › RTC. A própria SE/CGNFS-e diz que é um
//!   trabalho inicial: a correlação ORIENTA (filtra as listas e gera avisos), não bloqueia.
//!
//! As tabelas baixadas ficam em logs/tabelas/: na instalação, é a única pasta que o serviço de
//! dados grava e que todo usuário lê (a tela consulta o catálogo no próprio processo). Um
//! arquivo baixado só vale se estiver completo; senão, valem as fotografias de configs/.
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock, RwLock};

use serde_json::{Value, json};

use crate::caminhos;
use crate::despacho::Avisar;
use crate::erro::{Erro, Res};

const ARQ_CLASSIFICACOES: &str = "rtc_classificacoes.json";
const ARQ_CORRELACAO: &str = "correlacao_nbs.json";
const URL_CFF: &str = "https://dfe-portal.svrs.rs.gov.br/CFF/ClassificacaoTributaria";
const URL_RTC: &str = "https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/rtc";
/// Mínimos de sanidade: uma tabela baixada menor que isto é recusada (página mudou, erro).
const MIN_CLASSIFICACOES: usize = 30;
const MIN_CORRELACOES: usize = 500;

fn tabela_de(caminho: &std::path::Path) -> Value {
    std::fs::read(caminho)
        .ok()
        .and_then(|b| serde_json::from_slice(b.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&b)).ok())
        .unwrap_or(Value::Null)
}

fn tabela(arquivo: &str) -> Value {
    tabela_de(&caminhos::recurso(&["configs", arquivo]))
}

/// Onde ficam as tabelas baixadas pelo botão.
pub fn pasta_tabelas() -> PathBuf {
    crate::registro::pasta_logs().join("tabelas")
}

/// A tabela baixada (se existir e tiver ao menos `minimo` itens em `chave`) ou a de configs/.
fn tabela_atualizavel(arquivo: &str, chave: &str, minimo: usize) -> Value {
    let baixada = tabela_de(&pasta_tabelas().join(arquivo));
    if baixada
        .get(chave)
        .and_then(Value::as_array)
        .is_some_and(|a| a.len() >= minimo)
    {
        return baixada;
    }
    tabela(arquivo)
}

fn lista(
    arquivo: &'static str,
    chave: &'static str,
    guarda: &'static OnceLock<Vec<Value>>,
) -> &'static [Value] {
    guarda.get_or_init(|| {
        tabela(arquivo)
            .get(chave)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    })
}

/// A tabela de produção mais os códigos que só existem no leiaute novo da NFS-e (NT 009), de um
/// arquivo à parte: a fotografia da tabela de produção continua igual à oficial.
fn lista_com_novos(
    arquivo: &'static str,
    novos: &'static str,
    chave: &'static str,
    guarda: &'static OnceLock<Vec<Value>>,
) -> &'static [Value] {
    guarda.get_or_init(|| {
        let ler = |nome: &str| {
            tabela(nome)
                .get(chave)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        };
        let mut itens = ler(arquivo);
        for novo in ler(novos) {
            if !itens.iter().any(|i| t(i, "codigo") == t(&novo, "codigo")) {
                itens.push(novo);
            }
        }
        itens
    })
}

fn operacoes() -> &'static [Value] {
    static T: OnceLock<Vec<Value>> = OnceLock::new();
    lista_com_novos("indic_op.json", "indic_op_nt009.json", "operacoes", &T)
}

// ---- tabelas recarregáveis --------------------------------------------------------------- //
static CLASSIFICACOES: RwLock<Option<Arc<Vec<Value>>>> = RwLock::new(None);
/// Linhas do Anexo VIII: [item da LC 116 só com dígitos, NBS, cIndOp, cClassTrib].
static CORRELACOES: RwLock<Option<Arc<Vec<[String; 4]>>>> = RwLock::new(None);

fn cache<T>(guarda: &RwLock<Option<Arc<T>>>, carregar: impl FnOnce() -> T) -> Arc<T> {
    if let Some(v) = guarda
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
    {
        return v.clone();
    }
    let v = Arc::new(carregar());
    *guarda.write().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(v.clone());
    v
}

fn classificacoes() -> Arc<Vec<Value>> {
    cache(&CLASSIFICACOES, || {
        tabela_atualizavel(ARQ_CLASSIFICACOES, "classificacoes", MIN_CLASSIFICACOES)
            .get("classificacoes")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    })
}

fn so_digitos(s: &str) -> String {
    s.chars().filter(char::is_ascii_digit).collect()
}

fn correlacoes() -> Arc<Vec<[String; 4]>> {
    cache(&CORRELACOES, || {
        tabela_atualizavel(ARQ_CORRELACAO, "correlacoes", MIN_CORRELACOES)
            .get("correlacoes")
            .and_then(Value::as_array)
            .map(|linhas| {
                linhas
                    .iter()
                    .filter_map(|l| {
                        let c = |i: usize| l.get(i).and_then(Value::as_str).unwrap_or("");
                        let linha = [so_digitos(c(0)), so_digitos(c(1)), so_digitos(c(2)), so_digitos(c(3))];
                        (!linha[0].is_empty() && !linha[1].is_empty() && !linha[3].is_empty())
                            .then_some(linha)
                    })
                    .collect()
            })
            .unwrap_or_default()
    })
}

/// Esquece as tabelas em memória: a próxima consulta relê (depois de atualizar pelo botão).
pub fn recarregar() {
    *CLASSIFICACOES.write().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    *CORRELACOES.write().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
}

fn tributacao_nacional() -> &'static [Value] {
    static T: OnceLock<Vec<Value>> = OnceLock::new();
    lista_com_novos(
        "cod_tribut_nac.json",
        "cod_tribut_nac_nt009.json",
        "tributacao_nacional",
        &T,
    )
}

fn nbs() -> &'static [Value] {
    static T: OnceLock<Vec<Value>> = OnceLock::new();
    lista("item_nbs.json", "nbs", &T)
}

fn t<'a>(item: &'a Value, campo: &str) -> &'a str {
    item.get(campo).and_then(Value::as_str).unwrap_or("")
}

pub type Opcoes = Vec<(String, String)>;

/// (código, "código - tipo - local") do indicador da operação.
pub fn indop_options() -> &'static Opcoes {
    static O: OnceLock<Opcoes> = OnceLock::new();
    O.get_or_init(|| {
        operacoes()
            .iter()
            .map(|i| {
                (
                    t(i, "codigo").to_string(),
                    format!("{} - {} - {}", t(i, "codigo"), t(i, "tipo"), t(i, "local")),
                )
            })
            .collect()
    })
}

/// (CST, "CST - nome"), em ordem de código.
pub fn cst_options() -> Opcoes {
    let mut nomes: std::collections::BTreeMap<String, String> = Default::default();
    for i in classificacoes().iter() {
        nomes.insert(t(i, "cst").to_string(), t(i, "cst_nome").to_string());
    }
    nomes
        .into_iter()
        .map(|(c, n)| (c.clone(), format!("{c} - {n}")))
        .collect()
}

/// (código, "código - descrição") das classificações de um CST.
pub fn class_options(cst: &str) -> Opcoes {
    classificacoes()
        .iter()
        .filter(|i| t(i, "cst") == cst)
        .map(|i| {
            (
                t(i, "codigo").to_string(),
                format!("{} - {}", t(i, "codigo"), t(i, "descricao")),
            )
        })
        .collect()
}

/// "código - descrição" de uma classificação tributária do IBS/CBS (vazio se não está na tabela).
pub fn classtrib_rotulo(codigo: &str) -> String {
    classificacoes()
        .iter()
        .find(|i| t(i, "codigo") == codigo)
        .map(|i| format!("{} - {}", t(i, "codigo"), t(i, "descricao")))
        .unwrap_or_default()
}

pub fn valid_indop(codigo: &str) -> bool {
    operacoes().iter().any(|i| t(i, "codigo") == codigo)
}

pub fn valid_classification(cst: &str, codigo: &str) -> bool {
    classificacoes()
        .iter()
        .any(|i| t(i, "cst") == cst && t(i, "codigo") == codigo)
}

fn classificacao_nfse(codigo: &str) -> bool {
    classificacoes().iter().any(|i| t(i, "codigo") == codigo)
}

/// (código, "00.00.00 - descrição") da tributação nacional.
pub fn tribnac_options() -> &'static Opcoes {
    static O: OnceLock<Opcoes> = OnceLock::new();
    O.get_or_init(|| {
        tributacao_nacional()
            .iter()
            .map(|i| {
                let c: Vec<char> = t(i, "codigo").chars().collect();
                let parte = |a: usize, b: usize| {
                    c.iter()
                        .skip(a)
                        .take(b.saturating_sub(a))
                        .collect::<String>()
                };
                let resto: String = c.iter().skip(4).collect();
                (
                    t(i, "codigo").to_string(),
                    format!(
                        "{}.{}.{} - {}",
                        parte(0, 2),
                        parte(2, 4),
                        resto,
                        t(i, "descricao")
                    ),
                )
            })
            .collect()
    })
}

/// (código, "código - descrição") dos itens da NBS.
pub fn nbs_options() -> &'static Opcoes {
    static O: OnceLock<Opcoes> = OnceLock::new();
    O.get_or_init(|| {
        nbs()
            .iter()
            .map(|i| {
                let (c, d) = (t(i, "codigo"), t(i, "descricao"));
                (
                    c.to_string(),
                    if d.is_empty() {
                        c.to_string()
                    } else {
                        format!("{c} - {d}")
                    },
                )
            })
            .collect()
    })
}

/// Deixa tabelas e rótulos prontos para a sessão.
pub fn preload() {
    indop_options();
    cst_options();
    tribnac_options();
    nbs_options();
    correlacoes();
}

pub fn valid_tribnac(codigo: &str) -> bool {
    tributacao_nacional()
        .iter()
        .any(|i| t(i, "codigo") == codigo)
}

pub fn valid_nbs(codigo: &str) -> bool {
    nbs().iter().any(|i| t(i, "codigo") == codigo)
}

// ------------------------------------------------------------------------------------------- //
// Compatibilidade tributária (Anexo VIII)
// ------------------------------------------------------------------------------------------- //
/// "0101" → "01.01"; "990201" → "99.02.01".
fn item_formatado(item: &str) -> String {
    item.as_bytes()
        .chunks(2)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect::<Vec<_>>()
        .join(".")
}

/// CST da tributação integral: a regra geral do IBS/CBS (LC 214/2025, art. 4º). O Anexo VIII
/// às vezes só lista as exceções de um NBS (ex.: construção 1.0101.11.00 traz só reduções),
/// então as classificações deste CST nunca são escondidas nem geram aviso.
const CST_INTEGRAL: &str = "000";

/// O que o Anexo VIII diz de um NBS: indicadores de operação, classificações e CSTs que
/// combinam com ele (só os que existem nas tabelas da NFS-e; a tributação integral sempre
/// entra) e se o item do cTribNac aparece ligado a ele. `conhecido` = false: o NBS não está no
/// anexo e nada é filtrado.
pub fn compatibilidade(nbs: &str, trib_nac: &str) -> Value {
    let (nbs, trib_nac) = (so_digitos(nbs), so_digitos(trib_nac));
    let tabela = correlacoes();
    let linhas: Vec<&[String; 4]> = tabela.iter().filter(|l| l[1] == nbs).collect();
    let indop: BTreeSet<&str> = linhas
        .iter()
        .map(|l| l[2].as_str())
        .filter(|c| valid_indop(c))
        .collect();
    let todas = classificacoes();
    let mut classes: BTreeSet<&str> = linhas
        .iter()
        .map(|l| l[3].as_str())
        .filter(|c| classificacao_nfse(c))
        .collect();
    if !linhas.is_empty() {
        classes.extend(
            todas
                .iter()
                .filter(|i| t(i, "cst") == CST_INTEGRAL)
                .map(|i| t(i, "codigo")),
        );
    }
    let csts: BTreeSet<&str> = todas
        .iter()
        .filter(|i| classes.contains(t(i, "codigo")))
        .map(|i| t(i, "cst"))
        .collect();
    let itens: BTreeSet<String> = linhas.iter().map(|l| item_formatado(&l[0])).collect();
    let item_ok = trib_nac.is_empty()
        || linhas.is_empty()
        || linhas.iter().any(|l| trib_nac.starts_with(l[0].as_str()));
    json!({
        "conhecido": !linhas.is_empty(),
        "indop": indop,
        "cclasstrib": classes,
        "csts": csts,
        "itens": itens,
        "item_ok": item_ok,
    })
}

/// Avisos (não bloqueiam) de uma combinação que o Anexo VIII não prevê. Vazio quando o NBS
/// não está no anexo ou quando a combinação aparece nele.
pub fn avisos_correlacao(trib_nac: &str, nbs: &str, indop: &str, cclass: &str) -> Vec<String> {
    let nbs_d = so_digitos(nbs);
    if nbs_d.is_empty() {
        return Vec::new();
    }
    let c = compatibilidade(&nbs_d, trib_nac);
    if c["conhecido"] != true {
        return Vec::new();
    }
    let lista = |k: &str| -> Vec<String> {
        c[k].as_array()
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default()
    };
    let mut avisos = Vec::new();
    if c["item_ok"] == false {
        let trib = so_digitos(trib_nac);
        avisos.push(format!(
            "O NBS {nbs_d} não aparece ligado ao item {} da LC 116 no Anexo VIII (itens previstos: {}).",
            item_formatado(&trib[..trib.len().min(4)]),
            lista("itens").join(", ")
        ));
    }
    let indops = lista("indop");
    if !indop.is_empty() && !indops.is_empty() && !indops.iter().any(|i| i == indop) {
        avisos.push(format!(
            "O indicador da operação {indop} não está previsto para o NBS {nbs_d} no Anexo VIII (previstos: {}).",
            indops.join(", ")
        ));
    }
    let classes = lista("cclasstrib");
    let integral = classificacoes()
        .iter()
        .any(|i| t(i, "codigo") == cclass && t(i, "cst") == CST_INTEGRAL);
    if !cclass.is_empty() && !integral && !classes.is_empty() && !classes.iter().any(|i| i == cclass) {
        avisos.push(format!(
            "A classificação tributária {cclass} não está prevista para o NBS {nbs_d} no Anexo VIII (previstas: {}).",
            classes.join(", ")
        ));
    }
    avisos
}

/// Versão e origem das tabelas em uso (fotografia do programa ou baixada pelo botão).
pub fn situacao_tabelas() -> Value {
    let info = |arquivo: &str, chave: &str, minimo: usize| {
        let baixada = tabela_de(&pasta_tabelas().join(arquivo));
        let usa_baixada = baixada
            .get(chave)
            .and_then(Value::as_array)
            .is_some_and(|a| a.len() >= minimo);
        let v = if usa_baixada { baixada } else { tabela(arquivo) };
        json!({
            "origem": if usa_baixada { "baixada" } else { "programa" },
            "versao": v.get("versao").and_then(Value::as_str).unwrap_or(""),
            "consultado_em": v.get("consultado_em").and_then(Value::as_str).unwrap_or(""),
            "fonte": v.get("fonte").and_then(Value::as_str).unwrap_or(""),
            "quantidade": v.get(chave).and_then(Value::as_array).map_or(0, Vec::len),
        })
    };
    json!({
        "classificacoes": info(ARQ_CLASSIFICACOES, "classificacoes", MIN_CLASSIFICACOES),
        "correlacao": info(ARQ_CORRELACAO, "correlacoes", MIN_CORRELACOES),
    })
}

// ------------------------------------------------------------------------------------------- //
// Atualização pelos portais oficiais
// ------------------------------------------------------------------------------------------- //
fn sessao() -> Res<crate::rede::Sessao> {
    crate::rede::Sessao::nova(
        None,
        crate::rede::Tempo {
            conectar: 10.0,
            ler: 60.0,
        },
        "Baiacu-NFS-e (tabelas)",
        false,
    )
}

fn baixar(url: &str) -> Res<Vec<u8>> {
    let r = sessao()?.get(url, &[])?;
    if r.status != 200 {
        return Err(Erro::valor(format!("O portal respondeu {} em {url}.", r.status)));
    }
    Ok(r.corpo)
}

fn gravar_tabela(arquivo: &str, v: &Value) -> Res<()> {
    let pasta = pasta_tabelas();
    std::fs::create_dir_all(&pasta)?;
    let tmp = pasta.join(format!("{arquivo}.tmp"));
    std::fs::write(&tmp, serde_json::to_vec_pretty(v)?)?;
    std::fs::rename(&tmp, pasta.join(arquivo))?;
    Ok(())
}

/// As classificações da página do Conformidade Fácil (JSON embutido em `dadosOriginais`):
/// só as que valem para NFS-e e estão vigentes em `hoje` (AAAA-MM-DD).
pub fn classificacoes_do_cff(html: &str, hoje: &str) -> Res<Vec<Value>> {
    let ilegivel = || Erro::valor("A página do Conformidade Fácil mudou: a tabela não foi encontrada.");
    let ini = html.find("var dadosOriginais = ").ok_or_else(ilegivel)? + 21;
    let mut fluxo = serde_json::Deserializer::from_str(&html[ini..]).into_iter::<Value>();
    let dados = fluxo.next().ok_or_else(ilegivel)?.map_err(|_| ilegivel())?;
    let data = |v: &Value| v.as_str().map(|s| s.chars().take(10).collect::<String>());
    let mut out = Vec::new();
    for cst in dados.as_array().ok_or_else(ilegivel)? {
        for c in cst["ClassificacoesTributarias"].as_array().into_iter().flatten() {
            let inicio = data(&c["DthIniVig"]).unwrap_or_default();
            let fim = data(&c["DthFimVig"]);
            if c["IndNfse"] == true
                && inicio.as_str() <= hoje
                && fim.as_deref().is_none_or(|f| f >= hoje)
            {
                out.push(json!({
                    "cst": t(cst, "Cst"),
                    "cst_nome": t(cst, "NomeCst"),
                    "codigo": t(c, "CodClassTrib"),
                    "descricao": t(c, "NomeClassTrib"),
                }));
            }
        }
    }
    Ok(out)
}

/// O link do Anexo VIII mais novo na página de documentação RTC (pela versão no nome).
pub fn link_anexo_viii(html: &str) -> Option<String> {
    let rx = regex::Regex::new(r#"href="([^"]*anexo[_-]?viii[^"]*\.xlsx)""#).ok()?;
    let versao = regex::Regex::new(r"v(\d+)-(\d+)-(\d+)").ok()?;
    rx.captures_iter(&html.to_ascii_lowercase())
        .map(|c| c[1].to_string())
        .max_by_key(|url| {
            versao
                .captures(url)
                .map(|v| (v[1].parse::<u32>().unwrap_or(0), v[2].parse::<u32>().unwrap_or(0), v[3].parse::<u32>().unwrap_or(0)))
                .unwrap_or_default()
        })
        .map(|u| if u.starts_with("http") { u } else { format!("https://www.gov.br{u}") })
}

/// Linhas completas do Anexo VIII (aba "tabela geral"), pelas colunas do cabeçalho.
pub fn correlacoes_do_anexo(bytes: &[u8]) -> Res<Vec<Value>> {
    let linhas = crate::planilha::ler_xlsx(bytes, Some("tabela geral"), true)
        .or_else(|_| crate::planilha::ler_xlsx(bytes, None, true))?;
    let norm = |s: &str| s.trim().to_lowercase();
    let (&pos_cab, cab) = linhas
        .iter()
        .find(|(_, l)| l.values().any(|c| norm(c) == "nbs") && l.values().any(|c| norm(c) == "cclasstrib"))
        .ok_or_else(|| Erro::valor("O Anexo VIII mudou de formato: cabeçalho não encontrado."))?;
    let col = |f: &dyn Fn(&str) -> bool| cab.iter().find_map(|(&i, c)| f(&norm(c)).then_some(i));
    let (Some(item), Some(nbs), Some(indop), Some(classe)) = (
        col(&|c| c.starts_with("item")),
        col(&|c| c == "nbs"),
        col(&|c| c == "indop" || c == "cindop"),
        col(&|c| c == "cclasstrib"),
    ) else {
        return Err(Erro::valor("O Anexo VIII mudou de formato: faltam colunas."));
    };
    let mut vistos = BTreeSet::new();
    for (_, l) in linhas.range(pos_cab + 1..) {
        let campo = |i: usize| l.get(&i).map(|s| s.trim().to_string()).unwrap_or_default();
        let (it, nb, op, cl) = (campo(item), so_digitos(&campo(nbs)), so_digitos(&campo(indop)), so_digitos(&campo(classe)));
        if it.is_empty() || nb.is_empty() || cl.is_empty() {
            continue;
        }
        let op = if op.is_empty() { op } else { format!("{op:0>6}") };
        vistos.insert((it, nb, op, format!("{cl:0>6}")));
    }
    Ok(vistos.into_iter().map(|(a, b, c, d)| json!([a, b, c, d])).collect())
}

/// Baixa as tabelas dos portais oficiais e passa a usá-las. Cada tabela é independente: uma
/// que falhe mantém a anterior. Devolve o resultado de cada uma.
pub fn atualizar_tabelas(avisar: Avisar) -> Res<Value> {
    let hoje = chrono::Local::now().format("%Y-%m-%d").to_string();
    let mut resultado = Vec::new();

    avisar(&json!({"etapa": "Consultando o Conformidade Fácil (cClassTrib)…"}));
    let r = (|| -> Res<usize> {
        let html = String::from_utf8_lossy(&baixar(URL_CFF)?).into_owned();
        let classes = classificacoes_do_cff(&html, &hoje)?;
        if classes.len() < MIN_CLASSIFICACOES {
            return Err(Erro::valor(format!("Só {} classificações vieram do portal: tabela recusada.", classes.len())));
        }
        let n = classes.len();
        gravar_tabela(ARQ_CLASSIFICACOES, &json!({
            "fonte": URL_CFF,
            "consultado_em": hoje,
            "versao": format!("Conformidade Fácil, consultado em {hoje}"),
            "criterio": format!("IndNfse=true e vigencia em {hoje}"),
            "classificacoes": classes,
        }))?;
        Ok(n)
    })();
    resultado.push(match r {
        Ok(n) => json!({"tabela": "Classificação tributária (cClassTrib)", "ok": true, "quantidade": n}),
        Err(e) => json!({"tabela": "Classificação tributária (cClassTrib)", "ok": false, "erro": e.msg}),
    });

    avisar(&json!({"etapa": "Procurando o Anexo VIII na documentação da NFS-e…"}));
    let r = (|| -> Res<(usize, String)> {
        let pagina = String::from_utf8_lossy(&baixar(URL_RTC)?).into_owned();
        let url = link_anexo_viii(&pagina)
            .ok_or_else(|| Erro::valor("O Anexo VIII não foi encontrado na página de documentação RTC."))?;
        avisar(&json!({"etapa": "Baixando o Anexo VIII…"}));
        let linhas = correlacoes_do_anexo(&baixar(&url)?)?;
        if linhas.len() < MIN_CORRELACOES {
            return Err(Erro::valor(format!("Só {} correlações no Anexo VIII baixado: tabela recusada.", linhas.len())));
        }
        let n = linhas.len();
        let nome = url.rsplit('/').next().unwrap_or("").to_string();
        gravar_tabela(ARQ_CORRELACAO, &json!({
            "fonte": url,
            "versao": format!("Anexo VIII ({nome})"),
            "consultado_em": hoje,
            "aviso": "Trabalho inicial da SE/CGNFS-e, ainda em desenvolvimento: serve de orientação, não de bloqueio.",
            "colunas": ["item_lc116", "nbs", "indop", "cclasstrib"],
            "correlacoes": linhas,
        }))?;
        Ok((n, nome))
    })();
    resultado.push(match r {
        Ok((n, nome)) => json!({"tabela": "Correlação NBS (Anexo VIII)", "ok": true, "quantidade": n, "arquivo": nome}),
        Err(e) => json!({"tabela": "Correlação NBS (Anexo VIII)", "ok": false, "erro": e.msg}),
    });

    recarregar();
    for r in &resultado {
        crate::registro::info("catalogo", &format!("Atualização de tabelas: {r}"));
    }
    Ok(json!({"tabelas": resultado, "situacao": situacao_tabelas()}))
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn le_a_pagina_do_cff() {
        let html = r#"<script> var dadosOriginais = [{"Cst":"000","NomeCst":"Tributação integral","ClassificacoesTributarias":[
            {"CodClassTrib":"000001","NomeClassTrib":"Integral","IndNfse":true,"DthIniVig":"2025-05-05T00:00:00","DthFimVig":null},
            {"CodClassTrib":"000002","NomeClassTrib":"Só NF-e","IndNfse":false,"DthIniVig":"2025-05-05T00:00:00","DthFimVig":null},
            {"CodClassTrib":"000003","NomeClassTrib":"Vencida","IndNfse":true,"DthIniVig":"2025-05-05T00:00:00","DthFimVig":"2026-01-01T00:00:00"}]}];
            var outra = 1;</script>"#;
        let c = classificacoes_do_cff(html, "2026-11-18").unwrap();
        assert_eq!(c.len(), 1);
        assert_eq!(c[0]["codigo"], "000001");
        assert_eq!(c[0]["cst"], "000");
        assert!(classificacoes_do_cff("<html></html>", "2026-11-18").is_err());
    }

    #[test]
    fn escolhe_o_anexo_viii_mais_novo() {
        let html = r#"<a href="https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/rtc/anexoviii-correlacaoitemnbsindopcclasstrib_ibscbs_v1-01-00.xlsx">
            <a href="https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/rtc/anexo_viii-tabela-correlacao-v01-02-00-20261026.xlsx">
            <a href="/nfse/pt-br/x/anexovii-indop_ibscbs_v1-03-00-nt009.xlsx">"#;
        assert!(link_anexo_viii(html).unwrap().ends_with("anexo_viii-tabela-correlacao-v01-02-00-20261026.xlsx"));
        assert_eq!(link_anexo_viii("<p>nada</p>"), None);
    }

    /// Com BAIACU_TESTE_REDE=1, baixa de verdade dos portais (para NFSE_LOG_DIR/tabelas).
    #[test]
    fn atualiza_pelos_portais_se_pedido() {
        if std::env::var("BAIACU_TESTE_REDE").as_deref() != Ok("1") {
            return;
        }
        let r = atualizar_tabelas(&|_| {}).unwrap();
        eprintln!("{r:#}");
        for t in r["tabelas"].as_array().unwrap() {
            assert_eq!(t["ok"], true, "{t}");
        }
    }

    /// Com BAIACU_ANEXO_VIII apontando para a planilha oficial, confere a leitura real.
    #[test]
    fn le_a_planilha_oficial_se_informada() {
        let Ok(caminho) = std::env::var("BAIACU_ANEXO_VIII") else { return };
        let linhas = correlacoes_do_anexo(&std::fs::read(caminho).unwrap()).unwrap();
        assert!(linhas.len() >= MIN_CORRELACOES, "{}", linhas.len());
        eprintln!("Anexo VIII: {} correlações; primeira {}", linhas.len(), linhas[0]);
    }

    #[test]
    fn compatibilidade_pelo_anexo_viii() {
        // Fotografia do programa (configs/correlacao_nbs.json, Anexo VIII v1.02.00): a raiz do
        // projeto fica um nível acima do crate, aqui e na cópia do rodar_testes.
        caminhos::definir_raiz(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
        recarregar();
        let c = compatibilidade("115021000", "010101");
        assert_eq!(c["conhecido"], true);
        assert_eq!(c["item_ok"], true);
        assert!(c["indop"].as_array().unwrap().iter().any(|v| v == "100301"));
        assert!(c["cclasstrib"].as_array().unwrap().iter().any(|v| v == "000001"));
        assert!(avisos_correlacao("010101", "115021000", "100301", "000001").is_empty());
        let avisos = avisos_correlacao("070201", "115021000", "020201", "200001");
        assert_eq!(avisos.len(), 3, "{avisos:?}");
        // NBS fora do anexo: nenhum aviso.
        assert!(avisos_correlacao("010101", "999999999", "100301", "000001").is_empty());
        // Construção: o anexo só lista reduções (200045/200046), mas a tributação integral
        // continua oferecida e sem aviso.
        let c = compatibilidade("101011100", "070201");
        assert!(c["cclasstrib"].as_array().unwrap().iter().any(|v| v == "000001"));
        assert!(c["csts"].as_array().unwrap().iter().any(|v| v == "000"));
        assert!(avisos_correlacao("070201", "101011100", "020201", "000001").is_empty());
    }
}
