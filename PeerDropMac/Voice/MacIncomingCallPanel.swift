#if canImport(AppKit)
import AppKit
import SwiftUI

/// Floating top-right `NSPanel` that hosts `IncomingCallPanelView`.
///
/// Design:
///   - `NSPanel` + `.nonactivatingPanel` style mask: appears without
///     bringing PeerDrop to the foreground (FaceTime parity).
///   - `.canJoinAllSpaces | .stationary`: stays visible when the user
///     switches Spaces; position is screen-relative, not Space-relative.
///   - `.fullScreenAuxiliary`: surfaces over a full-screen app.
///   - `orderFrontRegardless()`: shows even if PeerDrop is inactive.
@MainActor
final class MacIncomingCallPanel {
    private var panel: NSPanel?

    func show(
        callerName: String,
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let view = IncomingCallPanelView(
            callerName: callerName,
            onAccept: onAccept,
            onDecline: onDecline
        )
        panel.contentView = NSHostingView(rootView: view)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - 380 - 20,
                y: frame.maxY - 100 - 80
            ))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
#endif
