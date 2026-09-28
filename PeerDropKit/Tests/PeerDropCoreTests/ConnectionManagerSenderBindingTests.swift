// PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerSenderBindingTests.swift
//
// Issue #161: inbound frames were routed by the self-reported
// `PeerMessage.senderID` (`connections[senderID]`), not by the transport
// they arrived on. A stranger still waiting on the consent sheet — or any
// connected peer — could claim `senderID = C` and have its frame processed
// as C's (edit/delete C's messages, inject into C's thread, re-point C's
// identity, tear down C's connection).
//
// These tests drive the real ConnectionManager over loopback TCP
// (NWListener + NWConnection with the PeerDrop framer, no TLS).
import XCTest
import Network
@testable import PeerDropCore
@testable import PeerDropTransport
import PeerDropProtocol
@testable import PeerDropSecurity
import CryptoKit

/// Thread-safe flag set when the client's socket sees the far end close.
private final class CloseObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _closed = false
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    func markClosed() { lock.lock(); _closed = true; lock.unlock() }
}

/// Frame types a fake acceptor received.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _types: [MessageType] = []
    var types: [MessageType] { lock.lock(); defer { lock.unlock() }; return _types }
    func append(_ t: MessageType) { lock.lock(); _types.append(t); lock.unlock() }
    private var _closed = false
    /// The fake acceptor's socket was closed (by us or the manager).
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    func markClosed() { lock.lock(); _closed = true; lock.unlock() }
}

/// A one-way latch the test opens to let a fake acceptor proceed.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func openGate() { lock.lock(); open = true; lock.unlock() }
}

/// Server-side sockets accepted by test listeners, cancelled in tearDown.
private final class SocketBag: @unchecked Sendable {
    private let lock = NSLock()
    private var conns: [NWConnection] = []
    func add(_ c: NWConnection) { lock.lock(); conns.append(c); lock.unlock() }
    func cancelAll() { lock.lock(); let cs = conns; conns = []; lock.unlock(); cs.forEach { $0.cancel() } }
}

/// In-memory LocalSecureChannel identity for the test-side client.
private struct EphemeralChannelIdentity: LocalChannelIdentity {
    let priv = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Curve25519.KeyAgreement.PublicKey { priv.publicKey }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try priv.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

@MainActor
final class ConnectionManagerSenderBindingTests: XCTestCase {
    private var cm: ConnectionManager!
    private var listeners: [NWListener] = []
    private var clients: [NWConnection] = []
    private var keyDir: URL!
    private var touchedPeers: [String] = []
    private var hookCalls: [(peerID: String, text: String)] = []
    private let socketBag = SocketBag()

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmbind-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmbindtest")
        // Never let a test write the real system pasteboard.
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        cm = ConnectionManager()
        hookCalls = []
        cm.onTextMessageReceived = { [weak self] peerID, text in
            self?.hookCalls.append((peerID, text))
        }
    }

    override func tearDown() async throws {
        for c in clients { c.cancel() }
        clients = []
        socketBag.cancelAll()
        for l in listeners { l.cancel() }
        listeners = []
        for peer in touchedPeers {
            cm.chatManager.deleteMessages(forPeer: peer)
            cm.deviceStore.remove(id: peer)
        }
        touchedPeers = []
        cm = nil
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func identity(_ name: String, id: String = UUID().uuidString) -> PeerIdentity {
        PeerIdentity(id: id, displayName: name, supportsSecureChannel: false)
    }

    /// Install an already-connected victim peer C (no real socket).
    @discardableResult
    private func installVictim(_ ident: PeerIdentity) -> PeerConnection {
        let dummy = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let pc = PeerConnection(
            peerID: ident.id,
            connection: dummy,
            peerIdentity: ident,
            localIdentity: cm.localIdentity,
            state: .connected
        )
        cm._setConnectionForTesting(peerID: ident.id, pc)
        touchedPeers.append(ident.id)
        return pc
    }

    /// Seed an incoming 1:1 message from `peerID` and return its id.
    private func seedMessage(from peerID: String, text: String) -> String {
        let id = "seed-\(UUID().uuidString)"
        _ = cm.chatManager.saveIncoming(text: text, peerID: peerID, peerName: peerID, messageID: id)
        cm.chatManager.flushAllPendingPersists()
        return id
    }

    private func storedText(peerID: String, messageID: String) -> String? {
        cm.chatManager.flushAllPendingPersists()
        cm.chatManager.loadMessages(forPeer: peerID)
        return cm.chatManager.messages.first { $0.id == messageID }?.text
    }

    private func poll(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Every test socket gets its own SERIAL queue: on the concurrent
    /// `.global()` queue Network can deliver `.preparing`/`.ready` out of
    /// order and leave `state` stuck at `.preparing` (see WaitReadyHandlerTests).
    nonisolated private static func socketQueue() -> DispatchQueue {
        DispatchQueue(label: "test.cmbind.socket", qos: .userInitiated)
    }

    private func startAndWaitReady(_ connection: NWConnection) async throws {
        connection.start(queue: Self.socketQueue())
        try await connection.waitReady(timeout: 5)
    }

    /// Listen on a random port BELOW the ephemeral range (49152+). On
    /// loopback, a listener on a recently used ephemeral port can make a later
    /// client's connect collide with a TIME_WAIT 4-tuple: the client then sits
    /// in `.waiting(EADDRINUSE)` (observed ~1 in 130 connects over repeated
    /// runs). A non-ephemeral listener port can never be a client's local port.
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
            if ready.isOpen {
                listeners.append(l)
                return port.rawValue
            }
            l.cancel() // port taken; try another
        }
        throw NWConnectionError.timeout
    }

