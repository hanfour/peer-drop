import Foundation

// Project E — client for ONE anonymous rendezvous room (`/rv`).
//
// Wire contract (cloudflare-worker/src/rendezvousRoute.ts, rendezvousRoom.ts):
//   - `GET /rv` WebSocket; the token is never in the URL. First text frame =
//     `RendezvousFirstFrame` ({v,t,pow,s}); PoW solved OFF the main actor.
//   - The literal text frame "ping" at least every 30 s (we send every 25 s so
//     tick jitter never pushes it past 30 s). Protocol-level pings do not count.
//     The DO auto-answers "pong" (ignored).
//   - `{"t":"joined"}` / `{"t":"left"}` are relayed on the same channel as peer
//     frames, so they are HINTS only; app frames are wrapped as
//     `{"t":"sig","c":"<b64url sealed>"}`, hellos are `{"t":"hello","r":…}`.
//   - Any close = session over. The close code/reason is never read.
//   - `POST /rv/ice` body {t,pow} → {"iceServers":[{urls,username?,credential?}]}.
//
// Handshake rules (Task 3 review, binding):
//   - A NEW handshake (fresh 8-byte r) starts only on `joined`; our hello is
//     sent only after `joined`.
//   - The first acceptable hello completes the handshake; any later hello is
//     dropped (never rebind). A hello before `joined` is dropped.
//   - The FIRST sealed frame failing AEAD ⇒ discard cipher, close the socket,
//     report `.closed`. A LATER failure (bad tag, stale counter) ⇒ drop the
//     frame; the cipher is never reset or rebuilt.
//   - The cipher only ever comes from `RendezvousSignalingHandshake.accept`.
//
// Privacy: nothing here logs. Tokens, keys, session tags, SDP and IPs never
// leave this type except as the frames above.

/// What the room tells the session. `.closed` is the ONLY failure signal
/// (internally "unreachable"); no cause is ever distinguished.
public enum RendezvousSignalingEvent: Equatable {
    case peerJoined
    case peerLeft
    case handshakeCompleted
    case signal(Data)
    case closed
}

/// ICE server entry as returned by `POST /rv/ice`.
public struct RendezvousICEServer: Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?
    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// Seam used by `RendezvousManager` (tests inject a fake; no network/WebRTC).
@MainActor
public protocol RendezvousSignalingTransport: AnyObject {
    var onEvent: ((RendezvousSignalingEvent) -> Void)? { get set }
    func connect()
    /// Seal + wrap a plaintext signaling payload. Dropped if no cipher yet.
    func sendSignal(_ plaintext: Data)
    /// Drives the keepalive cadence.
    func tick(now: Date)
    /// Close without emitting any event; idempotent.
    func close()
    /// Anonymous STUN/TURN config; [] on any failure (callers fall back to STUN).
    func fetchICEServers() async -> [RendezvousICEServer]
}

@MainActor
public protocol RendezvousSignalingTransportFactory: AnyObject {
    func makeTransport(token: Data, day: Int, peerKey: Data) -> RendezvousSignalingTransport
}

// MARK: - Lower-level seams

/// Minimal text WebSocket. Callbacks arrive on the main actor. `close()` must
/// not trigger `onClose`.
@MainActor
public protocol RendezvousWebSocket: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func send(text: String)
    func close()
}

@MainActor
public protocol RendezvousWebSocketFactory: AnyObject {
    func makeSocket(url: URL) -> RendezvousWebSocket
}

public protocol RendezvousHTTPPoster: Sendable {
    /// Returns (body, HTTP status). Throws on transport errors.
    func post(url: URL, body: Data) async throws -> (Data, Int)
}

public protocol RendezvousPoWSolving: Sendable {
    func solve(token: Data, hour: Int) async throws -> String
}

/// Runs `RendezvousProofOfWork.solve` on a detached task (never the main actor).
public struct DetachedRendezvousPoWSolver: RendezvousPoWSolving {
    /// Test hook: called on the solving thread with `true` iff it is the main thread.
    public var threadObserver: (@Sendable (Bool) -> Void)?
    public init(threadObserver: (@Sendable (Bool) -> Void)? = nil) {
        self.threadObserver = threadObserver
    }
    public func solve(token: Data, hour: Int) async throws -> String {
        let observer = threadObserver
        return try await Task.detached(priority: .utility) {
            observer?(pthread_main_np() != 0)
            return try RendezvousProofOfWork.solve(tokenBytes: token, hour: hour)
        }.value
    }
}

extension RendezvousSessionTagStore {
    /// The ONE tag store for this process (app run). Never persisted.
    public static let process = RendezvousSessionTagStore()
}

// MARK: - Client

@MainActor
public final class RendezvousSignalingClient: RendezvousSignalingTransport {

    public nonisolated static let pingInterval: TimeInterval = 25
    public nonisolated static let maxInboundFrameBytes = 64 * 1024
    static let joinedFrame = #"{"t":"joined"}"#
    static let leftFrame = #"{"t":"left"}"#

