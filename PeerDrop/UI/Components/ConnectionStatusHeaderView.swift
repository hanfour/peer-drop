import SwiftUI

struct ConnectionStatusHeaderView: View {
    let state: ConnectionState
    let peerName: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private var statusColor: Color {
        switch state {
        case .connected, .transferring, .voiceCall: return .green
        case .connecting, .requesting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    private var statusText: String {
        switch state {
        case .connected:
            return "Connected to \(peerName ?? "peer")"
        case .transferring:
            return "Transferring..."
        case .voiceCall:
            return "On call with \(peerName ?? "peer")"
        case .connecting, .requesting:
            return "Connecting..."
        case .failed(let reason):
            return "Failed: \(reason)"
        case .disconnected:
            return "Disconnected"
        default:
            return "Not connected"
        }
    }
}
