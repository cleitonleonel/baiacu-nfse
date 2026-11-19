//! Importar e exportar clientes (tomadores) por planilha: Excel (.xlsx, .xls), OpenDocument
//! (.ods) ou CSV, com cabeçalho na primeira linha.
//!
//! Não há padrão universal; o modelo segue o que os outros emissores costumam usar. A
//! importação é em duas etapas: `previa` lê e confere tudo sem gravar (erros por linha,
//! duplicados pelo CPF/CNPJ, novos × já cadastrados) e `importar` refaz a conferência e grava
//! só as linhas boas. A exportação usa as mesmas colunas, para backup e migração.
//! Só a identidade do cliente (documento, nome, endereço, um telefone e um e-mail) entra aqui;
//! os serviços e a tributação continuam no cadastro de cada cliente.
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use serde_json::{Value, json};

use crate::cadastro::{self, ContatoTomador, TipoContato, TomadorForm};
use crate::erro::{Erro, Res};
use crate::planilha;
use crate::texto::{aparar, cnpj_valido, cpf_valido, only_digits, only_doc, sort_nome};

/// Colunas do modelo e da exportação, na ordem.
pub const COLUNAS: [&str; 14] = [
    "CPF/CNPJ",
    "Nome/Razão social",
    "Inscrição municipal",
    "Código IBGE do município",
    "Cidade",
    "UF",
    "CEP",
    "Logradouro",
    "Número",
    "Complemento",
    "Bairro",
    "Telefone",
    "E-mail",
    "Observações",
];

#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
enum Campo {
    Doc,
    Nome,
    Im,
    Ibge,
    Cidade,
    Uf,
    Cep,
    Lgr,
    Nro,
    Cpl,
    Bairro,
    Fone,
    Email,
    Obs,
}

/// Nomes de coluna aceitos (já sem acento, espaço e pontuação).
fn campo_do_cabecalho(nome: &str) -> Option<Campo> {
    let n: String = sort_nome(nome).chars().filter(|c| c.is_alphanumeric()).collect();
    Some(match n.as_str() {
        "cpfcnpj" | "cnpjcpf" | "documento" | "cnpj" | "cpf" | "doc" => Campo::Doc,
        "nomerazaosocial" | "razaosocialnome" | "nome" | "razaosocial" | "cliente" | "tomador"
        | "xnome" => Campo::Nome,
        "inscricaomunicipal" | "im" => Campo::Im,
        "codigoibgedomunicipio" | "codigoibge" | "ibge" | "cmun" | "codigomunicipio"
        | "codigodomunicipio" | "municipioibge" => Campo::Ibge,
        "cidade" | "municipio" | "xcidade" => Campo::Cidade,
        "uf" | "estado" => Campo::Uf,
        "cep" => Campo::Cep,
        "logradouro" | "endereco" | "rua" | "xlgr" => Campo::Lgr,
        "numero" | "nro" | "num" | "n" => Campo::Nro,
        "complemento" | "xcpl" => Campo::Cpl,
        "bairro" | "xbairro" => Campo::Bairro,
        "telefone" | "fone" | "celular" | "telefones" => Campo::Fone,
        "email" | "emails" => Campo::Email,
        "observacoes" | "observacao" | "obs" => Campo::Obs,
        _ => return None,
    })
}

/// Lê o arquivo que o usuário escolheu (com a identidade dele, na instalação).
fn ler_planilha(origem: &Path) -> Res<planilha::Linhas> {
    let bytes = crate::caminhos::arquivo_usuario(|| std::fs::read(origem))?;
    planilha::ler_bytes(&origem.to_string_lossy(), &bytes)
}

/// CPF/CNPJ que o Excel transformou em número perde os zeros à esquerda: recupera.
fn documento(bruto: &str) -> (String, String) {
    let doc = only_doc(bruto);
    if doc.bytes().all(|b| b.is_ascii_digit()) && !doc.is_empty() && doc.len() < 14 {
        if doc.len() <= 11 {
            let cpf = format!("{doc:0>11}");
            if cpf_valido(&cpf) {
                return ("CPF".into(), cpf);
            }
        }
        let cnpj = format!("{doc:0>14}");
        if cnpj_valido(&cnpj) {
            return ("CNPJ".into(), cnpj);
        }
    }
    let tipo = if doc.len() == 11 { "CPF" } else { "CNPJ" };
    (tipo.into(), doc)
}

