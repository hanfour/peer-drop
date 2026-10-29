import Foundation

/// A text-oriented WebSocket connection used by group live updates.
public protocol GroupWebSocket: AnyObject, Sendable {
    /// Sends one text frame.
    func send(text: String) async throws

    /// Receives the next text frame.
    func receive() async throws -> String

    /// Closes the connection.
    func close()
}

/// Builds group WebSocket connections for production or tests.
public protocol GroupWebSocketFactory: Sendable {
    /// Creates and starts a connection for the supplied URL.
    func make(url: URL) -> GroupWebSocket
}

/// The close code reported by a WebSocket connection.
public enum GroupWebSocketFailure: Error, Equatable, Sendable {
    /// The server closed the connection with this WebSocket code.
    case closed(code: Int)
}

/// Clock and sleep operations used by socket timers.
public protocol GroupSocketClock: Sendable {
    /// Suspends for the requested duration or throws when cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

/// The system clock used for keepalive and reconnect delays.
public struct GroupSocketSystemClock: GroupSocketClock {
    /// Creates a clock backed by task sleep.
    public init() {}

    /// Suspends for the requested duration.
    public func sleep(for seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// The store action associated with a socket lifecycle transition.
public enum CloseReason: Equatable, Sendable {
    /// The server reported that this member was removed.
    case removed

    /// A replacement connection received its first server frame.
    case reconnected
}

/// URLSession-backed factory for group WebSocket connections.
public struct URLSessionGroupWebSocketFactory: GroupWebSocketFactory {
    private let session: URLSession

    /// Creates a factory using an isolated URL session by default.
    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Creates and starts a WebSocket task without adding request headers.
    public func make(url: URL) -> GroupWebSocket {
        let task = session.webSocketTask(with: url)
        task.resume()
        return URLSessionGroupWebSocket(task: task)
    }
}

/// Manages one group's WebSocket, keepalive, ticket renewal, and reconnect loop.
public actor GroupSocket {
    private let groupId: String
    private let baseURL: URL
    private let ticketProvider: @Sendable () async throws -> String
    private let factory: GroupWebSocketFactory
    private let onEvent: @Sendable (WireEvent) -> Void
    private let onClosed: @Sendable (CloseReason) -> Void
    private let clock: GroupSocketClock
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private var activeSocket: GroupWebSocket?
    private var runTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    /// Creates a socket that obtains a single-use ticket before each connection.
    public init(
        groupId: String,
        baseURL: URL,
        ticket: @escaping @Sendable () async throws -> String,
        factory: GroupWebSocketFactory,
        onEvent: @escaping @Sendable (WireEvent) -> Void,
        onClosed: @escaping @Sendable (CloseReason) -> Void,
        clock: GroupSocketClock = GroupSocketSystemClock(),
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { $0 * Double.random(in: 0.75...1.25) }
    ) {
        self.groupId = groupId
        self.baseURL = baseURL
        self.ticketProvider = ticket
        self.factory = factory
        self.onEvent = onEvent
        self.onClosed = onClosed
        self.clock = clock
        self.jitter = jitter
    }

    /// Starts the connection loop once. A stopped socket cannot be restarted.
    public func start() {
        guard !started, !stopped else { return }
        started = true
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    /// Cancels timers, closes the current connection, and prevents future reconnects.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        activeSocket?.close()
        activeSocket = nil
        runTask?.cancel()
        runTask = nil
    }

    private func run() async {
        let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30]
        var backoffIndex = 0
        var hasConnected = false

        while !stopped && !Task.isCancelled {
            let ticketValue: String
            do {
                ticketValue = try await ticketProvider()
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                let groupError = (error as? GroupError) ?? GroupError.from(error)
                switch groupError {
                case .notMember:
                    finishAsRemoved()
                    return
                case .cancelled:
                    return
                case .transient:
                    break
                default:
                    break
                }
                guard await waitToRetry(delays[backoffIndex]) else { return }
                backoffIndex = min(backoffIndex + 1, delays.count - 1)
                continue
            }
            guard !stopped, !Task.isCancelled else { return }
            guard let url = Self.socketURL(baseURL: baseURL, groupId: groupId, ticket: ticketValue) else { return }

            let socket = factory.make(url: url)
            activeSocket = socket
            let result = await receive(from: socket, isReconnect: hasConnected)
            activeSocket = nil
            socket.close()
            guard !stopped, !Task.isCancelled else { return }

            switch result {
            case .removed:
                finishAsRemoved()
                return
            case .stopped:
                return
            case .disconnected(let receivedFrame):
                if receivedFrame {
                    hasConnected = true
                    backoffIndex = 0
                }
                guard await waitToRetry(delays[backoffIndex]) else { return }
                backoffIndex = min(backoffIndex + 1, delays.count - 1)
            }
        }
    }

    private enum ConnectionResult {
        case removed
        case stopped
        case disconnected(receivedFrame: Bool)
    }

    private func receive(from socket: GroupWebSocket, isReconnect: Bool) async -> ConnectionResult {
        let keepalive = Task { [clock] in
            do {
                while !Task.isCancelled {
                    try await clock.sleep(for: 30)
                    try Task.checkCancellation()
                    try await socket.send(text: "ping")
                }
            } catch {
                if !Task.isCancelled { socket.close() }
            }
        }
        defer { keepalive.cancel() }

        var receivedFrame = false
        do {
            while !stopped && !Task.isCancelled {
                let frame = try await socket.receive()
                if !receivedFrame {
                    receivedFrame = true
                    if isReconnect { onClosed(.reconnected) }
                }
                handle(frame)
            }
            return .stopped
        } catch {
            guard !stopped, !Task.isCancelled else { return .stopped }
            if let failure = error as? GroupWebSocketFailure,
               case .closed(code: 4003) = failure { return .removed }
            return .disconnected(receivedFrame: receivedFrame)
        }
    }

    private func handle(_ frame: String) {
        struct Envelope: Decodable {
            let t: String
            let e: WireEvent?
        }
        guard let data = frame.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.t == "ev",
              let event = envelope.e else { return }
        onEvent(event)
    }

    private func waitToRetry(_ baseDelay: TimeInterval) async -> Bool {
        do {
            try await clock.sleep(for: min(max(jitter(baseDelay), 0), 37.5))
            return !stopped && !Task.isCancelled
        } catch {
            return false
        }
    }

    private func finishAsRemoved() {
        stopped = true
        activeSocket?.close()
        activeSocket = nil
        runTask = nil
        onClosed(.removed)
    }

    private static func socketURL(baseURL: URL, groupId: String, ticket: String) -> URL? {
        guard groupId.utf8.count == 26,
              groupId.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/v3/groups/\(groupId)/ws"
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        components.fragment = nil
        return components.url
    }
}

private final class URLSessionGroupWebSocket: GroupWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        do {
            let message = try await task.receive()
            switch message {
            case .string(let text): return text
            case .data(_): return "\u{0}"
            @unknown default: return "\u{0}"
            }
        } catch {
            if task.closeCode != .invalid {
                throw GroupWebSocketFailure.closed(code: Int(task.closeCode.rawValue))
            }
            throw error
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
