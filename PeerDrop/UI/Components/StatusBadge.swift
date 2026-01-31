import SwiftUI

struct StatusBadge: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }

    private var label: String {
        switch state {
        case .idle: return "Idle"
        case .discovering: return "Discovering"
        case .peerFound: return "Peer Found"
        case .requesting: return "Requesting"
        case .incomingRequest: return "Incoming"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .transferring: return "Transferring"
        case .voiceCall: return "On Call"
        case .disconnected: return "Disconnected"
        case .rejected: return "Rejected"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .idle, .disconnected: return .gray
        case .discovering, .peerFound: return .blue
        case .requesting, .incomingRequest, .connecting: return .orange
        case .connected: return .green
        case .transferring: return .purple
        case .voiceCall: return .green
        case .rejected: return .red
        case .failed: return .red
        }
    }
}
