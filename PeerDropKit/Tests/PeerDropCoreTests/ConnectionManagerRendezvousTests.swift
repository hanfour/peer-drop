// Project E / Task 5: ConnectionManager seam for rendezvous ("always
// connected") connections — strict secure-channel policy, `.connecting`
// presence, background, and direct/cross-network dedupe.
//
// One real ConnectionManager + a scripted PeerConnection peer over an
// in-memory pipe (no network). The CM side uses `IdentityKeyManager.shared`
// (file-backed in tests); the scripted peer uses an in-memory identity, so the
// pair reaches `.secured` in-process.
import XCTest
import Combine
import CryptoKit
@testable import PeerDropCore
@testable import PeerDropTransport
@testable import PeerDropProtocol
@testable import PeerDropSecurity

// MARK: - In-memory pipe

/// One end of an in-memory duplex pipe. Thread-safe (sends run off the main
/// actor). `close()` closes both ends, like a data channel going down.
final class RVPipeEnd: TransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    weak var other: RVPipeEnd?
    private var inbox: [PeerMessage] = []
    private var waiters: [CheckedContinuation<PeerMessage, Error>] = []
    private var _sent: [PeerMessage] = []
    private var _closed = false
    private var _onStateChangeSets = 0
    private var _onStateChange: ((TransportState) -> Void)?

    var onStateChange: ((TransportState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStateChange }
        set { lock.lock(); _onStateChange = newValue; _onStateChangeSets += 1; lock.unlock() }
    }
    var onStateChangeSetCount: Int { lock.lock(); defer { lock.unlock() }; return _onStateChangeSets }
    var sent: [PeerMessage] { lock.lock(); defer { lock.unlock() }; return _sent }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var isReady: Bool { !closed }

    static func pair() -> (RVPipeEnd, RVPipeEnd) {
        let a = RVPipeEnd(), b = RVPipeEnd()
        a.other = b; b.other = a
        return (a, b)
    }

    func send(_ message: PeerMessage) async throws {
        guard let peer = record(message) else { throw CancellationError() }
        peer?.deliver(message)
    }

    /// nil when closed; otherwise the (possibly gone) other end.
    private func record(_ message: PeerMessage) -> RVPipeEnd?? {
        lock.lock(); defer { lock.unlock() }
        if _closed { return nil }
        _sent.append(message)
        return .some(other)
    }

    private func deliver(_ message: PeerMessage) {
        lock.lock()
        if _closed { lock.unlock(); return }
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            lock.unlock()
            w.resume(returning: message)
            return
        }
        inbox.append(message)
        lock.unlock()
    }

    func receive() async throws -> PeerMessage {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<PeerMessage, Error>) in
            lock.lock()
            if !inbox.isEmpty {
                let m = inbox.removeFirst()
                lock.unlock()
                c.resume(returning: m)
            } else if _closed {
                lock.unlock()
                c.resume(throwing: CancellationError())
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    func close() {
        shutDown()
        other?.shutDown()
    }

    private func shutDown() {
        lock.lock()
        if _closed { lock.unlock(); return }
        _closed = true
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume(throwing: CancellationError()) }
    }
}

// MARK: - Scripted peer

/// The friend's side: a plain PeerConnection driven by hand, with its own
/// in-memory identity key.
@MainActor
final class ScriptedRVPeer {
    let key: LocalChannelIdentity
    let end: RVPipeEnd
    let pc: PeerConnection
    var respondToHandshake = true
    /// false: never send the initiator's bootstrap no-op.
    var sendsBootstrap = true
    /// false: drop every inbound envelope (so no responder no-op either).
    var readsEnvelopes = true
    private(set) var inbox: [PeerMessage] = []
    private var reader: Task<Void, Never>?

    init(key: LocalChannelIdentity, end: RVPipeEnd, deviceID: String, cmIdentity: PeerIdentity) {
        self.key = key
        self.end = end
        pc = PeerConnection(
            peerID: cmIdentity.id, transport: end,
            peerIdentity: PeerIdentity(id: cmIdentity.id, displayName: "CM", identityPublicKey: cmIdentity.identityPublicKey),
            localIdentity: PeerIdentity(id: deviceID, displayName: "Friend", identityPublicKey: key.publicKey.rawRepresentation),
            state: .connected)
        pc.onMessageReceived = { [weak self] in self?.inbox.append($0) }
        pc.onSecureChannelEstablished = { [weak self] _ in
            // Mirror the app: the ratchet initiator sends a bootstrap no-op.
            Task { @MainActor [weak self] in
                guard let self, self.sendsBootstrap, self.pc.secureChannel?.isInitiator == true,
                      let msg = try? PeerMessage.typingIndicator(
                          TypingIndicatorPayload(isTyping: false, timestamp: Date()), senderID: deviceID)
                else { return }
                try? await self.pc.sendMessage(msg)
            }
        }
    }

    func start() {
        reader = Task { @MainActor [weak self] in
            while let self, let m = try? await self.end.receive() {
                if m.type == .secureHandshake {
                    guard self.respondToHandshake else { continue }
                    try? await self.pc.handleIncomingSecureHandshake(m, identity: self.key)
                } else if m.type == .secureEnvelope, !self.readsEnvelopes {
                    continue
                } else {
                    try? await self.pc.handleIncomingMessage(m)
                }
            }
        }
    }

    func stop() { reader?.cancel() }

    /// Encrypted (if the channel is up) send of a business frame.
    func send(_ m: PeerMessage) async throws { try await pc.sendMessage(m) }

    /// Raw frame straight onto the wire (plaintext, no PeerConnection policy).
    func sendRaw(_ m: PeerMessage) async throws { try await end.send(m) }
}

// MARK: - Recorders / negotiator

@MainActor
final class RVEventRecorder: RendezvousConnectionEventSink {
    private(set) var secure: [(UUID, Bool)] = []
    private(set) var closed: [UUID] = []
    private(set) var secureReasons: [RendezvousConnectionFailure?] = []
    private(set) var closeReasons: [RendezvousConnectionFailure?] = []
    func secureChannelDidComplete(contactID: UUID, ok: Bool, reason: RendezvousConnectionFailure?) {
        secure.append((contactID, ok)); secureReasons.append(reason)
    }
    func connectionDidClose(contactID: UUID, reason: RendezvousConnectionFailure?) {
        closed.append(contactID); closeReasons.append(reason)
    }
}

