import XCTest
import Combine
@testable import peerdrop_cli
@testable import PeerDropCore
@testable import PeerDropProtocol
@testable import PeerDropSecurity
@testable import PeerDropTransport

/// Transport that records every message sent through it.
final class RecordingTransport: TransportProtocol {
    private let lock = NSLock()
    private var _sent: [PeerMessage] = []
    var sent: [PeerMessage] { lock.withLock { _sent } }
    var isReady: Bool { true }
    var onStateChange: ((TransportState) -> Void)?
    func send(_ message: PeerMessage) async throws { lock.withLock { _sent.append(message) } }
    func receive() async throws -> PeerMessage {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        throw CancellationError()
    }
    func close() {}
}

/// Records every (peerID, text) the session sends back out to peers.
@MainActor
final class RecordingSender {
    var sent: [(peer: String, text: String)] = []
    /// Called after each recorded send (lets a test change auth mid-stream).
    var afterSend: (() -> Void)?
    func texts(to peer: String) -> [String] { sent.filter { $0.peer == peer }.map(\.text) }
    func record(_ text: String, _ peer: String) {
        sent.append((peer, text))
        afterSend?()
    }
}

/// Output side of #166: PTY output and scrollback only ever go to peers that
/// pass the input gate at the moment of each send.
@MainActor
final class AgentSessionOutputTests: XCTestCase {

    private var authorized: Set<String> = []
    private var sender: RecordingSender!
    private var changes: [String: PassthroughSubject<Void, Never>] = [:]
    private var cm: ConnectionManager!

    override func setUp() async throws {
        authorized = []
        sender = RecordingSender()
        changes = [:]
        cm = ConnectionManager()
    }

    private func makeSession() -> AgentSession {
        let sender = self.sender!
        let session = AgentSession(
            bridge: RecordingBridge(),
            connectionManager: cm,
            store: .inMemory(),
            isAuthorized: { [unowned self] in self.authorized.contains($0) },
            sendToPeer: { text, peer in await sender.record(text, peer) },
            authorizationChanges: { [unowned self] peer in
                let subject = self.changes[peer] ?? PassthroughSubject<Void, Never>()
                self.changes[peer] = subject
                return subject.eraseToAnyPublisher()
            })
        session.wire()
        return session
    }

    private func input(_ text: String, from peer: String) throws {
        cm.dispatchTextForTesting(
            try PeerMessage.textMessage(TextMessagePayload(text: text, senderName: "x"), senderID: peer),
            from: peer)
    }

    /// Lets main-queue hops (Combine `receive(on:)`) run, then drains sends.
    private func settle(_ session: AgentSession) async {
        for _ in 0..<3 { await Task.yield() }
        let hop = expectation(description: "main queue hop")
        DispatchQueue.main.async { hop.fulfill() }
        await fulfillment(of: [hop], timeout: 2)
        await session.drainSends()
    }

    // MARK: - Item 6: broadcast + replay only to authorised attached peers

    func test_broadcast_reachesAuthorisedAttachedPeer_notUnauthorisedOne() async throws {
        let session = makeSession()
        authorized = ["a", "b"]
        try input("hi", from: "a")
        try input("hi", from: "b")
        authorized = ["a"]            // b's slot now held by an unauthenticated connection

        session.broadcastNow("out")
        await settle(session)

        XCTAssertEqual(sender.texts(to: "a"), ["out"])
        XCTAssertEqual(sender.texts(to: "b"), [])
    }

    func test_replay_reachesAuthorisedPeer_notUnauthorisedOne() async throws {
        let session = makeSession()
        authorized = ["a", "b"]
        try input("hi", from: "a")
        try input("hi", from: "b")
        session.broadcastNow("l1")
        await settle(session)
        sender.sent = []
        authorized = ["a"]

        session.replayScrollback(to: "b")
        session.replayScrollback(to: "a")
        await settle(session)

        XCTAssertEqual(sender.texts(to: "a"), ["l1"])
        XCTAssertEqual(sender.texts(to: "b"), [])
    }

