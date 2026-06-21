import Foundation

/// Global (per-process) brute-force limiter for the login endpoint.
///
/// Single-tenant tool — the connecting IP is always the Cloudflare tunnel (127.0.0.1),
/// so per-IP keying is meaningless. Instead, a GLOBAL failure counter is used.
///
/// Policy: ≥ `maxFailures` distinct failures within `window` seconds → 429 Too Many Requests.
/// A correct login clears the failure history immediately.
///
/// The type is an actor for thread-safety and accepts an injectable clock closure
/// (`clock: @escaping () -> Date`) so unit tests can simulate the sliding window without
/// real sleeps.
public actor LoginRateLimiter {
    /// Maximum number of allowed failures within `window` seconds before 429 fires.
    public let maxFailures: Int
    /// Duration of the sliding window (seconds).
    public let window: TimeInterval
    /// Injectable clock — defaults to `Date()` for production.
    private let clock: () -> Date
    /// Timestamps of recent failures (oldest first).
    private var failures: [Date] = []

    public init(
        maxFailures: Int = 5,
        window: TimeInterval = 60,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.maxFailures = maxFailures
        self.window = window
        self.clock = clock
    }

    /// Returns `true` if there have been ≥ `maxFailures` failures within the last `window` seconds.
    /// Call this BEFORE verifying the password; if limited, respond 429 immediately.
    public func isLimited() -> Bool {
        let now = clock()
        let cutoff = now.addingTimeInterval(-window)
        failures = failures.filter { $0 > cutoff }
        return failures.count >= maxFailures
    }

    /// Record a failed login attempt. Call after a wrong-password rejection.
    public func recordFailure() {
        failures.append(clock())
    }

    /// Clear all recorded failures. Call on a correct login.
    public func recordSuccess() {
        failures.removeAll()
    }
}
