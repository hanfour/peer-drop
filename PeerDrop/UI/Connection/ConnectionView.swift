import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showDisconnectConfirm = false

    var body: some View {
        VStack(spacing: 20) {
            if let peer = connectionManager.connectedPeer {
                Spacer()

                PeerAvatar(name: peer.displayName)
                    .scaleEffect(1.8)
                    .padding(.bottom, 8)

                Text(peer.displayName)
                    .font(.title2.bold())

                StatusBadge(state: connectionManager.state)

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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                Spacer()
                ProgressView()
                Text("Establishing connection...")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button("Disconnect", role: .destructive) {
                showDisconnectConfirm = true
            }
            .padding(.bottom)
            .confirmationDialog(
                "Disconnect from peer?",
                isPresented: $showDisconnectConfirm,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    connectionManager.disconnect()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding()
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.25), value: connectionManager.state)
    }
}