struct Municipios {
    por_codigo: HashMap<String, (String, String)>,
    por_nome: HashMap<(String, String), String>,
}

fn municipios() -> Municipios {
    let mut m = Municipios {
        por_codigo: HashMap::new(),
        por_nome: HashMap::new(),
    };
    for (codigo, nome, uf) in crate::consulta::listar_municipios() {
        m.por_nome
            .insert((sort_nome(&nome), uf.to_uppercase()), codigo.clone());
        m.por_codigo.insert(codigo, (nome, uf));
    }
    m
}

/// Uma linha da planilha conferida.
struct Linha {
    numero: usize,
    form: Option<TomadorForm>,
    documento: String,
    nome: String,
    municipio: String,
    erros: Vec<String>,
}

fn conferir(linhas: &planilha::Linhas) -> Res<Vec<Linha>> {
    // O cabeçalho: a primeira das 5 primeiras linhas que tem a coluna do documento.
    let (pos_cab, mapa) = linhas
        .range(..5)
        .find_map(|(&i, l)| {
            let mapa: BTreeMap<Campo, usize> = l
                .iter()
                .filter_map(|(&c, nome)| campo_do_cabecalho(nome).map(|campo| (campo, c)))
                .rev() // a primeira ocorrência de cada campo vence
                .collect();
            mapa.contains_key(&Campo::Doc).then_some((i, mapa))
        })
        .ok_or_else(|| {
            Erro::valor("Cabeçalho não encontrado: a primeira linha precisa ter a coluna \"CPF/CNPJ\" (baixe o modelo de planilha).")
        })?;
    if !mapa.contains_key(&Campo::Nome) {
        return Err(Erro::valor("Falta a coluna \"Nome/Razão social\" no cabeçalho."));
    }
    if !mapa.contains_key(&Campo::Ibge)
        && !(mapa.contains_key(&Campo::Cidade) && mapa.contains_key(&Campo::Uf))
    {
        return Err(Erro::valor(
            "Falta o município: inclua a coluna \"Código IBGE do município\" ou as colunas \"Cidade\" e \"UF\".",
        ));
    }
    let municipios = municipios();
    let mut out = Vec::new();
    for (&i, l) in linhas.range(pos_cab + 1..) {
        let v = |c: Campo| {
            mapa.get(&c)
                .and_then(|p| l.get(p))
                .map(|s| aparar(s).to_string())
                .unwrap_or_default()
        };
        if l.values().all(|c| aparar(c).is_empty()) {
            continue;
        }
        let (tipo, doc) = documento(&v(Campo::Doc));
        let mut erros = Vec::new();
        // Município: o código IBGE vence; sem ele, cidade + UF.
        let mut cidade = v(Campo::Cidade);
        let mut uf = v(Campo::Uf).to_uppercase();
        let ibge_bruto = only_digits(&v(Campo::Ibge));
        let ibge = if !ibge_bruto.is_empty() {
            match municipios.por_codigo.get(&ibge_bruto) {
                Some((nome, estado)) => {
                    if cidade.is_empty() {
                        cidade = nome.clone();
                    }
                    if uf.is_empty() {
                        uf = estado.clone();
                    }
                    ibge_bruto
                }
                None => {
                    erros.push(format!("Código IBGE {ibge_bruto} não existe."));
                    String::new()
                }
            }
        } else if !cidade.is_empty() && !uf.is_empty() {
            match municipios.por_nome.get(&(sort_nome(&cidade), uf.clone())) {
                Some(codigo) => codigo.clone(),
                None => {
                    erros.push(format!("Município \"{cidade}/{uf}\" não encontrado: confira o nome ou informe o código IBGE."));
                    String::new()
                }
            }
        } else {
            erros.push("Informe o código IBGE do município ou a cidade e a UF.".into());
            String::new()
        };
        let mut cep = only_digits(&v(Campo::Cep));
        if !cep.is_empty() && cep.len() < 8 {
            cep = format!("{cep:0>8}"); // o Excel tira o zero de "01310-100"
        }
        let fone = only_digits(&v(Campo::Fone));
        let email = v(Campo::Email).to_lowercase();
        if !email.is_empty() && (!email.contains('@') || email.contains(' ')) {
            erros.push(format!("E-mail \"{email}\" inválido."));
        }
        let mut contatos = Vec::new();
        if !fone.is_empty() {
            contatos.push(ContatoTomador {
                tipo: TipoContato::Telefone,
                valor: fone,
                principal: true,
                ..Default::default()
            });
        }
        if !email.is_empty() {
            contatos.push(ContatoTomador {
                tipo: TipoContato::Email,
                valor: email,
                principal: true,
                ..Default::default()
            });
        }
        let form = TomadorForm {
            tipo_doc: tipo,
            documento: doc.clone(),
            IM: v(Campo::Im),
            xNome: v(Campo::Nome),
            contatos: Some(contatos),
            observacoes_gerais: v(Campo::Obs),
            cMun: ibge.clone(),
            CEP: cep,
            xLgr: v(Campo::Lgr),
            nro: v(Campo::Nro),
            xCpl: v(Campo::Cpl),
            xBairro: v(Campo::Bairro),
            xCidade: cidade.clone(),
            UF: uf.clone(),
            ..Default::default()
        };
        // As mesmas regras do cadastro pela tela (sem repetir o aviso do município).
        for e in form.validate() {
            if !(e.contains("cMun") && !erros.is_empty()) {
                erros.push(e);
            }
        }
        out.push(Linha {
            numero: i + 1,
            documento: doc,
            nome: form.xNome.clone(),
            municipio: if ibge.is_empty() {
                String::new()
            } else {
                format!("{cidade}/{uf} ({ibge})")
            },
            form: Some(form),
            erros,
        });
    }
    if out.is_empty() {
        return Err(Erro::valor("A planilha não tem clientes abaixo do cabeçalho."));
    }
    // Duplicados dentro da planilha: vale a primeira linha.
    let mut vistos: HashMap<String, usize> = HashMap::new();
    for l in &mut out {
        if l.documento.is_empty() {
            continue;
        }
        if let Some(primeira) = vistos.get(&l.documento) {
            l.erros
                .push(format!("CPF/CNPJ repetido na planilha (já na linha {primeira})."));
        } else {
            vistos.insert(l.documento.clone(), l.numero);
        }
    }
    Ok(out)
}

