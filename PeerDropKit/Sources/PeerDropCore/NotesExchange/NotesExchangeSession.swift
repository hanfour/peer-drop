import Foundation
import PeerDropProtocol

/// Per-connection state machine for the mutual notes-account exchange
/// (spec §4.1, §10.5, §10.8). Pure value type: time (`now`), nonces and the
/// local account are injected as events; it never touches the network, the
/// clock, the CM or any store. The CM keeps one per `PeerConnection` instance
/// and drops it on disconnect/removal.
///
/// Commit-then-reveal rules:
/// - A reveal (or `unavailable`) is sent only when BOTH intents are present,
///   at most once per session (connection). It is still sent after the peer's
///   reveal was accepted or verified (`.bound`), so a late-ready local account
///   reciprocates exactly once.
/// - A peer `reveal` is accepted only when BOTH intents are present. A reveal
///   that arrives while only MY intent exists would mean the peer saw an intent
///   of theirs we never received; over the ordered secure channel an honest peer
///   always delivers its `intent` first, so such a reveal is ignored with no
///   state change (it does not consume the one-reveal slot).
/// - Only the first accepted peer reveal is used; later ones are ignored.
/// - Once the local response is sent or the peer's reveal is accepted the pair
///   is LOCKED: nonces are frozen and intents/cancels no longer change it.
/// - Consent is still required while the pair is locked but my response is not
///   yet sent (account unknown when the peer's reveal arrived): `userCancelled`,
///   or my intent reaching `intentLifetime`, withdraws my response for good
///   (`sendUnavailable`, never a reveal for this pairing). The peer's pending
///   verification still decides the outcome. A reveal is only ever emitted
///   while my intent is unexpired relative to the latest `now`.
/// - Duplicate intents are ignored; the first intent's nonce is kept. An intent
///   echoing any nonce we sent in this session is ignored.
/// - Intents expire `intentLifetime` seconds after they were made/received
///   (elapsed ≥ 600 s). Expiry runs at the start of EVERY event that carries
///   `now` (`userPressed`, `receivedIntent`, `receivedReveal`,
///   `localAccountReady`, `tick`), before pairing, so a late intent, reveal or
///   account can never pair with an expired intent. My expiry emits `sendCancel`;
///   the peer's is silent.
/// - Time only moves forward: the session uses the largest `now` seen so far,
///   so a clock that jumps backwards can make an intent expire sooner but never
///   later. The CM must still feed MONOTONIC time (e.g. a `Date` derived from
///   `ProcessInfo.systemUptime`, or an injected clock), not wall-clock time.
/// - `receivedCancel` clears only the peer's intent and never unbinds.
/// - `userCancelled` withdraws my intent (`sendCancel`), or, when only the peer
///   has an intent, declines it locally (no network action): that nonce never
///   prompts again, but a later press still pairs with it. On a locked pair it
///   withdraws my not-yet-sent response (see above); after my reveal it does
///   nothing.
/// - `disconnected` closes the session for good: every later event is ignored,
///   so replays after a disconnect can do nothing.
/// - `receivedUnavailable` is honoured only once both intents are present and
///   before the peer's reveal; it ends the exchange (`peerUnavailable`).
/// - Local `unavailable` (account nil, or `localRevealFailed`) ends the exchange
///   only if no peer reveal has been accepted yet; otherwise we still tell the
///   peer (`sendUnavailable`) but the pending verification decides the outcome,
///   and an existing `.bound` is never overwritten.
///
/// CM contract (Task 4 hand-off):
/// - Create the session when the connection's exchange becomes possible and
///   feed `localAccountReady` IMMEDIATELY (and again whenever the account
///   state changes); while it is unknown a completed pair just waits.
/// - Pass the same monotonic `now` with `receivedReveal` and
///   `localAccountReady` as with intents and ticks. Drive `tick` from it, e.g.
///   once per second while any intent is pending or a response is owed.
/// - Re-run `NotesExchangeGate` on the same `PeerConnection` when any exchange
///   message is received and right before acting on `.sendReveal`.
/// - `.sendReveal`: build it with `NotesExchangeCrypto.makeReveal` using this
///   connection's handshake keys and the action's nonces. If that throws, feed
///   `.localRevealFailed` (never leave the session waiting).
/// - `.verify`: call `NotesExchangeCrypto.verifyReveal` with this connection's
///   handshake keys and the action's nonces, then check the directory
///   (`entry.accountId.raw == accountId`, `entry.identityKey == peer handshake
///   key`, `entry.signingKey == payload.signingKey`). These checks must pass
///   BEFORE any binding, including a pending one, is persisted. Feed back
///   `.verificationSucceeded` / `.verificationFailed`.
public struct NotesExchangeSession: Sendable {

