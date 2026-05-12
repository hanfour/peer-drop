import XCTest
@testable import PeerDrop

/// Tests for the v5.0.3 chunk-size and total-bytes caps in
/// `FileTransferSession.handleFileChunk`. A malicious peer can declare a
/// small fileSize then stream forever, or send a single oversized frame to
/// exhaust memory before the file handle write hits backing store. The caps
/// stop both attacks deterministically and clean up partial state.
@MainActor
final class FileTransferChunkLimitsTests: XCTestCase {

    /// Construct a session that's already accepted an offer for a file of
    /// `declaredSize` bytes and primed its receive state. Caller can then
    /// call `handleFileChunk` directly to simulate incoming chunks.
    private func makeSessionWithAcceptedOffer(declaredSize: Int64) -> FileTransferSession {
        let session = FileTransferSession(peerID: "test-peer")
        let metadata = TransferMetadata(
            fileName: "test.bin",
            fileSize: declaredSize,
            mimeType: "application/octet-stream",
            sha256Hash: "deadbeef",
            isDirectory: false)
        let payload = try! JSONEncoder().encode(metadata)
        let offer = PeerMessage(type: .fileOffer, payload: payload, senderID: "remote")
        session.handleFileOffer(offer)
        return session
    }

    // MARK: - Per-chunk size cap

    func test_oversizedSingleChunk_isRejected() {
        let session = makeSessionWithAcceptedOffer(declaredSize: 10_000_000)
        // 2 MB chunk exceeds the 1 MB per-chunk cap.
        let oversized = Data(repeating: 0xAB, count: 2 * 1_048_576)
        let chunk = PeerMessage(type: .fileChunk, payload: oversized, senderID: "remote")

        session.handleFileChunk(chunk)

        XCTAssertEqual(session.lastError, "Chunk size violated max-chunk-bytes limit")
        XCTAssertFalse(session.isTransferring, "session aborted")
        XCTAssertEqual(session.progress, 0)
    }

    func test_chunkAtMaxBoundary_isAccepted() {
        let session = makeSessionWithAcceptedOffer(declaredSize: 10_000_000)
        // Exactly maxChunkBytes — must NOT be rejected (cap is exclusive of equality).
        let atLimit = Data(repeating: 0xCD, count: FileTransferSession.maxChunkBytes)
        let chunk = PeerMessage(type: .fileChunk, payload: atLimit, senderID: "remote")

        session.handleFileChunk(chunk)

        // No error means the chunk passed both caps. We don't check
        // isTransferring because handleFileOffer sets it inside an async
        // Task that may not have run yet — this is a unit test for the cap
        // logic, not the broader session lifecycle.
        XCTAssertNil(session.lastError)
    }

    // MARK: - Total-bytes cap (vs declared file size)

    func test_chunkExceedingDeclaredFileSize_isRejected() {
        // Attacker declares 100 KB but sends 1 MB.
        let session = makeSessionWithAcceptedOffer(declaredSize: 100_000)
        let oversized = Data(repeating: 0xEE, count: 200_000)
        let chunk = PeerMessage(type: .fileChunk, payload: oversized, senderID: "remote")

        session.handleFileChunk(chunk)

        XCTAssertEqual(session.lastError, "Received bytes exceeded declared file size")
        XCTAssertFalse(session.isTransferring)
        XCTAssertEqual(session.progress, 0)
    }

    func test_cumulativeChunksExceedingDeclaredFileSize_isRejected() {
        // Each chunk under the per-chunk cap and under the declared total,
        // but cumulatively they'd overshoot — third chunk should be rejected.
        let session = makeSessionWithAcceptedOffer(declaredSize: 150_000)
        let chunk = PeerMessage(type: .fileChunk, payload: Data(repeating: 0xAA, count: 80_000), senderID: "remote")

        session.handleFileChunk(chunk)  // total 80k, ok
        XCTAssertNil(session.lastError)

        session.handleFileChunk(chunk)  // total 160k, would exceed 150k declared
        XCTAssertEqual(session.lastError, "Received bytes exceeded declared file size")
        XCTAssertFalse(session.isTransferring)
    }

    func test_abortClearsPartialState() {
        let session = makeSessionWithAcceptedOffer(declaredSize: 100_000)
        let huge = Data(repeating: 0xFF, count: 200_000)
        let chunk = PeerMessage(type: .fileChunk, payload: huge, senderID: "remote")
        session.handleFileChunk(chunk)

        // After abort: a follow-up chunk on the same session should be
        // ignored (receiveMetadata is nil, the early-return in
        // handleFileChunk skips processing).
        let followUp = PeerMessage(type: .fileChunk, payload: Data(count: 100), senderID: "remote")
        session.handleFileChunk(followUp)
        XCTAssertEqual(session.lastError, "Received bytes exceeded declared file size",
                       "error unchanged — follow-up chunk silently dropped")
    }
}
