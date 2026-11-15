//! A config FINAL de uma emissão: cadastro do prestador + cliente/serviço, com os valores
//! forçados por quem chama (ambiente, série…) e os marcadores `{auto}` resolvidos (número,
//! datas, Id, tributos calculados).
use std::str::FromStr;

use rust_decimal::{Decimal, RoundingStrategy};

use crate::erro::{Erro, Res};
use crate::ini::Ini;
use crate::texto::aparar;
use crate::{banco, caminhos, pyfmt};

pub const PISCOFINS: &str = "valores.trib.tribFed.piscofins";
pub const TRIB_FED: &str = "valores.trib.tribFed";
pub const TOT_TRIB: &str = "valores.trib.totTrib.pTotTrib";
pub const VSERV: &str = "valores.vServPrest";
pub const DESCONTOS: &str = "valores.vDescCondIncond";
const TRIB_OFICIAIS: &str = "tags oficiais";
const TRIB_AUXILIARES: [&str; 2] = ["tags nao oficiais", "tags não oficiais"];
/// Percentuais próprios do serviço. Fora da árvore <dps>: nunca é emitido no XML.
const GUI_TRIBUTOS: &str = "gui.tributos";
/// Escolhas do serviço que não são campos da DPS (também fora do XML).
const GUI_SERVICO: &str = "gui.servico";
/// Seções que pertencem SÓ ao programa (não são campos da DPS). Saem da config final: o
/// montador trata toda seção sem ponto como filho de <infDPS> — um [email] que sobrasse viraria
/// uma tag <email> inválida no XML.
const SO_DO_PROGRAMA: [&str; 1] = ["email"];

/// Valores forçados por quem chama: ((seção, opção), valor), na ordem.
pub type Forcados = Vec<((String, String), String)>;

/// Acrescenta/substitui um valor forçado (mantendo a posição de quem já estava).
pub fn forcar(lista: &mut Forcados, secao: &str, opcao: &str, valor: &str) {
    match lista
        .iter_mut()
        .find(|((s, o), _)| s == secao && o == opcao)
    {
        Some((_, v)) => *v = valor.to_string(),
        None => lista.push(((secao.to_string(), opcao.to_string()), valor.to_string())),
    }
}

/// Falta um percentual de tributo: nem o serviço nem o prestador o informam.
pub const TRIBUTOS_INCOMPLETOS: &str = "TributosIncompletos";

pub struct Contexto<'a> {
    /// Chave do contador de numeração do ambiente.
    pub last_dps: &'a str,
    /// Chave dos tributos do prestador.
    pub tributos: &'a str,
}

fn valor(ini: &Ini, secao: &str, opcao: &str) -> String {
    ini.val(secao, opcao, "")
}

/// O texto é só um marcador `{…}`? Devolve o que vai dentro.
fn marcador(v: &str) -> Option<&str> {
    let dentro = v.strip_prefix('{')?.strip_suffix('}')?;
    if dentro.is_empty() || dentro.contains('{') || dentro.contains('}') {
        None
    } else {
        Some(dentro)
    }
}

fn e_auto(v: &str) -> bool {
    marcador(v).is_some_and(|d| aparar(d).to_lowercase() == "auto")
}

// ------------------------------------------------------------------------------- //
// Dinheiro e percentuais (aritmética decimal exata, arredondamento comercial)
// ------------------------------------------------------------------------------- //
pub fn decimal(texto: &str, rotulo: &str) -> Res<Decimal> {
    let bruto = aparar(texto).replace(',', ".");
    Decimal::from_str(&bruto)
        .or_else(|_| Decimal::from_scientific(&bruto))
        .map_err(|_| {
            Erro::valor(format!(
                "Não foi possível resolver {rotulo}: valor decimal inválido: {}",
                pyfmt::repr(texto)
            ))
        })
}

/// Arredondamento comercial: 0,005 sobe, abaixo desce.
pub fn dinheiro(v: Decimal) -> Decimal {
    v.round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero)
}

pub fn dinheiro_texto(v: Decimal) -> String {
    format!("{:.2}", dinheiro(v))
}

fn parte_percentual(base: Decimal, percentual: Decimal) -> Decimal {
    dinheiro(base * percentual / Decimal::ONE_HUNDRED)
}

