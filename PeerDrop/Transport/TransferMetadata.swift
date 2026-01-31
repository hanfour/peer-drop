import Foundation

struct TransferMetadata: Codable {
    let fileName: String
    let fileSize: Int64
    let mimeType: String?
    let sha256Hash: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
