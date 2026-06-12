import Foundation

/// Deterministic teardown rule for the heartbeat keepalive (audit round 15).
///
/// Before this, a dead transport produced "Heartbeat ping failed" every
/// 10s indefinitely (observed live 2026-06-12: 30+ consecutive failures
/// over 5 minutes) while the UI kept showing a zombie "connected" peer.
/// N consecutive failures (default 3 ≈ 30s of silence) now request a
/// disconnect; any successful ping resets the counter.
struct HeartbeatFailurePolicy {
    let maxConsecutiveFailures: Int
    private(set) var consecutiveFailures = 0

    init(maxConsecutiveFailures: Int = 3) {
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    /// Returns `true` when the failure streak reached the threshold and
    /// the caller should tear the connection down.
    mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures >= maxConsecutiveFailures
    }
}
