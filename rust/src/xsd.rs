//! Validação de um XML contra um XSD, feita pela libxml2 (ligada estaticamente, a mesma versão
//! 2.11.9 de sempre): as mensagens de erro vão para a tela, e o programa conhece as manias
//! dela (ver `validacao`). Trocar de validador mudaria o texto e o que é aceito.
//!
//! Tudo o que toca a libxml2 roda numa ÚNICA linha de execução própria: ela guarda estado por
//! linha de execução e, compilada estática, cria uma ajudante para limpar cada uma que a use.
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Sender, SyncSender, channel, sync_channel};
use std::sync::{Mutex, OnceLock};

use crate::erro::{Erro, Res};

#[repr(C)]
struct XmlError {
    domain: c_int,
    code: c_int,
    message: *mut c_char,
    level: c_int,
    file: *mut c_char,
    line: c_int,
    str1: *mut c_char,
    str2: *mut c_char,
    str3: *mut c_char,
    int1: c_int,
    int2: c_int,
    ctxt: *mut c_void,
    node: *mut c_void,
}

type Tratador = unsafe extern "C" fn(*mut c_void, *mut XmlError);
/// `xmlExternalEntityLoader`: (URL, ID público, contexto) -> entrada do parser.
type Carregador = unsafe extern "C" fn(*const c_char, *const c_char, *mut c_void) -> *mut c_void;

unsafe extern "C" {
    fn xmlInitParser();
    fn xmlGetExternalEntityLoader() -> Option<Carregador>;
    fn xmlSetExternalEntityLoader(f: Option<Carregador>);
    fn xmlGetIntSubset(doc: *const c_void) -> *mut c_void;
    fn xmlSetStructuredErrorFunc(ctx: *mut c_void, handler: Option<Tratador>);
    fn xmlReadFile(url: *const c_char, encoding: *const c_char, options: c_int) -> *mut c_void;
    fn xmlReadMemory(
        buffer: *const c_char,
        size: c_int,
        url: *const c_char,
        encoding: *const c_char,
        options: c_int,
    ) -> *mut c_void;
    fn xmlFreeDoc(doc: *mut c_void);
    fn xmlSchemaNewDocParserCtxt(doc: *mut c_void) -> *mut c_void;
    fn xmlSchemaSetParserStructuredErrors(
        ctxt: *mut c_void,
        handler: Option<Tratador>,
        data: *mut c_void,
    );
    fn xmlSchemaParse(ctxt: *mut c_void) -> *mut c_void;
    fn xmlSchemaFreeParserCtxt(ctxt: *mut c_void);
    fn xmlSchemaFree(schema: *mut c_void);
    fn xmlSchemaNewValidCtxt(schema: *mut c_void) -> *mut c_void;
    fn xmlSchemaSetValidStructuredErrors(
        ctxt: *mut c_void,
        handler: Option<Tratador>,
        data: *mut c_void,
    );
    fn xmlSchemaValidateDoc(ctxt: *mut c_void, doc: *mut c_void) -> c_int;
    fn xmlSchemaFreeValidCtxt(ctxt: *mut c_void);
}

// As opções com que o programa sempre leu XML (as da lxml): entidades resolvidas, CDATA como
// texto, sem rede, nós compactos, linhas além de 65535. Valem para os XSD do próprio Baiacu.
const OPCOES: c_int = 2 | (1 << 14) | (1 << 11) | (1 << 16) | (1 << 22);
const XML_PARSE_NOENT: c_int = 2;
// O documento validado vem de fora (tela, fila, lote): as entidades NÃO são resolvidas. Sem DTD,
// que a DPS não tem, o resultado é o mesmo; com DTD, nada de arquivo ou endereço é lido.
const OPCOES_DOCUMENTO: c_int = OPCOES & !XML_PARSE_NOENT;

const SEM_DTD: &str = "O XML não pode trazer declaração DOCTYPE nem entidades: a DPS não usa esse recurso.";

/// Durante a leitura e a validação do documento, qualquer pedido de arquivo ou endereço externo
/// é recusado. Os XSD continuam carregando os vizinhos pelo carregador padrão.
unsafe extern "C" fn recusar_externo(
    _url: *const c_char,
    _id: *const c_char,
    _ctxt: *mut c_void,
) -> *mut c_void {
    std::ptr::null_mut()
}

