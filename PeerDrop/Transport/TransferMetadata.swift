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

    /// Byte offset to resume from (nil = start from beginning).
    let resumeOffset: Int64?

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

    init(fileName: String, fileSize: Int64, mimeType: String?, sha256Hash: String, fileIndex: Int? = nil, totalFiles: Int? = nil, isDirectory: Bool = false, resumeOffset: Int64? = nil) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.sha256Hash = sha256Hash
        self.fileIndex = fileIndex
        self.totalFiles = totalFiles
        self.isDirectory = isDirectory
        self.resumeOffset = resumeOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decode(String.self, forKey: .fileName)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        sha256Hash = try container.decode(String.self, forKey: .sha256Hash)
        fileIndex = try container.decodeIfPresent(Int.self, forKey: .fileIndex)
        totalFiles = try container.decodeIfPresent(Int.self, forKey: .totalFiles)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        resumeOffset = try container.decodeIfPresent(Int64.self, forKey: .resumeOffset)
    }
}

/// Metadata sent at the start of a multi-file batch.
struct BatchMetadata: Codable {
    let totalFiles: Int
    let batchID: String
}