/// Lê e confere a planilha sem gravar nada.
pub fn previa(prestador: &str, origem: &Path) -> Res<Value> {
    let linhas = conferir(&ler_planilha(origem)?)?;
    let mut novos = 0;
    let mut existentes = 0;
    let mut com_erro = 0;
    let mut saida = Vec::new();
    for l in &linhas {
        let situacao = if !l.erros.is_empty() {
            com_erro += 1;
            "erro"
        } else if cadastro::tomador_cadastrado(prestador, &l.documento)? {
            existentes += 1;
            "existente"
        } else {
            novos += 1;
            "novo"
        };
        saida.push(json!({
            "linha": l.numero,
            "documento": l.documento,
            "nome": l.nome,
            "municipio": l.municipio,
            "situacao": situacao,
            "erros": l.erros,
        }));
    }
    Ok(json!({
        "linhas": saida,
        "novos": novos,
        "existentes": existentes,
        "erros": com_erro,
    }))
}

/// Junta o que veio da planilha a um cadastro existente: campos preenchidos substituem;
/// telefone e e-mail novos entram nos contatos sem apagar os que já existiam.
fn mesclar(mut atual: TomadorForm, novo: TomadorForm) -> TomadorForm {
    let trocar = |destino: &mut String, valor: String| {
        if !aparar(&valor).is_empty() {
            *destino = valor;
        }
    };
    trocar(&mut atual.xNome, novo.xNome);
    trocar(&mut atual.IM, novo.IM);
    trocar(&mut atual.cMun, novo.cMun);
    trocar(&mut atual.CEP, novo.CEP);
    trocar(&mut atual.xLgr, novo.xLgr);
    trocar(&mut atual.nro, novo.nro);
    trocar(&mut atual.xCpl, novo.xCpl);
    trocar(&mut atual.xBairro, novo.xBairro);
    trocar(&mut atual.xCidade, novo.xCidade);
    trocar(&mut atual.UF, novo.UF);
    trocar(&mut atual.observacoes_gerais, novo.observacoes_gerais);
    // Inclui os cadastros antigos (contatos nas listas): a conversão do próprio cadastro.
    let mut contatos = atual.contatos_para_gravar();
    for c in novo.contatos.unwrap_or_default() {
        let igual = |x: &ContatoTomador| {
            x.tipo == c.tipo
                && if c.tipo == TipoContato::Email {
                    x.valor.trim().to_lowercase() == c.valor.trim().to_lowercase()
                } else {
                    only_doc(&x.valor).eq_ignore_ascii_case(&only_doc(&c.valor))
                }
        };
        if !contatos.iter().any(igual) {
            let tem_principal = contatos.iter().any(|x| x.tipo == c.tipo && x.principal);
            contatos.push(ContatoTomador {
                principal: !tem_principal,
                ..c
            });
        }
    }
    atual.contatos = Some(contatos);
    atual
}

