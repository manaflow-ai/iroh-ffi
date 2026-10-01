//! Foreign-implementable address lookup (custom discovery) surface.
//!
//! [`AddressLookupService`] lets the foreign language (Swift/Kotlin/Python)
//! act as an `iroh::address_lookup::AddressLookup` service: resolve answers
//! endpoint-id lookups with pkarr signed-packet blobs, publish receives the
//! local endpoint's freshly signed record whenever its address data changes.
//!
//! Records are pkarr `SignedPacket`s (ed25519-signed DNS packets keyed by the
//! endpoint public key). Rust verifies every record signature at parse time
//! and drops records whose key does not match the requested endpoint id, so
//! the foreign store never has to be trusted for integrity. Freshness policy
//! (TTL windows, relay allowlists) stays with the foreign implementation.

use std::{net::SocketAddr, str::FromStr, sync::Arc, time::Duration};

use iroh::address_lookup::{
    AddressLookup, AddressLookupBuilder, AddressLookupBuilderError, EndpointData, EndpointInfo,
    Error as LookupError, Item,
};
use iroh_base::RelayUrl;
use iroh_dns::pkarr::SignedPacket;
use n0_future::{StreamExt, boxed::BoxStream};

use crate::{CallbackError, EndpointId, IrohError, SecretKey};

/// Provenance string attached to every [`Item`] this service yields.
pub(crate) const PROVENANCE: &str = "cmux-registry";

/// TTL baked into records signed on the publish side, in seconds.
///
/// Matches iroh's pkarr default. Consumers apply their own freshness policy;
/// this value only ends up inside the DNS TXT records.
const RECORD_TTL_SECONDS: u32 = 30;

/// Upper bound on a single foreign resolve call.
///
/// magicsock runs at most one lookup per remote at a time; a hung foreign
/// implementation must not pin that slot forever.
const RESOLVE_TIMEOUT: Duration = Duration::from_secs(15);

/// A foreign-implementable address lookup service.
///
/// Install one via [`EndpointOptions::address_lookup`] or
/// [`EndpointBuilder::add_address_lookup`]; iroh then calls it whenever a
/// connect needs addressing information for an endpoint id, and whenever the
/// local endpoint's own addressing data changes.
///
/// [`EndpointOptions::address_lookup`]: crate::EndpointOptions::address_lookup
/// [`EndpointBuilder::add_address_lookup`]: crate::EndpointBuilder::add_address_lookup
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait AddressLookupService: Send + Sync + 'static {
    /// Resolve signed records for `endpoint_id`.
    ///
    /// Returns zero or more pkarr `SignedPacket` byte blobs (as produced by
    /// [`sign_endpoint_record`] or a peer's publish callback). Signature
    /// verification and endpoint-id matching happen in Rust afterwards, so
    /// implementations can return whatever their cache or registry holds.
    /// One-shot: called again on later connects when needed. Bounded by a
    /// Rust-side timeout; a hung call is dropped, not awaited forever.
    async fn resolve(&self, endpoint_id: Arc<EndpointId>) -> Result<Vec<Vec<u8>>, CallbackError>;

    /// Receive the local endpoint's freshly signed record.
    ///
    /// Called (fire and forget, from a spawned task) whenever the endpoint's
    /// address data changes: relay or direct addresses appeared or changed.
    /// The record is a pkarr `SignedPacket`, already signed with the
    /// endpoint's secret key; upload or store it as an opaque blob.
    async fn publish(&self, record: Vec<u8>) -> Result<(), CallbackError>;
}

/// Errors produced while adapting foreign lookup results for iroh.
#[derive(Debug, thiserror::Error)]
enum RecordError {
    #[error("record is signed by {actual}, requested endpoint is {expected}")]
    EndpointIdMismatch {
        expected: iroh::EndpointId,
        actual: iroh::EndpointId,
    },
    #[error("foreign resolve timed out after {0:?}")]
    Timeout(Duration),
}

