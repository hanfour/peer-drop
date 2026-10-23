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

/// What the fake directory answers (globally or per account id), every path
/// it was asked for, and requests parked while `hold` is on.
private final class DirectoryScript: @unchecked Sendable {
    enum Reply {
        case entry(accountId: String, identityKey: Data, signingKey: Data)
        case notFound
        case offline
        case status(Int)
        case malformed
    }
    static let shared = DirectoryScript()
    private let lock = NSLock()
    private var _reply: Reply = .notFound
    private var _byAccount: [String: Reply] = [:]
    private var _requests: [String] = []
    private var _hold = false
    private var _parked: [(path: String, proto: FakeDirectoryProtocol)] = []
    var reply: Reply {
        get { lock.lock(); defer { lock.unlock() }; return _reply }
        set { lock.lock(); _reply = newValue; lock.unlock() }
    }
    var hold: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hold }
        set { lock.lock(); _hold = newValue; lock.unlock() }
    }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    var parkedPaths: [String] { lock.lock(); defer { lock.unlock() }; return _parked.map(\.path) }
    func setReply(_ r: Reply, for accountId: String) { lock.lock(); _byAccount[accountId] = r; lock.unlock() }
    func record(_ s: String) { lock.lock(); _requests.append(s); lock.unlock() }
    func reply(forPath path: String) -> Reply {
        lock.lock(); defer { lock.unlock() }
        let id = path.split(separator: "/").last.map(String.init) ?? ""
        return _byAccount[id] ?? _reply
    }
    /// Parks the request when holding; returns false to answer now.
    func parkIfHolding(_ path: String, _ proto: FakeDirectoryProtocol) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _hold else { return false }
        _parked.append((path, proto))
        return true
    }
    /// Answers every parked request for `accountId` with its current reply.
    func release(accountId: String) {
        lock.lock()
        let matching = _parked.filter { $0.path.hasSuffix("/" + accountId) }
        _parked.removeAll { $0.path.hasSuffix("/" + accountId) }
        lock.unlock()
        for item in matching {
            let r = reply(forPath: item.path)
            DispatchQueue.global().async { item.proto.deliver(r) }
        }
    }
    func reset() {
        lock.lock()
        _reply = .notFound; _byAccount = [:]; _requests = []; _hold = false; _parked = []
        lock.unlock()
    }
}

