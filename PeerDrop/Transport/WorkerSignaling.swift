import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "WorkerSignaling")

/// Client for the PeerDrop Cloudflare Worker signaling server.
final class WorkerSignaling: NSObject {

    // MARK: - Properties

    private let baseURL: URL
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    // MARK: - Callbacks

    var onSDPOffer: ((String) -> Void)?
    var onSDPAnswer: ((String) -> Void)?
    var onICECandidate: ((String, String?, Int32) -> Void)? // sdp, sdpMid, sdpMLineIndex
    var onPeerJoined: (() -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Default Worker URL

    private static let defaultWorkerURL = "https://peerdrop-signal.hanfourhuang.workers.dev"

    static var workerURL: String {
        UserDefaults.standard.string(forKey: "peerDropWorkerURL") ?? defaultWorkerURL
    }

    /// API key for authenticating with the Worker.
    private let apiKey: String?

    /// Read the API key from Info.plist (injected via build settings).
    private static var bundledAPIKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "PeerDropWorkerAPIKey") as? String
    }

    // MARK: - Init

    init(baseURL: URL? = nil, apiKey: String? = nil) {
        self.baseURL = baseURL ?? URL(string: Self.workerURL)!
        self.apiKey = apiKey ?? UserDefaults.standard.string(forKey: "peerDropWorkerAPIKey") ?? Self.bundledAPIKey
        self.session = URLSession(configuration: .default)
        super.init()
    }

    deinit {
        disconnect()
    }

    // MARK: - Room Management

    /// Room creation result containing code and auth token.
    struct RoomInfo {
        let roomCode: String
        let roomToken: String
    }

    /// Create a new signaling room. Returns the room code and auth token.
    func createRoom() async throws -> RoomInfo {
        let url = baseURL.appendingPathComponent("room")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            throw WorkerSignalingError.roomCreationFailed
        }

        struct RoomResponse: Decodable {
            let roomCode: String
            let roomToken: String
        }

        let roomResponse = try JSONDecoder().decode(RoomResponse.self, from: data)
        logger.info("Created room: \(roomResponse.roomCode)")
        return RoomInfo(roomCode: roomResponse.roomCode, roomToken: roomResponse.roomToken)
    }

    /// Join an existing room via WebSocket for signaling.
    func joinRoom(code: String, token: String? = nil) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/room/\(code)"
        if let token {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }

        let wsURL = components.url!
        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        logger.info("WebSocket connecting to room: \(code)")
        startReceiving()
    }

    /// ICE credentials result, optionally including a room token for WebSocket auth.
    struct ICEResult {
        let credentials: ICECredentials?
        let roomToken: String?
    }

    /// Request ICE/TURN credentials for a room. Also returns the room token for WebSocket auth.
    func requestICECredentials(roomCode: String) async throws -> ICEResult {
        let url = baseURL.appendingPathComponent("room/\(roomCode)/ice")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WorkerSignalingError.iceCredentialsFailed
        }

        struct ICEResponse: Decodable {
            let iceServers: [ICEServerResponse]
            let roomToken: String?
        }
        struct ICEServerResponse: Decodable {
            let urls: [String]
            let username: String?
            let credential: String?
        }

        let iceResponse = try JSONDecoder().decode(ICEResponse.self, from: data)

        // Find the TURN server entry
        let creds: ICECredentials?
        if let turnServer = iceResponse.iceServers.first(where: { $0.username != nil }) {
            creds = ICECredentials(
                username: turnServer.username!,
                credential: turnServer.credential ?? "",
                urls: turnServer.urls,
                ttl: 900
            )
        } else {
            creds = nil
        }

        return ICEResult(credentials: creds, roomToken: iceResponse.roomToken)
    }

    // MARK: - Signaling Messages

    func sendSDP(_ sdp: String, type: String) {
        let message: [String: Any] = [
            "type": type,
            "sdp": sdp
        ]
        sendJSON(message)
    }

    func sendICECandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        let message: [String: Any] = [
            "type": "ice-candidate",
            "candidate": sdp,
            "sdpMid": sdpMid ?? "",
            "sdpMLineIndex": sdpMLineIndex
        ]
        sendJSON(message)
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Private

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize signaling message")
            return
        }
        webSocketTask?.send(.string(string)) { [weak self] error in
            if let error {
                logger.error("WebSocket send error: \(error.localizedDescription)")
                self?.onError?(error)
            }
        }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let task = self?.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    // Re-check self after await to avoid retaining across suspension
                    guard let self else { break }
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        logger.error("WebSocket receive error: \(error.localizedDescription)")
                        self?.onError?(error)
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.warning("Received invalid signaling message")
            return
        }

        switch type {
        case "offer":
            if let sdp = json["sdp"] as? String {
                onSDPOffer?(sdp)
            }
        case "answer":
            if let sdp = json["sdp"] as? String {
                onSDPAnswer?(sdp)
            }
        case "ice-candidate":
            if let candidate = json["candidate"] as? String {
                let sdpMid = json["sdpMid"] as? String
                let sdpMLineIndex = json["sdpMLineIndex"] as? Int32 ?? 0
                onICECandidate?(candidate, sdpMid, sdpMLineIndex)
            }
        case "peer-joined":
            onPeerJoined?()
        default:
            logger.debug("Unknown signaling message type: \(type)")
        }
    }
}

// MARK: - Errors

enum WorkerSignalingError: LocalizedError {
    case roomCreationFailed
    case roomNotFound
    case iceCredentialsFailed
    case noTURNCredentials
    case webSocketError

    var errorDescription: String? {
        switch self {
        case .roomCreationFailed: return "Failed to create signaling room"
        case .roomNotFound: return "Room not found or expired"
        case .iceCredentialsFailed: return "Failed to get ICE credentials"
        case .noTURNCredentials: return "No TURN credentials available"
        case .webSocketError: return "WebSocket connection error"
        }
    }
}
