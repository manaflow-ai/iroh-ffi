#!/usr/bin/env bash
set -euo pipefail

# Build a fresh package that consumes the checked-out IrohLib package and the
# just-built local XCFramework. This exercises the package boundary from a
# consumer's perspective without importing the repository's test target.
# The artifact verifier and the multi-XCFramework fixture cover the individual
# slice/layout invariants; this check proves a clean package can resolve,
# compile, link, and execute a native API call through the public product.

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
IROH_XCF="${IROH_XCFRAMEWORK:-$REPO_ROOT/Iroh.xcframework}"
[ -d "$IROH_XCF" ] || {
  echo "ERROR: $IROH_XCF not found (run cargo make swift-xcframework first)" >&2
  exit 1
}

HOST_ARCH=$("$REPO_ROOT/scripts/apple_hardware_arch.sh")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iroh-swift-consumer.XXXXXX")
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# Stage only the package manifest, public Swift sources, and artifact. A
# separate directory prevents the fixture from accidentally resolving the
# repository's own Package.resolved or test target.
mkdir -p "$TMP/iroh-ffi/IrohLib" "$TMP/Sources"
cp "$REPO_ROOT/Package.swift" "$TMP/iroh-ffi/Package.swift"
cp -R "$REPO_ROOT/IrohLib/Sources" "$TMP/iroh-ffi/IrohLib/"
ditto "$IROH_XCF" "$TMP/iroh-ffi/Iroh.xcframework"
cp "$REPO_ROOT/scripts/fixtures/swift-consumer/Package.swift" "$TMP/Package.swift"
cp -R "$REPO_ROOT/scripts/fixtures/swift-consumer/Sources/"* "$TMP/Sources/"

(
  cd "$TMP"
  arch -"$HOST_ARCH" xcodebuild build \
    -scheme IrohFFIConsumerSmoke \
    -destination 'platform=macOS' \
    -derivedDataPath "$TMP/DerivedData" \
    ARCHS="$HOST_ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    -quiet
)

EXECUTABLE=$(find "$TMP/DerivedData/Build/Products/Debug" \
  -type f \
  -name IrohFFIConsumerSmoke \
  -perm -111 \
  -print -quit)
[ -n "$EXECUTABLE" ] || {
  echo "ERROR: consumer executable was not produced" >&2
  exit 1
}

if arch -"$HOST_ARCH" xcrun otool -L "$EXECUTABLE" | grep -q 'Iroh.framework'; then
  echo "ERROR: consumer unexpectedly links a dynamic Iroh.framework" >&2
  exit 1
fi

arch -"$HOST_ARCH" "$EXECUTABLE"
echo "verify-swift-package-consumer: OK"
