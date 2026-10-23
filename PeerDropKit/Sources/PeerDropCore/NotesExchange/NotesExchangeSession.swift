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
///   at most once per session (connection).
/// - A peer `reveal` is accepted only when BOTH intents are present. A reveal
///   that arrives while only MY intent exists would mean the peer saw an intent
///   of theirs we never received; over the ordered secure channel an honest peer
///   always delivers its `intent` first, so such a reveal is ignored with no
///   state change (it does not consume the one-reveal slot).
/// - Only the first accepted peer reveal is used; later ones are ignored.
/// - Once the local response is sent or the peer's reveal is accepted the pair
///   is LOCKED: nonces are frozen, intents/cancels/expiry are ignored.
/// - Duplicate intents are ignored; the first intent's nonce is kept.
/// - Intents expire `intentLifetime` seconds after they were made/received
///   (elapsed ≥ 600 s). My expiry emits `sendCancel`; the peer's is silent.
/// - `receivedCancel` clears only the peer's intent and never unbinds.
/// - `disconnected` closes the session for good: every later event is ignored,
///   so replays after a disconnect can do nothing.
/// - `receivedUnavailable` is honoured only once both intents are present and
///   before the peer's reveal; it ends the exchange (`peerUnavailable`).
public struct NotesExchangeSession: Sendable {

    public static let intentLifetime: TimeInterval = 600

    /// The local notes account, validated at construction (strict 8-char id,
    /// 32-byte Ed25519 signing key).
    public struct AccountSnapshot: Equatable, Sendable {
        public let accountId: String
        public let signingKey: Data
        public init?(accountId: String, signingKey: Data) {
            guard NotesExchangeCrypto.isValidAccountId(accountId),
                  signingKey.count == NotesExchangeCrypto.signingKeyLength
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
    }

    public enum UIState: Equatable, Sendable {
        case idle, waitingForPeer, peerWantsExchange, exchanging, verifying,
             bound, peerUnavailable, expired
        case failed(Reason)
    }

    public enum Event {
        case userPressed(nonce: Data, now: Date)
        /// The local user withdrew before anything was revealed.
        case userCancelled
        case receivedIntent(nonce: Data, now: Date)
        case receivedReveal(NotesExchangePayload)
        case receivedUnavailable
        case receivedCancel
        /// nil = account not `ready`. Until the first such event the account is
        /// "unknown" and a completed pair waits (no reveal, no unavailable).
        case localAccountReady(AccountSnapshot?)
        /// Result of the CM's handling of a `.verify` action. A pending
        /// directory lookup needs no event (state stays `.verifying`).
        case verificationSucceeded
        case verificationFailed
        case tick(now: Date)
        case disconnected
    }

    public enum Action: Equatable {
        case sendIntent(nonce: Data)
        /// Sign with `NotesExchangeCrypto.makeReveal(account:handshakeKeys:nonces:signer:)`.
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

    public private(set) var state: UIState = .idle

    private var account: AccountKnowledge = .unknown
    private var myIntent: Intent?
    private var peerIntent: Intent?
    private var mySentResponse = false
    private var peerRevealAccepted = false
    private var verificationPending = false
    private var didExpire = false
    private var terminal: Terminal?
    private var closed = false

    public init() {}

    /// The pair is frozen once either side has committed a response.
    private var isLocked: Bool { mySentResponse || peerRevealAccepted }
    private var isOpen: Bool { !closed && terminal == nil }