private final class FakeDirectoryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        DirectoryScript.shared.record(url.path + (url.query.map { "?" + $0 } ?? ""))
        if DirectoryScript.shared.parkIfHolding(url.path, self) { return }
        deliver(DirectoryScript.shared.reply(forPath: url.path))
    }
    func deliver(_ reply: DirectoryScript.Reply) {
        switch reply {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .notFound:
            respond(404, Data(#"{"error":"not_found"}"#.utf8))
        case let .status(code):
            respond(code, Data(#"{"error":"server_error"}"#.utf8))
        case .malformed:
            respond(200, Data(#"{"unexpected":true}"#.utf8))
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

    // MARK: - Per-connection advertised flag (final-fix item 11)

    func testGateLocalSupportUsesWhatTheConnectionAdvertisedNotTheAppIdentity() {
        XCTAssertTrue(cm.localIdentity.supportsNotesExchange)
        let pc = PeerConnection(peerID: "p1", connection: NWConnection(host: "127.0.0.1", port: 9, using: .peerDrop()),
                                peerIdentity: PeerIdentity(id: "p1", displayName: "x", supportsNotesExchange: true),
                                localIdentity: cm.localIdentity, state: .connected)
        // Unknown (nothing recorded when a HELLO was sent) fails closed.
        XCTAssertNil(pc.advertisedNotesExchange)
        XCTAssertFalse(cm.notesExchangeFacts(for: pc).localSupportsExchange)
        pc.advertisedNotesExchange = false   // e.g. tailnet HELLO went out without the flag
        XCTAssertFalse(cm.notesExchangeFacts(for: pc).localSupportsExchange)
        pc.advertisedNotesExchange = true
        XCTAssertTrue(cm.notesExchangeFacts(for: pc).localSupportsExchange)
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
                             expectFlagInHello: Bool = true,
                             key fixedKey: EphemeralKey? = nil, id fixedID: String? = nil) async throws -> ScriptedPeer {
        let key = fixedKey ?? EphemeralKey()
        let ident = PeerIdentity(id: fixedID ?? UUID().uuidString, displayName: "Pat",
                                 identityPublicKey: helloKey ?? key.raw,
                                 supportsSecureChannel: true, supportsNotesExchange: advertise)
        if !touchedPeers.contains(ident.id) { touchedPeers.append(ident.id) }
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
        // The gate's "local supports" fact is what THIS connection's HELLO advertised.
        XCTAssertEqual(cm.connections[ident.id]?.advertisedNotesExchange, expectFlagInHello, "per-connection advertised flag")

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
        // M7: nothing is owed once bound with our reveal sent: the tick stops.
        let tickStopped = await poll { !self.cm._notesExchangeTickActiveForTesting(peer.identity.id) }
        XCTAssertTrue(tickStopped, "tick still running in .bound")
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

    /// Accept side: the per-connection flag records what the accepted HELLO actually carried.
    func testAcceptSideRecordsAdvertisedFlagPerConnection() async throws {
        let direct = try await connectPeer()
        XCTAssertEqual(cm.connections[direct.identity.id]?.advertisedNotesExchange, true)
        XCTAssertTrue(cm.notesExchangeFacts(for: try XCTUnwrap(cm.connections[direct.identity.id])).localSupportsExchange)
        cm.notesExchangeRemoteHostOverride = { _ in "100.101.102.103" }
        let tail = try await connectPeer(expectFlagInHello: false)
        let pc = try XCTUnwrap(cm.connections[tail.identity.id])
        XCTAssertEqual(pc.advertisedNotesExchange, false)
        XCTAssertFalse(cm.notesExchangeFacts(for: pc).localSupportsExchange)
        XCTAssertEqual(cm.connections[direct.identity.id]?.advertisedNotesExchange, true, "other connections unaffected")
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
        // Oversize field inside a small payload (100-byte signature).
        try await peer.send(NotesExchangePayload(phase: "intent", nonce: peer.nonce,
                                                 signature: Data(repeating: 1, count: 100)))
        // Oversize nonce.
        try await peer.send(NotesExchangePayload(phase: "intent", nonce: Data(repeating: 3, count: 33)))
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
        await cm.notesExchangeDidBecomeActive()
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
        // The directory agrees with the contact's CURRENT key: only the hash
        // check stops binding an account revealed under the old key.
        DirectoryScript.shared.reply = .entry(accountId: peerAccountId, identityKey: newKey, signingKey: signing)
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

    // MARK: - Fix round 1

    private func pendingContact(_ accountId: String, key: Data, signing: Data,
                                receivedAt: Date = Date(), deviceId: String? = nil) -> TrustedContact {
        TrustedContact(deviceId: deviceId ?? "dev-\(accountId)", displayName: accountId, identityPublicKey: key,
                       trustLevel: .unknown,
                       pendingAccountBinding: PendingAccountBinding(
                           accountId: accountId, signingKey: signing,
                           handshakeKeyHash: Data(SHA256.hash(data: key)), receivedAt: receivedAt))
    }

    private func lookups(_ accountId: String) -> Int {
        directoryLookups.filter { $0.hasSuffix("/" + accountId) }.count
    }

    /// Pairs, sends a valid reveal for `accountId` and waits for `.verifying`.
    @discardableResult
    private func revealAndAwaitVerifying(_ peer: ScriptedPeer, accountId: String? = nil) async throws -> Data {
        let cmNonce = try await pairIntents(peer)
        try await peer.send(try peer.reveal(accountId: accountId ?? peerAccountId, cmNonce: cmNonce))
        let verifying = await poll { self.state(peer) == .verifying }
        XCTAssertTrue(verifying, "state=\(String(describing: state(peer)))")
        return cmNonce
    }

    // I1: network recovery.

    func testNetworkRecoveryDecision() {
        typealias CM = ConnectionManager
        XCTAssertTrue(CM.notesShouldRetryOnPathChange(from: .unsatisfied, oldInterfaces: ["en0"], to: .satisfied, newInterfaces: ["en0"]))
        XCTAssertTrue(CM.notesShouldRetryOnPathChange(from: .requiresConnection, oldInterfaces: [], to: .satisfied, newInterfaces: ["pdp_ip0"]))
        // Library Wi-Fi without internet is already `.satisfied`: a new interface
        // (cellular, another Wi-Fi) while satisfied also retries.
        XCTAssertTrue(CM.notesShouldRetryOnPathChange(from: .satisfied, oldInterfaces: ["en0"], to: .satisfied, newInterfaces: ["en0", "pdp_ip0"]))
        XCTAssertFalse(CM.notesShouldRetryOnPathChange(from: .satisfied, oldInterfaces: ["en0"], to: .satisfied, newInterfaces: ["en0"]))
        XCTAssertFalse(CM.notesShouldRetryOnPathChange(from: .satisfied, oldInterfaces: ["en0"], to: .unsatisfied, newInterfaces: []))
        XCTAssertFalse(CM.notesShouldRetryOnPathChange(from: .unsatisfied, oldInterfaces: ["en0"], to: .unsatisfied, newInterfaces: ["en1"]))
        // The first path at startup: the app-active retry covers it.
        XCTAssertFalse(CM.notesShouldRetryOnPathChange(from: nil, oldInterfaces: [], to: .satisfied, newInterfaces: ["en0"]))
    }

    func testNetworkRecoveryTriggersOneDebouncedRetry() async throws {
        cm.notesRetryDebounceNanoseconds = 150_000_000
        let k = EphemeralKey().raw
        let signing = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let c = pendingContact(peerAccountId, key: k, signing: signing)
        cm.trustedContactStore.add(c)
        // Still offline: every retry would hit the directory, so the count
        // shows how many retries a burst of path updates caused.
        DirectoryScript.shared.reply = .offline
        for _ in 0..<5 {
            cm.notesExchangeNetworkPathChanged(from: .unsatisfied, oldInterfaces: [], to: .satisfied, newInterfaces: ["en0"])
        }
        let tried = await poll { self.lookups(self.peerAccountId) >= 1 }
        XCTAssertTrue(tried, "network recovery did not retry the pending binding")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(lookups(peerAccountId), 1, "a burst of path updates must retry once")
        XCTAssertNotNil(cm.trustedContactStore.find(byId: c.id)?.pendingAccountBinding)

        DirectoryScript.shared.reply = .entry(accountId: peerAccountId, identityKey: k, signingKey: signing)
        cm.notesExchangeNetworkPathChanged(from: .unsatisfied, oldInterfaces: [], to: .satisfied, newInterfaces: ["en0"])
        let bound = await poll { self.cm.trustedContactStore.find(byId: c.id)?.accountId == self.peerAccountId }
        XCTAssertTrue(bound, "network recovery did not bind once the directory answered")

        // An unchanged satisfied path does not retry.
        let d = pendingContact("PEER2346", key: EphemeralKey().raw, signing: signing)
        cm.trustedContactStore.add(d)
        cm.notesExchangeNetworkPathChanged(from: .satisfied, oldInterfaces: ["en0"], to: .satisfied, newInterfaces: ["en0"])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(lookups("PEER2346"), 0)
    }

    // I2: pending TTL.

    func testExpiredPendingClearedWithoutNetwork() async throws {
        let now = Date()
        cm.notesPendingBindingClock = { now }
        let signing = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let k1 = EphemeralKey().raw, k2 = EphemeralKey().raw
        let old = pendingContact(peerAccountId, key: k1, signing: signing,
                                 receivedAt: now.addingTimeInterval(-ConnectionManager.notesPendingBindingLifetime - 60))
        let young = pendingContact("PEER2346", key: k2, signing: signing,
                                   receivedAt: now.addingTimeInterval(-ConnectionManager.notesPendingBindingLifetime + 3600))
        cm.trustedContactStore.add(old)
        cm.trustedContactStore.add(young)
        // Would bind if it were asked.
        DirectoryScript.shared.setReply(.entry(accountId: peerAccountId, identityKey: k1, signingKey: signing), for: peerAccountId)
        DirectoryScript.shared.setReply(.offline, for: "PEER2346")
        XCTAssertEqual(ConnectionManager.notesPendingBindingLifetime, 7 * 24 * 3600)
        await cm.retryPendingBindings()
        XCTAssertNil(cm.trustedContactStore.find(byId: old.id)?.pendingAccountBinding, "expired pending kept")
        XCTAssertNil(cm.trustedContactStore.find(byId: old.id)?.accountId, "expired pending was bound")
        XCTAssertEqual(lookups(peerAccountId), 0, "expired pending must not reach the network")
        XCTAssertNotNil(cm.trustedContactStore.find(byId: young.id)?.pendingAccountBinding, "young pending dropped on a transient error")
        XCTAssertEqual(lookups("PEER2346"), 1)
    }

    func testExpiredPendingEndsLiveVerifying() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline
        try await revealAndAwaitVerifying(peer)
        let pending = await poll { self.contact(peer)?.pendingAccountBinding != nil }
        XCTAssertTrue(pending)
        let before = directoryLookups.count
        cm.notesPendingBindingClock = { Date().addingTimeInterval(ConnectionManager.notesPendingBindingLifetime + 60) }
        await cm.retryPendingBindings()
        XCTAssertEqual(state(peer), .failed(.verificationFailed), "UI still says verifying")
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
        XCTAssertEqual(directoryLookups.count, before)
    }

    func testRetryKeepsPendingOnServerErrorsAndClearsOn404() async throws {
        let signing = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let cases: [(String, DirectoryScript.Reply)] = [
            ("PEER2342", .status(401)), ("PEER2343", .status(403)), ("PEER2344", .status(429)),
            ("PEER2347", .status(500)), ("PEER2348", .status(503)), ("PEER2349", .malformed),
        ]
        var ids: [UUID] = []
        for (account, reply) in cases {
            let c = pendingContact(account, key: EphemeralKey().raw, signing: signing)
            cm.trustedContactStore.add(c)
            ids.append(c.id)
            DirectoryScript.shared.setReply(reply, for: account)
        }
        await cm.retryPendingBindings()
        for (i, id) in ids.enumerated() {
            XCTAssertNotNil(cm.trustedContactStore.find(byId: id)?.pendingAccountBinding, "\(cases[i].1) dropped pending")
            XCTAssertNil(cm.trustedContactStore.find(byId: id)?.accountId)
            XCTAssertGreaterThan(lookups(cases[i].0), 0)
        }
        for (account, _) in cases { DirectoryScript.shared.setReply(.notFound, for: account) }
        await cm.retryPendingBindings()
        for id in ids {
            XCTAssertNil(cm.trustedContactStore.find(byId: id)?.pendingAccountBinding, "404 must clear pending")
            XCTAssertNil(cm.trustedContactStore.find(byId: id)?.accountId)
        }
    }

    func testContactChangedDuringRetryAwaitIsNotBound() async throws {
        let k = EphemeralKey().raw
        let signing = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let c = pendingContact(peerAccountId, key: k, signing: signing)
        cm.trustedContactStore.add(c)
        DirectoryScript.shared.reply = .entry(accountId: peerAccountId, identityKey: k, signingKey: signing)
        DirectoryScript.shared.hold = true
        let cmRef = cm!
        let retry = Task { @MainActor in await cmRef.retryPendingBindings() }
        let parked = await poll { DirectoryScript.shared.parkedPaths.count == 1 }
        XCTAssertTrue(parked)
        // A newer exchange replaced the pending binding meanwhile.
        let newer = PendingAccountBinding(accountId: "PEER2346", signingKey: signing,
                                          handshakeKeyHash: Data(SHA256.hash(data: k)), receivedAt: Date())
        cm.trustedContactStore.setPendingBinding(for: c.id, newer)
        DirectoryScript.shared.hold = false
        DirectoryScript.shared.setReply(.offline, for: "PEER2346")
        DirectoryScript.shared.release(accountId: peerAccountId)
        await retry.value
        XCTAssertNil(cm.trustedContactStore.find(byId: c.id)?.accountId, "bound a contact that changed during the await")
        XCTAssertEqual(cm.trustedContactStore.find(byId: c.id)?.pendingAccountBinding, newer)
    }

    // I3 (1)/(7): pinning denial at CM level.

    func testKnownDeviceWithNewKeyMismatchDenied() async throws {
        let id = UUID().uuidString
        cm.trustedContactStore.add(TrustedContact(deviceId: id, displayName: "Pat", identityPublicKey: EphemeralKey().raw,
                                                  trustLevel: .linked))
        let peer = try await connectPeer(id: id)
        guard case .mismatch = cm.connections[id]?.pinningVerdict else {
            return XCTFail("verdict=\(String(describing: cm.connections[id]?.pinningVerdict))")
        }
        XCTAssertEqual(cm.pressExchangeNotes(with: id), .denied(.pinningMismatch))
        try await peer.sendIntent()
        try await drain(peer)
        XCTAssertNil(state(peer), "intent on a mismatched connection made a session")
        XCTAssertTrue(peer.log.payloads.isEmpty)
    }

    func testIntentWhilePinningNotCheckedIgnored() async throws {
        let peer = try await connectPeer()
        cm.connections[peer.identity.id]?.setPinningVerdict(.notChecked)
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .denied(.pinningNotEvaluated))
        try await peer.sendIntent()
        try await drain(peer)
        XCTAssertNil(state(peer))
        XCTAssertEqual(cm._notesExchangeSessionCountForTesting, 0)
        XCTAssertTrue(peer.log.payloads.isEmpty)
    }

    // I3 (2): a late lookup after reconnect.

    func testLateLookupAfterReconnectDoesNotTouchNewSession() async throws {
        let key = EphemeralKey(), id = UUID().uuidString
        let first = try await connectPeer(key: key, id: id)
        setDirectoryValid(for: first)
        DirectoryScript.shared.hold = true
        try await revealAndAwaitVerifying(first)
        let parked = await poll { DirectoryScript.shared.parkedPaths.count == 1 }
        XCTAssertTrue(parked)
        await cm.disconnect(from: id)
        let gone = await poll { self.cm._notesExchangeSessionCountForTesting == 0 && self.state(first) == nil }
        XCTAssertTrue(gone)

        let second = try await connectPeer(key: key, id: id)
        XCTAssertEqual(cm.pressExchangeNotes(with: id), .allowed)
        XCTAssertEqual(state(second), .waitingForPeer)
        DirectoryScript.shared.release(accountId: peerAccountId)
        // Accepted decision: the proof completed in the first connection, so
        // the binding still lands...
        let bound = await poll { self.contact(second)?.accountId == self.peerAccountId }
        XCTAssertTrue(bound)
        // ...but the new session is untouched.
        try await drain(second)
        XCTAssertEqual(state(second), .waitingForPeer)
        XCTAssertEqual(second.log.phases, ["intent"])
    }

    // I3 (3): the gate flips between pairing and the reveal.

    func testGateFlipBeforeRevealSendsNoReveal() async throws {
        cm._setAccountManagerForTesting(try await makeAccountManager(ready: false, hold: true))
        let registering = cm.accountManager
        Task { await registering.bootstrap() }
        let isRegistering = await poll { registering.state == .registering }
        XCTAssertTrue(isRegistering)

        let flipped = try await connectPeer()
        let replaced = try await connectPeer()
        try await pairIntents(flipped, expectReveal: false)
        try await pairIntents(replaced, expectReveal: false)
        XCTAssertEqual(state(flipped), .exchanging)
        XCTAssertEqual(state(replaced), .exchanging)

        // (a) pinning turns into a mismatch; (b) the PC is replaced in the
        // table without teardown.
        cm.connections[flipped.identity.id]?.setPinningVerdict(.mismatch(stored: "a", received: "b"))
        let original = try XCTUnwrap(cm.connections[replaced.identity.id])
        let dummy = PeerConnection(peerID: replaced.identity.id,
                                   connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
                                   peerIdentity: replaced.identity, localIdentity: cm.localIdentity, state: .connected)
        cm._setConnectionForTesting(peerID: replaced.identity.id, dummy)

        cm._setAccountManagerForTesting(try await makeAccountManager(ready: true))
        let failed = await poll { self.state(flipped) == .failed(.localRevealFailed) }
        XCTAssertTrue(failed, "state=\(String(describing: state(flipped)))")
        cm._setConnectionForTesting(peerID: replaced.identity.id, original)
        try await drain(flipped)
        try await drain(replaced)
        XCTAssertNil(flipped.log.first("reveal"), "reveal sent after the gate flipped")
        XCTAssertNil(replaced.log.first("reveal"), "reveal sent on a replaced connection")
    }

    // I3 (4): contact ambiguity.

    func testAmbiguousContactsNeitherBindNorPend() async throws {
        let scenarios: [(String, (ConnectionManagerNotesExchangeTests, ScriptedPeer) -> Void)] = [
            ("two contacts with the key", { t, p in
                t.cm.trustedContactStore.add(TrustedContact(deviceId: nil, displayName: "Dup", identityPublicKey: p.key.raw,
                                                            trustLevel: .unknown))
            }),
            ("blocked contact", { t, p in
                if let c = t.contact(p) { t.cm.trustedContactStore.setBlocked(c.id, blocked: true) }
            }),
            ("device id held under another key", { t, p in
                for c in t.cm.trustedContactStore.contacts { t.cm.trustedContactStore.remove(c.id) }
                t.cm.trustedContactStore.add(TrustedContact(deviceId: p.identity.id, displayName: "Old",
                                                            identityPublicKey: EphemeralKey().raw, trustLevel: .linked))
            }),
        ]
        for online in [true, false] {
            for (name, setup) in scenarios {
                let peer = try await connectPeer()
                if online { setDirectoryValid(for: peer) } else { DirectoryScript.shared.reply = .offline }
                setup(self, peer)
                let cmNonce = try await pairIntents(peer)
                try await peer.send(try peer.reveal(accountId: peerAccountId, cmNonce: cmNonce))
                let failed = await poll { self.state(peer) == .failed(.verificationFailed) }
                XCTAssertTrue(failed, "\(name) online=\(online): state=\(String(describing: state(peer)))")
                XCTAssertNil(cm.trustedContactStore.find(byAccountId: peerAccountId), "\(name) online=\(online) bound")
                XCTAssertTrue(cm.trustedContactStore.contacts.allSatisfy { $0.pendingAccountBinding == nil },
                              "\(name) online=\(online) stored pending")
                await cm.disconnect(from: peer.identity.id)
                cm.trustedContactStore.removeAll()
            }
        }
    }

    // I3 (6): a second reveal.

    func testSecondDifferentRevealIgnored() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline
        let cmNonce = try await revealAndAwaitVerifying(peer)
        let pending = await poll { self.contact(peer)?.pendingAccountBinding != nil }
        XCTAssertTrue(pending)
        DirectoryScript.shared.setReply(.entry(accountId: "PEER2346", identityKey: peer.key.raw, signingKey: peer.signingKey),
                                        for: "PEER2346")
        try await peer.send(try peer.reveal(accountId: "PEER2346", cmNonce: cmNonce))
        try await drain(peer)
        XCTAssertEqual(lookups("PEER2346"), 0, "a second reveal reached the directory")
        XCTAssertEqual(contact(peer)?.pendingAccountBinding?.accountId, peerAccountId)
        XCTAssertNil(contact(peer)?.accountId)
        XCTAssertEqual(state(peer), .verifying)
    }

    // M1: fail closed without a readable host.

    func testTcpWithoutReadableHostDenied() async throws {
        cm.notesExchangeRemoteHostOverride = { _ in nil }
        let peer = try await connectPeer(expectFlagInHello: false)
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .denied(.notLocalDirect))
        try await peer.sendIntent()
        try await drain(peer)
        XCTAssertNil(state(peer))
        XCTAssertTrue(peer.log.payloads.isEmpty)
    }

    // M2: queued sends after teardown / overwrite.

    func testTeardownDropsQueuedSends() async throws {
        let peer = try await connectPeer()
        let pc = try XCTUnwrap(cm.connections[peer.identity.id])
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .allowed)
        cm.tearDownNotesExchange(for: pc)          // same main-actor turn
        try await drain(peer)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(peer.log.payloads.isEmpty, "a queued frame went out after teardown: \(peer.log.phases)")
    }

    func testQueuedSendSkipsOverwrittenConnection() async throws {
        let peer = try await connectPeer()
        let pc = try XCTUnwrap(cm.connections[peer.identity.id])
        XCTAssertEqual(cm.pressExchangeNotes(with: peer.identity.id), .allowed)
        let dummy = PeerConnection(peerID: peer.identity.id,
                                   connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
                                   peerIdentity: peer.identity, localIdentity: cm.localIdentity, state: .connected)
        cm._setConnectionForTesting(peerID: peer.identity.id, dummy)   // same turn
        try await Task.sleep(nanoseconds: 300_000_000)
        cm._setConnectionForTesting(peerID: peer.identity.id, pc)
        try await drain(peer)
        XCTAssertTrue(peer.log.payloads.isEmpty, "a queued frame went out on an overwritten connection")
    }

    // M4: unbind / hash mismatch end a live "verifying".

    func testUnbindDuringVerifyingEndsSession() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline
        try await revealAndAwaitVerifying(peer)
        let pending = await poll { self.contact(peer)?.pendingAccountBinding != nil }
        XCTAssertTrue(pending)
        cm.unbindNotes(contactID: try XCTUnwrap(contact(peer)).id)
        XCTAssertEqual(state(peer), .failed(.verificationFailed))
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
    }

    func testUnbindDuringInFlightLookupWins() async throws {
        let peer = try await connectPeer()
        setDirectoryValid(for: peer)
        DirectoryScript.shared.hold = true
        try await revealAndAwaitVerifying(peer)
        let parked = await poll { DirectoryScript.shared.parkedPaths.count == 1 }
        XCTAssertTrue(parked)
        cm.unbindNotes(contactID: try XCTUnwrap(contact(peer)).id)
        XCTAssertEqual(state(peer), .failed(.verificationFailed))
        DirectoryScript.shared.release(accountId: peerAccountId)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(contact(peer)?.accountId, "an in-flight lookup bound after the user unbound")
        XCTAssertNil(contact(peer)?.pendingAccountBinding)
    }

    func testRetryHashMismatchEndsLiveVerifying() async throws {
        let peer = try await connectPeer()
        DirectoryScript.shared.reply = .offline
        try await revealAndAwaitVerifying(peer)
        let pending = await poll { self.contact(peer)?.pendingAccountBinding != nil }
        XCTAssertTrue(pending)
        let old = try XCTUnwrap(contact(peer))
        cm.trustedContactStore.remove(old.id)
        cm.trustedContactStore.add(TrustedContact(deviceId: old.deviceId, displayName: old.displayName,
                                                  identityPublicKey: EphemeralKey().raw, trustLevel: .unknown,
                                                  pendingAccountBinding: old.pendingAccountBinding))
        await cm.retryPendingBindings()
        XCTAssertEqual(state(peer), .failed(.verificationFailed))
    }

    // M5: last-started verification wins.

    func testNewerVerificationWinsOverOlderInFlight() async throws {
        let key = EphemeralKey(), id = UUID().uuidString
        let first = try await connectPeer(key: key, id: id)
        DirectoryScript.shared.setReply(.entry(accountId: peerAccountId, identityKey: key.raw, signingKey: first.signingKey),
                                        for: peerAccountId)
        DirectoryScript.shared.hold = true
        try await revealAndAwaitVerifying(first, accountId: peerAccountId)
        let a = await poll { DirectoryScript.shared.parkedPaths.count == 1 }
        XCTAssertTrue(a)
        await cm.disconnect(from: id)
        _ = await poll { self.cm._notesExchangeSessionCountForTesting == 0 }

        let second = try await connectPeer(key: key, id: id)
        DirectoryScript.shared.setReply(.entry(accountId: "PEER2346", identityKey: key.raw, signingKey: second.signingKey),
                                        for: "PEER2346")
        try await revealAndAwaitVerifying(second, accountId: "PEER2346")
        let b = await poll { DirectoryScript.shared.parkedPaths.count == 2 }
        XCTAssertTrue(b)

        DirectoryScript.shared.release(accountId: "PEER2346")
        let bound = await poll { self.contact(second)?.accountId == "PEER2346" }
        XCTAssertTrue(bound)
        XCTAssertEqual(state(second), .bound)
        DirectoryScript.shared.release(accountId: peerAccountId)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(contact(second)?.accountId, "PEER2346", "an older lookup overwrote the newer binding")
        XCTAssertNil(contact(second)?.pendingAccountBinding)
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
