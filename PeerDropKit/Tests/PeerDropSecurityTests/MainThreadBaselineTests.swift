// Phase-0 baseline for the MainActor-offload refactor. Not assertions about
// speed (machine dependent) — it prints how much time each path spends on the
// main thread so before/after runs can be compared. Run:
//   swift test --filter MainThreadBaselineTests
import XCTest
import PeerDropPlatform
@testable import PeerDropSecurity

final class MainThreadBaselineTests: XCTestCase {
    override func setUp() { PerfSignpost.reset() }

    private func makeFile(megabytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString).bin")
        try Data(repeating: 0xAB, count: megabytes * 1_048_576).write(to: url)
        return url
    }

    @MainActor
    func testFileHashAndProofOfWorkMainThreadShare() async throws {
        let url = try makeFile(megabytes: 64)
        defer { try? FileManager.default.removeItem(at: url) }

        // Legacy sync call from the main actor: the whole hash lands on main.
        let syncHash = try HashVerifier.sha256(fileAt: url)
        // Current code path: same digest, computed on a background task.
        let asyncHash = try await HashVerifier.sha256Async(fileAt: url)
        XCTAssertEqual(syncHash, asyncHash)

        _ = await ProofOfWork.generate(challenge: "baseline")

        let snap = PerfSignpost.snapshot()
        print("[perf-baseline]\n" + PerfSignpost.report())

        // fileHash ran twice: once on main (legacy sync), once off (async).
        XCTAssertEqual(snap[.fileHash]?.count, 2)
        XCTAssertEqual(snap[.fileHash]?.mainThreadCount, 1)
        // PoW via the async overload must stay off main (phase 1 acceptance).
        XCTAssertEqual(snap[.proofOfWork]?.mainThreadCount, 0)
    }
}
