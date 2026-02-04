import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showDisconnectConfirm = false
    @State private var showToast = false
    @State private var toastRecord: TransferRecord?
    @State private var showFilePicker = false
    @State private var showChat = false
    @AppStorage("peerDropFileTransferEnabled") private var fileTransferEnabled = true
    @AppStorage("peerDropVoiceCallEnabled") private var voiceCallEnabled = true
    @AppStorage("peerDropChatEnabled") private var chatEnabled = true

    private var isTerminalState: Bool {
        switch connectionManager.state {
        case .disconnected, .failed: return true
        default: return false
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
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
                        HStack(spacing: 32) {
                            if fileTransferEnabled {
                                circleButton(icon: "doc.fill", label: "Send File", color: .blue) {
                                    showFilePicker = true
                                }
                            }

                            if chatEnabled {
                                ZStack(alignment: .topTrailing) {
                                    circleButton(icon: "message.fill", label: "Chat", color: .orange) {
                                        showChat = true
                                    }

                                    if let count = connectionManager.chatManager.unreadCounts[peer.id], count > 0 {
                                        Text("\(count)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                            .padding(5)
                                            .background(Circle().fill(.red))
                                            .offset(x: 4, y: -4)
                                    }
                                }
                            }

                            if voiceCallEnabled {
                                circleButton(icon: "phone.fill", label: "Voice Call", color: .green) {
                                    Task {
                                        await connectionManager.voiceCallManager?.startCall()
                                    }
                                }
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .navigationDestination(isPresented: $showFilePicker) {
                            FilePickerView()
                                .environmentObject(connectionManager)
                        }
                        .navigationDestination(isPresented: $showChat) {
                            ChatView(
                                chatManager: connectionManager.chatManager,
                                peerID: peer.id,
                                peerName: peer.displayName
                            )
                            .environmentObject(connectionManager)
                        }
                    }

                    // Reconnect button for disconnected/failed states
                    if isTerminalState {
                        Button {
                            connectionManager.reconnect()
                        } label: {
                            Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!connectionManager.canReconnect)
                        .transition(.opacity)
                    }
                } else {
                    Spacer()
                    ProgressView()
                    Text("Establishing connection...")
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if case .connected = connectionManager.state {
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
                } else if isTerminalState {
                    Button("Back to Discovery") {
                        connectionManager.returnToDiscovery()
                    }
                    .padding(.bottom)
                }
            }
            .padding()

            // Toast overlay
            if showToast, let record = toastRecord {
                ToastView(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: connectionManager.state)
        .animation(.easeInOut(duration: 0.25), value: showChat)
        .animation(.easeInOut(duration: 0.25), value: showFilePicker)
        .onChange(of: connectionManager.latestToast?.id) { _ in
            guard let record = connectionManager.latestToast else { return }
            toastRecord = record
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showToast = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    showToast = false
                }
            }
        }
    }

    private func circleButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(color)
                    .clipShape(Circle())
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
