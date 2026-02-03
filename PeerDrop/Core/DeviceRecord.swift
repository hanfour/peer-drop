import Foundation

enum SortMode: String, CaseIterable {
    case name
    case lastConnected
    case connectionCount
}

struct DeviceRecord: Identifiable, Codable, Hashable {
    let id: String
    var displayName: String
    var sourceType: String
    var host: String?
    var port: UInt16?
    var lastConnected: Date
    var connectionCount: Int
    var connectionHistory: [Date] = []

    var relativeLastConnected: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastConnected, relativeTo: Date())
    }

    mutating func merge(with other: DeviceRecord) {
        if other.lastConnected > self.lastConnected {
            self.host = other.host ?? self.host
            self.port = other.port ?? self.port
            self.lastConnected = other.lastConnected
        }
        self.connectionCount += other.connectionCount
        self.connectionHistory = (self.connectionHistory + other.connectionHistory).sorted()
    }
}
