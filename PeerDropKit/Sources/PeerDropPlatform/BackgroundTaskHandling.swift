import Foundation

/// Opaque background-task handle. iOS wraps `UIBackgroundTaskIdentifier`;
/// other platforms map to a sentinel `.invalid`.
public struct BackgroundTaskToken: Hashable {
    /// Sentinel for an invalid / never-started task.
    public static let invalid = BackgroundTaskToken(rawValue: 0)

    /// Platform-specific raw value (iOS: UIBackgroundTaskIdentifier.rawValue).
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Cross-platform background-task lifecycle. iOS implementation wraps
/// `UIApplication.beginBackgroundTask`. macOS implementation is a no-op
/// (the OS doesn't suspend foreground apps the same way; long-running
/// work runs without the special API).
@MainActor
public protocol BackgroundTaskHandling: AnyObject {
    /// Request additional time to finish work when the app is about to
    /// suspend. `expirationHandler` runs when the OS is about to forcibly
    /// end the task — the caller MUST call `end(_:)` from within it.
    func begin(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken

    /// Release the background-task token. No-op for `.invalid`.
    func end(_ token: BackgroundTaskToken)

    /// Remaining time before the OS forcibly ends the current task.
    /// macOS returns `.infinity`.
    var backgroundTimeRemaining: TimeInterval { get }
}
