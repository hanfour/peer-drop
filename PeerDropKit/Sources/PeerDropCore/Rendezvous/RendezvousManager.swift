import Foundation
import Combine
import PeerDropSecurity
import PeerDropTransport

// Project E — owns every rendezvous room ("always connected" friends).
//
// - One `RendezvousSession` per (contact, UTC day). Near midnight two days are
//   joined (`RendezvousToken.daysToJoin`): separate sockets and handshakes per
//   token. Only the OFFERER chooses which room negotiates (at most one per
//   contact at a time; others park); the answerer follows the latest offer, so
//   both ends always negotiate in the same room ⇒ same day. Once a room
//   installs a connection every other room of that contact is retired.
// - At most `TrustedContactStore.maxRendezvousContacts` contacts, eligible by
//   the same rule as `FriendBinding.verifiedAccount` (re-checked on every
//   reconcile, so a pending re-exchange, block or key change suspends at once).
// - Foreground only. Background / downgrade close sockets and connections and
//   send nothing. A direct (nearby) connection always wins.
// - Never logs (tokens, keys, IPs, session values, friend relationships).
//
// Seams for Task 5 (ConnectionManager): `DirectConnectionChecker`,
// `RendezvousConnectionInstaller`, `secureChannelDidComplete(contactID:ok:)`,
// `connectionDidClose(contactID:)`, `appDidBecomeActive()`,
// `appDidEnterBackground()`, `contactsDidChange()`.

/// Coarse per-contact status for presence/UI. `unreachable` is the ONLY
/// failure value: causes are never distinguished.
public enum RendezvousLinkState: Equatable {
    case inactive
    case connecting
    case connected
    case unreachable
}

/// Why the connection layer gave up on an installed rendezvous connection.
/// LOCAL diagnostics only (Task 6): kept in memory per contact, never logged,
/// never sent, and never shown in a way that tells "they turned me off" apart
/// from "they're offline" (presence stays offline / unreachable either way).
public enum RendezvousConnectionFailure: Equatable, Sendable {
    /// The handshake key is not the pinned contact key.
    case keyMismatch
    /// Binding, opt-in or eligibility no longer holds.
    case bindingFailed
    /// A HELLO claimed a key other than the pinned / handshake key.
    case helloMismatch
    /// No confirmed secure channel within the deadline.
    case timeout
    /// An envelope from the peer did not decrypt.
    case decryptFailed
    /// The secure channel could not be negotiated (send failed, no support).
    case channelFailed
    /// The connection layer refused the install.
    case installRefused
    /// Closed (peer hung up, transport dropped, local disconnect).
    case connectionClosed

    /// Pinned-identity contradictions: the room stays suspended until the
    /// contact's key or device id changes (no retry loop against them).
    public var suspendsRoom: Bool { self == .keyMismatch || self == .helloMismatch }
}

@MainActor
public protocol DirectConnectionChecker: AnyObject {
    /// A direct (nearby / local) connection to this contact exists.
    func hasDirectConnection(to contact: TrustedContact) -> Bool
    /// Set by the manager; the owner calls it whenever direct connections change.
    var onDirectConnectionsChanged: (() -> Void)? { get set }
}

@MainActor
public protocol RendezvousConnectionInstaller: AnyObject {
    /// Hand an open data channel to the connection layer (keyed by
    /// `contact.deviceId`, strict secure-channel policy). Return false to refuse
    /// (e.g. the key is already in use); the manager then closes it and backs off.
    /// The installer reports the outcome via `secureChannelDidComplete` and
    /// `connectionDidClose`.
    func install(transport: TransportProtocol, contact: TrustedContact) -> Bool
    /// Remove a previously installed connection. Must not send any farewell
    /// frame (downgrade must look like going offline).
    func uninstall(contact: TrustedContact)
}

/// WebRTC side of one negotiation attempt. Callbacks must not fire
/// synchronously from `close()`.
@MainActor
public protocol RendezvousNegotiator: AnyObject {
    var onLocalSignal: ((RendezvousSignal) -> Void)? { get set }
    var onOpen: ((TransportProtocol) -> Void)? { get set }
    /// Failure before open, or the channel closing after open.
    var onClosed: (() -> Void)? { get set }
    func start()
    func handleRemote(_ signal: RendezvousSignal)
    func close()
}