    public mutating func handle(_ event: Event) -> [Action] {
        guard !closed else { return [] }
        var out: [Action] = []
        switch event {
        case let .userPressed(nonce, now):
            guard isOpen, !isLocked, myIntent == nil,
                  nonce.count == NotesExchangeCrypto.nonceLength,
                  nonce != peerIntent?.nonce
            else { return [] }
            myIntent = Intent(nonce: nonce, at: now)
            didExpire = false
            out.append(.sendIntent(nonce: nonce))
            out += respondIfPaired()

        case .userCancelled:
            guard isOpen, !isLocked, myIntent != nil else { return [] }
            myIntent = nil
            out.append(.sendCancel)

        case let .receivedIntent(nonce, now):
            guard isOpen, !isLocked, peerIntent == nil,
                  nonce.count == NotesExchangeCrypto.nonceLength,
                  nonce != myIntent?.nonce   // reflected own intent
            else { return [] }
            peerIntent = Intent(nonce: nonce, at: now)
            didExpire = false
            out += respondIfPaired()

        case let .receivedReveal(payload):
            guard isOpen, let mine = myIntent, let theirs = peerIntent, !peerRevealAccepted,
                  payload.phase == NotesExchangePhase.reveal.rawValue
            else { return [] }
            peerRevealAccepted = true
            if isStructurallyValidPeerReveal(payload) {
                verificationPending = true
                out.append(.verify(reveal: payload,
                                   nonces: NotesExchangePair(mine: mine.nonce, theirs: theirs.nonce)))
            } else {
                terminal = .failed(.invalidReveal)
            }

        case .receivedUnavailable:
            guard isOpen, myIntent != nil, peerIntent != nil, !peerRevealAccepted else { return [] }
            terminal = .peerUnavailable

        case .receivedCancel:
            guard isOpen, !isLocked, peerIntent != nil else { return [] }
            peerIntent = nil

        case let .localAccountReady(snapshot):
            account = snapshot.map(AccountKnowledge.ready) ?? .unavailable
            guard isOpen else { return [] }
            out += respondIfPaired()

        case .verificationSucceeded:
            guard isOpen, verificationPending else { return [] }
            verificationPending = false
            terminal = .bound

        case .verificationFailed:
            guard isOpen, verificationPending else { return [] }
            verificationPending = false
            terminal = .failed(.verificationFailed)

        case let .tick(now):
            guard isOpen, !isLocked else { return [] }
            if let m = myIntent, now.timeIntervalSince(m.at) >= Self.intentLifetime {
                myIntent = nil
                didExpire = true
                out.append(.sendCancel)
            }
            if let p = peerIntent, now.timeIntervalSince(p.at) >= Self.intentLifetime {
                peerIntent = nil
            }

        case .disconnected:
            closed = true
            myIntent = nil
            peerIntent = nil
            verificationPending = false
            terminal = nil
            account = .unknown
        }
        if let s = publishState() { out.append(.updateState(s)) }
        return out
    }

    /// Sends our single response once both intents are present and the
    /// account is known. Unknown account → wait.
    private mutating func respondIfPaired() -> [Action] {
        guard isOpen, !mySentResponse, let mine = myIntent, let theirs = peerIntent else { return [] }
        switch account {
        case .unknown:
            return []
        case .unavailable:
            mySentResponse = true
            terminal = .failed(.localAccountUnavailable)
            return [.sendUnavailable]
        case let .ready(snapshot):
            mySentResponse = true
            return [.sendReveal(account: snapshot,
                                nonces: NotesExchangePair(mine: mine.nonce, theirs: theirs.nonce))]
        }
    }

    /// Size/shape checks plus reflection: a peer echoing our own reveal yields
    /// the same (symmetric) digest, so reject our own accountId / signing key.
    private func isStructurallyValidPeerReveal(_ p: NotesExchangePayload) -> Bool {
        guard let id = p.accountId, NotesExchangeCrypto.isValidAccountId(id),
              let key = p.signingKey, key.count == NotesExchangeCrypto.signingKeyLength,
              let sig = p.signature, sig.count == NotesExchangeCrypto.signatureLength
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
        switch (myIntent != nil, peerIntent != nil) {
        case (true, true): return .exchanging
        case (true, false): return .waitingForPeer
        case (false, true): return .peerWantsExchange
        case (false, false): return didExpire ? .expired : .idle
        }
    }

    private mutating func publishState() -> UIState? {
        let s = derivedState()
        guard s != state else { return nil }
        state = s
        return s
    }
}
