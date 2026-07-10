import Darwin
import XCTest
@testable import IrohLib

private let ALPN = Data("iroh-ffi/test/0".utf8)

private enum TestConnectError: Error {
    case cancelled
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class BlockingConnectAttempt: ConnectAttemptProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let started: XCTestExpectation?
    private var continuation: CheckedContinuation<Connection, Error>?
    private var isCancelled = false
    private var connectCallCount = 0
    private var cancelCallCount = 0

    init(started: XCTestExpectation? = nil) {
        self.started = started
    }

    func connect() async throws -> Connection {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            connectCallCount += 1
            let cancelled = isCancelled
            if !cancelled {
                self.continuation = continuation
            }
            lock.unlock()

            started?.fulfill()
            if cancelled {
                continuation.resume(throwing: TestConnectError.cancelled)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelCallCount += 1
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(throwing: TestConnectError.cancelled)
    }

    func state() -> (connectCallCount: Int, cancelCallCount: Int, hasContinuation: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (connectCallCount, cancelCallCount, continuation != nil)
    }
}

private final class NoopAddrChangeCallback: AddrChangeCallback, @unchecked Sendable {
    func onChange(addr _: EndpointAddr) async throws {}
}

private final class NoopHomeRelayCallback: HomeRelayCallback, @unchecked Sendable {
    func onChange(relayUrls _: [String]) async throws {}
}

private final class NoopNetworkChangeCallback: NetworkChangeCallback, @unchecked Sendable {
    func onChange() async throws {}
}

private final class NoopPathChangeCallback: PathChangeCallback, @unchecked Sendable {
    func onChange(paths _: [PathSnapshot]) async throws {}
}

private final class NoopPathEventCallback: PathEventCallback, @unchecked Sendable {
    func onEvent(event _: PathEvent) async throws {}
}

final class CancellableConnectTests: XCTestCase {
    func testAlreadyCancelledTaskCancelsAttemptBeforeConnectStarts() async throws {
        let ready = expectation(description: "task reached pre-connect gate")
        let gate = AsyncGate()
        let attempt = BlockingConnectAttempt()
        let task = Task {
            ready.fulfill()
            await gate.wait()
            return try await irohConnectWithTaskCancellation(attempt: attempt)
        }

        await fulfillment(of: [ready], timeout: 1)
        task.cancel()
        gate.open()

        do {
            _ = try await task.value
            XCTFail("expected task cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let state = attempt.state()
        XCTAssertEqual(state.connectCallCount, 0)
        XCTAssertEqual(state.cancelCallCount, 1)
        XCTAssertFalse(state.hasContinuation)
    }

    func testTaskCancellationCancelsAttemptAndReleasesOperation() async throws {
        let started = expectation(description: "connect operation started")
        let attempt = BlockingConnectAttempt(started: started)
        let task = Task {
            try await irohConnectWithTaskCancellation(attempt: attempt)
        }

        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected task cancellation")
        } catch is CancellationError {
            // Expected: the bridge maps the Rust-side cancellation error back
            // to Swift's structured-concurrency cancellation.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let state = attempt.state()
        XCTAssertEqual(state.connectCallCount, 1)
        XCTAssertEqual(state.cancelCallCount, 1)
        XCTAssertFalse(state.hasContinuation)
    }

    func testRustAttemptCanBeCancelledBeforeLookup() async throws {
        let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal()))
        let remoteID = SecretKey.generate().`public`()
        let remote = EndpointAddr(id: remoteID, relayUrl: nil, addresses: [])
        let attempt = try endpoint.beginConnect(addr: remote, alpn: ALPN)

        attempt.cancel()
        attempt.cancel()

        do {
            _ = try await attempt.connect()
            XCTFail("expected cancelled Rust connection attempt")
        } catch let error as IrohError {
            XCTAssertTrue(error.message().contains("outgoing connection cancelled"))
        } catch {
            XCTFail("expected IrohError, got \(error)")
        }

        try await endpoint.close()
    }
}

final class AppleBackDeploymentTests: XCTestCase {
    func testNetworkPathShimIsLinkedAndForwardsWhenAvailable() throws {
        let symbolName = "nw_path_is_ultra_constrained"
        let process = try XCTUnwrap(dlopen(nil, RTLD_LAZY))
        defer { dlclose(process) }
        let shim = try XCTUnwrap(
            dlsym(process, symbolName),
            "the compatibility definition must survive static linking"
        )

        let networkFramework = try XCTUnwrap(
            dlopen(
                "/System/Library/Frameworks/Network.framework/Network",
                RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST
            )
        )
        defer { dlclose(networkFramework) }
        let systemImplementation = dlsym(networkFramework, symbolName)

        var symbolInfo = Dl_info()
        XCTAssertNotEqual(dladdr(shim, &symbolInfo), 0)
        let definingImage = String(cString: try XCTUnwrap(symbolInfo.dli_fname))

        if #available(macOS 26.0, iOS 26.0, *) {
            let systemImplementation = try XCTUnwrap(
                systemImplementation,
                "OS 26 and newer must provide the Network.framework implementation"
            )
            XCTAssertEqual(
                UInt(bitPattern: shim),
                UInt(bitPattern: systemImplementation),
                "Network.framework's strong definition must replace the weak fallback"
            )
            XCTAssertTrue(definingImage.contains("Network.framework"), definingImage)
        } else {
            XCTAssertNil(
                systemImplementation,
                "older systems must use the compatibility definition's false fallback"
            )
            XCTAssertFalse(definingImage.contains("Network.framework"), definingImage)
        }
    }
}