fn decimal_da_config(ini: &Ini, secao: &str, opcao: &str) -> Res<Decimal> {
    let v = valor(ini, secao, opcao);
    if v.is_empty() {
        return Err(Erro::valor(format!(
            "Não foi possível resolver cálculo automático: campo ausente/vazio: [{secao}] {opcao}"
        )));
    }
    if marcador(&v).is_some() {
        return Err(Erro::valor(format!(
            "Não foi possível resolver cálculo automático: dependência ainda variável: [{secao}] {opcao} = {v}"
        )));
    }
    decimal(&v, &format!("[{secao}] {opcao}"))
}

/// Como cada percentual aparece para o usuário (Configurações › Prestador › Tributos).
fn rotulo_do_tributo(opcao: &str) -> &str {
    match opcao {
        "pAliqPis" => "PIS",
        "pAliqCofins" => "COFINS",
        "irrf" => "IRRF",
        "csll" => "CSLL",
        "pTotTribFed" => "total aproximado dos tributos federais",
        "pTotTribEst" => "total aproximado dos tributos estaduais",
        "pTotTribMun" => "total aproximado dos tributos municipais",
        outro => outro,
    }
}

/// Percentual dos tributos do PRESTADOR. Prestador que ainda não os preencheu: erro com o nome
/// do que falta.
fn tributo_do_prestador(ctx: &Contexto, secoes: &[&str], opcao: &str) -> Res<String> {
    let tributos = if banco::exists_ini(ctx.tributos)? {
        banco::load_ini(ctx.tributos, false)?
    } else {
        Ini::novo()
    };
    for secao in secoes {
        let v = valor(&tributos, secao, opcao);
        if !v.is_empty() {
            return Ok(v);
        }
    }
    Err(Erro::novo(
        TRIBUTOS_INCOMPLETOS,
        format!(
            "Falta o percentual de {}. Preencha os tributos do prestador em Configurações › Prestador, ou informe \
             esse percentual no próprio serviço.",
            rotulo_do_tributo(opcao)
        ),
    ))
}

// ------------------------------------------------------------------------------- //
// Cada {auto}
// ------------------------------------------------------------------------------- //
fn auto_ndps(ctx: &Contexto) -> Res<String> {
    match banco::get_contador(ctx.last_dps)? {
        Some(v) => Ok((v + 1).to_string()),
        None => Err(Erro::nao_encontrado(format!(
            "Não foi possível resolver [dps] nDPS = {{auto}}: contador não encontrado: {}",
            caminhos::normalizar(&caminhos::absoluto(ctx.last_dps)).display()
        ))),
    }
}

/// Agora, com o fuso da máquina ("2026-10-09T10:00:00-03:00").
pub fn agora_iso() -> String {
    chrono::Local::now()
        .format("%Y-%m-%dT%H:%M:%S%:z")
        .to_string()
}

fn hoje_iso() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

fn auto_versao() -> Res<String> {
    let caminho = caminhos::recurso(&["configs"]).join("paths.ini");
    if !caminho.exists() {
        return Err(Erro::nao_encontrado(format!(
            "Não foi possível ler o config: {}",
            caminho.display()
        )));
    }
    let v = valor(&Ini::de_arquivo(&caminho, false)?, "schemas", "versao");
    if v.is_empty() {
        return Err(Erro::valor(
            "Não foi possível resolver [dps] versao = {auto}: campo ausente/vazio em paths.ini: [schemas] versao",
        ));
    }
    Ok(v)
}

fn zeros(s: &str, largura: usize) -> String {
    let n = s.chars().count();
    if n >= largura {
        s.to_string()
    } else {
        format!("{}{s}", "0".repeat(largura - n))
    }
}

fn auto_id(ini: &Ini) -> Res<String> {
    let c_loc_emi = valor(ini, "dps", "cLocEmi");
    let serie = valor(ini, "dps", "serie");
    let ndps = valor(ini, "dps", "nDPS");
    let cnpj = valor(ini, "prest", "CNPJ");
    let cpf = valor(ini, "prest", "CPF");
    if !cnpj.is_empty() && !cpf.is_empty() {
        return Err(Erro::valor(
            "Não foi possível resolver [dps] Id = {auto}: CNPJ e CPF do prestador estão preenchidos ao mesmo tempo.",
        ));
    }
    let tipo = if cnpj.is_empty() { "1" } else { "2" };
    let inscricao = if cnpj.is_empty() { cpf } else { cnpj };
    let mut faltam: Vec<&str> = Vec::new();
    if c_loc_emi.is_empty() {
        faltam.push("[dps] cLocEmi");
    }
    if serie.is_empty() {
        faltam.push("[dps] serie");
    }
    if ndps.is_empty() {
        faltam.push("[dps] nDPS");
    }
    if inscricao.is_empty() {
        faltam.push("[prest] CNPJ ou [prest] CPF");
    }
    if !faltam.is_empty() {
        return Err(Erro::valor(format!(
            "Não foi possível resolver [dps] Id = {{auto}}: campos ausentes/vazios: {}",
            faltam.join(", ")
        )));
    }
    // A série ocupa 5 posições no Id (TSIdDPS), mesmo quando a tag <serie> tem menos dígitos
    // ("900" -> "00900"): sem os zeros o Id saía curto e o XSD recusava a DPS.
    Ok(format!(
        "DPS{c_loc_emi}{tipo}{}{}{}",
        zeros(&inscricao, 14),
        zeros(&serie, 5),
        zeros(&ndps, 15)
    ))
}