    public static let intentLifetime: TimeInterval = 600

    /// The local notes account, validated at construction (strict 8-char id,
    /// 32-byte Ed25519 signing key that is not a small-order point).
    public struct AccountSnapshot: Equatable, Sendable {
        public let accountId: String
        public let signingKey: Data
        public init?(accountId: String, signingKey: Data) {
            guard NotesExchangeCrypto.isValidAccountId(accountId),
                  NotesExchangeCrypto.isAcceptableSigningKey(signingKey)
            else { return nil }
            self.accountId = accountId
            self.signingKey = signingKey
        }
    }

    public enum Reason: Equatable, Sendable {
        /// We had no ready account when both intents met; we sent `unavailable`.
        case localAccountUnavailable
        /// The peer's reveal was malformed or reflected our own account.
        case invalidReveal
        /// The CM's signature/directory verification rejected the reveal.
        case verificationFailed
        /// The CM could not build/sign our reveal (`makeReveal` threw).
        case localRevealFailed
    }

    public enum UIState: Equatable, Sendable {
        case idle, waitingForPeer, peerWantsExchange, exchanging, verifying,
             bound, peerUnavailable, expired
        case failed(Reason)
    }

    public enum Event {
        case userPressed(nonce: Data, now: Date)
        /// The local user withdrew (my intent) or declined (the peer's intent).
        case userCancelled
        case receivedIntent(nonce: Data, now: Date)
        case receivedReveal(NotesExchangePayload, now: Date)
        case receivedUnavailable
        case receivedCancel
        /// nil = account not `ready`. Until the first such event the account is
        /// "unknown" and a completed pair waits (no reveal, no unavailable).
        case localAccountReady(AccountSnapshot?, now: Date)
        /// Result of the CM's handling of a `.verify` action. A pending
        /// directory lookup needs no event (state stays `.verifying`).
        case verificationSucceeded
        case verificationFailed
        /// The CM failed to build or sign the reveal requested by `.sendReveal`.
        case localRevealFailed
        /// Monotonic time (see the type's doc comment).
        case tick(now: Date)
        case disconnected

        var now: Date? {
            switch self {
            case let .userPressed(_, now), let .receivedIntent(_, now), let .tick(now),
                 let .receivedReveal(_, now), let .localAccountReady(_, now): return now
            default: return nil
            }
        }
    }

    public enum Action: Equatable {
        case sendIntent(nonce: Data)
        /// Sign with `NotesExchangeCrypto.makeReveal(account:handshakeKeys:nonces:signer:)`;
        /// on failure feed `.localRevealFailed`.
        case sendReveal(account: AccountSnapshot, nonces: NotesExchangePair)
        case sendUnavailable
        case sendCancel
        /// Verify with `NotesExchangeCrypto.verifyReveal` + the directory, then
        /// feed back `.verificationSucceeded` / `.verificationFailed`.
        case verify(reveal: NotesExchangePayload, nonces: NotesExchangePair)
        case updateState(UIState)
    }

    private struct Intent: Sendable {
        let nonce: Data
        let at: Date
    }

    private enum AccountKnowledge: Sendable {
        case unknown, unavailable
        case ready(AccountSnapshot)
    }

    private enum Terminal: Equatable, Sendable {
        case bound, peerUnavailable
        case failed(Reason)
    }

    private enum Response: Sendable {
        case none, reveal, unavailable
    }

    public private(set) var state: UIState = .idle

