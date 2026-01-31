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