/// Claims `claimed` as its identity key but derives with a private key it
/// actually owns (it does NOT own the private half of `claimed`).
final class ImpostorChannelIdentity: LocalChannelIdentity {
    let claimed: Curve25519.KeyAgreement.PublicKey
    let actual = Curve25519.KeyAgreement.PrivateKey()
    init(claiming key: Data) throws { claimed = try .init(rawRepresentation: key) }
    var publicKey: Curve25519.KeyAgreement.PublicKey { claimed }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try actual.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

/// Hands the manager a pipe end; like the real negotiator, `close()` closes
/// the transport and fires no callback.
@MainActor
final class PipeNegotiator: RendezvousNegotiator {
    var onLocalSignal: ((RendezvousSignal) -> Void)?
    var onOpen: ((TransportProtocol) -> Void)?
    var onClosed: (() -> Void)?
    let transport: RVPipeEnd
    private(set) var closed = false
    init(transport: RVPipeEnd) { self.transport = transport }
    func start() {}
    func handleRemote(_ signal: RendezvousSignal) {}
    func close() { closed = true; transport.close() }
    func open() { onOpen?(transport) }
}

@MainActor
final class PipeNegotiatorFactory: RendezvousNegotiatorFactory {
    var makeTransport: () -> RVPipeEnd = { RVPipeEnd.pair().0 }
    private(set) var made: [PipeNegotiator] = []
    func makeNegotiator(role: RendezvousRole, iceServers: [RendezvousICEServer]) -> RendezvousNegotiator {
        let n = PipeNegotiator(transport: makeTransport())
        made.append(n)
        return n
    }
}

// MARK: - Tests

@MainActor
final class ConnectionManagerRendezvousTests: XCTestCase {
    private var cm: ConnectionManager!
    private var keyDir: URL!
    private var peers: [ScriptedRVPeer] = []
    private var touched: [String] = []
    private var recorder: RVEventRecorder!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmrv-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmrvtest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        cm = ConnectionManager()
        cm.trustedContactStore.removeAll()
        recorder = RVEventRecorder()
        cm.rendezvousEventSinkForTesting = recorder
        cm.rendezvousSecureChannelTimeoutNanoseconds = 3_000_000_000
    }

    override func tearDown() async throws {
        for p in peers { p.stop(); p.end.close() }
        peers = []
        for id in touched {
            cm.chatManager.deleteMessages(forPeer: id)
            cm.deviceStore.remove(id: id)
        }
        touched = []
        cancellables.removeAll()
        cm.trustedContactStore.removeAll()
        cm = nil
        recorder = nil
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try await super.tearDown()
    }

    // MARK: Helpers

    private func poll(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// A bound, opted-in friend in the CM's store.
    @discardableResult
    private func addFriend(key: RendezvousTestIdentity = RendezvousTestIdentity(), name: String = "Mika",
                           bound: Bool = true, optIn: Bool = true) throws -> TrustedContact {
        let deviceID = "dev-\(UUID().uuidString)"
        touched.append(deviceID)
        let c = TrustedContact(deviceId: deviceID, displayName: name, identityPublicKey: key.raw, trustLevel: .linked)
        cm.trustedContactStore.add(c)
        if bound {
            cm.trustedContactStore.setAccountBinding(for: c.id, accountId: "AC\(UUID().uuidString.prefix(6))")
            if optIn { try cm.trustedContactStore.setRendezvousEnabled(for: c.id, true) }
        }
        return try XCTUnwrap(cm.trustedContactStore.find(byId: c.id))
    }

    /// Install `contact` over a fresh pipe; the scripted peer answers with `peerKey`.
    private func install(_ contact: TrustedContact, peerKey: LocalChannelIdentity,
                         respond: Bool = true) -> (PeerConnection?, ScriptedRVPeer, RVPipeEnd) {
        let (cmEnd, peerEnd) = RVPipeEnd.pair()
        let peer = ScriptedRVPeer(key: peerKey, end: peerEnd, deviceID: contact.deviceId!, cmIdentity: cm.localIdentity)
        peer.respondToHandshake = respond
        peers.append(peer)
        peer.start()
        let pc = cm.installRendezvousConnection(transport: cmEnd, contact: contact)
        return (pc, peer, cmEnd)
    }

    /// Install and wait until the CM reports the secure-channel outcome.
    private func installVerified(_ contact: TrustedContact, key: RendezvousTestIdentity)
        async throws -> (PeerConnection, ScriptedRVPeer, RVPipeEnd) {
        let (pc, peer, end) = install(contact, peerKey: key)
        let installed = try XCTUnwrap(pc)
        let done = await poll { !self.recorder.secure.isEmpty }
        XCTAssertTrue(done, "secure-channel outcome never reported")
        XCTAssertEqual(recorder.secure.map(\.1), [true])
        XCTAssertTrue(installed.rendezvousVerified)
        // Wait for the ratchet bootstrap so either side can send.
        _ = await poll { peer.pc.secureChannelState == .secured }
        return (installed, peer, end)
    }

    private func text(_ s: String, from senderID: String) throws -> PeerMessage {
        try PeerMessage.textMessage(TextMessagePayload(text: s, messageID: UUID().uuidString), senderID: senderID)
    }

    // MARK: Install does not touch foreground state

    func testInstallDoesNotChangeFocusGlobalStateOrDialogs() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let stateBefore = cm.state
        let contactsBefore = cm.trustedContactStore.contacts.count
        let (pc, _, _) = try await installVerified(friend, key: key)

        XCTAssertNil(cm.focusedPeerID)
        XCTAssertEqual(cm.state, stateBefore)
        XCTAssertTrue(cm.connections.isEmpty, "rendezvous connections never enter `connections`")
        XCTAssertNil(cm.pendingLocalFirstTrust)
        XCTAssertNil(cm.pendingKeyChangeAlert)
        XCTAssertNil(cm.pendingFirstContact)
        XCTAssertNil(cm.pendingRelayPIN)
        XCTAssertEqual(cm.trustedContactStore.contacts.count, contactsBefore, "no TOFU contact added")
        XCTAssertEqual(pc.id, friend.deviceId)
        XCTAssertEqual(pc.peerIdentity.id, friend.deviceId)
        XCTAssertEqual(pc.peerIdentity.displayName, friend.displayName)
        XCTAssertEqual(pc.peerIdentity.identityPublicKey, friend.identityPublicKey)
        XCTAssertTrue(pc.isRelayTransport)
        XCTAssertFalse(pc.isRelayPlaceholder)
        XCTAssertEqual(pc.pinningVerdict, .matched)
    }

    // MARK: Strict secure-channel policy

