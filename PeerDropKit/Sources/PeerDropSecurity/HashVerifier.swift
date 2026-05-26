import Foundation
import CryptoKit

/// Incremental SHA-256 hash computation and verification.
public final class HashVerifier {
    private var hasher = SHA256()
    public private(set) var isFinalized = false

    public init() {}

    /// Feed data chunks incrementally.
    public func update(with data: Data) {
        precondition(!isFinalized)
        hasher.update(data: data)
    }

    /// Finalize and return the hex-encoded digest.
    public func finalize() -> String {
        isFinalized = true
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verify that the computed hash matches the expected value.
    public func verify(expected: String) -> Bool {
        let computed = isFinalized ? computedHash : finalize()
        return computed == expected.lowercased()
    }

    private var computedHash: String {
        // Re-finalize returns same result since SHA256 is value type
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute SHA-256 of an entire Data blob at once.
    public static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute SHA-256 of a file at a URL by streaming chunks.
    public static func sha256(fileAt url: URL, chunkSize: Int = 65536) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
