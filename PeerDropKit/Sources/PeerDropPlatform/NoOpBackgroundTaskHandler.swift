import Foundation

/// No-op `BackgroundTaskHandling` adapter for platforms where the OS
/// doesn't suspend foreground apps via the iOS background-task API
/// (currently macOS). All operations succeed trivially; remaining time
/// is `.infinity` so callers that compare against thresholds short-
/// circuit to "still have time."
@MainActor
public final class NoOpBackgroundTaskHandler: BackgroundTaskHandling {
    public init() {}

    public func begin(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
        BackgroundTaskToken(rawValue: 1) // any non-invalid value
    }

    public func end(_ token: BackgroundTaskToken) {
        // No-op.
    }

    public var backgroundTimeRemaining: TimeInterval { .infinity }
}
