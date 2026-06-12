#if canImport(AppKit)
import AppKit
import SwiftUI
import PeerDropTransport

/// Floating in-call window hosting `MacVoiceCallView`.
///
/// Unlike `MacIncomingCallPanel` this is a regular `NSWindow` — once
/// the user has accepted the call they expect a "real" window they can
/// focus / drag / minimise. `.canJoinAllSpaces | .fullScreenAuxiliary`
/// preserve the panel's cross-Space behaviour during the call.
///
/// Round 12 audit fix: previously
///   - the title-bar ✕ closed the window without ending the call —
///     WebRTC session kept running, mic stayed hot (privacy + UX bug;
///     Apple Guideline 2.1 reject risk because reviewer's "end the
///     call" path appears broken).
///   - `show()` did not dismiss any prior window, so re-showing during
///     a cold-launch grace flip orphaned the previous NSWindow on
///     screen (same pattern `MacIncomingCallPanel` already fixed).
/// Both fixed here: NSWindowDelegate routes user-close to
/// `onUserClose`, and `show()` dismisses first.
@MainActor
final class MacActiveCallWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onUserClose: (() -> Void)?
    /// True while `dismiss()` is tearing down the window. Guards against
    /// the `windowWillClose:` re-entrance that would otherwise fire
    /// `onUserClose` a second time after the consumer already initiated
    /// the end-call flow.
    private var isProgrammaticDismiss = false

    /// Present the active-call window. `onUserClose` fires when the user
    /// clicks the title-bar ✕ (or otherwise dismisses the window from
    /// the system). Consumers should route this to the VoiceCallManager's
    /// `endCall()` so the in-band tear-down PeerMessage is sent.
    func show(
        peerName: String,
        voiceCallManager: VoiceCallManager,
        onUserClose: @escaping () -> Void
    ) {
        // Tear down any orphan window from a previous call before
        // assigning a fresh one. Matches MacIncomingCallPanel's pattern.
        dismiss()
        self.onUserClose = onUserClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Call with \(peerName)"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.contentView = NSHostingView(
            rootView: MacVoiceCallView(peerName: peerName)
                .environmentObject(voiceCallManager)
        )

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func dismiss() {
        guard let window else { return }
        isProgrammaticDismiss = true
        window.delegate = nil
        window.close()
        self.window = nil
        onUserClose = nil
        isProgrammaticDismiss = false
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isProgrammaticDismiss else { return }
        let callback = onUserClose
        // Clear local state before invoking the callback so consumer's
        // re-entrant `dismiss()` from cleanup is a no-op.
        window = nil
        onUserClose = nil
        callback?()
    }
}
#endif
