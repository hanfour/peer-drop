import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var searchQuery = ""

    private var filteredRecords: [DeviceRecord] {
        let store = connectionManager.deviceStore
        if searchQuery.isEmpty {
            return store.sorted(by: .lastConnected)
        }
        return store.search(query: searchQuery).sorted { $0.lastConnected > $1.lastConnected }
    }

    var body: some View {
        Group {
            if connectionManager.deviceStore.records.isEmpty && searchQuery.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
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
                    ForEach(filteredRecords) { record in
                        DeviceRecordRow(record: record) {
                            reconnect(record: record)
                        }
                    }
                    .onDelete { indexSet in
                        let records = filteredRecords
                        for index in indexSet {
                            connectionManager.deviceStore.remove(id: records[index].id)
                        }
                    }
                }
                .searchable(text: $searchQuery, prompt: "Search devices")
            }
        }
        .navigationTitle("Library")
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
