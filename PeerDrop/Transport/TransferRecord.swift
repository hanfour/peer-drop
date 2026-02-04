import Foundation

struct TransferRecord: Identifiable, Codable {
    let id: String
    let fileName: String
    let fileSize: Int64
    let direction: Direction
    let timestamp: Date
    let success: Bool

    init(id: String = UUID().uuidString, fileName: String, fileSize: Int64, direction: Direction, timestamp: Date, success: Bool) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.direction = direction
        self.timestamp = timestamp
        self.success = success
    }

    enum Direction: String, Codable {
        case sent, received
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
