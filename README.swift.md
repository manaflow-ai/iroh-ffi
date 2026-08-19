# Iroh Swift

## Build & test

With [`cargo-make`](https://crates.io/crates/cargo-make) installed:

```sh
cargo make test-swift        # build all slices + run native macOS tests
cargo make swift-xcframework # iOS + universal macOS + Catalyst artifact
```

## Xcode and iOS

- Run `cargo make swift-xcframework`.
- Add `IrohLib` as a local package dependency under `Frameworks, Libraries, and
  Embedded Content` in your project's `General` settings.
- Build. Confirm `IrohLib` is listed under `Frameworks, Libraries, and Embedded
  Content` (re-add with `+` if not).
- Add `SystemConfiguration` and `CoreWLAN` as Frameworks (iroh's netwatch needs
  them on Apple platforms).
- `import IrohLib` in Swift.

The package supports macOS 14.0 or newer on arm64 and x86_64. The artifact
also includes iOS device arm64, universal iOS Simulator, and universal Mac
Catalyst slices with a 17.5 minimum.

See [PLATFORM_SUPPORT.md](PLATFORM_SUPPORT.md) for the exact artifact and CI
contract, plus the compatibility commits retained from the previous fork.
