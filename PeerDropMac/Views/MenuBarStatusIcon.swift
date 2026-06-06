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
        let template = NSLocalizedString(
            "PeerDrop status: %@",
            comment: "VoiceOver label for the menu bar status icon; %@ is the current connection state"
        )
        return String(format: template, localizedStateName)
    }

    private var localizedStateName: String {
        switch state {
        case .idle:            return NSLocalizedString("Idle", comment: "ConnectionState: no peer activity")
        case .discovering:     return NSLocalizedString("Discovering", comment: "ConnectionState: scanning for peers")
        case .peerFound:       return NSLocalizedString("Peer Found", comment: "ConnectionState: discovered a peer")
        case .requesting:      return NSLocalizedString("Requesting", comment: "ConnectionState: outbound connection request")
        case .incomingRequest: return NSLocalizedString("Incoming Request", comment: "ConnectionState: inbound connection request pending")
        case .connecting:      return NSLocalizedString("Connecting", comment: "ConnectionState: handshake in progress")
        case .connected:       return NSLocalizedString("Connected", comment: "ConnectionState: peer connected")
        case .transferring:    return NSLocalizedString("Transferring", comment: "ConnectionState: file transfer active")
        case .voiceCall:       return NSLocalizedString("In Call", comment: "ConnectionState: voice call active")
        case .disconnected:    return NSLocalizedString("Disconnected", comment: "ConnectionState: peer disconnected")
        case .rejected:        return NSLocalizedString("Rejected", comment: "ConnectionState: connection rejected")
        case .failed:          return NSLocalizedString("Failed", comment: "ConnectionState: connection failed")
        }
    }
}
