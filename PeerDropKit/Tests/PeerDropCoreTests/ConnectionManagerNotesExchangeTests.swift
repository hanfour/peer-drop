// PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerNotesExchangeTests.swift
//
// Project C Task 4: the notes-account exchange wired into the real
// ConnectionManager. Two real ConnectionManagers cannot reach `.secured` in
// one process (both use `IdentityKeyManager.shared`), so each test drives ONE
// real CM over loopback TCP against a scripted raw `PeerConnection` peer that
// holds its own in-memory channel identity and Ed25519 signing key (pattern:
// `test_M3_…` in ConnectionManagerSenderBindingTests). The directory is a
// fake URLProtocol behind a real `AccountClient`/`AccountManager`.
import XCTest
import Network
import CryptoKit
@testable import PeerDropCore
@testable import PeerDropTransport
import PeerDropProtocol
@testable import PeerDropSecurity
import PeerDropAccount

// MARK: - Fakes

/// In-memory LocalSecureChannel identity for the scripted peer.
private struct EphemeralKey: LocalChannelIdentity {
    let priv = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Curve25519.KeyAgreement.PublicKey { priv.publicKey }
    var raw: Data { priv.publicKey.rawRepresentation }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try priv.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

/// What the fake directory answers, plus every path it was asked for.
private final class DirectoryScript: @unchecked Sendable {
    enum Reply {
        case entry(accountId: String, identityKey: Data, signingKey: Data)
        case notFound
        case offline
    }
    static let shared = DirectoryScript()
    private let lock = NSLock()
    private var _reply: Reply = .notFound
    private var _requests: [String] = []
    var reply: Reply {
        get { lock.lock(); defer { lock.unlock() }; return _reply }
        set { lock.lock(); _reply = newValue; lock.unlock() }
    }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    func record(_ s: String) { lock.lock(); _requests.append(s); lock.unlock() }
    func reset() { lock.lock(); _reply = .notFound; _requests = []; lock.unlock() }
}

private final class FakeDirectoryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        DirectoryScript.shared.record(url.path + (url.query.map { "?" + $0 } ?? ""))
        switch DirectoryScript.shared.reply {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .notFound:
            respond(404, Data(#"{"error":"not_found"}"#.utf8))
        case let .entry(accountId, identityKey, signingKey):
            respond(200, Data(#"{"accountId":"\#(accountId)","nickname":"peer","identityKey":"\#(identityKey.base64EncodedString())","signingKey":"\#(signingKey.base64EncodedString())","mailboxId":"m"}"#.utf8))
        }
    }
    private func respond(_ status: Int, _ body: Data) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Registration dependencies that are never needed (the account is loaded
/// from the store), except `currentMailbox`, which can be held open so the
/// manager stays `.registering` (= "account unknown" to the exchange).
private struct TestAccountDeps: AccountRegistrationDependencies {
    let hold: Bool
    var deviceId: String { "nx-test-device" }
    var platform: String { "ios" }
    var registrationSupported: Bool { true }
    var attestSupported: Bool { true }
    func identityKeys() throws -> (identity: Data, signing: Data) { (Data(), Data()) }
    func sign(_ data: Data) throws -> Data { Data() }
    func currentMailbox() async throws -> (id: String, token: String) {
        if hold { try await Task.sleep(nanoseconds: 120 * 1_000_000_000) }
        throw URLError(.cancelled)
    }
}

/// Controllable monotonic clock.
private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 10_000)
}

/// Notes-exchange payloads the scripted peer received inside envelopes.
private final class PayloadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _payloads: [NotesExchangePayload] = []
    private var _plaintextExchange = 0
    var payloads: [NotesExchangePayload] { lock.lock(); defer { lock.unlock() }; return _payloads }
    var phases: [String] { payloads.map(\.phase) }
    var plaintextExchangeCount: Int { lock.lock(); defer { lock.unlock() }; return _plaintextExchange }
    func append(_ p: NotesExchangePayload) { lock.lock(); _payloads.append(p); lock.unlock() }
    func notePlaintext() { lock.lock(); _plaintextExchange += 1; lock.unlock() }
    func first(_ phase: String) -> NotesExchangePayload? { payloads.first { $0.phase == phase } }
}

/// The far end of the connection: raw PeerConnection + its own keys.
@MainActor
private final class ScriptedPeer {
    let key: EphemeralKey
    let signing = Curve25519.Signing.PrivateKey()
    let identity: PeerIdentity
    let socket: NWConnection
    let pc: PeerConnection
    let serverHello: PeerIdentity
    let log: PayloadLog
    var reader: Task<Void, Never>?
    var nonce = NotesExchangeCrypto.makeNonce()

    init(key: EphemeralKey, identity: PeerIdentity, socket: NWConnection, pc: PeerConnection,
         serverHello: PeerIdentity, log: PayloadLog) {
        self.key = key; self.identity = identity; self.socket = socket; self.pc = pc
        self.serverHello = serverHello; self.log = log
    }

    var signingKey: Data { signing.publicKey.rawRepresentation }
    /// The CM's handshake identity key as this peer saw it.
    var cmKey: Data { pc.handshakePeerIdentityKey! }

    func send(_ p: NotesExchangePayload) async throws {
        try await pc.sendMessage(try PeerMessage.notesExchange(p, senderID: identity.id))
    }
    func sendIntent() async throws { try await send(NotesExchangePayload(phase: "intent", nonce: nonce)) }

    /// A correctly signed reveal for this connection (peer = revealer).
    func reveal(accountId: String, cmNonce: Data, signer: Curve25519.Signing.PrivateKey? = nil) throws -> NotesExchangePayload {
        let key = signer ?? signing
        let snap = try XCTUnwrap(NotesExchangeSession.AccountSnapshot(
            accountId: accountId, signingKey: key.publicKey.rawRepresentation))
        return try NotesExchangeCrypto.makeReveal(
            account: snap,
            handshakeKeys: NotesExchangePair(mine: self.key.raw, theirs: cmKey),
            nonces: NotesExchangePair(mine: nonce, theirs: cmNonce),
            signer: { try key.signature(for: $0) })
    }
}

// MARK: - Tests

@MainActor
final class ConnectionManagerNotesExchangeTests: XCTestCase {
    private var cm: ConnectionManager!
    private var listeners: [NWListener] = []
    private var clients: [NWConnection] = []
    private var peers: [ScriptedPeer] = []
    private var serverSockets: [NWConnection] = []
    private var keyDir: URL!
    private var touchedPeers: [String] = []
    private let clock = TestClock()

    private let myAccountId = "MYACCT01"
    private let peerAccountId = "PEER2345"

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmnx-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmnxtest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        DirectoryScript.shared.reset()
        cm = ConnectionManager()
        cm.trustedContactStore.removeAll()
        // Headless/test identities do not advertise the flag; this CM plays
        // the app, which does.
        let li = cm.localIdentity
        cm._setLocalIdentityForTesting(PeerIdentity(
            id: li.id, displayName: li.displayName, certificateFingerprint: li.certificateFingerprint,
            identityPublicKey: li.identityPublicKey, identityFingerprint: li.identityFingerprint,
            supportsSecureChannel: li.supportsSecureChannel, isHeadless: li.isHeadless,
            secureChannelVersion: li.secureChannelVersion, supportsNotesExchange: true))
        cm._setAccountManagerForTesting(try await makeAccountManager(ready: true))
        cm.notesExchangeClock = { [clock] in clock.now }
        cm.notesExchangeTickNanoseconds = 20_000_000
    }

    override func tearDown() async throws {
        for p in peers { p.reader?.cancel() }
        peers = []
        for c in clients { c.cancel() }
        clients = []
        for s in serverSockets { s.cancel() }
        serverSockets = []
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

    // MARK: - Helpers

    private func makeAccountManager(ready: Bool, hold: Bool = false) async throws -> AccountManager {
        let store = AccountStore(storageKey: "nx-account-\(UUID().uuidString)",
                                 directory: keyDir.appendingPathComponent("acct", isDirectory: true),
                                 encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeDirectoryProtocol.self]
        let client = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg),
                                   authProvider: { _ in }, tokenInvalidator: {})
        let manager = AccountManager(client: client, store: store, deps: TestAccountDeps(hold: hold),
                                     tokenAdopter: { _, _ in }, tokenIsFresh: { true })
        if ready {
            try store.save(Account(accountId: AccountID(raw: myAccountId)!, nickname: "me",
                                   mailboxId: "mbx", createdAt: Date()))
            await manager.bootstrap()
            XCTAssertNotNil(manager.account)
        }
        return manager
    }

