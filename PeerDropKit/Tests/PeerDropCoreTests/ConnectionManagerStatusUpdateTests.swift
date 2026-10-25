// PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerStatusUpdateTests.swift
//
// Project F2 Task 2: the `supportsStatusUpdate` HELLO capability and the
// receive gate for the encrypted `.statusUpdate` frame. One real CM over
// loopback TCP against a scripted raw `PeerConnection` peer with its own
// in-memory channel identity (pattern: ConnectionManagerNotesExchangeTests;
// its helpers are private, so a trimmed copy lives here).
import XCTest
import Network
import CryptoKit
@testable import PeerDropCore
@testable import PeerDropTransport
@testable import PeerDropProtocol
@testable import PeerDropSecurity

/// In-memory LocalSecureChannel identity for the scripted peer.
private struct SUEphemeralKey: LocalChannelIdentity {
    let priv = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Curve25519.KeyAgreement.PublicKey { priv.publicKey }
    var raw: Data { priv.publicKey.rawRepresentation }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try priv.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

/// The far end of the connection: raw PeerConnection + its own key.
@MainActor
private final class SUScriptedPeer {
    let key: SUEphemeralKey
    let identity: PeerIdentity
    let socket: NWConnection
    let pc: PeerConnection
    let serverHello: PeerIdentity
    var reader: Task<Void, Never>?

    init(key: SUEphemeralKey, identity: PeerIdentity, socket: NWConnection, pc: PeerConnection, serverHello: PeerIdentity) {
        self.key = key; self.identity = identity; self.socket = socket; self.pc = pc; self.serverHello = serverHello
    }
}

@MainActor
final class ConnectionManagerStatusUpdateTests: XCTestCase {
    private var cm: ConnectionManager!
    private var listeners: [NWListener] = []
    private var clients: [NWConnection] = []
    private var peers: [SUScriptedPeer] = []
    private var keyDir: URL!
    private var touchedPeers: [String] = []
    /// Payloads the CM accepted and handed on (in order).
    private var accepted: [(StatusUpdatePayload, String)] = []

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmsu-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmsutest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        cm = ConnectionManager()
        cm.trustedContactStore.removeAll()
        accepted = []
        cm.statusUpdateAcceptedForTesting = { [weak self] payload, pc in
            self?.accepted.append((payload, pc.id))
        }
    }

