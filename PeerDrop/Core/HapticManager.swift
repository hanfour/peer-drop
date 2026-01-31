import UIKit

/// Centralized haptic feedback for key app events.
enum HapticManager {
    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

    /// Peer discovered on the network.
    static func peerDiscovered() {
        selection.selectionChanged()
    }

    /// Connection accepted by peer.
    static func connectionAccepted() {
        notification.notificationOccurred(.success)
    }

    /// Connection rejected by peer.
    static func connectionRejected() {
        notification.notificationOccurred(.error)
    }

    /// File transfer completed successfully.
    static func transferComplete() {
        notification.notificationOccurred(.success)
    }

    /// File transfer failed.
    static func transferFailed() {
        notification.notificationOccurred(.warning)
    }

    /// Incoming connection request received.
    static func incomingRequest() {
        impact.impactOccurred()
    }

    /// Voice call started.
    static func callStarted() {
        impact.impactOccurred()
    }

    /// Voice call ended.
    static func callEnded() {
        selection.selectionChanged()
    }

    /// Button tap feedback.
    static func tap() {
        impact.impactOccurred(intensity: 0.5)
    }
}
