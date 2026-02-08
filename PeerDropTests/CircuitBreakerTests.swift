import XCTest
@testable import PeerDrop

@MainActor
final class CircuitBreakerTests: XCTestCase {

    // MARK: - Circuit Breaker Tests

    func testShouldAttemptConnectionInitially() {
        let manager = ConnectionManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Should allow connection to new peer
        XCTAssertTrue(manager.shouldAttemptConnection(to: peerID))
    }

    func testShouldAttemptConnectionAfterSingleFailure() {
        let manager = ConnectionManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Record one failure
        manager.recordConnectionFailure(for: peerID)

        // Should still allow connection (threshold is 3)
        XCTAssertTrue(manager.shouldAttemptConnection(to: peerID))
    }

    func testShouldAttemptConnectionAfterTwoFailures() {
        let manager = ConnectionManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Record two failures
        manager.recordConnectionFailure(for: peerID)
        manager.recordConnectionFailure(for: peerID)

        // Should still allow connection (threshold is 3)
        XCTAssertTrue(manager.shouldAttemptConnection(to: peerID))
    }

    func testCircuitBreakerOpensAfterThreeFailures() {
        let manager = ConnectionManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Record three failures (threshold)
        manager.recordConnectionFailure(for: peerID)
        manager.recordConnectionFailure(for: peerID)
        manager.recordConnectionFailure(for: peerID)

        // Circuit breaker should be open now
        XCTAssertFalse(manager.shouldAttemptConnection(to: peerID))
    }

    func testCircuitBreakerBlocksMoreThanThreshold() {
        let manager = ConnectionManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Record five failures
        for _ in 0..<5 {
            manager.recordConnectionFailure(for: peerID)
        }

        // Circuit breaker should still be open
        XCTAssertFalse(manager.shouldAttemptConnection(to: peerID))
    }

    func testConnectionSuccessResetsCircuitBreaker() {
        let manager = ConnectionManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Record failures to open circuit breaker
        manager.recordConnectionFailure(for: peerID)
        manager.recordConnectionFailure(for: peerID)
        manager.recordConnectionFailure(for: peerID)
        XCTAssertFalse(manager.shouldAttemptConnection(to: peerID))

        // Record success
        manager.recordConnectionSuccess(for: peerID)

        // Circuit breaker should be reset
        XCTAssertTrue(manager.shouldAttemptConnection(to: peerID))
    }

    func testCircuitBreakerIsolatesPerPeer() {
        let manager = ConnectionManager()
        let peerA = "peer-a-\(UUID().uuidString.prefix(8))"
        let peerB = "peer-b-\(UUID().uuidString.prefix(8))"

        // Open circuit breaker for peer A
        manager.recordConnectionFailure(for: peerA)
        manager.recordConnectionFailure(for: peerA)
        manager.recordConnectionFailure(for: peerA)

        // Peer A should be blocked
        XCTAssertFalse(manager.shouldAttemptConnection(to: peerA))

        // Peer B should still be allowed
        XCTAssertTrue(manager.shouldAttemptConnection(to: peerB))
    }

    func testRecordConnectionSuccessForUnknownPeer() {
        let manager = ConnectionManager()
        let peerID = "unknown-peer-\(UUID().uuidString.prefix(8))"

        // Should not crash when recording success for unknown peer
        manager.recordConnectionSuccess(for: peerID)

        // Should still allow connection
        XCTAssertTrue(manager.shouldAttemptConnection(to: peerID))
    }

    func testMultiplePeersIndependentCircuitBreakers() {
        let manager = ConnectionManager()
        var peers: [String] = []

        // Create 5 peers
        for i in 0..<5 {
            peers.append("peer-\(i)-\(UUID().uuidString.prefix(8))")
        }

        // Open circuit breaker for peers 0 and 2
        for _ in 0..<3 {
            manager.recordConnectionFailure(for: peers[0])
            manager.recordConnectionFailure(for: peers[2])
        }

        // Peers 0 and 2 should be blocked
        XCTAssertFalse(manager.shouldAttemptConnection(to: peers[0]))
        XCTAssertFalse(manager.shouldAttemptConnection(to: peers[2]))

        // Peers 1, 3, 4 should be allowed
        XCTAssertTrue(manager.shouldAttemptConnection(to: peers[1]))
        XCTAssertTrue(manager.shouldAttemptConnection(to: peers[3]))
        XCTAssertTrue(manager.shouldAttemptConnection(to: peers[4]))
    }

    func testPartialFailureDoesNotOpenCircuitBreaker() {
        let manager = ConnectionManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Record 2 failures
        manager.recordConnectionFailure(for: peerID)
        manager.recordConnectionFailure(for: peerID)

        // Record success (should reset counter)
        manager.recordConnectionSuccess(for: peerID)

        // Record 2 more failures
        manager.recordConnectionFailure(for: peerID)
        manager.recordConnectionFailure(for: peerID)

        // Should still be allowed (count was reset by success)
        XCTAssertTrue(manager.shouldAttemptConnection(to: peerID))
    }
}
