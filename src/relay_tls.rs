//! System trust and endpoint-owned certificate diagnostics, including discovery.

use std::sync::Arc;

use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use tokio::sync::watch;

use crate::relay_diagnostics::{RelayConnectionDiagnostic, RelayFailureKind, classify_certificate};

#[derive(Debug, Clone)]
pub(crate) struct RelayTlsDiagnostics {
    failures: watch::Sender<Vec<RelayConnectionDiagnostic>>,
}

impl Default for RelayTlsDiagnostics {
    fn default() -> Self {
        Self {
            failures: watch::channel(Vec::new()).0,
        }
    }
}

impl RelayTlsDiagnostics {
    pub(crate) fn configure(&self, builder: iroh::endpoint::Builder) -> iroh::endpoint::Builder {
        let diagnostics = self.clone();
        builder.ca_tls_config(iroh::tls::CaTlsConfig::custom_server_cert_verifier(
            Arc::new(move |provider| {
                #[cfg(target_os = "macos")]
                let policy = iroh::tls::CaTlsConfig::system();
                // iOS and other platforms keep their existing embedded policy.
                #[cfg(not(target_os = "macos"))]
                let policy = iroh::tls::CaTlsConfig::embedded();
                Ok(Arc::new(DiagnosticVerifier {
                    verifier: policy.server_cert_verifier(provider)?,
                    diagnostics: diagnostics.clone(),
                }))
            }),
        ))
    }

    pub(crate) fn subscribe(&self) -> watch::Receiver<Vec<RelayConnectionDiagnostic>> {
        self.failures.subscribe()
    }

    pub(crate) fn snapshot(&self) -> Vec<RelayConnectionDiagnostic> {
        self.failures.borrow().clone()
    }

    fn record(&self, host: String, failure: Option<RelayFailureKind>) {
        // Verification is a synchronous rustls callback. watch owns the short
        // synchronous update and asynchronously notifies consumers; no foreign
        // callback runs while its internal lock is held.
        self.failures.send_if_modified(|failures| {
            let previous = failures.clone();
            failures.retain(|value| value.host != host);
            if let Some(failure) = failure {
                if failures.len() == 64 {
                    failures.remove(0);
                }
                failures.push(RelayConnectionDiagnostic {
                    host,
                    port: None, // TLS's SNI callback supplies no port.
                    connected: false,
                    failure: Some(failure),
                });
            }
            failures.sort_by(|left, right| left.host.cmp(&right.host));
            *failures != previous
        });
    }
}

#[derive(Debug)]
struct DiagnosticVerifier {
    verifier: Arc<dyn ServerCertVerifier>,
    diagnostics: RelayTlsDiagnostics,
}

impl ServerCertVerifier for DiagnosticVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let result = self.verifier.verify_server_cert(
            end_entity,
            intermediates,
            server_name,
            ocsp_response,
            now,
        );
        let failure = result.as_ref().err().map(|error| match error {
            rustls::Error::InvalidCertificate(certificate) => classify_certificate(certificate),
            _ => RelayFailureKind::TlsFailed,
        });
        self.diagnostics
            .record(server_name.to_str().into_owned(), failure);
        result
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.verifier.verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.verifier.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.verifier.supported_verify_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn successful_validation_clears_only_the_matching_host() {
        let state = RelayTlsDiagnostics::default();
        state.record("one.example".into(), Some(RelayFailureKind::UnknownIssuer));
        state.record(
            "two.example".into(),
            Some(RelayFailureKind::HostnameMismatch),
        );
        state.record("one.example".into(), None);
        assert_eq!(state.snapshot().len(), 1);
        assert_eq!(state.snapshot()[0].host, "two.example");
    }
}