/// O documento tem DOCTYPE/ENTITY no começo? Confere o texto em UTF-8 e em UTF-16 (a libxml2
/// aceita os dois); o que escapar daqui ainda cai no `xmlGetIntSubset` depois da leitura.
fn tem_dtd(xml: &[u8]) -> bool {
    let procura = |agulha: &[u8]| xml.windows(agulha.len()).any(|j| j == agulha);
    let utf16 = |t: &str, le: bool| -> Vec<u8> {
        t.encode_utf16()
            .flat_map(|u| if le { u.to_le_bytes() } else { u.to_be_bytes() })
            .collect()
    };
    ["<!DOCTYPE", "<!ENTITY"].iter().any(|t| {
        procura(t.as_bytes()) || procura(&utf16(t, true)) || procura(&utf16(t, false))
    })
}

/// Um apontamento do validador.
#[derive(Debug, Clone, PartialEq)]
pub struct Apontamento {
    pub linha: i32,
    /// O texto da libxml2, sem a quebra de linha do fim.
    pub mensagem: String,
}

unsafe extern "C" fn recolher(dados: *mut c_void, erro: *mut XmlError) {
    if dados.is_null() || erro.is_null() {
        return;
    }
    let lista = unsafe { &mut *(dados as *mut Vec<Apontamento>) };
    let e = unsafe { &*erro };
    let mut mensagem = if e.message.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(e.message) }
            .to_string_lossy()
            .into_owned()
    };
    if mensagem.ends_with('\n') {
        mensagem.pop();
    }
    lista.push(Apontamento {
        linha: e.line,
        mensagem,
    });
}

struct Pedido {
    xsd: PathBuf,
    xml: Vec<u8>,
    resposta: SyncSender<Res<Vec<Apontamento>>>,
}

fn fila() -> &'static Mutex<Sender<Pedido>> {
    static FILA: OnceLock<Mutex<Sender<Pedido>>> = OnceLock::new();
    FILA.get_or_init(|| {
        let (tx, rx) = channel::<Pedido>();
        std::thread::Builder::new()
            .name("xsd".into())
            .spawn(move || {
                unsafe { xmlInitParser() };
                let mut cache = Cache::default();
                for p in rx {
                    let _ = p.resposta.send(cache.validar(&p.xsd, &p.xml));
                }
            })
            .expect("linha de execução do XSD");
        Mutex::new(tx)
    })
}

/// Valida `xml` contra o XSD do arquivo `xsd`. Devolve os apontamentos (vazio = válido).
pub fn validar(xsd: &Path, xml: &[u8]) -> Res<Vec<Apontamento>> {
    let (tx, rx) = sync_channel(1);
    let pedido = Pedido {
        xsd: xsd.to_path_buf(),
        xml: xml.to_vec(),
        resposta: tx,
    };
    fila()
        .lock()
        .map_err(|_| Erro::runtime("validador XSD indisponível"))?
        .send(pedido)
        .map_err(|_| Erro::runtime("validador XSD indisponível"))?;
    rx.recv()
        .map_err(|_| Erro::runtime("validador XSD indisponível"))?
}

/// O XSD já carregado, enquanto os arquivos da pasta dele não mudarem.
#[derive(Default)]
struct Cache {
    caminho: PathBuf,
    carimbo: Vec<(String, u64, Option<std::time::SystemTime>)>,
    esquema: Option<Esquema>,
}

/// O esquema e o documento do XSD de que ele depende (quem libera o documento somos nós).
struct Esquema {
    esquema: *mut c_void,
    doc: *mut c_void,
}

impl Drop for Esquema {
    fn drop(&mut self) {
        unsafe {
            xmlSchemaFree(self.esquema);
            xmlFreeDoc(self.doc);
        }
    }
}

/// Nome, tamanho e data de cada .xsd da pasta (o principal inclui os vizinhos).
fn carimbo_da_pasta(xsd: &Path) -> Vec<(String, u64, Option<std::time::SystemTime>)> {
    let mut v = Vec::new();
    if let Some(pasta) = xsd.parent() {
        for e in std::fs::read_dir(pasta).into_iter().flatten().flatten() {
            let nome = e.file_name().to_string_lossy().into_owned();
            if nome.to_ascii_lowercase().ends_with(".xsd") {
                if let Ok(m) = e.metadata() {
                    v.push((nome, m.len(), m.modified().ok()));
                }
            }
        }
    }
    v.sort();
    v
}

