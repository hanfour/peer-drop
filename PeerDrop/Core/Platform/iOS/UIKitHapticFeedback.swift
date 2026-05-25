#if canImport(UIKit)
import UIKit

final class UIKitHapticFeedback: HapticFeedback {
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    func peerDiscovered() { selection.selectionChanged() }
    func connectionAccepted() { notification.notificationOccurred(.success) }
    func connectionRejected() { notification.notificationOccurred(.error) }
    func transferComplete() { notification.notificationOccurred(.success) }
    func transferFailed() { notification.notificationOccurred(.warning) }
    func incomingRequest() { impact.impactOccurred() }
    func callStarted() { impact.impactOccurred() }
    func callEnded() { selection.selectionChanged() }
    func tap() { impact.impactOccurred(intensity: 0.5) }
}
#endif