    private var account: AccountKnowledge = .unknown
    private var myIntent: Intent?
    private var peerIntent: Intent?
    private var myResponse: Response = .none
    private var peerRevealAccepted = false
    private var verificationPending = false
    private var didExpire = false
    private var terminal: Terminal?
    private var closed = false
    /// Largest `now` seen; time never moves backwards inside the session.
    private var latestNow: Date?
    /// Every nonce we sent as an intent in this session (reflection check).
    private var ownNonces: Set<Data> = []
    /// Peer intent nonce the user declined; it never prompts again.
    private var declinedPeerNonce: Data?

    public init() {}

    /// The pair is frozen once either side has committed a response.
    private var isLocked: Bool { myResponse != .none || peerRevealAccepted }
    private var isOpen: Bool { !closed && terminal == nil }

    public mutating func handle(_ event: Event) -> [Action] {
        guard !closed else { return [] }
        var out: [Action] = []
        if let now = event.now { out += expireIntents(now: advance(to: now)) }
        out += apply(event)
        if let s = publishState() { out.append(.updateState(s)) }
        return out
    }

    private mutating func advance(to now: Date) -> Date {
        let t = max(latestNow ?? now, now)
        latestNow = t
        return t
    }

    private mutating func expireIntents(now: Date) -> [Action] {
        if isLocked {
            // Intents are frozen, but a response we still owe must not outlive
            // my intent: consent has lapsed, so withdraw it for good.
            if myResponse == .none, canStillRespond, myIntentExpired(at: now) { return withdrawMyResponse() }
            return []
        }
        guard isOpen else { return [] }
        var out: [Action] = []
        if let m = myIntent, now.timeIntervalSince(m.at) >= Self.intentLifetime {
            myIntent = nil
            didExpire = true
            out.append(.sendCancel)
        }
        if let p = peerIntent, now.timeIntervalSince(p.at) >= Self.intentLifetime {
            peerIntent = nil
        }
        return out
    }

    private mutating func apply(_ event: Event) -> [Action] {
        switch event {
        case let .userPressed(nonce, now):
            guard isOpen, !isLocked, myIntent == nil,
                  nonce.count == NotesExchangeCrypto.nonceLength,
                  nonce != peerIntent?.nonce
            else { return [] }
            // Recorded with the raw `now` (≤ latestNow): a backwards clock can
            // only shorten the intent's life.
            myIntent = Intent(nonce: nonce, at: now)
            ownNonces.insert(nonce)
            didExpire = false
            return [.sendIntent(nonce: nonce)] + respondIfPaired()

        case .userCancelled:
            // Locked but my response not sent yet (account unknown when the
            // peer's reveal was accepted): withdraw consent permanently.
            if isLocked {
                guard myResponse == .none, canStillRespond else { return [] }
                return withdrawMyResponse()
            }
            guard isOpen else { return [] }
            if myIntent != nil {
                myIntent = nil
                return [.sendCancel]
            }
            if let p = peerIntent { declinedPeerNonce = p.nonce }
            return []

        case let .receivedIntent(nonce, now):
            guard isOpen, !isLocked, peerIntent == nil,
                  nonce.count == NotesExchangeCrypto.nonceLength,
                  !ownNonces.contains(nonce),      // reflected own intent
                  nonce != declinedPeerNonce
            else { return [] }
            peerIntent = Intent(nonce: nonce, at: now)
            didExpire = false
            return respondIfPaired()

        case let .receivedReveal(payload, _):
            guard isOpen, let mine = myIntent, let theirs = peerIntent, !peerRevealAccepted,
                  payload.phase == NotesExchangePhase.reveal.rawValue
            else { return [] }
            peerRevealAccepted = true
            guard isStructurallyValidPeerReveal(payload) else {
                terminal = .failed(.invalidReveal)
                return []
            }
            verificationPending = true
            return [.verify(reveal: payload,
                            nonces: NotesExchangePair(mine: mine.nonce, theirs: theirs.nonce))]

        case .receivedUnavailable:
            guard isOpen, myIntent != nil, peerIntent != nil, !peerRevealAccepted else { return [] }
            terminal = .peerUnavailable
            return []

        case .receivedCancel:
            guard isOpen, !isLocked, peerIntent != nil else { return [] }
            peerIntent = nil
            return []

        case let .localAccountReady(snapshot, _):
            account = snapshot.map(AccountKnowledge.ready) ?? .unavailable
            return respondIfPaired()

        case .verificationSucceeded:
            guard isOpen, verificationPending else { return [] }
            verificationPending = false
            terminal = .bound
            return []

        case .verificationFailed:
            guard isOpen, verificationPending else { return [] }
            verificationPending = false
            terminal = .failed(.verificationFailed)
            return []

        case .localRevealFailed:
            guard myResponse == .reveal else { return [] }
            myResponse = .unavailable
            if terminal == nil, !peerRevealAccepted { terminal = .failed(.localRevealFailed) }
            return [.sendUnavailable]

        case .tick:
            return []   // expiry already ran in `handle`

        case .disconnected:
            closed = true
            myIntent = nil
            peerIntent = nil
            verificationPending = false
            terminal = nil
            account = .unknown
            return []
        }
    }

