// PeerDropKit/Tests/PeerDropSecurityTests/ProofOfWorkAsyncTests.swift
//
// The async ProofOfWork.generate runs the CPU-bound search off the calling
// actor (so it doesn't freeze the main thread), but must produce the exact
// same proof as the synchronous overload.
import XCTest
@testable import PeerDropSecurity

final class ProofOfWorkAsyncTests: XCTestCase {

    func test_asyncGenerate_producesVerifiableProof() async throws {
        let challenge = "phase1-offmain"
        let maybeProof = await ProofOfWork.generate(challenge: challenge, difficulty: 8)
        let proof = try XCTUnwrap(maybeProof)
        XCTAssertTrue(ProofOfWork.verify(challenge: challenge, proof: proof, difficulty: 8))
    }

    func test_asyncGenerate_matchesKnownSyncProof() async {
        // The search is deterministic (starts at nonce 0, returns the first hit),
        // so the async wrapper must return the same nonce the sync search finds.
        let challenge = "determinism"
        let syncProof = syncSearch(challenge: challenge, difficulty: 8)
        let asyncProof = await ProofOfWork.generate(challenge: challenge, difficulty: 8)
        XCTAssertEqual(asyncProof, syncProof)
    }

    /// Wrapper in a non-async context so overload resolution picks the sync
    /// `generate` (in an async context the async overload wins and needs await).
    private func syncSearch(challenge: String, difficulty: Int) -> UInt64? {
        ProofOfWork.generate(challenge: challenge, difficulty: difficulty)
    }
}
