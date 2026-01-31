import SwiftUI

struct VoiceCallView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @StateObject private var callManager: VoiceCallManager

    init() {
        // Placeholder — actual init happens via environment
        _callManager = StateObject(wrappedValue: VoiceCallManager(
            connectionManager: ConnectionManager(),
            callKitManager: CallKitManager()
        ))
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            if let peer = connectionManager.connectedPeer {
                PeerAvatar(name: peer.displayName)
                    .scaleEffect(2.0)

                Text(peer.displayName)
                    .font(.title.bold())

                Text(callManager.isInCall ? "Connected" : "Calling...")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Call controls
            HStack(spacing: 40) {
                CallButton(
                    icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: "Mute",
                    isActive: callManager.isMuted
                ) {
                    callManager.isMuted.toggle()
                }

                CallButton(
                    icon: "speaker.wave.3.fill",
                    label: "Speaker",
                    isActive: callManager.isSpeakerOn
                ) {
                    callManager.isSpeakerOn.toggle()
                }

                CallButton(
                    icon: "phone.down.fill",
                    label: "End",
                    isDestructive: true
                ) {
                    callManager.endCall()
                }
            }
            .padding(.bottom, 48)
        }
        .padding()
        .onAppear {
            if connectionManager.voiceCallManager != nil {
                // Voice call manager is available from connectionManager
            }
        }
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