/// Grava as linhas sem erro. Já cadastrados: atualizados só se `atualizar`.
pub fn importar(prestador: &str, origem: &Path, atualizar: bool) -> Res<Value> {
    let linhas = conferir(&ler_planilha(origem)?)?;
    let (mut criados, mut atualizados, mut pulados, mut falhas) = (0, 0, 0, Vec::new());
    for l in linhas {
        let Some(form) = l.form else { continue };
        if !l.erros.is_empty() {
            pulados += 1;
            continue;
        }
        let existe = cadastro::tomador_cadastrado(prestador, &l.documento)?;
        if existe && !atualizar {
            pulados += 1;
            continue;
        }
        let gravar = if existe {
            mesclar(cadastro::get_tomador_form(prestador, &l.documento)?, form)
        } else {
            form
        };
        match cadastro::save_tomador_form(prestador, &gravar) {
            Ok(_) if existe => atualizados += 1,
            Ok(_) => criados += 1,
            Err(e) => falhas.push(json!({"linha": l.numero, "erro": e.msg})),
        }
    }
    crate::registro::info(
        "clientes",
        &format!(
            "Importação de clientes: {criados} novo(s), {atualizados} atualizado(s), {pulados} pulado(s), {} falha(s).",
            falhas.len()
        ),
    );
    Ok(json!({
        "criados": criados,
        "atualizados": atualizados,
        "pulados": pulados,
        "falhas": falhas,
    }))
}

fn linha_do_cliente(f: &TomadorForm) -> Vec<String> {
    let principal = |tipo: TipoContato| {
        f.contatos
            .as_ref()
            .and_then(|cs| {
                cs.iter()
                    .find(|c| c.tipo == tipo && c.principal)
                    .or_else(|| cs.iter().find(|c| c.tipo == tipo))
                    .map(|c| c.valor.clone())
            })
            .unwrap_or_else(|| match tipo {
                TipoContato::Telefone => f.fone.clone(),
                _ => f.email.clone(),
            })
    };
    vec![
        only_doc(&f.documento),
        f.xNome.clone(),
        f.IM.clone(),
        f.cMun.clone(),
        f.xCidade.clone(),
        f.UF.clone(),
        f.CEP.clone(),
        f.xLgr.clone(),
        f.nro.clone(),
        f.xCpl.clone(),
        f.xBairro.clone(),
        principal(TipoContato::Telefone),
        principal(TipoContato::Email),
        f.observacoes_gerais.clone(),
    ]
}

fn erro_xlsx(e: rust_xlsxwriter::XlsxError) -> Erro {
    Erro::os(format!("Não foi possível montar a planilha: {e}"))
}

