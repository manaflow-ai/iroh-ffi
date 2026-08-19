#!/usr/bin/env bash
set -euo pipefail

# Builds one XCFramework for four Apple platforms from seven Rust targets:
# iOS device (arm64), iOS Simulator (arm64 + x86_64), macOS (arm64 +
# x86_64), and Mac Catalyst (arm64 + x86_64). Prefer
# `cargo make swift-xcframework`.
#
# Each slice ships a static `Iroh.framework`. Keeping Headers/ and
# Modules/module.modulemap inside the named framework prevents Xcode from
# installing Iroh's module map into a shared Products/include directory,
# where it can collide with another flat static-library XCFramework.
# iOS and Simulator use Apple's shallow framework layout. macOS and Mac
# Catalyst use the versioned layout required by current Xcode releases.
#
# Frameworks are generated under target/ from scratch on every build. No
# bundle skeleton is checked in. `xcodebuild -create-xcframework` derives
# the outer platform and architecture metadata from the staged binaries.

# Reproducible-build path normalization. Without this, every `.a` binary
# embeds absolute paths from `file!()` macros (in deps, in iroh, and in
# std/core/alloc panic sites). The four remaps below cover every absolute
# path rustc emits: cargo registry, cargo git deps, the source checkout,
# and the rustup-managed std sysroot.
CARGO_PFX="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_PFX="${RUSTUP_HOME:-$HOME/.rustup}"
REPO_PFX="$(pwd)"
export RUSTFLAGS="${RUSTFLAGS:-} \
  --remap-path-prefix=${CARGO_PFX}/registry=/cargo/registry \
  --remap-path-prefix=${CARGO_PFX}/git=/cargo/git \
  --remap-path-prefix=${RUSTUP_PFX}=/rustup \
  --remap-path-prefix=${REPO_PFX}=/build"
# --remap-path-prefix is Rust-only. Several deps (notably `ring`) compile
# bundled C sources via build.rs + the `cc` crate; -ffile-prefix-map is
# clang/gcc's analogue.
export CFLAGS="${CFLAGS:-} \
  -ffile-prefix-map=${CARGO_PFX}/registry=/cargo/registry \
  -ffile-prefix-map=${CARGO_PFX}/git=/cargo/git \
  -ffile-prefix-map=${REPO_PFX}=/build"

# Apple deployment-target floors. netdev 0.45 references the OS 26-only
# `nw_path_is_ultra_constrained` API. `src/apple_compat.c` back-deploys that
# symbol; these explicit floors keep every Mach-O slice aligned with the
# oldest OS versions declared by Package.swift.
export IPHONEOS_DEPLOYMENT_TARGET="17.5"
export MACOSX_DEPLOYMENT_TARGET="14.0"

UDL_NAME="iroh_ffi"
FRAMEWORK_NAME="Iroh"
SWIFT_INTERFACE="IrohLib"
INCLUDE_DIR="include/apple"

# Resolve the cargo target dir (honours CARGO_TARGET_DIR / .cargo config).
TARGET_DIR=$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')

# Default lib for the bindgen-metadata step (uniffi-bindgen reads symbols
# from a debug dylib to discover the FFI surface).
cargo build --lib

echo "Building aarch64-apple-ios"
cargo build --release --lib --target aarch64-apple-ios
echo "Building aarch64-apple-ios-sim"
cargo build --release --lib --target aarch64-apple-ios-sim
echo "Building x86_64-apple-ios"
cargo build --release --lib --target x86_64-apple-ios
echo "Building aarch64-apple-darwin"
cargo build --release --lib --target aarch64-apple-darwin
echo "Building x86_64-apple-darwin"
cargo build --release --lib --target x86_64-apple-darwin
echo "Building aarch64-apple-ios-macabi"
cargo build --release --lib --target aarch64-apple-ios-macabi
echo "Building x86_64-apple-ios-macabi"
cargo build --release --lib --target x86_64-apple-ios-macabi

# Wipe outputs so we don't blend stale slices into the new xcframework.
rm -rf "$FRAMEWORK_NAME.xcframework"
rm -rf "$INCLUDE_DIR"
mkdir -p "$INCLUDE_DIR"

