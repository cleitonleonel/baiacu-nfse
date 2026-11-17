//! Lotes persistidos no banco cifrado. Cada tentativa é registrada antes da rede;
//! resultado incerto nunca volta automaticamente ao estado pronto para emissão.
use crate::erro::{Erro, Res};
use crate::{banco, cadastro, emissao};
use chrono::{Local, NaiveDate};
use rusqlite::{OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Mutex;

static ENVIOS: Mutex<()> = Mutex::new(());
const LIMITE_NOME: usize = 30;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Linha {
    pub id: String,
    pub tomador: String,
    pub servico: String,
    pub competencia: String,
    pub form: cadastro::ServicoForm,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub editada: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Lote {
    pub id: String,
    pub nome: String,
    pub revisao: i64,
    pub linhas: Vec<Linha>,
}
fn identificador(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
pub fn obter(prestador: &str, id: &str) -> Res<Lote> {
    let texto: String = banco::conn()?.query_row(
        "SELECT documento FROM lote WHERE prestador=?1 AND id=?2",
        params![prestador, id],
        |r| r.get(0),
    )?;
    Ok(serde_json::from_str(&texto)?)
}
fn ambiente_valido(prestador: &str, ambiente: &str) -> Res<()> {
    if cadastro::ambiente_rotulo(ambiente).is_none()
        || cadastro::get_ambiente(prestador)? != ambiente
    {
        return Err(Erro::valor(
            "O ambiente do prestador mudou. Reabra o lote e confira antes de emitir.",
        ));
    }
    Ok(())
}

fn validar(prestador: &str, lote: &Lote) -> Res<()> {
    if !identificador(&lote.id)
        || lote.nome.trim().is_empty()
        || lote.nome.chars().count() > 100
        || lote.linhas.len() > 1000
    {
        return Err(Erro::valor(
            "Informe um nome e inclua até 1000 linhas no lote.",
        ));
    }
    cadastro::get_prestador_form(prestador)?;
    let mut ids = std::collections::HashSet::new();
    let mut pares = std::collections::HashSet::new();
    for (i, linha) in lote.linhas.iter().enumerate() {
        if !identificador(&linha.id)
            || !identificador(&linha.servico)
            || crate::texto::only_doc(&linha.tomador) != linha.tomador
            || !ids.insert(&linha.id)
            || !pares.insert((&linha.tomador, &linha.servico))
        {
            return Err(Erro::valor(format!(
                "Linha {}: identificador inválido ou cliente/serviço duplicados.",
                i + 1
            )));
        }
        if !cadastro::tomador_cadastrado(prestador, &linha.tomador)? {
            return Err(Erro::valor(format!(
                "Linha {}: cliente não cadastrado.",
                i + 1
            )));
        }
        cadastro::get_servico(prestador, &linha.tomador, &linha.servico)?;
        let data = NaiveDate::parse_from_str(&linha.competencia, "%Y-%m-%d")
            .map_err(|_| Erro::valor(format!("Linha {}: competência inválida.", i + 1)))?;
        if data.format("%Y-%m-%d").to_string() != linha.competencia
            || data > Local::now().date_naive()
        {
            return Err(Erro::valor("A competência não pode ser futura."));
        }
        let erros = linha.form.validate(false);
        if !erros.is_empty() {
            return Err(Erro::valor(format!(
                "Linha {}: {}",
                i + 1,
                erros.join("; ")
            )));
        }
    }
    Ok(())
}
fn salvar(prestador: &str, mut lote: Lote) -> Res<Value> {
    lote.nome = lote.nome.trim().to_owned();
    validar(prestador, &lote)?;
    let mut con = banco::conn()?;
    let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if eh_execucao(&tx, prestador, &lote.id)? {
        return Err(Erro::valor(
            "O histórico de uma emissão não pode ser editado.",
        ));
    }
    let atual: Option<(i64, String)> = tx
        .query_row(
            "SELECT revisao, documento ->> '$.nome' FROM lote WHERE prestador=?1 AND id=?2",
            params![prestador, lote.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if atual.as_ref().map_or(0, |(revisao, _)| *revisao) != lote.revisao {
        return Err(Erro::valor(
            "Este lote mudou em outra janela. Reabra antes de salvar.",
        ));
    }
    if lote.nome.chars().count() > LIMITE_NOME
        && atual
            .as_ref()
            .is_none_or(|(_, anterior)| anterior.trim() != lote.nome)
    {
        return Err(Erro::valor("O nome do lote pode ter até 30 caracteres."));
    }
    let nome = lote.nome.to_lowercase();
    // Modelos antigos com nomes repetidos continuam editáveis até serem renomeados.
    if atual
        .as_ref()
        .is_none_or(|(_, anterior)| anterior.trim().to_lowercase() != nome)
    {
        let mut st = tx.prepare(
            "SELECT l.documento ->> '$.nome' FROM lote l
             WHERE l.prestador=?1 AND l.id<>?2 AND NOT EXISTS (
                SELECT 1 FROM lote_execucao e WHERE e.prestador=l.prestador AND e.id=l.id
             )",
        )?;
        let nomes = st.query_map(params![prestador, lote.id], |r| r.get::<_, String>(0))?;
        for existente in nomes {
            if existente?.trim().to_lowercase() == nome {
                return Err(Erro::valor("Já existe um lote com este nome."));
            }
        }
    }
    // Alterações em linha que já tem tentativa não apagam seu histórico.
    lote.revisao += 1;
    tx.execute("INSERT INTO lote(prestador,id,documento,revisao) VALUES(?1,?2,?3,?4) ON CONFLICT(prestador,id) DO UPDATE SET documento=excluded.documento,revisao=excluded.revisao",params![prestador,lote.id,serde_json::to_string(&lote)?,lote.revisao])?;
    tx.commit()?;
    Ok(serde_json::to_value(lote)?)
}

fn eh_execucao(con: &rusqlite::Connection, prestador: &str, id: &str) -> Res<bool> {
    Ok(con.query_row(
        "SELECT EXISTS(SELECT 1 FROM lote_execucao WHERE prestador=?1 AND id=?2)",
        params![prestador, id],
        |r| r.get(0),
    )?)
}

fn excluir(prestador: &str, id: &str, revisao: i64) -> Res<Value> {
    let mut con = banco::conn()?;
    let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if eh_execucao(&tx, prestador, id)? {
        return Err(Erro::valor(
            "O histórico de uma emissão não pode ser excluído.",
        ));
    }
    migrar_historico_na_transacao(&tx, prestador)?;
    let removidos = tx.execute(
        "DELETE FROM lote WHERE prestador=?1 AND id=?2 AND revisao=?3",
        params![prestador, id, revisao],
    )?;
    if removidos == 0 {
        return Err(Erro::valor(
            "Este lote mudou ou já foi excluído. Atualize a lista.",
        ));
    }
    tx.commit()?;
    Ok(Value::Null)
}
fn extras(linha: &Linha) -> crate::config_dps::Forcados {
    vec![(("dps".into(), "dCompet".into()), linha.competencia.clone())]
}
fn conferir_linha(prestador: &str, linha: &Linha, ambiente: &str) -> Res<()> {
    emissao::validar_leiaute_transmissao(&linha.form.cTribNac, ambiente)?;
    emissao::preview_emissao_com(
        prestador,
        &linha.tomador,
        ambiente,
        &linha.servico,
        Some(&linha.form),
        &extras(linha),
        true,
    )?;
    Ok(())
}

fn conferir(prestador: &str, lote: &Lote, ambiente: &str) -> Res<Value> {
    validar(prestador, lote)?;
    ambiente_valido(prestador, ambiente)?;
    let mut erros = Vec::new();
    for linha in &lote.linhas {
        if let Err(e) = conferir_linha(prestador, linha, ambiente) {
            erros.push(json!({"linha":linha.id,"erro":e.msg}));
        }
    }
    Ok(
        json!({"valido":erros.is_empty(),"erros":erros,"revisao":lote.revisao,"quantidade":lote.linhas.len()}),
    )
}
fn conferir_ambiente_execucao(prestador: &str, id: &str, ambiente: &str) -> Res<()> {
    let salvo: Option<String> = banco::conn()?
        .query_row(
            "SELECT ambiente FROM lote_execucao WHERE prestador=?1 AND id=?2",
            params![prestador, id],
            |r| r.get(0),
        )
        .optional()?;
    match salvo.as_deref() {
        Some(a) if a == ambiente => Ok(()),
        Some(_) => Err(Erro::valor(
            "O ambiente desta emissão é diferente do ambiente selecionado.",
        )),
        None => Err(Erro::valor(
            "Inicie uma emissão do lote antes de transmitir suas linhas.",
        )),
    }
}

fn conferir_aberta(prestador: &str, id: &str) -> Res<()> {
    let encerrada: bool = banco::conn()?.query_row(
        "SELECT EXISTS(SELECT 1 FROM lote_execucao_fim WHERE prestador=?1 AND id=?2)",
        params![prestador, id],
        |r| r.get(0),
    )?;
    if encerrada {
        return Err(Erro::valor("Esta execução já foi concluída."));
    }
    Ok(())
}

struct Envio<'a> {
    prestador: &'a str,
    id: &'a str,
    ambiente: &'a str,
    linha: &'a Linha,
}

impl Envio<'_> {
    fn atual(&self) -> Res<(String, Value)> {
        let atual = banco::conn()?
            .query_row(
                "SELECT estado,resultado FROM lote_envio
             WHERE prestador=?1 AND lote=?2 AND linha=?3 AND ambiente=?4 AND competencia=?5",
                params![
                    self.prestador,
                    self.id,
                    self.linha.id,
                    self.ambiente,
                    self.linha.competencia
                ],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        Ok(atual.map_or_else(
            || (String::new(), Value::Null),
            |(estado, documento)| {
                (
                    estado,
                    serde_json::from_str(&documento).unwrap_or(Value::Null),
                )
            },
        ))
    }

    fn guardar(&self, con: &rusqlite::Connection, estado: &str, resultado: &Value) -> Res<()> {
        con.execute(
            "INSERT INTO lote_envio VALUES(?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(prestador,lote,linha,ambiente,competencia)
             DO UPDATE SET estado=excluded.estado,resultado=excluded.resultado",
            params![
                self.prestador,
                self.id,
                self.linha.id,
                self.ambiente,
                self.linha.competencia,
                estado,
                resultado.to_string()
            ],
        )?;
        Ok(())
    }

    fn arquivar_tentativa(&self, con: &rusqlite::Connection) -> Res<()> {
        con.execute(
            "INSERT INTO lote_tentativa(prestador,lote,linha,ambiente,competencia,estado,resultado)
             SELECT prestador,lote,linha,ambiente,competencia,estado,resultado FROM lote_envio
             WHERE prestador=?1 AND lote=?2 AND linha=?3 AND ambiente=?4 AND competencia=?5",
            params![
                self.prestador,
                self.id,
                self.linha.id,
                self.ambiente,
                self.linha.competencia
            ],
        )?;
        Ok(())
    }

    fn pendente(&self, resultado: &Value) -> Res<emissao::PendenteInfo> {
        let id = resultado["fila"]["id"].as_str().ok_or_else(|| {
            Erro::valor(
                "Esta tentativa não tem a DPS assinada. Confira o envio no portal da NFS-e.",
            )
        })?;
        emissao::list_pendentes_na(self.prestador, "lote")?
            .into_iter()
            .find(|p| p.id == id)
            .ok_or_else(|| {
                Erro::valor(
                    "Não foi possível localizar a DPS deste envio. Confira a nota em Consultar.",
                )
            })
    }

    fn arquivar_dps(&self, con: &rusqlite::Connection, id: &str) -> Res<()> {
        con.execute(
            "UPDATE pendente SET situacao='lote_arquivada_' || lower(hex(randomblob(8)))
             WHERE prestador=?1 AND id=?2 AND situacao='lote'",
            params![self.prestador, id],
        )?;
        Ok(())
    }

    fn preparar(&self, anterior: &Value) -> Res<emissao::PendenteInfo> {
        let linha = self.linha;
        if !cadastro::tomador_cadastrado(self.prestador, &linha.tomador)? {
            return Err(Erro::valor(
                "O cliente desta linha não está mais cadastrado.",
            ));
        }
        let cert = cadastro::cert_da_emissao(self.prestador, &linha.form)?;
        let mut forcados = extras(linha);
        let identidade = anterior["id_dps"].as_str().filter(|id| !id.is_empty());
        if identidade.is_some() {
            for (campo, chave) in [("nDPS", "n_dps"), ("serie", "serie")] {
                let valor = anterior[chave]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| {
                        Erro::valor("O registro não contém a numeração original da DPS.")
                    })?;
                crate::config_dps::forcar(&mut forcados, "dps", campo, valor);
            }
        }
        let resultado = emissao::emitir_com_preparo(
            self.prestador,
            &linha.tomador,
            &linha.servico,
            &cert,
            self.ambiente,
            &forcados,
            Some(&linha.form),
            Some(&|dps| {
                if identidade.is_some_and(|id| id != dps.id_dps) {
                    return Err(Erro::valor(
                        "A identidade da DPS mudou. Confira a numeração e o cadastro do prestador.",
                    ));
                }
                let (p, xml) = emissao::preparar_pendente(
                    self.prestador,
                    &linha.tomador,
                    &linha.servico,
                    &linha.tomador,
                    &linha.form.vServ,
                    &dps,
                    &Value::Null,
                )?;
                let meta = serde_json::to_value(&p)?;
                let contador = cadastro::ensure_last_dps(self.prestador, self.ambiente)?;
                let n: i64 = p
                    .n_dps
                    .parse()
                    .map_err(|_| Erro::valor("Número da DPS inválido."))?;
                let mut con = banco::conn()?;
                let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
                // O XML e o número são reservados juntos antes de qualquer POST.
                tx.execute(
                    "INSERT INTO pendente VALUES(?1,?2,'lote',?3,?4,?5)",
                    params![
                        self.prestador,
                        p.id,
                        meta.to_string(),
                        xml,
                        dps.shadow_config
                    ],
                )?;
                tx.execute(
                    "INSERT INTO contador(arquivo,valor) VALUES (?1,?2)
                     ON CONFLICT(arquivo) DO UPDATE SET valor=excluded.valor
                     WHERE CAST(contador.valor AS INTEGER) < CAST(excluded.valor AS INTEGER)",
                    params![crate::caminhos::chave_logica(&contador), n.to_string()],
                )?;
                self.guardar(&tx, "fila", &json!({"fila":meta}))?;
                tx.commit()?;
                Ok(meta)
            }),
        )?;
        Ok(serde_json::from_value(resultado)?)
    }

    fn transmitir(&self, estado: &str, documento: &Value) -> Res<Value> {
        let p = match estado {
            "emitida" | "removida" => {
                return Err(Erro::valor("Esta linha já foi tratada nesta execução."));
            }
            "fila" => self.pendente(documento)?,
            "conferir" | "enviando" => {
                return Err(Erro::valor(
                    "O envio anterior ficou sem confirmação e a DPS assinada não está disponível. Confira a nota no portal da NFS-e.",
                ));
            }
            _ => {
                let mut con = banco::conn()?;
                let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
                if estado == "falhou" {
                    self.arquivar_tentativa(&tx)?;
                }
                self.guardar(&tx, "preparando", documento)?;
                tx.commit()?;
                match self.preparar(&documento["fila"]) {
                    Ok(p) => p,
                    Err(e) => {
                        self.guardar(
                            &con,
                            "falhou",
                            &json!({"erro":e.msg,"tipo":e.tipo,"fila":documento["fila"]}),
                        )?;
                        return Err(e);
                    }
                }
            }
        };
        let resultado = emissao::entregar_pendente_do_lote(self.prestador, &p, false);
        if let Err(e) = &resultado {
            let rejeitada = e.tipo == "EmissionRejected"
                && !emissao::codigos_erro(e.dado("body")).is_empty()
                && p.chave.is_empty();
            let mut con = banco::conn()?;
            let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if rejeitada {
                self.arquivar_dps(&tx, &p.id)?;
                self.guardar(&tx, "falhou", &json!({"erro":e.msg,"tipo":e.tipo,"fila":p}))?;
            } else {
                self.guardar(&tx, "fila", &json!({"erro":e.msg,"fila":p}))?;
            }
            tx.commit()?;
        }
        resultado
    }
}

fn emitir_linha(
    prestador: &str,
    id: &str,
    linha_id: &str,
    revisao: i64,
    ambiente: &str,
) -> Res<Value> {
    crate::permissoes::exigir("lotes.emitir")?;
    crate::permissoes::exigir("emitir.transmitir")?;
    let _trava = ENVIOS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    ambiente_valido(prestador, ambiente)?;
    conferir_ambiente_execucao(prestador, id, ambiente)?;
    conferir_aberta(prestador, id)?;
    let lote = obter(prestador, id)?;
    if lote.revisao != revisao {
        return Err(Erro::valor("O registro mudou. Abra-o novamente."));
    }
    let linha = encontrar_linha(&lote, linha_id)?;
    let envio = Envio {
        prestador,
        id,
        ambiente,
        linha,
    };
    let (estado, resultado) = envio.atual()?;
    envio.transmitir(&estado, &resultado)
}

fn encontrar_linha<'a>(lote: &'a Lote, id: &str) -> Res<&'a Linha> {
    lote.linhas
        .iter()
        .find(|l| l.id == id)
        .ok_or_else(|| Erro::valor("Linha não encontrada nesta execução."))
}

fn historico(prestador: &str, id: &str) -> Res<Vec<Value>> {
    let con = banco::conn()?;
    let mut historico = historico_em(&con, prestador, id)?;
    let mut leitor = None;
    for linha in &mut historico {
        if linha["estado"] != "emitida" {
            continue;
        }
        let resultado = &linha["resultado"];
        if let Some(numero) = numero_nfse_resultado(resultado) {
            linha["nNFSe"] = json!(numero);
        } else if let Some(chave) = chave_nfse_resultado(resultado) {
            // Registros antigos podem ter guardado só a chave. O Cofre é uma leitura complementar.
            if let Ok(leitor) = leitor.get_or_insert_with(crate::cofre::LeitorXml::novo)
                && let Ok(Some(nota)) = leitor.nota(prestador, chave)
                && nota.papel == crate::cofre::PAPEL_EMITIDA
                && linha["ambiente"] == nota.amb
                && !nota.nNFSe.is_empty()
            {
                linha["nNFSe"] = json!(nota.nNFSe);
            }
        }
    }
    Ok(historico)
}

pub(crate) fn chave_nfse_resultado(resultado: &Value) -> Option<&str> {
    [
        &resultado["chave"],
        &resultado["official_nfse"]["chaveAcesso"],
        &resultado["chaveAcesso"],
    ]
    .into_iter()
    .filter_map(Value::as_str)
    .find(|s| s.len() == 50 && s.bytes().all(|b| b.is_ascii_digit()))
}

pub(crate) fn numero_nfse_resultado(resultado: &Value) -> Option<&str> {
    [&resultado["official_nfse"]["nNFSe"], &resultado["nNFSe"]]
        .into_iter()
        .filter_map(Value::as_str)
        .map(str::trim)
        .find(|n| !n.is_empty())
}

fn historico_em(con: &rusqlite::Connection, prestador: &str, id: &str) -> Res<Vec<Value>> {
    let mut st = con.prepare(
        "SELECT linha,competencia,ambiente,estado,resultado FROM lote_envio
         WHERE prestador=?1 AND lote=?2",
    )?;
    let rows = st
        .query_map(params![prestador, id], |r| {
            let resultado: String = r.get(4)?;
            Ok(json!({
                "linha": r.get::<_, String>(0)?,
                "competencia": r.get::<_, String>(1)?,
                "ambiente": r.get::<_, String>(2)?,
                "estado": r.get::<_, String>(3)?,
                "resultado": serde_json::from_str::<Value>(&resultado).unwrap_or(Value::Null),
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub(crate) struct RegistroExportavel {
    pub lote: Lote,
    pub criado: String,
    pub ambiente: String,
    pub concluida: bool,
    pub historico: Vec<Value>,
}

pub(crate) fn registros_exportaveis(
    prestador: &str,
    ids: &[String],
) -> Res<Vec<RegistroExportavel>> {
    let mut con = banco::conn()?;
    // A lista e a situação das linhas usam a mesma visão do banco durante a leitura.
    let tx = con.transaction()?;
    let mut st = tx.prepare(
        "SELECT l.documento,e.criado,e.ambiente,f.id IS NOT NULL
         FROM lote_execucao e JOIN lote l ON l.prestador=e.prestador AND l.id=e.id
         LEFT JOIN lote_execucao_fim f ON f.prestador=e.prestador AND f.id=e.id
         WHERE e.prestador=?1 AND e.id=?2",
    )?;
    let mut registros = Vec::with_capacity(ids.len());
    let mut vistos = std::collections::HashSet::new();
    for id in ids {
        if !vistos.insert(id.as_str()) {
            continue;
        }
        let (doc, criado, ambiente, finalizada): (String, String, String, bool) = st
            .query_row(params![prestador, id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .optional()?
            .ok_or_else(|| {
                Erro::valor(
                    "Um dos registros selecionados não está disponível para este prestador.",
                )
            })?;
        let lote: Lote = serde_json::from_str(&doc)?;
        let historico = historico_em(&tx, prestador, id)?;
        let encerradas: std::collections::HashSet<_> = historico
            .iter()
            .filter(|h| {
                h["ambiente"] == ambiente
                    && matches!(h["estado"].as_str(), Some("emitida" | "removida"))
            })
            .filter_map(|h| Some((h["linha"].as_str()?, h["competencia"].as_str()?)))
            .collect();
        let concluida = finalizada
            || lote
                .linhas
                .iter()
                .all(|l| encerradas.contains(&(l.id.as_str(), l.competencia.as_str())));
        registros.push(RegistroExportavel {
            lote,
            criado,
            ambiente,
            concluida,
            historico,
        });
    }
    Ok(registros)
}

const META_AVISO_LOTE: &str = "lotes.aviso_reenvio";

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct AvisoReenvio {
    ativo: bool,
    periodo: String,
    quantidade: u32,
    unidade: String,
}

impl AvisoReenvio {
    fn ler(con: &rusqlite::Connection) -> Res<Self> {
        let bruto = banco::get_meta_em(con, META_AVISO_LOTE)?;
        if bruto.is_empty() {
            return Ok(Self {
                ativo: true,
                periodo: "dia".into(),
                quantidade: 1,
                unidade: "dia".into(),
            });
        }
        Ok(serde_json::from_str(&bruto)?)
    }

    fn inicio(&self, agora: chrono::DateTime<Local>) -> Option<chrono::DateTime<Local>> {
        if !self.ativo {
            return None;
        }
        let (n, unidade) = if self.periodo == "custom" {
            (self.quantidade, self.unidade.as_str())
        } else {
            (1, self.periodo.as_str())
        };
        match unidade {
            "hora" => agora.checked_sub_signed(chrono::TimeDelta::hours(n.into())),
            "dia" => agora.checked_sub_signed(chrono::TimeDelta::days(n.into())),
            "semana" => agora.checked_sub_signed(chrono::TimeDelta::weeks(n.into())),
            "mes" => agora.checked_sub_months(chrono::Months::new(n)),
            _ => None,
        }
    }
}

fn iniciado_no_intervalo(
    con: &rusqlite::Connection,
    prestador: &str,
    origem: &str,
    agora: chrono::DateTime<Local>,
) -> Res<bool> {
    let Some(inicio) = AvisoReenvio::ler(con)?.inicio(agora) else {
        return Ok(false);
    };
    let mut st = con.prepare(
        "SELECT criado FROM lote_execucao WHERE prestador=?1 AND origem=?2 AND criado<>''",
    )?;
    let datas = st.query_map(params![prestador, origem], |r| r.get::<_, String>(0))?;
    for data in datas {
        let data = data?;
        let local = chrono::DateTime::parse_from_rfc3339(&data)
            .map(|d| d.with_timezone(&Local))
            .ok()
            .or_else(|| {
                let data = chrono::NaiveDateTime::parse_from_str(
                    &data.replace('T', " "),
                    "%Y-%m-%d %H:%M:%S%.f",
                )
                .ok()?;
                data.and_local_timezone(Local).earliest()
            });
        if local.is_some_and(|d| d >= inicio && d <= agora) {
            return Ok(true);
        }
    }
    Ok(false)
}

fn iniciar_execucao(
    prestador: &str,
    id: &str,
    ambiente: &str,
    revisao: i64,
    confirmacao: &str,
) -> Res<Value> {
    crate::permissoes::exigir("lotes.emitir")?;
    crate::permissoes::exigir("emitir.transmitir")?;
    if banco::conn()?.query_row(
        "SELECT EXISTS(SELECT 1 FROM lote_execucao WHERE prestador=?1 AND id=?2)",
        params![prestador, id],
        |r| r.get::<_, bool>(0),
    )? {
        return Err(Erro::valor(
            "Selecione o lote salvo para iniciar uma nova emissão.",
        ));
    }
    let mut lote = obter(prestador, id)?;
    if lote.revisao != revisao {
        return Err(Erro::valor("O lote mudou. Valide novamente."));
    }
    ambiente_valido(prestador, ambiente)?;
    if lote.linhas.is_empty() {
        return Err(Erro::valor("Inclua ao menos uma linha para emitir o lote."));
    }
    let origem = lote.id.clone();
    lote.id = format!(
        "exec-{}-{}",
        Local::now().timestamp_micros(),
        std::process::id()
    );
    let mut con = banco::conn()?;
    let tx = con.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let atual: i64 = tx.query_row(
        "SELECT revisao FROM lote WHERE prestador=?1 AND id=?2",
        params![prestador, origem],
        |r| r.get(0),
    )?;
    if atual != revisao {
        return Err(Erro::valor("O lote mudou. Valide novamente."));
    }
    let agora = Local::now();
    if confirmacao != "transmitir" && iniciado_no_intervalo(&tx, prestador, &origem, agora)? {
        return Err(Erro::novo(
            "LoteRepetidoNoIntervalo",
            "Este lote já teve uma transmissão iniciada no intervalo configurado.",
        ));
    }
    tx.execute(
        "INSERT INTO lote VALUES(?1,?2,?3,?4)",
        params![
            prestador,
            lote.id,
            serde_json::to_string(&lote)?,
            lote.revisao
        ],
    )?;
    tx.execute(
        "INSERT INTO lote_execucao VALUES(?1,?2,?3,?4,?5)",
        params![prestador, lote.id, origem, agora.to_rfc3339(), ambiente],
    )?;
    tx.commit()?;
    Ok(serde_json::to_value(lote)?)
}

// A versão inicial registrava tentativas diretamente no modelo reutilizável.
// Preserva esses registros em uma execução separada antes de listar o histórico.
fn migrar_historico_anterior(prestador: &str) -> Res<()> {
    let mut con = banco::conn()?;
    let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
    migrar_historico_na_transacao(&tx, prestador)?;
    tx.commit()?;
    Ok(())
}

fn migrar_historico_na_transacao(tx: &rusqlite::Transaction<'_>, prestador: &str) -> Res<()> {
    let anteriores = {
        let mut st=tx.prepare("SELECT DISTINCT e.lote,e.ambiente,l.documento FROM lote_envio e JOIN lote l ON l.prestador=e.prestador AND l.id=e.lote WHERE e.prestador=?1 AND NOT EXISTS(SELECT 1 FROM lote_execucao x WHERE x.prestador=e.prestador AND x.id=e.lote)")?;
        st.query_map([prestador], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?
    };
    for (origem, ambiente, doc) in anteriores {
        let modelo: Lote = serde_json::from_str(&doc)?;
        let registros = {
            let mut st=tx.prepare("SELECT linha,competencia FROM lote_envio WHERE prestador=?1 AND lote=?2 AND ambiente=?3 ORDER BY linha,competencia")?;
            st.query_map(params![prestador, origem, ambiente], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
        };
        let novo_id = format!("anterior-{}-{}", Local::now().timestamp_micros(), ambiente);
        let mut snapshot = Lote {
            id: novo_id.clone(),
            nome: format!("{} (histórico anterior)", modelo.nome),
            revisao: modelo.revisao,
            linhas: Vec::new(),
        };
        for (i, (linha, competencia)) in registros.iter().enumerate() {
            // Sem os dados da linha antiga, conserva o registro no modelo de origem.
            let Some(base) = modelo.linhas.iter().find(|l| l.id == *linha) else {
                continue;
            };
            let mut copia = base.clone();
            copia.id = format!("anterior-{i}");
            copia.competencia = competencia.clone();
            tx.execute("UPDATE lote_envio SET lote=?6,linha=?7 WHERE prestador=?1 AND lote=?2 AND linha=?3 AND ambiente=?4 AND competencia=?5",params![prestador,origem,linha,ambiente,competencia,novo_id,copia.id])?;
            tx.execute("UPDATE lote_envio_servico SET lote=?6,linha=?7 WHERE prestador=?1 AND lote=?2 AND linha=?3 AND ambiente=?4 AND competencia=?5",params![prestador,origem,linha,ambiente,competencia,novo_id,copia.id])?;
            snapshot.linhas.push(copia);
        }
        if snapshot.linhas.is_empty() {
            continue;
        }
        tx.execute(
            "INSERT INTO lote VALUES(?1,?2,?3,?4)",
            params![
                prestador,
                novo_id,
                serde_json::to_string(&snapshot)?,
                snapshot.revisao
            ],
        )?;
        tx.execute(
            "INSERT INTO lote_execucao VALUES(?1,?2,?3,'',?4)",
            params![prestador, novo_id, origem, ambiente],
        )?;
    }
    Ok(())
}

fn execucoes(prestador: &str) -> Res<Value> {
    migrar_historico_anterior(prestador)?;
    let con = banco::conn()?;
    let mut st = con.prepare(
        "SELECT e.id,e.criado,e.ambiente,l.documento,f.id IS NOT NULL,
                (SELECT count(*) FROM lote_envio n
                 JOIN json_each(l.documento, '$.linhas') linha
                   ON linha.value ->> 'id'=n.linha AND linha.value ->> 'competencia'=n.competencia
                 WHERE n.prestador=e.prestador AND n.lote=e.id AND n.ambiente=e.ambiente
                   AND n.estado IN ('emitida','removida'))
         FROM lote_execucao e JOIN lote l ON l.prestador=e.prestador AND l.id=e.id
         LEFT JOIN lote_execucao_fim f ON f.prestador=e.prestador AND f.id=e.id
         WHERE e.prestador=?1 ORDER BY e.criado DESC",
    )?;
    let dados = st.query_map([prestador], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, bool>(4)?,
            r.get::<_, i64>(5)?,
        ))
    })?;
    let mut saida = Vec::new();
    for dado in dados {
        let (id, criado, ambiente, doc, finalizada, tratados) = dado?;
        let lote: Lote = serde_json::from_str(&doc)?;
        let restantes = lote
            .linhas
            .len()
            .saturating_sub(usize::try_from(tratados).unwrap_or_default());
        saida.push(json!({
            "id":id,"nome":lote.nome,"criado":criado,"ambiente":ambiente,
            "pendentes":if finalizada {0} else {restantes},
            "concluida": finalizada || restantes == 0,
        }));
    }
    Ok(json!(saida))
}

fn alterar_linha(prestador: &str, a: &Value, editar: bool) -> Res<Value> {
    crate::permissoes::exigir("lotes.emitir.tratar")?;
    if editar {
        crate::permissoes::exigir("lotes.editar")?;
    }
    let _trava = ENVIOS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let id = crate::despacho::texto(a, "id")?;
    let linha_id = crate::despacho::texto(a, "linha")?;
    let ambiente = crate::despacho::texto(a, "ambiente")?;
    conferir_ambiente_execucao(prestador, id, ambiente)?;
    conferir_aberta(prestador, id)?;
    let mut lote = obter(prestador, id)?;
    let linha = encontrar_linha(&lote, linha_id)?;
    let envio = Envio {
        prestador,
        id,
        ambiente,
        linha,
    };
    let (estado, resultado) = envio.atual()?;
    if !matches!(estado.as_str(), "falhou" | "fila" | "conferir" | "enviando") {
        return Err(Erro::valor(
            "Apenas linhas com erro ou em contingência podem ser tratadas.",
        ));
    }
    let novo_form = if editar {
        let form: cadastro::ServicoForm = serde_json::from_value(a["form"].clone())?;
        let erros = form.validate(false);
        if !erros.is_empty() {
            return Err(Erro::valor(erros.join("; ")));
        }
        if matches!(estado.as_str(), "conferir" | "enviando") {
            return Err(Erro::valor(
                "Confira no portal da NFS-e a tentativa sem confirmação antes de corrigir os dados.",
            ));
        }
        Some(form)
    } else {
        None
    };
    let pendente = if estado == "fila" {
        let p = envio.pendente(&resultado)?;
        if !p.chave.is_empty() {
            return Err(Erro::valor(
                "A NFS-e já foi autorizada. Use Tentar retransmitir para baixar o XML.",
            ));
        }
        if editar {
            ambiente_valido(prestador, ambiente)?;
            match emissao::entregar_pendente_do_lote(prestador, &p, true) {
                Ok(_) => {
                    return Err(Erro::valor(
                        "A DPS já tinha gerado uma NFS-e e o registro foi atualizado.",
                    ));
                }
                Err(e) if e.tipo == "DpsNaoLocalizada" => {}
                Err(e) => return Err(e),
            }
        }
        Some(p)
    } else {
        None
    };
    let mut con = banco::conn()?;
    let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if let Some(p) = pendente {
        envio.arquivar_dps(&tx, &p.id)?;
    }
    let foi_editada = novo_form.is_some();
    if foi_editada {
        envio.arquivar_tentativa(&tx)?;
        envio.guardar(&tx, "falhou", &json!({"fila":resultado["fila"]}))?;
    } else {
        envio.guardar(&tx, "removida", &resultado)?;
    }
    if let Some(form) = novo_form {
        let linha = lote
            .linhas
            .iter_mut()
            .find(|l| l.id == linha_id)
            .ok_or_else(|| Erro::valor("Linha não encontrada nesta execução."))?;
        linha.form = form;
        linha.editada = true;
        lote.revisao += 1;
        tx.execute(
            "UPDATE lote SET documento=?3,revisao=?4 WHERE prestador=?1 AND id=?2",
            params![prestador, id, serde_json::to_string(&lote)?, lote.revisao],
        )?;
    }
    tx.commit()?;
    if foi_editada {
        Ok(serde_json::to_value(lote)?)
    } else {
        Ok(Value::Null)
    }
}

fn finalizar(prestador: &str, a: &Value) -> Res<Value> {
    crate::permissoes::exigir("lotes.emitir.tratar")?;
    let _trava = ENVIOS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let id = crate::despacho::texto(a, "id")?;
    let ambiente = crate::despacho::texto(a, "ambiente")?;
    conferir_ambiente_execucao(prestador, id, ambiente)?;
    banco::conn()?.execute(
        "INSERT OR IGNORE INTO lote_execucao_fim VALUES (?1,?2,?3)",
        params![prestador, id, Local::now().to_rfc3339()],
    )?;
    Ok(Value::Null)
}

pub fn executar(metodo: &str, a: &Value) -> Res<Value> {
    match metodo {
        "lotes.config_aviso" => return Ok(json!(AvisoReenvio::ler(&banco::conn()?)?)),
        "lotes.salvar_aviso" => {
            crate::permissoes::exigir("config.emissao")?;
            let aviso: AvisoReenvio = serde_json::from_value(a["config"].clone())?;
            if !matches!(aviso.periodo.as_str(), "dia" | "semana" | "mes" | "custom")
                || !(1..=99).contains(&aviso.quantidade)
                || !matches!(aviso.unidade.as_str(), "hora" | "dia" | "semana" | "mes")
            {
                return Err(Erro::valor(
                    "Informe um intervalo válido de 1 a 99 unidades.",
                ));
            }
            banco::set_meta(META_AVISO_LOTE, &serde_json::to_string(&aviso)?)?;
            return Ok(Value::Null);
        }
        _ => {}
    }
    let p = crate::despacho::texto(a, "prestador")?;
    match metodo {
        "lotes.execucoes" => execucoes(p),
        "lotes.repetido_intervalo" => Ok(json!(iniciado_no_intervalo(
            &banco::conn()?,
            p,
            crate::despacho::texto(a, "id")?,
            Local::now(),
        )?)),
        "lotes.iniciar" => iniciar_execucao(
            p,
            crate::despacho::texto(a, "id")?,
            crate::despacho::texto(a, "ambiente")?,
            a["revisao"]
                .as_i64()
                .ok_or_else(|| Erro::valor("Revisão ausente."))?,
            crate::despacho::texto_ou(a, "confirmacao_repeticao", ""),
        ),
        "lotes.remover_falha" => alterar_linha(p, a, false),
        "lotes.editar_linha" => alterar_linha(p, a, true),
        "lotes.finalizar" => finalizar(p, a),
        "lotes.listar" => {
            let con = banco::conn()?;
            let mut st =
                con.prepare("SELECT documento FROM lote WHERE prestador=?1 AND id NOT IN (SELECT id FROM lote_execucao WHERE prestador=?1) ORDER BY id")?;
            let docs = st
                .query_map([p], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            let lotes = docs
                .iter()
                .map(|s| serde_json::from_str::<Value>(s))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(json!(lotes))
        }
        "lotes.obter" => Ok(serde_json::to_value(obter(
            p,
            crate::despacho::texto(a, "id")?,
        )?)?),
        "lotes.salvar" => salvar(p, serde_json::from_value(a["lote"].clone())?),
        "lotes.excluir" => excluir(
            p,
            crate::despacho::texto(a, "id")?,
            a["revisao"]
                .as_i64()
                .ok_or_else(|| Erro::valor("Revisão ausente."))?,
        ),
        "lotes.validar" => conferir(
            p,
            &obter(p, crate::despacho::texto(a, "id")?)?,
            crate::despacho::texto(a, "ambiente")?,
        ),
        "lotes.emitir_linha" | "lotes.retransmitir" => emitir_linha(
            p,
            crate::despacho::texto(a, "id")?,
            crate::despacho::texto(a, "linha")?,
            a["revisao"]
                .as_i64()
                .ok_or_else(|| Erro::valor("Revisão ausente."))?,
            crate::despacho::texto(a, "ambiente")?,
        ),
        "lotes.historico" => Ok(json!(historico(p, crate::despacho::texto(a, "id")?)?)),
        _ => Err(Erro::valor("Operação de lote desconhecida.")),
    }
}