/// Parses and verifies one record blob into an [`Item`] for `expected`.
fn parse_item(expected: iroh::EndpointId, blob: &[u8]) -> Result<Item, LookupError> {
    let packet =
        SignedPacket::from_bytes(blob).map_err(|err| LookupError::from_err(PROVENANCE, err))?;
    let info = EndpointInfo::from_pkarr_signed_packet(&packet)
        .map_err(|err| LookupError::from_err(PROVENANCE, err))?;
    if info.endpoint_id != expected {
        return Err(LookupError::from_err(
            PROVENANCE,
            RecordError::EndpointIdMismatch {
                expected,
                actual: info.endpoint_id,
            },
        ));
    }
    let last_updated = packet.timestamp().as_micros();
    Ok(Item::new(info, PROVENANCE, Some(last_updated)))
}

/// [`AddressLookupBuilder`] that captures the endpoint secret key at bind so
/// the adapter can sign publish-side records without a second key custodian.
#[derive(derive_more::Debug)]
pub(crate) struct ForeignAddressLookupBuilder {
    #[debug("AddressLookupService")]
    service: Arc<dyn AddressLookupService>,
}

impl ForeignAddressLookupBuilder {
    pub(crate) fn new(service: Arc<dyn AddressLookupService>) -> Self {
        Self { service }
    }
}

impl AddressLookupBuilder for ForeignAddressLookupBuilder {
    fn into_address_lookup(
        self,
        endpoint: &iroh::Endpoint,
    ) -> Result<impl AddressLookup, AddressLookupBuilderError> {
        Ok(ForeignAddressLookup {
            service: self.service,
            secret_key: endpoint.secret_key().clone(),
        })
    }
}

/// Adapter between iroh's [`AddressLookup`] and the foreign
/// [`AddressLookupService`].
#[derive(derive_more::Debug, Clone)]
pub(crate) struct ForeignAddressLookup {
    #[debug("AddressLookupService")]
    service: Arc<dyn AddressLookupService>,
    secret_key: iroh::SecretKey,
}

impl AddressLookup for ForeignAddressLookup {
    fn publish(&self, data: &EndpointData) {
        let info = EndpointInfo::from_parts(self.secret_key.public(), data.clone());
        let packet = match info.to_pkarr_signed_packet(&self.secret_key, RECORD_TTL_SECONDS) {
            Ok(packet) => packet,
            Err(err) => {
                tracing::warn!("address lookup publish: failed to sign endpoint record: {err:?}");
                return;
            }
        };
        let record = packet.as_bytes().to_vec();
        let service = self.service.clone();
        // `publish` must not block; iroh calls it from a runtime task.
        tokio::spawn(async move {
            if let Err(err) = service.publish(record).await {
                tracing::debug!("address lookup publish callback failed: {err:?}");
            }
        });
    }

    fn resolve(
        &self,
        endpoint_id: iroh::EndpointId,
    ) -> Option<BoxStream<Result<Item, LookupError>>> {
        let service = self.service.clone();
        let results = async move {
            let foreign_id = Arc::new(EndpointId::from(endpoint_id));
            let resolved = tokio::time::timeout(RESOLVE_TIMEOUT, service.resolve(foreign_id)).await;
            let blobs = match resolved {
                Err(_elapsed) => {
                    return vec![Err(LookupError::from_err(
                        PROVENANCE,
                        RecordError::Timeout(RESOLVE_TIMEOUT),
                    ))];
                }
                Ok(Err(err)) => {
                    return vec![Err(LookupError::from_err(PROVENANCE, err))];
                }
                Ok(Ok(blobs)) => blobs,
            };
            blobs
                .iter()
                .map(|blob| parse_item(endpoint_id, blob))
                .collect()
        };
        Some(
            n0_future::stream::once_future(results)
                .flat_map(n0_future::stream::iter)
                .boxed(),
        )
    }
}

