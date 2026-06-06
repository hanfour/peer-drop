#if canImport(AppKit)
import AppKit
import PeerDropPlatform
import PeerDropTransport
import os

/// macOS implementation of `CallProvider`.
///
/// Symmetric to iOS `CallKitManager` but draws the incoming-call UI as
/// a custom `NSPanel` (`MacIncomingCallPanel`) and the in-call UI as a
/// floating `NSWindow` (`MacActiveCallWindow`). PushKit is not used on
/// macOS — APNs alert push wakes the app, and the actual call
/// signalling arrives over the in-band PeerMessage channel.
///
/// **Cold-launch grace window:** When the user accepts a call from the
/// APNs notification, the SDP offer may take 3-10s to arrive over the
/// re-established relay WebSocket. `handleColdLaunchPush` shows the
/// panel immediately from the push payload alone and tolerates a 10s
/// grace window before declaring the call expired.
///
/// **`onEndCall` is parameterless** (`(() -> Void)?`) — the CallProvider
/// protocol does not propagate the end reason via that callback. The
/// reason is surfaced via `reportCallEnded(reason:)` on the consumer
/// side.
@MainActor
final class MacCallProvider: NSObject, CallProvider {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "CallProvider")

    private let incomingPanel = MacIncomingCallPanel()
    private let activeWindow = MacActiveCallWindow()
    private let ringer = MacRingtonePlayer()
    private let dismissTimer = IncomingCallAutoDismissTimer()

    private var coldLaunchGraceTask: Task<Void, Never>?
    private var pendingColdLaunchCaller: String?

    // MARK: - CallProvider

    var onAnswerCall: (() -> Void)?
    var onEndCall: (() -> Void)?

    func reportIncomingCall(from peerName: String) async throws {
        logger.info("Incoming call from \(peerName, privacy: .public)")

        let silenced = await DNDFilter.shouldSilenceRingtone()
        ringer.start(silent: silenced)

        incomingPanel.show(
            callerName: peerName,
            onAccept: { [weak self] in self?.handleAccept() },
            onDecline: { [weak self] in self?.handleDecline() }
        )

        dismissTimer.start(duration: 30) { [weak self] in
            self?.handleTimeout()
        }
    }

    func startOutgoingCall(to peerName: String) {
        logger.info("Outgoing call to \(peerName, privacy: .public)")
        // Active window is shown by the consumer (see showActiveWindow)
        // once it has the VoiceCallManager instance.
    }

    func reportOutgoingCallConnected() {
        logger.info("Outgoing call connected")
        // VoiceCallManager.isInCall flips via its own state machine;
        // MacVoiceCallView observes it. No work needed here.
    }

    func reportCallEnded(reason: CallEndReason) {
        logger.info("Call ended: \(String(describing: reason), privacy: .public)")
        cleanup()
    }

    func endCall() {
        logger.info("Local user ended call")
        cleanup()
    }

    func configureAudioSession() {
        // No-op: macOS routes voice-chat audio automatically (WebRTC
        // manages capture device internally on macOS).
    }

    // MARK: - Cold-launch grace window

    /// Called by `MacAppDelegate.application(_:didReceiveRemoteNotification:)`
    /// when a `type: "callRequest"` push payload arrives. If the app was
    /// cold-launched by the push, the in-band callRequest PeerMessage
    /// (carrying the SDP offer) may take 3-10s to arrive once relay
    /// reconnects. We show the panel from the push payload alone and
    /// allow a 10s grace window before treating the call as expired.
    func handleColdLaunchPush(callerName: String) {
        logger.info("Cold-launch push: \(callerName, privacy: .public) — starting 10s grace")
        pendingColdLaunchCaller = callerName

        Task {
            try? await reportIncomingCall(from: callerName)
        }

        coldLaunchGraceTask?.cancel()
        coldLaunchGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.logger.warning("Cold-launch SDP grace expired — treating call as unanswered")
            self.reportCallEnded(reason: .unanswered)
            self.pendingColdLaunchCaller = nil
        }
    }

    /// Called when the real in-band callRequest PeerMessage arrives
    /// after a cold-launch push. Cancels the grace timer.
    func handleInbandCallRequest(from peerName: String) {
        guard pendingColdLaunchCaller != nil else { return }
        logger.info("In-band SDP arrived during cold-launch grace — proceeding")
        coldLaunchGraceTask?.cancel()
        coldLaunchGraceTask = nil
        pendingColdLaunchCaller = nil
    }

    // MARK: - Active window

    /// Present the active-call window. Called by the consumer (Task 12
    /// wiring) after `onAnswerCall` fires, with the live
    /// VoiceCallManager instance from `ConnectionManager`.
    func showActiveWindow(peerName: String, voiceCallManager: VoiceCallManager) {
        activeWindow.show(peerName: peerName, voiceCallManager: voiceCallManager)
    }

    // MARK: - Private

    private func handleAccept() {
        logger.info("User accepted call")
        ringer.stop()
        dismissTimer.cancel()
        coldLaunchGraceTask?.cancel()
        coldLaunchGraceTask = nil
        pendingColdLaunchCaller = nil
        incomingPanel.dismiss()
        onAnswerCall?()
    }

    private func handleDecline() {
        logger.info("User declined call")
        cleanup()
        onEndCall?()
    }

    private func handleTimeout() {
        logger.info("Call timed out (30s)")
        cleanup()
        onEndCall?()
    }

    private func cleanup() {
        ringer.stop()
        dismissTimer.cancel()
        coldLaunchGraceTask?.cancel()
        coldLaunchGraceTask = nil
        pendingColdLaunchCaller = nil
        incomingPanel.dismiss()
        activeWindow.dismiss()
    }
}
#endif
