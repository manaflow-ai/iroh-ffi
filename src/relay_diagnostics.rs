//! Credential-free snapshots of the native relay's last connection failure.

use std::error::Error;

use iroh::Watcher;
use rustls::CertificateError;

use crate::Endpoint;

/// A bounded local connection failure, never a peer-supplied error message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RelayFailureKind {
    UnknownIssuer,
    HostnameMismatch,
    CertificateExpired,
    CertificateNotYetValid,
    CertificateRevoked,
    SystemTrustFailed,
    TlsFailed,
    NetworkFailed,
    Other,
}

/// The current native home-relay state. URL credentials and paths are omitted.
#[derive(Debug, uniffi::Record)]
pub struct RelayConnectionDiagnostic {
    pub host: String,
    pub port: u16,
    pub connected: bool,
    pub failure: Option<RelayFailureKind>,
}

#[uniffi::export]
impl Endpoint {
    /// Reads the endpoint's authoritative relay state without network probes.
    pub fn relay_connection_diagnostics(&self) -> Vec<RelayConnectionDiagnostic> {
        self.raw()
            .home_relay_status()
            .get()
            .into_iter()
            .map(|status| RelayConnectionDiagnostic {
                host: status.url().host_str().unwrap_or_default().to_owned(),
                port: status.url().port_or_known_default().unwrap_or(443),
                connected: status.is_connected(),
                failure: status.last_error().map(|error| classify(error)),
            })
            .collect()
    }
}

fn classify(error: &(dyn Error + 'static)) -> RelayFailureKind {
    let mut current = Some(error);
    let mut fallback = RelayFailureKind::Other;
    // A malformed custom error chain must not make diagnostics unbounded.
    for _ in 0..32 {
        let Some(error) = current else { break };
        if let Some(error) = error.downcast_ref::<rustls::Error>() {
            return match error {
                rustls::Error::InvalidCertificate(certificate) => classify_certificate(certificate),
                _ => RelayFailureKind::TlsFailed,
            };
        }
        // These wrappers' std Error::source can skip their wrapped value.
        // Inspect it explicitly so a typed certificate error is not lost.
        if let Some(error) = error.downcast_ref::<std::io::Error>() {
            fallback = RelayFailureKind::NetworkFailed;
            current = error.get_ref().map(|error| error as &(dyn Error + 'static));
        } else if let Some(error) = error.downcast_ref::<n0_error::AnyError>() {
            use n0_error::StackError;
            current = Some(error.as_std());
        } else {
            current = error.source();
        }
    }
    fallback
}

fn classify_certificate(error: &CertificateError) -> RelayFailureKind {
    match error {
        CertificateError::UnknownIssuer => RelayFailureKind::UnknownIssuer,
        CertificateError::NotValidForName | CertificateError::NotValidForNameContext { .. } => {
            RelayFailureKind::HostnameMismatch
        }
        CertificateError::Expired | CertificateError::ExpiredContext { .. } => {
            RelayFailureKind::CertificateExpired
        }
        CertificateError::NotValidYet | CertificateError::NotValidYetContext { .. } => {
            RelayFailureKind::CertificateNotYetValid
        }
        CertificateError::Revoked => RelayFailureKind::CertificateRevoked,
        CertificateError::Other(error) => {
            // rustls-platform-verifier 0.7 maps hostname/issuer/revocation to
            // typed errors, but preserves other Apple CFError codes only as
            // "<localized description>: <numeric code>". Match the numeric
            // suffix ONLY inside this local certificate-error variant.
            match error
                .0
                .to_string()
                .rsplit_once(": ")
                .and_then(|(_, code)| code.parse::<i32>().ok())
            {
                Some(-67818) => RelayFailureKind::CertificateExpired,
                Some(-67819) => RelayFailureKind::CertificateNotYetValid,
                _ => RelayFailureKind::SystemTrustFailed,
            }
        }
        _ => RelayFailureKind::SystemTrustFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_nested_native_certificate_errors_without_rendering_credentials() {
        for (certificate, expected) in [
            (
                CertificateError::UnknownIssuer,
                RelayFailureKind::UnknownIssuer,
            ),
            (
                CertificateError::NotValidForName,
                RelayFailureKind::HostnameMismatch,
            ),
            (
                CertificateError::Expired,
                RelayFailureKind::CertificateExpired,
            ),
            (
                CertificateError::NotValidYet,
                RelayFailureKind::CertificateNotYetValid,
            ),
            (
                CertificateError::Revoked,
                RelayFailureKind::CertificateRevoked,
            ),
        ] {
            let error = n0_error::AnyError::from_std(std::io::Error::other(
                rustls::Error::InvalidCertificate(certificate),
            ))
            .context("relay https://user:secret@example.test/path?token=secret");
            assert_eq!(classify(&error), expected);
        }
        let network = std::io::Error::from(std::io::ErrorKind::ConnectionRefused);
        assert_eq!(classify(&network), RelayFailureKind::NetworkFailed);
        let untyped = std::io::Error::other("UnknownIssuer secret");
        assert_eq!(classify(&untyped), RelayFailureKind::NetworkFailed);
    }

    #[test]
    fn classifies_apple_date_codes_without_exposing_localized_text() {
        for (message, expected) in [
            (
                "localized certificate error: -67818",
                RelayFailureKind::CertificateExpired,
            ),
            (
                "localized certificate error: -67819",
                RelayFailureKind::CertificateNotYetValid,
            ),
            (
                "unrecognized certificate error: -67843",
                RelayFailureKind::SystemTrustFailed,
            ),
        ] {
            let error = CertificateError::Other(rustls::OtherError(std::sync::Arc::new(
                std::io::Error::other(message),
            )));
            assert_eq!(classify_certificate(&error), expected);
        }
    }
}