    func testHandshakeKeyNotPinnedDisconnectsAndReportsFalse() async throws {
        let friend = try addFriend()
        let impostor = RendezvousTestIdentity()
        let (pc, _, end) = install(friend, peerKey: impostor)
        XCTAssertNotNil(pc)
        let done = await poll { !self.recorder.secure.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.secure.map(\.1), [false])
        XCTAssertEqual(recorder.secure.map(\.0), [friend.id])
        XCTAssertTrue(end.closed, "transport closed on mismatch")
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
        XCTAssertNil(cm.connection(for: friend.deviceId!))
        XCTAssertNotEqual(cm.presence(ids: [friend.deviceId!]), .online)
        XCTAssertNil(cm.pendingLocalFirstTrust)
        XCTAssertNil(cm.pendingKeyChangeAlert)
        XCTAssertNil(cm.trustedContactStore.find(byPublicKey: impostor.raw), "impostor key never stored")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.secure.count, 1, "reported exactly once")
        XCTAssertTrue(recorder.closed.isEmpty)
    }

    func testHelloKeyDifferentFromHandshakeKeyDisconnectsBeforeSecure() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (pc, peer, end) = install(friend, peerKey: key, respond: false)
        XCTAssertNotNil(pc)
        let other = RendezvousTestIdentity()
        try await peer.sendRaw(try PeerMessage.hello(identity: PeerIdentity(
            id: friend.deviceId!, displayName: "Mika", identityPublicKey: other.raw)))
        let done = await poll { !self.recorder.secure.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.secure.map(\.1), [false])
        XCTAssertTrue(end.closed)
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
    }

    func testHelloKeyDifferentFromHandshakeKeyDisconnectsAfterSecure() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, peer, end) = try await installVerified(friend, key: key)
        let other = RendezvousTestIdentity()
        try await peer.send(try PeerMessage.hello(identity: PeerIdentity(
            id: friend.deviceId!, displayName: "Mika", identityPublicKey: other.raw)))
        let gone = await poll { self.cm.rendezvousConnections[friend.deviceId!] == nil }
        XCTAssertTrue(gone)
        XCTAssertTrue(end.closed)
        XCTAssertEqual(recorder.secure.map(\.1), [true], "secure outcome not re-reported")
        XCTAssertEqual(recorder.closed, [friend.id])
    }

    func testMatchingHelloIsHarmless() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (pc, peer, end) = try await installVerified(friend, key: key)
        try await peer.send(try PeerMessage.hello(identity: PeerIdentity(
            id: "someone-else", displayName: "Renamed", identityPublicKey: key.raw)))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(end.closed)
        XCTAssertTrue(cm.rendezvousConnections[friend.deviceId!] === pc)
        XCTAssertEqual(pc.peerIdentity.id, friend.deviceId, "identity is never re-pointed by HELLO")
        XCTAssertEqual(pc.peerIdentity.displayName, friend.displayName)
    }

    func testNoSecureChannelWithinTimeoutDisconnectsAndNeverPlaintext() async throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 300_000_000
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (cmEnd, peerEnd) = RVPipeEnd.pair()
        let peer = ScriptedRVPeer(key: key, end: peerEnd, deviceID: friend.deviceId!, cmIdentity: cm.localIdentity)
        peer.respondToHandshake = false
        peers.append(peer)
        peer.start()
        let pc = try XCTUnwrap(cm.installRendezvousConnection(transport: cmEnd, contact: friend))
        var states: [PeerConnection.SecureChannelState] = []
        pc.$secureChannelState.sink { states.append($0) }.store(in: &cancellables)
        // A business send before the channel exists must not leave in plaintext.
        try? await pc.sendMessage(try text("early", from: cm.localIdentity.id))

        let done = await poll { !self.recorder.secure.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.secure.map(\.1), [false])
        XCTAssertTrue(cmEnd.closed)
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(states.contains(.fallbackPlaintext), "never entered plaintext: \(states)")
        XCTAssertNotEqual(pc.secureChannelState, .fallbackPlaintext)
        XCTAssertEqual(Set(cmEnd.sent.map(\.type)), [.secureHandshake], "only the handshake bundle went out")
        XCTAssertEqual(recorder.secure.count, 1)
    }

    func testPlaintextBusinessFrameBeforeSecureIsDropped() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (pc, peer, _) = install(friend, peerKey: key, respond: false)
        XCTAssertNotNil(pc)
        try await peer.sendRaw(try text("injected", from: friend.deviceId!))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(cm.chatManager.unreadCounts[friend.deviceId!])
    }

    // MARK: Presence

    func testUnverifiedConnectionIsConnectingNotOnlineAndNeverLive() async throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 10_000_000_000
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (pc, _, _) = install(friend, peerKey: key, respond: false)
        XCTAssertNotNil(pc)
        let id = friend.deviceId!
        XCTAssertEqual(cm.presence(ids: [id]), .connecting)
        XCTAssertNil(cm.connection(for: id), "no sendable connection until verified")
        for binding in [BindingState.none, .pending, .verified] {
            for account in [AccountAvailability.ready, .notReady, .unavailable] {
                XCTAssertNotEqual(ThreadTransport.decide(presence: cm.presence(ids: [id]), binding: binding, account: account), .live)
            }
        }
    }

    func testVerifiedConnectionIsOnlineAndSendTextMessageSucceedsWithChatKey() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let id = friend.deviceId!
        let (pc, peer, _) = try await installVerified(friend, key: key)

        XCTAssertEqual(cm.presence(ids: [id]), .online)
        XCTAssertEqual(ThreadTransport.decide(presence: cm.presence(ids: [id]), binding: .verified, account: .ready), .live)
        XCTAssertTrue(cm.connection(for: id) === pc)
        XCTAssertEqual(ChatStorageKey.key(forConnection: pc), id)
        XCTAssertTrue(cm.isPeerTrustedForUserActions(peerID: id))

        cm.chatManager.loadMessages(forPeer: id)
        cm.sendTextMessage("hello over the internet", to: id)
        let sent = await poll {
            self.cm.chatManager.messages.last.map { $0.isOutgoing && $0.status != .failed && $0.status != .sending } ?? false
        }
        XCTAssertTrue(sent, "status: \(String(describing: cm.chatManager.messages.last?.status))")
        let arrived = await poll { peer.inbox.contains { $0.type == .textMessage } }
        XCTAssertTrue(arrived)

        try await peer.send(try text("hi back", from: id))
        let incoming = await poll {
            self.cm.chatManager.messages.contains { !$0.isOutgoing && $0.text == "hi back" }
        }
        XCTAssertTrue(incoming, "incoming stored under the same chat key")
    }

    func testLinkStateConnectingMapsToConnectingAndUnreachableToOffline() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let h = makeLiveManager()
        h.manager.appDidBecomeActive()
        XCTAssertEqual(h.manager.linkState(for: friend.id), .connecting)
        XCTAssertEqual(cm.presence(ids: [friend.deviceId!]), .connecting)
        XCTAssertNotEqual(ThreadTransport.decide(presence: cm.presence(ids: [friend.deviceId!]), binding: .verified, account: .ready), .live)

        h.signaling.made[0].emit(.closed)
        XCTAssertEqual(h.manager.linkState(for: friend.id), .unreachable)
        XCTAssertEqual(cm.presence(ids: [friend.deviceId!]), .offline, "unreachable is shown as offline")
    }

    // MARK: Dedupe with direct connections

    func testExistingDirectConnectionRefusesInstall() throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let direct = PeerConnection(peerID: friend.deviceId!, transport: RVPipeEnd.pair().0,
                                    peerIdentity: PeerIdentity(id: friend.deviceId!, displayName: "Mika"),
                                    localIdentity: cm.localIdentity, state: .connected)
        cm._setConnectionForTesting(peerID: friend.deviceId!, direct)
        XCTAssertTrue(cm.rendezvousBridge.hasDirectConnection(to: friend))
        let (cmEnd, _) = RVPipeEnd.pair()
        XCTAssertFalse(cm.rendezvousBridge.install(transport: cmEnd, contact: friend))
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
        XCTAssertTrue(cm.connections[friend.deviceId!] === direct)
        XCTAssertTrue(cmEnd.sent.isEmpty)
    }

    func testHasDirectConnectionExcludesRendezvousConnections() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        _ = try await installVerified(friend, key: key)
        XCTAssertFalse(cm.rendezvousBridge.hasDirectConnection(to: friend))
    }

    func testDirectConnectionLaterMakesManagerCloseCrossNetwork() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let h = makeLiveManager()
        let (cmEnd, peerEnd) = RVPipeEnd.pair()
        let peer = ScriptedRVPeer(key: key, end: peerEnd, deviceID: friend.deviceId!, cmIdentity: cm.localIdentity)
        peers.append(peer)
        peer.start()
        h.negotiators.makeTransport = { cmEnd }
        let n = await openLiveConnection(h, friend: friend)
        await rvWaitUntil { h.manager.linkState(for: friend.id) == .connected }
        XCTAssertNotNil(cm.rendezvousConnections[friend.deviceId!])
        let framesBefore = cmEnd.sent.count

        let direct = PeerConnection(peerID: friend.deviceId!, transport: RVPipeEnd.pair().0,
                                    peerIdentity: PeerIdentity(id: friend.deviceId!, displayName: "Mika"),
                                    localIdentity: cm.localIdentity, state: .connected)
        cm._addConnectionForTesting(direct)
        await rvWaitUntil { self.cm.rendezvousConnections[friend.deviceId!] == nil }
        XCTAssertTrue(n.closed, "manager closed the negotiator")
        XCTAssertTrue(cmEnd.closed)
        XCTAssertEqual(cmEnd.sent.count, framesBefore, "no farewell frame")
        XCTAssertTrue(cm.connections[friend.deviceId!] === direct, "the direct connection survives")
        XCTAssertTrue(cm.connection(for: friend.deviceId!) === direct)
        XCTAssertEqual(h.manager.roomCount, 0)
    }

    func testDirectConnectionChangeIsReportedAsynchronously() async throws {
        var calls = 0
        cm.rendezvousBridge.onDirectConnectionsChanged = { calls += 1 }
        let direct = PeerConnection(peerID: "direct-\(UUID().uuidString)", transport: RVPipeEnd.pair().0,
                                    peerIdentity: PeerIdentity(id: "d", displayName: "D"),
                                    localIdentity: cm.localIdentity, state: .connected)
        cm._addConnectionForTesting(direct)
        XCTAssertEqual(calls, 0, "never synchronous")
        let fired = await poll { calls >= 1 }
        XCTAssertTrue(fired)
    }

    func testInstallReportsNothingSynchronously() throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (cmEnd, _) = RVPipeEnd.pair()
        cmEnd.close()  // receive fails at once
        _ = cm.installRendezvousConnection(transport: cmEnd, contact: friend)
        XCTAssertTrue(recorder.secure.isEmpty)
        XCTAssertTrue(recorder.closed.isEmpty)
        var unbound = friend; unbound.accountId = nil
        _ = cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: unbound)
        XCTAssertTrue(recorder.secure.isEmpty)
    }

    // MARK: Eligibility

    func testUnboundOrPendingOrBlockedOrRekeyedContactIsRefused() throws {
        let unbound = try addFriend(bound: false)
        XCTAssertNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: unbound))

        let pending = try addFriend(name: "P")
        cm.trustedContactStore.setPendingBinding(for: pending.id, PendingAccountBinding(
            accountId: "X", signingKey: Data(count: 32), handshakeKeyHash: Data(count: 32), receivedAt: Date()))
        XCTAssertNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: pending))

        let blocked = try addFriend(name: "B")
        cm.trustedContactStore.setBlocked(blocked.id, blocked: true)
        XCTAssertNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: blocked))

        // The manager's copy carries a key the store no longer has.
        var stale = try addFriend(name: "S")
        stale.identityPublicKey = RendezvousTestIdentity().raw
        XCTAssertNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: stale))

        let unknown = TrustedContact(deviceId: "dev-x", displayName: "X", identityPublicKey: RendezvousTestIdentity().raw,
                                     trustLevel: .linked, accountId: "AC1")
        XCTAssertNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: unknown))
        XCTAssertTrue(cm.rendezvousConnections.isEmpty)
    }

    // MARK: Project C exchange gate

    func testNotesExchangeGateRejectsRendezvousConnection() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (pc, _, _) = try await installVerified(friend, key: key)
        XCTAssertFalse(cm.notesExchangeIsLocalDirect(pc))
        XCTAssertEqual(NotesExchangeGate.evaluate(cm.notesExchangeFacts(for: pc)), .denied(.notLocalDirect))
        XCTAssertNotEqual(cm.notesExchangeAvailability(with: friend.deviceId!), .allowed)
        XCTAssertNotEqual(cm.pressExchangeNotes(with: friend.deviceId!), .allowed)
    }

    func testNonChatFramesAreDropped() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, peer, _) = try await installVerified(friend, key: key)
        let stateBefore = cm.state
        try await peer.send(PeerMessage(type: .fileOffer, payload: Data("{}".utf8), senderID: friend.deviceId!))
        try await peer.send(PeerMessage(type: .callRequest, senderID: friend.deviceId!))
        try await peer.send(text("marker", from: friend.deviceId!))
        _ = await poll { (self.cm.chatManager.unreadCounts[friend.deviceId!] ?? 0) >= 1 }
        XCTAssertFalse(cm.showTransferProgress)
        XCTAssertEqual(cm.state, stateBefore)
        XCTAssertNil(cm.focusedPeerID)
    }

    // MARK: Counting

    func testCrossNetworkNotCountedInMaxConnectionsAndCappedAtFive() throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 10_000_000_000
        var friends: [TrustedContact] = []
        for i in 0..<5 { friends.append(try addFriend(name: "F\(i)")) }
        for f in friends {
            XCTAssertNotNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: f))
        }
        XCTAssertEqual(cm.rendezvousConnections.count, 5)
        XCTAssertEqual(cm.maxRendezvousConnections, 5)
        XCTAssertEqual(cm.activeConnectionCount, 0, "not counted against maxConnections")
        XCTAssertEqual(cm.maxConnections, 5)

        // A sixth opted-in friend while five connections are still up (the
        // first one's opt-in was turned off but its connection not yet torn
        // down) is refused by the connection cap itself.
        try cm.trustedContactStore.setRendezvousEnabled(for: friends[0].id, false)
        let sixth = try addFriend(name: "Six")
        XCTAssertTrue(sixth.isRendezvousEnabled)
        XCTAssertNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: sixth))
        XCTAssertEqual(cm.rendezvousConnections.count, 5)
    }

    // MARK: Layers of the strict policy, one at a time

    /// The impostor is another bound friend: the binding resolves (to the
    /// wrong contact), so only the pinned-key comparison stops it.
    func testHandshakeWithAnotherBoundFriendsKeyIsRefused() async throws {
        let mallory = RendezvousTestIdentity()
        _ = try addFriend(key: mallory, name: "Mallory")
        let mika = try addFriend(name: "Mika")
        let (pc, _, end) = install(mika, peerKey: mallory)
        XCTAssertNotNil(pc)
        let done = await poll { !self.recorder.secure.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.secure.map(\.1), [false])
        XCTAssertTrue(end.closed)
        XCTAssertNil(cm.connection(for: mika.deviceId!))
    }

    /// A re-exchange started after install (pending claim) must stop the
    /// connection from verifying even though the key matches.
    func testBindingPendingBeforeSecureIsRefused() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (pc, peer, end) = install(friend, peerKey: key, respond: false)
        XCTAssertNotNil(pc)
        cm.trustedContactStore.setPendingBinding(for: friend.id, PendingAccountBinding(
            accountId: "NEW", signingKey: Data(count: 32), handshakeKeyHash: Data(count: 32), receivedAt: Date()))
        // Now the friend sends its bundle; the CM (which already sent its own) secures.
        await peer.pc.startSecureChannelNegotiation(peerSupportsSecureChannel: true, identity: key)
        let done = await poll { !self.recorder.secure.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.secure.map(\.1), [false])
        XCTAssertTrue(end.closed)
        XCTAssertEqual(pc?.secureChannelState, .secured, "the channel came up; the binding refused it")
    }

    /// An unverified rendezvous connection dispatches nothing, even an
    /// (injected) envelope-origin chat frame.
    func testUnverifiedConnectionDispatchesNothing() async throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 10_000_000_000
        let friend = try addFriend()
        let pc = try XCTUnwrap(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: friend))
        pc.onMessageReceivedWithOrigin?(try text("sneak", from: friend.deviceId!), .envelope)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(cm.chatManager.unreadCounts[friend.deviceId!])
    }

    func testStrictPeerConnectionDropsPlaintextBusinessBeforeSecure() async throws {
        let (a, _) = RVPipeEnd.pair()
        let pc = PeerConnection(peerID: "p", transport: a, peerIdentity: PeerIdentity(id: "p", displayName: "P"),
                                localIdentity: PeerIdentity(id: "me", displayName: "Me"), state: .connected)
        pc.requiresStrictSecureChannel = true
        var delivered: [MessageType] = []
        pc.onMessageReceived = { delivered.append($0.type) }
        try await pc.handleIncomingMessage(try text("x", from: "p"))
        try await pc.handleIncomingMessage(PeerMessage(type: .fileOffer, payload: Data(), senderID: "p"))
        try await pc.handleIncomingMessage(PeerMessage.ping(senderID: "p"))
        try await pc.handleIncomingMessage(try PeerMessage.hello(identity: PeerIdentity(id: "p", displayName: "P")))
        XCTAssertEqual(delivered, [.ping, .hello], "only control frames and HELLO pass before the channel")
    }

    func testStrictPeerConnectionNeverSendsBusinessInPlaintext() async throws {
        let (a, _) = RVPipeEnd.pair()
        let pc = PeerConnection(peerID: "p", transport: a, peerIdentity: PeerIdentity(id: "p", displayName: "P"),
                                localIdentity: PeerIdentity(id: "me", displayName: "Me"), state: .connected)
        pc.requiresStrictSecureChannel = true
        do {
            try await pc.sendMessage(try text("x", from: "me"))
            XCTFail("a business frame must not go out without the channel")
        } catch {}
        try await pc.sendMessage(PeerMessage.ping(senderID: "me"))
        XCTAssertEqual(a.sent.map(\.type), [.ping])
    }

    func testStrictPeerConnectionWithoutPeerSupportFailsInsteadOfPlaintext() async {
        let (a, _) = RVPipeEnd.pair()
        let pc = PeerConnection(peerID: "p", transport: a, peerIdentity: PeerIdentity(id: "p", displayName: "P"),
                                localIdentity: PeerIdentity(id: "me", displayName: "Me"), state: .connected)
        pc.requiresStrictSecureChannel = true
        var failed = 0
        pc.onStrictSecureChannelFailure = { failed += 1 }
        await pc.startSecureChannelNegotiation(peerSupportsSecureChannel: false)
        XCTAssertEqual(failed, 1)
        XCTAssertNotEqual(pc.secureChannelState, .fallbackPlaintext)
    }

    func testStrictHandshakeTimeoutFailsInsteadOfPlaintext() async {
        let (a, _) = RVPipeEnd.pair()
        let pc = PeerConnection(peerID: "p", transport: a, peerIdentity: PeerIdentity(id: "p", displayName: "P"),
                                localIdentity: PeerIdentity(id: "me", displayName: "Me"), state: .connected)
        pc.requiresStrictSecureChannel = true
        pc.handshakeFallbackNanoseconds = 50_000_000
        var failed = 0
        pc.onStrictSecureChannelFailure = { failed += 1 }
        await pc.startSecureChannelNegotiation(peerSupportsSecureChannel: true, identity: RendezvousTestIdentity())
        let fired = await poll { failed == 1 }
        XCTAssertTrue(fired)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(pc.secureChannelState, .handshakeInProgress, "never .fallbackPlaintext")
    }

    // MARK: Background, uninstall

    func testBackgroundClosesConnectionsAndSendsNothing() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let h = makeLiveManager()
        let (cmEnd, peerEnd) = RVPipeEnd.pair()
        let peer = ScriptedRVPeer(key: key, end: peerEnd, deviceID: friend.deviceId!, cmIdentity: cm.localIdentity)
        peers.append(peer)
        peer.start()
        h.negotiators.makeTransport = { cmEnd }
        _ = await openLiveConnection(h, friend: friend)
        await rvWaitUntil { h.manager.linkState(for: friend.id) == .connected }
        let framesBefore = cmEnd.sent.count
        let signalsBefore = h.signaling.made.map(\.sent.count)

        cm.rendezvousClosesOnBackground = true
        cm.handleScenePhaseChange(.background)
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
        XCTAssertTrue(cmEnd.closed)
        XCTAssertEqual(cmEnd.sent.count, framesBefore, "no frame on downgrade")
        XCTAssertEqual(h.signaling.made.map(\.sent.count), signalsBefore)
        XCTAssertFalse(h.manager.isForeground)
        XCTAssertEqual(h.manager.roomCount, 0)
        XCTAssertNotEqual(cm.presence(ids: [friend.deviceId!]), .online)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(cmEnd.sent.count, framesBefore)
    }

    func testMacDoesNotTreatBackgroundAsSuspension() {
        #if os(macOS)
        XCTAssertFalse(cm.rendezvousClosesOnBackground)
        #else
        XCTAssertTrue(cm.rendezvousClosesOnBackground)
        #endif
    }

    func testUninstallIsIdempotentAndSendsNothing() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, _, end) = try await installVerified(friend, key: key)
        let framesBefore = end.sent.count
        let secureBefore = recorder.secure.count
        cm.rendezvousBridge.uninstall(contact: friend)
        cm.rendezvousBridge.uninstall(contact: friend)
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
        XCTAssertTrue(end.closed)
        XCTAssertEqual(end.sent.count, framesBefore, "uninstall sends nothing")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(end.sent.count, framesBefore)
        XCTAssertEqual(recorder.secure.count, secureBefore)
        XCTAssertTrue(recorder.closed.isEmpty, "the manager asked; nothing is reported back")
    }

    func testUninstallNeverTouchesADirectConnectionWithTheSameKey() throws {
        let friend = try addFriend()
        let direct = PeerConnection(peerID: friend.deviceId!, transport: RVPipeEnd.pair().0,
                                    peerIdentity: PeerIdentity(id: friend.deviceId!, displayName: "Mika"),
                                    localIdentity: cm.localIdentity, state: .connected)
        cm._setConnectionForTesting(peerID: friend.deviceId!, direct)
        cm.rendezvousBridge.uninstall(contact: friend)
        XCTAssertTrue(cm.connections[friend.deviceId!] === direct)
    }

    func testPeerDropAfterVerifiedReportsCloseOnce() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, peer, _) = try await installVerified(friend, key: key)
        peer.end.close()
        let closed = await poll { !self.recorder.closed.isEmpty }
        XCTAssertTrue(closed)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.closed, [friend.id])
        XCTAssertEqual(recorder.secure.map(\.1), [true])
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
    }

    func testTransportOnStateChangeIsNotOverwritten() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (cmEnd, peerEnd) = RVPipeEnd.pair()
        var negotiatorSaw = 0
        cmEnd.onStateChange = { _ in negotiatorSaw += 1 }   // the negotiator's observer
        let peer = ScriptedRVPeer(key: key, end: peerEnd, deviceID: friend.deviceId!, cmIdentity: cm.localIdentity)
        peers.append(peer)
        peer.start()
        XCTAssertNotNil(cm.installRendezvousConnection(transport: cmEnd, contact: friend))
        _ = await poll { !self.recorder.secure.isEmpty }
        XCTAssertEqual(recorder.secure.map(\.1), [true])
        XCTAssertEqual(cmEnd.onStateChangeSetCount, 1, "CM never assigns transport.onStateChange")
        cmEnd.onStateChange?(.ready)
        XCTAssertEqual(negotiatorSaw, 1)
    }

    // MARK: Live manager harness (fake signaling + pipe negotiator)

    private struct LiveHarness {
        let manager: RendezvousManager
        let signaling: FakeSignalingFactory
        let negotiators: PipeNegotiatorFactory
    }

    private func makeLiveManager() -> LiveHarness {
        let me = RendezvousTestIdentity()
        let signaling = FakeSignalingFactory()
        let negotiators = PipeNegotiatorFactory()
        let manager = RendezvousManager(
            contacts: { [weak cm] in cm?.trustedContactStore.contacts ?? [] },
            secrets: IdentityRendezvousSecretProvider(identity: me),
            direct: cm.rendezvousBridge, installer: cm.rendezvousBridge,
            signaling: signaling, negotiators: negotiators,
            clock: FakeRVClock(Date()), jitter: FixedRVJitter(), ticker: ManualRVTicker(),
            sessionTags: RendezvousSessionTagStore())
        cm._setRendezvousManagerForTesting(manager)
        cm.rendezvousEventSinkForTesting = nil   // production path: the manager
        return LiveHarness(manager: manager, signaling: signaling, negotiators: negotiators)
    }

    /// Foreground → authenticated room → negotiator → data channel open.
    private func openLiveConnection(_ h: LiveHarness, friend: TrustedContact) async -> PipeNegotiator {
        h.manager.appDidBecomeActive()
        let t = h.signaling.made[0]
        t.emit(.peerJoined)
        t.emit(.handshakeCompleted)
        // Either role: the offerer starts on `ready`, the answerer on `offer`.
        t.emit(.signal(RendezvousSignal.ready.encoded()))
        t.emit(.signal(RendezvousSignal.offer(sdp: "v=0").encoded()))
        await rvWaitUntil { h.negotiators.made.count == 1 }
        let n = h.negotiators.made[0]
        n.open()
        return n
    }
}