fn primeira(lista: &[Apontamento]) -> String {
    lista
        .first()
        .map(|a| a.mensagem.clone())
        .unwrap_or_default()
}

impl Cache {
    fn esquema(&mut self, xsd: &Path) -> Res<*mut c_void> {
        let carimbo = carimbo_da_pasta(xsd);
        if self.esquema.is_none() || self.caminho != xsd || self.carimbo != carimbo {
            self.esquema = None;
            self.esquema = Some(carregar(xsd)?);
            self.caminho = xsd.to_path_buf();
            self.carimbo = carimbo;
        }
        Ok(self
            .esquema
            .as_ref()
            .map(|e| e.esquema)
            .unwrap_or(std::ptr::null_mut()))
    }

    fn validar(&mut self, xsd: &Path, xml: &[u8]) -> Res<Vec<Apontamento>> {
        if tem_dtd(xml) {
            return Err(Erro::valor(SEM_DTD));
        }
        let esquema = self.esquema(xsd)?;
        let mut erros: Vec<Apontamento> = Vec::new();
        let dados = &mut erros as *mut Vec<Apontamento> as *mut c_void;
        let tamanho = c_int::try_from(xml.len()).map_err(|_| Erro::valor("XML grande demais."))?;
        // Toda a libxml2 roda nesta linha de execução: trocar o carregador aqui não afeta
        // ninguém, e ele volta ao padrão antes de qualquer XSD ser lido de novo.
        let padrao = unsafe { xmlGetExternalEntityLoader() };
        unsafe { xmlSetExternalEntityLoader(Some(recusar_externo)) };
        let resultado = (|| unsafe {
            xmlSetStructuredErrorFunc(dados, Some(recolher));
            let doc = xmlReadMemory(
                xml.as_ptr() as *const c_char,
                tamanho,
                std::ptr::null(),
                std::ptr::null(),
                OPCOES_DOCUMENTO,
            );
            xmlSetStructuredErrorFunc(std::ptr::null_mut(), None);
            if doc.is_null() {
                return Err(Erro::valor(format!("XML inválido: {}", primeira(&erros))));
            }
            if !xmlGetIntSubset(doc).is_null() {
                xmlFreeDoc(doc);
                return Err(Erro::valor(SEM_DTD));
            }
            erros.clear();
            let ctxt = xmlSchemaNewValidCtxt(esquema);
            if ctxt.is_null() {
                xmlFreeDoc(doc);
                return Err(Erro::runtime("validador XSD: sem memória"));
            }
            xmlSchemaSetValidStructuredErrors(ctxt, Some(recolher), dados);
            let r = xmlSchemaValidateDoc(ctxt, doc);
            xmlSchemaFreeValidCtxt(ctxt);
            xmlFreeDoc(doc);
            if r < 0 {
                return Err(Erro::runtime("Erro interno do validador XSD."));
            }
            if r == 0 {
                erros.clear();
            }
            Ok(())
        })();
        unsafe { xmlSetExternalEntityLoader(padrao) };
        resultado.map(|()| erros)
    }
}

fn carregar(xsd: &Path) -> Res<Esquema> {
    let texto = xsd.to_string_lossy().into_owned();
    let c = CString::new(texto.clone()).map_err(|_| Erro::valor("caminho do XSD inválido"))?;
    let mut erros: Vec<Apontamento> = Vec::new();
    let dados = &mut erros as *mut Vec<Apontamento> as *mut c_void;
    unsafe {
        xmlSetStructuredErrorFunc(dados, Some(recolher));
        let doc = xmlReadFile(c.as_ptr(), std::ptr::null(), OPCOES);
        if doc.is_null() {
            xmlSetStructuredErrorFunc(std::ptr::null_mut(), None);
            return Err(Erro::os(format!(
                "Error reading file '{texto}': {}",
                primeira(&erros)
            )));
        }
        let ctxt = xmlSchemaNewDocParserCtxt(doc);
        if ctxt.is_null() {
            xmlSetStructuredErrorFunc(std::ptr::null_mut(), None);
            xmlFreeDoc(doc);
            return Err(Erro::runtime("validador XSD: sem memória"));
        }
        xmlSchemaSetParserStructuredErrors(ctxt, Some(recolher), dados);
        let esquema = xmlSchemaParse(ctxt);
        xmlSchemaFreeParserCtxt(ctxt);
        xmlSetStructuredErrorFunc(std::ptr::null_mut(), None);
        if esquema.is_null() {
            xmlFreeDoc(doc);
            return Err(Erro::valor(format!(
                "XSD inválido ({texto}): {}",
                primeira(&erros)
            )));
        }
        Ok(Esquema { esquema, doc })
    }
}