final class KeyTests: XCTestCase {
    func testEndpointId() throws {
        let keyStr = "523c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea"
        let fmtStr = "523c7996ba"
        let bytes = Data([
            0x52, 0x3c, 0x79, 0x96, 0xba, 0xd7, 0x74, 0x24,
            0xe9, 0x67, 0x86, 0xcf, 0x7a, 0x72, 0x05, 0x11,
            0x53, 0x37, 0xa5, 0xb4, 0x56, 0x5c, 0xd2, 0x55,
            0x06, 0xa0, 0xf2, 0x97, 0xb1, 0x91, 0xa5, 0xea,
        ])

        let id = try EndpointId.fromString(s: keyStr)
        XCTAssertEqual(id.description, keyStr)
        XCTAssertEqual(id.toBytes(), bytes)
        XCTAssertEqual(id.fmtShort(), fmtStr)

        let id2 = try EndpointId.fromBytes(bytes: bytes)
        XCTAssertEqual(id, id2)
    }

    func testEndpointIdRejectsBadBytes() {
        XCTAssertThrowsError(try EndpointId.fromBytes(bytes: Data([1, 2, 3])))
    }

    func testSecretKeyRoundtrip() throws {
        let secret = SecretKey.generate()
        let raw = secret.toBytes()
        XCTAssertEqual(raw.count, 32)
        let secret2 = try SecretKey.fromBytes(bytes: raw)
        XCTAssertEqual(secret.toBytes(), secret2.toBytes())
        XCTAssertEqual(secret.`public`().toBytes(), secret2.`public`().toBytes())
    }

    func testSignVerifyRoundtrip() throws {
        let secret = SecretKey.generate()
        let pub = secret.`public`()
        let msg = Data("hello iroh".utf8)
        let sig = secret.sign(message: msg)

        let raw = sig.toBytes()
        XCTAssertEqual(raw.count, 64)
        let sig2 = try Signature.fromBytes(bytes: raw)
        XCTAssertEqual(sig2.toBytes(), raw)

        try pub.verify(message: msg, signature: sig)
        try pub.verify(message: msg, signature: sig2)
    }

    func testVerifyRejectsTampered() {
        let secret = SecretKey.generate()
        let pub = secret.`public`()
        let sig = secret.sign(message: Data("original".utf8))
        XCTAssertThrowsError(try pub.verify(message: Data("tampered".utf8), signature: sig))
    }
}

