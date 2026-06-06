#if canImport(AppKit)
import SwiftUI
import PeerDropTransport

/// Mac-bespoke in-call UI hosted by `MacActiveCallWindow`.
///
/// Different from the iOS `VoiceCallView` because:
///   - No speaker toggle: macOS users control output device via the
///     system Volume menu / AirPods picker, not in-app.
///   - No navigation chrome / sheet semantics: lives in its own
///     floating NSWindow.
///   - No CallKit-driven dismiss: window closes via `MacCallProvider.cleanup`
///     when the call ends.
struct MacVoiceCallView: View {
    @EnvironmentObject var voiceCallManager: VoiceCallManager
    let peerName: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text(peerName)
                .font(.title2)

            Text(voiceCallManager.isInCall
                ? NSLocalizedString("Connected", comment: "Voice call status: peer connected")
                : NSLocalizedString("Connecting…", comment: "Voice call status: handshake in progress"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 24) {
                Button {
                    voiceCallManager.isMuted.toggle()
                } label: {
                    Image(systemName: voiceCallManager.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .background(voiceCallManager.isMuted ? .red : .secondary.opacity(0.2), in: Circle())
                        .foregroundStyle(voiceCallManager.isMuted ? .white : .primary)
                }
                .buttonStyle(.plain)
                .help(voiceCallManager.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(voiceCallManager.isMuted ? "Unmute microphone" : "Mute microphone")

                Button {
                    voiceCallManager.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .background(.red, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("End call")
                .accessibilityLabel("End call")
            }
            .padding(.bottom, 40)
        }
        .padding(.top, 40)
        .frame(width: 320, height: 420)
    }
}
#endif