    // MARK: - Item 3: re-check before EACH send

    func test_replay_stopsAsSoonAsPeerLosesAuthorisation() async throws {
        let session = makeSession()
        authorized = ["a"]
        try input("hi", from: "a")
        session.broadcastNow("l1")
        session.broadcastNow("l2")
        session.broadcastNow("l3")
        await settle(session)
        sender.sent = []

        // The connection is replaced by an unauthenticated one after the first line.
        sender.afterSend = { [unowned self] in self.authorized = [] }
        session.replayScrollback(to: "a")
        await settle(session)

        XCTAssertEqual(sender.texts(to: "a"), ["l1"])
    }

    // MARK: - Item 4: replay on reconnect fires when the connection is authorised

    func test_reconnect_replayWaitsForAuthorisation_thenFlushesOnce() async throws {
        let session = makeSession()
        authorized = ["a"]
        try input("hi", from: "a")
        session.broadcastNow("l1")
        session.broadcastNow("l2")
        await settle(session)
        sender.sent = []

        // Reconnect: the new connection is not secured/verified yet.
        authorized = []
        session.handlePeerConnected("a")
        changes["a"]?.send(())
        await settle(session)
        XCTAssertEqual(sender.sent.count, 0, "nothing before the connection is authorised")

        // Handshake + verification complete → replay without waiting for input/output.
        authorized = ["a"]
        changes["a"]?.send(())
        await settle(session)
        XCTAssertEqual(sender.texts(to: "a"), ["l1", "l2"])

        // Further state changes must not replay again.
        changes["a"]?.send(())
        await settle(session)
        XCTAssertEqual(sender.texts(to: "a"), ["l1", "l2"])
    }

    func test_reconnect_outputAfterFlushKeepsOrder_noDuplicates() async throws {
        let session = makeSession()
        authorized = ["a"]
        try input("hi", from: "a")
        session.broadcastNow("l1")
        await settle(session)
        sender.sent = []
        authorized = []
        session.handlePeerConnected("a")

        authorized = ["a"]
        changes["a"]?.send(())
        session.broadcastNow("l2")      // may race the flush
        await settle(session)

        XCTAssertEqual(sender.texts(to: "a"), ["l1", "l2"])
    }

    /// Output produced while the reconnecting peer is still unauthorised is
    /// held in scrollback and delivered by the flush, in order.
    func test_reconnect_outputWhilePending_isDeliveredByFlushInOrder() async throws {
        let session = makeSession()
        authorized = ["a"]
        try input("hi", from: "a")
        session.broadcastNow("l1")
        await settle(session)
        sender.sent = []
        authorized = []
        session.handlePeerConnected("a")
        session.broadcastNow("l2")
        await settle(session)
        XCTAssertEqual(sender.sent.count, 0)

        authorized = ["a"]
        changes["a"]?.send(())
        await settle(session)
        XCTAssertEqual(sender.texts(to: "a"), ["l1", "l2"])
    }

    /// Default wiring: the production authorizer + the connection's own
    /// published state trigger the replay when verification completes.
    func test_reconnect_defaultWiring_flushesWhenVerdictBecomesMatched() async throws {
        let store = TrustedContactStore.inMemory()
        let peer = EphemeralIdentity()
        let peerKey = peer.publicKey.rawRepresentation
        store.add(TrustedContact(displayName: "phone", identityPublicKey: peerKey, trustLevel: .linked))
        let conn = try await makeSecuredConnection(peerID: "p", peer: peer, helloKey: peerKey)
        conn.setPinningVerdict(.matched)
        cm._setConnectionForTesting(peerID: "p", conn)

        let sender = self.sender!
        let session = AgentSession(
            bridge: RecordingBridge(), connectionManager: cm, store: store,
            sendToPeer: { text, peer in await sender.record(text, peer) })
        session.wire()
        try input("hi", from: "p")
        session.broadcastNow("l1")
        await settle(session)
        XCTAssertEqual(sender.texts(to: "p"), ["l1"])
        sender.sent = []

        conn.setPinningVerdict(.firstTrust)   // stand-in for "new, not yet verified"
        session.handlePeerConnected("p")
        await settle(session)
        XCTAssertEqual(sender.sent.count, 0)

        conn.setPinningVerdict(.matched)
        await settle(session)
        XCTAssertEqual(sender.texts(to: "p"), ["l1"])
    }
}

