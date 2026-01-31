import SwiftUI
import UIKit

struct ConnectionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showDisconnectConfirm = false
    @State private var showToast = false
    @State private var toastRecord: TransferRecord?
    @State private var hasClipboardContent = false
    @State private var showClipboardShare = false

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
                                showClipboardShare = true
                            } label: {
                                Label("Clipboard", systemImage: "doc.on.clipboard")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(!hasClipboardContent)

                            Button {
                                Task {
                                    await connectionManager.voiceCallManager?.startCall()
                                }
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

            // Toast overlay
            if showToast, let record = toastRecord {
                ToastView(record: record)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .zIndex(1)
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    TransferHistoryView()
                        .environmentObject(connectionManager)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
        }
        .sheet(isPresented: $showClipboardShare) {
            ClipboardShareView()
                .environmentObject(connectionManager)
        }
        .animation(.easeInOut(duration: 0.25), value: connectionManager.state)
        .onAppear {
            checkClipboardContent()
        }
        .onChange(of: connectionManager.state) { _ in
            checkClipboardContent()
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

    // MARK: - Clipboard Helper

    private func checkClipboardContent() {
        let pasteboard = UIPasteboard.general
        hasClipboardContent = pasteboard.hasStrings || pasteboard.hasImages
    }

}
