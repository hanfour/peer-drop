import Foundation

struct TransferMetadata: Codable {
    let fileName: String
    let fileSize: Int64
    let mimeType: String?
    let sha256Hash: String
    let fileIndex: Int?
    let totalFiles: Int?
    /// Indicates the transferred file is a zipped directory that should be unzipped on receive.
    let isDirectory: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// The original directory name (strips .zip suffix if this is a directory transfer).
    var displayName: String {
        if isDirectory, fileName.hasSuffix(".zip") {
            return String(fileName.dropLast(4))
        }
        return fileName
    }

    init(fileName: String, fileSize: Int64, mimeType: String?, sha256Hash: String, fileIndex: Int? = nil, totalFiles: Int? = nil, isDirectory: Bool = false) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.sha256Hash = sha256Hash
        self.fileIndex = fileIndex
        self.totalFiles = totalFiles
        self.isDirectory = isDirectory
    }
}

/// Metadata sent at the start of a multi-file batch.
struct BatchMetadata: Codable {
    let totalFiles: Int
    let batchID: String
}
