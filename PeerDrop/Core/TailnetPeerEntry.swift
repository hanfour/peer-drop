import Foundation

struct TailnetPeerEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var ip: String
    var port: UInt16
    var lastReachable: Date?
    var lastChecked: Date?
    var consecutiveFailures: Int
    var addedAt: Date

    init(id: UUID = UUID(), displayName: String, ip: String, port: UInt16 = 9876,
         lastReachable: Date? = nil, lastChecked: Date? = nil,
         consecutiveFailures: Int = 0, addedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.ip = ip
        self.port = port
        self.lastReachable = lastReachable
        self.lastChecked = lastChecked
        self.consecutiveFailures = consecutiveFailures
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        ip = try c.decode(String.self, forKey: .ip)
        port = try c.decode(UInt16.self, forKey: .port)
        lastReachable = try c.decodeIfPresent(Date.self, forKey: .lastReachable)
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        addedAt = try c.decode(Date.self, forKey: .addedAt)
    }
}
