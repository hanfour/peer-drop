import SwiftUI
import PeerDropCore

/// Compact status icon shown in the macOS menu bar.
///
/// Maps every real `ConnectionState` case (defined in PeerDropCore) to a
/// distinct SF Symbol so the menu bar gives the user an at-a-glance read
/// of what the app is doing. The label is exposed via `accessibilityLabel`
/// so VoiceOver users get the same information.
struct MenuBarStatusIcon: View {
    let state: ConnectionState

    var body: some View {
        Image(systemName: iconName)
            .accessibilityLabel(accessibilityLabel)
    }

    private var iconName: String {
        switch state {
        case .idle:             return "circle.dotted"
        case .discovering:      return "dot.radiowaves.left.and.right"
        case .peerFound:        return "person.crop.circle.badge.questionmark"
        case .requesting:       return "paperplane"
        case .incomingRequest:  return "tray.and.arrow.down"
        case .connecting:       return "arrow.triangle.2.circlepath"
        case .connected:        return "checkmark.circle.fill"
        case .transferring:     return "arrow.up.arrow.down"
        case .voiceCall:        return "phone.fill"
        case .disconnected:     return "circle.slash"
        case .rejected:         return "xmark.circle"
        case .failed:           return "exclamationmark.triangle"
        }
    }

    private var accessibilityLabel: String {
        // `String(describing:)` keeps localisation simple — the menu bar
        // icon is a one-glyph status indicator, so a short technical
        // label is preferable to a sentence.
        NSLocalizedString("PeerDrop status: \(String(describing: state))", comment: "")
    }
}
