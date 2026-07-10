//! Keeps the weak Apple back-deployment definition in the final static link.

unsafe extern "C" {
    fn iroh_ffi_apple_compat_force_link();
}

/// `src/apple_compat.c` defines an OS 26 Network.framework API weakly. This
/// strong reference forces that object out of the static archive whenever an
/// endpoint is linked, while allowing Apple's strong definition to win on OS
/// 26 and newer.
pub(crate) fn ensure_linked() {
    unsafe { iroh_ffi_apple_compat_force_link() }
}
