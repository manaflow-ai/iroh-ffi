#!/usr/bin/env python3
"""Route Endpoint.connect through the maintained Swift cancellation bridge."""

from __future__ import annotations

import pathlib
import sys


SIGNATURE = "open func connect(addr: EndpointAddr, alpn: Data)async throws  -> Connection  {"
BRIDGE_CALL = "irohConnectWithTaskCancellation(attempt: attempt)"


def patch(path: pathlib.Path) -> None:
    source = path.read_text()
    if source.count(SIGNATURE) != 1:
        sys.exit(f"expected exactly one Endpoint.connect in {path}")

    start = source.index(SIGNATURE)
    end = source.index("\n}\n", start) + len("\n}\n")
    original = source[start:end]
    if BRIDGE_CALL in original:
        print(f"Swift cancellation bridge already present in {path}")
        return
    if "uniffi_iroh_ffi_fn_method_endpoint_connect" not in original:
        sys.exit(f"Endpoint.connect in {path} no longer matches UniFFI output")

    replacement = f"""{SIGNATURE}
    let attempt = try beginConnect(addr: addr, alpn: alpn)
    return try await {BRIDGE_CALL}
}}
"""
    path.write_text(source[:start] + replacement + source[end:])
    print(f"Patched Swift Task cancellation into {path}")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {pathlib.Path(sys.argv[0]).name} <IrohLib.swift>")
    patch(pathlib.Path(sys.argv[1]))


if __name__ == "__main__":
    main()
