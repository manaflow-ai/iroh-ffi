#include <stdbool.h>

// netdev 0.44 references this OS 26 Network.framework API unconditionally.
// The weak fallback lets iroh-ffi load on older supported Apple releases. On
// OS 26 and newer, dyld coalesces it with Apple's strong definition.
__attribute__((weak, visibility("default")))
bool nw_path_is_ultra_constrained(void *path) {
    (void)path;
    return false;
}

// Rust references this strong symbol so the weak fallback's object cannot be
// omitted when a consumer links the static xcframework archive.
__attribute__((visibility("hidden")))
void iroh_ffi_apple_compat_force_link(void) {}
