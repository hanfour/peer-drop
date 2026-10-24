import Foundation

// Project E — one rendezvous ROOM (one contact × one UTC day token) as a pure,
// deterministic state machine. No I/O, no clock, no randomness: the caller
// (`RendezvousManager`) passes `now` and a pre-drawn jitter with every event and
// executes the returned actions. Crypto lives in `RendezvousSignalingClient`; the
// session only ever sees *authenticated, decrypted* signaling payloads.
//
// Binding rules implemented here (plan Review Focus, Task 3 reset rule):
//   - The peer is trusted for signaling only after its FIRST valid sealed frame
//     (`ready`). A bare `joined` / hello (operator, third party) never starts
//     WebRTC. No valid sealed frame within 5 s of `joined` → close the socket
//     and reconnect with backoff (the client discards the cipher with the socket).
//   - Downgrade (`disabled`) emits only `leaveRoom` (+ `closeConnection` when a
//     connection exists) — never a frame. Background likewise.
//   - Timeouts: negotiation 30 s (startNegotiation → dataChannelOpen), secure
//     channel 5 s (dataChannelOpen → secureChannelResult(ok: true)); both fire at
//     exactly `deadline` (now ≥ start + limit). Never falls back to plaintext.
//   - Reconnect: exponential backoff 1 s → 300 s cap plus jitter 0…30 s. The
//     FIRST join after foreground/enable is immediate (controller ruling R-a,
//     amending plan Ruling 7: jitter costs latency, it does not defeat
//     correlation). A socket that stayed up > 60 s before failing resets the
//     failure counter (R-b), so long healthy waits don't inflate backoff.
//   - Role: the party with the lexicographically smaller agreement key offers.

/// Who sends the WebRTC offer.
public enum RendezvousRole: Equatable, Sendable {
    case offerer
    case answerer

    /// Smaller raw agreement key (lexicographic) is the offerer.
    public static func forKeys(myKey: Data, peerKey: Data) throws -> RendezvousRole {
        try RendezvousKeyOrder.isLocalSmaller(myKey: myKey, peerKey: peerKey) ? .offerer : .answerer
    }
}

/// Internal failure cause. NEVER shown to the UI (it only sees `unreachable`)
/// and never logged with any identifier.
public enum RendezvousFailureReason: Equatable, Sendable {
    case signalingClosed
    case signalingTimeout
    case negotiationTimeout
    case negotiationFailed
    case secureChannelTimeout
    case secureChannelFailed
    case installRejected
    case connectionLost
}

/// Plaintext signaling payload carried inside a sealed `{"t":"sig"}` frame.
public enum RendezvousSignal: Equatable, Sendable {
    /// Sent once, immediately after our handshake completes: proves to the
    /// peer that we hold the DH (first valid sealed frame).
    case ready
    case offer(sdp: String)
    case answer(sdp: String)
    case ice(sdp: String, mid: String?, index: Int32)

    static let maxSDPBytes = 32 * 1024

    private struct Wire: Codable {
        var k: String
        var sdp: String?
        var mid: String?
        var idx: Int32?
    }

    public func encoded() -> Data {
        let w: Wire
        switch self {
        case .ready: w = Wire(k: "ready")
        case .offer(let s): w = Wire(k: "offer", sdp: s)
        case .answer(let s): w = Wire(k: "answer", sdp: s)
        case .ice(let s, let m, let i): w = Wire(k: "ice", sdp: s, mid: m, idx: i)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(w)) ?? Data()
    }

    public static func decode(_ data: Data) -> RendezvousSignal? {
        guard data.count <= maxSDPBytes + 512, let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch w.k {
        case "ready": return .ready
        case "offer": return w.sdp.flatMap { $0.utf8.count <= maxSDPBytes ? .offer(sdp: $0) : nil }
        case "answer": return w.sdp.flatMap { $0.utf8.count <= maxSDPBytes ? .answer(sdp: $0) : nil }
        case "ice":
            guard let s = w.sdp, s.utf8.count <= maxSDPBytes, let i = w.idx else { return nil }
            return .ice(sdp: s, mid: w.mid, index: i)
        default: return nil
        }
    }
}

public struct RendezvousSession: Equatable {

    public static let signalingTimeout: TimeInterval = 5
    public static let negotiationTimeout: TimeInterval = 30
    public static let secureChannelTimeout: TimeInterval = 5
    public static let maxJitter: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 300
    /// A socket open longer than this before failing resets the backoff (R-b).
    public static let healthySocketResetAfter: TimeInterval = 60
    /// Peer ICE candidates accepted per negotiation attempt (minor 11).
    public static let maxRemoteICECandidates = 64

