import Foundation

public struct TransferRecord: Identifiable, Codable {
    public let id: String
    public let fileName: String
    public let fileSize: Int64
    public let direction: Direction
    public let timestamp: Date
    public let success: Bool

    public init(id: String = UUID().uuidString, fileName: String, fileSize: Int64, direction: Direction, timestamp: Date, success: Bool) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.direction = direction
        self.timestamp = timestamp
        self.success = success
    }

    public enum Direction: String, Codable {
        case sent, received
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
