// Project F2 / Task 3: category presence enforced on every path — a hidden
// friend's incoming direct connection is cancelled without a single frame,
// dialing them is refused, always-connected rooms are left, live connections
// close quietly (never a `.disconnect` frame), and one timer wakes the
// manager at the next schedule boundary. Relay-code connections are exempt.
//
// One real ConnectionManager + scripted peers: a raw loopback TCP socket for
// the direct path, an in-memory pipe (`RVPipeEnd`) for live / rendezvous ones.
import XCTest
import Network
import CryptoKit
@testable import PeerDropCore
@testable import PeerDropTransport
import PeerDropProtocol
@testable import PeerDropSecurity

@MainActor
final class ConnectionManagerPresenceTests: XCTestCase {
    private var cm: ConnectionManager!
    private var keyDir: URL!
    private var catDir: URL!
    private var suite: String!
    private var touched: [String] = []
    private var listeners: [NWListener] = []
    private var clients: [NWConnection] = []
    private var rvPeers: [ScriptedRVPeer] = []
    private var recorder: RVEventRecorder!

    /// 2026-10-23 (Friday) 12:00 in Taipei.
    private var noon: Date { taipei.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12, minute: 0))! }
    private var taipei: Calendar { calendar("Asia/Taipei") }
    /// Daily 09:00–17:00: `noon` is inside, 20:00 is outside.
    private let workHours = ScheduleWindow(weekdays: [], startMinute: 540, endMinute: 1020)

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmpres-\(UUID().uuidString)")
        catDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmpres-cat-\(UUID().uuidString)")
        suite = "cmpres-\(UUID().uuidString)"
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmprestest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        let store = FriendCategoryStore(directory: catDir,
                                        encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)),
                                        migrationDefaults: UserDefaults(suiteName: suite)!)
        cm = ConnectionManager(categoryStore: store)
        cm.trustedContactStore.removeAll()
        let now = noon
        cm.presenceClock = { now }
        cm.presenceCalendar = taipei
        recorder = RVEventRecorder()
        cm.rendezvousEventSinkForTesting = recorder
        cm.rendezvousSecureChannelTimeoutNanoseconds = 3_000_000_000
    }

    override func tearDown() async throws {
        for p in rvPeers { p.stop(); p.end.close() }
        rvPeers = []
        for c in clients { c.cancel() }
        clients = []
        for l in listeners { l.cancel() }
        listeners = []
        cm.cancelPresenceTimer()
        for id in touched {
            cm.chatManager.deleteMessages(forPeer: id)
            cm.deviceStore.remove(id: id)
        }
        touched = []
        cm.trustedContactStore.removeAll()
        cm = nil
        recorder = nil
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        UserDefaults().removePersistentDomain(forName: suite)
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try? FileManager.default.removeItem(at: catDir)
        try await super.tearDown()
    }

    // MARK: Helpers

    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func poll(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// A category holding `friendID` with `presence`; returns its id.
    @discardableResult
    private func category(_ presence: CategoryPresence, holding friendID: String) -> String {
        let cat = cm.categoryStore.create(name: "分類\(UUID().uuidString.prefix(4))")!
        cm.categoryStore.assign(friendID: friendID, to: cat.id)
        XCTAssertTrue(cm.categoryStore.setPresence(presence, for: cat.id))
        return cat.id
    }

    nonisolated private static func socketQueue() -> DispatchQueue {
        DispatchQueue(label: "test.cmpres.socket", qos: .userInitiated)
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

    /// A raw socket into the CM's real acceptor path.
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

    /// Sends HELLO + connectionRequest as `ident`.
    private func request(as ident: PeerIdentity) async throws -> NWConnection {
        touched.append(ident.id)
        let socket = try await dialManager()
        try await socket.sendMessage(try PeerMessage.hello(identity: ident))
        try await socket.sendMessage(PeerMessage.connectionRequest(senderID: ident.id))
        return socket
    }

    /// Reads until the CM closes the socket (or `timeout`): the frame types
    /// seen and whether the socket really closed (vs. timed out).
    private func readUntilClosed(_ socket: NWConnection, timeout: TimeInterval = 3) async -> (types: [MessageType], closed: Bool) {
        var types: [MessageType] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                types.append(try await socket.receiveMessage(timeout: max(0.1, deadline.timeIntervalSinceNow)).type)
            } catch NWConnectionError.timeout {
                return (types, false)
            } catch {
                return (types, true)
            }
        }
        return (types, false)
    }

    /// A direct peer without a secure channel (no handshake frames), accepted.
    private func connectedDirectPeer(id: String = "dev-\(UUID().uuidString)") async throws -> NWConnection {
        let ident = PeerIdentity(id: id, displayName: "Pat \(id.prefix(6))")
        let socket = try await request(as: ident)
        let pending = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == id }
        XCTAssertTrue(pending, "consent sheet never appeared")
        cm.acceptConnection()
        let accept = try await socket.receiveMessage(timeout: 5)
        XCTAssertEqual(accept.type, .connectionAccept)
        let hello = try await socket.receiveMessage(timeout: 5)
        XCTAssertEqual(hello.type, .hello)
        let live = await poll { self.cm.connections[id]?.state.isActive == true }
        XCTAssertTrue(live, "connection never installed")
        return socket
    }

    /// A live connection over an in-memory pipe; the returned end records what the CM sent.
    private func pipeConnection(id: String, identityID: String? = nil, relay: Bool = false) -> RVPipeEnd {
        let (cmEnd, _) = RVPipeEnd.pair()
        let pc = PeerConnection(peerID: id, transport: cmEnd,
                                peerIdentity: PeerIdentity(id: identityID ?? id, displayName: "Friend"),
                                localIdentity: cm.localIdentity, state: .connected)
        pc.isRelayTransport = relay
        cm._addConnectionForTesting(pc)
        touched.append(id)
        if let identityID { touched.append(identityID) }
        return cmEnd
    }

    @discardableResult
    private func addRVFriend(key: RendezvousTestIdentity) throws -> TrustedContact {
        let deviceID = "dev-\(UUID().uuidString)"
        touched.append(deviceID)
        let c = TrustedContact(deviceId: deviceID, displayName: "Mika", identityPublicKey: key.raw, trustLevel: .linked)
        cm.trustedContactStore.add(c)
        cm.trustedContactStore.setAccountBinding(for: c.id, accountId: "AC\(UUID().uuidString.prefix(6))")
        try cm.trustedContactStore.setRendezvousEnabled(for: c.id, true)
        return try XCTUnwrap(cm.trustedContactStore.find(byId: c.id))
    }

    private func installRV(_ contact: TrustedContact, key: RendezvousTestIdentity) -> (PeerConnection?, ScriptedRVPeer, RVPipeEnd) {
        let (cmEnd, peerEnd) = RVPipeEnd.pair()
        let peer = ScriptedRVPeer(key: key, end: peerEnd, deviceID: contact.deviceId!, cmIdentity: cm.localIdentity)
        rvPeers.append(peer)
        peer.start()
        return (cm.installRendezvousConnection(transport: cmEnd, contact: contact), peer, cmEnd)
    }

    // MARK: Incoming direct connections

    func testHiddenFriendIncomingIsCancelledWithoutAnyFrame() async throws {
        let id = "dev-\(UUID().uuidString)"
        category(.offline, holding: id)
        let socket = try await request(as: PeerIdentity(id: id, displayName: "Hidden"))
        let (types, closed) = await readUntilClosed(socket)
        XCTAssertTrue(closed, "the CM must cancel the socket")
        XCTAssertEqual(types, [], "not a single frame to a hidden friend")
        XCTAssertNil(cm.pendingIncomingRequest)
        XCTAssertNotEqual(cm.state, .incomingRequest)
        XCTAssertNil(cm.connections[id])
    }

    func testVisibleFriendIncomingStillShowsConsent() async throws {
        let id = "dev-\(UUID().uuidString)"
        category(.online, holding: id)
        _ = try await request(as: PeerIdentity(id: id, displayName: "Visible"))
        let pending = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == id }
        XCTAssertTrue(pending, "a visible friend still gets the consent sheet")
    }

    /// The consent sheet is up when their category starts hiding us: it is
    /// dismissed and the socket dropped — no `.connectionReject`, no toast.
    func testPendingConsentFromNowHiddenFriendIsDismissedQuietly() async throws {
        let id = "dev-\(UUID().uuidString)"
        let catID = category(.online, holding: id)
        let socket = try await request(as: PeerIdentity(id: id, displayName: "Soon hidden"))
        let pending = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == id }
        XCTAssertTrue(pending)
        XCTAssertEqual(cm.state, .incomingRequest)

        XCTAssertTrue(cm.categoryStore.setPresence(.offline, for: catID))
        let (types, closed) = await readUntilClosed(socket)
        XCTAssertTrue(closed, "the pending socket must be dropped")
        XCTAssertEqual(types, [], "no reject (or any) frame: \(types)")
        XCTAssertNil(cm.pendingIncomingRequest)
        XCTAssertEqual(cm.state, .discovering)
        XCTAssertNil(cm.statusToast)
        XCTAssertNil(cm.connections[id])
    }

    /// The category holds only the LAN record; the HELLO comes from another
    /// record of the same person (same pinned key) — hidden too.
    func testHiddenViaSecondRecordOfSamePerson() async throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let lanID = "lan-\(UUID().uuidString)"
        touched.append(lanID)
        cm.trustedContactStore.add(TrustedContact(deviceId: lanID, displayName: "Mika", identityPublicKey: key, trustLevel: .linked))
        category(.offline, holding: lanID)
        let otherID = "other-\(UUID().uuidString)"
        let socket = try await request(as: PeerIdentity(id: otherID, displayName: "Mika", identityPublicKey: key))
        let (types, closed) = await readUntilClosed(socket)
        XCTAssertTrue(closed)
        XCTAssertEqual(types, [])
        XCTAssertNil(cm.pendingIncomingRequest)
    }

    func testScheduledWindowHidesOnlyInsideWindow() async throws {
        let id = "dev-\(UUID().uuidString)"
        category(.scheduled(workHours), holding: id)

        // 12:00 — inside the window: hidden.
        let inside = try await request(as: PeerIdentity(id: id, displayName: "Sched"))
        let (types, closed) = await readUntilClosed(inside)
        XCTAssertTrue(closed)
        XCTAssertEqual(types, [])
        XCTAssertNil(cm.pendingIncomingRequest)

        // 20:00 — outside: consent as usual.
        let evening = taipei.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 20, minute: 0))!
        cm.presenceClock = { evening }
        _ = try await request(as: PeerIdentity(id: id, displayName: "Sched"))
        let pending = await poll { self.cm.pendingIncomingRequest?.peerIdentity.id == id }
        XCTAssertTrue(pending)
    }

    // MARK: Dialing

    func testDialToHiddenFriendRefusedWithToast() {
        let id = "dev-\(UUID().uuidString)"
        category(.offline, holding: id)
        let before = cm.state
        cm.requestConnection(to: DiscoveredPeer(id: id, displayName: "Hidden",
                                                endpoint: .manual(host: "127.0.0.1", port: 9), source: .manual))
        XCTAssertFalse(cm._hasDialAttemptForTesting)
        XCTAssertEqual(cm.statusToast, String(localized: "This friend's category shows you as offline"))
        XCTAssertEqual(cm.state, before)
    }

    func testDialToHiddenFriendWithLiveRelayLinkFocusesInsteadOfToasting() {
        let relayID = "relay-\(UUID().uuidString.prefix(6))"
        let friend = "friend-\(UUID().uuidString)"
        _ = pipeConnection(id: relayID, identityID: friend, relay: true)
        category(.offline, holding: relayID)
        cm.statusToast = nil
        cm.requestConnection(to: DiscoveredPeer(id: relayID, displayName: "Friend",
                                                endpoint: .manual(host: "127.0.0.1", port: 9), source: .manual))
        XCTAssertEqual(cm.focusedPeerID, relayID, "the existing exempt link is focused")
        XCTAssertNil(cm.statusToast, "no 'shows you as offline' toast for a link that already exists")
        XCTAssertFalse(cm._hasDialAttemptForTesting)
    }

    func testReconnectToHiddenFriendDoesNotBurnABackoffAttempt() async {
        let id = "dev-\(UUID().uuidString)"
        category(.offline, holding: id)
        cm._setLastConnectedPeerForTesting(DiscoveredPeer(id: id, displayName: "Hidden",
                                                         endpoint: .manual(host: "127.0.0.1", port: 9), source: .manual))
        let before = await cm._reconnectAttemptCountForTesting()
        cm.reconnect()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = await cm._reconnectAttemptCountForTesting()
        XCTAssertEqual(after, before, "reconnect() consumed a back-off attempt on a refused dial")
        XCTAssertFalse(cm._hasDialAttemptForTesting)
        cm._setLastConnectedPeerForTesting(nil)
    }

    enum LegacyAcceptor {
        /// Legacy: the identity rides in the accept payload.
        case identityInAccept
        /// Identity-less accept, identity only in the HELLO that follows.
        case identityInHello
    }

    /// A scripted acceptor whose Bonjour id differs from its identity id.
    /// Reads our HELLO + request, answers per `script`, then records every
    /// later frame type until the dialer closes the socket.
    private func startLegacyAcceptor(replyingAs reply: PeerIdentity, script: LegacyAcceptor,
                                     recorder: FrameRecorder) async throws -> UInt16 {
        try await startListener { conn in
            conn.start(queue: Self.socketQueue())
            Task {
                defer { recorder.markClosed() }
                do {
                    try await conn.waitReady(timeout: 5)
                    _ = try await conn.receiveMessage(timeout: 5) // hello
                    _ = try await conn.receiveMessage(timeout: 5) // connectionRequest
                    switch script {
                    case .identityInAccept:
                        try await conn.sendMessage(PeerMessage(type: .connectionAccept,
                                                               payload: try JSONEncoder().encode(reply),
                                                               senderID: reply.id))
                    case .identityInHello:
                        try await conn.sendMessage(PeerMessage.connectionAccept(senderID: reply.id))
                        recorder.markAccepted()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        try await conn.sendMessage(try PeerMessage.hello(identity: reply))
                    }
                    while true { recorder.append(try await conn.receiveMessage(timeout: 10).type) }
                } catch {}
            }
        }
    }

    private func assertDialAbandonedQuietly(_ script: LegacyAcceptor) async throws {
        let bonjourID = "bonjour-\(UUID().uuidString)"
        let hidden = PeerIdentity(id: "ident-\(UUID().uuidString)", displayName: "Legacy")
        touched += [bonjourID, hidden.id]
        category(.offline, holding: hidden.id)
        let recorder = FrameRecorder()
        let port = try await startLegacyAcceptor(replyingAs: hidden, script: script, recorder: recorder)
        cm.requestConnection(to: DiscoveredPeer(id: bonjourID, displayName: "Legacy",
                                                endpoint: .manual(host: "127.0.0.1", port: port), source: .manual))
        XCTAssertTrue(cm._hasDialAttemptForTesting, "the Bonjour id is visible: the dial starts")
        if script == .identityInHello {
            let accepted = await poll { recorder.accepted && self.cm.state == .connected }
            XCTAssertTrue(accepted, "identity-less accept moves to .connected (state=\(cm.state))")
        }
        let closed = await poll(timeout: 5) { recorder.closed }
        XCTAssertTrue(closed, "the dialer must drop the socket")
        XCTAssertEqual(recorder.types, [], "no frame after learning who it is: \(recorder.types)")
        XCTAssertFalse(cm._hasDialAttemptForTesting)
        XCTAssertTrue(cm.connections.isEmpty)
        XCTAssertNil(cm.statusToast, "no toast")
        XCTAssertEqual(cm.state, .discovering, "alone ⇒ back to discovering, not \(cm.state)")
        XCTAssertTrue(cm.shouldAttemptConnection(to: bonjourID), "no failure recorded")
        XCTAssertTrue(cm.shouldAttemptConnection(to: hidden.id), "no failure recorded")
        // Nothing late (timeouts, read-loop errors) turns it into a failure.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(cm.state, .discovering)
        XCTAssertNil(cm.statusToast)
    }

    func testDialAbandonedWhenLegacyAcceptRevealsHiddenFriend() async throws {
        try await assertDialAbandonedQuietly(.identityInAccept)
    }

    func testDialAbandonedWhenHelloAfterIdentitylessAcceptRevealsHiddenFriend() async throws {
        try await assertDialAbandonedQuietly(.identityInHello)
    }

    // MARK: Live connections

    func testBecomingHiddenClosesLiveConnectionWithoutFrame() async throws {
        let id = "dev-\(UUID().uuidString)"
        let catID = category(.online, holding: id)
        let socket = try await connectedDirectPeer(id: id)
        XCTAssertTrue(cm.categoryStore.setPresence(.offline, for: catID))
        let (types, closed) = await readUntilClosed(socket)
        XCTAssertTrue(closed, "the connection must be closed")
        XCTAssertFalse(types.contains(.disconnect), "never a farewell frame: \(types)")
        let gone = await poll { self.cm.connections[id] == nil }
        XCTAssertTrue(gone)
        XCTAssertNil(cm.statusToast)
    }

    func testRelayConnectionUnaffected() async {
        let friend = "friend-\(UUID().uuidString)"
        let relayID = "relay-ABC123"
        let end = pipeConnection(id: relayID, identityID: friend, relay: true)
        let catID = category(.online, holding: friend)
        XCTAssertTrue(cm.categoryStore.setPresence(.offline, for: catID))
        try? await Task.sleep(nanoseconds: 150_000_000)
        cm.reevaluatePresence()
        XCTAssertNotNil(cm.connections[relayID], "a relay-code connection is the user's explicit consent")
        XCTAssertFalse(end.closed)
    }

    func testTimeZoneChangeReevaluates() async {
        // 12:00 Taipei = 21:00 the day before in Los Angeles (outside 09–17).
        cm.presenceCalendar = calendar("America/Los_Angeles")
        let id = "dev-\(UUID().uuidString)"
        category(.scheduled(workHours), holding: id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let end = pipeConnection(id: id)
        cm.reevaluatePresence()
        XCTAssertNotNil(cm.connections[id], "outside the window in Los Angeles")

        cm.presenceCalendar = taipei
        XCTAssertNotNil(cm.connections[id], "nothing re-evaluates until the system says so")
        let before = end.sent.count
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        let gone = await poll { self.cm.connections[id] == nil }
        XCTAssertTrue(gone, "inside the window in Taipei")
        XCTAssertTrue(end.closed)
        XCTAssertEqual(end.sent.count, before, "closed without a frame")
    }

    // MARK: Always connected

    func testScheduleStartClosesRendezvousWithoutFrame() async throws {
        let morning = taipei.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 8, minute: 59))!
        cm.presenceClock = { morning }
        let key = RendezvousTestIdentity()
        let friend = try addRVFriend(key: key)
        category(.scheduled(workHours), holding: friend.deviceId!)
        let (pc, peer, cmEnd) = installRV(friend, key: key)
        XCTAssertNotNil(pc, "08:59 is outside the window")
        let verified = await poll { pc?.rendezvousVerified == true }
        XCTAssertTrue(verified)
        _ = await poll { peer.inbox.contains { $0.type == .hello } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let sentBefore = cmEnd.sent.count

        let nine = taipei.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 0, second: 1))!
        cm.presenceClock = { nine }
        cm.reevaluatePresence()
        XCTAssertTrue(cm.rendezvousConnections.isEmpty)
        XCTAssertTrue(cmEnd.closed)
        XCTAssertEqual(cmEnd.sent.count, sentBefore, "no frame when the window starts")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(recorder.closed.isEmpty, "a friend hidden on purpose is not a link failure: \(recorder.closeReasons)")
        XCTAssertFalse(recorder.secure.contains { !$0.1 }, "no failed outcome reported either")
    }

    func testInstallRefusedForHiddenContact() throws {
        let key = RendezvousTestIdentity()
        let friend = try addRVFriend(key: key)
        category(.offline, holding: friend.deviceId!)
        let (pc, _, cmEnd) = installRV(friend, key: key)
        XCTAssertNil(pc)
        XCTAssertTrue(cmEnd.sent.isEmpty)
        XCTAssertTrue(cm.rendezvousConnections.isEmpty)
    }

    // MARK: Timer

    func testTimerScheduledAtNextTransitionAndClearedWithoutSchedules() async {
        let id = "dev-\(UUID().uuidString)"
        let catID = category(.scheduled(workHours), holding: id)
        let five = taipei.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 17, minute: 0))!
        let expected = PresencePolicy.nextTransition(categories: cm.categoryStore.categories, after: noon, calendar: taipei)
        XCTAssertEqual(expected, five)
        let scheduled = await poll { self.cm.presenceTimer?.fireDate == five.addingTimeInterval(1) }
        XCTAssertTrue(scheduled, "fire = next boundary + 1 s, got \(String(describing: cm.presenceTimer?.fireDate))")

        XCTAssertTrue(cm.categoryStore.setPresence(.online, for: catID))
        let cleared = await poll { self.cm.presenceTimer == nil }
        XCTAssertTrue(cleared, "no schedule left ⇒ no timer")
    }

    func testIOSBackgroundCancelsTimerMacKeepsIt() async {
        category(.scheduled(workHours), holding: "dev-\(UUID().uuidString)")
        let scheduled = await poll { self.cm.presenceTimer != nil }
        XCTAssertTrue(scheduled)

        cm.rendezvousClosesOnBackground = false   // Mac
        cm.handleScenePhaseChange(.background)
        XCTAssertNotNil(cm.presenceTimer, "the Mac keeps enforcing in the background")

        cm.rendezvousClosesOnBackground = true    // iOS
        cm.handleScenePhaseChange(.background)
        XCTAssertNil(cm.presenceTimer)
    }

    func testMacWakeWhileBackgroundedRechecksSchedules() async {
        let id = "dev-\(UUID().uuidString)"
        let evening = taipei.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 8, minute: 0))!
        cm.presenceClock = { evening }
        category(.scheduled(workHours), holding: id)
        let end = pipeConnection(id: id)
        cm.rendezvousClosesOnBackground = false   // Mac
        cm.handleScenePhaseChange(.background)
        cm.cancelPresenceTimer()                  // the timer was missed while asleep
        XCTAssertNotNil(cm.connections[id], "08:00 is outside the window")

        let nine = taipei.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 30))!
        cm.presenceClock = { nine }
        let before = end.sent.count
        cm.startRendezvousIfForeground()          // Mac wake, app still in the background
        XCTAssertNil(cm.connections[id], "the schedule started while asleep")
        XCTAssertTrue(end.closed)
        XCTAssertEqual(end.sent.count, before, "closed without a frame")
        XCTAssertNotNil(cm.presenceTimer, "the Mac re-arms the timer in the background")
    }
}

/// Frame types an acceptor saw after its scripted reply, and whether the
/// dialer closed the socket.
final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _types: [MessageType] = []
    private var _closed = false
    private var _accepted = false
    var types: [MessageType] { lock.withLock { _types } }
    var closed: Bool { lock.withLock { _closed } }
    var accepted: Bool { lock.withLock { _accepted } }
    func append(_ t: MessageType) { lock.withLock { _types.append(t) } }
    func markClosed() { lock.withLock { _closed = true } }
    func markAccepted() { lock.withLock { _accepted = true } }
}
