import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showDisconnectConfirm = false
    @State private var showToast = false
    @State private var toastRecord: TransferRecord?
    @State private var showFilePicker = false
    @State private var showChat = false
    @State private var showFeatureDisabledAlert = false
    @State private var disabledFeatureName = ""
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
                            circleButton(icon: "doc.fill", label: "Send File", color: .blue, disabled: !fileTransferEnabled) {
                                if fileTransferEnabled {
                                    showFilePicker = true
                                } else {
                                    disabledFeatureName = "File Transfer"
                                    showFeatureDisabledAlert = true
                                }
                            }
                            .accessibilityIdentifier("send-file-button")

                            ZStack(alignment: .topTrailing) {
                                circleButton(icon: "message.fill", label: "Chat", color: .orange, disabled: !chatEnabled) {
                                    if chatEnabled {
                                        showChat = true
                                    } else {
                                        disabledFeatureName = "Chat"
                                        showFeatureDisabledAlert = true
                                    }
                                }
                                .accessibilityIdentifier("chat-button")

                                if chatEnabled, let count = connectionManager.chatManager.unreadCounts[peer.id], count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(5)
                                        .background(Circle().fill(.red))
                                        .offset(x: 4, y: -4)
                                        .accessibilityLabel("\(count) unread messages")
                                }
                            }

                            circleButton(icon: "phone.fill", label: "Voice Call", color: .green, disabled: !voiceCallEnabled) {
                                if voiceCallEnabled {
                                    Task {
                                        await connectionManager.voiceCallManager?.startCall(to: peer.id)
                                    }
                                } else {
                                    disabledFeatureName = "Voice Calls"
                                    showFeatureDisabledAlert = true
                                }
                            }
                            .accessibilityIdentifier("voice-call-button")
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .sheet(isPresented: $showFilePicker) {
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
                        .accessibilityHint("Attempts to reconnect to this peer")
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
                    .accessibilityHint("Disconnects from the current peer")
                    .padding(.bottom)
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
        .sheet(isPresented: $showDisconnectConfirm) {
            if let peer = connectionManager.connectedPeer {
                DisconnectSheet(peerName: peer.displayName) {
                    connectionManager.disconnect()
                }
            }
        }
        .alert("\(disabledFeatureName) is Off", isPresented: $showFeatureDisabledAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable \(disabledFeatureName) in Settings to use this feature.")
        }
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

    private func circleButton(icon: String, label: String, color: Color, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(disabled ? Color.gray : color)
                    .clipShape(Circle())
                    .opacity(disabled ? 0.5 : 1.0)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(disabled ? "\(label) is disabled. Enable in Settings." : "Double tap to \(label.lowercased())")
    }
}
