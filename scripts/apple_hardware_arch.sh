#!/bin/sh
set -eu

[ "$(uname -s)" = "Darwin" ] || {
  echo "ERROR: Apple hardware architecture detection requires macOS" >&2
  exit 1
}

# `uname -m` reports the process architecture under Rosetta. Some CI setup
# actions install x86_64 helper binaries even on Apple Silicon, so shell tasks
# spawned by those helpers would otherwise test the Intel slice twice and
# leave the arm64 slice unexercised. This sysctl reports the physical hardware.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
  printf '%s\n' arm64
  exit 0
fi

case "$(uname -m)" in
  x86_64) printf '%s\n' x86_64 ;;
  *)
    echo "ERROR: unsupported Apple hardware architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
