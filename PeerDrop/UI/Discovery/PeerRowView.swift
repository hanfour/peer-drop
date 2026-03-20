import SwiftUI

struct PeerRowView: View {
    let peer: DiscoveredPeer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PeerAvatar(name: peer.displayName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: sourceIcon)
                            .font(.caption2)
                        Text(sourceLabel)
                        if let distance = peer.distance {
                            Text(String(format: "%.1f m", distance))
                                .fontWeight(.medium)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if peer.source == .bluetooth, case .bleOnly = peer.endpoint {
                        Text("Connect to the same WiFi network to transfer files")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if let rssi = peer.rssi {
                    signalStrengthIcon(rssi: rssi)
                        .font(.caption)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peer.displayName), \(sourceLabel)")
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
}