/// Review 2, item 1: with the PRODUCTION sender, the gate check and the
/// connection the line is sent on must not be separated by other main-queue
/// work. A job queued right before the send swaps the peer ID over to a new,
/// unauthenticated plaintext connection; the line must not reach it.
@MainActor
final class AgentSessionSendRaceTests: XCTestCase {
    func test_defaultSender_connectionSwappedJustBeforeSend_lineDoesNotReachNewConnection() async throws {
        let cm = ConnectionManager()
        let store = TrustedContactStore.inMemory()
        let peer = EphemeralIdentity()
        let peerKey = peer.publicKey.rawRepresentation
        store.add(TrustedContact(displayName: "phone", identityPublicKey: peerKey, trustLevel: .linked))
        let oldTransport = RecordingTransport()
        let verified = try await makeSecuredConnection(peerID: "p", peer: peer, helloKey: peerKey,
                                                       transport: oldTransport)
        verified.setPinningVerdict(.matched)
        cm._setConnectionForTesting(peerID: "p", verified)

        let session = AgentSession(bridge: RecordingBridge(), connectionManager: cm, store: store)
        session.wire()
        cm.dispatchTextForTesting(
            try PeerMessage.textMessage(TextMessagePayload(text: "hi", senderName: "x"), senderID: "p"),
            from: "p")

        let newTransport = RecordingTransport()
        let intruder = PeerConnection(
            peerID: "p", transport: newTransport,
            peerIdentity: PeerIdentity(id: "p", displayName: "phone", identityPublicKey: peerKey,
                                       supportsSecureChannel: false),
            localIdentity: PeerIdentity(id: "cli", displayName: "cli"),
            state: .connected)

        session.broadcastNow("secret-output")                          // send job queued first
        DispatchQueue.main.async { cm._setConnectionForTesting(peerID: "p", intruder) }  // then the swap
        await session.drainSends()
        let hop = expectation(description: "main queue drained")
        DispatchQueue.main.async { hop.fulfill() }
        await fulfillment(of: [hop], timeout: 2)
        await session.drainSends()

        XCTAssertFalse(newTransport.sent.contains { $0.type == .textMessage || $0.type == .secureEnvelope },
                       "output leaked to the unauthenticated connection that took over the peer ID")
        XCTAssertTrue(oldTransport.sent.contains { $0.type == .secureEnvelope },
                      "the line should have gone out, encrypted, on the verified connection")
    }
}

/// A PeerConnection secured by a real LocalSecureChannel handshake over a null
/// transport, with in-memory identity keys.
@MainActor
func makeSecuredConnection(
    peerID: String, peer: EphemeralIdentity, helloKey: Data?,
    transport: TransportProtocol = NullTransport()
) async throws -> PeerConnection {
    let conn = PeerConnection(
        peerID: peerID,
        transport: transport,
        peerIdentity: PeerIdentity(id: peerID, displayName: "phone",
                                   identityPublicKey: helloKey, supportsSecureChannel: true),
        localIdentity: PeerIdentity(id: "cli", displayName: "cli"))
    let (bundle, _) = LocalSecureChannel.prepareHandshake(identity: peer)
    // Make our side the ratchet initiator (lex-smaller identity key) so it has
    // a sending chain and can encrypt immediately.
    var me = EphemeralIdentity()
    while !me.publicKey.rawRepresentation.lexicographicallyPrecedes(peer.publicKey.rawRepresentation) {
        me = EphemeralIdentity()
    }
    try await conn.handleIncomingSecureHandshake(
        try PeerMessage.secureHandshake(bundle: bundle, senderID: peerID),
        identity: me)
    return conn
}
