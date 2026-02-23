import SwiftUI

struct ConnectedTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showDetail = false
    @State private var selectedPeerID: String?

    private var isConnected: Bool {
        switch connectionManager.state {
        case .connected, .transferring, .voiceCall: return true
        default: return false
        }
    }

    /// All active peer connections sorted by display name.
    private var activeConnections: [PeerConnection] {
        connectionManager.connections.values
            .filter { $0.state.isConnected }
            .sorted { $0.peerIdentity.displayName < $1.peerIdentity.displayName }
    }

    private var contactRecords: [DeviceRecord] {
        connectionManager.deviceStore.sorted(by: .name)
    }

    var body: some View {
        Group {
            if isConnected || !activeConnections.isEmpty {
                connectedView
            } else if contactRecords.isEmpty {
                emptyStateView
            } else {
                contactsOnlyView
            }
        }
        .navigationTitle("Connected")
    }

    // MARK: - Connected View (with active connections)

    private var connectedView: some View {
        List {
            Section("Active (\(activeConnections.count)/\(connectionManager.maxConnections))") {
                ForEach(activeConnections) { peerConn in
                    Button {
                        connectionManager.focus(on: peerConn.id)
                        selectedPeerID = peerConn.id
                        showDetail = true
                    } label: {
                        activePeerRow(for: peerConn)
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("active-peer-row")
                    .accessibilityLabel("\(peerConn.peerIdentity.displayName), \(peerConn.isTransferring ? "transferring" : peerConn.isInVoiceCall ? "in call" : "connected")")
                    .accessibilityHint("Double tap to view connection details")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                await connectionManager.disconnect(from: peerConn.id)
                            }
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle.fill")
                        }
                    }
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
    }

    private func activePeerRow(for peerConn: PeerConnection) -> some View {
        HStack {
            PeerAvatar(name: peerConn.peerIdentity.displayName)

            VStack(alignment: .leading) {
                Text(peerConn.peerIdentity.displayName)
                    .font(.body.bold())

                HStack(spacing: 4) {
                    if peerConn.isTransferring {
                        Text("Transferring")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else if peerConn.isInVoiceCall {
                        Text("In Call")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if connectionManager.focusedPeerID == peerConn.id {
                        Text("• Active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let count = connectionManager.chatManager.unreadCounts[peerConn.id], count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(.red))
                    .accessibilityLabel("\(count) unread messages")
            }

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No saved devices")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Devices you connect to will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Contacts Only View (no active connections)

    private var contactsOnlyView: some View {
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

    // MARK: - Actions

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
