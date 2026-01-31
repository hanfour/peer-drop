import Foundation

struct TransferRecord: Identifiable {
    let id = UUID()
    let fileName: String
    let fileSize: Int64
    let direction: Direction
    let timestamp: Date
    let success: Bool

    enum Direction: String {
        case sent, received
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
