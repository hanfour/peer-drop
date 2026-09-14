// PeerDropKit/Tests/PeerDropSecurityTests/HashVerifierAsyncTests.swift
//
// sha256Async streams + hashes on a background task (so the whole-file hash
// doesn't freeze the main actor before a transfer's first byte), and must
// produce exactly the same digest as the synchronous overload.
import XCTest
@testable import PeerDropSecurity

final class HashVerifierAsyncTests: XCTestCase {

    func test_sha256Async_matchesSync() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hvtest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // Larger than the default 64 KiB chunk so the streaming loop runs.
        try Data(repeating: 0xAB, count: 200_000).write(to: url)

        let syncHash = try HashVerifier.sha256(fileAt: url)
        let asyncHash = try await HashVerifier.sha256Async(fileAt: url)

        XCTAssertEqual(asyncHash, syncHash)
        XCTAssertFalse(asyncHash.isEmpty)
    }
}
