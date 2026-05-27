import Foundation

public struct ConnectionMetric: Codable, Equatable {
    public let id: String
    public let timestamp: Date
    public let connectionType: ConnectionType
    public let role: Role
    public let outcome: Outcome
    public let durationMs: Int
    public let iceStats: ICEStats?
    public let platform: String
    public let appVersion: String
    public let networkType: NetworkType
    public let hasTailscale: Bool
    public let hasIPv6: Bool

    public init(
        id: String,
        timestamp: Date,
        connectionType: ConnectionType,
        role: Role,
        outcome: Outcome,
        durationMs: Int,
        iceStats: ICEStats? = nil,
        platform: String,
        appVersion: String,
        networkType: NetworkType,
        hasTailscale: Bool,
        hasIPv6: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.connectionType = connectionType
        self.role = role
        self.outcome = outcome
        self.durationMs = durationMs
        self.iceStats = iceStats
        self.platform = platform
        self.appVersion = appVersion
        self.networkType = networkType
        self.hasTailscale = hasTailscale
        self.hasIPv6 = hasIPv6
    }

    public enum ConnectionType: String, Codable {
        case localBonjour, relayWorker, manualTailnet, manualIP
    }

    public enum Role: String, Codable { case initiator, joiner }

    public enum NetworkType: String, Codable {
        case wifi
        case cellular
        case wifiHotspot = "wifi_hotspot"
        case ethernet
        case unknown
    }

    /// WebRTC ICE candidate types. `srflx` = server-reflexive (STUN),
    /// `prflx` = peer-reflexive, `relay` = TURN.
    public enum CandidateType: String, Codable { case host, srflx, relay, prflx }

    public enum Outcome: Codable, Equatable {
        case success
        case failure(reason: String)
        case abandoned

        private enum CodingKeys: String, CodingKey { case type, reason }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .success:
                try c.encode("success", forKey: .type)
            case .failure(let reason):
                try c.encode("failure", forKey: .type)
                try c.encode(reason, forKey: .reason)
            case .abandoned:
                try c.encode("abandoned", forKey: .type)
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "success":
                self = .success
            case "abandoned":
                self = .abandoned
            default:
                self = .failure(reason: (try? c.decode(String.self, forKey: .reason)) ?? "unknown")
            }
        }
    }

    public struct ICEStats: Codable, Equatable {
        public let candidatesGathered: [CandidateType]
        public let candidatesUsed: CandidateType?
        public let srflxGatherOrder: Int?
        public let relayGatherOrder: Int?
        public let firstConnectedMs: Int?
        public let phase1ConnectedMs: Int?
        public let phase2ConnectedMs: Int?
        public let ipv6CandidateGathered: Bool
        public let ipv6Connected: Bool

        public init(
            candidatesGathered: [CandidateType],
            candidatesUsed: CandidateType?,
            srflxGatherOrder: Int?,
            relayGatherOrder: Int?,
            firstConnectedMs: Int?,
            phase1ConnectedMs: Int?,
            phase2ConnectedMs: Int?,
            ipv6CandidateGathered: Bool,
            ipv6Connected: Bool
        ) {
            self.candidatesGathered = candidatesGathered
            self.candidatesUsed = candidatesUsed
            self.srflxGatherOrder = srflxGatherOrder
            self.relayGatherOrder = relayGatherOrder
            self.firstConnectedMs = firstConnectedMs
            self.phase1ConnectedMs = phase1ConnectedMs
            self.phase2ConnectedMs = phase2ConnectedMs
            self.ipv6CandidateGathered = ipv6CandidateGathered
            self.ipv6Connected = ipv6Connected
        }
    }
}

extension ConnectionMetric {
    /// Canonical encoder — use this when posting metrics to the Worker
    /// so `timestamp` matches the Worker's ISO-8601 convention for other date fields.
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
