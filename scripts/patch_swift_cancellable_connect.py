#!/usr/bin/env python3
"""Route Endpoint.connect through the maintained Swift cancellation bridge."""

from __future__ import annotations

import pathlib
import sys


SIGNATURE = "open func connect(addr: EndpointAddr, alpn: Data)async throws  -> Connection  {"
BRIDGE_CALL = "irohConnectWithTaskCancellation(attempt: attempt)"
CONNECT_ATTEMPT_START = "public protocol ConnectAttemptProtocol"
CONNECT_ATTEMPT_END = "/**\n * A client-side handshake in progress."
BEGIN_CONNECT_DOC = """    /**
     * Create a cancellable outgoing connection attempt without starting any
     * address lookup or network I/O.
     */"""


def normalize_generated_additions(source: str) -> str:
    """Keep the post-processed additions stable across repeated generation."""
    start = source.index(CONNECT_ATTEMPT_START)
    end = source.index(CONNECT_ATTEMPT_END, start)
    generated_attempt = "\n".join(
        line.rstrip() for line in source[start:end].split("\n")
    )
    source = source[:start] + generated_attempt + source[end:]

    source = source.replace(
        "    func addr()  -> EndpointAddr\n    \n" + BEGIN_CONNECT_DOC,
        "    func addr()  -> EndpointAddr\n\n" + BEGIN_CONNECT_DOC,
        1,
    )
    source = source.replace(
        "})\n}\n    \n" + BEGIN_CONNECT_DOC,
        "})\n}\n\n" + BEGIN_CONNECT_DOC,
        1,
    )
    return source.rstrip() + "\n"


def patch(path: pathlib.Path) -> None:
    source = path.read_text()
    if source.count(SIGNATURE) != 1:
        sys.exit(f"expected exactly one Endpoint.connect in {path}")

    start = source.index(SIGNATURE)
    end = source.index("\n}\n", start) + len("\n}\n")
    original = source[start:end]
    if BRIDGE_CALL in original:
        print(f"Swift cancellation bridge already present in {path}")
    else:
        if "uniffi_iroh_ffi_fn_method_endpoint_connect" not in original:
            sys.exit(f"Endpoint.connect in {path} no longer matches UniFFI output")

        replacement = f"""{SIGNATURE}
    let attempt = try beginConnect(addr: addr, alpn: alpn)
    return try await {BRIDGE_CALL}
}}
"""
        source = source[:start] + replacement + source[end:]
        print(f"Patched Swift Task cancellation into {path}")

    path.write_text(normalize_generated_additions(source))


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {pathlib.Path(sys.argv[0]).name} <IrohLib.swift>")
    patch(pathlib.Path(sys.argv[1]))


if __name__ == "__main__":
    main()