    private func poll(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    nonisolated private static func socketQueue() -> DispatchQueue {
        DispatchQueue(label: "test.cmnx.socket", qos: .userInitiated)
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

    /// Wires a raw client PeerConnection that records envelope-borne
    /// notesExchange payloads, secures it, and starts its reader.
    private func attachClient(key: EphemeralKey, ident: PeerIdentity, socket: NWConnection,
                              serverHello: PeerIdentity, initiate: Bool) async -> ScriptedPeer {
        let pc = PeerConnection(peerID: serverHello.id, connection: socket, peerIdentity: serverHello,
                                localIdentity: ident, state: .connected)
        let log = PayloadLog()
        pc.onMessageReceivedWithOrigin = { m, origin in
            guard m.type == .notesExchange else { return }
            guard origin == .envelope else { log.notePlaintext(); return }
            if let d = m.payload, let p = try? JSONDecoder().decode(NotesExchangePayload.self, from: d) { log.append(p) }
        }
        let peer = ScriptedPeer(key: key, identity: ident, socket: socket, pc: pc, serverHello: serverHello, log: log)
        if initiate { await pc.startSecureChannelNegotiation(peerSupportsSecureChannel: true, identity: key) }
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
        return peer
    }

    /// Dials the CM as a new secure peer, gets accepted, secures the channel
    /// and warms both ratchet directions.
    private func connectPeer(advertise: Bool = true, helloKey: Data? = nil,
                             expectFlagInHello: Bool = true) async throws -> ScriptedPeer {
        let key = EphemeralKey()
        let ident = PeerIdentity(id: UUID().uuidString, displayName: "Pat",
                                 identityPublicKey: helloKey ?? key.raw,
                                 supportsSecureChannel: true, supportsNotesExchange: advertise)
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
        XCTAssertEqual(serverHello.supportsNotesExchange, expectFlagInHello, "HELLO capability flag")

        let peer = await attachClient(key: key, ident: ident, socket: socket, serverHello: serverHello, initiate: true)
        let secured = await poll(timeout: 6) {
            peer.pc.secureChannelState == .secured
                && self.cm.connections[ident.id]?.secureChannelState == .secured
                && self.cm.connections[ident.id]?.pinningVerdict != .notChecked
        }
        XCTAssertTrue(secured, "channel never secured")
        try await warm(peer)
        return peer
    }

    /// Sends encrypted text until it gets through (the ratchet responder must
    /// first receive an envelope), so both directions can send afterwards.
    private func warm(_ peer: ScriptedPeer) async throws {
        let before = cm.chatManager.unreadCounts[peer.identity.id] ?? 0
        var sent = false
        let deadline = Date().addingTimeInterval(4)
        while !sent && Date() < deadline {
            do { try await peer.pc.sendMessage(try text("warm", senderID: peer.identity.id)); sent = true }
            catch { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(sent, "peer could never send")
        let got = await poll { (self.cm.chatManager.unreadCounts[peer.identity.id] ?? 0) > before }
        XCTAssertTrue(got, "warm-up text never arrived")
    }

    /// Every frame the peer sent before this has been processed by the CM.
    private func drain(_ peer: ScriptedPeer, unreadKey: String? = nil) async throws {
        let k = unreadKey ?? peer.identity.id
        let before = cm.chatManager.unreadCounts[k] ?? 0
        try await peer.pc.sendMessage(try text("sentinel", senderID: peer.identity.id))
        let drained = await poll { (self.cm.chatManager.unreadCounts[k] ?? 0) > before }
        XCTAssertTrue(drained, "sentinel never arrived")
    }

    private func state(_ peer: ScriptedPeer) -> NotesExchangeSession.UIState? {
        cm.notesExchangeStates[peer.identity.id]
    }

    private func contact(_ peer: ScriptedPeer) -> TrustedContact? {
        cm.trustedContactStore.find(byPublicKey: peer.key.raw)
    }

    private var directoryLookups: [String] { DirectoryScript.shared.requests.filter { $0.contains("v3/directory/") } }

    private func setDirectoryValid(for peer: ScriptedPeer) {
        DirectoryScript.shared.reply = .entry(accountId: peerAccountId, identityKey: peer.key.raw, signingKey: peer.signingKey)
    }

    /// CM presses, peer presses; returns the CM's intent nonce once the CM's
    /// reveal has arrived (the account is ready by default).
    @discardableResult
    private func pairIntents(_ peer: ScriptedPeer, expectReveal: Bool = true) async throws -> Data {
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .allowed)
        let gotIntent = await poll { peer.log.first("intent") != nil }
        XCTAssertTrue(gotIntent, "CM intent never arrived")
        let cmNonce = try XCTUnwrap(peer.log.first("intent")?.nonce)
        XCTAssertEqual(cmNonce.count, 32)
        try await peer.sendIntent()
        if expectReveal {
            let gotReveal = await poll { peer.log.first("reveal") != nil }
            XCTAssertTrue(gotReveal, "CM reveal never arrived: \(peer.log.phases)")
        } else {
            try await drain(peer)
        }
        return cmNonce
    }

    // MARK: - Happy path

    func testExchangeBindsAfterBothIntentsAndValidReveal() async throws {
        let peer = try await connectPeer()
        setDirectoryValid(for: peer)
        let cmNonce = try await pairIntents(peer)
        XCTAssertEqual(state(peer), .exchanging)

        // The CM's reveal is correct for THIS connection and role.
        let mine = try XCTUnwrap(peer.log.first("reveal"))
        XCTAssertEqual(mine.accountId, myAccountId)
        XCTAssertEqual(mine.signingKey, IdentityKeyManager.shared.signingPublicKey.rawRepresentation)
        XCTAssertTrue(NotesExchangeCrypto.verifyReveal(
            payload: mine,
            handshakeKeys: NotesExchangePair(mine: peer.key.raw, theirs: peer.cmKey),
            nonces: NotesExchangePair(mine: peer.nonce, theirs: cmNonce)))
        XCTAssertNil(peer.log.first("reveal").flatMap { _ in contact(peer)?.accountId }, "bound before the peer revealed")

        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let bound = await poll { self.contact(peer)?.accountId == self.peerAccountId }
        XCTAssertTrue(bound, "valid reveal never bound")
        XCTAssertEqual(state(peer), .bound)
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
        XCTAssertEqual(directoryLookups, ["/v3/directory/\(peerAccountId)"], "lookup must be by id, without bundle")
        XCTAssertEqual(peer.log.phases.filter { $0 == "reveal" }.count, 1, "reveal sent more than once")
    }

    // MARK: - Guard: origin, consent, keys, transport, flag

    func testPlaintextExchangeMessageDropped() async throws {
        let peer = try await connectPeer()
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .allowed)
        let plain = try PeerMessage.notesExchange(NotesExchangePayload(phase: "intent", nonce: peer.nonce),
                                                  senderID: peer.identity.id)
        // (a) Straight into the CM's bound dispatch as plaintext origin.
        cm.dispatchTextForTesting(plain, from: peer.identity.id)
        // (b) Raw plaintext on the wire of the secured socket.
        try await peer.socket.sendMessage(plain)
        try await drain(peer)
        XCTAssertEqual(state(peer), .waitingForPeer, "plaintext intent changed the session")
        XCTAssertNil(peer.log.first("reveal"), "a reveal answered a plaintext intent")
        XCTAssertTrue(directoryLookups.isEmpty)

        // Positive control: the same intent inside an envelope pairs.
        try await peer.sendIntent()
        let revealed = await poll { peer.log.first("reveal") != nil }
        XCTAssertTrue(revealed)
        XCTAssertEqual(peer.log.plaintextExchangeCount, 0, "the CM sent notesExchange as plaintext")
    }

    func testRevealWithoutLocalIntentIgnored() async throws {
        let peer = try await connectPeer()
        setDirectoryValid(for: peer)
        try await peer.sendIntent()
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: Data(repeating: 7, count: 32)))
        try await drain(peer)
        XCTAssertEqual(state(peer), .peerWantsExchange)
        XCTAssertTrue(directoryLookups.isEmpty, "a reveal without our intent reached the directory")
        XCTAssertNil(contact(peer)?.accountId)
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
        XCTAssertNil(peer.log.first("reveal"), "we revealed without the user pressing")
    }

