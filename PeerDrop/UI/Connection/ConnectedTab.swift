import SwiftUI

struct ConnectedTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showDetail = false

    private var isConnected: Bool {
        switch connectionManager.state {
        case .connected, .transferring, .voiceCall: return true
        default: return false
        }
    }

    private var contactRecords: [DeviceRecord] {
        connectionManager.deviceStore.sorted(by: .name)
    }

    var body: some View {
        Group {
            if isConnected {
                List {
                    Section("Active") {
                        if let peer = connectionManager.connectedPeer {
                            Button { showDetail = true } label: {
                                HStack {
                                    PeerAvatar(name: peer.displayName)

                                    VStack(alignment: .leading) {
                                        Text(peer.displayName)
                                            .font(.body.bold())
                                        Text("Connected")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }

                                    Spacer()

                                    if let count = connectionManager.chatManager.unreadCounts[peer.id], count > 0 {
                                        Text("\(count)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                            .padding(6)
                                            .background(Circle().fill(.red))
                                    }

                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .accessibilityIdentifier("active-peer-row")
                            .tint(.primary)
                        }
                    }

                    Section("Contacts") {
                        if contactRecords.isEmpty {
                            Text("No saved devices")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(contactRecords) { record in
                                DeviceRecordRow(record: record) {
                                    reconnect(record: record)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteRecord(record)
                                    } label: {
                                        Image(systemName: "trash.circle.fill")
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationDestination(isPresented: $showDetail) {
                    ConnectionView()
                        .environmentObject(connectionManager)
                }
            } else if contactRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No saved devices")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Devices you connect to will appear here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No active connection")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    Section("Contacts") {
                        ForEach(contactRecords) { record in
                            DeviceRecordRow(record: record) {
                                reconnect(record: record)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteRecord(record)
                                } label: {
                                    Image(systemName: "trash.circle.fill")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Connected")
    }

    private func deleteRecord(_ record: DeviceRecord) {
        connectionManager.deviceStore.remove(id: record.id)
        connectionManager.chatManager.deleteMessages(forPeer: record.id)
    }

    private func reconnect(record: DeviceRecord) {
        if let peer = connectionManager.discoveredPeers.first(where: { $0.id == record.id }) {
            connectionManager.requestConnection(to: peer)
        } else if let host = record.host, let port = record.port {
            connectionManager.addManualPeer(host: host, port: port, name: record.displayName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let peer = connectionManager.discoveredPeers.first(where: { $0.id == record.id }) {
                    connectionManager.requestConnection(to: peer)
                }
            }
        }
    }
}
