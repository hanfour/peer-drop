import Foundation

/// Cross-platform haptic feedback abstraction. Method names match the
/// 9 semantic call sites in HapticManager rather than UIKit's generator
/// types — keeps macOS no-op trivially simple and iOS impl mechanical.
public protocol HapticFeedback {
    func peerDiscovered()
    func connectionAccepted()
    func connectionRejected()
    func transferComplete()
    func transferFailed()
    func incomingRequest()
    func callStarted()
    func callEnded()
    func evolutionTriggered()
    func tap()
}
