//! Converte a config final em XML da DPS.
//!
//! O montador não valida valor, obrigatoriedade, combinação de campos ou regra fiscal: só usa
//! o XSD indicado em paths.ini para pôr as tags na ordem oficial.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use crate::erro::{Erro, Res};
use crate::ini::Ini;
use crate::leiaute::{self, Leiaute};
use crate::texto::aparar;
use crate::xml::{self, Elemento, No};
use crate::{caminhos, validacao};

const NS_XS: &str = "http://www.w3.org/2001/XMLSchema";

/// A ordem dos elementos de cada tipo complexo do XSD: tipo -> [(elemento, tipo dele)].
pub struct OrdemXsd {
    tipos: Vec<(String, Vec<(String, String)>)>,
    pub tipo_inf_dps: String,
}

fn nome_local(v: Option<&str>) -> String {
    match v {
        Some(v) if !v.is_empty() => v.split_once(':').map(|(_, r)| r).unwrap_or(v).to_string(),
        _ => String::new(),
    }
}

fn elementos_do_modelo(no: &Elemento, out: &mut Vec<(String, String)>) {
    for filho in no.elementos() {
        match filho.nome.as_str() {
            "sequence" | "choice" | "all" => elementos_do_modelo(filho, out),
            "element" => {
                let nome = nome_local(
                    filho
                        .attr("name")
                        .filter(|n| !n.is_empty())
                        .or(filho.attr("ref")),
                );
                if !nome.is_empty() {
                    out.push((nome, nome_local(filho.attr("type"))));
                }
            }
            _ => {}
        }
    }
}

fn tipos_complexos(no: &Elemento, tipos: &mut Vec<(String, Vec<(String, String)>)>) {
    for filho in no.elementos() {
        if filho.nome == "complexType" && filho.ns == NS_XS {
            if let Some(nome) = filho.attr("name").filter(|n| !n.is_empty()) {
                let mut elementos = Vec::new();
                elementos_do_modelo(filho, &mut elementos);
                match tipos.iter_mut().find(|(n, _)| n == nome) {
                    Some((_, e)) => *e = elementos,
                    None => tipos.push((nome.to_string(), elementos)),
                }
            }
        }
        tipos_complexos(filho, tipos);
    }
}

impl OrdemXsd {
    fn ler(caminho: &Path) -> Res<OrdemXsd> {
        let bytes = std::fs::read(caminho)
            .map_err(|e| Erro::os(format!("Error reading file '{}': {e}", caminho.display())))?;
        let raiz = xml::ler(&bytes)?;
        let mut tipos = Vec::new();
        tipos_complexos(&raiz, &mut tipos);
        let tipo_inf_dps = tipos
            .iter()
            .flat_map(|(_, elementos)| elementos.iter())
            .find(|(nome, tipo)| nome == "infDPS" && !tipo.is_empty())
            .map(|(_, tipo)| tipo.clone())
            .ok_or_else(|| {
                Erro::valor("Não foi possível descobrir no XSD qual tipo monta infDPS.")
            })?;
        Ok(OrdemXsd {
            tipos,
            tipo_inf_dps,
        })
    }

    /// A ordem do XSD que paths.ini aponta em `[schemas] schema_organizacao_xml` (lida uma vez
    /// por arquivo), no leiaute dado.
    pub fn do_leiaute(leiaute: Leiaute) -> Res<Arc<OrdemXsd>> {
        static GUARDADAS: OnceLock<Mutex<HashMap<PathBuf, Arc<OrdemXsd>>>> = OnceLock::new();
        let versao = match leiaute {
            Leiaute::EmVigor => None,
            Leiaute::Novo => Some(leiaute::versao_do_novo()?),
            Leiaute::Futuro => Some(leiaute::versao_do_futuro()?),
        };
        let caminho = caminho_do_xsd_de_ordem(versao.as_deref())?;
        let mapa = GUARDADAS.get_or_init(|| Mutex::new(HashMap::new()));
        if let Some(o) = mapa
            .lock()
            .map_err(|_| Erro::runtime("ordem do XSD indisponível"))?
            .get(&caminho)
        {
            return Ok(o.clone());
        }
        let ordem = Arc::new(OrdemXsd::ler(&caminho)?);
        mapa.lock()
            .map_err(|_| Erro::runtime("ordem do XSD indisponível"))?
            .insert(caminho, ordem.clone());
        Ok(ordem)
    }