    override func tearDown() async throws {
        for p in peers { p.reader?.cancel() }
        peers = []
        for c in clients { c.cancel() }
        clients = []
        for l in listeners { l.cancel() }
        listeners = []
        for peer in touchedPeers {
            cm.chatManager.deleteMessages(forPeer: peer)
            cm.deviceStore.remove(id: peer)
        }
        touchedPeers = []
        cm.trustedContactStore.removeAll()
        cm = nil
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testHelloAdvertisesStatusUpdateAndRecordsPerConnection() async throws {
        XCTAssertTrue(cm.localIdentity.supportsStatusUpdate)
        let peer = try await connectPeer()
        XCTAssertTrue(peer.serverHello.supportsStatusUpdate, "accept-side HELLO carries the flag")
        XCTAssertEqual(cm.connections[peer.identity.id]?.advertisedStatusUpdate, true)
        XCTAssertTrue(cm.connections[peer.identity.id]?.peerSupportsStatusUpdate ?? false)
        XCTAssertTrue(StatusUpdateGate.allows(cm.statusUpdateFacts(for: try XCTUnwrap(cm.connections[peer.identity.id]))))

        // The relay HELLO (and the rendezvous one) is built from this copy.
        let relayHello = try PeerMessage.hello(identity: cm.localIdentity.withoutNotesExchange())
        let decoded = try JSONDecoder().decode(PeerIdentity.self, from: try XCTUnwrap(relayHello.payload))
        XCTAssertTrue(decoded.supportsStatusUpdate)
        XCTAssertFalse(decoded.supportsNotesExchange)

        // Unknown (nothing recorded when a HELLO was sent) fails closed.
        let bare = PeerConnection(peerID: "p1", connection: NWConnection(host: "127.0.0.1", port: 9, using: .peerDrop()),
                                  peerIdentity: PeerIdentity(id: "p1", displayName: "x", supportsStatusUpdate: true),
                                  localIdentity: cm.localIdentity, state: .connected)
        XCTAssertNil(bare.advertisedStatusUpdate)
        XCTAssertFalse(cm.statusUpdateFacts(for: bare).localAdvertised)
        XCTAssertFalse(cm.statusUpdateFacts(for: bare).isInstalled)
    }

    func testPlaintextStatusUpdateDropped() async throws {
        let peer = try await connectPeer(beforeSecure: { socket, ident in
            // Before the channel exists.
            try await socket.sendMessage(try PeerMessage.statusUpdate(
                StatusUpdatePayload(text: "early", updatedAt: Date()), senderID: ident.id))
        })
        let pc = try XCTUnwrap(cm.connections[peer.identity.id])
        let plain = try PeerMessage.statusUpdate(StatusUpdatePayload(text: "plain", updatedAt: Date()),
                                                 senderID: peer.identity.id)
        // After the channel is secured: raw plaintext on the wire.
        try await peer.socket.sendMessage(plain)
        try await drain(peer)
        XCTAssertTrue(accepted.isEmpty, "a plaintext statusUpdate was accepted: \(accepted.map(\.0))")
        XCTAssertNil(cm.acceptedStatusUpdate(plain, on: pc, origin: .plaintext))
        XCTAssertTrue(cm.connections[peer.identity.id]?.state.isConnected ?? false, "plaintext frame broke the connection")
        // Positive control: the same frame counts only as an envelope.
        XCTAssertEqual(cm.acceptedStatusUpdate(plain, on: pc, origin: .envelope)?.text, "plain")
    }

    func testEnvelopeStatusUpdateFromFlaggedPeerAccepted() async throws {
        let peer = try await connectPeer()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try await peer.pc.sendMessage(try PeerMessage.statusUpdate(
            StatusUpdatePayload(text: "  在圖書館\n晚點回  ", updatedAt: when), senderID: peer.identity.id))
        let got = await poll { !self.accepted.isEmpty }
        XCTAssertTrue(got, "envelope statusUpdate never accepted")
        XCTAssertEqual(accepted.first?.0, StatusUpdatePayload(text: "在圖書館 晚點回", updatedAt: when), "text is cleaned")
        XCTAssertEqual(accepted.first?.1, peer.identity.id)

        // A nil text (status cleared / hidden) is a valid update too.
        try await peer.pc.sendMessage(try PeerMessage.statusUpdate(
            StatusUpdatePayload(text: nil, updatedAt: when), senderID: peer.identity.id))
        let cleared = await poll { self.accepted.count == 2 }
        XCTAssertTrue(cleared)
        XCTAssertNil(accepted.last?.0.text)
        XCTAssertTrue(cm.connections[peer.identity.id]?.state.isConnected ?? false)
    }

    func testStatusUpdateFromUnflaggedPeerDropped() async throws {
        let peer = try await connectPeer(advertiseStatus: false)
        let pc = try XCTUnwrap(cm.connections[peer.identity.id])
        XCTAssertFalse(pc.peerSupportsStatusUpdate)
        XCTAssertFalse(StatusUpdateGate.allows(cm.statusUpdateFacts(for: pc)))
        let m = try PeerMessage.statusUpdate(StatusUpdatePayload(text: "hi", updatedAt: Date()), senderID: peer.identity.id)
        try await peer.pc.sendMessage(m)
        try await drain(peer)
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertNil(cm.acceptedStatusUpdate(m, on: pc, origin: .envelope))
        XCTAssertTrue(cm.connections[peer.identity.id]?.state.isConnected ?? false)
    }

    func testOversizeOrOverlongStatusUpdateDropped() async throws {
        let peer = try await connectPeer()
        let pc = try XCTUnwrap(cm.connections[peer.identity.id])
        let now = Date()
        // > 1024 bytes on the wire.
        let big = try PeerMessage.statusUpdate(StatusUpdatePayload(text: String(repeating: "a", count: 2048), updatedAt: now),
                                               senderID: peer.identity.id)
        XCTAssertGreaterThan(try XCTUnwrap(big.payload).count, 1024)
        // Small enough, but 61 characters after cleaning.
        let long = try PeerMessage.statusUpdate(StatusUpdatePayload(text: String(repeating: "b", count: 61), updatedAt: now),
                                                senderID: peer.identity.id)
        XCTAssertNil(cm.acceptedStatusUpdate(big, on: pc, origin: .envelope))
        XCTAssertNil(cm.acceptedStatusUpdate(long, on: pc, origin: .envelope))
        // Undecodable payload.
        let junk = PeerMessage(type: .statusUpdate, payload: Data("{\"text\":1}".utf8), senderID: peer.identity.id)
        XCTAssertNil(cm.acceptedStatusUpdate(junk, on: pc, origin: .envelope))
        // Boundary: 60 grapheme clusters (emoji) pass.
        let sixty = try PeerMessage.statusUpdate(StatusUpdatePayload(text: String(repeating: "🙂", count: 60), updatedAt: now),
                                                 senderID: peer.identity.id)
        XCTAssertEqual(cm.acceptedStatusUpdate(sixty, on: pc, origin: .envelope)?.text?.count, 60)

        try await peer.pc.sendMessage(big)
        try await peer.pc.sendMessage(long)
        try await drain(peer)
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(cm.connections[peer.identity.id]?.state.isConnected ?? false)
    }

    /// Why the frame is capability-gated: an older build cannot decode an
    /// unknown `MessageType`, and a frame that fails to decode fails its
    /// receive loop, i.e. the connection.
    func testUnknownMessageTypeStillFailsDecoding() throws {
        let known = try PeerMessage(type: .ping, senderID: "x").encoded()
        XCTAssertNoThrow(try PeerMessage.decoded(from: known))
        let future = try XCTUnwrap(String(data: known, encoding: .utf8))
            .replacingOccurrences(of: #""ping""#, with: #""someFutureType""#)
        XCTAssertTrue(future.contains("someFutureType"))
        XCTAssertThrowsError(try PeerMessage.decoded(from: Data(future.utf8)))
        XCTAssertFalse(PeerConnection.unwrappedControlTypes.contains(.statusUpdate))
    }

    // MARK: - Helpers

    private func poll(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    nonisolated private static func socketQueue() -> DispatchQueue {
        DispatchQueue(label: "test.cmsu.socket", qos: .userInitiated)
    }

    private func startListener(onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        for _ in 0..<20 {
            let port = NWEndpoint.Port(rawValue: UInt16.random(in: 20_000..<45_000))!
            let l = try NWListener(using: .peerDrop(), on: port)
            l.newConnectionHandler = onConnection
            let ready = Gate(), failed = Gate()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.openGate()
                case .failed, .cancelled: failed.openGate()
                default: break
                }
            }
            l.start(queue: Self.socketQueue())
            _ = await poll(timeout: 5) { ready.isOpen || failed.isOpen }
            if ready.isOpen { listeners.append(l); return port.rawValue }
            l.cancel()
        }
        throw NWConnectionError.timeout
    }

    private func dialManager() async throws -> NWConnection {
        let port = try await startListener { [cm] conn in
            Task { @MainActor in cm?._handleIncomingConnectionForTesting(conn) }
        }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .peerDrop())
        clients.append(client)
        client.start(queue: Self.socketQueue())
        try await client.waitReady(timeout: 5)
        return client
    }

