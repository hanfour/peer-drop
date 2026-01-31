import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        VStack(spacing: 20) {
            if let peer = connectionManager.connectedPeer {
                PeerAvatar(name: peer.displayName)
                    .scaleEffect(1.5)

                Text("Connected to \(peer.displayName)")
                    .font(.headline)

                StatusBadge(state: connectionManager.state)
            }

            Spacer()

            if case .connected = connectionManager.state {
                HStack(spacing: 16) {
                    NavigationLink {
                        FilePickerView()
                            .environmentObject(connectionManager)
                    } label: {
                        Label("Send File", systemImage: "doc.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        connectionManager.showVoiceCall = true
                    } label: {
                        Label("Voice Call", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }
                .padding(.horizontal)
            }

            Button("Disconnect", role: .destructive) {
                connectionManager.disconnect()
            }
            .padding(.bottom)
        }
        .padding()
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}