    fn elementos_do_tipo(&self, tipo: &str) -> &[(String, String)] {
        self.tipos
            .iter()
            .find(|(n, _)| n == tipo)
            .map(|(_, e)| e.as_slice())
            .unwrap_or(&[])
    }
}

fn caminho_do_xsd_de_ordem(outra_versao: Option<&str>) -> Res<PathBuf> {
    let arquivo = caminhos::raiz().join("configs").join("paths.ini");
    if !arquivo.is_file() {
        return Err(Erro::nao_encontrado(format!(
            "Não foi possível ler o arquivo: {}",
            arquivo.display()
        )));
    }
    let ini = Ini::de_arquivo(&arquivo, false)?;
    let exigir = |opcao: &str| -> Res<String> {
        if !ini.tem_secao("schemas") {
            return Err(Erro::novo("NoSectionError", "No section: 'schemas'"));
        }
        ini.obter("schemas", opcao)
            .map(|v| aparar(v).to_string())
            .ok_or_else(|| {
                Erro::novo(
                    "NoOptionError",
                    format!("No option '{opcao}' in section: 'schemas'"),
                )
            })
    };
    let base = exigir("dir")?;
    let versao = match outra_versao {
        Some(v) => v.to_string(),
        None => exigir("versao")?,
    };
    let molde_pasta = ini.val("schemas", "ful_dir", "dir/versao");
    let pasta = validacao::expandir_molde(&molde_pasta, &[("dir", &base), ("versao", &versao)]);
    let molde = ini.val(
        "schemas",
        "schema_organizacao_xml",
        &format!("ful_dir/tiposComplexos_v{versao}.xsd"),
    );
    let valor = validacao::expandir_molde(
        &molde,
        &[("dir", &base), ("versao", &versao), ("ful_dir", &pasta)],
    );
    Ok(caminhos::normalizar(&caminhos::absoluto(&valor)))
}

/// A DPS montada.
pub struct Montada {
    pub xml: Vec<u8>,
    /// O mesmo XML, recuado, para mostrar na tela.
    pub bonito: Vec<u8>,
    pub id_dps: String,
    pub n_dps: String,
    pub serie: String,
}

struct Montador<'a> {
    cfg: &'a Ini,
    ordem: &'a OrdemXsd,
}

fn atributo_da_dps(secao: &str, opcao: &str) -> bool {
    secao == "dps" && (opcao == "versao" || opcao == "Id")
}

