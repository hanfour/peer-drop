import XCTest
@testable import PeerDrop

final class ProofOfWorkTests: XCTestCase {

    func testGenerateProof() {
        let challenge = "test-challenge-\(Date().timeIntervalSince1970)"
        let proof = ProofOfWork.generate(challenge: challenge, difficulty: 16)
        XCTAssertNotNil(proof)
        XCTAssertTrue(ProofOfWork.verify(challenge: challenge, proof: proof!, difficulty: 16))
    }

    func testVerifyRejectsWrongProof() {
        let challenge = "test-challenge"
        XCTAssertFalse(ProofOfWork.verify(challenge: challenge, proof: 12345, difficulty: 16))
    }

    func testVerifyRejectsWrongChallenge() {
        let challenge = "test-challenge-\(Date().timeIntervalSince1970)"
        let proof = ProofOfWork.generate(challenge: challenge, difficulty: 16)!
        XCTAssertFalse(ProofOfWork.verify(challenge: "wrong-challenge", proof: proof, difficulty: 16))
    }

    func testDifficulty16CompletesQuickly() {
        let start = Date()
        let challenge = "perf-test-\(UUID().uuidString)"
        let proof = ProofOfWork.generate(challenge: challenge, difficulty: 16)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(proof)
        XCTAssertLessThan(elapsed, 2.0)
    }
}
