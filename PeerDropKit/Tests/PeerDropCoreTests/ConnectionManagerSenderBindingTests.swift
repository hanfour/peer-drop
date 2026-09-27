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
import PeerDropSecurity

/// Thread-safe flag set when the client's socket sees the far end close.
private final class CloseObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _closed = false
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    func markClosed() { lock.lock(); _closed = true; lock.unlock() }
}

@MainActor
final class ConnectionManagerSenderBindingTests: XCTestCase {
    private var cm: ConnectionManager!
    private var listener: NWListener?
    private var clients: [NWConnection] = []
    private var keyDir: URL!
    private var touchedPeers: [String] = []
    private var hookCalls: [(peerID: String, text: String)] = []

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
        listener?.cancel()
        listener = nil
        for peer in touchedPeers { cm.chatManager.deleteMessages(forPeer: peer) }
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

    private func startListener(onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        let l = try NWListener(using: .peerDrop(), on: .any)
        l.newConnectionHandler = onConnection
        let ready = expectation(description: "listener ready")
        l.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        l.start(queue: .global(qos: .userInitiated))
        await fulfillment(of: [ready], timeout: 5)
        listener = l
        return try XCTUnwrap(l.port?.rawValue)
    }

    /// A listener whose inbound connections go through ConnectionManager's
    /// real acceptor path; returns a connected client socket.
    private func dialManager() async throws -> NWConnection {
        // Hand the socket over only once it is ready. NWConnection+Async's
        // `waitReady` can miss the ready transition when the connection is
        // still in `.setup` at call time on loopback (pre-existing race, not
        // part of #161), which made the acceptor path hang intermittently.
        // `handleIncomingConnection`'s own start() is then a no-op.
        let port = try await startListener { [cm] conn in
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.stateUpdateHandler = nil
                    Task { @MainActor in cm?._handleIncomingConnectionForTesting(conn) }
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .peerDrop())
        clients.append(client)
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()
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
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(cm.pendingIncomingRequest?.peerIdentity.id, mallory.id, "ping must not dismiss the request")
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

    /// Plays a minimal acceptor: reads HELLO + request, replies accept + hello(`reply`).
    private func startFakeAcceptor(replyingAs reply: PeerIdentity) async throws -> UInt16 {
        try await startListener { conn in
            conn.start(queue: .global(qos: .userInitiated))
            Task {
                do {
                    try await conn.waitReady()
                    _ = try await conn.receiveMessage(timeout: 5) // hello
                    _ = try await conn.receiveMessage(timeout: 5) // connectionRequest
                    try await conn.sendMessage(PeerMessage.connectionAccept(senderID: reply.id))
                    try await conn.sendMessage(try PeerMessage.hello(identity: reply))
                    // Keep the socket open for the rest of the test.
                    _ = try? await conn.receiveMessage(timeout: 30)
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
        let port = try await startFakeAcceptor(replyingAs: impostor)
        cm.requestConnection(to: DiscoveredPeer(
            id: "manual-imp", displayName: "Imp",
            endpoint: .manual(host: "127.0.0.1", port: port), source: .manual
        ))

        _ = await poll(timeout: 2) { self.cm.state == .connected }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(cm.connections[carol.id] === carolPC, "existing connection was replaced")
        XCTAssertEqual(carolPC.peerIdentity.displayName, "Carol", "existing connection's identity was re-pointed")
    }
}