    public var onEvent: ((RendezvousSignalingEvent) -> Void)?

    private enum Phase { case idle, connecting, open, closed }

    private let token: Data
    private let day: Int
    private let peerKey: Data
    private let provider: RendezvousSecretProvider
    private let sessionTags: RendezvousSessionTagStore
    private let baseURL: URL
    private let socketFactory: RendezvousWebSocketFactory
    private let http: RendezvousHTTPPoster
    private let solver: RendezvousPoWSolving
    private let random: RendezvousRandomSource
    private let clock: () -> Date

    private var phase: Phase = .idle
    private var socket: RendezvousWebSocket?
    private var handshake: RendezvousSignalingHandshake?
    private var cipher: RendezvousSignalingCipher?
    private var receivedValidSealed = false
    private var lastPingAt: Date?
    private var powCache: (hour: Int, nonce: String)?
    /// In-flight `/rv/ice` fetches; `close()` cancels them (and with them the
    /// URLSession request), so a downgrade stops a request already under way.
    private var iceTasks: [UUID: Task<[RendezvousICEServer], Never>] = [:]

    public init(
        token: Data,
        day: Int,
        peerKey: Data,
        provider: RendezvousSecretProvider,
        sessionTags: RendezvousSessionTagStore = .process,
        baseURL: URL,
        socketFactory: RendezvousWebSocketFactory,
        http: RendezvousHTTPPoster,
        solver: RendezvousPoWSolving = DetachedRendezvousPoWSolver(),
        random: RendezvousRandomSource = SystemRendezvousRandom.shared,
        clock: @escaping () -> Date = Date.init
    ) {
        self.token = token
        self.day = day
        self.peerKey = peerKey
        self.provider = provider
        self.sessionTags = sessionTags
        self.baseURL = baseURL
        self.socketFactory = socketFactory
        self.http = http
        self.solver = solver
        self.random = random
        self.clock = clock
    }

    /// Exposed for tests only (never logged).
    var hasCipher: Bool { cipher != nil }

    public func connect() {
        guard phase == .idle else { return }
        phase = .connecting
        let hour = RendezvousProofOfWork.currentHour(now: clock())
        let solver = self.solver
        let token = self.token
        Task { [weak self] in
            do {
                let nonce = try await solver.solve(token: token, hour: hour)
                self?.didSolve(hour: hour, nonce: nonce)
            } catch {
                self?.fail()
            }
        }
    }

    private func didSolve(hour: Int, nonce: String) {
        guard phase == .connecting else { return }
        let frame: String
        do {
            frame = try RendezvousFirstFrame.build(token: token, hour: hour, nonce: nonce,
                                                   sessionTag: sessionTags.tag(for: token))
        } catch {
            fail()
            return
        }
        powCache = (hour, nonce)
        let s = socketFactory.makeSocket(url: Self.socketURL(base: baseURL))
        socket = s
        s.onText = { [weak self] text in self?.receive(text) }
        s.onClose = { [weak self] in self?.fail() }
        phase = .open
        s.send(text: frame)
        lastPingAt = clock()
    }

    public func tick(now: Date) {
        guard phase == .open, let s = socket else { return }
        if let last = lastPingAt, now.timeIntervalSince(last) < Self.pingInterval { return }
        lastPingAt = now
        s.send(text: "ping")
    }