impl Montador<'_> {
    fn valor(&self, secao: &str, opcao: &str) -> String {
        self.cfg.val(secao, opcao, "")
    }

    /// Opções preenchidas da seção, na ordem em que estão nela.
    fn opcoes(&self, secao: &str) -> Vec<&str> {
        self.cfg
            .itens(secao)
            .into_iter()
            .filter(|(_, v)| !aparar(v).is_empty())
            .map(|(k, _)| k)
            .collect()
    }

    fn tem_grupo(&self, secao: &str) -> bool {
        if !self.opcoes(secao).is_empty() {
            return true;
        }
        let prefixo = format!("{secao}.");
        self.cfg
            .secoes()
            .into_iter()
            .any(|s| s.starts_with(&prefixo) && !self.opcoes(s).is_empty())
    }

    fn caminho_do_filho(secao: &str, filho: &str) -> String {
        if secao == "dps" {
            filho.to_string()
        } else {
            format!("{secao}.{filho}")
        }
    }

    /// Um grupo que se repete (unidades do imóvel, bens móveis…) tem uma seção por ocorrência,
    /// numerada: `X.1`, `X.2`… (nome de tag não começa por dígito, então não há confusão).
    /// Devolve os números presentes, em ordem; vazio = grupo comum, de uma ocorrência só.
    fn ocorrencias(&self, secao: &str) -> Vec<u32> {
        let prefixo = format!("{secao}.");
        let mut numeros: Vec<u32> = Vec::new();
        for s in self.cfg.secoes() {
            if let Some(resto) = s.strip_prefix(&prefixo) {
                let primeiro = resto.split('.').next().unwrap_or("");
                if let Ok(n) = primeiro.parse::<u32>() {
                    if primeiro.bytes().all(|b| b.is_ascii_digit()) && !numeros.contains(&n) {
                        numeros.push(n);
                    }
                }
            }
        }
        numeros.sort_unstable();
        numeros
    }

    fn filhos_imediatos(&self, secao: &str) -> Vec<String> {
        let mut filhos: Vec<String> = Vec::new();
        if secao == "dps" {
            for s in self.cfg.secoes() {
                if s != "dps" && !s.contains('.') {
                    filhos.push(s.to_string());
                }
            }
            return filhos;
        }
        let prefixo = format!("{secao}.");
        for s in self.cfg.secoes() {
            if let Some(resto) = s.strip_prefix(&prefixo) {
                let filho = resto.split('.').next().unwrap_or("").to_string();
                if !filhos.contains(&filho) {
                    filhos.push(filho);
                }
            }
        }
        filhos
    }

    fn por_opcao(&self, pai: &mut Elemento, secao: &str, opcao: &str) -> bool {
        if atributo_da_dps(secao, opcao) {
            return false;
        }
        let v = self.valor(secao, opcao);
        if v.is_empty() {
            return false;
        }
        pai.filho_texto(opcao, &v);
        true
    }

    fn por_grupo(&self, pai: &mut Elemento, secao: &str, tag: &str, tipo: &str) -> bool {
        let secao_filha = Self::caminho_do_filho(secao, tag);
        if !self.tem_grupo(&secao_filha) {
            return false;
        }
        let numeros = self.ocorrencias(&secao_filha);
        if numeros.is_empty() {
            let filho = pai.filho(tag);
            self.por_conteudo(filho, &secao_filha, tipo);
            return true;
        }
        let mut posto = false;
        for n in numeros {
            let da_ocorrencia = format!("{secao_filha}.{n}");
            if self.tem_grupo(&da_ocorrencia) {
                let filho = pai.filho(tag);
                self.por_conteudo(filho, &da_ocorrencia, tipo);
                posto = true;
            }
        }
        posto
    }

    fn por_conteudo(&self, pai: &mut Elemento, secao: &str, tipo: &str) {
        let mut postos: Vec<String> = Vec::new();
        // 1) o que o XSD conhece, na ordem dele
        for (nome, tipo_do_item) in self.ordem.elementos_do_tipo(tipo) {
            if self.por_opcao(pai, secao, nome) || self.por_grupo(pai, secao, nome, tipo_do_item) {
                postos.push(nome.clone());
            }
        }
        // 2) as demais opções da seção, na ordem em que estão
        for opcao in self.opcoes(secao) {
            if postos.iter().any(|p| p == opcao) || atributo_da_dps(secao, opcao) {
                continue;
            }
            if self.por_opcao(pai, secao, opcao) {
                postos.push(opcao.to_string());
            }
        }
        // 3) os demais grupos
        for filho in self.filhos_imediatos(secao) {
            if postos.contains(&filho) {
                continue;
            }
            if self.por_grupo(pai, secao, &filho, "") {
                postos.push(filho);
            }
        }
    }
}

/// Monta a DPS a partir da config final.
pub fn montar(cfg: &Ini, ns_nfse: &str) -> Res<Montada> {
    // Locação e, quando a SEFIN aceitar, todas as notas saem no leiaute novo (ver `leiaute`).
    let leiaute = leiaute::da_config(cfg);
    let no_novo;
    let cfg = match leiaute {
        Leiaute::EmVigor => cfg,
        Leiaute::Novo => {
            no_novo = leiaute::para_o_novo(cfg)?;
            &no_novo
        }
        Leiaute::Futuro => {
            no_novo = leiaute::para_o_futuro(cfg);
            &no_novo
        }
    };
    let ordem = OrdemXsd::do_leiaute(leiaute)?;
    let m = Montador { cfg, ordem: &ordem };
    let mut raiz = Elemento::novo("DPS", ns_nfse);
    let versao = m.valor("dps", "versao");
    if !versao.is_empty() {
        raiz.definir_attr("versao", &versao);
    }
    let id_dps = m.valor("dps", "Id");
    {
        let inf = raiz.filho("infDPS");
        if !id_dps.is_empty() {
            inf.definir_attr("Id", &id_dps);
        }
        m.por_conteudo(inf, "dps", &ordem.tipo_inf_dps);
    }
    // um elemento sem nada dentro não leva nó de texto
    debug_assert!(raiz.filhos.iter().all(|f| matches!(f, No::Elemento(_))));
    Ok(Montada {
        xml: xml::para_bytes(&raiz, true),
        bonito: xml::para_bytes_bonito(&raiz),
        id_dps,
        n_dps: m.valor("dps", "nDPS"),
        serie: m.valor("dps", "serie"),
    })
}
