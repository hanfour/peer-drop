import XCTest
import CryptoKit
@testable import PeerDropSecurity
import PeerDropTransport
@testable import PeerDropCore

// MARK: - Fakes

@MainActor
final class FakeSignalingTransport: RendezvousSignalingTransport {
    let token: Data
    let day: Int
    let peerKey: Data
    var onEvent: ((RendezvousSignalingEvent) -> Void)?
    private(set) var connected = false
    private(set) var closed = false
    private(set) var sent: [Data] = []
    private(set) var tickCount = 0
    var iceServers = [RendezvousICEServer(urls: ["turn:t.example:3478"], username: "u", credential: "c")]
    private(set) var iceFetches = 0

    init(token: Data, day: Int, peerKey: Data) {
        self.token = token
        self.day = day
        self.peerKey = peerKey
    }
    func connect() { connected = true }
    func sendSignal(_ plaintext: Data) { sent.append(plaintext) }
    func tick(now: Date) { tickCount += 1 }
    func close() { closed = true }
    /// When set, ICE fetches suspend until `releaseICE()`.
    var holdICE = false
    private var iceWaiters: [CheckedContinuation<Void, Never>] = []
    func fetchICEServers() async -> [RendezvousICEServer] {
        iceFetches += 1
        if holdICE { await withCheckedContinuation { iceWaiters.append($0) } }
        return iceServers
    }
    func releaseICE() {
        let w = iceWaiters
        iceWaiters = []
        w.forEach { $0.resume() }
    }
    func emit(_ e: RendezvousSignalingEvent) { onEvent?(e) }
    var sentSignals: [RendezvousSignal] { sent.compactMap(RendezvousSignal.decode) }
}

@MainActor
final class FakeSignalingFactory: RendezvousSignalingTransportFactory {
    private(set) var made: [FakeSignalingTransport] = []
    func makeTransport(token: Data, day: Int, peerKey: Data) -> RendezvousSignalingTransport {
        let t = FakeSignalingTransport(token: token, day: day, peerKey: peerKey)
        made.append(t)
        return t
    }
    func live(day: Int? = nil) -> [FakeSignalingTransport] { made.filter { !$0.closed && (day == nil || $0.day == day) } }
}

@MainActor
final class FakeNegotiator: RendezvousNegotiator {
    let role: RendezvousRole
    let iceServers: [RendezvousICEServer]
    var onLocalSignal: ((RendezvousSignal) -> Void)?
    var onOpen: ((TransportProtocol) -> Void)?
    var onClosed: (() -> Void)?
    private(set) var started = false
    private(set) var closed = false
    private(set) var remote: [RendezvousSignal] = []
    let transport = FakeRVTransport(label: "dc")
    init(role: RendezvousRole, iceServers: [RendezvousICEServer]) { self.role = role; self.iceServers = iceServers }
    func start() { started = true }
    func handleRemote(_ signal: RendezvousSignal) { remote.append(signal) }
    func close() { closed = true }
    func open() { onOpen?(transport) }
    func drop() { onClosed?() }
    func local(_ s: RendezvousSignal) { onLocalSignal?(s) }
}

@MainActor
final class FakeNegotiatorFactory: RendezvousNegotiatorFactory {
    private(set) var made: [FakeNegotiator] = []
    func makeNegotiator(role: RendezvousRole, iceServers: [RendezvousICEServer]) -> RendezvousNegotiator {
        let n = FakeNegotiator(role: role, iceServers: iceServers)
        made.append(n)
        return n
    }
}

@MainActor
final class FakeDirectChecker: DirectConnectionChecker {
    var direct: Set<UUID> = []
    var onDirectConnectionsChanged: (() -> Void)?
    func hasDirectConnection(to contact: TrustedContact) -> Bool { direct.contains(contact.id) }
    func set(_ id: UUID, _ on: Bool) {
        if on { direct.insert(id) } else { direct.remove(id) }
        onDirectConnectionsChanged?()
    }
}

@MainActor
final class FakeInstaller: RendezvousConnectionInstaller {
    var accept = true
    private(set) var installs: [(transport: TransportProtocol, contact: TrustedContact)] = []
    private(set) var uninstalls: [UUID] = []
    var onInstall: ((TrustedContact) -> Void)?
    var onUninstall: ((TrustedContact) -> Void)?
    func install(transport: TransportProtocol, contact: TrustedContact) -> Bool {
        onInstall?(contact)
        guard accept else { return false }
        installs.append((transport, contact))
        return true
    }
    func uninstall(contact: TrustedContact) {
        uninstalls.append(contact.id)
        onUninstall?(contact)
    }
}

final class FakeRVClock: RendezvousClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

final class FixedRVJitter: RendezvousJitterSource {
    var value: TimeInterval
    init(_ v: TimeInterval = 0) { value = v }
    func jitter() -> TimeInterval { value }
}

@MainActor
final class ManualRVTicker: RendezvousTicker {
    private(set) var running = false
    func start(_ tick: @escaping @MainActor () -> Void) { running = true }
    func stop() { running = false }
}

// MARK: - Tests

@MainActor
final class RendezvousManagerTests: XCTestCase {

    /// 08:00 UTC — far from a day boundary.
    let noon = Date(timeIntervalSince1970: 1_800_000_000)
    var me: RendezvousTestIdentity!
    var contacts: [TrustedContact] = []
    var factory: FakeSignalingFactory!
    var negotiators: FakeNegotiatorFactory!
    var direct: FakeDirectChecker!
    var installer: FakeInstaller!
    var clock: FakeRVClock!
    var jitter: FixedRVJitter!
    var ticker: ManualRVTicker!
    var tags: RendezvousSessionTagStore!
    var manager: RendezvousManager!

    override func setUp() async throws {
        me = RendezvousTestIdentity()
        contacts = []
        factory = FakeSignalingFactory()
        negotiators = FakeNegotiatorFactory()
        direct = FakeDirectChecker()
        installer = FakeInstaller()
        clock = FakeRVClock(noon)
        jitter = FixedRVJitter()
        ticker = ManualRVTicker()
        tags = RendezvousSessionTagStore()
        manager = RendezvousManager(
            contacts: { [unowned self] in self.contacts },
            secrets: IdentityRendezvousSecretProvider(identity: me),
            direct: direct, installer: installer, signaling: factory, negotiators: negotiators,
            clock: clock, jitter: jitter, ticker: ticker, sessionTags: tags)
    }

