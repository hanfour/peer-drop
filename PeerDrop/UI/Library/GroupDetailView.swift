import SwiftUI

struct GroupDetailView: View {
    let group: DeviceGroup
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showAddMember = false
    @State private var showEditGroup = false
    @State private var isConnecting = false

    private var groupStore: DeviceGroupStore {
        connectionManager.groupStore
    }

    private var members: [(id: String, record: DeviceRecord?, isOnline: Bool, isConnected: Bool)] {
        group.deviceIDs.map { deviceID in
            let record = connectionManager.deviceStore.records.first { $0.id == deviceID }
            let isOnline = connectionManager.discoveredPeers.contains { $0.id == deviceID }
            let isConnected = connectionManager.isConnected(to: deviceID)
            return (deviceID, record, isOnline, isConnected)
        }
    }

    private var connectionStatus: (connected: Int, total: Int, online: Int) {
        connectionManager.groupConnectionStatus(group)
    }

    private var hasConnectedMembers: Bool {
        connectionStatus.connected > 0
    }

    private var hasOnlineMembers: Bool {
        connectionStatus.online > 0
    }

    var body: some View {
        List {
            // Status section
            Section {
                statusRow
            }

            // Actions section
            Section {
                // Connect All button
                Button {
                    connectAll()
                } label: {
                    HStack {
                        Label("Connect All", systemImage: "link.badge.plus")
                        Spacer()
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .disabled(!hasOnlineMembers || isConnecting)

                // Group Chat button
                NavigationLink {
                    GroupChatView(group: group)
                } label: {
                    HStack {
                        Label("Group Chat", systemImage: "bubble.left.and.bubble.right")
                        Spacer()
                        let unread = connectionManager.chatManager.groupUnreadCount(for: group.id)
                        if unread > 0 {
                            Text("\(unread)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                    }
                }
                .disabled(!hasConnectedMembers)
            }

            // Members section
            Section {
                ForEach(members, id: \.id) { member in
                    memberRow(member)
                }
                .onDelete { indexSet in
                    let memberList = members
                    for index in indexSet {
                        groupStore.removeDevice(memberList[index].id, fromGroup: group.id)
                    }
                }

                Button {
                    showAddMember = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Add Member")
                            .foregroundStyle(.blue)
                    }
                }
            } header: {
                Text("Members (\(group.deviceIDs.count))")
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditGroup = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showAddMember) {
            AddGroupMemberSheet(groupID: group.id)
        }
        .sheet(isPresented: $showEditGroup) {
            GroupEditorView(groupStore: groupStore, group: group)
        }
    }

    private var statusRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection Status")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    // Connected indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("\(connectionStatus.connected) connected")
                            .font(.caption)
                    }

                    Text("·")
                        .foregroundStyle(.tertiary)

                    // Online indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                        Text("\(connectionStatus.online) online")
                            .font(.caption)
                    }
                }
            }

            Spacer()

            Text("\(connectionStatus.total) total")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func memberRow(_ member: (id: String, record: DeviceRecord?, isOnline: Bool, isConnected: Bool)) -> some View {
        HStack(spacing: 12) {
            // Avatar
            if let record = member.record {
                PeerAvatar(name: record.displayName)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.fill")
                        .foregroundStyle(.gray)
                }
            }

            // Name and status
            VStack(alignment: .leading, spacing: 2) {
                Text(member.record?.displayName ?? "Unknown Device")
                    .font(.body)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(member.isConnected ? .green : (member.isOnline ? .blue : .gray))
                        .frame(width: 6, height: 6)
                    Text(member.isConnected ? "Connected" : (member.isOnline ? "Online" : "Offline"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Connect button for online but not connected members
            if member.isOnline && !member.isConnected {
                Button {
                    if let peer = connectionManager.discoveredPeers.first(where: { $0.id == member.id }) {
                        connectionManager.requestConnection(to: peer)
                    }
                } label: {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func connectAll() {
        isConnecting = true
        connectionManager.connectToGroup(group)
        // Reset connecting state after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isConnecting = false
        }
    }
}

// MARK: - Add Group Member Sheet

struct AddGroupMemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var connectionManager: ConnectionManager
    let groupID: String

    private var groupStore: DeviceGroupStore {
        connectionManager.groupStore
    }

    private var group: DeviceGroup? {
        groupStore.groups.first { $0.id == groupID }
    }

    private var availableDevices: [DeviceRecord] {
        guard let group = group else { return [] }
        return connectionManager.deviceStore.records.filter { record in
            !group.deviceIDs.contains(record.id)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if availableDevices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No devices available")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Connect to more devices first")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(availableDevices) { record in
                        Button {
                            groupStore.addDevice(record.id, toGroup: groupID)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                PeerAvatar(name: record.displayName)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.displayName)
                                        .font(.body)
                                        .foregroundStyle(.primary)

                                    let isOnline = connectionManager.discoveredPeers.contains { $0.id == record.id }
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(isOnline ? .blue : .gray)
                                            .frame(width: 6, height: 6)
                                        Text(isOnline ? "Online" : "Offline")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