    private func text(_ body: String, senderID: String) throws -> PeerMessage {
        try PeerMessage.textMessage(TextMessagePayload(text: body, senderName: "x", messageID: UUID().uuidString),
                                    senderID: senderID)
    }

    /// Dials the CM as a new secure peer, gets accepted, secures the channel
    /// and warms both ratchet directions. `advertiseStatus` sets the peer's
    /// HELLO `supportsStatusUpdate`; `beforeSecure` runs on the raw socket
    /// after the CM's HELLO and before the handshake.
    private func connectPeer(advertiseStatus: Bool = true,
                             beforeSecure: ((NWConnection, PeerIdentity) async throws -> Void)? = nil)
        async throws -> SUScriptedPeer {
        let key = SUEphemeralKey()
        let ident = PeerIdentity(id: UUID().uuidString, displayName: "Pat", identityPublicKey: key.raw,
                                 supportsSecureChannel: true, supportsStatusUpdate: advertiseStatus)
        touchedPeers.append(ident.id)
        let socket = try await dialManager()
        try await socket.sendMessage(try PeerMessage.hello(identity: ident))
        try await socket.sendMessage(PeerMessage.connectionRequest(senderID: ident.id))
        let pending = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == ident.id }
        XCTAssertTrue(pending, "consent sheet never appeared")
        cm.acceptConnection()
        let accept = try await socket.receiveMessage(timeout: 5)
        XCTAssertEqual(accept.type, .connectionAccept)
        let helloMsg = try await socket.receiveMessage(timeout: 5)
        XCTAssertEqual(helloMsg.type, .hello)
        let serverHello = try JSONDecoder().decode(PeerIdentity.self, from: try XCTUnwrap(helloMsg.payload))
        if let beforeSecure { try await beforeSecure(socket, ident) }

        let pc = PeerConnection(peerID: serverHello.id, connection: socket, peerIdentity: serverHello,
                                localIdentity: ident, state: .connected)
        let peer = SUScriptedPeer(key: key, identity: ident, socket: socket, pc: pc, serverHello: serverHello)
        await pc.startSecureChannelNegotiation(peerSupportsSecureChannel: true, identity: key)
        peer.reader = Task { @MainActor in
            while let m = try? await socket.receiveMessage(timeout: 30) {
                if m.type == .secureHandshake {
                    try? await pc.handleIncomingSecureHandshake(m, identity: key)
                } else {
                    try? await pc.handleIncomingMessage(m)
                }
            }
        }
        peers.append(peer)
        let secured = await poll(timeout: 6) {
            pc.secureChannelState == .secured
                && self.cm.connections[ident.id]?.secureChannelState == .secured
                && self.cm.connections[ident.id]?.pinningVerdict != .notChecked
        }
        XCTAssertTrue(secured, "channel never secured")
        try await drain(peer)   // also warms the ratchet so the CM can send
        return peer
    }

    /// Every frame the peer sent before this has been processed by the CM.
    private func drain(_ peer: SUScriptedPeer) async throws {
        let k = peer.identity.id
        let before = cm.chatManager.unreadCounts[k] ?? 0
        var sent = false
        let deadline = Date().addingTimeInterval(4)
        while !sent && Date() < deadline {
            do { try await peer.pc.sendMessage(try text("sentinel", senderID: k)); sent = true }
            catch { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(sent, "peer could never send")
        let drained = await poll { (self.cm.chatManager.unreadCounts[k] ?? 0) > before }
        XCTAssertTrue(drained, "sentinel never arrived")
    }
}