final class RelayTests: XCTestCase {
    func testRelayMapCrud() throws {
        let m = RelayMap.empty()
        XCTAssertTrue(m.isEmpty())

        let cfg = RelayConfig(
            url: "https://relay.example.org/",
            quicPort: 7842,
            authToken: "hunter2"
        )
        try m.insert(config: cfg)
        XCTAssertEqual(m.len(), 1)
        XCTAssertTrue(try m.contains(url: "https://relay.example.org/"))

        let got = try m.get(url: "https://relay.example.org/")
        XCTAssertEqual(got?.url, "https://relay.example.org/")
        XCTAssertEqual(got?.quicPort, 7842)
        XCTAssertEqual(got?.authToken, "hunter2")

        XCTAssertTrue(try m.remove(url: "https://relay.example.org/"))
        XCTAssertTrue(m.isEmpty())
    }

    func testRelayModeConstructors() throws {
        _ = RelayMode.disabled()
        _ = RelayMode.defaultMode()
        _ = RelayMode.staging()
        let m = try RelayMap.fromUrls(urls: ["https://r1.example.org/"])
        let custom = RelayMode.custom(map: m)
        XCTAssertEqual(custom.relayMap().len(), 1)
        _ = try RelayMode.customFromUrls(urls: ["https://r2.example.org/"])
    }
}

/// A user-implemented Preset: minimal baseline + a custom ALPN.
final class CustomPreset: Preset {
    func apply(builder: EndpointBuilder) {
        builder.applyMinimal()
        builder.alpns(alpns: [Data("custom/preset/1".utf8)])
    }
}

final class EndpointTests: XCTestCase {
    func testCustomPreset() async throws {
        let ep = try await Endpoint.bind(options: EndpointOptions(preset: CustomPreset()))
        XCTAssertFalse(ep.boundSockets().isEmpty)
        try await ep.close()
    }

    func testBuilderBind() async throws {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        let ep = try await builder.bind()
        XCTAssertFalse(ep.boundSockets().isEmpty)
        try await ep.close()
    }

    func testBuilderBindConsumes() async throws {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        let ep = try await builder.bind()
        try await ep.close()
        do {
            _ = try await builder.bind()
            XCTFail("expected error on second bind()")
        } catch {
            XCTAssertTrue("\(error)".contains("already consumed"), "got: \(error)")
        }
    }

