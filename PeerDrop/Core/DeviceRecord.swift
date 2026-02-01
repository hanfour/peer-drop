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

    var relativeLastConnected: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastConnected, relativeTo: Date())
    }
}