@MainActor
public protocol RendezvousNegotiatorFactory: AnyObject {
    /// `iceServers` empty ⇒ use the default STUN servers. Policy is always `.all`.
    func makeNegotiator(role: RendezvousRole, iceServers: [RendezvousICEServer]) -> RendezvousNegotiator
}

public protocol RendezvousClock: AnyObject {
    var now: Date { get }
}

public final class SystemRendezvousClock: RendezvousClock {
    public init() {}
    public var now: Date { Date() }
}

/// Jitter in seconds, expected 0…30 (clamped by the session).
public protocol RendezvousJitterSource: AnyObject {
    func jitter() -> TimeInterval
}

public final class SystemRendezvousJitter: RendezvousJitterSource {
    public init() {}
    public func jitter() -> TimeInterval {
        var rng = SystemRandomNumberGenerator()
        return Double.random(in: 0...RendezvousSession.maxJitter, using: &rng)
    }
}

@MainActor
public protocol RendezvousTicker: AnyObject {
    func start(_ tick: @escaping @MainActor () -> Void)
    func stop()
}

/// 1 Hz main-run-loop timer in the COMMON modes, so it keeps firing (and the
/// signaling keepalive keeps going) while iOS scroll tracking runs the run loop
/// in `UITrackingRunLoopMode`; a default-mode timer would pause there and the
/// Worker would cut the socket after 90 s. Invalidated on `stop()` and deinit.
@MainActor
public final class TimerRendezvousTicker: RendezvousTicker {
    // nonisolated(unsafe): touched from `deinit`; the ticker lives and dies on the main thread.
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var fireCount = 0
    public init() {}
    var timerForTesting: Timer? { timer }
    var timerFireCountForTesting: Int { fireCount }
    public func start(_ tick: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.fireCount += 1
            Task { @MainActor in tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    public func stop() {
        timer?.invalidate()
        timer = nil
    }
    deinit {
        timer?.invalidate()
    }
}

@MainActor
public final class RendezvousManager: ObservableObject {

    @Published public private(set) var linkStates: [UUID: RendezvousLinkState] = [:]
    public private(set) var isForeground = false

    private struct Key: Hashable {
        let contactID: UUID
        let day: Int
    }

    private final class Room {
        var session: RendezvousSession
        var contact: TrustedContact
        let peerKey: Data
        var transport: RendezvousSignalingTransport?
        var negotiator: RendezvousNegotiator?
        /// Attempt the current/pending negotiator belongs to.
        var negotiatorAttempt = 0
        var pendingRemote: [RendezvousSignal] = []
        var openTransport: TransportProtocol?
        var installed = false
        init(session: RendezvousSession, contact: TrustedContact) {
            self.session = session
            self.contact = contact
            self.peerKey = contact.identityPublicKey
        }
    }

    private static let maxPendingRemoteSignals = 64

    private let contacts: () -> [TrustedContact]
    private let secrets: RendezvousSecretProvider
    private let direct: DirectConnectionChecker
    private let installer: RendezvousConnectionInstaller
    private let signaling: RendezvousSignalingTransportFactory
    private let negotiators: RendezvousNegotiatorFactory
    private let clock: RendezvousClock
    private let jitterSource: RendezvousJitterSource
    private let ticker: RendezvousTicker
    private let sessionTags: RendezvousSessionTagStore

    private var rooms: [Key: Room] = [:]
    /// Last connection-layer failure per contact (in memory, never logged).
    private var lastFailures: [UUID: RendezvousConnectionFailure] = [:]
    /// Contacts suspended after a pinned-identity contradiction, with the
    /// key + device id they were suspended at.
    private struct Suspension: Equatable { let key: Data; let deviceId: String? }
    private var suspensions: [UUID: Suspension] = [:]
    private var queue: [(Key, RendezvousSession.Event)] = []
    private var draining = false
    /// Entry points called re-entrantly while the queue drains (e.g. from
    /// inside `installer.install`) run after the drain, never mid-transition.
    private var deferredCalls: [() -> Void] = []

    private func deferIfDraining(_ call: @escaping () -> Void) -> Bool {
        guard draining else { return false }
        deferredCalls.append(call)
        return true
    }

    public init(
        contacts: @escaping () -> [TrustedContact],
        secrets: RendezvousSecretProvider,
        direct: DirectConnectionChecker,
        installer: RendezvousConnectionInstaller,
        signaling: RendezvousSignalingTransportFactory,
        negotiators: RendezvousNegotiatorFactory,
        clock: RendezvousClock = SystemRendezvousClock(),
        jitter: RendezvousJitterSource = SystemRendezvousJitter(),
        ticker: RendezvousTicker? = nil,
        sessionTags: RendezvousSessionTagStore = .process
    ) {
        self.contacts = contacts
        self.secrets = secrets
        self.direct = direct
        self.installer = installer
        self.signaling = signaling
        self.negotiators = negotiators
        self.clock = clock
        self.jitterSource = jitter
        self.ticker = ticker ?? TimerRendezvousTicker()
        self.sessionTags = sessionTags
        direct.onDirectConnectionsChanged = { [weak self] in self?.reconcile() }
    }

    // MARK: - Public API (Task 5 wiring)

    public func appDidBecomeActive() {
        if deferIfDraining({ [weak self] in self?.appDidBecomeActive() }) { return }
        guard !isForeground else { return }
        isForeground = true
        ticker.start { [weak self] in self?.tick() }
        reconcile()
    }

    /// Closes every socket and connection; sends nothing.
    public func appDidEnterBackground() {
        if deferIfDraining({ [weak self] in self?.appDidEnterBackground() }) { return }
        isForeground = false
        ticker.stop()
        for key in rooms.keys { enqueue(key, .appBackground) }
        drain()
        rooms.removeAll()
        publishLinkStates()
    }

    /// Call when `TrustedContactStore.contacts` changes (opt-in, binding, key).
    public func contactsDidChange() {
        reconcile()
    }

    public func tick() {
        if deferIfDraining({ [weak self] in self?.tick() }) { return }
        let now = clock.now
        for (key, room) in rooms {
            room.transport?.tick(now: now)
            enqueue(key, .tick)
        }
        drain()
        reconcile()
    }

    /// The connection layer finished the pinned-key secure channel on an
    /// installed rendezvous connection (`ok == false`: mismatch, plaintext, timeout).
    public func secureChannelDidComplete(contactID: UUID, ok: Bool, reason: RendezvousConnectionFailure? = nil) {
        if !ok, let reason { recordFailure(reason, contactID: contactID) }
        for (key, room) in rooms where key.contactID == contactID && room.installed {
            enqueue(key, .secureChannelResult(ok: ok))
        }
        drain()
        if !ok, reason?.suspendsRoom == true { reconcile() }
    }

    /// The installed connection was torn down by the connection layer.
    public func connectionDidClose(contactID: UUID, reason: RendezvousConnectionFailure? = nil) {
        if let reason { recordFailure(reason, contactID: contactID) }
        for (key, room) in rooms where key.contactID == contactID && room.installed {
            room.installed = false
            enqueue(key, .connectionLost)
        }
        drain()
        if reason?.suspendsRoom == true { reconcile() }
    }

    /// Last local failure reason for `contactID` (Task 6 diagnostics). In
    /// memory only; never logged.
    public func lastFailureReason(for contactID: UUID) -> RendezvousConnectionFailure? {
        lastFailures[contactID]
    }

    private func recordFailure(_ reason: RendezvousConnectionFailure, contactID: UUID) {
        lastFailures[contactID] = reason
        guard reason.suspendsRoom, let c = contacts().first(where: { $0.id == contactID }) else { return }
        suspensions[contactID] = Suspension(key: c.identityPublicKey, deviceId: c.deviceId)
    }

    /// Enabled + eligible + not suspended. A suspension lifts once the
    /// contact's key or device id differs from the one it was suspended at.
    private func currentActiveContacts() -> [TrustedContact] {
        let all = contacts()
        for (id, s) in suspensions {
            guard let c = all.first(where: { $0.id == id }),
                  c.identityPublicKey == s.key, c.deviceId == s.deviceId else {
                suspensions[id] = nil
                continue
            }
        }
        return Self.activeContacts(all, excluding: Set(suspensions.keys))
    }

    public func linkState(for contactID: UUID) -> RendezvousLinkState {
        linkStates[contactID] ?? .inactive
    }

    /// Test/diagnostic view: session states per (contact, day). Never logged.
    func sessionStates(for contactID: UUID) -> [Int: RendezvousSession.State] {
        var out: [Int: RendezvousSession.State] = [:]
        for (key, room) in rooms where key.contactID == contactID { out[key.day] = room.session.state }
        return out
    }

    var roomCount: Int { rooms.count }
    var tickerForTesting: RendezvousTicker { ticker }
    var sessionTagStore: RendezvousSessionTagStore { sessionTags }
    var signalingFactory: RendezvousSignalingTransportFactory { signaling }

    // MARK: - Reconcile

    /// Enabled + eligible contacts, deterministic order, capped at 5.
    static func activeContacts(_ all: [TrustedContact], excluding excluded: Set<UUID> = []) -> [TrustedContact] {
        Array(all
            .filter { !excluded.contains($0.id) }
            .filter { $0.isRendezvousEnabled && TrustedContactStore.isRendezvousEligible($0, among: all) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .prefix(TrustedContactStore.maxRendezvousContacts))
    }

    private func reconcile() {
        if deferIfDraining({ [weak self] in self?.reconcile() }) { return }
        let now = clock.now
        let before = currentActiveContacts()
        let byID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })

        // Drop rooms of contacts that are gone, disabled, ineligible or re-keyed.
        for (key, room) in rooms {
            guard let c = byID[key.contactID], c.identityPublicKey == room.peerKey else {
                enqueue(key, .disabled)
                continue
            }
            room.contact = c
        }
        drain()
        removeClosedRooms(forgetTokens: false)

        // Re-read: closing rooms above can call back into the connection layer
        // (e.g. `uninstall`), which may change the contacts (round 2, c).
        let active = currentActiveContacts()

        if isForeground {
            let days = RendezvousToken.daysToJoin(now: now)
            for contact in active {
                let keys = rooms.keys.filter { $0.contactID == contact.id }
                if direct.hasDirectConnection(to: contact) {
                    keys.forEach { enqueue($0, .directConnectionPresent) }
                    continue
                }
                if let winner = keys.first(where: { rooms[$0]?.session.state == .connected }) {
                    keys.filter { $0 != winner }.forEach { enqueue($0, .retire) }
                    continue
                }
                for key in keys where !days.contains(key.day) { enqueue(key, .retire) }
                for day in days where rooms[Key(contactID: contact.id, day: day)] == nil {
                    createRoom(contact: contact, day: day)
                }
            }
            drain()
        }
        removeClosedRooms(forgetTokens: true)
        publishLinkStates()
    }

    private func createRoom(contact: TrustedContact, day: Int) {
        guard let token = try? RendezvousToken.token(provider: secrets, peerKey: contact.identityPublicKey, day: day),
              let role = try? RendezvousRole.forKeys(myKey: secrets.localAgreementPublicKey, peerKey: contact.identityPublicKey)
        else { return }
        let key = Key(contactID: contact.id, day: day)
        rooms[key] = Room(session: RendezvousSession(contactID: contact.id, day: day, token: token, role: role),
                          contact: contact)
        enqueue(key, .enabled)
        enqueue(key, .appForeground)
    }

    private func removeClosedRooms(forgetTokens: Bool) {
        let days = Set(RendezvousToken.daysToJoin(now: clock.now))
        for (key, room) in rooms where room.session.state == .closed {
            closeNegotiator(room)
            room.transport?.onEvent = nil
            room.transport?.close()
            rooms[key] = nil
            if forgetTokens, !days.contains(key.day) { sessionTags.forget(tokens: [room.session.token]) }
        }
    }

    // MARK: - Event queue

    private func enqueue(_ key: Key, _ event: RendezvousSession.Event) {
        queue.append((key, event))
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        while !queue.isEmpty {
            let (key, event) = queue.removeFirst()
            process(key, event)
        }
        removeClosedRooms(forgetTokens: true)
        draining = false
        publishLinkStates()
        while !deferredCalls.isEmpty {
            deferredCalls.removeFirst()()
        }
    }

    private func siblings(of key: Key) -> [Key] {
        rooms.keys.filter { $0.contactID == key.contactID && $0 != key }
    }

    private func process(_ key: Key, _ event: RendezvousSession.Event) {
        guard let room = rooms[key] else { return }
        let siblingBusy = siblings(of: key).contains { rooms[$0]?.session.holdsSlot == true }
        let context = RendezvousSession.Context(siblingBusy: siblingBusy, jitter: jitterSource.jitter())
        let wasHolding = room.session.holdsSlot
        let actions = room.session.handle(event, now: clock.now, context: context)
        for action in actions { perform(action, key: key, room: room) }
        let holding = room.session.holdsSlot
        if !wasHolding && holding {
            for s in siblings(of: key) where rooms[s]?.session.state == .negotiating { enqueue(s, .siblingNegotiating) }
        } else if wasHolding && !holding {
            siblings(of: key).forEach { enqueue($0, .negotiationSlotFree) }
        }
    }

    private func perform(_ action: RendezvousSession.Action, key: Key, room: Room) {
        switch action {
        case .joinRoom(let token):
            if direct.hasDirectConnection(to: room.contact) {
                enqueue(key, .directConnectionPresent)
                return
            }
            let t = signaling.makeTransport(token: token, day: key.day, peerKey: room.peerKey)
            room.transport = t
            t.onEvent = { [weak self, weak t] event in
                guard let self, let t else { return }
                self.signalingEvent(event, key: key, from: t)
            }
            t.connect()

        case .leaveRoom:
            room.transport?.onEvent = nil
            room.transport?.close()
            room.transport = nil

        case .sendSignal(let data):
            room.transport?.sendSignal(data)

        case .startNegotiation(let role, let attempt):
            closeNegotiator(room)
            room.negotiatorAttempt = attempt
            let transport = room.transport
            // The fetch is bound to THIS Room object: a room recreated for the
            // same (contact, day) restarts `attempt` at 1 and must not adopt it.
            Task { [weak self, weak room] in
                let servers = await transport?.fetchICEServers() ?? []
                guard let self, let room else { return }
                self.negotiatorReady(key: key, room: room, role: role, attempt: attempt, servers: servers)
            }

        case .deliverRemoteSignal(let signal, let attempt):
            guard attempt == room.negotiatorAttempt else { return }
            if let n = room.negotiator {
                n.handleRemote(signal)
            } else if room.pendingRemote.count < Self.maxPendingRemoteSignals {
                room.pendingRemote.append(signal)
            }

        case .installConnection(let attempt):
            guard attempt == room.negotiatorAttempt, let transport = room.openTransport else {
                enqueue(key, .installFailed)
                return
            }
            let contact = contacts().first { $0.id == key.contactID } ?? room.contact
            if direct.hasDirectConnection(to: contact) {
                enqueue(key, .directConnectionPresent)
                return
            }
            // Mark installed BEFORE the call: the installer may synchronously
            // report `secureChannelDidComplete` / `connectionDidClose`, which
            // only target installed rooms (and only enqueue while draining).
            room.installed = true
            if installer.install(transport: transport, contact: contact) {
                siblings(of: key).forEach { enqueue($0, .retire) }
            } else {
                room.installed = false
                lastFailures[key.contactID] = .installRefused
                enqueue(key, .installFailed)
            }

        case .closeConnection:
            closeNegotiator(room)

        case .scheduleRetry:
            break  // `tick` drives retries
        }
    }

    private func closeNegotiator(_ room: Room) {
        let n = room.negotiator
        room.negotiator = nil
        room.pendingRemote = []
        room.openTransport = nil
        n?.onLocalSignal = nil
        n?.onOpen = nil
        n?.onClosed = nil
        n?.close()
        if room.installed {
            room.installed = false
            installer.uninstall(contact: room.contact)
        }
    }

    private func negotiatorReady(key: Key, room: Room, role: RendezvousRole, attempt: Int, servers: [RendezvousICEServer]) {
        guard rooms[key] === room, room.session.state == .negotiating, room.session.attempt == attempt,
              room.negotiatorAttempt == attempt, room.negotiator == nil else { return }
        let n = negotiators.makeNegotiator(role: role, iceServers: servers)
        room.negotiator = n
        n.onLocalSignal = { [weak self, weak n] signal in
            guard let self, let n, self.rooms[key]?.negotiator === n else { return }
            self.enqueue(key, .localSignal(signal))
            self.drain()
        }
        n.onOpen = { [weak self, weak n] transport in
            guard let self, let n, let room = self.rooms[key], room.negotiator === n else { return }
            room.openTransport = transport
            self.enqueue(key, .dataChannelOpen)
            self.drain()
        }
        n.onClosed = { [weak self, weak n] in
            guard let self, let n, let room = self.rooms[key], room.negotiator === n else { return }
            self.enqueue(key, room.session.state == .connected ? .connectionLost : .negotiationFailed)
            self.drain()
        }
        n.start()
        let pending = room.pendingRemote
        room.pendingRemote = []
        pending.forEach { n.handleRemote($0) }
    }

    private func signalingEvent(_ event: RendezvousSignalingEvent, key: Key, from t: RendezvousSignalingTransport) {
        guard let room = rooms[key], room.transport === t else { return }
        switch event {
        case .peerJoined: enqueue(key, .peerJoined)
        case .peerLeft: enqueue(key, .peerLeft)
        case .handshakeCompleted: enqueue(key, .signalingReady)
        case .signal(let data): enqueue(key, .signal(data))
        case .closed:
            room.transport = nil
            enqueue(key, .signalingClosed)
        }
        drain()
    }

    // MARK: - Link state

    private func publishLinkStates() {
        var states: [UUID: RendezvousLinkState] = [:]
        var byContact: [UUID: [RendezvousSession]] = [:]
        for (key, room) in rooms { byContact[key.contactID, default: []].append(room.session) }
        for (id, sessions) in byContact {
            if sessions.contains(where: { $0.isSecured }) {
                states[id] = .connected
            } else if sessions.contains(where: {
                switch $0.state {
                case .waiting, .negotiating, .connected: return true
                case .idle: return $0.pendingJoinAt != nil
                default: return false
                }
            }) {
                states[id] = .connecting
            } else if sessions.contains(where: { if case .failed = $0.state { return true } else { return false } }) {
                states[id] = .unreachable
            }
        }
        // A suspended contact looks like any other failure: unreachable.
        if !suspensions.isEmpty {
            let enabled = Set(contacts().filter(\.isRendezvousEnabled).map(\.id))
            for id in suspensions.keys where states[id] == nil && enabled.contains(id) { states[id] = .unreachable }
        }
        if states != linkStates { linkStates = states }
    }
}

// MARK: - Production signaling factory

@MainActor
public final class LiveRendezvousSignalingFactory: RendezvousSignalingTransportFactory {
    private let provider: RendezvousSecretProvider
    private let baseURL: URL
    let sessionTags: RendezvousSessionTagStore
    private let sockets = URLSessionRendezvousWebSocketFactory()

    public init(provider: RendezvousSecretProvider = IdentityRendezvousSecretProvider(),
                baseURL: URL = WorkerURL.current(),
                sessionTags: RendezvousSessionTagStore = .process) {
        self.provider = provider
        self.baseURL = baseURL
        self.sessionTags = sessionTags
    }

    public func makeTransport(token: Data, day: Int, peerKey: Data) -> RendezvousSignalingTransport {
        RendezvousSignalingClient(token: token, day: day, peerKey: peerKey, provider: provider,
                                  sessionTags: sessionTags, baseURL: baseURL, socketFactory: sockets,
                                  http: URLSessionRendezvousHTTPPoster())
    }
}