    func testBindLifecycle() async throws {
        let ep = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal()))
        let id = ep.id()
        XCTAssertFalse(id.description.isEmpty)
        XCTAssertEqual(ep.addr().id(), id)
        XCTAssertFalse(ep.boundSockets().isEmpty)
        XCTAssertEqual(ep.secretKey().`public`().toBytes(), id.toBytes())
        try await ep.close()
        XCTAssertTrue(ep.isClosed())
    }

    func testClosedResolvesAfterExplicitClose() async throws {
        let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal()))
        let closed = expectation(description: "endpoint closed signal")
        let waiter = Task {
            await endpoint.closed()
            closed.fulfill()
        }

        try await endpoint.close()
        await fulfillment(of: [closed], timeout: 1)
        await waiter.value
    }

    func testEndpointTicketRoundtrip() async throws {
        let ep = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal()))
        let addr = ep.addr()
        let ticket = try EndpointTicket.fromAddr(addr: addr)
        let s = ticket.description
        XCTAssertTrue(s.hasPrefix("endpoint"))
        let parsed = try EndpointTicket.fromString(str: s)
        XCTAssertEqual(parsed.endpointAddr().id(), addr.id())
        try await ep.close()
    }

    func testEndpointTicketRejectsGarbage() throws {
        XCTAssertThrowsError(try EndpointTicket.fromString(str: "not-a-ticket"))
    }

    func testConnectEchoRoundtrip() async throws {
        let server = try await Endpoint.bind(
            options: EndpointOptions(
                preset: presetN0(),
                alpns: [ALPN],
                relayMode: RelayMode.disabled()
            )
        )
        let serverAddr = server.addr()
        let serverId = server.id()

        let serverTask = Task {
            let incoming = await server.acceptNext()!
            let conn = try await incoming.accept().connect()
            XCTAssertEqual(conn.alpn(), ALPN)
            let bi = try await conn.acceptBi()
            let msg = try await bi.recv().readToEnd(sizeLimit: 64)
            try await bi.send().writeAll(buf: msg)
            try await bi.send().finish()
            let dg = try await conn.readDatagram()
            try conn.sendDatagram(data: dg)
            _ = await conn.closed()
        }

        let client = try await Endpoint.bind(
            options: EndpointOptions(preset: presetN0(), relayMode: RelayMode.disabled())
        )
        let conn = try await client.connect(addr: serverAddr, alpn: ALPN)
        XCTAssertEqual(conn.remoteId(), serverId)
        XCTAssertFalse(conn.paths().isEmpty)

        let bi = try await conn.openBi()
        try await bi.send().writeAll(buf: Data("hello iroh".utf8))
        try await bi.send().finish()
        let echoed = try await bi.recv().readToEnd(sizeLimit: 64)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "hello iroh")

        try conn.sendDatagram(data: Data("ping".utf8))
        let pong = try await conn.readDatagram()
        XCTAssertEqual(String(decoding: pong, as: UTF8.self), "ping")

        let stats = conn.stats()
        XCTAssertGreaterThan(stats.udpTxDatagrams, 0)

        try conn.close(errorCode: 0, reason: Data("bye".utf8))
        _ = try await serverTask.value
        try await client.close()
        try await server.close()
    }

    func testRelayTokenReplacementPreservesEndpointAndConnection() async throws {
        let server = try await Endpoint.bind(
            options: EndpointOptions(
                preset: presetN0(),
                alpns: [ALPN],
                relayMode: RelayMode.disabled()
            )
        )
        let relayURL = "https://127.0.0.1:9/"
        let relayMap = RelayMap.empty()
        try relayMap.insert(
            config: RelayConfig(url: relayURL, quicPort: nil, authToken: "token-a")
        )
        let client = try await Endpoint.bind(
            options: EndpointOptions(
                preset: presetN0(),
                relayMode: RelayMode.custom(map: relayMap)
            )
        )

        let serverTask = Task {
            let nextIncoming = await server.acceptNext()
            let incoming = try XCTUnwrap(nextIncoming)
            let connection = try await incoming.accept().connect()
            let stream = try await connection.acceptBi()
            let message = try await stream.recv().readToEnd(sizeLimit: 64)
            try await stream.send().writeAll(buf: message)
            try await stream.send().finish()
            _ = await connection.closed()
        }

        let connection = try await client.connect(addr: server.addr(), alpn: ALPN)
        let endpointID = client.id()
        let connectionID = connection.stableId()

        try await client.insertRelay(
            config: RelayConfig(url: relayURL, quicPort: nil, authToken: "token-b")
        )

        XCTAssertEqual(client.id(), endpointID)
        XCTAssertEqual(connection.stableId(), connectionID)
        XCTAssertNil(connection.closeReason())

        let stream = try await connection.openBi()
        try await stream.send().writeAll(buf: Data("after relay refresh".utf8))
        try await stream.send().finish()
        let echoed = try await stream.recv().readToEnd(sizeLimit: 64)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "after relay refresh")

        try connection.close(errorCode: 0, reason: Data("test complete".utf8))
        _ = try await serverTask.value
        try await client.close()
        try await server.close()
    }

    func testUniStream() async throws {
        let server = try await Endpoint.bind(
            options: EndpointOptions(
                preset: presetN0(),
                alpns: [ALPN],
                relayMode: RelayMode.disabled()
            )
        )
        let serverAddr = server.addr()

        let serverTask = Task {
            let incoming = await server.acceptNext()!
            let conn = try await incoming.accept().connect()
            let recv = try await conn.acceptUni()
            let msg = try await recv.readToEnd(sizeLimit: 32)
            XCTAssertEqual(String(decoding: msg, as: UTF8.self), "unidirectional")
        }

        let client = try await Endpoint.bind(
            options: EndpointOptions(preset: presetN0(), relayMode: RelayMode.disabled())
        )
        let conn = try await client.connect(addr: serverAddr, alpn: ALPN)
        let send = try await conn.openUni()
        try await send.writeAll(buf: Data("unidirectional".utf8))
        try await send.finish()

        _ = try await serverTask.value
        try await client.close()
        try await server.close()
    }

    func testWatcherRegistrationDoesNotRequireCallingThreadTokioRuntime() async throws {
        let server = try await Endpoint.bind(
            options: EndpointOptions(
                preset: presetN0(),
                alpns: [ALPN],
                relayMode: RelayMode.disabled()
            )
        )
        let client = try await Endpoint.bind(
            options: EndpointOptions(preset: presetN0(), relayMode: RelayMode.disabled())
        )

        let serverTask = Task {
            let nextIncoming = await server.acceptNext()
            let incoming = try XCTUnwrap(nextIncoming)
            return try await incoming.accept().connect()
        }
        let clientConnection = try await client.connect(addr: server.addr(), alpn: ALPN)
        let serverConnection = try await serverTask.value

        // These generated methods are synchronous FFI calls, so the calling
        // Swift thread has no entered Tokio runtime.
        let handles = [
            client.watchAddr(callback: NoopAddrChangeCallback()),
            client.watchHomeRelay(callback: NoopHomeRelayCallback()),
            client.watchNetworkChange(callback: NoopNetworkChangeCallback()),
            clientConnection.watchPaths(callback: NoopPathChangeCallback()),
            clientConnection.watchPathEvents(callback: NoopPathEventCallback()),
        ]

        for handle in handles {
            await handle.stop()
        }
        try clientConnection.close(errorCode: 0, reason: Data("test complete".utf8))
        _ = await serverConnection.closed()
        try await client.close()
        try await server.close()
    }
}