// MARK: - Task 5 fix round 1

extension ConnectionManagerRendezvousTests {

    private func reasonsByContact() -> [UUID: RendezvousConnectionFailure?] {
        Dictionary(zip(recorder.secure.map(\.0), recorder.secureReasons), uniquingKeysWith: { a, _ in a })
    }

    // MARK: I-1 key confirmation

    /// The impostor sends the PINNED public key in its bundle but does not own
    /// its private key. Static-static DH still reaches `.secured` on our side;
    /// only the first decrypted envelope (key confirmation) can tell. Several
    /// friends so both ratchet roles are exercised.
    func testImpostorClaimingThePinnedKeyWithoutItsPrivateKeyIsNeverVerified() async throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 600_000_000
        var friends: [TrustedContact] = []
        var ends: [RVPipeEnd] = []
        var pcs: [PeerConnection] = []
        for i in 0..<4 {
            let f = try addFriend(name: "V\(i)")
            friends.append(f)
            let (pc, _, end) = install(f, peerKey: try ImpostorChannelIdentity(claiming: f.identityPublicKey))
            pcs.append(try XCTUnwrap(pc))
            ends.append(end)
        }
        var sawLive = false
        let done = await poll(timeout: 5) {
            if pcs.contains(where: \.rendezvousVerified)
                || friends.contains(where: { self.cm.presence(ids: [$0.deviceId!]) == .online
                                             || self.cm.connection(for: $0.deviceId!) != nil }) {
                sawLive = true
            }
            return self.recorder.secure.count == friends.count
        }
        XCTAssertTrue(done)
        XCTAssertFalse(sawLive, "an impostor was online at some point")
        XCTAssertEqual(recorder.secure.map(\.1), Array(repeating: false, count: friends.count))
        for r in recorder.secureReasons {
            XCTAssertTrue(r == .timeout || r == .decryptFailed, String(describing: r))
        }
        XCTAssertTrue(pcs.allSatisfy { $0.secureChannelState == .secured }, "the claimed key alone reaches .secured")
        XCTAssertTrue(ends.allSatisfy(\.closed))
        XCTAssertTrue(recorder.closed.isEmpty)
        for f in friends { XCTAssertNotEqual(cm.presence(ids: [f.deviceId!]), .online) }
    }

    /// `.secured` with the right key is not enough: until the peer's first
    /// envelope decrypts, the connection is `.connecting`, unsendable, and
    /// nothing is reported. Without confirmation within the deadline: ok:false.
    func testSecuredButUnconfirmedStaysConnectingThenTimesOut() async throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 600_000_000
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let id = friend.deviceId!
        let (cmEnd, peerEnd) = RVPipeEnd.pair()
        let peer = ScriptedRVPeer(key: key, end: peerEnd, deviceID: id, cmIdentity: cm.localIdentity)
        peer.sendsBootstrap = false
        peer.readsEnvelopes = false
        peers.append(peer)
        peer.start()
        let pc = try XCTUnwrap(cm.installRendezvousConnection(transport: cmEnd, contact: friend))
        let secured = await poll { pc.secureChannelState == .secured }
        XCTAssertTrue(secured)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(pc.rendezvousVerified)
        XCTAssertEqual(cm.presence(ids: [id]), .connecting)
        XCTAssertNil(cm.connection(for: id))
        XCTAssertTrue(recorder.secure.isEmpty, "no ok:true before key confirmation")

        let done = await poll { !self.recorder.secure.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.secure.map(\.1), [false])
        XCTAssertEqual(recorder.secureReasons, [.timeout])
        XCTAssertTrue(cmEnd.closed)
        XCTAssertNil(cm.rendezvousConnections[id])
    }

    func testDecryptFailureAfterVerificationClosesAndReportsOnce() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, peer, end) = try await installVerified(friend, key: key)
        let garbage = Data((0..<96).map { _ in UInt8.random(in: 0...255) })
        try await peer.sendRaw(PeerMessage.secureEnvelope(frame: garbage, senderID: friend.deviceId!))
        let closed = await poll { !self.recorder.closed.isEmpty }
        XCTAssertTrue(closed)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.closed, [friend.id])
        XCTAssertEqual(recorder.closeReasons, [.decryptFailed])
        XCTAssertEqual(recorder.secure.map(\.1), [true])
        XCTAssertTrue(end.closed)
        XCTAssertNil(cm.rendezvousConnections[friend.deviceId!])
    }

    // MARK: I-4 local failure reasons (+ m-1 opt-in re-checked at verify)

    func testFailureReasonsAreReportedLocally() async throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 10_000_000_000
        // Handshake key is not the pinned one.
        let keyed = try addFriend(name: "K")
        _ = install(keyed, peerKey: RendezvousTestIdentity())
        // HELLO claims another key.
        let k2 = RendezvousTestIdentity()
        let helloed = try addFriend(key: k2, name: "H")
        let (_, p2, _) = install(helloed, peerKey: k2, respond: false)
        try await p2.sendRaw(try PeerMessage.hello(identity: PeerIdentity(
            id: helloed.deviceId!, displayName: "H", identityPublicKey: RendezvousTestIdentity().raw)))
        // Opt-in turned off between install and secure (m-1).
        let k3 = RendezvousTestIdentity()
        let optedOut = try addFriend(key: k3, name: "O")
        let (_, p3, e3) = install(optedOut, peerKey: k3, respond: false)
        try cm.trustedContactStore.setRendezvousEnabled(for: optedOut.id, false)
        await p3.pc.startSecureChannelNegotiation(peerSupportsSecureChannel: true, identity: k3)

        let done = await poll { self.recorder.secure.count == 3 }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.secure.map(\.1), [false, false, false])
        let reasons = reasonsByContact()
        XCTAssertEqual(reasons[keyed.id], .keyMismatch)
        XCTAssertEqual(reasons[helloed.id], .helloMismatchUnauthenticated, "plaintext HELLO: not authenticated")
        XCTAssertEqual(reasons[optedOut.id], .bindingFailed)
        XCTAssertTrue(e3.closed)
    }

    func testHelloMismatchAfterVerifyIsReportedWithItsReason() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, peer, _) = try await installVerified(friend, key: key)
        try await peer.send(try PeerMessage.hello(identity: PeerIdentity(
            id: friend.deviceId!, displayName: "Mika", identityPublicKey: RendezvousTestIdentity().raw)))
        let closed = await poll { !self.recorder.closed.isEmpty }
        XCTAssertTrue(closed)
        XCTAssertEqual(recorder.closeReasons, [.helloMismatch])
    }

    // MARK: Round 2, M-1: focus never lands on a cross-network connection

    func testFocusIgnoresRendezvousConnections() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        _ = try await installVerified(friend, key: key)
        cm.focus(on: friend.deviceId!)
        XCTAssertNil(cm.focusedPeerID)
    }

    // MARK: Round 2, M-2: one stored-thread read per frame

    func testThreadContainsBatchReadsTheThreadOnce() throws {
        let peerID = "batch-\(UUID().uuidString)"
        touched.append(peerID)
        let ours = (0..<5).map { cm.chatManager.saveOutgoing(text: "m\($0)", peerID: peerID, peerName: "P").id }
        cm.chatManager.flushAllPendingPersists()
        let before = cm.chatManager.threadDiskReadCount
        let found = cm.chatManager.threadContains(messageIDs: Set(ours + ["foreign"]), peerID: peerID, outgoingOnly: true)
        XCTAssertEqual(found, Set(ours))
        XCTAssertEqual(cm.chatManager.threadDiskReadCount - before, 1)
        for id in ours { XCTAssertTrue(cm.chatManager.threadContains(messageID: id, peerID: peerID, outgoingOnly: true)) }
        XCTAssertFalse(cm.chatManager.threadContains(messageID: "foreign", peerID: peerID))
    }

    func testReceiptWithManyIDsReadsTheThreadOnce() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let id = friend.deviceId!
        let (_, peer, _) = try await installVerified(friend, key: key)
        let ours = (0..<5).map { cm.chatManager.saveOutgoing(text: "m\($0)", peerID: id, peerName: "Mika").id }
        cm.chatManager.flushAllPendingPersists()
        let before = cm.chatManager.threadDiskReadCount
        try await peer.send(try PeerMessage.messageReceipt(
            MessageReceiptPayload(messageIDs: ours, receiptType: .read, timestamp: Date()), senderID: id))
        try await peer.send(text("marker", from: id))
        _ = await poll { (self.cm.chatManager.unreadCounts[id] ?? 0) >= 1 }
        XCTAssertEqual(cm.chatManager.threadDiskReadCount - before, 1)
        cm.chatManager.loadMessages(forPeer: id)
        for m in cm.chatManager.messages where ours.contains(m.id) { XCTAssertEqual(m.status, .read) }
    }

    // MARK: I-2 media goes to the chat's peer, not the focused one

    func testMediaFromAnOpenChatGoesToThatChatsPeerEvenWhenAnotherIsFocused() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let id = friend.deviceId!
        let (_, peer, _) = try await installVerified(friend, key: key)

        let otherID = "direct-\(UUID().uuidString)"
        touched.append(otherID)
        let (otherEnd, _) = RVPipeEnd.pair()
        let other = PeerConnection(peerID: otherID, transport: otherEnd,
                                   peerIdentity: PeerIdentity(id: otherID, displayName: "Other"),
                                   localIdentity: cm.localIdentity, state: .connected)
        cm._setConnectionForTesting(peerID: otherID, other)
        cm.focus(on: otherID)
        XCTAssertEqual(cm.focusedPeerID, otherID)

        cm.sendMediaMessage(mediaType: .file, fileName: "a.txt", fileData: Data("hi".utf8),
                            mimeType: "text/plain", duration: nil, thumbnailData: nil, to: id)
        let arrived = await poll { peer.inbox.contains { $0.type == .mediaMessage } }
        XCTAssertTrue(arrived, "media reached the open chat's peer")
        XCTAssertFalse(otherEnd.sent.contains { $0.type == .mediaMessage || $0.type == .secureEnvelope },
                       "nothing went to the focused peer")
        XCTAssertNil(cm.chatManager.summary(forPeer: otherID).lastMessage, "nothing saved under the focused peer")
        XCTAssertNotNil(cm.chatManager.summary(forPeer: id).lastMessage)
        XCTAssertEqual(cm.focusedPeerID, otherID, "rendezvous connections never grab focus")
    }

    // MARK: I-3 device id must be unique among contacts

    func testDeviceIdSharedWithAnotherContactIsNotEligible() throws {
        let friend = try addFriend()
        let twin = TrustedContact(deviceId: friend.deviceId!, displayName: "Twin",
                                  identityPublicKey: RendezvousTestIdentity().raw, trustLevel: .linked)
        cm.trustedContactStore.add(twin)
        cm.trustedContactStore.setAccountBinding(for: twin.id, accountId: "ACtwin\(UUID().uuidString.prefix(4))")
        let all = cm.trustedContactStore.contacts
        let current = try XCTUnwrap(cm.trustedContactStore.find(byId: friend.id))
        XCTAssertFalse(TrustedContactStore.isRendezvousEligible(current, among: all))
        XCTAssertTrue(RendezvousManager.activeContacts(all).isEmpty)
        XCTAssertNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: current))
    }

    // MARK: m-2 dead direct connections don't block

    func testDeadDirectConnectionDoesNotBlock() throws {
        cm.rendezvousSecureChannelTimeoutNanoseconds = 10_000_000_000
        let friend = try addFriend()
        let dead = PeerConnection(peerID: friend.deviceId!, transport: RVPipeEnd.pair().0,
                                  peerIdentity: PeerIdentity(id: friend.deviceId!, displayName: "Mika"),
                                  localIdentity: cm.localIdentity, state: .failed(reason: "gone"))
        cm._setConnectionForTesting(peerID: friend.deviceId!, dead)
        XCTAssertFalse(cm.rendezvousBridge.hasDirectConnection(to: friend))
        XCTAssertNotNil(cm.installRendezvousConnection(transport: RVPipeEnd.pair().0, contact: friend))
    }

    // MARK: m-3 relay identity swap notifies the manager

    func testRelayHelloIdentitySwapNotifiesDirectConnectionsChanged() async throws {
        let relayID = "relay-\(UUID().uuidString.prefix(6))"
        touched.append(relayID)
        let relay = PeerConnection(peerID: relayID, transport: RVPipeEnd.pair().0,
                                   peerIdentity: PeerIdentity(id: relayID, displayName: "Relay Peer", supportsSecureChannel: true),
                                   localIdentity: cm.localIdentity, state: .connected)
        relay.isRelayPlaceholder = true
        cm._setConnectionForTesting(peerID: relayID, relay)
        try? await Task.sleep(nanoseconds: 50_000_000)
        var calls = 0
        cm.rendezvousBridge.onDirectConnectionsChanged = { calls += 1 }
        let real = PeerIdentity(id: "real-\(UUID().uuidString)", displayName: "Rhea",
                                identityPublicKey: RendezvousTestIdentity().raw)
        touched.append(real.id)
        cm.handleMessageForPeer(try PeerMessage.hello(identity: real), peerConnection: relay)
        XCTAssertEqual(relay.peerIdentity.id, real.id)
        let fired = await poll { calls >= 1 }
        XCTAssertTrue(fired, "the manager learns the relay peer's real id")
    }

    // MARK: m-4 frames scoped to the sending peer

    func testReceiptForAnotherPeersMessageIsIgnored() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, peer, _) = try await installVerified(friend, key: key)
        let otherID = "other-\(UUID().uuidString)"
        touched.append(otherID)
        let foreign = cm.chatManager.saveOutgoing(text: "not yours", peerID: otherID, peerName: "Other")
        cm.chatManager.flushAllPendingPersists()
        let receipt = try PeerMessage.messageReceipt(
            MessageReceiptPayload(messageIDs: [foreign.id], receiptType: .read, timestamp: Date()),
            senderID: friend.deviceId!)
        try await peer.send(receipt)
        try await peer.send(text("marker", from: friend.deviceId!))
        _ = await poll { (self.cm.chatManager.unreadCounts[friend.deviceId!] ?? 0) >= 1 }
        cm.chatManager.loadMessages(forPeer: otherID)
        XCTAssertEqual(cm.chatManager.messages.first { $0.id == foreign.id }?.status, foreign.status,
                       "a peer cannot mark another thread's message")
    }

    func testReactionToAMessageOutsideThatPeersThreadIsIgnored() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let (_, peer, _) = try await installVerified(friend, key: key)
        let otherID = "other-\(UUID().uuidString)"
        touched.append(otherID)
        let foreign = cm.chatManager.saveOutgoing(text: "not yours", peerID: otherID, peerName: "Other")
        cm.chatManager.loadMessages(forPeer: otherID)   // the open chat is the OTHER peer's
        try await peer.send(try PeerMessage.reaction(
            ReactionPayload(messageID: foreign.id, emoji: "👍", action: .add, timestamp: Date()), senderID: friend.deviceId!))
        try await peer.send(text("marker", from: friend.deviceId!))
        _ = await poll { (self.cm.chatManager.unreadCounts[friend.deviceId!] ?? 0) >= 1 }
        XCTAssertNil(cm.chatManager.messages.first { $0.id == foreign.id }?.reactions)
    }

    func testGroupTextFromRendezvousRequiresLocalMembership() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let id = friend.deviceId!
        let (_, peer, _) = try await installVerified(friend, key: key)
        let unknownGroup = "G-\(UUID().uuidString)"
        try await peer.send(try PeerMessage.textMessage(
            TextMessagePayload(text: "spoofed group", groupID: unknownGroup, senderName: "Mika", messageID: UUID().uuidString),
            senderID: id))
        try await peer.send(text("marker", from: id))
        _ = await poll { (self.cm.chatManager.unreadCounts[id] ?? 0) >= 1 }
        XCTAssertFalse(cm.chatManager.groupMessages.contains { $0.groupID == unknownGroup })

        cm.groupStore.add(name: "Ours \(UUID().uuidString.prefix(4))")
        let group = try XCTUnwrap(cm.groupStore.groups.last)
        defer { cm.groupStore.remove(id: group.id) }
        cm.groupStore.addDevice(id, toGroup: group.id)
        try await peer.send(try PeerMessage.textMessage(
            TextMessagePayload(text: "member says hi", groupID: group.id, senderName: "Mika", messageID: UUID().uuidString),
            senderID: id))
        let saved = await poll { self.cm.chatManager.groupMessages.contains { $0.groupID == group.id } }
        XCTAssertTrue(saved, "a member of a local group is accepted")
    }

    // MARK: m-5 group sends: rendezvous friends neither counted nor sent to

    func testGroupBroadcastSkipsRendezvousFriendsAndNeverHangs() async throws {
        let key = RendezvousTestIdentity()
        let friend = try addFriend(key: key)
        let rvID = friend.deviceId!
        let (_, peer, _) = try await installVerified(friend, key: key)

        let directID = "direct-\(UUID().uuidString)"
        touched.append(directID)
        let (directEnd, _) = RVPipeEnd.pair()
        let direct = PeerConnection(peerID: directID, transport: directEnd,
                                    peerIdentity: PeerIdentity(id: directID, displayName: "D"),
                                    localIdentity: cm.localIdentity, state: .connected)
        cm._setConnectionForTesting(peerID: directID, direct)

        cm.groupStore.add(name: "Mixed \(UUID().uuidString.prefix(4))")
        let created = try XCTUnwrap(cm.groupStore.groups.last)
        defer { cm.groupStore.remove(id: created.id) }
        for d in [rvID, directID, "offline-\(UUID().uuidString)"] { cm.groupStore.addDevice(d, toGroup: created.id) }
        let group = try XCTUnwrap(cm.groupStore.groups.first { $0.id == created.id })

        XCTAssertEqual(cm.groupConnectionStatus(group).connected, 1, "only the direct member counts")
        cm.broadcastTextMessage("hi all", toGroup: group.id)
        let sent = await poll {
            self.cm.chatManager.groupMessages.last { $0.groupID == group.id && $0.isOutgoing }?.status == .sent
        }
        XCTAssertTrue(sent, "status: \(String(describing: cm.chatManager.groupMessages.last?.status))")
        XCTAssertTrue(directEnd.sent.contains { $0.type == .textMessage })
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(peer.inbox.contains { $0.type == .textMessage }, "rendezvous friend gets no group send")
    }
}
