import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var searchQuery = ""
    @State private var showGroupEditor = false

    private var groupStore: DeviceGroupStore {
        connectionManager.groupStore
    }

    private var filteredRecords: [DeviceRecord] {
        let store = connectionManager.deviceStore
        if searchQuery.isEmpty {
            return store.sorted(by: .lastConnected)
        }
        return store.search(query: searchQuery).sorted { $0.lastConnected > $1.lastConnected }
    }

    private var filteredGroups: [DeviceGroup] {
        if searchQuery.isEmpty {
            return groupStore.groups
        }
        return groupStore.groups.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var hasContent: Bool {
        !connectionManager.deviceStore.records.isEmpty || !groupStore.groups.isEmpty
    }

    var body: some View {
        Group {
            if !hasContent && searchQuery.isEmpty {
                emptyState
            } else {
                contentList
            }
        }
        .navigationTitle("Library")
        .sheet(isPresented: $showGroupEditor) {
            GroupEditorView(groupStore: groupStore)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No saved devices")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Devices you connect to will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                showGroupEditor = true
            } label: {
                Label("Create Group", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
            .accessibilityHint("Creates a new device group")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var contentList: some View {
        List {
            // Groups section
            if !filteredGroups.isEmpty || searchQuery.isEmpty {
                Section {
                    ForEach(filteredGroups) { group in
                        NavigationLink(destination: GroupDetailView(group: group)) {
                            GroupRow(group: group)
                        }
                    }
                    .onDelete { indexSet in
                        let groups = filteredGroups
                        for index in indexSet {
                            groupStore.remove(id: groups[index].id)
                        }
                    }

                    Button {
                        showGroupEditor = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                            Text("New Group")
                                .foregroundStyle(.blue)
                        }
                    }
                    .accessibilityLabel("New Group")
                    .accessibilityHint("Creates a new device group")
                } header: {
                    Text("Groups")
                }
            }

            // Devices section
            if !filteredRecords.isEmpty {
                Section {
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
                } header: {
                    Text("Devices")
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "Search devices and groups")
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
