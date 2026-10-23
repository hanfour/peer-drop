import Foundation
import PeerDropNotes
import Network
import Combine
import CryptoKit
import PeerDropTransport
import PeerDropProtocol
import PeerDropSecurity
import PeerDropAccount
import os

private let nxLogger = Logger(subsystem: "com.hanfour.peerdrop", category: "NotesExchange")

/// Per-`PeerConnection` holder for one `NotesExchangeSession` (Ruling 4).
/// Keyed by `ObjectIdentifier` in the CM; `connection` is weak and compared
/// by identity on every lookup, so a later object at the same address can
/// never inherit it.
final class NotesExchangeSessionBox {
    weak var connection: PeerConnection?
    let peerID: String
    var session = NotesExchangeSession()
    var tickTask: Task<Void, Never>?
    /// Serial chain of this session's outgoing frames (intent → reveal order).
    var sendTail: Task<Void, Never>?
    /// Peer intents + cancels received (harassment guard).
    var peerToggles = 0
    /// The peer reveal passed the offline checks and waits for the directory
    /// (live verification, or a persisted pending binding being retried).
    var awaitingDirectory: (accountId: String, handshakeKey: Data)?
    /// Set on teardown: queued frames of this session never go out.
    var tornDown = false

    init(connection: PeerConnection) {
        self.connection = connection
        self.peerID = connection.id
    }
}

/// Notes-account exchange over the local secure channel (spec §4.1, §4.2,
/// §10; plan Task 4). Security model, in order:
///
/// 1. Receive: only `.notesExchange` frames that came out of a secure
///    envelope on a `.secured` connection that is still the installed entry,
///    and only when `NotesExchangeGate` allows that same connection. Anything
///    else is dropped without a state change, reply or log of content.
/// 2. Send: only on the validated `PeerConnection` instance, built in the
///    same main-actor turn, and only while it has a secure channel (so
///    `sendMessage` always wraps it; it never goes out as plaintext). The gate
///    is re-run before every send, including right before signing a reveal.
/// 3. Verify a peer reveal: strict account id → signature over this
///    connection's role-ordered digest (offline, no network) → directory
///    lookup by id without bundle → `entry.accountId`, `identityKey ==
///    handshake key`, `signingKey` all equal. Only then is anything bound.
///    A pending binding is persisted only after the offline checks passed and
///    the directory was unreachable; it is bound only after a retry passes
///    the same directory checks, and it expires after
///    `notesPendingBindingLifetime`. Retries run at app-active (after the
///    notes sync), when the account becomes ready, and on network recovery.
/// 4. Last-started wins: a live verification that is superseded by a newer
///    one for the same handshake key, or invalidated by an unbind, changes
///    nothing when it completes.
///
/// Decision (plan item 8): the HELLO does not advertise the flag on relay
/// (Task 1) nor on a tailnet TCP connection (`notesExchangeHelloIdentity`);
/// the receive-side gate refuses both regardless of what the peer claims.
///
/// Decision: an account that is `.registering` is "unknown" to the session
/// (a completed pair waits; consent lapses on cancel or intent expiry), so a
/// press right after launch does not end in `unavailable`. `.idle` and
/// `.unavailable` are "no account" (nil).
extension ConnectionManager {

    /// Upper bound on a whole notesExchange payload (largest legit reveal
    /// is ~250 bytes of JSON).
    static let notesExchangeMaxPayloadBytes = 1024
    /// Peer intents + cancels accepted per session before further ones are
    /// ignored (harassment guard).
    static let notesExchangeMaxPeerToggles = 8