    var myKey: Data { me.raw }

    func friend(role: RendezvousRole? = nil, name: String = "f") -> (RendezvousTestIdentity, TrustedContact) {
        var id = RendezvousTestIdentity()
        if let role {
            while (try? RendezvousRole.forKeys(myKey: myKey, peerKey: id.raw)) != role { id = RendezvousTestIdentity() }
        }
        var c = TrustedContact(deviceId: "dev-\(name)-\(UUID().uuidString)", displayName: name, identityPublicKey: id.raw,
                               trustLevel: .verified, accountId: "acct-\(name)-\(UUID().uuidString)")
        c.rendezvousEnabled = true
        return (id, c)
    }

    @discardableResult
    func addFriend(role: RendezvousRole? = nil) -> TrustedContact {
        let (_, c) = friend(role: role)
        contacts.append(c)
        return c
    }

    /// Joined + handshake + peer `ready` on `t`.
    func authenticate(_ t: FakeSignalingTransport) {
        t.emit(.peerJoined)
        t.emit(.handshakeCompleted)
        t.emit(.signal(RendezvousSignal.ready.encoded()))
    }

    func negotiatingOfferer() async -> (TrustedContact, FakeSignalingTransport, FakeNegotiator) {
        let c = addFriend(role: .offerer)
        manager.appDidBecomeActive()
        let t = factory.made[0]
        authenticate(t)
        await rvWaitUntil { self.negotiators.made.count == 1 }
        return (c, t, negotiators.made[0])
    }

    func securedOfferer() async -> (TrustedContact, FakeSignalingTransport, FakeNegotiator) {
        let (c, t, n) = await negotiatingOfferer()
        n.open()
        manager.secureChannelDidComplete(contactID: c.id, ok: true)
        XCTAssertEqual(manager.linkState(for: c.id), .connected)
        return (c, t, n)
    }

    // MARK: Opt-in, eligibility, cap

    func testForegroundJoinsOneRoomPerEligibleContactCappedAtFive() throws {
        let eligible = (0..<7).map { _ in addFriend() }
        var unbound = friend(name: "u").1; unbound.accountId = nil
        var pending = friend(name: "p").1
        pending.pendingAccountBinding = PendingAccountBinding(accountId: "x", signingKey: Data(count: 32),
                                                              handshakeKeyHash: Data(count: 32), receivedAt: noon)
        var blocked = friend(name: "b").1; blocked.isBlocked = true
        var off = friend(name: "o").1; off.rendezvousEnabled = nil
        contacts += [unbound, pending, blocked, off]

        manager.contactsDidChange()
        XCTAssertTrue(factory.made.isEmpty, "background: nothing joins")

        manager.appDidBecomeActive()
        XCTAssertTrue(ticker.running)
        XCTAssertEqual(factory.made.count, 5)
        XCTAssertTrue(factory.made.allSatisfy(\.connected))
        let expected = eligible.sorted { $0.id.uuidString < $1.id.uuidString }.prefix(5)
        let day = RendezvousToken.day(at: noon)
        let expectedTokens = try expected.map {
            try RendezvousToken.token(provider: IdentityRendezvousSecretProvider(identity: me), peerKey: $0.identityPublicKey, day: day)
        }
        XCTAssertEqual(Set(factory.made.map(\.token)), Set(expectedTokens))
        XCTAssertTrue(factory.made.allSatisfy { $0.day == day })
        for c in [unbound, pending, blocked, off] { XCTAssertEqual(manager.linkState(for: c.id), .inactive) }
    }

    /// Ruling R-a: first join immediate even with jitter; retries are jittered.
    func testFirstJoinImmediateRetriesJittered() {
        jitter.value = 12
        let c = addFriend()
        manager.appDidBecomeActive()
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(manager.linkState(for: c.id), .connecting)
        factory.made[0].emit(.closed)
        clock.advance(12.5); manager.tick()
        XCTAssertEqual(factory.made.count, 1)
        clock.advance(0.5); manager.tick()
        XCTAssertEqual(factory.made.count, 2, "retry at 1 s backoff + 12 s jitter")
    }

    // MARK: Fix 2: stale ICE fetch