/// Summary of a parsed and signature-verified endpoint record.
#[derive(Debug, uniffi::Record)]
pub struct RecordSummary {
    /// The endpoint id that signed the record.
    pub endpoint_id: Arc<EndpointId>,
    /// Relay URLs published in the record, in record order.
    pub relay_urls: Vec<String>,
    /// Direct `ip:port` addresses published in the record, in record order.
    pub direct_addrs: Vec<String>,
    /// Microseconds since the unix epoch when the record was signed.
    pub last_updated: u64,
}

/// Parses a pkarr signed-packet blob, verifying its signature.
///
/// Fails on malformed blobs and on bad signatures. The returned summary is
/// for inspection and tests; the resolve path parses records itself.
#[uniffi::export]
pub fn parse_endpoint_record(bytes: Vec<u8>) -> Result<RecordSummary, IrohError> {
    let packet = SignedPacket::from_bytes(&bytes)
        .map_err(|err| anyhow::anyhow!("invalid endpoint record: {err:?}"))?;
    let info = EndpointInfo::from_pkarr_signed_packet(&packet)
        .map_err(|err| anyhow::anyhow!("invalid endpoint record contents: {err:?}"))?;
    Ok(RecordSummary {
        endpoint_id: Arc::new(info.endpoint_id.into()),
        relay_urls: info.relay_urls().map(|url| url.to_string()).collect(),
        direct_addrs: info.ip_addrs().map(|addr| addr.to_string()).collect(),
        last_updated: packet.timestamp().as_micros(),
    })
}

