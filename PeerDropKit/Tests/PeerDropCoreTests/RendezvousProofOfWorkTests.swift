import XCTest
@testable import PeerDropCore

private struct PowVectorFile: Decodable {
    struct Vector: Decodable {
        let name: String
        let token: String
        let h: Int
        let n: String
        let nowSeconds: Int
        let valid: Bool
        let bitsReported: Int
    }
    let difficultyBits: Int
    let vectors: [Vector]
}

final class RendezvousProofOfWorkTests: XCTestCase {

    /// Shared with the Worker: cloudflare-worker/test-vectors/rendezvous-pow.json.
    private func loadVectors(file: StaticString = #filePath) throws -> PowVectorFile {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // PeerDropCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PeerDropKit
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("cloudflare-worker/test-vectors/rendezvous-pow.json")
        guard let data = FileManager.default.contents(atPath: url.path) else {
            XCTFail("Shared PoW vectors missing at \(url.path) — the Swift and Worker PoW rules can no longer be checked against each other")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(PowVectorFile.self, from: data)
    }

    func testAllSharedWorkerVectors() throws {
        let file = try loadVectors()
        XCTAssertEqual(file.difficultyBits, RendezvousProofOfWork.defaultDifficultyBits)
        XCTAssertEqual(file.vectors.count, 11, "vector file changed; review the rule on both sides")
        for v in file.vectors {
            let token = try XCTUnwrap(RendezvousToken.decodeCanonical(v.token), v.name)
            let now = Date(timeIntervalSince1970: TimeInterval(v.nowSeconds))
            XCTAssertEqual(RendezvousProofOfWork.leadingZeroBits(tokenBytes: token, hour: v.h, nonce: v.n),
                           v.bitsReported, v.name)
            XCTAssertEqual(RendezvousProofOfWork.verifyClaim(tokenBytes: token, hour: v.h, nonce: v.n, now: now),
                           v.valid, v.name)
        }
    }

    func testBoundaryVectorsMatchClientHourRule() throws {
        let file = try loadVectors()
        for v in file.vectors where v.name.hasPrefix("client rule") {
            let now = Date(timeIntervalSince1970: TimeInterval(v.nowSeconds))
            XCTAssertEqual(RendezvousProofOfWork.currentHour(now: now), v.h, v.name)
        }
    }

    func testCurrentHourRule() {
        func h(_ s: Double) -> Int { RendezvousProofOfWork.currentHour(now: Date(timeIntervalSince1970: s)) }
        let b = 500_001.0 * 3600  // an hour boundary
        XCTAssertEqual(h(b), 500_000)
        XCTAssertEqual(h(b + 599), 500_000)
        XCTAssertEqual(h(b + 599.999), 500_000)
        XCTAssertEqual(h(b + 600), 500_001)
        XCTAssertEqual(h(b - 1), 500_000)
        XCTAssertEqual(h(b + 3600 + 599), 500_001)
        // The client hour is always inside the server window {cur, cur-1}.
        for offset in stride(from: 0.0, to: 7200, by: 37) {
            let now = Date(timeIntervalSince1970: b + offset)
            XCTAssertTrue(RendezvousProofOfWork.serverAcceptsHour(RendezvousProofOfWork.currentHour(now: now), now: now))
        }
        // Clamped at the epoch instead of going negative.
        XCTAssertEqual(h(0), 0)
    }

    func testServerHourWindowMirror() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // cur = 500000
        XCTAssertTrue(RendezvousProofOfWork.serverAcceptsHour(500_000, now: now))
        XCTAssertTrue(RendezvousProofOfWork.serverAcceptsHour(499_999, now: now))
        XCTAssertFalse(RendezvousProofOfWork.serverAcceptsHour(499_998, now: now))
        XCTAssertFalse(RendezvousProofOfWork.serverAcceptsHour(500_001, now: now))
    }

    func testSolveThenVerify() throws {
        let token = Data((0..<32).map { UInt8($0) })
        let nonce = try RendezvousProofOfWork.solve(tokenBytes: token, hour: 500_000)
        XCTAssertTrue(nonce.allSatisfy { $0.isASCII })
        XCTAssertLessThanOrEqual(nonce.utf16.count, RendezvousProofOfWork.maxNonceLength)
        XCTAssertTrue(RendezvousProofOfWork.verify(tokenBytes: token, hour: 500_000, nonce: nonce))
        XCTAssertGreaterThanOrEqual(RendezvousProofOfWork.leadingZeroBits(tokenBytes: token, hour: 500_000, nonce: nonce), 16)
        // Bound to hour and token.
        XCTAssertFalse(RendezvousProofOfWork.verify(tokenBytes: token, hour: 500_001, nonce: nonce))
        XCTAssertFalse(RendezvousProofOfWork.verify(tokenBytes: Data(repeating: 9, count: 32), hour: 500_000, nonce: nonce))
    }

    func testSolveIsDeterministicWithInjectedGenerator() throws {
        let token = Data(repeating: 1, count: 32)
        let n1 = try RendezvousProofOfWork.solve(tokenBytes: token, hour: 500_000, difficultyBits: 8,
                                                 nonceGenerator: { "x\($0)" })
        let n2 = try RendezvousProofOfWork.solve(tokenBytes: token, hour: 500_000, difficultyBits: 8,
                                                 nonceGenerator: { "x\($0)" })
        XCTAssertEqual(n1, n2)
        XCTAssertTrue(n1.hasPrefix("x"))
    }

    func testSolveGivesUpAfterMaxAttempts() {
        XCTAssertThrowsError(try RendezvousProofOfWork.solve(
            tokenBytes: Data(repeating: 1, count: 32), hour: 1, difficultyBits: 40, maxAttempts: 100))
    }

    func testSolveRejectsBadGeneratorAndInputs() {
        XCTAssertThrowsError(try RendezvousProofOfWork.solve(
            tokenBytes: Data(repeating: 1, count: 32), hour: 1, difficultyBits: 1, maxAttempts: 10,
            nonceGenerator: { _ in String(repeating: "a", count: 65) }))
        XCTAssertThrowsError(try RendezvousProofOfWork.solve(
            tokenBytes: Data(repeating: 1, count: 31), hour: 1))
        XCTAssertThrowsError(try RendezvousProofOfWork.solve(
            tokenBytes: Data(repeating: 1, count: 32), hour: -1))
    }

    func testVerifyShapeRules() {
        let token = Data(repeating: 1, count: 32)
        XCTAssertFalse(RendezvousProofOfWork.verify(tokenBytes: token, hour: 500_000, nonce: ""))
        XCTAssertFalse(RendezvousProofOfWork.verify(tokenBytes: token, hour: 500_000, nonce: String(repeating: "a", count: 65)))
        XCTAssertFalse(RendezvousProofOfWork.verify(tokenBytes: Data(count: 31), hour: 500_000, nonce: "asfh"))
        XCTAssertFalse(RendezvousProofOfWork.verify(tokenBytes: token, hour: -1, nonce: "asfh"))
        XCTAssertTrue(RendezvousProofOfWork.verify(tokenBytes: token, hour: 500_000, nonce: "asfh"))
        // Difficulty 0 accepts any well-formed nonce.
        XCTAssertTrue(RendezvousProofOfWork.verify(tokenBytes: token, hour: 500_000, nonce: "0", difficultyBits: 0))
    }
}