/// Percentual oficial (pAliqPis/pAliqCofins/pTotTrib*): o do serviço em [gui.tributos], se
/// houver; senão o do prestador.
fn auto_tributo_oficial(ini: &Ini, ctx: &Contexto, opcao: &str) -> Res<String> {
    let proprio = valor(ini, GUI_TRIBUTOS, opcao);
    if !proprio.is_empty() {
        return Ok(proprio);
    }
    tributo_do_prestador(ctx, &[TRIB_OFICIAIS], opcao)
}

/// Percentual auxiliar (IRRF/CSLL, sem campo XML próprio): o do serviço, se houver; senão o do
/// prestador.
fn percentual_auxiliar(ini: &Ini, ctx: &Contexto, chave_gui: &str, opcao: &str) -> Res<Decimal> {
    let proprio = valor(ini, GUI_TRIBUTOS, chave_gui);
    if !proprio.is_empty() {
        return decimal(&proprio, &format!("[{GUI_TRIBUTOS}] {chave_gui}"));
    }
    decimal(
        &tributo_do_prestador(ctx, &TRIB_AUXILIARES, opcao)?,
        &format!("percentual de {} do prestador", rotulo_do_tributo(opcao)),
    )
}

/// Base do PIS/COFINS de apuração própria: o valor do serviço menos o desconto INCONDICIONADO,
/// que por lei não integra a base (Lei 9.718/1998, art. 3º, § 2º, I; Leis 10.637/2002 e
/// 10.833/2003, art. 1º, § 3º, V, "a") — o mesmo critério da SEFIN para o ISSQN e o IBS/CBS. O
/// desconto condicionado não reduz base nenhuma (só o valor líquido).
fn base_dos_tributos(ini: &Ini) -> Res<Decimal> {
    let servico = decimal_da_config(ini, VSERV, "vServ")?;
    let desconto = valor(ini, DESCONTOS, "vDescIncond");
    if aparar(&desconto).is_empty() {
        return Ok(servico);
    }
    Ok(servico - decimal(&desconto, &format!("[{DESCONTOS}] vDescIncond"))?)
}

fn auto_base(ini: &Ini) -> Res<String> {
    Ok(dinheiro_texto(base_dos_tributos(ini)?))
}

fn base_piscofins(ini: &mut Ini) -> Res<Decimal> {
    let v = valor(ini, PISCOFINS, "vBCPisCofins");
    if e_auto(&v) {
        let resolvido = auto_base(ini)?;
        ini.por(PISCOFINS, "vBCPisCofins", &resolvido);
        return decimal(&resolvido, &format!("[{PISCOFINS}] vBCPisCofins"));
    }
    if !v.is_empty() {
        return decimal(&v, &format!("[{PISCOFINS}] vBCPisCofins"));
    }
    base_dos_tributos(ini)
}

fn auto_vpis(ini: &mut Ini) -> Res<String> {
    let base = base_piscofins(ini)?;
    Ok(dinheiro_texto(parte_percentual(
        base,
        decimal_da_config(ini, PISCOFINS, "pAliqPis")?,
    )))
}

fn auto_vcofins(ini: &mut Ini) -> Res<String> {
    let base = base_piscofins(ini)?;
    Ok(dinheiro_texto(parte_percentual(
        base,
        decimal_da_config(ini, PISCOFINS, "pAliqCofins")?,
    )))
}