    func testHandshakeKeyMismatchWithHelloDenies() async throws {
        let other = EphemeralKey()
        let peer = try await connectPeer(helloKey: other.raw)
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .denied(.handshakeKeyMismatch))
        try await peer.sendIntent()
        try await drain(peer)
        XCTAssertNil(state(peer), "a denied connection got an exchange session")
        XCTAssertTrue(peer.log.payloads.isEmpty)
    }

    func testRelayConnectionDenied() async throws {
        let (server, client) = try await rawPair()
        let pc = cm._installRelayPlaceholderForTesting(roomCode: "NX\(UUID().uuidString.prefix(4))", connection: server)
        touchedPeers.append(pc.id)
        cm._startRelayHandshakeForTesting(pc)
        // Deferred from Task 1: the relay HELLO is the flag-less copy.
        let helloMsg = try await client.receiveMessage(timeout: 5)
        XCTAssertEqual(helloMsg.type, .hello)
        let serverHello = try JSONDecoder().decode(PeerIdentity.self, from: try XCTUnwrap(helloMsg.payload))
        XCTAssertTrue(cm.localIdentity.supportsNotesExchange)
        XCTAssertFalse(serverHello.supportsNotesExchange, "relay HELLO advertised notes exchange")

        let key = EphemeralKey()
        let ident = PeerIdentity(id: UUID().uuidString, displayName: "Remote", identityPublicKey: key.raw,
                                 supportsSecureChannel: true, supportsNotesExchange: true)
        let peer = await attachClient(key: key, ident: ident, socket: client, serverHello: serverHello, initiate: false)
        try await client.sendMessage(try PeerMessage.hello(identity: ident))
        let secured = await poll(timeout: 6) {
            pc.secureChannelState == .secured && peer.pc.secureChannelState == .secured && pc.pinningVerdict != .notChecked
        }
        XCTAssertTrue(secured, "relay channel never secured")
        try await warmRelay(peer, unreadKey: pc.id)

        XCTAssertEqual(cm.pressExchangeNotes(with: pc.id), .denied(.notLocalDirect))
        try await peer.sendIntent()
        try await drain(peer, unreadKey: pc.id)
        XCTAssertNil(cm.notesExchangeStates[pc.id])
        XCTAssertTrue(peer.log.payloads.isEmpty, "notesExchange sent over relay")
    }

    func testTailnetConnectionDenied() async throws {
        cm.notesExchangeRemoteHostOverride = { _ in "100.101.102.103" }
        let peer = try await connectPeer(expectFlagInHello: false)
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .denied(.notLocalDirect))
        try await peer.sendIntent()
        try await drain(peer)
        XCTAssertNil(state(peer))
        XCTAssertTrue(peer.log.payloads.isEmpty)
    }

    func testTailnetHostClassifier() {
        for h in ["100.64.0.1", "100.127.255.254", "::ffff:100.100.1.1", "fd7a:115c:a1e0::1", "FD7A:115C:A1E0:ab::2%en0",
                  "pixel.tail1234.ts.net", "mac.tail-scale.ts.net."] {
            XCTAssertTrue(ConnectionManager.isTailnetHost(h), h)
        }
        for h in ["100.63.255.255", "100.128.0.1", "192.168.1.2", "127.0.0.1", "fe80::1", "printer.local", "10.0.0.1"] {
            XCTAssertFalse(ConnectionManager.isTailnetHost(h), h)
        }
    }

    func testNoNotesExchangeSentToPeerWithoutFlag() async throws {
        let peer = try await connectPeer(advertise: false)
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .denied(.peerLacksSupport))
        XCTAssertEqual(cm.notesExchangeAvailability(with: peer.identity.id), .denied(.peerLacksSupport))
        // A modified flag-less peer sending one anyway is ignored too.
        try await peer.sendIntent()
        try await drain(peer)
        XCTAssertNil(state(peer))
        XCTAssertTrue(peer.log.payloads.isEmpty, "notesExchange sent to a peer without the flag")
    }

    func testUnknownPhaseAndOversizePayloadIgnored() async throws {
        let peer = try await connectPeer()
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .allowed)
        try await peer.send(NotesExchangePayload(phase: "wave", nonce: peer.nonce))
        try await peer.pc.sendMessage(PeerMessage(type: .notesExchange, payload: Data("not json".utf8),
                                                  senderID: peer.identity.id))
        try await peer.pc.sendMessage(PeerMessage(type: .notesExchange, payload: nil, senderID: peer.identity.id))
        // Oversize field: an intent carrying a 4 KB signature is dropped whole.
        try await peer.send(NotesExchangePayload(phase: "intent", nonce: peer.nonce,
                                                 signature: Data(repeating: 1, count: 4096)))
        try await drain(peer)
        XCTAssertEqual(state(peer), .waitingForPeer)
        XCTAssertTrue(cm.connections[peer.identity.id]?.state.isConnected == true, "connection dropped")
        // Positive control.
        try await peer.sendIntent()
        let revealed = await poll { peer.log.first("reveal") != nil }
        XCTAssertTrue(revealed)
    }

    func testPeerIntentToggleLimit() async throws {
        let peer = try await connectPeer()
        for _ in 0..<(ConnectionManager.notesExchangeMaxPeerToggles / 2) {
            try await peer.sendIntent()
            try await peer.send(NotesExchangePayload(phase: "cancel"))
            peer.nonce = NotesExchangeCrypto.makeNonce()
        }
        try await drain(peer)
        XCTAssertEqual(state(peer), .idle)
        try await peer.sendIntent()
        try await drain(peer)
        XCTAssertEqual(state(peer), .idle, "peer intents beyond the toggle limit must be ignored")
    }

    // MARK: - Verification

    func testDirectoryIdentityKeyMismatchDoesNotBind() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .entry(accountId: peerAccountId, identityKey: EphemeralKey().raw,
                                              signingKey: peer.signingKey)
        let cmNonce = try await pairIntents(peer)
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let failed = await poll { self.state(peer) == .failed(.verificationFailed) }
        XCTAssertTrue(failed, "state=\(String(describing: state(peer)))")
        XCTAssertNil(contact(peer)?.accountId)
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
    }

    func testDirectorySigningKeyMismatchDoesNotBind() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .entry(accountId: peerAccountId, identityKey: peer.key.raw,
                                              signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let cmNonce = try await pairIntents(peer)
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let failed = await poll { self.state(peer) == .failed(.verificationFailed) }
        XCTAssertTrue(failed)
        XCTAssertNil(contact(peer)?.accountId)
    }

    func testDirectoryNicknameCollisionDoesNotBind() async throws {
        let peer = try await connectPeer()
        // The handle resolved to a DIFFERENT account (e.g. a nickname equal to
        // the revealed id after the real account was deleted).
        DirectoryScript.shared.reply = .entry(accountId: "N1CK0000", identityKey: peer.key.raw,
                                              signingKey: peer.signingKey)
        let cmNonce = try await pairIntents(peer)
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let failed = await poll { self.state(peer) == .failed(.verificationFailed) }
        XCTAssertTrue(failed)
        XCTAssertNil(contact(peer)?.accountId)
        XCTAssertNil(cm.trustedContactStore.find(byAccountId: "N1CK0000"))
        XCTAssertNil(cm.trustedContactStore.find(byAccountId: peerAccountId))
    }

    func testBadSignatureDoesNotBind() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline   // would persist a pending binding if reached
        let cmNonce = try await pairIntents(peer)
        var bad = try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce)
        var sig = try XCTUnwrap(bad.signature)
        sig[5] ^= 0x01
        bad.signature = sig
        try await peer.send(bad)
        let failed = await poll { self.state(peer) == .failed(.verificationFailed) }
        XCTAssertTrue(failed)
        XCTAssertTrue(directoryLookups.isEmpty, "signature must be checked before any network")
        XCTAssertNil(contact(peer)?.accountId)
        XCTAssertNil(contact(peer)?.pendingAccountBinding, "a bad-signature reveal was persisted as pending")
    }

    func testRevealSignedForAnotherConnectionDoesNotBind() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline
        let cmNonce = try await pairIntents(peer)
        // Signed over a different verifier nonce (another connection).
        let replay = try peer.reveal(accountId: peerAccountId, cmNonce: NotesExchangeCrypto.makeNonce())
        _ = cmNonce
        try await peer.send(replay)
        let failed = await poll { self.state(peer) == .failed(.verificationFailed) }
        XCTAssertTrue(failed)
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
    }

    func testReflectedOwnRevealRejected() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline
        try await pairIntents(peer)
        let ours = try XCTUnwrap(peer.log.first("reveal"))
        try await peer.send(ours)
        let failed = await poll { self.state(peer) == .failed(.invalidReveal) }
        XCTAssertTrue(failed, "state=\(String(describing: state(peer)))")
        XCTAssertTrue(directoryLookups.isEmpty)
        XCTAssertNil(cm.trustedContactStore.find(byAccountId: myAccountId))
        XCTAssertTrue(cm.trustedContactStore.contacts.allSatisfy { $0.pendingAccountBinding == nil })
    }

    // MARK: - Pending binding

    func testOfflineLookupStoresPendingAndRetriesOnForeground() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline
        let cmNonce = try await pairIntents(peer)
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let pending = await poll { self.contact(peer)?.pendingAccountBinding != nil }
        XCTAssertTrue(pending, "offline lookup did not persist a pending binding")
        let p = try XCTUnwrap(contact(peer)?.pendingAccountBinding)
        XCTAssertEqual(p.accountId, peerAccountId)
        XCTAssertEqual(p.signingKey, peer.signingKey)
        XCTAssertEqual(p.handshakeKeyHash, Data(SHA256.hash(data: peer.key.raw)))
        XCTAssertNil(contact(peer)?.accountId)
        XCTAssertEqual(state(peer), .verifying)

        // Back online; the app comes to the foreground.
        setDirectoryValid(for: peer)
        cm.notesExchangeDidBecomeActive()
        let bound = await poll { self.contact(peer)?.accountId == self.peerAccountId }
        XCTAssertTrue(bound, "foreground retry did not bind")
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
        XCTAssertEqual(state(peer), .bound, "the live session should learn the outcome")
    }

    func testRetryWithChangedKeyClearsPending() async throws {
        let oldKey = EphemeralKey().raw
        let newKey = EphemeralKey().raw
        let signing = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        // (a) The contact's key changed since the reveal: hash no longer matches.
        let a = TrustedContact(deviceId: "dev-a", displayName: "A", identityPublicKey: newKey, trustLevel: .unknown,
                               pendingAccountBinding: PendingAccountBinding(
                                   accountId: peerAccountId, signingKey: signing,
                                   handshakeKeyHash: Data(SHA256.hash(data: oldKey)), receivedAt: Date()))
        cm.trustedContactStore.add(a)
        DirectoryScript.shared.reply = .entry(accountId: peerAccountId, identityKey: oldKey, signingKey: signing)
        await cm.retryPendingBindings()
        XCTAssertNil(cm.trustedContactStore.find(byId: a.id)?.pendingAccountBinding)
        XCTAssertNil(cm.trustedContactStore.find(byId: a.id)?.accountId)

        // (b) Hash matches but the directory's identity key is now different.
        let b = TrustedContact(deviceId: "dev-b", displayName: "B", identityPublicKey: oldKey, trustLevel: .unknown,
                               pendingAccountBinding: PendingAccountBinding(
                                   accountId: "PEER2346", signingKey: signing,
                                   handshakeKeyHash: Data(SHA256.hash(data: oldKey)), receivedAt: Date()))
        cm.trustedContactStore.add(b)
        DirectoryScript.shared.reply = .entry(accountId: "PEER2346", identityKey: newKey, signingKey: signing)
        await cm.retryPendingBindings()
        XCTAssertNil(cm.trustedContactStore.find(byId: b.id)?.pendingAccountBinding)
        XCTAssertNil(cm.trustedContactStore.find(byId: b.id)?.accountId)

        // (c) Not found → cleared; (d) still offline → kept.
        let c = TrustedContact(deviceId: "dev-c", displayName: "C", identityPublicKey: newKey, trustLevel: .unknown,
                               pendingAccountBinding: PendingAccountBinding(
                                   accountId: "PEER2347", signingKey: signing,
                                   handshakeKeyHash: Data(SHA256.hash(data: newKey)), receivedAt: Date()))
        cm.trustedContactStore.add(c)
        DirectoryScript.shared.reply = .offline
        await cm.retryPendingBindings()
        XCTAssertNotNil(cm.trustedContactStore.find(byId: c.id)?.pendingAccountBinding, "transient error must keep pending")
        DirectoryScript.shared.reply = .notFound
        await cm.retryPendingBindings()
        XCTAssertNil(cm.trustedContactStore.find(byId: c.id)?.pendingAccountBinding)
        XCTAssertNil(cm.trustedContactStore.find(byId: c.id)?.accountId)
    }

    func testUnbindClearsBindingAndPending() {
        let k = EphemeralKey().raw
        let c = TrustedContact(deviceId: "dev-u", displayName: "U", identityPublicKey: k, trustLevel: .unknown,
                               accountId: peerAccountId,
                               pendingAccountBinding: PendingAccountBinding(
                                   accountId: "PEER2348", signingKey: Data(repeating: 9, count: 32),
                                   handshakeKeyHash: Data(SHA256.hash(data: k)), receivedAt: Date()))
        cm.trustedContactStore.add(c)
        cm.unbindNotes(contactID: c.id)
        XCTAssertNil(cm.trustedContactStore.find(byId: c.id)?.accountId)
        XCTAssertNil(cm.trustedContactStore.find(byId: c.id)?.pendingAccountBinding)
    }

    // MARK: - Contact resolution

    func testBindingCreatesContactWithDeviceIdOnDialer() async throws {
        let peer = try await connectPeer()
        // The dialing side never runs checkPeerTrust, so it has no contact:
        // emulate that by dropping the one the acceptor path recorded.
        for c in cm.trustedContactStore.contacts { cm.trustedContactStore.remove(c.id) }
        XCTAssertNil(contact(peer))
        setDirectoryValid(for: peer)
        let cmNonce = try await pairIntents(peer)
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let bound = await poll { self.contact(peer)?.accountId == self.peerAccountId }
        XCTAssertTrue(bound)
        let made = try XCTUnwrap(contact(peer))
        XCTAssertEqual(made.deviceId, peer.identity.id)
        XCTAssertEqual(made.displayName, peer.identity.displayName)
        XCTAssertEqual(made.trustLevel, .unknown)
        XCTAssertEqual(made.identityPublicKey, peer.key.raw)
    }

    func testBindingFillsMissingDeviceId() async throws {
        let peer = try await connectPeer()
        for c in cm.trustedContactStore.contacts { cm.trustedContactStore.remove(c.id) }
        let existing = TrustedContact(deviceId: nil, displayName: "Pat (SAS)", identityPublicKey: peer.key.raw,
                                      trustLevel: .linked)
        cm.trustedContactStore.add(existing)
        setDirectoryValid(for: peer)
        let cmNonce = try await pairIntents(peer)
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let bound = await poll { self.cm.trustedContactStore.find(byId: existing.id)?.accountId == self.peerAccountId }
        XCTAssertTrue(bound)
        XCTAssertEqual(cm.trustedContactStore.find(byId: existing.id)?.deviceId, peer.identity.id)
        XCTAssertEqual(cm.trustedContactStore.contacts.filter { $0.matchesKey(peer.key.raw) }.count, 1)
    }

    // MARK: - Lifecycle & state

    func testDisconnectClearsSession() async throws {
        let peer = try await connectPeer()
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .allowed)
        XCTAssertEqual(state(peer), .waitingForPeer)
        XCTAssertEqual(cm._notesExchangeSessionCountForTesting, 1)
        await cm.disconnect(from: peer.identity.id)
        let cleared = await poll { self.state(peer) == nil && self.cm._notesExchangeSessionCountForTesting == 0 }
        XCTAssertTrue(cleared, "session survived the disconnect")
    }

    func testPeerUnavailableShowsState() async throws {
        let peer = try await connectPeer()
        try await pairIntents(peer)
        try await peer.send(NotesExchangePayload(phase: "unavailable"))
        let shown = await poll { self.state(peer) == .peerUnavailable }
        XCTAssertTrue(shown, "state=\(String(describing: state(peer)))")
    }

    func testIntentExpiresViaTick() async throws {
        let peer = try await connectPeer()
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .allowed)
        XCTAssertEqual(state(peer), .waitingForPeer)
        clock.now = clock.now.addingTimeInterval(NotesExchangeSession.intentLifetime + 1)
        let expired = await poll { self.state(peer) == .expired }
        XCTAssertTrue(expired, "tick never expired the intent")
        let cancelled = await poll { peer.log.first("cancel") != nil }
        XCTAssertTrue(cancelled, "expiry did not withdraw the intent")
    }

    func testUserCancelAfterPeerRevealThenAccountReadyNoRevealSent() async throws {
        // Account still registering = unknown: a completed pair waits.
        cm._setAccountManagerForTesting(try await makeAccountManager(ready: false, hold: true))
        let registering = cm.accountManager
        Task { await registering.bootstrap() }
        let isRegistering = await poll { registering.state == .registering }
        XCTAssertTrue(isRegistering)

        let peer = try await connectPeer()
        setDirectoryValid(for: peer)
        let cmNonce = try await pairIntents(peer, expectReveal: false)
        XCTAssertEqual(state(peer), .exchanging)
        try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
        let verifying = await poll { self.state(peer) == .verifying }
        XCTAssertTrue(verifying)

        cm.cancelExchangeNotes(with: peer.identity.id)
        let withdrawn = await poll { peer.log.first("unavailable") != nil }
        XCTAssertTrue(withdrawn, "cancel did not withdraw the owed response: \(peer.log.phases)")

        // The account becomes ready afterwards: still no reveal for this pair,
        // but the pending verification of the PEER's reveal completes.
        cm._setAccountManagerForTesting(try await makeAccountManager(ready: true))
        let bound = await poll { self.contact(peer)?.accountId == self.peerAccountId }
        XCTAssertTrue(bound, "account-ready retry did not complete the pending binding")
        try await drain(peer)
        XCTAssertNil(peer.log.first("reveal"), "revealed after the user cancelled")
    }
}