// Well-formed (but fake) API secret — the remote does not exist, but the
// client connects lazily so construction still succeeds.
private let FAKE_API_SECRET =
    "servicesaaqaobyha4dqobyha4dqobyha4dqobyha4dqobyha4dqobyha4dqob"
    + "75c4sdqwvay5nwj63yzvqc7iozsh66x53lcpcy5vyc5ledl2pwdaaa"

final class ServicesTests: XCTestCase {
    private func endpoint() async throws -> Endpoint {
        try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal()))
    }

    func testBootsWithFakeSecret() async throws {
        let ep = try await endpoint()
        _ = try await ServicesClient.create(
            endpoint: ep,
            options: ServicesOptions(apiSecret: FAKE_API_SECRET)
        )
        try await ep.close()
    }

    func testRejectsNoCredentials() async throws {
        let ep = try await endpoint()
        do {
            _ = try await ServicesClient.create(endpoint: ep, options: ServicesOptions())
            XCTFail("expected rejection")
        } catch {}
        try await ep.close()
    }

    func testRejectsTwoCredentials() async throws {
        let ep = try await endpoint()
        do {
            _ = try await ServicesClient.create(
                endpoint: ep,
                options: ServicesOptions(apiSecret: FAKE_API_SECRET, apiSecretFromEnv: true)
            )
            XCTFail("expected rejection")
        } catch {}
        try await ep.close()
    }

    func testRejectsMalformedSecret() async throws {
        let ep = try await endpoint()
        do {
            _ = try await ServicesClient.create(
                endpoint: ep,
                options: ServicesOptions(apiSecret: "not-a-valid-ticket")
            )
            XCTFail("expected rejection")
        } catch {}
        try await ep.close()
    }
}
