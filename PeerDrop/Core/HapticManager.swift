import Foundation

/// Centralized haptic feedback for key app events.
///
/// Static facade preserved for call-site compatibility; the actual
/// implementation comes from `PlatformDependencies.shared.haptics()`.
enum HapticManager {
    private static var feedback: HapticFeedback { PlatformDependencies.shared.haptics() }

    static func peerDiscovered() { feedback.peerDiscovered() }
    static func connectionAccepted() { feedback.connectionAccepted() }
    static func connectionRejected() { feedback.connectionRejected() }
    static func transferComplete() { feedback.transferComplete() }
    static func transferFailed() { feedback.transferFailed() }
    static func incomingRequest() { feedback.incomingRequest() }
    static func callStarted() { feedback.callStarted() }
    static func callEnded() { feedback.callEnded() }
    static func evolutionTriggered() { feedback.evolutionTriggered() }
    static func tap() { feedback.tap() }
}
