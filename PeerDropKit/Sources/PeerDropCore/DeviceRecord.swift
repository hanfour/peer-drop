import Foundation

public enum SortMode: String, CaseIterable {
    case name
    case lastConnected
    case connectionCount
}

public struct DeviceRecord: Identifiable, Codable, Hashable {
    public let id: String
    public var displayName: String
    public var sourceType: String
    public var host: String?
    public var port: UInt16?
    public var lastConnected: Date
    public var connectionCount: Int
    public var connectionHistory: [Date] = []
    public var certificateFingerprint: String?
    public var peerDeviceId: String?  // UUID of the peer device — used for invite routing

    public init(
        id: String,
        displayName: String,
        sourceType: String,
        host: String? = nil,
        port: UInt16? = nil,
        lastConnected: Date,
        connectionCount: Int = 0,
        connectionHistory: [Date] = [],
        certificateFingerprint: String? = nil,
        peerDeviceId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceType = sourceType
        self.host = host
        self.port = port
        self.lastConnected = lastConnected
        self.connectionCount = connectionCount
        self.connectionHistory = connectionHistory
        self.certificateFingerprint = certificateFingerprint
        self.peerDeviceId = peerDeviceId
    }

    public var relativeLastConnected: String {
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
