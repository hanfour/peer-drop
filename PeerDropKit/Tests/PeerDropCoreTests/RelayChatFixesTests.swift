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
        // No record exists yet to observe, so poll the ordering sentinel: a text
        // sent after the exchange is processed after it.
        try await client.sendMessage(try text("sentinel", senderID: pc.peerIdentity.id))
        let drained = await poll { (self.cm.chatManager.unreadCounts[pc.id] ?? 0) > 0 }
        XCTAssertTrue(drained)
        XCTAssertNil(cm.deviceStore.records.first { $0.id == pc.id })

        cm.confirmRelayPIN()
        let applied = cm.deviceStore.records.first { $0.id == pc.id }?.peerDeviceId
        XCTAssertEqual(applied, "device-abc")
    }

    // MARK: - Review round 1

    private func relayPair(code: String) async throws -> (pc: PeerConnection, client: NWConnection) {
        let (server, client) = try await rawPair()
        let pc = cm._installRelayPlaceholderForTesting(roomCode: code, connection: server)
        touched.append(pc.id)
        return (pc, client)
    }

    private func hello(_ real: PeerIdentity, via client: NWConnection, pc: PeerConnection) async throws {
        touched.append(real.id)
        try await client.sendMessage(try PeerMessage.hello(identity: real))
        let swapped = await poll { pc.peerIdentity.id == real.id }
        XCTAssertTrue(swapped)
    }

    // I1: chat-key resolution for records

    func testOfflineRelayRecordWithPeerIdentityIdResolvesToIdentityFile() {
        let id = UUID().uuidString
        let rec = DeviceRecord(id: "relay-OFF1", displayName: "R", sourceType: "relay",
                               lastConnected: Date(), peerIdentityId: id)
        XCTAssertEqual(cm.chatKey(forRecord: rec), id)
    }

    func testOfflineRelayRecordWithoutPeerIdentityIdFallsBackToRecordID() {
        let rec = DeviceRecord(id: "relay-OFF2", displayName: "R", sourceType: "relay", lastConnected: Date())
        XCTAssertEqual(cm.chatKey(forRecord: rec), "relay-OFF2")
    }

    func testNonRelayRecordKeyUnaffected() {
        let rec = DeviceRecord(id: "lan-1", displayName: "L", sourceType: "bonjour", lastConnected: Date())
        XCTAssertEqual(cm.chatKey(forRecord: rec), "lan-1")
    }

    func testDeviceRecordJSONWithoutPeerIdentityIdDecodes() throws {
        let old = DeviceRecord(id: "x", displayName: "X", sourceType: "relay", lastConnected: Date())
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        obj.removeValue(forKey: "peerIdentityId")
        let data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(DeviceRecord.self, from: data)
        XCTAssertNil(back.peerIdentityId)
        XCTAssertEqual(back.id, "x")
    }

    func testHelloSwapRecordsPeerIdentityIdOnExistingRelayRecord() async throws {
        let (pc, client) = try await relayPair(code: "HS\(UUID().uuidString.prefix(5))")
        cm.deviceStore.addOrUpdate(id: pc.id, displayName: pc.id, sourceType: "relay", host: nil, port: nil)
        let real = legacyIdentity("Rita")
        try await hello(real, via: client, pc: pc)
        let applied = await poll { self.cm.deviceStore.records.first { $0.id == pc.id }?.peerIdentityId == real.id }
        XCTAssertTrue(applied)
    }

    func testPeerIdentityIdStashedUntilPinConfirmationCreatesRecord() async throws {
        let (pc, client) = try await relayPair(code: "SI\(UUID().uuidString.prefix(5))")
        cm.pendingRelayPIN = RelayPINRequest(pin: "123456", peerID: pc.id, remoteFingerprint: "fp")
        let real = legacyIdentity("Rita")
        try await hello(real, via: client, pc: pc)
        XCTAssertNil(cm.deviceStore.records.first { $0.id == pc.id })
        cm.confirmRelayPIN()
        XCTAssertEqual(cm.deviceStore.records.first { $0.id == pc.id }?.peerIdentityId, real.id)
    }

    // I2: forgetDevice removes both threads unless shared

    private func seedThread(_ key: String, text: String) {
        _ = cm.chatManager.saveIncoming(text: text, peerID: key, peerName: key)
        cm.chatManager.flushAllPendingPersists()
    }

    private func threadHasMessages(_ key: String) -> Bool {
        cm.chatManager.flushAllPendingPersists()
        cm.chatManager.loadMessages(forPeer: key)
        return !cm.chatManager.messages.isEmpty
    }

    func testForgetRelayDeviceDeletesRelayAndIdentityFiles() {
        let identityID = UUID().uuidString, rid = "relay-FG\(UUID().uuidString.prefix(5))"
        touched.append(contentsOf: [identityID, rid])
        cm.deviceStore.addOrUpdate(id: rid, displayName: "Relay Friend", sourceType: "relay", host: nil, port: nil)
        cm.deviceStore.setPeerIdentityId(for: rid, identityId: identityID)
        seedThread(rid, text: "old")
        seedThread(identityID, text: "new")
        XCTAssertTrue(threadHasMessages(rid) && threadHasMessages(identityID))
        cm.forgetDevice(id: rid)
        XCTAssertFalse(threadHasMessages(rid))
        XCTAssertFalse(threadHasMessages(identityID))
        XCTAssertNil(cm.deviceStore.records.first { $0.id == rid })
    }

    func testForgetRelayDeviceKeepsIdentityFileSharedWithLocalRecord() {
        let identityID = UUID().uuidString, rid = "relay-FK\(UUID().uuidString.prefix(5))"
        touched.append(contentsOf: [identityID, rid])
        cm.deviceStore.addOrUpdate(id: rid, displayName: "Relay Friend", sourceType: "relay", host: nil, port: nil)
        cm.deviceStore.setPeerIdentityId(for: rid, identityId: identityID)
        // The same friend also has a local-network record keyed by the identity UUID.
        cm.deviceStore.addOrUpdate(id: identityID, displayName: "Friend LAN", sourceType: "bonjour", host: nil, port: nil)
        seedThread(rid, text: "old")
        seedThread(identityID, text: "shared history")
        cm.forgetDevice(id: rid)
        XCTAssertFalse(threadHasMessages(rid))
        XCTAssertTrue(threadHasMessages(identityID), "shared identity history must survive")
    }

    // Minor tests

    func testStashIgnoredForNonRelayConnection() async throws {
        let (server, client) = try await rawPair()
        // A plain (non-relay) connection that happens to have no DeviceRecord.
        let ident = legacyIdentity("Lan")
        let pc = PeerConnection(peerID: ident.id, transport: TCPTransport(connection: server),
                                peerIdentity: ident, localIdentity: cm.localIdentity, state: .connected)
        cm._addConnectionForTesting(pc)
        touched.append(ident.id)
        try await client.sendMessage(try PeerMessage.deviceIdExchange(deviceId: "dev-lan", senderID: ident.id))
        try await client.sendMessage(try text("sentinel", senderID: ident.id))
        _ = await poll { (self.cm.chatManager.unreadCounts[ident.id] ?? 0) > 0 }
        // Registering the record later must not receive a stale stash.
        cm.deviceStore.addOrUpdate(id: ident.id, displayName: "Lan", sourceType: "bonjour", host: nil, port: nil)
        cm.pendingRelayPIN = RelayPINRequest(pin: "1", peerID: ident.id, remoteFingerprint: "fp")
        cm.confirmRelayPIN()
        XCTAssertNil(cm.deviceStore.records.first { $0.id == ident.id }?.peerDeviceId)
    }

    func testReconnectWithSameRelayCodeDoesNotApplyStaleStash() async throws {
        let code = "ST\(UUID().uuidString.prefix(5))"
        let (pc, client) = try await relayPair(code: code)
        cm.pendingRelayPIN = RelayPINRequest(pin: "1", peerID: pc.id, remoteFingerprint: "fp")
        try await client.sendMessage(try PeerMessage.deviceIdExchange(deviceId: "stale-dev", senderID: pc.peerIdentity.id))
        try await client.sendMessage(try text("sentinel", senderID: pc.peerIdentity.id))
        _ = await poll { (self.cm.chatManager.unreadCounts[pc.id] ?? 0) > 0 }
        cm.rejectRelayPIN()
        let gone = await poll { self.cm.connections[pc.id] == nil }
        XCTAssertTrue(gone)

        let (pc2, _) = try await relayPair(code: code)
        cm.pendingRelayPIN = RelayPINRequest(pin: "2", peerID: pc2.id, remoteFingerprint: "fp2")
        cm.confirmRelayPIN()
        XCTAssertNotNil(cm.deviceStore.records.first { $0.id == pc2.id })
        XCTAssertNil(cm.deviceStore.records.first { $0.id == pc2.id }?.peerDeviceId, "stale deviceId was applied")
    }

    func testAliasDoesNotRaiseTrustForSecureCapablePeerWithoutContact() async throws {
        let (pc, client) = try await relayPair(code: "TR\(UUID().uuidString.prefix(5))")
        let key = Data(repeating: 7, count: 32)
        let real = PeerIdentity(id: UUID().uuidString, displayName: "Sec", identityPublicKey: key, supportsSecureChannel: true)
        touched.append(real.id)
        // Install the identity directly (HELLO would also create an .unknown contact).
        pc.updatePeerIdentity(real)
        _ = client
        XCTAssertFalse(cm.isPeerTrustedForUserActions(peerID: pc.id))
        XCTAssertFalse(cm.isPeerTrustedForUserActions(peerID: real.id))
    }

    func testNonRelayConnectionStoresUnderConnectionID() async throws {
        let (server, client) = try await rawPair()
        let ident = legacyIdentity("Lan")
        let pc = PeerConnection(peerID: ident.id, transport: TCPTransport(connection: server),
                                peerIdentity: ident, localIdentity: cm.localIdentity, state: .connected)
        cm._addConnectionForTesting(pc)
        touched.append(ident.id)
        let mid = UUID().uuidString
        try await client.sendMessage(try PeerMessage.textMessage(TextMessagePayload(text: "lan hi", senderName: "x", messageID: mid), senderID: ident.id))
        let arrived = await poll { (self.cm.chatManager.unreadCounts[pc.id] ?? 0) > 0 }
        XCTAssertTrue(arrived)
        try await client.sendMessage(try PeerMessage.typingIndicator(TypingIndicatorPayload(isTyping: true, timestamp: Date()), senderID: ident.id))
        let typing = await poll { self.cm.chatManager.isTyping(peerID: pc.id) }
        XCTAssertTrue(typing)
        try await client.sendMessage(try PeerMessage.messageEdit(MessageEditPayload(messageID: mid, newText: "edited"), senderID: ident.id))
        let edited = await poll {
            self.cm.chatManager.loadMessages(forPeer: pc.id)
            return self.cm.chatManager.messages.first { $0.id == mid }?.text == "edited"
        }
        XCTAssertTrue(edited)
        try await client.sendMessage(try PeerMessage.messageDelete(MessageDeletePayload(messageID: mid), senderID: ident.id))
        let deleted = await poll {
            self.cm.chatManager.loadMessages(forPeer: pc.id)
            return self.cm.chatManager.messages.first { $0.id == mid }?.isDeleted == true
        }
        XCTAssertTrue(deleted)
    }

    func testRelayMediaRejectEditLandInIdentityFile() async throws {
        let real = legacyIdentity("Rita")
        let (pc, client) = try await swappedRelayPeer(real)
        // media
        let media = MediaMessagePayload(mediaType: .file, fileName: "a.txt", fileSize: 3, mimeType: "text/plain",
                                        duration: nil, thumbnailData: nil, fileData: Data([1, 2, 3]))
        try await client.sendMessage(try PeerMessage.mediaMessage(media, senderID: real.id))
        let got = await poll { (self.cm.chatManager.unreadCounts[real.id] ?? 0) > 0 }
        XCTAssertTrue(got, "media not stored under identity key")
        XCTAssertEqual(cm.chatManager.unreadCounts[pc.id] ?? 0, 0)
        // edit of an incoming text
        let tid = UUID().uuidString
        try await client.sendMessage(try PeerMessage.textMessage(TextMessagePayload(text: "v1", senderName: "x", messageID: tid), senderID: real.id))
        _ = await poll { self.cm.chatManager.getUnreadMessageIDs(for: real.id).contains(tid) }
        try await client.sendMessage(try PeerMessage.messageEdit(MessageEditPayload(messageID: tid, newText: "v2"), senderID: real.id))
        let edited = await poll {
            self.cm.chatManager.loadMessages(forPeer: real.id)
            return self.cm.chatManager.messages.first { $0.id == tid }?.text == "v2"
        }
        XCTAssertTrue(edited, "edit not applied in identity file")
        // chatReject marks the last outgoing failed in the identity file
        cm.sendTextMessage("out", to: real.id)
        let sent = await poll {
            self.cm.chatManager.flushAllPendingPersists()
            self.cm.chatManager.loadMessages(forPeer: real.id)
            return self.cm.chatManager.messages.first { $0.text == "out" }?.status == .sent
        }
        XCTAssertTrue(sent)
        try await client.sendMessage(PeerMessage.chatReject(senderID: real.id, reason: "featureDisabled"))
        let failed = await poll {
            self.cm.chatManager.loadMessages(forPeer: real.id)
            return self.cm.chatManager.messages.first { $0.text == "out" }?.status == .failed
        }
        XCTAssertTrue(failed, "chatReject did not hit the identity file")
        cm.chatManager.loadMessages(forPeer: pc.id)
        XCTAssertTrue(cm.chatManager.messages.isEmpty)
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
