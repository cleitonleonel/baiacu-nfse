//! Rede: HTTPS com (ou sem) o certificado do prestador (mTLS).
//!
//! A chave privada fica só na memória — nada de arquivo temporário com ela. Uma `Sessao`
//! reaproveita a conexão e os cookies entre as chamadas (POST /nfse, GET do XML e GET do DANFSe
//! batem no mesmo host) e vive UMA operação: nunca é global, para a conexão autenticada de um
//! prestador não servir a outro.
use std::time::Duration;

use serde_json::{Map, Value, json};
use ureq::config::IpFamily;
use ureq::unversioned::resolver::DefaultResolver;
use ureq::unversioned::transport::{ConnectProxyConnector, Connector, TcpConnector};
use ureq::{Agent, ResponseExt};

use crate::certificado::Material;
use crate::erro::{Erro, Res};
use crate::jsonpy;
use crate::rede_tls::{Conector, ErroTls};

/// Tempo máximo (segundos) para conectar e para o servidor responder.
#[derive(Debug, Clone, Copy)]
pub struct Tempo {
    pub conectar: f64,
    pub ler: f64,
}

impl Tempo {
    pub const fn igual(s: f64) -> Tempo {
        Tempo {
            conectar: s,
            ler: s,
        }
    }
}

/// Nome que cada falha de rede sempre teve nas mensagens do programa.
pub const TIPOS_DE_REDE: [&str; 6] = [
    "ConnectionError",
    "ConnectTimeout",
    "ReadTimeout",
    "SSLError",
    "ProxyError",
    "RequestException",
];

/// A falha é de rede (não chegou resposta do servidor)?
pub fn erro_de_rede(e: &Erro) -> bool {
    TIPOS_DE_REDE.contains(&e.tipo)
}

fn traduzir(e: ureq::Error) -> Erro {
    use ureq::Error as U;
    use ureq::Timeout as T;
    let tipo = match &e {
        U::Timeout(T::Connect | T::Resolve) => "ConnectTimeout",
        U::Timeout(_) | U::BodyStalled => "ReadTimeout",
        U::HostNotFound | U::ConnectionFailed | U::Io(_) | U::Protocol(_) => "ConnectionError",
        U::Other(e) if e.is::<ErroTls>() => "SSLError",
        U::ConnectProxyFailed(_) | U::InvalidProxyUrl => "ProxyError",
        _ => "RequestException",
    };
    Erro::novo(tipo, e.to_string())
}

/// Uma resposta HTTP completa.
#[derive(Debug, Clone)]
pub struct Resposta {
    pub url: String,
    pub metodo: String,
    pub status: u16,
    pub motivo: String,
    pub cabecalhos: Vec<(String, String)>,
    pub corpo: Vec<u8>,
}

impl Resposta {
    /// Cabeçalho pelo nome, sem diferenciar maiúsculas.
    pub fn cabecalho(&self, nome: &str) -> Option<&str> {
        self.cabecalhos
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(nome))
            .map(|(_, v)| v.as_str())
    }

    /// O corpo como JSON, se for.
    pub fn json(&self) -> Option<Value> {
        let b = self
            .corpo
            .strip_prefix(b"\xef\xbb\xbf")
            .unwrap_or(&self.corpo);
        serde_json::from_slice(b).ok()
    }

    /// O corpo como texto, na codificação que o servidor declarou.
    pub fn texto(&self) -> String {
        let tipo = self
            .cabecalho("content-type")
            .unwrap_or("")
            .to_ascii_lowercase();
        let declarada = tipo
            .split(';')
            .skip(1)
            .filter_map(|p| p.trim().strip_prefix("charset="))
            .map(|c| c.trim_matches(|x| x == '"' || x == '\'').to_string())
            .next();
        let latin1 = |b: &[u8]| b.iter().map(|&c| c as char).collect::<String>();
        match declarada.as_deref() {
            Some("iso-8859-1" | "latin-1" | "latin1" | "windows-1252" | "cp1252") => {
                latin1(&self.corpo)
            }
            Some(_) => String::from_utf8_lossy(&self.corpo).into_owned(),
            None if tipo.starts_with("text/") => latin1(&self.corpo),
            None => match std::str::from_utf8(&self.corpo) {
                Ok(t) => t.strip_prefix('\u{feff}').unwrap_or(t).to_string(),
                Err(_) => latin1(&self.corpo),
            },
        }
    }

    /// O registro da resposta que o programa guarda e examina.
    pub fn registro(&self) -> Value {
        let corpo = self.json().unwrap_or_else(|| Value::String(self.texto()));
        let mut cabecalhos = Map::new();
        for (k, v) in &self.cabecalhos {
            let v = if matches!(
                k.to_ascii_lowercase().as_str(),
                "set-cookie" | "cookie" | "authorization"
            ) {
                "***REDACTED***".to_string()
            } else {
                match cabecalhos.get(k).and_then(Value::as_str) {
                    Some(antes) => format!("{antes}, {v}"),
                    None => v.clone(),
                }
            };
            cabecalhos.insert(k.clone(), Value::String(v));
        }
        json!({
            "request_url": self.url,
            "request_method": self.metodo,
            "status_code": self.status,
            "reason": self.motivo,
            "headers": cabecalhos,
            "body": corpo,
        })
    }
}