    /// Coarse state (brief vocabulary).
    public enum State: Equatable {
        case idle
        case waiting
        case negotiating
        case connected
        case failed(RendezvousFailureReason)
        case closed
    }

    public enum Event: Equatable {
        case appForeground
        case appBackground
        case enabled
        case disabled
        /// `{"t":"joined"}` hint: a (new) peer socket is in the room. The
        /// signaling client has already started a fresh handshake and sent our hello.
        case peerJoined
        /// `{"t":"left"}` hint: peer socket gone; keep ours, await `joined`.
        case peerLeft
        /// The client accepted the peer's hello (cipher exists for this handshake).
        case signalingReady
        /// An authenticated, decrypted payload from the peer.
        case signal(Data)
        /// A payload produced by our own WebRTC negotiator.
        case localSignal(RendezvousSignal)
        /// The signaling socket closed (any cause; cause is never inspected).
        case signalingClosed
        case negotiationFailed
        case dataChannelOpen
        case installFailed
        case secureChannelResult(ok: Bool)
        /// The installed connection went away.
        case connectionLost
        /// A direct (nearby) connection to this contact exists: step aside.
        case directConnectionPresent
        /// The manager no longer wants this room (day rolled, sibling connected).
        case retire
        /// Another room of the same contact started negotiating (answerer follows the latest offer).
        case siblingNegotiating
        /// No sibling room is negotiating/connected any more.
        case negotiationSlotFree
        case tick
    }

    public enum Action: Equatable {
        case joinRoom(token: Data)
        case leaveRoom
        /// Plaintext payload; the signaling client seals and wraps it.
        case sendSignal(Data)
        case startNegotiation(RendezvousRole, attempt: Int)
        case deliverRemoteSignal(RendezvousSignal, attempt: Int)
        case installConnection(attempt: Int)
        case closeConnection
        case scheduleRetry(at: Date)
    }

    /// Per-event inputs that the pure machine cannot compute itself.
    public struct Context: Equatable {
        /// Another room of the same contact is negotiating or connected.
        public var siblingBusy: Bool
        /// Pre-drawn jitter, clamped to 0…30 s; used only when a join/retry is scheduled.
        public var jitter: TimeInterval
        public init(siblingBusy: Bool = false, jitter: TimeInterval = 0) {
            self.siblingBusy = siblingBusy
            self.jitter = jitter
        }
    }

    private enum Phase: Equatable {
        case idle(joinAt: Date?)
        case waiting
        case negotiating
        case connected(secured: Bool)
        case failed(RendezvousFailureReason, retryAt: Date)
        case closed
    }

    // MARK: Identity (immutable)

    public let contactID: UUID
    public let day: Int
    public let token: Data
    public let role: RendezvousRole

    // MARK: Mutable state

    public private(set) var isForeground: Bool
    public private(set) var isEnabled: Bool
    private var phase: Phase = .idle(joinAt: nil)
    /// The signaling socket is (being) opened — `leaveRoom` is meaningful.
    public private(set) var socketOpen = false
    public private(set) var peerPresent = false
    public private(set) var signalingReady = false
    /// The peer proved the DH with a valid sealed frame in this handshake.
    public private(set) var peerAuthenticated = false
    /// Offerer parked: authenticated but a sibling room holds the slot.
    public private(set) var parked = false
    public private(set) var consecutiveFailures = 0
    /// Increments on every startNegotiation; tags async work so stale callbacks are dropped.
    public private(set) var attempt = 0
    public private(set) var signalingDeadline: Date?
    public private(set) var negotiationDeadline: Date?
    public private(set) var secureDeadline: Date?
    /// When the current signaling socket was opened (nil when none).
    public private(set) var socketOpenedAt: Date?
    /// Peer ICE candidates delivered in the current attempt (capped).
    public private(set) var remoteICECount = 0

    public init(contactID: UUID, day: Int, token: Data, role: RendezvousRole,
                isForeground: Bool = false, isEnabled: Bool = false) {
        self.contactID = contactID
        self.day = day
        self.token = token
        self.role = role
        self.isForeground = isForeground
        self.isEnabled = isEnabled
    }

    public var state: State {
        switch phase {
        case .idle: return .idle
        case .waiting: return .waiting
        case .negotiating: return .negotiating
        case .connected: return .connected
        case .failed(let r, _): return .failed(r)
        case .closed: return .closed
        }
    }

    public var isSecured: Bool { phase == .connected(secured: true) }
    /// Negotiating or connected — holds the per-contact slot.
    public var holdsSlot: Bool {
        switch phase {
        case .negotiating, .connected: return true
        default: return false
        }
    }
    public var pendingJoinAt: Date? {
        if case .idle(let at) = phase { return at }
        return nil
    }
    public var retryAt: Date? {
        if case .failed(_, let at) = phase { return at }
        return nil
    }