# UniFfi bindgen: produces ${UDL_NAME}FFI.h (C header for the FFI surface),
# ${UDL_NAME}.swift (the Swift binding code), and ${UDL_NAME}FFI.modulemap
# (a module declaration we ignore — we ship our own module.modulemap below
# that names the module `Iroh` to match what the Swift consumer imports).
cargo run --bin uniffi-bindgen generate --language swift --out-dir ./$INCLUDE_DIR --library "$TARGET_DIR/debug/lib${UDL_NAME}.dylib" --config uniffi.toml

# Stage metadata shared by all four platform frameworks. Export.h keeps the
# UniFFI-generated header name out of the Swift-visible module surface.
FRAMEWORK_STAGE="$TARGET_DIR/apple-frameworks"
rm -rf "$FRAMEWORK_STAGE"
mkdir -p "$FRAMEWORK_STAGE/shared/Headers" "$FRAMEWORK_STAGE/shared/Modules"
cp "$INCLUDE_DIR/${UDL_NAME}FFI.h" \
  "$FRAMEWORK_STAGE/shared/Headers/${UDL_NAME}FFI.h"
cat > "$FRAMEWORK_STAGE/shared/Headers/Export.h" <<EOF
#include "${UDL_NAME}FFI.h"
EOF
cat > "$FRAMEWORK_STAGE/shared/Modules/module.modulemap" <<EOF
framework module $FRAMEWORK_NAME {
    umbrella header "Export.h"
    export *
    module * { export * }
}
EOF
cat > "$FRAMEWORK_STAGE/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>computer.iroh.$FRAMEWORK_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

# Fat lib for the iOS simulator slice. xcframework can carry one .a per
# slice, so the arm64-sim and x86_64-sim variants need to be merged here.
# Name it lib${UDL_NAME}.a (not universal.a) so xcodebuild uses the same
# filename in every slice — consumers and the layout check both rely on it.
SIM_FAT="$TARGET_DIR/apple-sim-fat/lib${UDL_NAME}.a"
mkdir -p "$(dirname "$SIM_FAT")"
rm -f "$SIM_FAT"
lipo -create \
    "$TARGET_DIR/aarch64-apple-ios-sim/release/lib${UDL_NAME}.a" \
    "$TARGET_DIR/x86_64-apple-ios/release/lib${UDL_NAME}.a" \
    -output "$SIM_FAT"

# Universal macOS and Catalyst binaries. Both supported Mac environments carry
# native arm64 and x86_64 code so consumers never need architecture exclusions.
MACOS_FAT="$TARGET_DIR/apple-macos-fat/lib${UDL_NAME}.a"
mkdir -p "$(dirname "$MACOS_FAT")"
rm -f "$MACOS_FAT"
lipo -create \
    "$TARGET_DIR/aarch64-apple-darwin/release/lib${UDL_NAME}.a" \
    "$TARGET_DIR/x86_64-apple-darwin/release/lib${UDL_NAME}.a" \
    -output "$MACOS_FAT"

CATALYST_FAT="$TARGET_DIR/apple-catalyst-fat/lib${UDL_NAME}.a"
mkdir -p "$(dirname "$CATALYST_FAT")"
rm -f "$CATALYST_FAT"
lipo -create \
    "$TARGET_DIR/aarch64-apple-ios-macabi/release/lib${UDL_NAME}.a" \
    "$TARGET_DIR/x86_64-apple-ios-macabi/release/lib${UDL_NAME}.a" \
    -output "$CATALYST_FAT"

# iOS and Simulator frameworks use the shallow Apple layout.
stage_shallow_framework() {
  framework=$1
  binary=$2
  mkdir -p "$framework/Headers" "$framework/Modules"
  cp "$FRAMEWORK_STAGE/Info.plist" "$framework/Info.plist"
  plutil -insert MinimumOSVersion \
    -string "$IPHONEOS_DEPLOYMENT_TARGET" \
    "$framework/Info.plist"
  cp "$FRAMEWORK_STAGE/shared/Headers/"* "$framework/Headers/"
  cp "$FRAMEWORK_STAGE/shared/Modules/module.modulemap" \
    "$framework/Modules/module.modulemap"
  cp "$binary" "$framework/$FRAMEWORK_NAME"
}