/// Conexões reaproveitadas de UMA operação.
#[derive(Clone)]
pub struct Sessao {
    agente: Agent,
}

fn dur(s: f64) -> Option<Duration> {
    Some(Duration::from_secs_f64(s.max(0.001)))
}

impl Sessao {
    /// `material`: o certificado do prestador (mTLS) ou nenhum. `so_ipv4`: não tentar IPv6.
    pub fn nova(
        material: Option<&Material>,
        tempo: Tempo,
        identificacao: &str,
        so_ipv4: bool,
    ) -> Res<Sessao> {
        let conector =
            ().chain(ConnectProxyConnector::default())
                .chain(TcpConnector::default())
                .chain(Conector::novo(material)?);
        let config = Agent::config_builder()
            .http_status_as_error(false)
            .user_agent(identificacao)
            .ip_family(if so_ipv4 {
                IpFamily::Ipv4Only
            } else {
                IpFamily::Any
            })
            .timeout_resolve(dur(tempo.conectar))
            .timeout_connect(dur(tempo.conectar))
            .timeout_send_request(dur(tempo.ler))
            .timeout_send_body(dur(tempo.ler))
            .timeout_recv_response(dur(tempo.ler))
            .timeout_recv_body(dur(tempo.ler))
            .build();
        Ok(Sessao {
            agente: Agent::with_parts(config, conector, DefaultResolver::default()),
        })
    }

    fn concluir(
        metodo: &str,
        r: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
    ) -> Res<Resposta> {
        let mut r = r.map_err(traduzir)?;
        let status = r.status();
        let cabecalhos: Vec<(String, String)> = r
            .headers()
            .iter()
            .map(|(k, v)| {
                (
                    k.as_str().to_string(),
                    String::from_utf8_lossy(v.as_bytes()).into_owned(),
                )
            })
            .collect();
        let url = r.get_uri().to_string();
        let corpo = r
            .body_mut()
            .with_config()
            .limit(1 << 30)
            .read_to_vec()
            .map_err(traduzir)?;
        Ok(Resposta {
            url,
            metodo: metodo.to_string(),
            status: status.as_u16(),
            motivo: status.canonical_reason().unwrap_or("").to_string(),
            cabecalhos,
            corpo,
        })
    }

    pub fn get(&self, url: &str, cabecalhos: &[(&str, &str)]) -> Res<Resposta> {
        let mut pedido = self.agente.get(url);
        for (k, v) in cabecalhos {
            pedido = pedido.header(*k, *v);
        }
        Self::concluir("GET", pedido.call())
    }

    /// GET de um arquivo grande direto para o disco, avisando quantos bytes já chegaram.
    /// Só aceita resposta 200; em qualquer falha o arquivo parcial é apagado.
    pub fn baixar(
        &self,
        url: &str,
        destino: &std::path::Path,
        progresso: &mut dyn FnMut(u64),
    ) -> Res<u64> {
        use std::io::{Read, Write};
        let mut r = self.agente.get(url).call().map_err(traduzir)?;
        if r.status().as_u16() != 200 {
            return Err(Erro::novo(
                "HTTPError",
                format!("{} ao baixar {url}", r.status().as_u16()),
            ));
        }
        let resultado = (|| -> Res<u64> {
            let mut leitor = r.body_mut().with_config().limit(1 << 32).reader();
            let mut saida = std::fs::File::create(destino)?;
            let mut buf = vec![0u8; 1 << 16];
            let mut total = 0u64;
            loop {
                let n = leitor.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                saida.write_all(&buf[..n])?;
                total += n as u64;
                progresso(total);
            }
            saida.sync_all()?;
            Ok(total)
        })();
        if resultado.is_err() {
            let _ = std::fs::remove_file(destino);
        }
        resultado
    }

    /// POST com o corpo em JSON (no formato de sempre: `", "` e `": "`, só ASCII).
    pub fn post_json(
        &self,
        url: &str,
        corpo: &Value,
        cabecalhos: &[(&str, &str)],
    ) -> Res<Resposta> {
        let texto = jsonpy::dumps(corpo, jsonpy::Formato::PADRAO);
        let mut pedido = self.agente.post(url);
        for (k, v) in cabecalhos {
            pedido = pedido.header(*k, *v);
        }
        Self::concluir("POST", pedido.send(texto.as_bytes()))
    }
}
