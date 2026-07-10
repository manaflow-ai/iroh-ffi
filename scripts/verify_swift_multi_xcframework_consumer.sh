#!/bin/bash
set -euo pipefail

# Xcode installs headers from flat static-library XCFrameworks into one shared
# Products/<configuration>/include directory. Two such artifacts that both
# contain Headers/module.modulemap therefore race to produce the same output.
# This fixture combines Iroh with a generated flat XCFramework so the package
# build fails if Iroh ever regresses from its product-scoped static framework.

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
IROH_XCF="$REPO_ROOT/Iroh.xcframework"
[ -d "$IROH_XCF" ] || {
  echo "ERROR: $IROH_XCF not found (run cargo make swift-xcframework first)" >&2
  exit 1
}

HOST_ARCH=$("$REPO_ROOT/scripts/apple_hardware_arch.sh")
case "$HOST_ARCH" in
  arm64|x86_64) ;;
  *) echo "ERROR: unsupported macOS architecture: $HOST_ARCH" >&2; exit 1 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/iroh-multi-xcframework.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/OtherFlatHeaders" "$TMP/Sources/IrohLib" "$TMP/Sources/CollisionConsumer"
printf '%s\n' 'int other_flat_value(void);' > "$TMP/OtherFlatHeaders/other_flat.h"
printf '%s\n' \
  'module OtherFlat {' \
  '    header "other_flat.h"' \
  '    export *' \
  '}' > "$TMP/OtherFlatHeaders/module.modulemap"
printf '%s\n' 'int other_flat_value(void) { return 42; }' > "$TMP/other_flat.c"

SDK=$(arch -"$HOST_ARCH" xcrun --sdk macosx --show-sdk-path)
arch -"$HOST_ARCH" xcrun clang -arch "$HOST_ARCH" -isysroot "$SDK" -mmacosx-version-min=14.0 \
  -c "$TMP/other_flat.c" -o "$TMP/other_flat.o"
arch -"$HOST_ARCH" xcrun libtool -static -o "$TMP/libother_flat.a" "$TMP/other_flat.o"
arch -"$HOST_ARCH" xcodebuild -create-xcframework \
  -library "$TMP/libother_flat.a" \
  -headers "$TMP/OtherFlatHeaders" \
  -output "$TMP/OtherFlat.xcframework" >/dev/null

ln -s "$IROH_XCF" "$TMP/Iroh.xcframework"
cp "$REPO_ROOT/IrohLib/Sources/IrohLib/"*.swift "$TMP/Sources/IrohLib/"

cat > "$TMP/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MultiXCFrameworkConsumer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CollisionConsumer", targets: ["CollisionConsumer"]),
    ],
    targets: [
        .binaryTarget(name: "Iroh", path: "Iroh.xcframework"),
        .binaryTarget(name: "OtherFlat", path: "OtherFlat.xcframework"),
        .target(
            name: "IrohLib",
            dependencies: ["Iroh"],
            path: "Sources/IrohLib",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN"),
            ]),
        .executableTarget(
            name: "CollisionConsumer",
            dependencies: ["IrohLib", "OtherFlat"],
            path: "Sources/CollisionConsumer"),
    ])
SWIFT

cat > "$TMP/Sources/CollisionConsumer/main.swift" <<'SWIFT'
import IrohLib
import OtherFlat

precondition(SecretKey.generate().toBytes().count == 32)
precondition(other_flat_value() == 42)
SWIFT

(
  cd "$TMP"
  arch -"$HOST_ARCH" xcodebuild build \
    -scheme MultiXCFrameworkConsumer \
    -destination 'platform=macOS' \
    -derivedDataPath "$TMP/DerivedData" \
    ARCHS="$HOST_ARCH" ONLY_ACTIVE_ARCH=YES \
    -quiet
)

EXECUTABLE="$TMP/DerivedData/Build/Products/Debug/CollisionConsumer"
[ -x "$EXECUTABLE" ] || {
  echo "ERROR: fixture executable not found at $EXECUTABLE" >&2
  exit 1
}

MAC_FRAMEWORK=$(find "$IROH_XCF" -type d -path '*/macos-*/Iroh.framework' -print -quit)
[ -n "$MAC_FRAMEWORK" ] || {
  echo "ERROR: Iroh must ship as a product-scoped static framework" >&2
  exit 1
}
if [ -f "$MAC_FRAMEWORK/Versions/A/Iroh" ]; then
  IROH_BINARY="$MAC_FRAMEWORK/Versions/A/Iroh"
else
  IROH_BINARY="$MAC_FRAMEWORK/Iroh"
fi
file -b "$IROH_BINARY" | grep -q 'current ar archive' || {
  echo "ERROR: Iroh.framework/Iroh is not a static archive" >&2
  exit 1
}

if arch -"$HOST_ARCH" xcrun otool -L "$EXECUTABLE" | grep -q 'Iroh.framework'; then
  echo "ERROR: fixture unexpectedly has a dynamic Iroh.framework dependency" >&2
  exit 1
fi
"$EXECUTABLE"

echo "verify-swift-multi-xcframework-consumer: OK"