#[cfg(test)]
mod testes {
    use super::*;

    const PRINCIPAL: &str = r#"<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
  <xs:include schemaLocation="tipos.xsd"/>
  <xs:element name="DPS" type="TNumero"/>
</xs:schema>"#;
    const TIPOS: &str = r#"<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
  <xs:simpleType name="TNumero"><xs:restriction base="xs:int"/></xs:simpleType>
</xs:schema>"#;

    fn pasta() -> PathBuf {
        let p = std::env::temp_dir().join(format!("baiacu_xsd_{}", std::process::id()));
        std::fs::create_dir_all(p.join("esquemas com espaço")).unwrap();
        p
    }

    #[test]
    fn documento_nao_le_arquivo_nem_endereco_externo() {
        let raiz = pasta();
        let dir = raiz.join("esquemas com espaço");
        std::fs::write(dir.join("principal.xsd"), PRINCIPAL).unwrap();
        std::fs::write(dir.join("tipos.xsd"), TIPOS).unwrap();
        let segredo = raiz.join("segredo.txt");
        std::fs::write(&segredo, "SEGREDO123").unwrap();
        std::fs::write(raiz.join("segredo.dtd"), "<!ENTITY vaza \"SEGREDO123\">").unwrap();
        let xsd = dir.join("principal.xsd");
        let url = |nome: &str| format!("file:///{}", raiz.join(nome).display()).replace('\\', "/");

        // O XSD com include carrega e valida normalmente.
        assert!(validar(&xsd, b"<DPS>12</DPS>").unwrap().is_empty());
        let ruim = validar(&xsd, b"<DPS>abc</DPS>").unwrap();
        assert!(ruim.iter().any(|a| a.mensagem.contains("abc")), "{ruim:?}");

        let ataques = [
            format!(r#"<!DOCTYPE DPS [<!ENTITY e SYSTEM "{}">]><DPS>&e;</DPS>"#, url("segredo.txt")),
            format!(r#"<?xml version="1.0"?><!DOCTYPE DPS [<!ENTITY % p SYSTEM "{}"> %p;]><DPS>&vaza;</DPS>"#, url("segredo.dtd")),
            format!(r#"<!DOCTYPE DPS SYSTEM "{}"><DPS>1</DPS>"#, url("segredo.dtd")),
            r#"<!DOCTYPE DPS [<!ENTITY e SYSTEM "http://127.0.0.1:9/x">]><DPS>&e;</DPS>"#.to_string(),
            r#"<!DOCTYPE DPS [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]><DPS>&b;</DPS>"#.to_string(),
        ];
        for ataque in &ataques {
            let e = validar(&xsd, ataque.as_bytes()).unwrap_err();
            assert_eq!(e.msg, SEM_DTD, "{ataque}");
        }
        // O mesmo em UTF-16 (com BOM), que a libxml2 também aceita.
        let mut utf16 = vec![0xFF, 0xFE];
        utf16.extend(ataques[0].encode_utf16().flat_map(u16::to_le_bytes));
        let e = validar(&xsd, &utf16).unwrap_err();
        assert!(!e.msg.contains("SEGREDO"), "{}", e.msg);

        // Depois das recusas, um XSD relido (a pasta mudou) volta a carregar os vizinhos.
        std::fs::write(dir.join("tipos.xsd"), format!("{TIPOS}\n")).unwrap();
        assert!(validar(&xsd, b"<DPS>7</DPS>").unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&raiz);
    }

    #[test]
    fn dtd_detectada_em_utf8_e_utf16() {
        assert!(tem_dtd(b"<?xml version='1.0'?><!DOCTYPE x><x/>"));
        let be: Vec<u8> = "<!ENTITY".encode_utf16().flat_map(u16::to_be_bytes).collect();
        assert!(tem_dtd(&be));
        assert!(!tem_dtd(b"<DPS xmlns=\"http://www.sped.fazenda.gov.br/nfse\"><a>&amp;</a></DPS>"));
    }
}
