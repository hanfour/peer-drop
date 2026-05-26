import Foundation

/// Centralized haptic feedback for key app events.
///
/// Static facade preserved for call-site compatibility; the actual
/// implementation comes from `PlatformDependencies.shared.haptics()`.
public enum HapticManager {
    private static var feedback: HapticFeedback { PlatformDependencies.shared.haptics() }

    public static func peerDiscovered() { feedback.peerDiscovered() }
    public static func connectionAccepted() { feedback.connectionAccepted() }
    public static func connectionRejected() { feedback.connectionRejected() }
    public static func transferComplete() { feedback.transferComplete() }
    public static func transferFailed() { feedback.transferFailed() }
    public static func incomingRequest() { feedback.incomingRequest() }
    public static func callStarted() { feedback.callStarted() }
    public static func callEnded() { feedback.callEnded() }
    public static func evolutionTriggered() { feedback.evolutionTriggered() }
    public static func tap() { feedback.tap() }
}
