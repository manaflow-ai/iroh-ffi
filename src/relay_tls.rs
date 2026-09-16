//! Platform trust policy for every FFI endpoint construction path.

pub(crate) fn configure(builder: iroh::endpoint::Builder) -> iroh::endpoint::Builder {
    // Use Apple's complete trust evaluation, including admin roots and trust
    // restrictions. Do not export keychain roots or fall back after a denial.
    #[cfg(target_os = "macos")]
    let builder = builder.ca_tls_config(iroh::tls::CaTlsConfig::system());
    // iOS and other platforms retain iroh's existing embedded WebPKI policy.
    builder
}