    /// Exponential backoff: failure n (≥1) waits min(2^(n−1), 300) s, plus jitter 0…30 s.
    public static func backoffDelay(failures: Int, jitter: TimeInterval) -> TimeInterval {
        let n = max(failures, 1)
        let base = n > 10 ? maxBackoff : min(pow(2, Double(n - 1)), maxBackoff)
        return base + clampJitter(jitter)
    }

    static func clampJitter(_ j: TimeInterval) -> TimeInterval {
        guard j.isFinite else { return 0 }
        return min(max(j, 0), maxJitter)
    }

    // MARK: - Transition function

    public mutating func handle(_ event: Event, now: Date, context: Context = Context()) -> [Action] {
        if case .closed = phase { return [] }

        // Events valid in every live phase.
        switch event {
        case .disabled:
            isEnabled = false
            return teardown(to: .closed)
        case .retire, .directConnectionPresent:
            return teardown(to: .closed)
        case .appBackground:
            isForeground = false
            return teardown(to: .idle(joinAt: nil))
        case .appForeground, .enabled:
            if event == .appForeground { isForeground = true } else { isEnabled = true }
            guard case .idle(let joinAt) = phase, joinAt == nil, isForeground, isEnabled else { return [] }
            consecutiveFailures = 0
            return join(now: now)  // R-a: no jitter on the first attempt
        default:
            break
        }

        switch phase {
        case .idle(let joinAt):
            if event == .tick, let at = joinAt, now >= at, isForeground, isEnabled { return join(now: now) }
            return []
        case .failed(_, let retryAt):
            if event == .tick, now >= retryAt, isForeground, isEnabled { return join(now: now) }
            return []
        case .waiting:
            return handleWaiting(event, now: now, context: context)
        case .negotiating:
            return handleNegotiating(event, now: now, context: context)
        case .connected(let secured):
            return handleConnected(event, secured: secured, now: now, context: context)
        case .closed:
            return []
        }
    }

    // MARK: Phases

    private mutating func handleWaiting(_ event: Event, now: Date, context: Context) -> [Action] {
        switch event {
        case .peerJoined:
            resetPeer()
            peerPresent = true
            signalingDeadline = now.addingTimeInterval(Self.signalingTimeout)
            return []
        case .peerLeft:
            resetPeer()
            return []
        case .signalingReady:
            guard peerPresent, !signalingReady else { return [] }
            signalingReady = true
            return [.sendSignal(RendezvousSignal.ready.encoded())]
        case .signal(let data):
            guard peerPresent, signalingReady else { return [] }
            markAuthenticated()
            guard let sig = RendezvousSignal.decode(data) else { return [] }
            switch (sig, role) {
            case (.ready, .offerer):
                if context.siblingBusy { parked = true; return [] }
                return startNegotiation(now: now)
            case (.offer, .answerer):
                var actions = startNegotiation(now: now)
                actions.append(.deliverRemoteSignal(sig, attempt: attempt))
                return actions
            default:
                return []  // wrong-role or out-of-order payloads are dropped
            }
        case .negotiationSlotFree:
            guard parked, role == .offerer, peerPresent, peerAuthenticated, !context.siblingBusy else { return [] }
            return startNegotiation(now: now)
        case .signalingClosed:
            socketOpen = false
            return fail(.signalingClosed, now: now, context: context, extra: [])
        case .tick:
            if let d = signalingDeadline, now >= d {
                return fail(.signalingTimeout, now: now, context: context, extra: [.leaveRoom])
            }
            return []
        default:
            return []
        }
    }