    /// Monotonic seconds including device sleep (`CLOCK_MONOTONIC` on Darwin
    /// is `mach_continuous_time`), wrapped in a `Date` for the session API.
    /// Not wall-clock: changing the system time cannot extend an intent.
    nonisolated static func notesExchangeMonotonicNow() -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000)
    }

    // MARK: - Public API

    /// Whether an exchange may run with `peerID` right now (the UI disables
    /// the button and explains the reason, e.g. `.peerLacksSupport`).
    public func notesExchangeAvailability(with peerID: String) -> NotesExchangeGate.Result {
        guard let pc = connection(for: peerID) else { return .denied(.notSecured) }
        return notesExchangeGate(for: pc)
    }

    /// The local user agreed to exchange notes accounts with `peerID`.
    /// Returns the gate result; on a denial nothing is created or sent.
    @discardableResult
    public func pressExchangeNotes(with peerID: String) -> NotesExchangeGate.Result {
        guard let pc = connection(for: peerID) else { return .denied(.notSecured) }
        let result = notesExchangeGate(for: pc)
        guard result == .allowed, let box = notesExchangeBox(for: pc, create: true) else { return result }
        feedNotesExchange(.userPressed(nonce: notesExchangeMakeNonce(), now: notesExchangeClock()), box: box, pc: pc)
        return .allowed
    }

    /// Withdraws my intent (or declines the peer's).
    public func cancelExchangeNotes(with peerID: String) {
        guard let pc = connection(for: peerID), let box = notesExchangeBox(for: pc, create: false) else { return }
        feedNotesExchange(.userCancelled, box: box, pc: pc)
    }

    /// "取消紙條綁定": clears the account binding and any pending one, voids
    /// any in-flight lookup for the contact's key, and ends a live session
    /// still showing "verifying" for it.
    public func unbindNotes(contactID: UUID) {
        guard let contact = trustedContactStore.find(byId: contactID) else { return }
        let key = contact.identityPublicKey
        let pending = contact.pendingAccountBinding
        trustedContactStore.setAccountBinding(for: contactID, accountId: nil)
        trustedContactStore.setPendingBinding(for: contactID, nil)
        noteOutbox.failQueuedEntries(forContact: contactID, reason: NoteOutboxSender.boundCancelledReason)
        let matches: (Data) -> Bool = { k in
            k == key || (pending.map { Data(SHA256.hash(data: k)) == $0.handshakeKeyHash } ?? false)
        }
        notesVerificationGenerations = notesVerificationGenerations.filter { !matches($0.key) }
        resolveLiveNotesVerification(event: .verificationFailed) { _, k in matches(k) }
    }

    /// Re-checks every pending binding against the directory. Success binds;
    /// a definitive failure (not found, any key/id mismatch, or a contact key
    /// that changed since the reveal) clears it; a transient error keeps it.
    public func retryPendingBindings() async {
        if notesExchangeRetryInFlight { notesExchangeRetryRequested = true; return }
        notesExchangeRetryInFlight = true
        defer { notesExchangeRetryInFlight = false }
        repeat {
            notesExchangeRetryRequested = false
            await retryPendingBindingsOnce()
        } while notesExchangeRetryRequested
    }

    /// App became active (called after `syncNotes()`): (re)observe the
    /// account and retry pending bindings.
    func notesExchangeDidBecomeActive() async {
        observeAccountForNotesExchange()
        await retryPendingBindings()
    }

    /// How long a pending binding may wait for the directory (spec §10.7).
    static let notesPendingBindingLifetime: TimeInterval = 7 * 24 * 3600

    /// Network recovery (spec §4.2, §10.7: e.g. library Wi-Fi without
    /// internet). Retries when the path becomes satisfied, or when the
    /// interface set changes while satisfied (Wi-Fi without internet is
    /// already "satisfied"). The first path seen at startup does not count.
    nonisolated static func notesShouldRetryOnPathChange(from oldStatus: NWPath.Status?, oldInterfaces: Set<String>,
                                                         to newStatus: NWPath.Status,
                                                         newInterfaces: Set<String>) -> Bool {
        guard let oldStatus, newStatus == .satisfied else { return false }
        return oldStatus != .satisfied || oldInterfaces != newInterfaces
    }

    /// Called by the path monitor for every path update.
    func notesExchangeNetworkPathChanged(from oldStatus: NWPath.Status?, oldInterfaces: Set<String>,
                                         to newStatus: NWPath.Status, newInterfaces: Set<String>) {
        guard Self.notesShouldRetryOnPathChange(from: oldStatus, oldInterfaces: oldInterfaces,
                                                to: newStatus, newInterfaces: newInterfaces) else { return }
        scheduleNotesBindingRetry()
        Task { [weak self] in await self?.flushNoteOutbox() }   // network recovery: same hook, no second monitor
    }

    /// Debounced: a burst of path updates runs one retry (which is itself
    /// single-flight).
    func scheduleNotesBindingRetry() {
        notesRetryDebounceTask?.cancel()
        let delay = notesRetryDebounceNanoseconds
        notesRetryDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.notesRetryDebounceTask = nil
            await self.retryPendingBindings()
        }
    }

    // MARK: - Gate

    func notesExchangeFacts(for pc: PeerConnection) -> NotesExchangeFacts {
        NotesExchangeFacts(
            verdict: pc.pinningVerdict,
            isSecured: pc.secureChannelState == .secured && pc.secureChannel != nil,
            handshakeKey: pc.handshakePeerIdentityKey,
            helloKey: pc.peerIdentity.identityPublicKey,
            isLocalDirect: notesExchangeIsLocalDirect(pc),
            peerSupportsExchange: pc.peerIdentity.supportsNotesExchange,
            localSupportsExchange: localIdentity.supportsNotesExchange)
    }

    /// Gate for `pc`, which must still be the installed, connected entry.
    func notesExchangeGate(for pc: PeerConnection) -> NotesExchangeGate.Result {
        guard connections[pc.id] === pc, pc.state.isConnected else { return .denied(.notSecured) }
        return NotesExchangeGate.evaluate(notesExchangeFacts(for: pc))
    }

    /// Local direct TCP only: every relay marker and every tailnet address
    /// (Ruling 1) refuse, and so does a connection with no readable remote
    /// host (fail closed).
    func notesExchangeIsLocalDirect(_ pc: PeerConnection) -> Bool {
        if pc.id.hasPrefix("relay-") || pc.isRelayTransport || pc.isRelayPlaceholder
            || pc.transport is DataChannelTransport {
            return false
        }
        return Self.notesHostsAreLocalDirect(notesExchangeRemoteHosts(of: pc.nwConnection))
    }

    /// At least one host, and none on the tailnet.
    nonisolated static func notesHostsAreLocalDirect(_ hosts: [String]) -> Bool {
        !hosts.isEmpty && !hosts.contains(where: isTailnetHost)
    }

    func notesExchangeRemoteHosts(of connection: NWConnection?) -> [String] {
        if let override = notesExchangeRemoteHostOverride { return override(connection).map { [$0] } ?? [] }
        guard let connection else { return [] }
        var hosts: [String] = []
        if let h = extractRemoteHost(from: connection.endpoint) { hosts.append(h) }
        if let remote = connection.currentPath?.remoteEndpoint, let h = extractRemoteHost(from: remote) { hosts.append(h) }
        return hosts
    }

    /// Tailscale CGNAT IPv4 (100.64.0.0/10, also IPv4-mapped), the Tailscale
    /// ULA IPv6 prefix fd7a:115c:a1e0::/48 and MagicDNS `*.ts.net` names.
    nonisolated static func isTailnetHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if let scope = h.firstIndex(of: "%") { h = String(h[..<scope]) }
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasSuffix(".ts.net") { return true }
        if h.hasPrefix("fd7a:115c:a1e0:") { return true }
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1]) else { return false }
        return a == 100 && (64...127).contains(b)
    }

    /// The HELLO identity for a TCP socket: no notes-exchange flag on tailnet
    /// or when no remote host is readable.
    func notesExchangeHelloIdentity(for connection: NWConnection) -> PeerIdentity {
        Self.notesHostsAreLocalDirect(notesExchangeRemoteHosts(of: connection))
            ? localIdentity : localIdentity.withoutNotesExchange()
    }

    // MARK: - Receive

    func handleNotesExchangeMessage(_ message: PeerMessage, on pc: PeerConnection,
                                    origin: PeerConnection.MessageOrigin) {
        guard origin == .envelope, pc.secureChannelState == .secured,
              notesExchangeGate(for: pc) == .allowed,
              let data = message.payload, data.count <= Self.notesExchangeMaxPayloadBytes,
              let payload = try? JSONDecoder().decode(NotesExchangePayload.self, from: data),
              Self.notesExchangeFieldsWithinLimits(payload),
              let phase = NotesExchangePhase(rawValue: payload.phase)
        else { return }
        let now = notesExchangeClock()
        switch phase {
        case .intent:
            guard let nonce = payload.nonce,
                  let box = notesExchangeBox(for: pc, create: true),
                  box.peerToggles < Self.notesExchangeMaxPeerToggles else { return }
            box.peerToggles += 1
            feedNotesExchange(.receivedIntent(nonce: nonce, now: now), box: box, pc: pc)
        case .cancel:
            guard let box = notesExchangeBox(for: pc, create: false),
                  box.peerToggles < Self.notesExchangeMaxPeerToggles else { return }
            box.peerToggles += 1
            feedNotesExchange(.receivedCancel, box: box, pc: pc)
        case .reveal:
            guard let box = notesExchangeBox(for: pc, create: false) else { return }
            feedNotesExchange(.receivedReveal(payload, now: now), box: box, pc: pc)
        case .unavailable:
            guard let box = notesExchangeBox(for: pc, create: false) else { return }
            feedNotesExchange(.receivedUnavailable, box: box, pc: pc)
        }
    }

    /// No field may exceed its fixed wire size (exact sizes are enforced by
    /// the session/crypto; this rejects junk before it reaches them).
    nonisolated static func notesExchangeFieldsWithinLimits(_ p: NotesExchangePayload) -> Bool {
        p.phase.utf8.count <= 32
            && (p.nonce?.count ?? 0) <= NotesExchangeCrypto.nonceLength
            && (p.accountId?.utf8.count ?? 0) <= NotesExchangeCrypto.accountIdLength
            && (p.signingKey?.count ?? 0) <= NotesExchangeCrypto.signingKeyLength
            && (p.signature?.count ?? 0) <= NotesExchangeCrypto.signatureLength
    }

    // MARK: - Sessions

    func notesExchangeBox(for pc: PeerConnection, create: Bool) -> NotesExchangeSessionBox? {
        let key = ObjectIdentifier(pc)
        if let box = notesExchangeSessions[key] {
            if box.connection === pc { return box }
            tearDownNotesExchange(box: box, key: key)   // stale entry at a reused address
        }
        guard create else { return nil }
        let box = NotesExchangeSessionBox(connection: pc)
        notesExchangeSessions[key] = box
        observeAccountForNotesExchange()
        if case let .known(snapshot) = notesExchangeAccountKnowledge(accountManager.state) {
            feedNotesExchange(.localAccountReady(snapshot, now: notesExchangeClock()), box: box, pc: pc)
        }
        return box
    }

    /// Called when `pc` is removed or overwritten (and on disconnect, which
    /// removes it): cancels the tick, closes the session, clears the UI state.
    func tearDownNotesExchange(for pc: PeerConnection) {
        let key = ObjectIdentifier(pc)
        guard let box = notesExchangeSessions[key] else { return }
        tearDownNotesExchange(box: box, key: key)
    }

    private func tearDownNotesExchange(box: NotesExchangeSessionBox, key: ObjectIdentifier) {
        box.tornDown = true
        box.tickTask?.cancel()
        box.tickTask = nil
        box.sendTail?.cancel()
        box.sendTail = nil
        box.awaitingDirectory = nil
        _ = box.session.handle(.disconnected)   // actions deliberately not executed
        notesExchangeSessions[key] = nil
        if !notesExchangeSessions.values.contains(where: { $0.peerID == box.peerID }) {
            notesExchangeStates[box.peerID] = nil
        }
    }

    /// Feeds one event and executes the resulting actions, including any
    /// follow-up events they produce, synchronously on the main actor.
    func feedNotesExchange(_ event: NotesExchangeSession.Event, box: NotesExchangeSessionBox, pc: PeerConnection) {
        guard notesExchangeSessions[ObjectIdentifier(pc)] === box, box.connection === pc else { return }
        var queue = box.session.handle(event)
        var i = 0
        while i < queue.count {
            let action = queue[i]
            i += 1
            switch action {
            case let .updateState(state):
                notesExchangeStates[pc.id] = state
            case let .sendIntent(nonce):
                sendNotesExchange(NotesExchangePayload(phase: NotesExchangePhase.intent.rawValue, nonce: nonce), box: box, pc: pc)
            case .sendCancel:
                sendNotesExchange(NotesExchangePayload(phase: NotesExchangePhase.cancel.rawValue), box: box, pc: pc)
            case .sendUnavailable:
                sendNotesExchange(NotesExchangePayload(phase: NotesExchangePhase.unavailable.rawValue), box: box, pc: pc)
            case let .sendReveal(account, nonces):
                if let reveal = makeNotesExchangeReveal(account: account, nonces: nonces, pc: pc),
                   sendNotesExchange(reveal, box: box, pc: pc) {
                    break
                }
                queue += box.session.handle(.localRevealFailed)
            case let .verify(reveal, nonces):
                if let result = beginNotesExchangeVerification(reveal: reveal, nonces: nonces, box: box, pc: pc) {
                    queue += box.session.handle(result)
                }
            }
        }
        updateNotesExchangeTicker(box: box, pc: pc)
    }

    // MARK: - Send

    /// Queues `payload` on `pc` only if it is installed, gate-allowed and has
    /// a secure channel right now (so `sendMessage` will wrap it). Frames of
    /// one session go out in order.
    @discardableResult
    func sendNotesExchange(_ payload: NotesExchangePayload, box: NotesExchangeSessionBox, pc: PeerConnection) -> Bool {
        guard pc.secureChannelState == .secured, pc.secureChannel != nil,
              notesExchangeGate(for: pc) == .allowed,
              let message = try? PeerMessage.notesExchange(payload, senderID: localIdentity.id)
        else { return false }
        let previous = box.sendTail
        box.sendTail = Task { @MainActor [weak self, pc, box] in
            _ = await previous?.value
            // Still this session's installed connection (not torn down or
            // overwritten while queued). `secureChannel` is never cleared once
            // set, so this send is always wrapped; checked again as defence
            // in depth.
            guard let self, !Task.isCancelled, !box.tornDown, self.connections[pc.id] === pc,
                  pc.secureChannel != nil, pc.secureChannelState == .secured else { return }
            do { try await pc.sendMessage(message) } catch {
                nxLogger.info("notesExchange send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    /// Signs our reveal for THIS connection, after re-running the gate.
    func makeNotesExchangeReveal(account: NotesExchangeSession.AccountSnapshot, nonces: NotesExchangePair,
                                 pc: PeerConnection) -> NotesExchangePayload? {
        guard notesExchangeGate(for: pc) == .allowed,
              let mine = pc.localHandshakeIdentityKey, let theirs = pc.handshakePeerIdentityKey
        else { return nil }
        return try? NotesExchangeCrypto.makeReveal(account: account,
                                                   handshakeKeys: NotesExchangePair(mine: mine, theirs: theirs),
                                                   nonces: nonces, signer: notesExchangeSigner)
    }

    // MARK: - Ticks

    /// Ticks once per interval only while a tick can change something (an
    /// intent may expire or a response is still owed); stops otherwise,
    /// including `.bound` with our reveal sent.
    func updateNotesExchangeTicker(box: NotesExchangeSessionBox, pc: PeerConnection) {
        if !box.session.needsTicks {
            box.tickTask?.cancel()
            box.tickTask = nil
            return
        }
        guard box.tickTask == nil else { return }
        let interval = notesExchangeTickNanoseconds
        box.tickTask = Task { @MainActor [weak self, weak box, weak pc] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self, let box, let pc else { return }
                self.feedNotesExchange(.tick(now: self.notesExchangeClock()), box: box, pc: pc)
            }
        }
    }

    // MARK: - Account

    enum NotesExchangeAccountKnowledge {
        /// Still registering: the session waits.
        case unknown
        /// nil = no account (`unavailable` is sent).
        case known(NotesExchangeSession.AccountSnapshot?)
    }

    func notesExchangeAccountKnowledge(_ state: AccountManager.State) -> NotesExchangeAccountKnowledge {
        switch state {
        case .registering:
            return .unknown
        case .idle, .unavailable:
            return .known(nil)
        case let .ready(account):
            return .known(NotesExchangeSession.AccountSnapshot(accountId: account.accountId.raw,
                                                               signingKey: notesExchangeLocalSigningKey()))
        }
    }

    /// Subscribes once per `AccountManager` instance to its state.
    func observeAccountForNotesExchange() {
        let manager = accountManager
        guard notesExchangeObservedAccountManager !== manager else { return }
        notesExchangeObservedAccountManager = manager
        notesExchangeAccountCancellable = manager.$state
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] state in
                // `@Published` emits in willSet: use the delivered value.
                Task { @MainActor in self?.notesExchangeAccountStateChanged(state) }
            }
    }

    func notesExchangeAccountStateChanged(_ state: AccountManager.State) {
        if case let .known(snapshot) = notesExchangeAccountKnowledge(state) {
            for box in Array(notesExchangeSessions.values) {
                guard let pc = box.connection else { continue }
                feedNotesExchange(.localAccountReady(snapshot, now: notesExchangeClock()), box: box, pc: pc)
            }
        }
        if case .ready = state {
            Task { [weak self] in
                await self?.retryPendingBindings()
                await self?.flushNoteOutbox()   // account ready
            }
        }
    }

    // MARK: - Verification

    enum NotesDirectoryOutcome { case verified, rejected, transient }

    /// Offline checks in the same turn as the reveal, on the same connection;
    /// returns an event to feed now, or nil when the directory step started.
    func beginNotesExchangeVerification(reveal: NotesExchangePayload, nonces: NotesExchangePair,
                                        box: NotesExchangeSessionBox,
                                        pc: PeerConnection) -> NotesExchangeSession.Event? {
        guard let accountId = reveal.accountId, NotesExchangeCrypto.isValidAccountId(accountId),
              let signingKey = reveal.signingKey,
              notesExchangeGate(for: pc) == .allowed,
              let theirs = pc.handshakePeerIdentityKey, let mine = pc.localHandshakeIdentityKey,
              NotesExchangeCrypto.verifyReveal(payload: reveal,
                                               handshakeKeys: NotesExchangePair(mine: mine, theirs: theirs),
                                               nonces: nonces)
        else { return .verificationFailed }
        let peer = pc.peerIdentity
        box.awaitingDirectory = (accountId, theirs)
        notesVerificationCounter += 1
        let generation = notesVerificationCounter
        notesVerificationGenerations[theirs] = generation
        Task { [weak self, weak box, weak pc] in
            guard let self else { return }
            let outcome = await self.checkNotesDirectory(accountId: accountId, handshakeKey: theirs, signingKey: signingKey)
            // Superseded by a newer verification for this key, or voided by
            // an unbind: change nothing, just end this session's wait.
            guard self.notesVerificationGenerations[theirs] == generation else {
                if let box, let pc, box.awaitingDirectory?.accountId == accountId {
                    box.awaitingDirectory = nil
                    self.feedNotesExchange(.verificationFailed, box: box, pc: pc)
                }
                return
            }
            self.notesVerificationGenerations[theirs] = nil
            let event: NotesExchangeSession.Event?
            switch outcome {
            case .verified:
                event = self.bindNotesAccount(accountId: accountId, handshakeKey: theirs, peer: peer)
                    ? .verificationSucceeded : .verificationFailed
            case .rejected:
                event = .verificationFailed
            case .transient:
                let stored = self.storePendingNotesBinding(accountId: accountId, signingKey: signingKey,
                                                           handshakeKey: theirs, peer: peer)
                event = stored ? nil : .verificationFailed   // nil: stay `.verifying`
            }
            guard let event, let box, let pc else { return }
            box.awaitingDirectory = nil
            self.feedNotesExchange(event, box: box, pc: pc)
        }
        return nil
    }

    /// Directory step: lookup by id without bundle; all three fields must match.
    func checkNotesDirectory(accountId: String, handshakeKey: Data, signingKey: Data) async -> NotesDirectoryOutcome {
        do {
            guard let entry = try await accountManager.lookup(handle: accountId, includeBundle: false) else {
                return .rejected
            }
            guard entry.accountId.raw == accountId, entry.identityKey == handshakeKey,
                  entry.signingKey == signingKey else { return .rejected }
            return .verified
        } catch {
            // Offline, server error, no account yet: try again later.
            return .transient
        }
    }

    /// The contact for the connection's handshake key (Ruling 2): exactly one
    /// match by key, or none (then created, `.unknown`, `deviceId` = HELLO id).
    /// Refuses ambiguous mappings and blocked contacts.
    func resolveNotesContact(handshakeKey: Data, peer: PeerIdentity) -> TrustedContact? {
        let byKey = trustedContactStore.contacts.filter { $0.matchesKey(handshakeKey) }
        guard byKey.count <= 1 else { return nil }
        if let contact = byKey.first {
            guard !contact.isBlocked else { return nil }
            if contact.deviceId == nil {
                guard !trustedContactStore.contacts.contains(where: { $0.id != contact.id && $0.deviceId == peer.id })
                else { return nil }
                trustedContactStore.setDeviceId(for: contact.id, peer.id)
            }
            return trustedContactStore.find(byId: contact.id)
        }
        // Another contact already holds this device id under a different key:
        // a key change, not a new friend. Do not guess.
        guard !peer.id.isEmpty, trustedContactStore.find(byDeviceId: peer.id) == nil else { return nil }
        let contact = TrustedContact(deviceId: peer.id, displayName: peer.displayName,
                                     identityPublicKey: handshakeKey, trustLevel: .unknown)
        trustedContactStore.add(contact)
        return contact
    }

    func bindNotesAccount(accountId: String, handshakeKey: Data, peer: PeerIdentity) -> Bool {
        guard let contact = resolveNotesContact(handshakeKey: handshakeKey, peer: peer) else { return false }
        trustedContactStore.setAccountBinding(for: contact.id, accountId: accountId)
        return true
    }

    func storePendingNotesBinding(accountId: String, signingKey: Data, handshakeKey: Data, peer: PeerIdentity) -> Bool {
        guard let contact = resolveNotesContact(handshakeKey: handshakeKey, peer: peer) else { return false }
        trustedContactStore.setPendingBinding(for: contact.id, PendingAccountBinding(
            accountId: accountId, signingKey: signingKey,
            handshakeKeyHash: Data(SHA256.hash(data: handshakeKey)), receivedAt: notesPendingBindingClock()))
        return true
    }

    /// Older than the lifetime, or dated implausibly far in the future (the
    /// wall clock was moved back): either way it may not wait any longer.
    func notesPendingBindingExpired(_ p: PendingAccountBinding) -> Bool {
        abs(notesPendingBindingClock().timeIntervalSince(p.receivedAt)) > Self.notesPendingBindingLifetime
    }

    private func retryPendingBindingsOnce() async {
        let pending = trustedContactStore.contacts.compactMap { c in
            c.pendingAccountBinding.map { (id: c.id, key: c.identityPublicKey, binding: $0) }
        }
        for item in pending {
            let p = item.binding
            // Matches the live session that produced this pending binding.
            let sameReveal: (String, Data) -> Bool = { accountId, key in
                accountId == p.accountId && Data(SHA256.hash(data: key)) == p.handshakeKeyHash
            }
            guard !notesPendingBindingExpired(p),
                  Data(SHA256.hash(data: item.key)) == p.handshakeKeyHash,
                  NotesExchangeCrypto.isValidAccountId(p.accountId),
                  NotesExchangeCrypto.isAcceptableSigningKey(p.signingKey)
            else {
                trustedContactStore.setPendingBinding(for: item.id, nil)
                resolveLiveNotesVerification(event: .verificationFailed, where: sameReveal)
                continue
            }
            // A live verification for this key is in flight: it is newer than
            // this pending binding and decides.
            guard notesVerificationGenerations[item.key] == nil else { continue }
            let outcome = await checkNotesDirectory(accountId: p.accountId, handshakeKey: item.key, signingKey: p.signingKey)
            // The contact may have changed, or a newer verification may have
            // started, while we waited.
            guard notesVerificationGenerations[item.key] == nil,
                  let now = trustedContactStore.find(byId: item.id), now.pendingAccountBinding == p,
                  now.identityPublicKey == item.key else { continue }
            switch outcome {
            case .verified:
                let unique = trustedContactStore.contacts.filter { $0.matchesKey(item.key) }.count == 1
                if unique && !now.isBlocked {
                    trustedContactStore.setAccountBinding(for: item.id, accountId: p.accountId)
                    resolveLiveNotesVerification(event: .verificationSucceeded, where: sameReveal)
                } else {
                    trustedContactStore.setPendingBinding(for: item.id, nil)
                    resolveLiveNotesVerification(event: .verificationFailed, where: sameReveal)
                }
            case .rejected:
                trustedContactStore.setPendingBinding(for: item.id, nil)
                resolveLiveNotesVerification(event: .verificationFailed, where: sameReveal)
            case .transient:
                break
            }
        }
    }

    /// Tells every live session still showing "verifying" for a matching
    /// reveal (`accountId`, peer handshake key).
    func resolveLiveNotesVerification(event: NotesExchangeSession.Event,
                                      where matches: (String, Data) -> Bool) {
        for box in Array(notesExchangeSessions.values) {
            guard let awaiting = box.awaitingDirectory, matches(awaiting.accountId, awaiting.handshakeKey),
                  let pc = box.connection else { continue }
            box.awaitingDirectory = nil
            feedNotesExchange(event, box: box, pc: pc)
        }
    }
}
