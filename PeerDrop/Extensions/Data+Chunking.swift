import Foundation

extension Data {
    /// Split data into chunks of the given size.
    func chunks(ofSize size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { offset in
            let end = Swift.min(offset + size, count)
            return self[offset..<end]
        }
    }

    static let defaultChunkSize = 64 * 1024 // 64KB
}

/// Lazy chunk iterator that reads from a FileHandle without loading the entire file into memory.
struct FileChunkIterator: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private let chunkSize: Int
    private let totalSize: Int64
    private var bytesRead: Int64 = 0

    init(handle: FileHandle, chunkSize: Int = Data.defaultChunkSize, totalSize: Int64) {
        self.handle = handle
        self.chunkSize = chunkSize
        self.totalSize = totalSize
    }

    mutating func next() -> Data? {
        guard bytesRead < totalSize else { return nil }
        let data = handle.readData(ofLength: chunkSize)
        guard !data.isEmpty else { return nil }
        bytesRead += Int64(data.count)
        return data
    }
}