fn valor_piscofins(
    ini: &mut Ini,
    opcao: &str,
    resolver: fn(&mut Ini) -> Res<String>,
) -> Res<Decimal> {
    let v = valor(ini, PISCOFINS, opcao);
    let rotulo = format!("[{PISCOFINS}] {opcao}");
    if e_auto(&v) {
        let resolvido = resolver(ini)?;
        ini.por(PISCOFINS, opcao, &resolvido);
        return decimal(&resolvido, &rotulo);
    }
    if !v.is_empty() {
        return decimal(&v, &rotulo);
    }
    decimal(&resolver(ini)?, &rotulo)
}

/// As retenções saem, por padrão, da mesma base: a lei manda reter sobre o montante a pagar (Lei
/// 10.833/2003, art. 31; RIR/2018, art. 714), e o desconto incondicionado não é pago. Mas quem
/// retém é o tomador, e há quem retenha sobre o valor cheio do serviço ("valor bruto da nota", IN
/// SRF 459/2004, art. 2º): o serviço marcado com `ret_abate_desconto = 0` usa esse valor. Só faz
/// diferença em nota com desconto incondicionado.
fn retencao_sobre_o_valor_cheio(ini: &Ini) -> Res<Option<Decimal>> {
    if aparar(&valor(ini, GUI_SERVICO, "ret_abate_desconto")) != "0"
        || aparar(&valor(ini, DESCONTOS, "vDescIncond")).is_empty()
    {
        return Ok(None);
    }
    Ok(Some(decimal_da_config(ini, VSERV, "vServ")?))
}

fn auto_vret_irrf(ini: &mut Ini, ctx: &Contexto) -> Res<String> {
    let percentual = percentual_auxiliar(ini, ctx, "pIRRF", "irrf")?;
    let base = match retencao_sobre_o_valor_cheio(ini)? {
        Some(cheio) => cheio,
        None => base_piscofins(ini)?,
    };
    Ok(dinheiro_texto(parte_percentual(base, percentual)))
}

fn auto_vret_csll(ini: &mut Ini, ctx: &Contexto) -> Res<String> {
    if let Some(cheio) = retencao_sobre_o_valor_cheio(ini)? {
        let pis = parte_percentual(cheio, decimal_da_config(ini, PISCOFINS, "pAliqPis")?);
        let cofins = parte_percentual(cheio, decimal_da_config(ini, PISCOFINS, "pAliqCofins")?);
        let percentual = percentual_auxiliar(ini, ctx, "pCSLL", "csll")?;
        return Ok(dinheiro_texto(
            pis + cofins + parte_percentual(cheio, percentual),
        ));
    }
    let base = base_piscofins(ini)?;
    let v_pis = valor_piscofins(ini, "vPis", auto_vpis)?;
    let v_cofins = valor_piscofins(ini, "vCofins", auto_vcofins)?;
    let percentual = percentual_auxiliar(ini, ctx, "pCSLL", "csll")?;
    Ok(dinheiro_texto(
        v_pis + v_cofins + parte_percentual(base, percentual),
    ))
}

/// Ordem em que os {auto} são resolvidos (uns dependem dos outros).
fn prioridade(secao: &str, opcao: &str) -> u32 {
    match (secao, opcao) {
        ("dps", "versao") => 10,
        ("dps", "nDPS") => 20,
        ("dps", "dhEmi") => 30,
        ("dps", "dCompet") => 40,
        (PISCOFINS, "pAliqPis" | "pAliqCofins") => 45,
        (PISCOFINS, "vBCPisCofins") => 50,
        (PISCOFINS, "vPis" | "vCofins") => 60,
        (TRIB_FED, "vRetIRRF") => 70,
        (TRIB_FED, "vRetCSLL") => 80,
        (TOT_TRIB, "pTotTribFed" | "pTotTribEst" | "pTotTribMun") => 85,
        ("dps", "Id") => 90,
        _ => 50,
    }
}

fn resolver(ini: &mut Ini, ctx: &Contexto, secao: &str, opcao: &str, ficha: &str) -> Res<String> {
    let sem_modulo = || {
        Erro::valor(format!(
            "Variável sem módulo: [{secao}] {opcao} = {{{ficha}}}"
        ))
    };
    if ficha.to_lowercase() != "auto" {
        return Err(sem_modulo());
    }
    match (secao, opcao) {
        ("dps", "versao") => auto_versao(),
        ("dps", "nDPS") => auto_ndps(ctx),
        ("dps", "dhEmi") => Ok(agora_iso()),
        ("dps", "dCompet") => Ok(hoje_iso()),
        ("dps", "Id") => auto_id(ini),
        (PISCOFINS, "pAliqPis" | "pAliqCofins") => auto_tributo_oficial(ini, ctx, opcao),
        (PISCOFINS, "vBCPisCofins") => auto_base(ini),
        (PISCOFINS, "vPis") => auto_vpis(ini),
        (PISCOFINS, "vCofins") => auto_vcofins(ini),
        (TRIB_FED, "vRetIRRF") => auto_vret_irrf(ini, ctx),
        (TRIB_FED, "vRetCSLL") => auto_vret_csll(ini, ctx),
        (TOT_TRIB, "pTotTribFed" | "pTotTribEst" | "pTotTribMun") => {
            auto_tributo_oficial(ini, ctx, opcao)
        }
        _ => Err(sem_modulo()),
    }
}

