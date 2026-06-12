import XCTest
@testable import PeerDropCore

/// Audit round 15: heartbeat pings failed every 10s for minutes (observed
/// live 2026-06-12, "Heartbeat ping failed" × 30+) without ever tearing
/// down the dead connection — the UI kept showing a zombie "connected"
/// peer. The policy below gives the heartbeat loop a deterministic
/// teardown rule: N consecutive failures (default 3 ≈ 30s) → disconnect.
final class HeartbeatFailurePolicyTests: XCTestCase {

    func testTearsDownAfterThreeConsecutiveFailures() {
        var policy = HeartbeatFailurePolicy()
        XCTAssertFalse(policy.recordFailure())
        XCTAssertFalse(policy.recordFailure())
        XCTAssertTrue(policy.recordFailure(), "3rd consecutive failure must request teardown")
    }

    func testSuccessResetsTheCounter() {
        var policy = HeartbeatFailurePolicy()
        XCTAssertFalse(policy.recordFailure())
        XCTAssertFalse(policy.recordFailure())
        policy.recordSuccess()
        XCTAssertFalse(policy.recordFailure(), "counter must reset after a successful ping")
        XCTAssertFalse(policy.recordFailure())
        XCTAssertTrue(policy.recordFailure())
    }

    func testCustomThreshold() {
        var policy = HeartbeatFailurePolicy(maxConsecutiveFailures: 1)
        XCTAssertTrue(policy.recordFailure())
    }
}