    /// A listener whose inbound connections go through ConnectionManager's
    /// real acceptor path; returns a connected client socket.
    private func dialManager() async throws -> NWConnection {
        // The unstarted inbound socket goes straight to the production
        // acceptor path, exactly as the Bonjour listener hands it over.
        let port = try await startListener { [cm] conn in
            Task { @MainActor in cm?._handleIncomingConnectionForTesting(conn) }
        }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .peerDrop())
        clients.append(client)
        try await startAndWaitReady(client)
        return client
    }

    /// Dial the manager as `ident` and wait until the consent sheet is up.
    private func pendingStranger(_ ident: PeerIdentity) async throws -> NWConnection {
        let client = try await dialManager()
        try await client.sendMessage(try PeerMessage.hello(identity: ident))
        try await client.sendMessage(PeerMessage.connectionRequest(senderID: ident.id))
        let pending = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == ident.id }
        XCTAssertTrue(pending, "consent sheet never appeared for \(ident.displayName) state=\(cm.state) toast=\(String(describing: cm.statusToast)) conns=\(cm.connections.count)")
        return client
    }

    /// Dial as `ident`, get accepted, and consume the acceptor's accept+hello.
    private func connectedPeer(_ ident: PeerIdentity) async throws -> NWConnection {
        let client = try await pendingStranger(ident)
        touchedPeers.append(ident.id)
        cm.acceptConnection()
        let accept = try await client.receiveMessage(timeout: 5)
        XCTAssertEqual(accept.type, .connectionAccept)
        let hello = try await client.receiveMessage(timeout: 5)
        XCTAssertEqual(hello.type, .hello)
        let installed = await poll { self.cm.connections[ident.id] != nil }
        XCTAssertTrue(installed, "accepted peer never installed")
        return client
    }

    /// Arm a non-blocking read that flags when the far end closes the socket.
    private func observeClose(_ client: NWConnection) -> CloseObserver {
        let obs = CloseObserver()
        func arm() {
            client.receiveMessage { content, _, isComplete, error in
                if error != nil || content == nil {
                    obs.markClosed()
                } else {
                    arm()
                }
            }
        }
        arm()
        return obs
    }

    private func text(_ body: String, senderID: String) throws -> PeerMessage {
        try PeerMessage.textMessage(
            TextMessagePayload(text: body, senderName: "x", messageID: UUID().uuidString),
            senderID: senderID
        )
    }

    // MARK: - (a) pre-consent stranger frames claiming to be C

    func test_preConsent_textMessageClaimingC_isNotStoredForC_andSocketCancelled() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let mallory = identity("Mallory")
        let client = try await pendingStranger(mallory)
        let closed = observeClose(client)

        try await client.sendMessage(try text("injected", senderID: carol.id))

        let didClose = await poll { closed.closed }
        XCTAssertTrue(didClose, "stranger's socket must be cancelled for a non-allowlisted pre-consent frame")
        XCTAssertNil(cm.chatManager.unreadCounts[carol.id], "pre-consent text was stored in C's thread")
        XCTAssertNil(cm.pendingIncomingRequest, "consent request should be dropped")
        XCTAssertTrue(hookCalls.isEmpty, "text hook must not fire pre-consent: \(hookCalls)")
    }

    func test_preConsent_messageEditClaimingC_doesNotRewriteCsMessage() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let seeded = seedMessage(from: carol.id, text: "original")
        let mallory = identity("Mallory")
        let client = try await pendingStranger(mallory)
        let closed = observeClose(client)

        let edit = try PeerMessage.messageEdit(
            MessageEditPayload(messageID: seeded, newText: "pwned"),
            senderID: carol.id
        )
        try await client.sendMessage(edit)

        let didClose = await poll { closed.closed }
        XCTAssertTrue(didClose, "stranger's socket must be cancelled")
        XCTAssertEqual(storedText(peerID: carol.id, messageID: seeded), "original")
    }

    func test_preConsent_clipboardSync_cancelsStranger() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let client = try await pendingStranger(identity("Mallory"))
        let closed = observeClose(client)

        let clip = try PeerMessage.clipboardSync(
            ClipboardSyncPayload(contentType: .text, textContent: "evil"),
            senderID: carol.id
        )
        try await client.sendMessage(clip)

        let didClose = await poll { closed.closed }
        XCTAssertTrue(didClose, "stranger's socket must be cancelled")
        XCTAssertNil(cm.pendingIncomingRequest)
    }

    func test_preConsent_helloClaimingC_doesNotRepointCsIdentity() async throws {
        let carol = identity("Carol")
        let carolPC = installVictim(carol)
        let client = try await pendingStranger(identity("Mallory"))
        let closed = observeClose(client)

        let fake = PeerIdentity(id: carol.id, displayName: "Mallory-as-Carol", supportsSecureChannel: false)
        try await client.sendMessage(try PeerMessage.hello(identity: fake))

        let didClose = await poll { closed.closed }
        XCTAssertTrue(didClose, "stranger's socket must be cancelled")
        XCTAssertEqual(carolPC.peerIdentity.displayName, "Carol")
        XCTAssertTrue(cm.connections[carol.id] === carolPC)
    }

    func test_preConsent_disconnectClaimingC_doesNotTearDownC_butDismissesRequest() async throws {
        let carol = identity("Carol")
        let carolPC = installVictim(carol)
        let client = try await pendingStranger(identity("Mallory"))

        try await client.sendMessage(PeerMessage.disconnect(senderID: carol.id))

        let dismissed = await poll { self.cm.pendingIncomingRequest == nil }
        XCTAssertTrue(dismissed, "disconnect from the pending initiator should dismiss the request")
        XCTAssertTrue(cm.connections[carol.id] === carolPC, "C's connection was torn down by a stranger")
        XCTAssertEqual(carolPC.state, .connected)
    }

    // MARK: - (b) allowlisted control frames from the pending initiator

    func test_preConsent_disconnectFromInitiator_dismissesConsent() async throws {
        let mallory = identity("Mallory")
        let client = try await pendingStranger(mallory)
        try await client.sendMessage(PeerMessage.disconnect(senderID: mallory.id))
        let dismissed = await poll { self.cm.pendingIncomingRequest == nil }
        XCTAssertTrue(dismissed)
    }

    func test_preConsent_connectionCancelFromInitiator_dismissesConsent() async throws {
        let mallory = identity("Mallory")
        let client = try await pendingStranger(mallory)
        try await client.sendMessage(PeerMessage.connectionCancel(senderID: mallory.id))
        let dismissed = await poll { self.cm.pendingIncomingRequest == nil }
        XCTAssertTrue(dismissed)
    }

    func test_preConsent_ping_isIgnored() async throws {
        let mallory = identity("Mallory")
        let client = try await pendingStranger(mallory)
        try await client.sendMessage(PeerMessage.ping(senderID: mallory.id))
        // Frames are handled in order: the cancel below is only processed (and
        // produces this toast) if the ping left the request pending.
        try await client.sendMessage(PeerMessage.connectionCancel(senderID: mallory.id))
        let dismissed = await poll { self.cm.pendingIncomingRequest == nil }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(cm.statusToast, "Connection request was cancelled", "ping must not dismiss the request")
    }

    // MARK: - (c) connected peer B claiming senderID = C

    func test_connectedPeer_spoofedSenderID_isAttributedToBoundPeer() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let seeded = seedMessage(from: carol.id, text: "original")
        let carolUnreadBefore = cm.chatManager.unreadCounts[carol.id]
        let bob = identity("Bob")
        let client = try await connectedPeer(bob)

        // First post-accept frame (may ride the consent monitor's in-flight read).
        try await client.sendMessage(try text("hi", senderID: bob.id))
        _ = await poll { self.cm.chatManager.unreadCounts[bob.id] == 1 }

        try await client.sendMessage(try text("spoofed", senderID: carol.id))
        let edit = try PeerMessage.messageEdit(
            MessageEditPayload(messageID: seeded, newText: "pwned"),
            senderID: carol.id
        )
        try await client.sendMessage(edit)
        // Sentinel: processed in order after the frames above.
        try await client.sendMessage(try text("sentinel", senderID: bob.id))

        let done = await poll { (self.cm.chatManager.unreadCounts[bob.id] ?? 0) >= 3 }
        XCTAssertTrue(done, "spoofed text should be attributed to B: unread[B]=\(String(describing: cm.chatManager.unreadCounts[bob.id]))")
        XCTAssertEqual(cm.chatManager.unreadCounts[carol.id], carolUnreadBefore, "B's frame landed in C's thread")
        XCTAssertEqual(storedText(peerID: carol.id, messageID: seeded), "original", "B rewrote C's message")
        XCTAssertFalse(hookCalls.contains { $0.peerID == carol.id }, "hook reported C for B's frame: \(hookCalls)")
        XCTAssertTrue(hookCalls.contains { $0.peerID == bob.id && $0.text == "spoofed" }, "hook: \(hookCalls)")
    }

    /// Connect B and get its first (consent-monitor handoff) frame through, so
    /// later frames ride B's own PeerConnection loop.
    private func connectedAndWarm(_ bob: PeerIdentity) async throws -> NWConnection {
        let client = try await connectedPeer(bob)
        try await client.sendMessage(try text("hi", senderID: bob.id))
        let warm = await poll { self.cm.chatManager.unreadCounts[bob.id] == 1 }
        XCTAssertTrue(warm, "B's first frame never arrived")
        return client
    }

    /// Send a sentinel text from B and wait for it: every frame B sent before
    /// it has then been processed.
    private func drain(_ client: NWConnection, bob: PeerIdentity) async throws {
        let before = cm.chatManager.unreadCounts[bob.id] ?? 0
        try await client.sendMessage(try text("sentinel", senderID: bob.id))
        let drained = await poll { (self.cm.chatManager.unreadCounts[bob.id] ?? 0) > before }
        XCTAssertTrue(drained, "sentinel from B never arrived")
    }

    func test_connectedPeer_groupTextClaimingC_isDropped() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let bob = identity("Bob")
        let client = try await connectedAndWarm(bob)
        let groupID = "grp-\(UUID().uuidString)"
        defer { cm.chatManager.deleteGroupMessages(forGroup: groupID) }

        let forged = try PeerMessage.textMessage(
            TextMessagePayload(text: "C said this", groupID: groupID, senderName: "Carol", messageID: UUID().uuidString),
            senderID: carol.id
        )
        try await client.sendMessage(forged)
        try await drain(client, bob: bob)

        cm.chatManager.loadGroupMessages(forGroup: groupID)
        XCTAssertFalse(cm.chatManager.groupMessages.contains { $0.senderID == carol.id },
                       "B injected a group message attributed to C")
    }

    func test_connectedPeer_groupReceiptClaimingC_isDropped() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let bob = identity("Bob")
        let client = try await connectedAndWarm(bob)
        let groupID = "grp-\(UUID().uuidString)"
        defer { cm.chatManager.deleteGroupMessages(forGroup: groupID) }
        let mine = cm.chatManager.saveGroupOutgoing(text: "to the group", groupID: groupID, localName: "me")
        cm.chatManager.flushAllPendingPersists()
        cm.chatManager.loadGroupMessages(forGroup: groupID)

        let receipt = try PeerMessage.messageReceipt(
            MessageReceiptPayload(messageIDs: [mine.id], receiptType: .read, timestamp: Date(),
                                  groupID: groupID, senderID: carol.id),
            senderID: carol.id
        )
        try await client.sendMessage(receipt)
        try await drain(client, bob: bob)

        let status = cm.chatManager.groupMessages.first { $0.id == mine.id }?.groupReadStatus
        XCTAssertFalse(status?.readBy.contains(carol.id) ?? false, "B marked the message read on C's behalf")
    }

    func test_connectedPeer_reactionClaimingC_isAttributedToB() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let bob = identity("Bob")
        let client = try await connectedAndWarm(bob)
        // Open B's conversation (reactions apply to the open one).
        let target = seedMessage(from: bob.id, text: "react to me")
        cm.chatManager.loadMessages(forPeer: bob.id)

        let reaction = try PeerMessage.reaction(
            ReactionPayload(messageID: target, emoji: "👍", action: .add, timestamp: Date()),
            senderID: carol.id
        )
        try await client.sendMessage(reaction)
        let applied = await poll { self.cm.chatManager.messages.first { $0.id == target }?.reactions?["👍"] != nil }
        XCTAssertTrue(applied, "reaction never applied")

        let senders = cm.chatManager.messages.first { $0.id == target }?.reactions?["👍"] ?? []
        XCTAssertFalse(senders.contains(carol.id), "B's reaction was recorded as C's")
        XCTAssertTrue(senders.contains(bob.id), "reaction should be recorded for the bound peer B: \(senders)")
    }

    // MARK: - (f) first frame after accept reaches the accepted connection

    func test_firstFrameAfterAccept_isDeliveredToAcceptedConnection() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        let bob = identity("Bob")
        let client = try await connectedPeer(bob)

        // Rides the consent monitor's still-pending read; claims to be C.
        try await client.sendMessage(try text("first", senderID: carol.id))

        let arrived = await poll { self.cm.chatManager.unreadCounts[bob.id] == 1 }
        XCTAssertTrue(arrived, "first post-accept frame was not delivered to B's connection")
        XCTAssertNil(cm.chatManager.unreadCounts[carol.id])
    }

    // MARK: - (e) hello identity swap on an established local connection

    func test_connectedPeer_helloIdentitySwap_isRejected() async throws {
        let carol = identity("Carol")
        let carolPC = installVictim(carol)
        let bob = identity("Bob")
        let client = try await connectedPeer(bob)
        let bobPC = try XCTUnwrap(cm.connections[bob.id])

        try await client.sendMessage(try text("hi", senderID: bob.id))
        _ = await poll { self.cm.chatManager.unreadCounts[bob.id] == 1 }

        let swap = PeerIdentity(id: carol.id, displayName: "Carol", supportsSecureChannel: false)
        try await client.sendMessage(try PeerMessage.hello(identity: swap))
        try await client.sendMessage(try text("sentinel", senderID: bob.id))
        _ = await poll { self.cm.chatManager.unreadCounts[bob.id] == 2 }

        XCTAssertEqual(bobPC.peerIdentity.id, bob.id, "B re-pointed its identity to C")
        XCTAssertEqual(bobPC.peerIdentity.displayName, "Bob")
        XCTAssertEqual(carolPC.peerIdentity.displayName, "Carol")
    }

    // MARK: - (d) initiator with an existing connection dials a second peer

    enum FakeAcceptorScript {
        case accept, disconnectBeforeAccept
        /// Hold the dial (no reply) until `gate` opens, then accept.
        case acceptWhenOpened(Gate)
    }

    /// Plays a minimal acceptor: reads HELLO + request, then (per `script`)
    /// replies accept + hello(`reply`) or hangs up with `.disconnect`. Every
    /// later frame type it receives is recorded.
    private func startFakeAcceptor(
        replyingAs reply: PeerIdentity,
        script: FakeAcceptorScript = .accept,
        recorder: Recorder? = nil
    ) async throws -> UInt16 {
        let bag = socketBag
        return try await startListener { conn in
            bag.add(conn)
            conn.start(queue: Self.socketQueue())
            Task {
                defer { recorder?.markClosed() }
                do {
                    try await conn.waitReady(timeout: 5)
                    recorder?.append(try await conn.receiveMessage(timeout: 5).type) // hello
                    recorder?.append(try await conn.receiveMessage(timeout: 5).type) // connectionRequest
                    switch script {
                    case .accept:
                        try await conn.sendMessage(PeerMessage.connectionAccept(senderID: reply.id))
                        try await conn.sendMessage(try PeerMessage.hello(identity: reply))
                        // Sync point: the pong comes back from the installed
                        // PeerConnection, after anything sent before install.
                        try await conn.sendMessage(PeerMessage.ping(senderID: reply.id))
                    case .disconnectBeforeAccept:
                        try await conn.sendMessage(PeerMessage.disconnect(senderID: reply.id))
                    case .acceptWhenOpened(let gate):
                        // Nothing is expected while held; a read error means
                        // the dialer hung up on us.
                        let watch = Task {
                            do { _ = try await conn.receiveMessage(timeout: 60) } catch { recorder?.markClosed() }
                        }
                        while !gate.isOpen {
                            if recorder?.closed == true { throw NWConnectionError.cancelled }
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                        watch.cancel()
                        try await conn.sendMessage(PeerMessage.connectionAccept(senderID: reply.id))
                        try await conn.sendMessage(try PeerMessage.hello(identity: reply))
                        try await conn.sendMessage(PeerMessage.ping(senderID: reply.id))
                    }
                    while true {
                        let m = try await conn.receiveMessage(timeout: 30)
                        recorder?.append(m.type)
                    }
                } catch {}
            }
        }
    }

    func test_initiatorWithExistingConnection_createsPeerConnectionForSecondPeer() async throws {
        let carol = identity("Carol")
        installVictim(carol)
        cm.focus(on: carol.id)
        XCTAssertEqual(cm.focusedPeerID, carol.id)

        let dave = identity("Dave")
        touchedPeers.append(dave.id)
        let port = try await startFakeAcceptor(replyingAs: dave)
        cm.requestConnection(to: DiscoveredPeer(
            id: "manual-dave", displayName: "Dave",
            endpoint: .manual(host: "127.0.0.1", port: port), source: .manual
        ))

        let installed = await poll(timeout: 5) { self.cm.connections[dave.id] != nil }
        XCTAssertTrue(installed, "second dialed peer never got a PeerConnection (state=\(cm.state))")
    }

    func test_initiator_helloClaimingExistingPeer_doesNotRepointIt() async throws {
        let carol = identity("Carol")
        let carolPC = installVictim(carol)
        cm.focus(on: carol.id)

        // The dialed peer answers with C's id.
        let impostor = PeerIdentity(id: carol.id, displayName: "Impostor", supportsSecureChannel: false)
        let recorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: impostor, recorder: recorder)
        cm.requestConnection(to: DiscoveredPeer(
            id: "manual-imp", displayName: "Imp",
            endpoint: .manual(host: "127.0.0.1", port: port), source: .manual
        ))

        // The refusal hangs up on the impostor.
        let refused = await poll(timeout: 5) { recorder.closed }
        XCTAssertTrue(refused, "impostor dial was never refused: \(recorder.types)")
        XCTAssertTrue(cm.connections[carol.id] === carolPC, "existing connection was replaced")
        XCTAssertEqual(carolPC.peerIdentity.displayName, "Carol", "existing connection's identity was re-pointed")
    }

    // MARK: - Review round (#161 I-1..I-3, M-1..M-3)

    /// A connected loopback pair: (server-side socket, client socket), both ready.
    private func rawPair() async throws -> (server: NWConnection, client: NWConnection) {
        let serverBox = ServerSocketBox()
        let bag = socketBag
        let port = try await startListener { conn in
            bag.add(conn)
            conn.stateUpdateHandler = { state in
                if case .ready = state { serverBox.set(conn) }
            }
            conn.start(queue: Self.socketQueue())
        }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .peerDrop())
        clients.append(client)
        try await startAndWaitReady(client)
        let got = await poll { serverBox.connection != nil }
        XCTAssertTrue(got, "server side never became ready")
        return (try XCTUnwrap(serverBox.connection), client)
    }

    /// Send a sentinel text and wait until `key`'s unread count moves.
    private func drain(_ client: NWConnection, unreadKey key: String) async throws {
        let before = cm.chatManager.unreadCounts[key] ?? 0
        try await client.sendMessage(try text("sentinel", senderID: key))
        let drained = await poll { (self.cm.chatManager.unreadCounts[key] ?? 0) > before }
        XCTAssertTrue(drained, "sentinel never arrived on \(key)")
    }

    private func dial(_ port: UInt16, id: String) {
        cm.requestConnection(to: DiscoveredPeer(
            id: id, displayName: id,
            endpoint: .manual(host: "127.0.0.1", port: port), source: .manual
        ))
    }

    // I-1: relay placeholder status is structural, not a string prefix.

    func test_I1_localHelloWithRelayPrefixedID_isRefused() async throws {
        let evil = PeerIdentity(id: "relay-evil", displayName: "Friendly", supportsSecureChannel: false)
        let client = try await dialManager()
        let closed = observeClose(client)
        try await client.sendMessage(try PeerMessage.hello(identity: evil))
        try await client.sendMessage(PeerMessage.connectionRequest(senderID: evil.id))

        let didClose = await poll { closed.closed }
        XCTAssertTrue(didClose, "a local peer claiming a relay-* id must be hung up on")
        XCTAssertNil(cm.pendingIncomingRequest)
        XCTAssertNil(cm.connections["relay-evil"])
    }

    func test_I1_initiatorHelloWithRelayPrefixedID_isRefused() async throws {
        let evil = PeerIdentity(id: "relay-evil2", displayName: "Friendly", supportsSecureChannel: false)
        let recorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: evil, recorder: recorder)
        dial(port, id: "manual-evil")
        // The refusal hangs up on the dialed peer.
        let refused = await poll(timeout: 5) { recorder.closed }
        XCTAssertTrue(refused, "relay-id dial was never refused: \(recorder.types)")
        XCTAssertNil(cm.connections["relay-evil2"], "dialed peer installed under a relay-* id")
    }

    func test_I1_relayPlaceholder_swapsIdentityExactlyOnce() async throws {
        let (server, client) = try await rawPair()
        let pc = cm._installRelayPlaceholderForTesting(roomCode: "R1\(UUID().uuidString.prefix(4))", connection: server)
        touchedPeers.append(pc.id)
        let real = identity("Rita")
        try await client.sendMessage(try PeerMessage.hello(identity: real))
        let swapped = await poll { pc.peerIdentity.id == real.id }
        XCTAssertTrue(swapped, "relay placeholder should take the peer's real identity")

        let other = identity("Other")
        try await client.sendMessage(try PeerMessage.hello(identity: other))
        try await drain(client, unreadKey: pc.id)
        XCTAssertEqual(pc.peerIdentity.id, real.id, "second HELLO re-pointed the relay connection")
    }

    func test_I1_m2_relaySwapToIDInUse_tearsDownRelayConnection() async throws {
        let carol = identity("Carol")
        let carolPC = installVictim(carol)
        let (server, client) = try await rawPair()
        let closed = observeClose(client)
        let pc = cm._installRelayPlaceholderForTesting(roomCode: "R2\(UUID().uuidString.prefix(4))", connection: server)
        touchedPeers.append(pc.id)
        let placeholderID = pc.peerIdentity.id

        let asCarol = PeerIdentity(id: carol.id, displayName: "Carol", supportsSecureChannel: false)
        try await client.sendMessage(try PeerMessage.hello(identity: asCarol))

        // Not left behind as a silently degraded "Relay Peer": torn down, with a toast.
        let tornDown = await poll { self.cm.connections[pc.id] == nil && closed.closed }
        XCTAssertTrue(tornDown, "relay connection with a refused identity should be torn down")
        XCTAssertEqual(pc.peerIdentity.id, placeholderID, "relay connection took over C's id")
        XCTAssertTrue(cm.connection(for: carol.id) === carolPC)
        XCTAssertEqual(cm.statusToast, String(localized: "Relay connection closed: this device is already connected"))
    }

    // I-2: per-connection consent handoff.

    func test_I2_backToBackAccepts_bothDeliverTheirFirstFrame() async throws {
        let alice = identity("Alice")
        let a = try await connectedPeer(alice)
        let bob = identity("Bob")
        let b = try await connectedPeer(bob)

        try await a.sendMessage(try text("A1", senderID: alice.id))
        try await b.sendMessage(try text("B1", senderID: bob.id))

        let both = await poll {
            self.cm.chatManager.unreadCounts[alice.id] == 1 && self.cm.chatManager.unreadCounts[bob.id] == 1
        }
        XCTAssertTrue(both, "first frames: A=\(String(describing: cm.chatManager.unreadCounts[alice.id])) B=\(String(describing: cm.chatManager.unreadCounts[bob.id]))")
    }

    func test_I2_frameArrivingBeforeInstall_isBufferedThenDelivered() async throws {
        cm._acceptInstallDelayNanosForTesting = 400_000_000
        let bob = identity("Bob")
        touchedPeers.append(bob.id)
        let client = try await pendingStranger(bob)
        cm.acceptConnection()
        let accept = try await client.receiveMessage(timeout: 5)
        XCTAssertEqual(accept.type, .connectionAccept)
        // Sent before the acceptor has installed B's PeerConnection.
        try await client.sendMessage(try text("early", senderID: bob.id))
        XCTAssertNil(cm.connections[bob.id], "precondition: not installed yet")

        let delivered = await poll { self.cm.chatManager.unreadCounts[bob.id] == 1 }
        XCTAssertTrue(delivered, "frame that beat the install was lost")
        XCTAssertEqual(cm._consentHandoffCountForTesting, 0)
    }

    func test_I2_noHandoffLeftAfterMonitorExits() async throws {
        let bob = identity("Bob")
        let b = try await connectedPeer(bob)
        try await b.sendMessage(try text("hi", senderID: bob.id))
        _ = await poll { self.cm.chatManager.unreadCounts[bob.id] == 1 }
        let clearedAfterDelivery = await poll { self.cm._consentHandoffCountForTesting == 0 }
        XCTAssertTrue(clearedAfterDelivery, "handoff kept after its frame was delivered")

        let carol = identity("Carol")
        let c = try await connectedPeer(carol)
        c.cancel() // hang up without ever sending
        let clearedAfterClose = await poll { self.cm._consentHandoffCountForTesting == 0 }
        XCTAssertTrue(clearedAfterClose, "handoff kept after the socket closed")

        let mallory = identity("Mallory")
        _ = try await pendingStranger(mallory)
        cm.rejectConnection()
        let clearedAfterReject = await poll { self.cm._consentHandoffCountForTesting == 0 }
        XCTAssertTrue(clearedAfterReject)
    }

    // I-3 / M-1: dialing a second peer from the real `.connected` state.

    func test_I3_secondDialWhileConnected_keepsFirstConnection_andSendsNoCancel() async throws {
        let carol = identity("Carol")
        let carolClient = try await connectedAndWarm(carol)
        XCTAssertEqual(cm.state, .connected)
        let carolClosed = observeClose(carolClient)

        let dave = identity("Dave")
        touchedPeers.append(dave.id)
        let recorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: dave, recorder: recorder)
        dial(port, id: "manual-dave")

        let installed = await poll(timeout: 5) { self.cm.connections[dave.id] != nil }
        XCTAssertTrue(installed, "second dialed peer never installed (state=\(cm.state))")
        // Sync: Dave's installed PeerConnection answers the acceptor's ping;
        // anything sent to Dave before install precedes that pong.
        let ponged = await poll(timeout: 5) { recorder.types.contains(.pong) }
        XCTAssertTrue(ponged, "no pong from Dave's PeerConnection: \(recorder.types)")
        XCTAssertFalse(recorder.types.contains(.connectionCancel), "acceptor was sent connectionCancel: \(recorder.types)")
        // Carol's socket still carries traffic after the dial.
        try await drain(carolClient, unreadKey: carol.id)
        XCTAssertFalse(carolClosed.closed, "dialing a second peer killed the first peer's socket")
        XCTAssertNotNil(cm.connections[carol.id])
        XCTAssertEqual(cm.connections[carol.id]?.state, .connected)
        XCTAssertEqual(cm.state, .connected)
    }

    func test_M1_dialedPeerDisconnectBeforeAccept_leavesExistingConnectionAlone() async throws {
        let carol = identity("Carol")
        let carolClient = try await connectedAndWarm(carol)
        XCTAssertEqual(cm.state, .connected)
        let carolClosed = observeClose(carolClient)

        let dave = identity("Dave")
        let recorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: dave, script: .disconnectBeforeAccept, recorder: recorder)
        dial(port, id: "manual-dave")
        // The disconnect ends the dial: we hang up on Dave.
        let ended = await poll(timeout: 5) { recorder.closed }
        XCTAssertTrue(ended, "dial was not ended by the peer's disconnect: \(recorder.types)")

        XCTAssertEqual(cm.state, .connected, "a dialed peer's pre-accept disconnect failed the whole session")
        XCTAssertNotNil(cm.connections[carol.id])
        try await drain(carolClient, unreadKey: carol.id)
        XCTAssertFalse(carolClosed.closed)
        XCTAssertNil(cm.connections[dave.id])
    }

    // M-2: duplicate checks cover aliases (`connection(for:)`).

    private func installAliasedRelay(for ident: PeerIdentity) -> PeerConnection {
        let pc = PeerConnection(
            peerID: "relay-ABC\(UUID().uuidString.prefix(4))",
            connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp),
            peerIdentity: ident, localIdentity: cm.localIdentity, state: .connected
        )
        cm._setConnectionForTesting(peerID: pc.id, pc)
        touchedPeers.append(pc.id)
        return pc
    }

    func test_M2_accept_refusesIDAliasedByAnotherConnection() async throws {
        let carol = identity("Carol")
        let relayPC = installAliasedRelay(for: carol)
        XCTAssertTrue(cm.connection(for: carol.id) === relayPC)

        let fake = PeerIdentity(id: carol.id, displayName: "Carol", supportsSecureChannel: false)
        let client = try await pendingStranger(fake)
        let closed = observeClose(client)
        cm.acceptConnection()
        let didClose = await poll { closed.closed }

        XCTAssertTrue(didClose, "duplicate of an aliased id should be refused")
        XCTAssertNil(cm.connections[carol.id])
        XCTAssertTrue(cm.connection(for: carol.id) === relayPC, "stranger hijacked connection(for:)")
    }

    func test_M2_initiator_refusesIDAliasedByAnotherConnection() async throws {
        let carol = identity("Carol")
        let relayPC = installAliasedRelay(for: carol)
        let fake = PeerIdentity(id: carol.id, displayName: "Carol", supportsSecureChannel: false)
        let recorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: fake, recorder: recorder)
        dial(port, id: "manual-fake")
        let refused = await poll(timeout: 5) { recorder.closed }
        XCTAssertTrue(refused, "aliased-id dial was never refused: \(recorder.types)")

        XCTAssertNil(cm.connections[carol.id])
        XCTAssertTrue(cm.connection(for: carol.id) === relayPC)
    }

    // M-3: a real `.secureHandshake` as the first post-accept frame, with the
    // first envelope sent the instant the client side is secured.

    func test_M3_secureHandshakeFirstFrame_securesAndDeliversImmediateEnvelope() async throws {
        var failures: [String] = []
        for i in 0..<8 {
            let key = EphemeralChannelIdentity()
            let me = PeerIdentity(id: UUID().uuidString, displayName: "Sec\(i)",
                                  identityPublicKey: key.publicKey.rawRepresentation,
                                  supportsSecureChannel: true)
            touchedPeers.append(me.id)
            let c = try await pendingStranger(me)
            cm.acceptConnection()
            _ = try await c.receiveMessage(timeout: 5) // accept
            let helloMsg = try await c.receiveMessage(timeout: 5)
            let serverIdent = try JSONDecoder().decode(PeerIdentity.self, from: try XCTUnwrap(helloMsg.payload))
            let clientPC = PeerConnection(peerID: serverIdent.id, connection: c, peerIdentity: serverIdent,
                                          localIdentity: me, state: .connected)
            clientPC.onMessageReceived = { _ in }
            // Our handshake is the first frame after accept.
            await clientPC.startSecureChannelNegotiation(peerSupportsSecureChannel: true, identity: key)
            let reader = Task { @MainActor in
                while let m = try? await c.receiveMessage(timeout: 10) {
                    if m.type == .secureHandshake {
                        try? await clientPC.handleIncomingSecureHandshake(m, identity: key)
                    } else {
                        try? await clientPC.handleIncomingMessage(m) // decrypts the bootstrap
                    }
                }
            }
            let secured = await poll(timeout: 5) { clientPC.secureChannelState == .secured }
            var sent = false
            if secured {
                // The Double-Ratchet initiator can send at once; the responder
                // must first receive the server's bootstrap envelope.
                let deadline = Date().addingTimeInterval(3)
                while !sent && Date() < deadline {
                    do { try await clientPC.sendMessage(try text("enc-\(i)", senderID: me.id)); sent = true }
                    catch { try await Task.sleep(nanoseconds: 20_000_000) }
                }
            }
            let got = await poll(timeout: 3) { (self.cm.chatManager.unreadCounts[me.id] ?? 0) >= 1 }
            let serverState = cm.connections[me.id]?.secureChannelState
            if !(secured && sent && got && serverState == .secured) {
                failures.append("i=\(i) initiator=\(String(describing: clientPC.secureChannel?.isInitiator)) sent=\(sent) client=\(clientPC.secureChannelState) server=\(String(describing: serverState)) got=\(got)")
            }
            await cm.disconnect(from: me.id)
            reader.cancel()
            c.cancel()
        }
        XCTAssertEqual(failures, [], "secure first-frame runs failed")
    }

    // MARK: - Pre-merge minors (m-3, m-5, m-6)

    func test_m3_dialWhileConsentSheetIsUp_isRefused() async throws {
        let mallory = identity("Mallory")
        let pending = try await pendingStranger(mallory)
        let dave = identity("Dave")
        let recorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: dave, recorder: recorder)

        dial(port, id: dave.id)

        XCTAssertEqual(cm.statusToast, String(localized: "Respond to the pending connection request first"))
        XCTAssertEqual(cm.state, .incomingRequest)
        XCTAssertEqual(cm.pendingIncomingRequest?.peerIdentity.id, mallory.id, "the consent request was lost")
        // The consent sheet still works afterwards.
        cm.acceptConnection()
        let accept = try await pending.receiveMessage(timeout: 5)
        XCTAssertEqual(accept.type, .connectionAccept, "the pending socket should still be alive")
        XCTAssertFalse(recorder.types.contains(.hello), "a dial went out while the consent sheet was up")
    }

    /// While `.connected` to Carol, we dial B and B dials us at the same time.
    /// Exactly one of the two sockets must survive, decided by id order.
    private func simultaneousDial(peerID: String) async throws
        -> (b: PeerIdentity, gate: Gate, dialRecorder: Recorder, incoming: NWConnection) {
        let carol = identity("Carol")
        _ = try await connectedAndWarm(carol)
        XCTAssertEqual(cm.state, .connected)

        let b = PeerIdentity(id: peerID, displayName: "B", supportsSecureChannel: false)
        touchedPeers.append(b.id)
        let gate = Gate()
        let dialRecorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: b, script: .acceptWhenOpened(gate), recorder: dialRecorder)
        dial(port, id: b.id) // Bonjour publishes the identity id as the peer id
        let reached = await poll { dialRecorder.types.contains(.connectionRequest) }
        XCTAssertTrue(reached, "our dial never reached B")

        // B's own dial arrives at us.
        let incoming = try await dialManager()
        try await incoming.sendMessage(try PeerMessage.hello(identity: b))
        try await incoming.sendMessage(PeerMessage.connectionRequest(senderID: b.id))
        return (b, gate, dialRecorder, incoming)
    }

    func test_m5_simultaneousDial_largerLocalID_keepsOutgoing() async throws {
        // B's id sorts below ours: we are the initiator and refuse B's dial.
        let (b, gate, dialRecorder, incoming) = try await simultaneousDial(peerID: "00000000-0000-0000-0000-000000000000")
        let incomingClosed = observeClose(incoming)
        let refused = await poll { incomingClosed.closed }
        XCTAssertTrue(refused, "B's simultaneous dial should be refused")
        XCTAssertNil(cm.pendingIncomingRequest)
        XCTAssertFalse(dialRecorder.closed, "our own dial to B was dropped")

        gate.openGate() // B accepts our dial
        let installed = await poll(timeout: 5) { self.cm.connections[b.id] != nil }
        XCTAssertTrue(installed, "our dial to B should complete")
        XCTAssertEqual(cm.connections.values.filter { $0.peerIdentity.id == b.id }.count, 1)
    }

    func test_m5_simultaneousDial_smallerLocalID_yieldsToIncoming() async throws {
        // B's id sorts above ours: B is the initiator; we drop our dial.
        let (b, _, dialRecorder, _) = try await simultaneousDial(peerID: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        let yielded = await poll { dialRecorder.closed }
        XCTAssertTrue(yielded, "our dial should be dropped in favour of B's")
        let consent = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == b.id }
        XCTAssertTrue(consent, "B's dial should reach the consent sheet")
    }

    func test_m6_secondAccept_doesNotStealFocus() async throws {
        let carol = identity("Carol")
        _ = try await connectedPeer(carol)
        XCTAssertEqual(cm.focusedPeerID, carol.id)
        let bob = identity("Bob")
        _ = try await connectedPeer(bob)
        XCTAssertEqual(cm.focusedPeerID, carol.id, "a new incoming connection stole the UI focus")
    }

    func test_mc_userDial_focusesTheDialedPeer() async throws {
        let carol = identity("Carol")
        _ = try await connectedAndWarm(carol)
        XCTAssertEqual(cm.focusedPeerID, carol.id)
        let dave = identity("Dave")
        touchedPeers.append(dave.id)
        let port = try await startFakeAcceptor(replyingAs: dave)
        dial(port, id: dave.id)
        let installed = await poll(timeout: 5) { self.cm.connections[dave.id] != nil }
        XCTAssertTrue(installed)
        XCTAssertEqual(cm.focusedPeerID, dave.id, "the peer the user chose to dial should get the focus")
    }

    // MARK: - Final review (I-A, m-b, m-d)

    private func deviceRecord(_ id: String) -> DeviceRecord? {
        cm.deviceStore.records.first { $0.id == id }
    }

    func test_IA_secondAccept_recordsTheNewPeerUnderItsOwnName() async throws {
        let carol = identity("Carol")
        _ = try await connectedPeer(carol)
        let bob = identity("Bob")
        _ = try await connectedPeer(bob)
        XCTAssertEqual(cm.focusedPeerID, carol.id, "precondition: focus stays on Carol")
        XCTAssertEqual(deviceRecord(bob.id)?.displayName, "Bob", "the second accepted peer was not recorded as itself")
        XCTAssertEqual(deviceRecord(carol.id)?.displayName, "Carol", "Carol's record was overwritten")
    }

    func test_IA_secondDial_recordsTheNewPeerUnderItsOwnName() async throws {
        let carol = identity("Carol")
        _ = try await connectedAndWarm(carol)
        let dave = identity("Dave")
        touchedPeers.append(dave.id)
        let port = try await startFakeAcceptor(replyingAs: dave)
        dial(port, id: dave.id)
        let installed = await poll(timeout: 5) { self.cm.connections[dave.id] != nil }
        XCTAssertTrue(installed)
        XCTAssertEqual(deviceRecord(dave.id)?.displayName, "Dave", "the dialed peer was recorded under another name")
        XCTAssertEqual(deviceRecord(carol.id)?.displayName, "Carol", "Carol's record was overwritten")
    }

    func test_mb_simultaneousYieldFromIdle_firesNoDisconnectedTransition() async throws {
        var states: [ConnectionState] = []
        let sub = cm.$state.sink { states.append($0) }
        defer { sub.cancel() }

        let b = PeerIdentity(id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", displayName: "B", supportsSecureChannel: false)
        touchedPeers.append(b.id)
        let dialRecorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: b, script: .acceptWhenOpened(Gate()), recorder: dialRecorder)
        dial(port, id: b.id)
        let reached = await poll { dialRecorder.types.contains(.connectionRequest) }
        XCTAssertTrue(reached)

        let incoming = try await dialManager()
        try await incoming.sendMessage(try PeerMessage.hello(identity: b))
        try await incoming.sendMessage(PeerMessage.connectionRequest(senderID: b.id))
        let consent = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == b.id }
        XCTAssertTrue(consent, "we should yield to B's dial")
        XCTAssertFalse(states.contains(.disconnected), "spurious .disconnected on the yield path: \(states)")
        XCTAssertEqual(cm.state, .incomingRequest)
    }

    /// Dial a peer that hangs up, so `lastConnectedPeer` is set for reconnect().
    private func primeReconnectTarget() async throws -> Recorder {
        let dave = identity("Dave")
        let recorder = Recorder()
        let port = try await startFakeAcceptor(replyingAs: dave, script: .disconnectBeforeAccept, recorder: recorder)
        dial(port, id: dave.id)
        let ended = await poll(timeout: 5) { recorder.closed }
        XCTAssertTrue(ended)
        return recorder
    }

    func test_md_reconnectDuringConsent_doesNotConsumeABackoffAttempt() async throws {
        let recorder = try await primeReconnectTarget()
        _ = try await pendingStranger(identity("Mallory"))
        let before = await cm._reconnectAttemptCountForTesting()

        cm.reconnect()

        var consumed = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await cm._reconnectAttemptCountForTesting() != before { consumed = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(consumed, "reconnect() burned a back-off attempt while the consent sheet was up")
        XCTAssertEqual(recorder.types.filter { $0 == .hello }.count, 1, "reconnect dialed while the consent sheet was up")
    }

    func test_md_consentArrivingDuringBackoff_refundsTheAttempt() async throws {
        let recorder = try await primeReconnectTarget()
        let before = await cm._reconnectAttemptCountForTesting()

        cm.reconnect() // first back-off delay is ~1 s
        _ = try await pendingStranger(identity("Mallory"))

        // The retry fires after its ~1 s (±10 %) back-off delay; by 2.5 s it has
        // found the consent sheet up, skipped, and given the attempt back.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let after = await cm._reconnectAttemptCountForTesting()
        XCTAssertEqual(after, before, "the skipped retry's back-off attempt was not given back")
        XCTAssertEqual(recorder.types.filter { $0 == .hello }.count, 1, "reconnect dialed while the consent sheet was up")
        XCTAssertNotNil(cm.pendingIncomingRequest)
    }
}

private final class ServerSocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _c: NWConnection?
    var connection: NWConnection? { lock.lock(); defer { lock.unlock() }; return _c }
    func set(_ c: NWConnection) { lock.lock(); _c = c; lock.unlock() }
}
