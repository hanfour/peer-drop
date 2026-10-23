import SwiftUI
import PeerDropTransport
import PeerDropCore

struct PeerRowView: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let peer: DiscoveredPeer
    let onTap: () -> Void
    var proximityDirection: SIMD3<Float>?
    var presence: PeerPresence = .nearby
    var isConnected: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PeerAvatar(name: peer.displayName, size: 44, presence: presence)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(paper(.incomingText))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 4) {
                        Image(systemName: sourceIcon)
                            .font(.caption2)
                        Text(sourceLabel)
                        if let distance = peer.distance {
                            Text(String(format: "%.1f m", distance))
                                .fontWeight(.medium)
                        }
                        if let dir = proximityDirection ?? peer.direction {
                            directionArrow(for: dir)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(paper(.datePillText))
                    .lineLimit(2)

                    if peer.source == .bluetooth, case .bleOnly = peer.endpoint {
                        Text("Connect to the same WiFi network to transfer files")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 8)

                if let rssi = peer.rssi {
                    signalStrengthIcon(rssi: rssi)
                        .font(.caption)
                }

                if isConnected {
                    Text("Connected")
                        .font(.caption.bold())
                        .foregroundStyle(paper(.datePillText))
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    // Visual only: the whole row is the button, so the pill is not a nested control.
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(paper(.brand)))
                        .fixedSize()
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peer.displayName), \(presence.accessibilityLabel), \(sourceLabel)")
        .accessibilityHint(peer.source == .bluetooth && isBLEOnly ? "Requires WiFi to connect" : "Tap to connect to this device")
    }

    private var sourceLabel: String {
        switch peer.source {
        case .bonjour:
            return "Local Network"
        case .manual:
            return "Manual Connection"
        case .bluetooth:
            return "Bluetooth"
        case .relay:
            return "Relay"
        }
    }

    private var sourceIcon: String {
        switch peer.source {
        case .bonjour:
            return "wifi"
        case .manual:
            return "bolt.horizontal"
        case .bluetooth:
            return "wave.3.right"
        case .relay:
            return "antenna.radiowaves.left.and.right.circle"
        }
    }

    private var isBLEOnly: Bool {
        if case .bleOnly = peer.endpoint { return true }
        return false
    }

    private func signalStrengthIcon(rssi: Int) -> some View {
        if rssi > -50 {
            return Image(systemName: "wifi")
                .foregroundStyle(.green)
        } else if rssi > -70 {
            return Image(systemName: "wifi")
                .foregroundStyle(.yellow)
        } else {
            return Image(systemName: "wifi")
                .foregroundStyle(.red)
        }
    }

    private func directionArrow(for direction: SIMD3<Float>) -> some View {
        let angle = atan2(direction.x, direction.z)
        return Image(systemName: "location.north.fill")
            .font(.caption)
            .foregroundStyle(.blue)
            .rotationEffect(.radians(Double(angle)))
    }
}
