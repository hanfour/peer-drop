import Foundation
import os.log

@MainActor
final class InboxService: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "InboxService")
    private let deviceId: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var session: URLSession?
    private var reconnectAttempt = 0
    private static let maxReconnectDelay: UInt64 = 30_000_000_000 // 30s

    @Published var isConnected: Bool = false
    @Published var receivedInvite: RelayInvite?

    init(deviceId: String = DeviceIdentity.deviceId) {
        self.deviceId = deviceId
        super.init()
    }

    func connect() {
        disconnect()
        reconnectAttempt = 0
        doConnect()
    }

    private func doConnect() {
        let base = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard var components = URLComponents(string: base) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v2/inbox/\(deviceId)"

        // Add API key as query param (WS upgrade can't use custom headers in URLSession)
        let apiKey = UserDefaults.standard.string(forKey: "peerDropWorkerAPIKey")
            ?? WorkerSignaling.bundledAPIKey
        if let apiKey {
            components.queryItems = [URLQueryItem(name: "apiKey", value: apiKey)]
        }

        guard let url = components.url else { return }

        if session == nil {
            session = URLSession(configuration: .default)
        }
        let task = session!.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        // isConnected stays false until first successful receive
        logger.info("Inbox WS connecting for device: \(self.deviceId.prefix(8)) (attempt \(self.reconnectAttempt))")
        startReceive()
        startPing()
    }

    func disconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    /// Parses a JSON string into a RelayInvite if valid. (Exposed for unit tests.)
    nonisolated func parseMessage(_ text: String) -> RelayInvite? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "relay-invite",
              let code = obj["roomCode"] as? String,
              let token = obj["roomToken"] as? String,
              let sender = obj["senderName"] as? String else {
            return nil
        }
        return RelayInvite(
            roomCode: code,
            roomToken: token,
            senderName: sender,
            senderId: obj["senderId"] as? String ?? "",
            source: .websocket
        )
    }

    private func startReceive() {
        // Explicit @MainActor: in Swift 6 strict concurrency, unannotated
        // `Task {}` no longer inherits the enclosing actor context, so reads
        // of `self.webSocketTask` (MainActor-isolated) would require `await`.
        // Marking the Task @MainActor makes the property access synchronous
        // and stays correct under both compilation modes.
        receiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    // First successful receive confirms connection
                    await MainActor.run {
                        if !self.isConnected {
                            self.isConnected = true
                            self.reconnectAttempt = 0
                        }
                    }
                    let text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text, let invite = self.parseMessage(text) {
                        await MainActor.run { self.receivedInvite = invite }
                    }
                } catch {
                    await MainActor.run {
                        self.logger.info("Inbox WS closed: \(error.localizedDescription)")
                        self.isConnected = false
                        self.scheduleReconnect()
                    }
                    break
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt += 1

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s max
        let baseDelay: UInt64 = 1_000_000_000
        let delay = min(baseDelay * (1 << UInt64(min(attempt, 5))), Self.maxReconnectDelay)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.logger.info("Inbox WS reconnecting (attempt \(self.reconnectAttempt))")
            self.doConnect()
        }
    }

    private func startPing() {
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let task = self.webSocketTask else { break }
                task.sendPing { error in
                    _ = error
                }
            }
        }
    }
}