/// Signs an endpoint record for `secret_key`'s endpoint id.
///
/// Returns the serialized pkarr `SignedPacket`, suitable for handing to an
/// [`AddressLookupService::resolve`] response. `ttl_seconds` is baked into
/// the DNS records (see [`parse_endpoint_record`] for reading it back is not
/// supported; freshness policy should use `last_updated`).
#[uniffi::export]
pub fn sign_endpoint_record(
    secret_key: &SecretKey,
    relay_urls: Vec<String>,
    direct_addrs: Vec<String>,
    ttl_seconds: u32,
) -> Result<Vec<u8>, IrohError> {
    let mut info = EndpointInfo::new(secret_key.0.public());
    for url in relay_urls {
        info = info.with_relay_url(RelayUrl::from_str(&url).map_err(anyhow::Error::from)?);
    }
    let addrs = direct_addrs
        .iter()
        .map(|addr| SocketAddr::from_str(addr))
        .collect::<Result<Vec<_>, _>>()
        .map_err(anyhow::Error::from)?;
    info = info.with_ip_addrs(addrs);
    let packet = info
        .to_pkarr_signed_packet(&secret_key.0, ttl_seconds)
        .map_err(|err| anyhow::anyhow!("failed to sign endpoint record: {err:?}"))?;
    Ok(packet.as_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashMap,
        sync::{
            Mutex as StdMutex,
            atomic::{AtomicUsize, Ordering},
        },
    };

    use tokio::sync::mpsc;

    use super::*;
    use crate::{Endpoint, EndpointAddr, EndpointOptions};

    const TEST_ALPN: &[u8] = b"/cmux/lookup-test/1";

    #[derive(Default)]
    struct TestLookupService {
        records: StdMutex<HashMap<Vec<u8>, Vec<Vec<u8>>>>,
        published: StdMutex<Option<mpsc::UnboundedSender<Vec<u8>>>>,
        resolve_calls: AtomicUsize,
        fail_resolve: bool,
    }

    impl TestLookupService {
        fn with_records(records: HashMap<Vec<u8>, Vec<Vec<u8>>>) -> Self {
            Self {
                records: StdMutex::new(records),
                ..Default::default()
            }
        }

        fn with_publish_sink(sender: mpsc::UnboundedSender<Vec<u8>>) -> Self {
            Self {
                published: StdMutex::new(Some(sender)),
                ..Default::default()
            }
        }
    }

    #[async_trait::async_trait]
    impl AddressLookupService for TestLookupService {
        async fn resolve(
            &self,
            endpoint_id: Arc<EndpointId>,
        ) -> Result<Vec<Vec<u8>>, CallbackError> {
            self.resolve_calls.fetch_add(1, Ordering::SeqCst);
            if self.fail_resolve {
                return Err(CallbackError::Error);
            }
            Ok(self
                .records
                .lock()
                .unwrap()
                .get(&endpoint_id.to_bytes())
                .cloned()
                .unwrap_or_default())
        }

        async fn publish(&self, record: Vec<u8>) -> Result<(), CallbackError> {
            if let Some(sender) = &*self.published.lock().unwrap() {
                let _ = sender.send(record);
            }
            Ok(())
        }
    }

    fn adapter(service: Arc<dyn AddressLookupService>) -> ForeignAddressLookup {
        ForeignAddressLookup {
            service,
            secret_key: iroh::SecretKey::generate(),
        }
    }

    async fn collect_resolve(
        lookup: &ForeignAddressLookup,
        endpoint_id: iroh::EndpointId,
    ) -> Vec<Result<Item, LookupError>> {
        let stream = lookup
            .resolve(endpoint_id)
            .expect("resolve returns a stream");
        stream.collect().await
    }

    #[test]
    fn test_sign_parse_roundtrip() {
        let secret = SecretKey::generate();
        let record = sign_endpoint_record(
            &secret,
            vec!["https://relay.example.com./".to_string()],
            vec!["192.168.1.10:4433".to_string(), "10.0.0.3:9999".to_string()],
            30,
        )
        .unwrap();

        let summary = parse_endpoint_record(record.clone()).unwrap();
        assert_eq!(summary.endpoint_id.to_bytes(), secret.public().to_bytes());
        assert_eq!(summary.relay_urls, vec!["https://relay.example.com./"]);
        assert_eq!(
            summary.direct_addrs,
            vec!["192.168.1.10:4433", "10.0.0.3:9999"]
        );
        assert!(summary.last_updated > 0);

        // Flipping a payload byte must break signature verification.
        let mut tampered = record;
        let last = tampered.len() - 1;
        tampered[last] ^= 0xff;
        assert!(parse_endpoint_record(tampered).is_err());
    }

    #[tokio::test]
    async fn test_resolve_verifies_and_filters_records() {
        let target_secret = SecretKey::generate();
        let target_id: iroh::EndpointId = (&*target_secret.public()).into();
        let other_secret = SecretKey::generate();

        let good = sign_endpoint_record(
            &target_secret,
            vec![],
            vec!["127.0.0.1:4444".to_string()],
            30,
        )
        .unwrap();
        // Valid signature, but signed by a different endpoint.
        let mismatched = sign_endpoint_record(
            &other_secret,
            vec![],
            vec!["127.0.0.1:5555".to_string()],
            30,
        )
        .unwrap();
        let garbage = vec![0u8; 32];

        let service = Arc::new(TestLookupService::with_records(HashMap::from([(
            target_secret.public().to_bytes(),
            vec![garbage, mismatched, good],
        )])));
        let lookup = adapter(service.clone());

        let results = collect_resolve(&lookup, target_id).await;
        assert_eq!(results.len(), 3);
        let items: Vec<&Item> = results.iter().filter_map(|r| r.as_ref().ok()).collect();
        assert_eq!(items.len(), 1, "exactly the matching record survives");
        assert_eq!(items[0].endpoint_id(), target_id);
        let addrs: Vec<String> = items[0]
            .endpoint_info()
            .ip_addrs()
            .map(|a| a.to_string())
            .collect();
        assert_eq!(addrs, vec!["127.0.0.1:4444"]);
        assert_eq!(items[0].provenance(), PROVENANCE);
        assert!(items[0].last_updated().is_some());
        assert_eq!(service.resolve_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_resolve_foreign_error_yields_lookup_error() {
        let service = Arc::new(TestLookupService {
            fail_resolve: true,
            ..Default::default()
        });
        let lookup = adapter(service);
        let target = iroh::SecretKey::generate().public();

        let results = collect_resolve(&lookup, target).await;
        assert_eq!(results.len(), 1);
        assert!(results[0].is_err());
    }

    #[tokio::test]
    async fn test_resolve_empty_records_yields_empty_stream() {
        let service = Arc::new(TestLookupService::default());
        let lookup = adapter(service);
        let target = iroh::SecretKey::generate().public();

        let results = collect_resolve(&lookup, target).await;
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn test_publish_fires_with_signed_record_on_bind() {
        let (sender, mut receiver) = mpsc::unbounded_channel();
        let service = Arc::new(TestLookupService::with_publish_sink(sender));

        let endpoint = Endpoint::bind(EndpointOptions {
            preset: Some(crate::preset_minimal()),
            address_lookup: Some(service),
            ..Default::default()
        })
        .await
        .unwrap();

        let record = tokio::time::timeout(Duration::from_secs(10), receiver.recv())
            .await
            .expect("publish callback did not fire")
            .expect("publish channel closed");

        // The record must parse, carry a valid signature, and be signed by
        // this endpoint's own key.
        let summary = parse_endpoint_record(record).unwrap();
        assert_eq!(summary.endpoint_id.to_bytes(), endpoint.id().to_bytes());
        assert!(
            !summary.direct_addrs.is_empty(),
            "bound endpoint publishes its direct addresses"
        );

        endpoint.close().await.unwrap();
    }

    #[tokio::test]
    async fn test_connect_by_id_resolves_through_foreign_lookup() {
        let server_secret = SecretKey::generate();
        let server = Endpoint::bind(EndpointOptions {
            preset: Some(crate::preset_minimal()),
            secret_key: Some(server_secret.to_bytes()),
            alpns: Some(vec![TEST_ALPN.to_vec()]),
            ..Default::default()
        })
        .await
        .unwrap();
        let server_id = server.id();

        // Sign a record for the server's live direct addresses with the
        // server's own key, exactly as its publish side would.
        let record =
            sign_endpoint_record(&server_secret, vec![], server.addr().direct_addresses(), 30)
                .unwrap();
        let service = Arc::new(TestLookupService::with_records(HashMap::from([(
            server_id.to_bytes(),
            vec![record],
        )])));

        let client = Endpoint::bind(EndpointOptions {
            preset: Some(crate::preset_minimal()),
            address_lookup: Some(service.clone()),
            ..Default::default()
        })
        .await
        .unwrap();

        let server_accept = {
            let server = server.clone();
            tokio::spawn(async move {
                server
                    .accept_next()
                    .await
                    .expect("incoming connection")
                    .accept()
                    .await
                    .unwrap()
                    .connect()
                    .await
                    .unwrap()
            })
        };

        // Connect with the endpoint id only: no relay URL, no direct
        // addresses. The only way to reach the server is the foreign lookup.
        let bare_addr = EndpointAddr::new(&server_id, None, Vec::new());
        let connection = tokio::time::timeout(
            Duration::from_secs(10),
            client.connect(&bare_addr, TEST_ALPN),
        )
        .await
        .expect("connect timed out")
        .unwrap();
        let server_connection = server_accept.await.unwrap();

        assert_eq!(connection.remote_id().to_bytes(), server_id.to_bytes());
        assert_eq!(
            server_connection.remote_id().to_bytes(),
            client.id().to_bytes()
        );
        assert!(
            service.resolve_calls.load(Ordering::SeqCst) >= 1,
            "connect must have consulted the foreign lookup"
        );

        client.close().await.unwrap();
        server.close().await.unwrap();
    }
}