    func testStaleICEFetchAfterBackgroundForegroundDoesNotAttach() async {
        _ = addFriend(role: .offerer)
        manager.appDidBecomeActive()
        let t1 = factory.made[0]; t1.holdICE = true
        authenticate(t1)
        await rvWaitUntil { t1.iceFetches == 1 }
        manager.appDidEnterBackground()
        manager.appDidBecomeActive()
        let t2 = factory.made[1]; t2.holdICE = true
        authenticate(t2)  // recreated room: attempt restarts at 1
        await rvWaitUntil { t2.iceFetches == 1 }
        t1.releaseICE()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(negotiators.made.isEmpty, "a stale fetch must not attach to the new room")
        t2.releaseICE()
        await rvWaitUntil { self.negotiators.made.count == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(negotiators.made.count, 1)
    }

    func testStaleICEFetchAfterRetireRecreateDoesNotAttach() async {
        _ = addFriend(role: .offerer)
        manager.appDidBecomeActive()
        let t1 = factory.made[0]; t1.holdICE = true
        authenticate(t1)
        await rvWaitUntil { t1.iceFetches == 1 }
        contacts[0].rendezvousEnabled = nil
        manager.contactsDidChange()
        contacts[0].rendezvousEnabled = true
        manager.contactsDidChange()
        let t2 = factory.made[1]; t2.holdICE = true
        authenticate(t2)
        await rvWaitUntil { t2.iceFetches == 1 }
        t1.releaseICE()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(negotiators.made.isEmpty)
        t2.releaseICE()
        await rvWaitUntil { self.negotiators.made.count == 1 }
    }

    // MARK: Re-entrant connection-layer callbacks during install

    func testConnectionDidCloseInsideInstallIsNotLost() async {
        let (c, _, n) = await negotiatingOfferer()
        installer.onInstall = { [unowned self] c in self.manager.connectionDidClose(contactID: c.id) }
        n.open()
        XCTAssertTrue(n.closed)
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
        XCTAssertEqual(manager.sessionStates(for: c.id).values.first, .failed(.connectionLost))
    }

    func testSecureChannelDidCompleteInsideInstallIsNotLost() async {
        let (c, t, n) = await negotiatingOfferer()
        installer.onInstall = { [unowned self] c in self.manager.secureChannelDidComplete(contactID: c.id, ok: true) }
        n.open()
        XCTAssertEqual(manager.linkState(for: c.id), .connected)
        XCTAssertTrue(t.closed)
    }

    func testFailedSecureChannelInsideInstallUninstalls() async {
        let (c, _, n) = await negotiatingOfferer()
        installer.onInstall = { [unowned self] c in self.manager.secureChannelDidComplete(contactID: c.id, ok: false) }
        n.open()
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
    }

    func testDirectConnectionAppearingInsideInstallClosesEverything() async {
        let (c, t, n) = await negotiatingOfferer()
        installer.onInstall = { [unowned self] c in self.direct.set(c.id, true) }
        n.open()
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertTrue(n.closed)
        XCTAssertTrue(t.closed)
        XCTAssertEqual(manager.roomCount, 0)
        XCTAssertEqual(manager.linkState(for: c.id), .inactive)
    }

    /// Round 2 (b): installer reports OK synchronously and then refuses.
    func testInstallRefusedAfterSynchronousSecureOKFails() async {
        let (c, _, n) = await negotiatingOfferer()
        installer.accept = false
        installer.onInstall = { [unowned self] c in self.manager.secureChannelDidComplete(contactID: c.id, ok: true) }
        n.open()
        XCTAssertTrue(n.closed)
        XCTAssertEqual(manager.sessionStates(for: c.id).values.first, .failed(.installRejected))
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
        XCTAssertTrue(installer.uninstalls.isEmpty, "never installed")
    }

    /// Round 2 (c): contacts changing during reconcile's first drain (here the
    /// connection layer's uninstall disables the contact) must not let a stale
    /// `active` list recreate a room.
    func testContactsChangedDuringReconcileDrainAreReRead() async {
        let (_, _, _) = await securedOfferer()
        let made = factory.made.count
        installer.onUninstall = { [unowned self] _ in self.contacts[0].rendezvousEnabled = nil }
        contacts[0].identityPublicKey = RendezvousTestIdentity().raw  // key change, flag still set
        manager.contactsDidChange()
        XCTAssertEqual(factory.made.count, made, "no room for a just-disabled contact")
        XCTAssertEqual(manager.roomCount, 0)
    }

    func testBackgroundInsideInstallClosesEverything() async {
        let (c, t, n) = await negotiatingOfferer()
        installer.onInstall = { [unowned self] _ in self.manager.appDidEnterBackground() }
        n.open()
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertTrue(n.closed)
        XCTAssertTrue(t.closed)
        XCTAssertEqual(manager.roomCount, 0)
    }

    // MARK: Downgrade / key change

    func testDowngradeLeavesRoomAndSendsNothingExtra() {
        let c = addFriend(role: .answerer)
        manager.appDidBecomeActive()
        let t = factory.made[0]
        authenticate(t)
        XCTAssertEqual(t.sentSignals, [.ready])
        contacts[0].rendezvousEnabled = nil
        manager.contactsDidChange()
        XCTAssertTrue(t.closed)
        XCTAssertEqual(t.sentSignals, [.ready], "no reject/farewell frame")
        XCTAssertEqual(manager.roomCount, 0)
        XCTAssertEqual(manager.linkState(for: c.id), .inactive)
        clock.advance(3600); manager.tick()
        XCTAssertEqual(factory.made.count, 1, "never rejoins while disabled")
    }

    func testDowngradeWhileNegotiatingClosesWithoutSignal() async {
        let (_, t, n) = await negotiatingOfferer()
        let before = t.sent
        contacts[0].rendezvousEnabled = nil
        manager.contactsDidChange()
        XCTAssertTrue(n.closed)
        XCTAssertTrue(t.closed)
        XCTAssertEqual(t.sent, before)
    }

    func testKeyChangeDisablesAndClosesRoom() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mgr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrustedContactStore(storageKey: "rv", directory: dir,
                                        encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        let (_, c0) = friend()
        var c = c0; c.rendezvousEnabled = nil
        store.add(c)
        try store.setRendezvousEnabled(for: c.id, true)
        manager = RendezvousManager(contacts: { store.contacts }, secrets: IdentityRendezvousSecretProvider(identity: me),
                                    direct: direct, installer: installer, signaling: factory, negotiators: negotiators,
                                    clock: clock, jitter: jitter, ticker: ticker, sessionTags: tags)
        manager.appDidBecomeActive()
        XCTAssertEqual(factory.live().count, 1)
        store.updatePublicKey(for: c.id, newKey: RendezvousTestIdentity().raw, reason: .detectedOnReconnect)
        manager.contactsDidChange()
        XCTAssertEqual(factory.live().count, 0)
        XCTAssertEqual(manager.roomCount, 0)
    }

    // MARK: Project F2: category presence

    /// A manager whose `visible` filter is the test's `visibleNow` flag.
    func makeVisibilityManager(_ visibleNow: @escaping () -> Bool) {
        manager = RendezvousManager(
            contacts: { [unowned self] in self.contacts },
            secrets: IdentityRendezvousSecretProvider(identity: me),
            direct: direct, installer: installer, signaling: factory, negotiators: negotiators,
            clock: clock, jitter: jitter, ticker: ticker, sessionTags: tags,
            visible: { _ in visibleNow() })
    }

    func testInvisibleContactGetsNoRoomAndVisibleAgainRejoins() {
        var visibleNow = false
        makeVisibilityManager { visibleNow }
        let c = addFriend()
        manager.appDidBecomeActive()
        XCTAssertTrue(factory.made.isEmpty, "a hidden friend gets no room")
        XCTAssertEqual(manager.linkState(for: c.id), .inactive)
        visibleNow = true
        manager.contactsDidChange()
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(manager.linkState(for: c.id), .connecting)
    }

    func testBecomingInvisibleLeavesRoomAndSendsNothingExtra() {
        var visibleNow = true
        makeVisibilityManager { visibleNow }
        let c = addFriend(role: .answerer)
        manager.appDidBecomeActive()
        let t = factory.made[0]
        authenticate(t)
        XCTAssertEqual(t.sentSignals, [.ready])
        visibleNow = false
        manager.contactsDidChange()
        XCTAssertTrue(t.closed)
        XCTAssertEqual(t.sentSignals, [.ready], "no reject/farewell frame")
        XCTAssertEqual(manager.roomCount, 0)
        XCTAssertEqual(manager.linkState(for: c.id), .inactive)
        clock.advance(3600); manager.tick()
        XCTAssertEqual(factory.made.count, 1, "never rejoins while hidden")
    }

    /// The visibility filter runs after eligibility over ALL contacts: hiding
    /// one of two contacts sharing a device id must not make the other eligible.
    func testVisibilityFilterDoesNotChangeDeviceIdUniqueness() {
        let a = addFriend()
        var b = friend(name: "dup").1
        b.deviceId = a.deviceId
        contacts.append(b)
        manager = RendezvousManager(
            contacts: { [unowned self] in self.contacts },
            secrets: IdentityRendezvousSecretProvider(identity: me),
            direct: direct, installer: installer, signaling: factory, negotiators: negotiators,
            clock: clock, jitter: jitter, ticker: ticker, sessionTags: tags,
            visible: { $0.id != b.id })
        manager.appDidBecomeActive()
        XCTAssertTrue(factory.made.isEmpty, "a's device id is still shared with b")
        XCTAssertEqual(manager.linkState(for: a.id), .inactive)
        XCTAssertTrue(RendezvousManager.activeContacts(contacts, visible: { $0.id != b.id }).isEmpty)
    }

    // MARK: Background

    func testBackgroundClosesEverythingAndSendsNothing() async {
        let (c, t, n) = await securedOfferer()
        let other = addFriend(role: .answerer)
        manager.contactsDidChange()
        let t2 = factory.made.last!
        authenticate(t2)
        let sentBefore = factory.made.map(\.sent)
        manager.appDidEnterBackground()
        XCTAssertFalse(ticker.running)
        XCTAssertTrue(factory.made.allSatisfy(\.closed))
        XCTAssertTrue(n.closed)
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertEqual(factory.made.map(\.sent), sentBefore, "background sends nothing")
        XCTAssertEqual(manager.roomCount, 0)
        XCTAssertEqual(manager.linkState(for: other.id), .inactive)
        _ = t
        let count = factory.made.count
        clock.advance(600); manager.tick()
        XCTAssertEqual(factory.made.count, count)
        manager.appDidBecomeActive()
        XCTAssertEqual(factory.made.count, count + 2, "foreground rejoins every enabled contact")
    }

    // MARK: Full flows

    func testOffererFlowInstallsAndLeavesRoomWhenSecured() async throws {
        let (c, t, n) = await negotiatingOfferer()
        XCTAssertEqual(t.sentSignals, [.ready])
        XCTAssertEqual(n.role, .offerer)
        XCTAssertEqual(n.iceServers, t.iceServers)
        XCTAssertTrue(n.started)
        n.local(.offer(sdp: "o"))
        n.local(.ice(sdp: "c1", mid: "0", index: 0))
        XCTAssertEqual(t.sentSignals, [.ready, .offer(sdp: "o"), .ice(sdp: "c1", mid: "0", index: 0)])
        t.emit(.signal(RendezvousSignal.answer(sdp: "a").encoded()))
        XCTAssertEqual(n.remote, [.answer(sdp: "a")])
        XCTAssertEqual(manager.linkState(for: c.id), .connecting)
        n.open()
        XCTAssertEqual(installer.installs.count, 1)
        XCTAssertTrue(installer.installs[0].transport === n.transport)
        XCTAssertEqual(installer.installs[0].contact.id, c.id)
        XCTAssertEqual(manager.linkState(for: c.id), .connecting, "not online before the pinned secure channel")
        XCTAssertFalse(t.closed)
        manager.secureChannelDidComplete(contactID: c.id, ok: true)
        XCTAssertTrue(t.closed, "signaling done ⇒ leave the room")
        XCTAssertEqual(manager.linkState(for: c.id), .connected)
    }

    func testAnswererBuffersRemoteSignalsUntilNegotiatorExists() async {
        _ = addFriend(role: .answerer)
        manager.appDidBecomeActive()
        let t = factory.made[0]
        authenticate(t)
        XCTAssertTrue(negotiators.made.isEmpty, "answerer waits for an offer")
        t.emit(.signal(RendezvousSignal.offer(sdp: "o").encoded()))
        t.emit(.signal(RendezvousSignal.ice(sdp: "c", mid: nil, index: 0).encoded()))
        await rvWaitUntil { self.negotiators.made.count == 1 }
        let n = negotiators.made[0]
        XCTAssertEqual(n.role, .answerer)
        XCTAssertEqual(n.remote, [.offer(sdp: "o"), .ice(sdp: "c", mid: nil, index: 0)])
        n.local(.answer(sdp: "a"))
        XCTAssertEqual(t.sentSignals.last, .answer(sdp: "a"))
    }

    func testThirdPartyJoinWithoutSealedFramesClosesAfterFiveSecondsThenRetries() {
        let c = addFriend(role: .offerer)
        manager.appDidBecomeActive()
        let t = factory.made[0]
        t.emit(.peerJoined)
        t.emit(.handshakeCompleted)  // someone's hello, but never a valid sealed frame
        clock.advance(4.9); manager.tick()
        XCTAssertFalse(t.closed)
        clock.advance(0.1); manager.tick()
        XCTAssertTrue(t.closed)
        XCTAssertTrue(negotiators.made.isEmpty, "a bare joined/hello never starts WebRTC")
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
        clock.advance(1); manager.tick()
        XCTAssertEqual(factory.made.count, 2, "reconnect after backoff")
        XCTAssertEqual(manager.linkState(for: c.id), .connecting)
    }

    func testSecureChannelTimeoutUninstallsAndRetriesWithoutPlaintext() async {
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        clock.advance(4.9); manager.tick()
        XCTAssertTrue(installer.uninstalls.isEmpty)
        clock.advance(0.1); manager.tick()
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertTrue(n.closed)
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
        // A late success is ignored.
        manager.secureChannelDidComplete(contactID: c.id, ok: true)
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
    }

    func testSecureChannelFailureAndInstallRefusalBothMapToUnreachable() async {
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        manager.secureChannelDidComplete(contactID: c.id, ok: false)
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
        clock.advance(1); manager.tick()
        installer.accept = false
        let t2 = factory.made.last!
        authenticate(t2)
        await rvWaitUntil { self.negotiators.made.count == 2 }
        negotiators.made[1].open()
        XCTAssertTrue(negotiators.made[1].closed)
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
    }

    func testNegotiationTimeout() async {
        let (c, t, n) = await negotiatingOfferer()
        clock.advance(29.9); manager.tick()
        XCTAssertFalse(n.closed)
        clock.advance(0.1); manager.tick()
        XCTAssertTrue(n.closed)
        XCTAssertTrue(t.closed)
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
    }

    func testConnectionLostRejoinsAfterBackoff() async {
        let (c, _, n) = await securedOfferer()
        let made = factory.made.count
        n.drop()  // data channel closed under us
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
        clock.advance(1); manager.tick()
        XCTAssertEqual(factory.made.count, made + 1)
        // Connection-layer report path is idempotent with the negotiator path.
        manager.connectionDidClose(contactID: c.id)
        XCTAssertEqual(factory.live().count, 1)
    }

    func testPeerLeftDuringNegotiationKeepsSocket() async {
        let (_, t, n) = await negotiatingOfferer()
        t.emit(.peerLeft)
        XCTAssertTrue(n.closed)
        XCTAssertFalse(t.closed)
    }

    // MARK: Direct-connection dedup (both orders)

    func testExistingDirectConnectionPreventsRendezvous() {
        let c = addFriend()
        direct.direct = [c.id]
        manager.appDidBecomeActive()
        XCTAssertTrue(factory.made.isEmpty)
        XCTAssertEqual(manager.linkState(for: c.id), .inactive)
        direct.set(c.id, false)
        XCTAssertEqual(factory.made.count, 1, "direct gone ⇒ join")
    }

    func testDirectConnectionAppearingClosesCrossNetwork() async {
        let (c, t, n) = await securedOfferer()
        direct.set(c.id, true)
        XCTAssertEqual(installer.uninstalls, [c.id])
        XCTAssertTrue(n.closed)
        XCTAssertTrue(t.closed)
        XCTAssertEqual(manager.roomCount, 0)
        XCTAssertEqual(manager.linkState(for: c.id), .inactive)
    }

    func testDirectAppearingBeforeInstallRefusesInstall() async {
        let (c, _, n) = await negotiatingOfferer()
        direct.direct = [c.id]  // not yet notified
        n.open()
        XCTAssertTrue(installer.installs.isEmpty)
        XCTAssertTrue(n.closed)
    }

    // MARK: Day boundary

    func dayStart(_ d: Int) -> Date { Date(timeIntervalSince1970: Double(d) * 86_400) }

    func testDayBoundaryJoinsBothTokensAndRetiresTheStaleDay() throws {
        let d = RendezvousToken.day(at: noon) + 1
        clock.now = dayStart(d).addingTimeInterval(-300)
        let c = addFriend()
        manager.appDidBecomeActive()
        XCTAssertEqual(factory.made.map(\.day).sorted(), [d - 1, d])
        let p = IdentityRendezvousSecretProvider(identity: me)
        XCTAssertEqual(factory.made.first { $0.day == d - 1 }?.token,
                       try RendezvousToken.token(provider: p, peerKey: c.identityPublicKey, day: d - 1))
        XCTAssertEqual(factory.made.first { $0.day == d }?.token,
                       try RendezvousToken.token(provider: p, peerKey: c.identityPublicKey, day: d))
        let oldToken = factory.made.first { $0.day == d - 1 }!.token
        let oldTag = tags.tag(for: oldToken)
        clock.now = dayStart(d).addingTimeInterval(600)
        manager.tick()
        XCTAssertEqual(factory.live().map(\.day), [d])
        XCTAssertNotEqual(tags.tag(for: oldToken), oldTag, "expired day's session tag forgotten")
    }

    func testDayBoundaryOffererNegotiatesOneRoomAndRetiresTheOther() async {
        let d = RendezvousToken.day(at: noon) + 1
        clock.now = dayStart(d).addingTimeInterval(-60)
        let c = addFriend(role: .offerer)
        manager.appDidBecomeActive()
        let tA = factory.made.first { $0.day == d - 1 }!, tB = factory.made.first { $0.day == d }!
        authenticate(tB)
        await rvWaitUntil { self.negotiators.made.count == 1 }
        authenticate(tA)  // parked: the slot is taken by day d
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(negotiators.made.count, 1)
        XCTAssertEqual(manager.sessionStates(for: c.id)[d - 1], .waiting)
        negotiators.made[0].open()
        XCTAssertEqual(installer.installs.count, 1)
        XCTAssertTrue(tA.closed, "the other day's room is retired")
        XCTAssertEqual(manager.sessionStates(for: c.id).keys.sorted(), [d])
        manager.secureChannelDidComplete(contactID: c.id, ok: true)
        // Past the window the connection stays up and nothing is rejoined.
        clock.now = dayStart(d).addingTimeInterval(3600)
        manager.tick()
        XCTAssertEqual(factory.live().count, 0)
        XCTAssertEqual(manager.linkState(for: c.id), .connected)
    }

    func testDayBoundaryParkedOffererTakesOverWhenSlotFrees() async {
        let d = RendezvousToken.day(at: noon) + 1
        clock.now = dayStart(d).addingTimeInterval(-60)
        _ = addFriend(role: .offerer)
        manager.appDidBecomeActive()
        let tA = factory.made.first { $0.day == d - 1 }!, tB = factory.made.first { $0.day == d }!
        authenticate(tB)
        await rvWaitUntil { self.negotiators.made.count == 1 }
        authenticate(tA)
        tB.emit(.peerLeft)  // peer abandoned day d
        await rvWaitUntil { self.negotiators.made.count == 2 }
        XCTAssertTrue(negotiators.made[0].closed)
    }

    func testDayBoundaryAnswererFollowsLatestOffer() async {
        let d = RendezvousToken.day(at: noon) + 1
        clock.now = dayStart(d).addingTimeInterval(-60)
        let c = addFriend(role: .answerer)
        manager.appDidBecomeActive()
        let tA = factory.made.first { $0.day == d - 1 }!, tB = factory.made.first { $0.day == d }!
        authenticate(tA); authenticate(tB)
        tA.emit(.signal(RendezvousSignal.offer(sdp: "1").encoded()))
        await rvWaitUntil { self.negotiators.made.count == 1 }
        tB.emit(.signal(RendezvousSignal.offer(sdp: "2").encoded()))
        await rvWaitUntil { self.negotiators.made.count == 2 }
        XCTAssertTrue(negotiators.made[0].closed, "superseded by the newer offer")
        negotiators.made[1].open()
        XCTAssertEqual(installer.installs.count, 1)
        XCTAssertTrue(tA.closed)
        XCTAssertEqual(manager.sessionStates(for: c.id).keys.sorted(), [d])
    }

    // MARK: Replay through the real client

    func testReplayedOldOfferFailsAndTriggersCloseAndReconnect() async throws {
        let sockets = FakeRVSocketFactory()
        let peer = RVPeer()
        var c = TrustedContact(deviceId: "dev-r", displayName: "r", identityPublicKey: peer.key, trustLevel: .verified, accountId: "acct-r")
        c.rendezvousEnabled = true
        contacts = [c]
        let liveFactory = TestClientFactory(provider: IdentityRendezvousSecretProvider(identity: me), sockets: sockets,
                                            tags: tags, clock: clock)
        manager = RendezvousManager(contacts: { [unowned self] in self.contacts },
                                    secrets: IdentityRendezvousSecretProvider(identity: me),
                                    direct: direct, installer: installer, signaling: liveFactory, negotiators: negotiators,
                                    clock: clock, jitter: jitter, ticker: ticker, sessionTags: tags)
        manager.appDidBecomeActive()
        await rvWaitUntil { sockets.sockets.count == 1 }
        let s = sockets.sockets[0]
        let day = RendezvousToken.day(at: noon)
        s.deliver(#"{"t":"joined"}"#)
        let oldHello = try peer.hello(towards: me.raw, day: day)
        try peer.accept(XCTUnwrap(s.sent.last))
        s.deliver(oldHello)
        let oldOffer = try peer.sealFrame(RendezvousSignal.offer(sdp: "old").encoded())
        // New session: the operator replays the old hello and the old sealed offer.
        s.deliver(#"{"t":"left"}"#)
        s.deliver(#"{"t":"joined"}"#)
        s.deliver(oldHello)
        s.deliver(oldOffer)
        XCTAssertTrue(s.closedByClient)
        XCTAssertTrue(negotiators.made.isEmpty)
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable)
        clock.advance(1); manager.tick()
        await rvWaitUntil { sockets.sockets.count == 2 }
    }

    // MARK: After the secure channel: silence

    /// Real client: once secured, the room is left; a minute and more of ticks
    /// sends no frame (no ping, no signal) on any socket and opens none.
    func testAfterSecureOKLongTicksSendNoFrameOnAnySocket() async throws {
        let sockets = FakeRVSocketFactory()
        var peer = RVPeer()
        while (try? RendezvousRole.forKeys(myKey: me.raw, peerKey: peer.key)) != .offerer { peer = RVPeer() }
        var c = TrustedContact(deviceId: "dev-q", displayName: "q", identityPublicKey: peer.key, trustLevel: .verified, accountId: "acct-q")
        c.rendezvousEnabled = true
        contacts = [c]
        manager = RendezvousManager(contacts: { [unowned self] in self.contacts },
                                    secrets: IdentityRendezvousSecretProvider(identity: me),
                                    direct: direct, installer: installer,
                                    signaling: TestClientFactory(provider: IdentityRendezvousSecretProvider(identity: me),
                                                                 sockets: sockets, tags: tags, clock: clock),
                                    negotiators: negotiators, clock: clock, jitter: jitter, ticker: ticker, sessionTags: tags)
        manager.appDidBecomeActive()
        await rvWaitUntil { sockets.sockets.count == 1 }
        let s = sockets.sockets[0]
        let day = RendezvousToken.day(at: clock.now)
        s.deliver(#"{"t":"joined"}"#)
        let peerHello = try peer.hello(towards: me.raw, day: day)
        try peer.accept(XCTUnwrap(s.sent.last))
        s.deliver(peerHello)
        XCTAssertEqual(peer.open(try XCTUnwrap(s.sent.last)), RendezvousSignal.ready.encoded())
        s.deliver(try peer.sealFrame(RendezvousSignal.ready.encoded()))
        await rvWaitUntil { self.negotiators.made.count == 1 }
        negotiators.made[0].open()
        manager.secureChannelDidComplete(contactID: c.id, ok: true)
        XCTAssertTrue(s.closedByClient)
        let sent = sockets.sockets.map(\.sent)
        for _ in 0..<6 { clock.advance(15); manager.tick() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sockets.sockets.map(\.sent), sent)
        XCTAssertEqual(sockets.sockets.count, 1)
        XCTAssertEqual(manager.linkState(for: c.id), .connected)
    }

    // MARK: Shared session-tag store (minor 5)

    func testLiveManagerSharesOneTagStoreWithItsSignalingFactory() {
        let shared = RendezvousSessionTagStore()
        let m = RendezvousManager.live(contacts: { [] }, secrets: IdentityRendezvousSecretProvider(identity: me),
                                       direct: direct, installer: installer, sessionTags: shared)
        XCTAssertTrue(m.sessionTagStore === shared)
        XCTAssertTrue((m.signalingFactory as? LiveRendezvousSignalingFactory)?.sessionTags === shared)
    }

    // MARK: Two real managers (real client + crypto) through an in-memory room

    func testTwoManagersAtDayBoundaryInstallExactlyOneConnectionOnTheSameDay() async throws {
        try await runPair(at: dayStart(RendezvousToken.day(at: noon) + 1).addingTimeInterval(-120))
    }

    func testTwoManagersMiddayConnect() async throws {
        try await runPair(at: noon)
    }

    func runPair(at now: Date) async throws {
        clock.now = now
        let hub = FakeRVRoomHub()
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        func contact(for id: RendezvousTestIdentity, name: String) -> TrustedContact {
            var c = TrustedContact(deviceId: "dev-\(name)", displayName: name, identityPublicKey: id.raw,
                                   trustLevel: .verified, accountId: "acct-\(name)")
            c.rendezvousEnabled = true
            return c
        }
        let contactB = contact(for: b, name: "b"), contactA = contact(for: a, name: "a")
        let pairs = PairedNegotiatorHub()
        func make(_ me: RendezvousTestIdentity, friend: TrustedContact) -> (RendezvousManager, FakeInstaller, FakeRVSocketFactory) {
            let sockets = FakeRVSocketFactory()
            hub.attach(sockets)
            let inst = FakeInstaller()
            let m = RendezvousManager(
                contacts: { [friend] }, secrets: IdentityRendezvousSecretProvider(identity: me),
                direct: FakeDirectChecker(), installer: inst,
                signaling: TestClientFactory(provider: IdentityRendezvousSecretProvider(identity: me), sockets: sockets,
                                             tags: RendezvousSessionTagStore(), clock: clock),
                negotiators: pairs, clock: clock, jitter: FixedRVJitter(), ticker: ManualRVTicker(),
                sessionTags: RendezvousSessionTagStore())
            inst.onInstall = { [weak m] c in DispatchQueue.main.async { m?.secureChannelDidComplete(contactID: c.id, ok: true) } }
            return (m, inst, sockets)
        }
        let (mA, instA, _) = make(a, friend: contactB)
        let (mB, instB, _) = make(b, friend: contactA)
        mA.appDidBecomeActive()
        mB.appDidBecomeActive()
        await rvWaitUntil(timeout: 10) {
            mA.linkState(for: contactB.id) == .connected && mB.linkState(for: contactA.id) == .connected
        }
        XCTAssertEqual(instA.installs.count, 1)
        XCTAssertEqual(instB.installs.count, 1)
        let dayA = mA.sessionStates(for: contactB.id).keys.sorted()
        let dayB = mB.sessionStates(for: contactA.id).keys.sorted()
        XCTAssertEqual(dayA.count, 1)
        XCTAssertEqual(dayA, dayB, "both ends chose the same day")
        XCTAssertEqual(pairs.opened, 1, "exactly one WebRTC connection opened")
        // Every room socket was left once secured.
        await rvWaitUntil { hub.openSockets == 0 }
    }
}

// MARK: - Test factories / hubs

@MainActor
final class TestClientFactory: RendezvousSignalingTransportFactory {
    let provider: RendezvousSecretProvider
    let sockets: FakeRVSocketFactory
    let tags: RendezvousSessionTagStore
    let clock: FakeRVClock
    init(provider: RendezvousSecretProvider, sockets: FakeRVSocketFactory, tags: RendezvousSessionTagStore, clock: FakeRVClock) {
        self.provider = provider; self.sockets = sockets; self.tags = tags; self.clock = clock
    }
    func makeTransport(token: Data, day: Int, peerKey: Data) -> RendezvousSignalingTransport {
        RendezvousSignalingClient(token: token, day: day, peerKey: peerKey, provider: provider, sessionTags: tags,
                                  baseURL: URL(string: "https://rv.example.test")!, socketFactory: sockets,
                                  http: FakeRVHTTP(), clock: { [clock] in clock.now })
    }
}

/// In-memory stand-in for the Worker + RendezvousRoom DO: first frame picks
/// the room, 2-socket cap, `joined` to both when full, blind relay, `left` on
/// close, "ping" → "pong". Deliveries are asynchronous and FIFO.
@MainActor
final class FakeRVRoomHub {
    private var rooms: [String: [FakeRVSocket]] = [:]
    private var roomOf: [ObjectIdentifier: String] = [:]
    var openSockets: Int { rooms.values.reduce(0) { $0 + $1.count } }

    func attach(_ factory: FakeRVSocketFactory) {
        factory.onMake = { [unowned self] s in
            s.onSend = { [unowned self, unowned s] text in self.received(text, from: s) }
            s.onClientClose = { [unowned self, unowned s] in self.gone(s) }
        }
    }

    private func later(_ s: FakeRVSocket, _ text: String) {
        DispatchQueue.main.async { s.deliver(text) }
    }

    private func received(_ text: String, from s: FakeRVSocket) {
        let id = ObjectIdentifier(s)
        guard let room = roomOf[id] else {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let t = obj["t"] as? String else { DispatchQueue.main.async { s.remoteClose() }; return }
            if rooms[t, default: []].count >= 2 { DispatchQueue.main.async { s.remoteClose() }; return }
            rooms[t, default: []].append(s)
            roomOf[id] = t
            if rooms[t]!.count == 2 { rooms[t]!.forEach { later($0, #"{"t":"joined"}"#) } }
            return
        }
        if text == "ping" { later(s, "pong"); return }
        for other in rooms[room] ?? [] where other !== s { later(other, text) }
    }

    private func gone(_ s: FakeRVSocket) {
        let id = ObjectIdentifier(s)
        guard let room = roomOf.removeValue(forKey: id) else { return }
        rooms[room]?.removeAll { $0 === s }
        for other in rooms[room] ?? [] { later(other, #"{"t":"left"}"#) }
        if rooms[room]?.isEmpty == true { rooms[room] = nil }
    }
}

/// Pairs an offerer and an answerer by the SDP they exchange (no WebRTC).
@MainActor
final class PairedNegotiatorHub: RendezvousNegotiatorFactory {
    private(set) var opened = 0
    fileprivate var offerers: [String: PairedNegotiator] = [:]
    func makeNegotiator(role: RendezvousRole, iceServers: [RendezvousICEServer]) -> RendezvousNegotiator {
        PairedNegotiator(role: role, hub: self)
    }
    fileprivate func open(_ x: PairedNegotiator, _ y: PairedNegotiator) {
        opened += 1
        DispatchQueue.main.async {
            x.onOpen?(FakeRVTransport(label: "x"))
            y.onOpen?(FakeRVTransport(label: "y"))
        }
    }
}

@MainActor
final class PairedNegotiator: RendezvousNegotiator {
    var onLocalSignal: ((RendezvousSignal) -> Void)?
    var onOpen: ((TransportProtocol) -> Void)?
    var onClosed: (() -> Void)?
    let role: RendezvousRole
    unowned let hub: PairedNegotiatorHub
    private var id = UUID().uuidString
    private var closed = false
    fileprivate var answerer: PairedNegotiator?

    init(role: RendezvousRole, hub: PairedNegotiatorHub) { self.role = role; self.hub = hub }

    func start() {
        guard role == .offerer else { return }
        hub.offerers[id] = self
        let sdp = "offer:\(id)"
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.onLocalSignal?(.offer(sdp: sdp))
        }
    }

    func handleRemote(_ signal: RendezvousSignal) {
        guard !closed else { return }
        switch (signal, role) {
        case (.offer(let sdp), .answerer):
            id = String(sdp.dropFirst("offer:".count))
            guard let offerer = hub.offerers[id] else { return }
            offerer.answerer = self
            let answer = "answer:\(id)"
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.onLocalSignal?(.answer(sdp: answer))
            }
        case (.answer(let sdp), .offerer):
            guard sdp == "answer:\(id)", let a = answerer, !a.closed else { return }
            hub.open(self, a)
        default:
            break
        }
    }

    func close() {
        closed = true
        hub.offerers[id] = nil
    }
}

// MARK: - Task 5 fix round 1, I-4: local failure reasons and suspension

extension RendezvousManagerTests {

    /// N-1: a handshake-key mismatch happens BEFORE key confirmation, so an
    /// unauthenticated on-path party can cause it: never a suspension, only
    /// the normal (capped) backoff.
    func testKeyMismatchIsRecordedButNotSuspended() async { await assertRecordedAndRetried(.keyMismatch) }
    func testUnauthenticatedHelloMismatchIsNotSuspended() async {
        await assertRecordedAndRetried(.helloMismatchUnauthenticated)
    }

    /// Suspended by an authenticated (envelope) HELLO mismatch after verify.
    private func suspendedFriend() async -> TrustedContact {
        let (c, _, _) = await securedOfferer()
        manager.connectionDidClose(contactID: c.id, reason: .helloMismatch)
        XCTAssertEqual(manager.roomCount, 0)
        return c
    }

    func testClearSuspensionRejoins() async {
        let c = await suspendedFriend()
        manager.clearSuspension(contactID: c.id)
        XCTAssertEqual(manager.roomCount, 1)
    }

    func testOptInToggleClearsSuspension() async {
        _ = await suspendedFriend()
        contacts[0].rendezvousEnabled = nil
        manager.contactsDidChange()
        contacts[0].rendezvousEnabled = true
        manager.contactsDidChange()
        XCTAssertEqual(manager.roomCount, 1)
    }

    func testForegroundAfterFiveMinutesClearsSuspension() async {
        _ = await suspendedFriend()
        manager.appDidEnterBackground()
        clock.advance(60)
        manager.appDidBecomeActive()
        XCTAssertEqual(manager.roomCount, 0, "still suspended after a short background")
        manager.appDidEnterBackground()
        clock.advance(RendezvousManager.suspensionForegroundReset + 1)
        manager.appDidBecomeActive()
        XCTAssertEqual(manager.roomCount, 1)
    }

    func testHelloMismatchAfterVerifySuspendsUntilTheDeviceIdChanges() async {
        let (c, _, _) = await securedOfferer()
        manager.connectionDidClose(contactID: c.id, reason: .helloMismatch)
        XCTAssertEqual(manager.lastFailureReason(for: c.id), .helloMismatch)
        let made = factory.made.count
        for _ in 0..<10 { clock.advance(60); manager.tick() }
        XCTAssertEqual(factory.made.count, made)
        XCTAssertEqual(manager.roomCount, 0)
        contacts[0].deviceId = "dev-new-\(UUID().uuidString)"
        manager.contactsDidChange()
        XCTAssertEqual(manager.roomCount, 1)
    }

    private func assertRecordedAndRetried(_ reason: RendezvousConnectionFailure, line: UInt = #line) async {
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        manager.secureChannelDidComplete(contactID: c.id, ok: false, reason: reason)
        XCTAssertEqual(manager.lastFailureReason(for: c.id), reason, line: line)
        XCTAssertEqual(manager.linkState(for: c.id), .unreachable, line: line)
        let made = factory.made.count
        clock.advance(1); manager.tick()
        XCTAssertEqual(factory.made.count, made + 1, "\(reason): rejoins after backoff", line: line)
    }

    func testTimeoutIsRecordedButRetried() async { await assertRecordedAndRetried(.timeout) }
    func testDecryptFailureIsRecordedButRetried() async { await assertRecordedAndRetried(.decryptFailed) }
    func testBindingFailureIsRecordedButRetried() async { await assertRecordedAndRetried(.bindingFailed) }
    func testChannelFailureIsRecordedButRetried() async { await assertRecordedAndRetried(.channelFailed) }

    func testInstallRefusalIsRecorded() async {
        installer.accept = false
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        XCTAssertEqual(manager.lastFailureReason(for: c.id), .installRefused)
        XCTAssertNotEqual(manager.roomCount, 0, "refusal is not a suspension")
    }

    // MARK: Task 6 fix round 1 (I3): lastFailures lifecycle

    func testFailureClearedWhenOptInTurnedOff() async {
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        manager.secureChannelDidComplete(contactID: c.id, ok: false, reason: .keyMismatch)
        XCTAssertEqual(manager.lastFailureReason(for: c.id), .keyMismatch)
        contacts[0].rendezvousEnabled = nil
        manager.contactsDidChange()
        XCTAssertNil(manager.lastFailureReason(for: c.id))
    }

    func testFailureClearedWhenKeyOrDeviceIdChanges() async {
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        manager.secureChannelDidComplete(contactID: c.id, ok: false, reason: .keyMismatch)
        contacts[0].deviceId = "dev-changed-\(UUID().uuidString)"
        manager.contactsDidChange()
        XCTAssertNil(manager.lastFailureReason(for: c.id))
    }

    func testFailureClearedByClearSuspension() async {
        let c = await suspendedFriend()
        XCTAssertEqual(manager.lastFailureReason(for: c.id), .helloMismatch)
        manager.clearSuspension(contactID: c.id)
        XCTAssertNil(manager.lastFailureReason(for: c.id))
    }

    func testFailureClearedOnSuccessfulConnect() async {
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        manager.secureChannelDidComplete(contactID: c.id, ok: false, reason: .timeout)
        XCTAssertEqual(manager.lastFailureReason(for: c.id), .timeout)
        manager.secureChannelDidComplete(contactID: c.id, ok: true)
        XCTAssertNil(manager.lastFailureReason(for: c.id))
    }

    func testFailureSurvivesUnrelatedContactChange() async {
        let (c, _, n) = await negotiatingOfferer()
        n.open()
        manager.secureChannelDidComplete(contactID: c.id, ok: false, reason: .keyMismatch)
        manager.contactsDidChange()
        XCTAssertEqual(manager.lastFailureReason(for: c.id), .keyMismatch)
    }
}

// MARK: - Final review: no 1 Hz ticker without active contacts

extension RendezvousManagerTests {
    func testTickerRunsOnlyWhileContactsAreActive() {
        manager.appDidBecomeActive()
        XCTAssertFalse(ticker.running, "no eligible contact: no ticker")
        addFriend()
        manager.contactsDidChange()
        XCTAssertTrue(ticker.running)
        contacts[0].rendezvousEnabled = nil
        manager.contactsDidChange()
        XCTAssertEqual(manager.roomCount, 0)
        XCTAssertFalse(ticker.running, "last contact gone: ticker stops")
        manager.appDidEnterBackground()
        contacts[0].rendezvousEnabled = true
        manager.contactsDidChange()
        XCTAssertFalse(ticker.running, "never in background")
    }
}
