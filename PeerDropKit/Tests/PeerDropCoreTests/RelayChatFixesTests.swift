// Project E / Task 1: relay chat bugs — trust-gate alias, shared chat storage
// key, and deviceIdExchange arriving before PIN confirmation.
import XCTest
import Network
@testable import PeerDropCore
@testable import PeerDropTransport
import PeerDropProtocol
@testable import PeerDropSecurity

private final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _c: NWConnection?
    var connection: NWConnection? { lock.lock(); defer { lock.unlock() }; return _c }
    func set(_ c: NWConnection) { lock.lock(); _c = c; lock.unlock() }
}

@MainActor
final class RelayChatFixesTests: XCTestCase {
    private var cm: ConnectionManager!
    private var listeners: [NWListener] = []
    private var sockets: [NWConnection] = []
    private var keyDir: URL!
    private var touched: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaychatfix-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "relaychatfixtest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        cm = ConnectionManager()
    }

    override func tearDown() async throws {
        for s in sockets { s.cancel() }
        sockets = []
        for l in listeners { l.cancel() }
        listeners = []
        for id in touched {
            cm.chatManager.deleteMessages(forPeer: id)
            cm.deviceStore.remove(id: id)
        }
        touched = []
        cm = nil
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func poll(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func queue() -> DispatchQueue { DispatchQueue(label: "test.relaychatfix", qos: .userInitiated) }

    private func rawPair() async throws -> (server: NWConnection, client: NWConnection) {
        let box = SocketBox()
        var port: UInt16 = 0
        for _ in 0..<20 {
            let p = NWEndpoint.Port(rawValue: UInt16.random(in: 20_000..<45_000))!
            let l = try NWListener(using: .peerDrop(), on: p)
            let q = queue()
            l.newConnectionHandler = { [weak self] conn in
                conn.stateUpdateHandler = { if case .ready = $0 { box.set(conn) } }
                conn.start(queue: q)
                Task { @MainActor in self?.sockets.append(conn) }
            }
            let ready = SocketBox()
            _ = ready
            var ok = false
            let flag = FlagBox()
            l.stateUpdateHandler = { if case .ready = $0 { flag.set() } }
            l.start(queue: q)
            ok = await poll(timeout: 5) { flag.isSet }
            if ok { listeners.append(l); port = p.rawValue; break }
            l.cancel()
        }
        XCTAssertNotEqual(port, 0)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .peerDrop())
        sockets.append(client)
        client.start(queue: queue())
        try await client.waitReady(timeout: 5)
        let got = await poll { box.connection != nil }
        XCTAssertTrue(got, "server side never became ready")
        return (try XCTUnwrap(box.connection), client)
    }

    private func text(_ body: String, senderID: String) throws -> PeerMessage {
        try PeerMessage.textMessage(
            TextMessagePayload(text: body, senderName: "x", messageID: UUID().uuidString),
            senderID: senderID)
    }

    /// A relay peer installed as `relay-<code>` whose HELLO swapped in `real`.
    private func swappedRelayPeer(_ real: PeerIdentity) async throws -> (pc: PeerConnection, client: NWConnection) {
        let (server, client) = try await rawPair()
        let pc = cm._installRelayPlaceholderForTesting(roomCode: "RC\(UUID().uuidString.prefix(6))", connection: server)
        touched.append(pc.id)
        touched.append(real.id)
        try await client.sendMessage(try PeerMessage.hello(identity: real))
        let swapped = await poll { pc.peerIdentity.id == real.id }
        XCTAssertTrue(swapped, "HELLO swap never happened")
        return (pc, client)
    }

    private func legacyIdentity(_ name: String) -> PeerIdentity {
        PeerIdentity(id: UUID().uuidString, displayName: name, supportsSecureChannel: false)
    }

    // MARK: - (a) trust gate alias

    func testTrustGateResolvesRelayAlias() async throws {
        let real = legacyIdentity("Rita")
        let (pc, _) = try await swappedRelayPeer(real)
        XCTAssertTrue(cm.isPeerTrustedForUserActions(peerID: pc.id), "direct key")
        XCTAssertTrue(cm.isPeerTrustedForUserActions(peerID: real.id), "identity-UUID alias must resolve like connection(for:)")
        XCTAssertFalse(cm.isPeerTrustedForUserActions(peerID: "nobody"))
    }

    func testSendToRelayPeerOpenedByIdentityIDIsNotMarkedFailed() async throws {
        let real = legacyIdentity("Rita")
        let (_, client) = try await swappedRelayPeer(real)
        cm.sendTextMessage("hello rita", to: real.id)
        cm.chatManager.loadMessages(forPeer: real.id)
        let sent = await poll {
            self.cm.chatManager.flushAllPendingPersists()
            self.cm.chatManager.loadMessages(forPeer: real.id)
            return self.cm.chatManager.messages.first { $0.text == "hello rita" }?.status == .sent
        }
        let status = cm.chatManager.messages.first { $0.text == "hello rita" }?.status
        XCTAssertTrue(sent, "send must reach .sent, got \(String(describing: status))")
        _ = client
    }

    // MARK: - (b) one chat file

    func testIncomingAndOutgoingShareOneChatFileForRelayPeer() async throws {
        let real = legacyIdentity("Rita")
        let (pc, client) = try await swappedRelayPeer(real)
        try await client.sendMessage(try text("from rita", senderID: real.id))
        let arrived = await poll { (self.cm.chatManager.unreadCounts[real.id] ?? 0) > 0 }
        XCTAssertTrue(arrived, "incoming text should be keyed by the peer identity id")
        XCTAssertEqual(cm.chatManager.unreadCounts[pc.id] ?? 0, 0, "must not split into the relay- thread")

        cm.sendTextMessage("to rita", to: real.id)
        cm.chatManager.flushAllPendingPersists()
        cm.chatManager.loadMessages(forPeer: real.id)
        let texts = cm.chatManager.messages.map(\.text)
        XCTAssertTrue(texts.contains("from rita"), "\(texts)")
        XCTAssertTrue(texts.contains("to rita"), "\(texts)")

        cm.chatManager.loadMessages(forPeer: pc.id)
        XCTAssertTrue(cm.chatManager.messages.isEmpty, "nothing may be stored under the relay- key")
    }

    func testStorageKeyBeforeHelloSwapFallsBackToConnectionID() async throws {
        let (server, client) = try await rawPair()
        let pc = cm._installRelayPlaceholderForTesting(roomCode: "PRE\(UUID().uuidString.prefix(5))", connection: server)
        touched.append(pc.id)
        XCTAssertEqual(ChatStorageKey.key(forConnection: pc), pc.id)
        try await client.sendMessage(try text("early", senderID: pc.peerIdentity.id))
        let arrived = await poll { (self.cm.chatManager.unreadCounts[pc.id] ?? 0) > 0 }
        XCTAssertTrue(arrived, "pre-HELLO text keeps the connection-id key")
    }

    func testNonRelayStorageKeyUnchanged() async throws {
        let ident = legacyIdentity("Lan")
        let dummy = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let local = PeerConnection(peerID: ident.id, connection: dummy, peerIdentity: ident,
                                   localIdentity: cm.localIdentity, state: .connected)
        XCTAssertEqual(ChatStorageKey.key(forConnection: local), ident.id)
        // A non-relay connection keyed differently from its identity keeps its own id.
        let other = PeerConnection(peerID: "bonjour-xyz", connection: dummy, peerIdentity: ident,
                                   localIdentity: cm.localIdentity, state: .connected)
        XCTAssertEqual(ChatStorageKey.key(forConnection: other), "bonjour-xyz")
    }

    // MARK: - (c) deviceIdExchange before PIN confirmation

    func testDeviceIdExchangeBeforePinConfirmationIsApplied() async throws {
        let (server, client) = try await rawPair()
        let code = "PIN\(UUID().uuidString.prefix(5))"
        let pc = cm._installRelayPlaceholderForTesting(roomCode: code, connection: server)
        touched.append(pc.id)
        XCTAssertNil(cm.deviceStore.records.first { $0.id == pc.id })

        cm.pendingRelayPIN = RelayPINRequest(pin: "123456", peerID: pc.id, remoteFingerprint: "fp-\(code)")
        try await client.sendMessage(try PeerMessage.deviceIdExchange(deviceId: "device-abc", senderID: pc.peerIdentity.id))
        // Let the frame be processed (no record exists yet to observe).
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(cm.deviceStore.records.first { $0.id == pc.id })

        cm.confirmRelayPIN()
        let applied = cm.deviceStore.records.first { $0.id == pc.id }?.peerDeviceId
        XCTAssertEqual(applied, "device-abc")
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