    private mutating func handleNegotiating(_ event: Event, now: Date, context: Context) -> [Action] {
        switch event {
        case .localSignal(let sig):
            switch (sig, role) {
            case (.offer, .offerer), (.answer, .answerer), (.ice, _):
                return [.sendSignal(sig.encoded())]
            default:
                return []
            }
        case .signal(let data):
            guard let sig = RendezvousSignal.decode(data) else { return [] }
            switch (sig, role) {
            case (.ice, _):
                guard remoteICECount < Self.maxRemoteICECandidates else { return [] }
                remoteICECount += 1
                return [.deliverRemoteSignal(sig, attempt: attempt)]
            case (.answer, .offerer):
                return [.deliverRemoteSignal(sig, attempt: attempt)]
            default:
                return []  // a second offer / stray ready is dropped
            }
        case .dataChannelOpen:
            negotiationDeadline = nil
            secureDeadline = now.addingTimeInterval(Self.secureChannelTimeout)
            phase = .connected(secured: false)
            return [.installConnection(attempt: attempt)]
        case .negotiationFailed:
            return fail(.negotiationFailed, now: now, context: context, extra: [.closeConnection, .leaveRoom])
        case .peerLeft:
            negotiationDeadline = nil
            phase = .waiting
            resetPeer()
            return [.closeConnection]
        case .peerJoined:
            // The peer restarted (new socket ⇒ new handshake already begun by the client).
            negotiationDeadline = nil
            phase = .waiting
            resetPeer()
            peerPresent = true
            signalingDeadline = now.addingTimeInterval(Self.signalingTimeout)
            return [.closeConnection]
        case .siblingNegotiating:
            negotiationDeadline = nil
            phase = .waiting
            parked = role == .offerer
            return [.closeConnection]
        case .signalingClosed:
            socketOpen = false
            return fail(.signalingClosed, now: now, context: context, extra: [.closeConnection])
        case .tick:
            if let d = negotiationDeadline, now >= d {
                return fail(.negotiationTimeout, now: now, context: context, extra: [.closeConnection, .leaveRoom])
            }
            return []
        default:
            return []
        }
    }

    private mutating func handleConnected(_ event: Event, secured: Bool, now: Date, context: Context) -> [Action] {
        switch event {
        case .secureChannelResult(let ok):
            guard !secured else { return [] }
            guard ok else {
                return fail(.secureChannelFailed, now: now, context: context, extra: [.closeConnection, .leaveRoom])
            }
            secureDeadline = nil
            consecutiveFailures = 0
            phase = .connected(secured: true)
            // Signaling is done: leave the room (nothing else is sent).
            return socketOpen ? leave() : []
        case .installFailed:
            guard !secured else { return [] }
            return fail(.installRejected, now: now, context: context, extra: [.closeConnection, .leaveRoom])
        case .connectionLost:
            return fail(.connectionLost, now: now, context: context, extra: [.closeConnection, .leaveRoom])
        case .signalingClosed:
            socketOpen = false
            socketOpenedAt = nil
            return []  // the connection, not the room, matters now
        case .tick:
            if !secured, let d = secureDeadline, now >= d {
                return fail(.secureChannelTimeout, now: now, context: context, extra: [.closeConnection, .leaveRoom])
            }
            return []
        default:
            // Hints (joined/left), late signals and ICE are irrelevant once open.
            return []
        }
    }

    // MARK: Helpers

    private mutating func join(now: Date) -> [Action] {
        phase = .waiting
        socketOpen = true
        socketOpenedAt = now
        resetPeer()
        return [.joinRoom(token: token)]
    }

    private mutating func startNegotiation(now: Date) -> [Action] {
        attempt += 1
        remoteICECount = 0
        parked = false
        phase = .negotiating
        negotiationDeadline = now.addingTimeInterval(Self.negotiationTimeout)
        return [.startNegotiation(role, attempt: attempt)]
    }

    private mutating func markAuthenticated() {
        peerAuthenticated = true
        signalingDeadline = nil
    }

    private mutating func resetPeer() {
        peerPresent = false
        signalingReady = false
        peerAuthenticated = false
        parked = false
        signalingDeadline = nil
    }

    private mutating func leave() -> [Action] {
        guard socketOpen else { return [] }
        socketOpen = false
        socketOpenedAt = nil
        return [.leaveRoom]
    }

    /// Closing paths that never send a frame (downgrade, background, retire).
    private mutating func teardown(to next: Phase) -> [Action] {
        var actions: [Action] = []
        if holdsSlot { actions.append(.closeConnection) }
        actions += leave()
        resetPeer()
        negotiationDeadline = nil
        secureDeadline = nil
        phase = next
        return actions
    }

    private mutating func fail(_ reason: RendezvousFailureReason, now: Date, context: Context, extra: [Action]) -> [Action] {
        if let opened = socketOpenedAt, now.timeIntervalSince(opened) > Self.healthySocketResetAfter {
            consecutiveFailures = 0  // R-b: the socket was healthy for > 60 s
        }
        var actions: [Action] = []
        for a in extra {
            if a == .leaveRoom { actions += leave() } else { actions.append(a) }
        }
        socketOpen = false
        socketOpenedAt = nil
        resetPeer()
        negotiationDeadline = nil
        secureDeadline = nil
        consecutiveFailures += 1
        let at = now.addingTimeInterval(Self.backoffDelay(failures: consecutiveFailures, jitter: context.jitter))
        phase = .failed(reason, retryAt: at)
        actions.append(.scheduleRetry(at: at))
        return actions
    }
}
