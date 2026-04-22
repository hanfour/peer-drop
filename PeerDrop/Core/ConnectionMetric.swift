import Foundation

struct ConnectionMetric: Codable, Equatable {
    let id: String
    let timestamp: Date
    let connectionType: ConnectionType
    let role: Role
    let outcome: Outcome
    let durationMs: Int
    let iceStats: ICEStats?
    let platform: String
    let appVersion: String
    let networkType: NetworkType
    let hasTailscale: Bool
    let hasIPv6: Bool

    enum ConnectionType: String, Codable {
        case localBonjour, relayWorker, manualTailnet, manualIP
    }

    enum Role: String, Codable { case initiator, joiner }

    enum NetworkType: String, Codable {
        case wifi, cellular, wifi_hotspot, ethernet, unknown
    }

    enum CandidateType: String, Codable { case host, srflx, relay, prflx }

    enum Outcome: Codable, Equatable {
        case success
        case failure(reason: String)
        case abandoned

        private enum CodingKeys: String, CodingKey { case type, reason }

        func encode(to encoder: Encoder) throws {
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

        init(from decoder: Decoder) throws {
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

    struct ICEStats: Codable, Equatable {
        let candidatesGathered: [CandidateType]
        let candidatesUsed: CandidateType?
        let srflxGatherOrder: Int?
        let relayGatherOrder: Int?
        let firstConnectedMs: Int?
        let phase1ConnectedMs: Int?
        let phase2ConnectedMs: Int?
        let ipv6CandidateGathered: Bool
        let ipv6Connected: Bool
    }
}