fn resolver_variaveis(ini: &mut Ini, ctx: &Contexto) -> Res<()> {
    let mut variaveis: Vec<(u32, usize, String, String, String)> = Vec::new();
    for secao in ini.secoes() {
        if SO_DO_PROGRAMA.contains(&secao) {
            continue;
        }
        for (opcao, v) in ini.itens(secao) {
            if !v.contains('{') && !v.contains('}') {
                continue;
            }
            // Variável é só o marcador {auto}, que o próprio programa grava. Qualquer outro texto
            // com chaves ("Honorários {ref. contrato 12}") é texto do usuário e segue como está.
            let Some(dentro) = marcador(aparar(v)) else {
                continue;
            };
            if aparar(dentro).to_lowercase() != "auto" {
                continue;
            }
            variaveis.push((
                prioridade(secao, opcao),
                variaveis.len(),
                secao.to_string(),
                opcao.to_string(),
                aparar(dentro).to_string(),
            ));
        }
    }
    variaveis.sort();
    for (_, _, secao, opcao, ficha) in variaveis {
        if marcador(&valor(ini, &secao, &opcao)).is_none() {
            continue;
        }
        let resolvido = resolver(ini, ctx, &secao, &opcao, &ficha)?;
        ini.por(&secao, &opcao, &resolvido);
    }
    Ok(())
}

/// Regras de negócio da SEFIN Nacional aplicadas à config FINAL da emissão:
/// - E0121: quando o emitente da DPS é o PRÓPRIO prestador (tpEmit=1), o grupo <prest> NÃO pode
///   conter xNome — a SEFIN resolve pelo cadastro do CNPJ. Sai só do XML.
/// - xNomeExib é rótulo interno da tela e NUNCA vai no XML.
fn regras_da_sefin(ini: &mut Ini) {
    let tp_emit = valor(ini, "dps", "tpEmit");
    if ini.tem_secao("prest") {
        if tp_emit == "1" {
            ini.remover_opcao("prest", "xNome");
        }
        ini.remover_opcao("prest", "xNomeExib");
    }
}

/// Monta a config final. `config_prestador`: chave do cadastro do prestador; `config_tomador`:
/// identidade do cliente + serviço escolhido, já compostos (`cadastro::compose_active_config`).
pub fn parse_configs(
    config_prestador: &str,
    config_tomador: &Ini,
    ctx: &Contexto,
    forcados: &Forcados,
) -> Res<Ini> {
    if !banco::exists_ini(config_prestador)? {
        return Err(Erro::nao_encontrado(format!(
            "Não foi possível ler o config: {}",
            caminhos::normalizar(&caminhos::absoluto(config_prestador)).display()
        )));
    }
    let prestador = banco::load_ini(config_prestador, true)?;
    // a config do tomador sempre passou por arquivo: vale o que sobra dessa ida e volta
    let tomador = config_tomador.ida_e_volta(true)?;
    let mut junto = Ini::novo();
    for origem in [&prestador, &tomador] {
        for secao in origem.secoes() {
            junto.garantir_secao(secao);
            for (opcao, v) in origem.itens(secao) {
                junto.por(secao, opcao, aparar(v));
            }
        }
    }
    for secao in SO_DO_PROGRAMA {
        junto.remover_secao(secao);
    }
    for ((secao, opcao), v) in forcados {
        junto.por(secao, opcao, v);
    }
    regras_da_sefin(&mut junto);
    resolver_variaveis(&mut junto, ctx)?;
    // sem campos vazios
    let mut limpo = Ini::novo();
    for secao in junto.secoes() {
        for (opcao, v) in junto.itens(secao) {
            let v = aparar(v);
            if !v.is_empty() {
                limpo.por(secao, opcao, v);
            }
        }
    }
    Ok(limpo)
}