    /// Sends our single response once both intents are present and the
    /// account is known. Unknown account → wait. Allowed after `.bound` so a
    /// late-ready account still reciprocates.
    private mutating func respondIfPaired() -> [Action] {
        guard myResponse == .none, canStillRespond,
              let mine = myIntent, let theirs = peerIntent
        else { return [] }
        // The only place a reveal is emitted: never on a lapsed intent. Locked
        // → withdraw for good; unlocked → leave it to expiry (next event).
        if let now = latestNow, myIntentExpired(at: now) { return isLocked ? withdrawMyResponse() : [] }
        switch account {
        case .unknown:
            return []
        case .unavailable:
            myResponse = .unavailable
            if terminal == nil, !peerRevealAccepted { terminal = .failed(.localAccountUnavailable) }
            return [.sendUnavailable]
        case let .ready(snapshot):
            myResponse = .reveal
            return [.sendReveal(account: snapshot,
                                nonces: NotesExchangePair(mine: mine.nonce, theirs: theirs.nonce))]
        }
    }

    /// A response can still go out: open, or bound by the peer's reveal.
    private var canStillRespond: Bool { !closed && (terminal == nil || terminal == .bound) }

    private func myIntentExpired(at now: Date) -> Bool {
        guard let m = myIntent else { return false }
        return now.timeIntervalSince(m.at) >= Self.intentLifetime
    }

    /// Commits `unavailable` as my one response: no reveal is ever sent for
    /// this pairing. The peer is told so it does not wait (it honours
    /// `unavailable` because it has not seen my reveal). Any pending
    /// verification of the peer's reveal is left to the CM, and an existing
    /// outcome is not overwritten (the pair is locked here, so the peer's
    /// reveal has already been accepted).
    private mutating func withdrawMyResponse() -> [Action] {
        myResponse = .unavailable
        return [.sendUnavailable]
    }

    /// Size/shape checks plus reflection: the role-ordered digest already makes
    /// an echoed reveal fail signature verification; rejecting our own
    /// accountId / signing key here is defence in depth.
    private func isStructurallyValidPeerReveal(_ p: NotesExchangePayload) -> Bool {
        guard let id = p.accountId, NotesExchangeCrypto.isValidAccountId(id),
              let key = p.signingKey, NotesExchangeCrypto.isAcceptableSigningKey(key),
              let sig = p.signature, NotesExchangeCrypto.isAcceptableSignature(sig)
        else { return false }
        if case let .ready(me) = account, me.accountId == id || me.signingKey == key { return false }
        return true
    }

    private func derivedState() -> UIState {
        if closed { return .idle }
        switch terminal {
        case .bound: return .bound
        case .peerUnavailable: return .peerUnavailable
        case let .failed(r): return .failed(r)
        case nil: break
        }
        if verificationPending { return .verifying }
        switch (myIntent, peerIntent) {
        case (.some, .some): return .exchanging
        case (.some, nil): return .waitingForPeer
        case let (nil, .some(p)):
            if p.nonce == declinedPeerNonce { return didExpire ? .expired : .idle }
            return .peerWantsExchange
        case (nil, nil): return didExpire ? .expired : .idle
        }
    }

    private mutating func publishState() -> UIState? {
        let s = derivedState()
        guard s != state else { return nil }
        state = s
        return s
    }
}
