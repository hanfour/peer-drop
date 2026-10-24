#if os(iOS)
import SwiftUI
import PeerDropCore
import PeerDropTransport
import PeerDropSecurity

/// What the old full-screen connection page showed, as a compact sheet opened from the chat's info
/// button: who, whether the link is encrypted and verified, how close, and the one action that lives
/// nowhere else (disconnect). Sending files and calling are in the chat itself.
struct ConnectionDetailsSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    let peerID: String
    let name: String
    @State private var showDisconnectConfirm = false

    private var connection: PeerConnection? { connectionManager.connection(for: peerID) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                PeerAvatar(name: name)
                    .scaleEffect(1.5)
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                Text(verbatim: name)
                    .font(.title2.bold())
                if let conn = connection {
                    StatusBadge(state: .connected)
                    SecureChannelIndicator(peerConn: conn)
                    if let ni = connectionManager.nearbyInteractionManager {
                        PeerProximityRow(manager: ni, peerID: conn.id)
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) { showDisconnectConfirm = true }
                        .accessibilityHint("Disconnects from the current peer")
                        .accessibilityIdentifier("disconnect-button")
                        .padding(.bottom)
                } else {
                    Text("Not connected yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Connection details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showDisconnectConfirm) {
                DisconnectSheet(peerName: name) {
                    let id = connection?.id ?? peerID
                    Task { await connectionManager.disconnect(from: id) }
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Distance / direction to the peer from Nearby Interaction (UWB devices only; absent otherwise).
private struct PeerProximityRow: View {
    @ObservedObject var manager: NearbyInteractionManager
    let peerID: String

    var body: some View {
        if let proximity = manager.peerProximity[peerID] {
            HStack(spacing: 4) {
                if let distance = proximity.distance {
                    Image(systemName: "ruler")
                        .font(.system(size: 9))
                    Text(String(format: "%.1f m", distance))
                        .font(.caption2)
                }
                if let direction = proximity.direction {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                        .rotationEffect(.radians(Double(atan2(direction.x, direction.z))))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}
#endif
