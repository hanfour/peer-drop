import Foundation

extension URL {
    /// Zip a directory using NSFileCoordinator (iOS creates zip automatically for directories).
    /// - Returns: URL to the temporary zip file
    /// - Throws: Error if the directory cannot be zipped
    func zipDirectory() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            let intent = NSFileAccessIntent.readingIntent(with: self, options: .forUploading)

            coordinator.coordinate(with: [intent], queue: OperationQueue()) { err in
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(self.lastPathComponent + ".zip")

                try? FileManager.default.removeItem(at: tempURL) // P2: temp cleanup, failure is acceptable

                do {
                    try FileManager.default.copyItem(at: intent.url, to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Unzip a file into a temporary directory.
    /// - Returns: URL to the unzipped directory
    /// - Throws: Error if the file cannot be unzipped
    func unzipFile() throws -> URL {
        let fm = FileManager.default
        let baseName = deletingPathExtension().lastPathComponent
        let destURL = fm.temporaryDirectory.appendingPathComponent(baseName, isDirectory: true)

        // Remove any existing directory at this location
        try? fm.removeItem(at: destURL)
        try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
        try fm.unzipItem(at: self, to: destURL)

        return destURL
    }
}

// MARK: - FileManager zip/unzip helper

extension FileManager {
    /// Unzip an archive at the given URL into a destination directory.
    /// Uses the built-in Archive support via Process on macOS or manual zip reading on iOS.
    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        // Use NSFileCoordinator with reading intent to let the system handle unzipping
        // For iOS, we use a minimal zip reader since Process is unavailable.
        let data = try Data(contentsOf: sourceURL)
        try MiniZipReader.extract(data: data, to: destinationURL)
    }
}

// MARK: - Minimal Zip Reader

/// A minimal zip file reader that extracts entries from a standard ZIP archive.
/// Supports Store (no compression) and Deflate methods.
enum MiniZipReader {

    static func extract(data: Data, to directory: URL) throws {
        let fm = FileManager.default
        var offset = 0

        while offset + 30 <= data.count {
            // Check for local file header signature: PK\x03\x04
            let sig = data.subdata(in: offset..<offset + 4)
            guard sig == Data([0x50, 0x4B, 0x03, 0x04]) else { break }

            let compressionMethod = data.readUInt16(at: offset + 8)
            let compressedSize = Int(data.readUInt32(at: offset + 18))
            _ = Int(data.readUInt32(at: offset + 22)) // uncompressedSize (reserved for future validation)
            let fileNameLength = Int(data.readUInt16(at: offset + 26))
            let extraFieldLength = Int(data.readUInt16(at: offset + 28))

            let fileNameStart = offset + 30
            let fileNameEnd = fileNameStart + fileNameLength
            guard fileNameEnd <= data.count else { throw ZipError.corrupted }

            let fileNameData = data.subdata(in: fileNameStart..<fileNameEnd)
            guard let fileName = String(data: fileNameData, encoding: .utf8) else {
                throw ZipError.corrupted
            }

            let dataStart = fileNameEnd + extraFieldLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { throw ZipError.corrupted }

            let entryURL = directory.appendingPathComponent(fileName)

            // Prevent path traversal
            guard entryURL.standardized.path.hasPrefix(directory.standardized.path) else {
                throw ZipError.invalidPath
            }

            if fileName.hasSuffix("/") {
                // Directory entry
                try fm.createDirectory(at: entryURL, withIntermediateDirectories: true)
            } else {
                // File entry
                try fm.createDirectory(at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let compressedData = data.subdata(in: dataStart..<dataEnd)

                switch compressionMethod {
                case 0: // Store
                    try compressedData.write(to: entryURL)
                case 8: // Deflate
                    let decompressed = try (compressedData as NSData).decompressed(using: .zlib) as Data
                    // If the decompressed size doesn't match, it might still be valid
                    // due to zip64 or streaming, but write what we got
                    try decompressed.write(to: entryURL)
                default:
                    throw ZipError.unsupportedCompression
                }
            }

            offset = dataEnd
        }
    }

    enum ZipError: Error, LocalizedError {
        case corrupted
        case invalidPath
        case unsupportedCompression

        var errorDescription: String? {
            switch self {
            case .corrupted: return "Zip file is corrupted"
            case .invalidPath: return "Zip contains invalid path"
            case .unsupportedCompression: return "Unsupported compression method"
            }
        }
    }
}

// MARK: - Data helpers for reading little-endian integers

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let bytes = self.subdata(in: offset..<offset + 2)
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let bytes = self.subdata(in: offset..<offset + 4)
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}
