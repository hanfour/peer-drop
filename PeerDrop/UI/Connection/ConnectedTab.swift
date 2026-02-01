import SwiftUI

struct ConnectedTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    private var isConnected: Bool {
        switch connectionManager.state {
        case .connected, .transferring, .voiceCall: return true
        default: return false
        }
    }

    private var recentRecords: [DeviceRecord] {
        connectionManager.deviceStore.sorted(by: .lastConnected)
    }

    var body: some View {
        Group {
            if isConnected {
                ConnectionView()
            } else if recentRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No active connection")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Connect to a device from the Nearby tab")
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

                    Section("Recent Connections") {
                        ForEach(recentRecords) { record in
                            DeviceRecordRow(record: record) {
                                reconnect(record: record)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Connected")
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
