//! TLS das conexões, pelo OpenSSL (ligado estaticamente) — o mesmo de sempre.
//!
//! Não é capricho: a SEFIN Nacional só pede o certificado do prestador numa RENEGOCIAÇÃO do TLS
//! 1.2, depois de receber o pedido HTTP. Biblioteca que não renegocia (rustls) nunca chega a
//! apresentar o certificado, e toda chamada volta HTTP 403.
use std::fmt;
use std::io::Write;

use openssl::pkey::PKey;
use openssl::ssl::{ErrorCode, HandshakeError, SslConnector, SslMethod, SslStream, SslVersion};
use openssl::x509::X509;
use ureq::Error;
use ureq::unversioned::transport::{
    Buffers, ConnectionDetails, Connector, Either, LazyBuffers, NextTimeout, Transport,
    TransportAdapter,
};

use crate::certificado::Material;
use crate::erro::{Erro, Res};

/// Falha do TLS (aperto de mão, certificado do servidor recusado…).
#[derive(Debug)]
pub struct ErroTls(pub String);

impl fmt::Display for ErroTls {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ErroTls {}

fn erro_ssl(e: openssl::ssl::Error) -> Error {
    let texto = e.to_string();
    match e.into_io_error() {
        Ok(io) => Error::from(io),
        Err(_) => Error::Other(Box::new(ErroTls(texto))),
    }
}

/// Embrulha a conexão em TLS, com as autoridades certificadoras da Mozilla (as mesmas do
/// `certifi`) e, se houver, o certificado do prestador.
pub struct Conector {
    conector: SslConnector,
}

impl fmt::Debug for Conector {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Conector").finish()
    }
}

impl Conector {
    pub fn novo(material: Option<&Material>) -> Res<Conector> {
        let ssl = |e: openssl::error::ErrorStack| Erro::novo("SSLError", e.to_string());
        let mut b = SslConnector::builder(SslMethod::tls_client()).map_err(ssl)?;
        b.set_min_proto_version(Some(SslVersion::TLS1_2))
            .map_err(ssl)?;
        for der in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
            if let Ok(c) = X509::from_der(der.as_ref()) {
                let _ = b.cert_store_mut().add_cert(c);
            }
        }
        if let Some(m) = material {
            let pem = m.chave_pkcs1_pem()?;
            let chave = PKey::private_key_from_pem(pem.as_bytes()).map_err(ssl)?;
            let certificado = X509::from_der(&m.cert_der).map_err(ssl)?;
            b.set_certificate(&certificado).map_err(ssl)?;
            b.set_private_key(&chave).map_err(ssl)?;
            for c in &m.adicionais_der {
                b.add_extra_chain_cert(X509::from_der(c).map_err(ssl)?)
                    .map_err(ssl)?;
            }
        }
        Ok(Conector {
            conector: b.build(),
        })
    }
}

impl<In: Transport> Connector<In> for Conector {
    type Out = Either<In, Transporte>;

    fn connect(
        &self,
        details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, Error> {
        let Some(transporte) = chained else {
            return Err(Error::Other(Box::new(ErroTls(
                "sem conexão para o TLS".into(),
            ))));
        };
        if !details.needs_tls() || transporte.is_tls() {
            return Ok(Some(Either::A(transporte)));
        }
        let dominio = details
            .uri
            .host()
            .unwrap_or("")
            .trim_start_matches('[')
            .trim_end_matches(']')
            .to_string();
        let mut adaptador = TransportAdapter::new(transporte.boxed());
        adaptador.set_timeout(details.timeout);
        let fluxo = self
            .conector
            .connect(&dominio, adaptador)
            .map_err(|e| match e {
                HandshakeError::SetupFailure(pilha) => {
                    Error::Other(Box::new(ErroTls(pilha.to_string())))
                }
                HandshakeError::Failure(meio) | HandshakeError::WouldBlock(meio) => {
                    let verificacao = meio.ssl().verify_result();
                    let erro = meio.into_error();
                    let texto = if verificacao != openssl::x509::X509VerifyResult::OK {
                        format!("{erro}: {}", verificacao.error_string())
                    } else {
                        erro.to_string()
                    };
                    match erro.into_io_error() {
                        Ok(io) => Error::from(io),
                        Err(_) => Error::Other(Box::new(ErroTls(texto))),
                    }
                }
            })?;
        let buffers = LazyBuffers::new(
            details.config.input_buffer_size(),
            details.config.output_buffer_size(),
        );
        Ok(Some(Either::B(Transporte { buffers, fluxo })))
    }
}

pub struct Transporte {
    buffers: LazyBuffers,
    fluxo: SslStream<TransportAdapter>,
}

impl fmt::Debug for Transporte {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Transporte").finish()
    }
}

impl Transport for Transporte {
    fn buffers(&mut self) -> &mut dyn Buffers {
        &mut self.buffers
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), Error> {
        self.fluxo.get_mut().set_timeout(timeout);
        let saida = &self.buffers.output()[..amount];
        let mut enviado = 0;
        while enviado < saida.len() {
            match self.fluxo.ssl_write(&saida[enviado..]) {
                Ok(n) => enviado += n,
                Err(e) if e.code() == ErrorCode::WANT_READ && e.io_error().is_none() => {}
                Err(e) => return Err(erro_ssl(e)),
            }
        }
        self.fluxo.flush()?;
        Ok(())
    }

    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, Error> {
        self.fluxo.get_mut().set_timeout(timeout);
        let entrada = self.buffers.input_append_buf();
        // a leitura cuida sozinha da renegociação pedida pelo servidor no meio da resposta
        let lido = loop {
            match self.fluxo.ssl_read(entrada) {
                Ok(n) => break n,
                Err(e) if e.code() == ErrorCode::ZERO_RETURN => break 0,
                Err(e) if e.code() == ErrorCode::SYSCALL && e.io_error().is_none() => break 0,
                Err(e) if e.code() == ErrorCode::WANT_READ && e.io_error().is_none() => {}
                Err(e) => return Err(erro_ssl(e)),
            }
        };
        self.buffers.input_appended(lido);
        Ok(lido > 0)
    }

    fn is_open(&mut self) -> bool {
        self.fluxo.get_mut().get_mut().is_open()
    }

    fn is_tls(&self) -> bool {
        true
    }
}
