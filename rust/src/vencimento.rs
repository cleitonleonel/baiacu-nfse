//! Vencimento contratual recorrente calculado a partir da competência do aluguel.
use chrono::{Datelike, NaiveDate};

use crate::erro::{Erro, Res};
use crate::{ini::Ini, leiaute, texto};

pub fn calcular(referencia: NaiveDate, dia: u32, meses: u32) -> Res<NaiveDate> {
    if !(1..=31).contains(&dia) || meses > 12 {
        return Err(Erro::valor(
            "Vencimento: escolha um dia de 1 a 31 e um mês de referência de 0 a 12 meses após a competência.",
        ));
    }
    let mes = referencia.month0() + meses;
    let ano = referencia.year() + (mes / 12) as i32;
    let mes = mes % 12 + 1;
    let seguinte = if mes == 12 {
        NaiveDate::from_ymd_opt(ano + 1, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(ano, mes + 1, 1)
    };
    let ultimo = seguinte
        .and_then(|d| d.pred_opt())
        .ok_or_else(|| Erro::valor("Não foi possível calcular o mês do vencimento."))?;
    NaiveDate::from_ymd_opt(ano, mes, dia.min(ultimo.day()))
        .ok_or_else(|| Erro::valor("Não foi possível calcular a data de vencimento."))
}

/// Aplica somente à config final. As preferências ficam fora do XML e a data segue em ISO.
pub fn aplicar(cfg: &mut Ini) -> Res<()> {
    let codigo = cfg.val("serv.cServ", "cTribNac", "");
    if (!leiaute::e_imovel(&codigo) && !leiaute::e_condominio(&codigo))
        || cfg.val("gui.vencimento", "automatico", "0") != "1"
    {
        return Ok(());
    }
    let referencia = texto::parse_iso_date(&cfg.val("dps", "dCompet", "")).ok_or_else(|| {
        Erro::valor("Informe uma competência válida para calcular o vencimento automático.")
    })?;
    let inteiro = |nome: &str| {
        cfg.val("gui.vencimento", nome, "")
            .parse::<u32>()
            .map_err(|_| Erro::valor("Configuração do vencimento inválida."))
    };
    let vencimento = calcular(referencia, inteiro("dia")?, inteiro("meses")?)?;
    let secao = if leiaute::e_imovel(&codigo) {
        "IBSCBS.imovel.gLocacao"
    } else {
        "IBSCBS.condominios"
    };
    cfg.por(
        secao,
        "dVencOrig",
        &vencimento.format("%Y-%m-%d").to_string(),
    );
    Ok(())
}
