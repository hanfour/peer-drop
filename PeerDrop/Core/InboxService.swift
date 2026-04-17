import Foundation
import os.log

@MainActor
final class InboxService: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "InboxService")
    private let deviceId: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    @Published var isConnected: Bool = false
    @Published var receivedInvite: RelayInvite?

    init(deviceId: String = DeviceIdentity.deviceId) {
        self.deviceId = deviceId
        super.init()
    }

    func connect() {
        disconnect()
        let base = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard var components = URLComponents(string: base) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v2/inbox/\(deviceId)"
        guard let url = components.url else { return }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        isConnected = true
        logger.info("Inbox WS connecting for device: \(self.deviceId.prefix(8))")
        startReceive()
        startPing()
    }

    func disconnect() {
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
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
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let task = await self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
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
                    }
                    break
                }
            }
        }
    }

    private func startPing() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let task = await self.webSocketTask else { break }
                task.sendPing { error in
                    _ = error
                }
            }
        }
    }
}