/// Planilha .xlsx com as colunas como TEXTO (o Excel não come os zeros do CPF/CNPJ e do CEP).
fn xlsx(linhas: &[Vec<String>], instrucoes: bool) -> Res<Vec<u8>> {
    use rust_xlsxwriter::{Format, Workbook};
    let mut wb = Workbook::new();
    let texto = Format::new().set_num_format("@");
    let negrito = Format::new().set_bold().set_num_format("@");
    let ws = wb.add_worksheet().set_name("Clientes").map_err(erro_xlsx)?;
    let larguras = [20.0, 40.0, 18.0, 14.0, 24.0, 6.0, 11.0, 34.0, 9.0, 18.0, 20.0, 16.0, 30.0, 40.0];
    for (c, nome) in COLUNAS.iter().enumerate() {
        ws.set_column_width(c as u16, larguras[c]).map_err(erro_xlsx)?;
        ws.set_column_format(c as u16, &texto).map_err(erro_xlsx)?;
        ws.write_string_with_format(0, c as u16, *nome, &negrito)
            .map_err(erro_xlsx)?;
    }
    for (r, linha) in linhas.iter().enumerate() {
        for (c, v) in linha.iter().enumerate() {
            ws.write_string_with_format(r as u32 + 1, c as u16, v, &texto)
                .map_err(erro_xlsx)?;
        }
    }
    ws.set_freeze_panes(1, 0).map_err(erro_xlsx)?;
    if instrucoes {
        let ws = wb.add_worksheet().set_name("Como preencher").map_err(erro_xlsx)?;
        ws.set_column_width(0, 110.0).map_err(erro_xlsx)?;
        let notas = [
            "Preencha a aba \"Clientes\" a partir da linha 2, um cliente por linha. Não mude a primeira linha (cabeçalho).",
            "CPF/CNPJ: obrigatório, com ou sem pontuação. É ele que evita duplicados: o mesmo documento duas vezes na planilha é recusado.",
            "Nome/Razão social: obrigatório.",
            "Município: informe o Código IBGE (7 dígitos) OU a Cidade e a UF (ex.: São Paulo / SP).",
            "CEP, Telefone e E-mail são opcionais. As colunas já estão como texto para o Excel não apagar zeros à esquerda.",
            "Também é aceito CSV (separado por ponto e vírgula) com as mesmas colunas.",
            "Antes de gravar, o Baiacu mostra uma prévia com os erros de cada linha. Clientes já cadastrados só são atualizados se você marcar essa opção.",
            "Esta planilha traz só os dados do cliente. Os serviços e a tributação de cada cliente são cadastrados no programa.",
        ];
        for (i, n) in notas.iter().enumerate() {
            ws.write_string(i as u32, 0, *n).map_err(erro_xlsx)?;
        }
    }
    wb.save_to_buffer().map_err(erro_xlsx)
}

fn gravar_destino(destino: &Path, dados: &[u8]) -> Res<()> {
    crate::caminhos::arquivo_usuario(|| std::fs::write(destino, dados))?;
    Ok(())
}

fn csv(destino: &Path) -> bool {
    destino
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("csv"))
}

/// O modelo de planilha (.xlsx com instruções, ou .csv só com o cabeçalho e um exemplo).
pub fn modelo(destino: &Path) -> Res<Value> {
    let exemplo: Vec<String> = [
        "12.345.678/0001-95",
        "EMPRESA EXEMPLO LTDA",
        "",
        "3550308",
        "São Paulo",
        "SP",
        "01310-100",
        "Avenida Paulista",
        "1000",
        "Sala 1",
        "Bela Vista",
        "(11) 3333-4444",
        "financeiro@exemplo.com.br",
        "Apague esta linha de exemplo",
    ]
    .map(str::to_string)
    .to_vec();
    let dados = if csv(destino) {
        let mut l = vec![COLUNAS.map(str::to_string).to_vec()];
        l.push(exemplo);
        planilha::escrever_csv(&l)
    } else {
        xlsx(&[exemplo], true)?
    };
    gravar_destino(destino, &dados)?;
    Ok(json!({"arquivo": destino.to_string_lossy()}))
}

