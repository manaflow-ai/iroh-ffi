# Platform support

This fork starts from upstream `n0-computer/iroh-ffi` commit
[`3103bf5`](https://github.com/n0-computer/iroh-ffi/commit/3103bf5295be6d50c5272ff7a426e9b539f3f587).
The previous Manaflow fork first diverged after clean upstream commit
[`66e628e`](https://github.com/n0-computer/iroh-ffi/commit/66e628e0fd2b7d526d01b81269041c97fc97f7a5).
No previous Manaflow runtime, dependency-pin, relay, NAT, cancellation, or
release commit is inherited by this branch.

## Apple artifact contract

The Swift binary artifact contains exactly four platform slices:

| Platform | Minimum | Architectures | Bundle layout |
| --- | --- | --- | --- |
| iOS device | 17.5 | arm64 | shallow static framework |
| iOS Simulator | 17.5 | arm64, x86_64 | shallow static framework |
| macOS | 14.0 | arm64, x86_64 | versioned static framework |
| Mac Catalyst | 17.5 | arm64, x86_64 | versioned static framework |

Every slice carries its module map inside `Iroh.framework`. This prevents the
header-output collision that occurs when two flat static XCFrameworks both
install `Headers/module.modulemap` into the same Xcode product directory.

The artifact verifier checks the exact slice count, binary architectures,
Mach-O platform identifiers, deployment targets, framework layout, deployment
metadata, and static linkage. Consumer checks run macOS, Mac Catalyst, and iOS
Simulator code natively on Apple Silicon and Intel CI hosts. An isolated
Simulator is created and deleted for each check.

The isolated `cmux-lite` branch runs
`.github/workflows/cmux_lite_swift.yml`. Each branch push and pull request
builds the artifact, runs the layout and consumer checks, and uploads the zip
with its SHA-256 file for fourteen days. A manual run can additionally create a
draft prerelease tagged with the source commit; publishing that draft does not
change the default SwiftPM fallback until `Package.swift` is deliberately
updated.

## Compatibility provenance

The old fork's broad first commit is not replayed. Its compatibility behavior
is split from unrelated changes and reimplemented against current upstream:

| Source | Compatibility retained |
| --- | --- |
| [`b16a921`](https://github.com/manaflow-ai/iroh-ffi/commit/b16a921f31a5c714907891f838edd56555ac92e5) | universal macOS, macOS 14.0, and the pre-OS-26 Network.framework fallback |
| [`596d8de`](https://github.com/manaflow-ai/iroh-ffi/commit/596d8dea3add687a30c515e8224a9441f48ca679), [`4439874`](https://github.com/manaflow-ai/iroh-ffi/commit/4439874c66b430b21ba58d7a930f61e59333d47f), [`27acade`](https://github.com/manaflow-ai/iroh-ffi/commit/27acade58bc4043019fbcd1ad33ad8ef349b556d) | product-scoped module maps and a fail-closed multi-XCFramework consumer check |
| [`20eb8c4`](https://github.com/manaflow-ai/iroh-ffi/commit/20eb8c4fcdd32ebeebc4160948172e2667ab6442) | hardware-architecture detection and isolated Simulator verification |
| [`5cce76f`](https://github.com/manaflow-ai/iroh-ffi/commit/5cce76f82f80f8ee1917cf599541f679457bce2d), [`81684cc`](https://github.com/manaflow-ai/iroh-ffi/commit/81684cc700f174d75f31cb2975e60036834c03ef) | deployment metadata verification and declaration |
| [`ff69fdc`](https://github.com/n0-computer/iroh-ffi/commit/ff69fdca21348d4d3851ac986d1e6663bdaf520b) | upstream Mac Catalyst support, extended here to Intel |
| [`c948937`](https://github.com/n0-computer/iroh-ffi/commit/c948937663ffe58df1a0a1bfda2def64e5bcdaa4) | Android armeabi-v7a, arm64-v8a, x86, and x86_64 binaries with 16 KB page alignment |

Upstream Rust, Kotlin/JVM, Python, JavaScript, Windows, Linux, and Android
matrices remain intact. This fork adds no new compatibility claim for those
bindings beyond upstream's existing checks.