IOS_FRAMEWORK="$FRAMEWORK_STAGE/ios/$FRAMEWORK_NAME.framework"
IOS_SIM_FRAMEWORK="$FRAMEWORK_STAGE/ios-simulator/$FRAMEWORK_NAME.framework"
stage_shallow_framework \
  "$IOS_FRAMEWORK" \
  "$TARGET_DIR/aarch64-apple-ios/release/lib${UDL_NAME}.a"
stage_shallow_framework "$IOS_SIM_FRAMEWORK" "$SIM_FAT"

# macOS and Mac Catalyst use versioned frameworks. The public entries resolve
# through Versions/Current, matching Xcode-produced frameworks on Mac hosts.
stage_deep_framework() {
  framework=$1
  binary=$2
  minimum=$3
  version="$framework/Versions/A"
  mkdir -p "$version/Headers" "$version/Modules" "$version/Resources"
  cp "$FRAMEWORK_STAGE/Info.plist" "$version/Resources/Info.plist"
  plutil -insert LSMinimumSystemVersion \
    -string "$minimum" \
    "$version/Resources/Info.plist"
  cp "$FRAMEWORK_STAGE/shared/Headers/"* "$version/Headers/"
  cp "$FRAMEWORK_STAGE/shared/Modules/module.modulemap" \
    "$version/Modules/module.modulemap"
  cp "$binary" "$version/$FRAMEWORK_NAME"
  ln -s A "$framework/Versions/Current"
  ln -s "Versions/Current/$FRAMEWORK_NAME" "$framework/$FRAMEWORK_NAME"
  ln -s Versions/Current/Headers "$framework/Headers"
  ln -s Versions/Current/Modules "$framework/Modules"
  ln -s Versions/Current/Resources "$framework/Resources"
}

MACOS_FRAMEWORK="$FRAMEWORK_STAGE/macos/$FRAMEWORK_NAME.framework"
CATALYST_FRAMEWORK="$FRAMEWORK_STAGE/maccatalyst/$FRAMEWORK_NAME.framework"
stage_deep_framework "$MACOS_FRAMEWORK" "$MACOS_FAT" "$MACOSX_DEPLOYMENT_TARGET"
stage_deep_framework "$CATALYST_FRAMEWORK" "$CATALYST_FAT" "$MACOSX_DEPLOYMENT_TARGET"

# Xcode-produced Catalyst framework plists carry this sentinel. The actual
# Catalyst deployment floor lives in each Mach-O object's LC_BUILD_VERSION.
plutil -insert MinimumOSVersion \
  -string "100.0" \
  "$CATALYST_FRAMEWORK/Versions/A/Resources/Info.plist"

# The contained binaries remain static archives. The framework bundles scope
# module metadata and add no dynamic runtime dependency.
xcodebuild -create-xcframework \
    -framework "$IOS_FRAMEWORK" \
    -framework "$IOS_SIM_FRAMEWORK" \
    -framework "$MACOS_FRAMEWORK" \
    -framework "$CATALYST_FRAMEWORK" \
    -output "$FRAMEWORK_NAME.xcframework"

# Swift interface for the IrohLib SwiftPM target. uniffi emits references
# to the C module under its own name (${UDL_NAME}FFI); rewrite to the
# module name the consumer imports (`Iroh`).
sed "s/${UDL_NAME}FFI/$FRAMEWORK_NAME/g" "$INCLUDE_DIR/$UDL_NAME.swift" > "$INCLUDE_DIR/$SWIFT_INTERFACE.swift"
rm -f "$SWIFT_INTERFACE/Sources/$SWIFT_INTERFACE/$SWIFT_INTERFACE.swift"
cp "$INCLUDE_DIR/$SWIFT_INTERFACE.swift" \
    "$SWIFT_INTERFACE/Sources/$SWIFT_INTERFACE/$SWIFT_INTERFACE.swift"
