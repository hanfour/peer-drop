import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showDisconnectConfirm = false
    @State private var showToast = false
    @State private var toastRecord: TransferRecord?
    @State private var showFilePicker = false
    @State private var showChat = false

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

                    // Connection History
                    if let record = connectionManager.deviceStore.records.first(where: { $0.id == peer.id }),
                       !record.connectionHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Connection History")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)

                            VStack(spacing: 0) {
                                ForEach(Array(record.connectionHistory.suffix(10).reversed().enumerated()), id: \.offset) { index, date in
                                    if index > 0 {
                                        Divider().padding(.leading, 16)
                                    }
                                    HStack {
                                        Text(date, style: .relative)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    Spacer()

                    if case .connected = connectionManager.state {
                        HStack(spacing: 32) {
                            circleButton(icon: "doc.fill", label: "Send File", color: .blue) {
                                showFilePicker = true
                            }

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

                            circleButton(icon: "phone.fill", label: "Voice Call", color: .green) {
                                Task {
                                    await connectionManager.voiceCallManager?.startCall()
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
