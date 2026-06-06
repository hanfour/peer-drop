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
@MainActor
final class MacActiveCallWindow {
    private var window: NSWindow?

    func show(peerName: String, voiceCallManager: VoiceCallManager) {
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

        window.contentView = NSHostingView(
            rootView: MacVoiceCallView(peerName: peerName)
                .environmentObject(voiceCallManager)
        )

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
#endif
