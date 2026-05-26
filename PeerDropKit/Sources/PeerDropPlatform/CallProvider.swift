import Foundation

/// Cross-platform end-of-call reason. Replaces CXCallEndedReason
/// (CallKit, iOS-only) at API boundaries.
///
/// Adapter mapping:
/// - iOS CallKit: .remoteEnded → CXCallEndedReason.remoteEnded; .declinedElsewhere → .declinedElsewhere;
///   .failed → .failed; .unanswered → .unanswered
/// - macOS (M3): mapped to UI-presented strings in the in-app call panel
public enum CallEndReason {
    case remoteEnded
    case declinedElsewhere
    case failed
    case unanswered
}

/// Cross-platform call lifecycle provider. iOS implementation is
/// `CallKitManager` (wraps CXProvider + CXCallController). macOS
/// implementation (M3) draws a custom floating NSWindow panel.
///
/// Method names are deliberately CallKit-derived but the parameter
/// shapes use only Foundation + cross-platform types.
public protocol CallProvider: AnyObject {
    /// Called by the provider when the user answers the incoming-call UI.
    /// Set by the consumer (VoiceCallManager) at wire-up time.
    var onAnswerCall: (() -> Void)? { get set }

    /// Called by the provider when the user ends an active call.
    /// Set by the consumer (VoiceCallManager) at wire-up time.
    var onEndCall: (() -> Void)? { get set }

    /// Start an outgoing call with the given peer's display name.
    func startOutgoingCall(to peerName: String)

    /// Report that the outgoing call has connected (remote answered).
    func reportOutgoingCallConnected()

    /// Report an incoming call. Async because iOS CallKit's reportNewIncomingCall
    /// is async/throws. macOS impl just shows the panel and resolves.
    func reportIncomingCall(from peerName: String) async throws

    /// End the current call (user-initiated from UI).
    func endCall()

    /// Report that the call ended for the given reason.
    func reportCallEnded(reason: CallEndReason)

    /// Configure platform audio session for active voice call (iOS only;
    /// macOS no-op since the system handles voice-chat routing).
    func configureAudioSession()
}
