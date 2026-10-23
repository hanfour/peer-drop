import SwiftUI
import PeerDropCore

/// 主頁: self row, connected / friends / groups, invite. Uses the `.live` look.
/// Expects to be hosted in a NavigationStack (the container owns it).
/// It registers the `ChatTarget` destination itself (`.chatTargetDestination()`), so the container must NOT add one.
struct HomeTab: View, PaperThemed {
    @EnvironmentObject var connectionManager: ConnectionManager
    /// Home is always the live look; children read it through the environment.
    var paperMode: PaperMode { .live }
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// Switches to the Nearby tab (provided by the container).
    var onAddFriend: () -> Void = {}

    @State private var query = ""
    @State private var showGroupEditor = false
    #if os(iOS)
    @State private var showProfile = false
    @State private var showSettings = false
    @State private var showConnection = false
    #endif

    private static let inviteURL = URL(string: "https://apps.apple.com/app/id6759594513")!

    private var groupStore: DeviceGroupStore { connectionManager.groupStore }

    /// Presence is resolved once per body update from a single `presenceSources()` snapshot.
    private struct Snapshot {
        let presence: [String: PeerPresence]
        let connecting: Set<String>
        let sections: (connected: [DeviceRecord], friends: [DeviceRecord])
    }

    private func snapshot() -> Snapshot {
        let sources = connectionManager.presenceSources()
        let records = connectionManager.deviceStore.records
        var map: [String: PeerPresence] = [:]
        var connecting: Set<String> = []
        for r in records {
            let p = connectionManager.presence(for: r, sources: sources)
            map[r.id] = p
            var ids: Set<String> = [r.id]
            if let a = r.peerDeviceId { ids.insert(a) }
            if p != .online, !ids.isDisjoint(with: sources.connecting) { connecting.insert(r.id) }
        }
        let sections = HomeListLogic.sections(records: records, presence: { map[$0.id] ?? .offline }, query: query)
        return Snapshot(presence: map, connecting: connecting, sections: sections)
    }

