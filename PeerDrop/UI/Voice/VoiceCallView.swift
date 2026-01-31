import SwiftUI

struct VoiceCallView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    private var callManager: VoiceCallManager? {
        connectionManager.voiceCallManager
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            if let peer = connectionManager.connectedPeer {
                PeerAvatar(name: peer.displayName)
                    .scaleEffect(2.0)

                Text(peer.displayName)
                    .font(.title.bold())

                Text(callManager?.isInCall == true ? "Connected" : "Calling...")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Call controls
            HStack(spacing: 40) {
                CallButton(
                    icon: callManager?.isMuted == true ? "mic.slash.fill" : "mic.fill",
                    label: "Mute",
                    isActive: callManager?.isMuted == true
                ) {
                    callManager?.isMuted.toggle()
                }

                CallButton(
                    icon: "speaker.wave.3.fill",
                    label: "Speaker",
                    isActive: callManager?.isSpeakerOn == true
                ) {
                    callManager?.isSpeakerOn.toggle()
                }

                CallButton(
                    icon: "phone.down.fill",
                    label: "End",
                    isDestructive: true
                ) {
                    callManager?.endCall()
                }
            }
            .padding(.bottom, 48)
        }
        .padding()
    }
}

struct CallButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .frame(width: 56, height: 56)
                    .background(backgroundColor)
                    .foregroundStyle(foregroundColor)
                    .clipShape(Circle())

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(isDestructive ? "Ends the current call" : "")
    }

    private var accessibilityDescription: String {
        if isDestructive { return "End call" }
        if isActive { return "\(label), active" }
        return label
    }

    private var backgroundColor: Color {
        if isDestructive { return .red }
        if isActive { return .white }
        return Color(.systemGray5)
    }

    private var foregroundColor: Color {
        if isDestructive { return .white }
        if isActive { return .black }
        return .primary
    }
}