    public func sendSignal(_ plaintext: Data) {
        guard phase == .open, let s = socket, let cipher else { return }
        do {
            let wire = try cipher.seal(plaintext)
            s.send(text: #"{"t":"sig","c":""# + RendezvousToken.encodeBase64URL(wire) + #""}"#)
        } catch {
            fail()
        }
    }

    public func close() {
        guard phase != .closed else { return }
        phase = .closed
        teardown()
    }

    // MARK: Inbound

    func receive(_ text: String) {
        guard phase == .open else { return }
        guard text.utf8.count <= Self.maxInboundFrameBytes else { return }
        if text == "pong" { return }
        if text == Self.joinedFrame {
            // Fresh handshake with a fresh r; the old cipher (if any) is discarded, never reused.
            cipher = nil
            receivedValidSealed = false
            guard let h = try? RendezvousSignalingHandshake(provider: provider, peerKey: peerKey, day: day, random: random) else {
                handshake = nil
                fail()
                return
            }
            handshake = h
            socket?.send(text: h.helloFrame)
            onEvent?(.peerJoined)
            return
        }
        if text == Self.leftFrame {
            handshake = nil
            cipher = nil
            receivedValidSealed = false
            onEvent?(.peerLeft)
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let kind = obj["t"] as? String else { return }
        switch kind {
        case "hello":
            // Only before completion of the CURRENT handshake; never rebind.
            guard let h = handshake, cipher == nil, let c = try? h.accept(peerHelloFrame: text) else { return }
            cipher = c
            onEvent?(.handshakeCompleted)
        case "sig":
            guard let cipher else { return }
            let opened = (obj["c"] as? String)
                .flatMap { Self.decodeBase64URLAnyLength($0) }
                .flatMap { try? cipher.open($0) }
            if let plaintext = opened {
                receivedValidSealed = true
                onEvent?(.signal(plaintext))
            } else if !receivedValidSealed {
                fail()  // first sealed frame not authentic: discard cipher, close
            }
            // else: later failure → drop the frame, keep the cipher.
        default:
            return
        }
    }

    private func fail() {
        guard phase != .closed else { return }
        phase = .closed
        teardown()
        onEvent?(.closed)
    }

    private func teardown() {
        let tasks = iceTasks.values
        iceTasks = [:]
        tasks.forEach { $0.cancel() }
        handshake = nil
        cipher = nil
        receivedValidSealed = false
        let s = socket
        socket = nil
        s?.onText = nil
        s?.onClose = nil
        s?.close()
    }

    // MARK: ICE

    /// Only while the socket is open: a closed client (downgrade, background,
    /// retire) never solves PoW for, nor POSTs, its token again.
    public func fetchICEServers() async -> [RendezvousICEServer] {
        guard phase == .open else { return [] }
        let id = UUID()
        let task = Task { [weak self] () -> [RendezvousICEServer] in
            await self?.performICEFetch() ?? []
        }
        iceTasks[id] = task
        let servers = await task.value
        iceTasks[id] = nil
        return phase == .open ? servers : []
    }

    private func performICEFetch() async -> [RendezvousICEServer] {
        guard phase == .open else { return [] }
        let hour = RendezvousProofOfWork.currentHour(now: clock())
        let nonce: String
        if let c = powCache, c.hour == hour {
            nonce = c.nonce
        } else {
            guard let n = try? await solver.solve(token: token, hour: hour) else { return [] }
            guard phase == .open else { return [] }  // closed during the solve
            powCache = (hour, n)
            nonce = n
        }
        guard let encoded = try? RendezvousToken.encoded(token),
              let body = try? JSONSerialization.data(withJSONObject: ["t": encoded, "pow": ["h": hour, "n": nonce]])
        else { return [] }
        guard phase == .open, !Task.isCancelled else { return [] }
        guard let (data, status) = try? await http.post(url: baseURL.appendingPathComponent("rv/ice"), body: body),
              status == 200 else { return [] }
        return Self.parseICEServers(data)
    }

    nonisolated static func parseICEServers(_ data: Data) -> [RendezvousICEServer] {
        guard data.count <= 16 * 1024,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["iceServers"] as? [[String: Any]] else { return [] }
        var out: [RendezvousICEServer] = []
        for entry in list.prefix(8) {
            let urls = (entry["urls"] as? [String] ?? (entry["urls"] as? String).map { [$0] } ?? [])
                .filter { $0.hasPrefix("stun:") || $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
            guard !urls.isEmpty else { continue }
            out.append(RendezvousICEServer(urls: Array(urls.prefix(8)),
                                           username: entry["username"] as? String,
                                           credential: entry["credential"] as? String))
        }
        return out
    }

    // MARK: Helpers

    nonisolated static func socketURL(base: URL) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = (base.scheme == "http") ? "ws" : "wss"
        c.path = "/rv"
        c.query = nil
        c.fragment = nil
        return c.url ?? base
    }

    /// Canonical unpadded base64url of any length (sealed frames vary in size).
    nonisolated static func decodeBase64URLAnyLength(_ s: String) -> Data? {
        guard !s.isEmpty, s.utf8.count <= maxInboundFrameBytes else { return nil }
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return RendezvousToken.decodeBase64URL(s, expectedLength: data.count)
    }
}

// MARK: - Production adapters

/// Ephemeral: no cookies, cache or credential storage for the anonymous route.
enum RendezvousURLSession {
    static let shared = URLSession(configuration: .ephemeral)
}

@MainActor
public final class URLSessionRendezvousWebSocketFactory: RendezvousWebSocketFactory {
    public init() {}
    public func makeSocket(url: URL) -> RendezvousWebSocket {
        URLSessionRendezvousWebSocket(task: RendezvousURLSession.shared.webSocketTask(with: url))
    }
}

@MainActor
final class URLSessionRendezvousWebSocket: RendezvousWebSocket {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let task: URLSessionWebSocketTask
    private var finished = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
        receiveNext()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                switch result {
                case .success(.string(let s)):
                    self.onText?(s)
                    self.receiveNext()
                case .success:
                    self.receiveNext()  // binary frames are not part of the protocol
                case .failure:
                    self.finish()
                }
            }
        }
    }

    func send(text: String) {
        guard !finished else { return }
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.finish() }
        }
    }

    func close() {
        guard !finished else { return }
        finished = true
        onText = nil
        onClose = nil
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        task.cancel(with: .normalClosure, reason: nil)
        let cb = onClose
        onText = nil
        onClose = nil
        cb?()
    }
}

public struct URLSessionRendezvousHTTPPoster: RendezvousHTTPPoster {
    public init() {}
    public func post(url: URL, body: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let (data, resp) = try await RendezvousURLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