/// Todos os clientes do prestador, nas colunas do modelo (a mesma planilha volta pela importação).
pub fn exportar(prestador: &str, destino: &Path) -> Res<Value> {
    let mut linhas = Vec::new();
    for t in cadastro::list_tomadores(prestador)? {
        let f = cadastro::get_tomador_form(prestador, &t.documento)?;
        linhas.push(linha_do_cliente(&f));
    }
    let dados = if csv(destino) {
        let mut l = vec![COLUNAS.map(str::to_string).to_vec()];
        l.extend(linhas.iter().cloned());
        planilha::escrever_csv(&l)
    } else {
        xlsx(&linhas, false)?
    };
    gravar_destino(destino, &dados)?;
    crate::registro::info(
        "clientes",
        &format!("Exportação de clientes: {} cliente(s).", linhas.len()),
    );
    Ok(json!({"arquivo": destino.to_string_lossy(), "quantidade": linhas.len()}))
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn recupera_zeros_que_o_excel_apaga() {
        // CPF 012.345.678-90 virou número 1234567890.
        let (tipo, doc) = documento("1234567890");
        assert_eq!(tipo, "CPF");
        assert_eq!(doc, "01234567890");
        assert!(cpf_valido(&doc));
        // CNPJ com pontuação continua igual.
        assert_eq!(documento("12.345.678/0001-95"), ("CNPJ".into(), "12345678000195".into()));
    }

    #[test]
    fn modelo_xlsx_volta_pela_importacao() {
        crate::caminhos::definir_raiz(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
        let linha = vec![
            "01234567890".to_string(), "MARIA DA SILVA".into(), "".into(), "".into(),
            "São Paulo".into(), "SP".into(), "01310100".into(), "RUA A".into(), "1".into(),
            "".into(), "CENTRO".into(), "11999998888".into(), "maria@exemplo.com".into(), "".into(),
        ];
        let bytes = xlsx(&[linha], true).unwrap();
        let lidas = planilha::ler_bytes("clientes.xlsx", &bytes).unwrap();
        assert_eq!(lidas[&0][&0], "CPF/CNPJ");
        let r = conferir(&lidas).unwrap();
        assert!(r[0].erros.is_empty(), "{:?}", r[0].erros);
        let f = r[0].form.as_ref().unwrap();
        assert_eq!((f.tipo_doc.as_str(), f.documento.as_str(), f.cMun.as_str()), ("CPF", "01234567890", "3550308"));
        assert_eq!(f.CEP, "01310100");
    }

    #[test]
    fn cabecalho_com_sinonimos() {
        assert_eq!(campo_do_cabecalho("CPF/CNPJ"), Some(Campo::Doc));
        assert_eq!(campo_do_cabecalho("Razão Social"), Some(Campo::Nome));
        assert_eq!(campo_do_cabecalho("Município"), Some(Campo::Cidade));
        assert_eq!(campo_do_cabecalho("Código IBGE do município"), Some(Campo::Ibge));
        assert_eq!(campo_do_cabecalho("E-mail"), Some(Campo::Email));
        assert_eq!(campo_do_cabecalho("qualquer"), None);
    }

    #[test]
    fn confere_linhas_e_duplicados() {
        crate::caminhos::definir_raiz(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(".."));
        let linhas = planilha::ler_bytes("clientes.csv", concat!(
            "CPF/CNPJ;Nome;Código IBGE;E-mail\n",
            "12.345.678/0001-95;EMPRESA A;;a@a.com\n",
            "12345678000195;EMPRESA A DE NOVO;;\n",
            "111;;;sem arroba"
        ).as_bytes()).unwrap();
        // Sem cidade/UF e sem IBGE preenchido: erro de município na linha, não na planilha.
        let r = conferir(&linhas).unwrap();
        assert_eq!(r.len(), 3);
        assert!(r[1].erros.iter().any(|e| e.contains("repetido")), "{:?}", r[1].erros);
        assert!(r[2].erros.iter().any(|e| e.contains("E-mail")), "{:?}", r[2].erros);
        assert!(r[2].erros.iter().any(|e| e.contains("Nome")), "{:?}", r[2].erros);
        let sem_documento = planilha::ler_bytes("clientes.csv", b"Nome;Cidade").unwrap();
        assert!(conferir(&sem_documento).is_err());
    }
}