    private var groups: [DeviceGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? groupStore.groups : groupStore.groups.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var hasAnyContent: Bool {
        !connectionManager.deviceStore.records.isEmpty || !groupStore.groups.isEmpty
    }

    var body: some View {
        let snap = snapshot()
        let sections = snap.sections
        List {
            selfRow
            if !hasAnyContent {
                emptyState
            } else if sections.connected.isEmpty && sections.friends.isEmpty && groups.isEmpty && !query.isEmpty {
                Text("No results")
                    .foregroundStyle(paper(.datePillText))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
            if !sections.connected.isEmpty {
                Section {
                    ForEach(sections.connected) { record in
                        connectedRow(record)
                    }
                } header: { Text("Connected \(sections.connected.count)") }
            }
            if !sections.friends.isEmpty {
                Section {
                    ForEach(sections.friends) { record in
                        friendRow(record, snap)
                    }
                } header: { Text("Friends \(sections.friends.count)") }
            }
            if hasAnyContent {
                groupsSection
            }
            inviteSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(paper(.background).ignoresSafeArea())
        .paperMode(.live)
        .navigationTitle("Home")
        .searchable(text: $query, prompt: Text("Search friends"))
        .toolbar { toolbarContent }
        .sheet(isPresented: $showGroupEditor) { GroupEditorView(groupStore: groupStore) }
        #if os(iOS)
        .sheet(isPresented: $showProfile) { UserProfileView() }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(connectionManager) }
        .navigationDestination(isPresented: $showConnection) { ConnectionView().environmentObject(connectionManager) }
        #endif
        .chatTargetDestination()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: onAddFriend) { Image(systemName: "person.badge.plus") }
                .accessibilityLabel(Text("Add friend"))
        }
        #if os(iOS)
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(Text("Settings"))
        }
        #endif
    }

    // MARK: - Rows

    private var selfRow: some View {
        let name = connectionManager.localIdentity.displayName
        let content = selfRowContent(name)
        #if os(iOS)
        return Button { showProfile = true } label: { content }
            .buttonStyle(.plain)
            .listRowBackground(paper(.incomingBubble))
        #else
        return content.listRowBackground(paper(.incomingBubble))
        #endif
    }

    private func selfRowContent(_ name: String) -> some View {
        HStack(spacing: 12) {
                PeerAvatar(name: name, size: 44)
                Text(name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(paper(.incomingText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func peerID(for record: DeviceRecord) -> String {
        connectionManager.connection(for: record.id)?.peerIdentity.id ?? record.id
    }

    private func connectedRow(_ record: DeviceRecord) -> some View {
        Button {
            #if os(iOS)
            connectionManager.focus(on: connectionManager.connection(for: record.id)?.id ?? record.id)
            showConnection = true
            #else
            openWindow(id: "chat", value: peerID(for: record))
            #endif
        } label: {
            FriendRow(record: record, presence: .online, connection: connectionManager.connection(for: record.id))
        }
        .buttonStyle(.plain)
        .listRowBackground(paper(.incomingBubble))
        // Swiping a connected row disconnects; forgetting the device is a second, non-default action.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                let id = connectionManager.connection(for: record.id)?.id ?? record.id
                Task { await connectionManager.disconnect(from: id) }
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
            }
            .tint(.orange)
            forgetButton(record)
        }
    }

    @ViewBuilder
    private func friendRow(_ record: DeviceRecord, _ snap: Snapshot) -> some View {
        let presence = snap.presence[record.id] ?? .offline
        let isConnecting = snap.connecting.contains(record.id)
        let connect: () -> Void = { _ = connectionManager.reconnect(to: record.id) }
        #if os(iOS)
        NavigationLink(value: ChatTarget(peerID: peerID(for: record), name: record.displayName)) {
            FriendRow(record: record, presence: presence, isConnecting: isConnecting, onConnect: connect)
        }
        .listRowBackground(paper(.incomingBubble))
        .swipeActions(edge: .trailing) { forgetButton(record) }
        #else
        Button {
            openWindow(id: "chat", value: peerID(for: record))
        } label: {
            FriendRow(record: record, presence: presence, isConnecting: isConnecting, onConnect: connect)
        }
        .buttonStyle(.plain)
        .listRowBackground(paper(.incomingBubble))
        .swipeActions(edge: .trailing) { forgetButton(record) }
        #endif
    }

    private func forgetButton(_ record: DeviceRecord) -> some View {
        Button(role: .destructive) {
            connectionManager.forgetDevice(id: record.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Groups / invite / empty

    private var groupsSection: some View {
        Section {
            ForEach(groups) { group in
                NavigationLink(destination: GroupDetailView(group: group)) {
                    GroupRow(group: group)
                }
                .listRowBackground(paper(.incomingBubble))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { groupStore.remove(id: group.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Button { showGroupEditor = true } label: {
                Label("New Group", systemImage: "plus.circle.fill")
                    .foregroundStyle(paper(.brand))
            }
            .listRowBackground(paper(.incomingBubble))
            .accessibilityHint(Text("Creates a new device group"))
        } header: { Text("Groups") }
    }

    private var inviteSection: some View {
        Section {
            ShareLink(item: Self.inviteURL) {
                Label("Invite friends to PeerDrop", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(paper(.brand))
            }
            .listRowBackground(paper(.incomingBubble))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 40))
                .foregroundStyle(paper(.datePillText))
                .accessibilityHidden(true)
            Text("No friends yet")
                .font(.headline)
                .foregroundStyle(paper(.incomingText))
            Text("Friends you connect with will show up here.")
                .font(.subheadline)
                .foregroundStyle(paper(.datePillText))
                .multilineTextAlignment(.center)
            Button(action: onAddFriend) {
                Text("Find nearby friends")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(paper(.brand)))
            }
            .buttonStyle(.borderless)
            Button { showGroupEditor = true } label: {
                Label("New Group", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(paper(.brand))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