// MARK: - Shared test plumbing

private final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _c: NWConnection?
    var connection: NWConnection? { lock.lock(); defer { lock.unlock() }; return _c }
    func set(_ c: NWConnection) { lock.lock(); _c = c; lock.unlock() }
}

extension ConnectionManagerNotesExchangeTests {
    fileprivate func rawPair() async throws -> (server: NWConnection, client: NWConnection) {
        let box = ServerBox()
        let port = try await startListener { conn in
            conn.stateUpdateHandler = { state in if case .ready = state { box.set(conn) } }
            conn.start(queue: DispatchQueue(label: "test.cmnx.server", qos: .userInitiated))
        }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .peerDrop())
        clients.append(client)
        client.start(queue: Self.socketQueue())
        try await client.waitReady(timeout: 5)
        let got = await poll { box.connection != nil }
        XCTAssertTrue(got)
        let server = try XCTUnwrap(box.connection)
        serverSockets.append(server)
        return (server, client)
    }

    fileprivate func warmRelay(_ peer: ScriptedPeer, unreadKey: String) async throws {
        let before = cm.chatManager.unreadCounts[unreadKey] ?? 0
        var sent = false
        let deadline = Date().addingTimeInterval(4)
        while !sent && Date() < deadline {
            do { try await peer.pc.sendMessage(try text("warm", senderID: peer.identity.id)); sent = true }
            catch { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(sent)
        let got = await poll { (self.cm.chatManager.unreadCounts[unreadKey] ?? 0) > before }
        XCTAssertTrue(got, "relay warm-up never arrived")
    }
}
