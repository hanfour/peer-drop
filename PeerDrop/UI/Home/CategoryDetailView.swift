import Combine
import SwiftUI
import PeerDropCore

/// A category's page (pushed from Home on both platforms): name (rename), notifications switch,
/// "Connect All", the member list (tap opens the chat, swipe/menu removes from the category),
/// "Add friends", and delete (members go back to the uncategorized Friends section).
/// Project F2: what friends in this category see (online / offline / scheduled) and the status message
/// live in `CategoryStatusSection`; while the category hides us, "Connect All" is disabled.
struct CategoryDetailView: View, PaperThemed {
    @EnvironmentObject var connectionManager: ConnectionManager
    @ObservedObject var store: FriendCategoryStore
    let categoryID: String
    var paperMode: PaperMode { .live }
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var renaming = false
    @State private var addingFriends = false
    @State private var confirmDelete = false
    @State private var isConnecting = false
    /// Bumped whenever the device records change (e.g. a member was forgotten), so the member list re-renders.
    @State private var recordsVersion = 0
    /// Re-evaluated every 30 s so a schedule boundary updates "Connect All" and the status section.
    @State private var now = Date()
    /// Held outside `body` so a redraw doesn't build and restart a new timer.
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var category: FriendCategory? { store.categories.first { $0.id == categoryID } }

    private struct Member {
        let record: DeviceRecord
        let presence: PeerPresence
        let isConnecting: Bool
    }

    private func members(of category: FriendCategory) -> [Member] {
        let records = connectionManager.deviceStore.records
        let assignment = HomeListLogic.categoryIDs(for: records, categories: store.categories,
                                                   aliases: { connectionManager.notificationAliasIDs(for: [$0.id]) })
        let sections = HomeListLogic.homeSections(records: records, presence: { _ in .offline }, query: "",
                                                  name: { connectionManager.displayName(for: $0) },
                                                  categories: [category], categoryID: { assignment[$0.id] })
        let sources = connectionManager.presenceSources()
        return (sections.categories.first?.members ?? []).map { r in
            let p = connectionManager.presence(for: r, sources: sources)
            var ids: Set<String> = [r.id]
            if let a = r.peerDeviceId { ids.insert(a) }
            return Member(record: r, presence: p, isConnecting: p != .online && !ids.isDisjoint(with: sources.connecting))
        }
    }

    var body: some View {
        Group {
            let _ = recordsVersion
            if let category {
                content(category, members: members(of: category))
            } else {
                Color.clear
            }
        }
        .background(paper(.background).ignoresSafeArea())
        .paperMode(.live)
        .onChange(of: category == nil) { gone in if gone { dismiss() } }
        .onReceive(connectionManager.deviceStore.$records.dropFirst()) { _ in recordsVersion &+= 1 }
        .onReceive(ticker) { now = $0 }
    }

    private func content(_ category: FriendCategory, members: [Member]) -> some View {
        let hiddenNow = category.isHiddenNow(at: now)
        return List {
            Section {
                if renaming {
                    InlineCategoryNameField(initial: category.name, onCommit: { name in
                        store.rename(id: category.id, to: name)
                        renaming = false
                    }, onCancel: { renaming = false })
                } else {
                    Button { renaming = true } label: {
                        HStack {
                            Text("Name")
                                .foregroundStyle(paper(.incomingText))
                            Spacer()
                            Text(verbatim: category.name)
                                .foregroundStyle(paper(.datePillText))
                                .lineLimit(1)
                            Image(systemName: "pencil")
                                .foregroundStyle(paper(.datePillText))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Category name"))
                    .accessibilityValue(Text(verbatim: category.name))
                    .accessibilityHint(Text("Rename category"))
                    .accessibilityIdentifier("category-rename")
                }
                Toggle(isOn: Binding(get: { category.notificationsEnabled },
                                     set: { store.setNotificationsEnabled($0, for: category.id) })) {
                    Label("Notifications", systemImage: category.notificationsEnabled ? "bell" : "bell.slash")
                        .foregroundStyle(paper(.incomingText))
                }
                .tint(paper(.brand))
                .accessibilityIdentifier("category-notifications-toggle")
            }
            .listRowBackground(paper(.incomingBubble))

            CategoryStatusSection(store: store, category: category, hiddenNow: hiddenNow)

            Section {
                let notOnline = members.filter { $0.presence != .online }.map(\.record.id)
                Button { connectAll(category, ids: notOnline) } label: {
                    HStack {
                        Label("Connect All", systemImage: "link.badge.plus")
                            .foregroundStyle(paper(.brand))
                        Spacer()
                        if isConnecting { ProgressView().controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(notOnline.isEmpty || isConnecting || hiddenNow)
                .accessibilityIdentifier("category-connect-all")

                ForEach(members, id: \.record.id) { member in memberRow(member) }

                Button { addingFriends = true } label: {
                    Label("Add friends", systemImage: "person.badge.plus")
                        .foregroundStyle(paper(.brand))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("category-add-friends")
            } header: {
                Text("Members")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if hiddenNow { Text("Friends in this category see you as offline right now.") }
                    if members.isEmpty { Text("No friends in this category yet.") }
                }
            }
            .listRowBackground(paper(.incomingBubble))

            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete category", systemImage: "trash")
                }
                .accessibilityIdentifier("category-delete")
            }
            .listRowBackground(paper(.incomingBubble))
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(verbatim: category.name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $addingFriends) {
            CategoryAddFriendsSheet(store: store, categoryID: category.id)
                .environmentObject(connectionManager)
        }
        .confirmationDialog(Text("Delete this category?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete category", role: .destructive) { store.delete(id: category.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Friends in this category return to Friends.")
        }
    }

    @ViewBuilder
    private func memberRow(_ member: Member) -> some View {
        let record = member.record
        let name = connectionManager.displayName(for: record)
        let row = FriendRow(record: record, name: name, presence: member.presence, isConnecting: member.isConnecting,
                            onConnect: { _ = connectionManager.reconnect(to: record.id) })
        let remove = { store.move(person: connectionManager.notificationAliasIDs(for: [record.id]), record: record.id, to: nil) }
        #if os(iOS)
        NavigationLink(value: ChatTarget(peerID: connectionManager.chatKey(forRecord: record), name: name)) { row }
            .accessibilityIdentifier("category-member-row")
            .categoryMemberActions(remove: remove)
        #else
        Button { openWindow(id: "chat", value: connectionManager.chatKey(forRecord: record)) } label: { row }
            .buttonStyle(.plain)
            .accessibilityIdentifier("category-member-row")
            .categoryMemberActions(remove: remove)
        #endif
    }

    /// Same behaviour as the retired group page's "Connect All": dial every member that is not online
    /// through the existing group-connect path (discovered peers, else a stored address).
    private func connectAll(_ category: FriendCategory, ids: [String]) {
        isConnecting = true
        connectionManager.connectToGroup(DeviceGroup(id: category.id, name: category.name, deviceIDs: ids))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isConnecting = false }
    }
}

private extension View {
    /// "Remove from category" from a trailing swipe, the long-press / right-click menu and VoiceOver.
    func categoryMemberActions(remove: @escaping () -> Void) -> some View {
        self
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: remove) {
                    Label("Remove from category", systemImage: "folder.badge.minus")
                }
            }
            .contextMenu {
                Button(action: remove) { Label("Remove from category", systemImage: "folder.badge.minus") }
            }
            .accessibilityAction(named: Text("Remove from category"), remove)
    }
}

/// "Add friends" on a category page: every friend not yet in this category; a friend already in
/// another category shows which one. Picking a friend moves them here (out of any other category).
struct CategoryAddFriendsSheet: View, PaperThemed {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FriendCategoryStore
    let categoryID: String
    var paperMode: PaperMode { .live }

    var body: some View {
        let records = connectionManager.deviceStore.records
        let assignment = HomeListLogic.categoryIDs(for: records, categories: store.categories,
                                                   aliases: { connectionManager.notificationAliasIDs(for: [$0.id]) })
        let names = Dictionary(store.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let candidates = records
            .filter { assignment[$0.id] != categoryID }
            .sorted { connectionManager.displayName(for: $0).localizedCaseInsensitiveCompare(connectionManager.displayName(for: $1)) == .orderedAscending }
        return NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("No friends yet")
                        .foregroundStyle(paper(.datePillText))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
                ForEach(candidates) { record in
                    let current = assignment[record.id].flatMap { names[$0] }
                    Button {
                        store.move(person: connectionManager.notificationAliasIDs(for: [record.id]), record: record.id, to: categoryID)
                    } label: {
                        HStack(spacing: 12) {
                            PeerAvatar(name: connectionManager.displayName(for: record), size: 44).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: connectionManager.displayName(for: record))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(paper(.incomingText))
                                    .lineLimit(1)
                                if let current {
                                    Label { Text(verbatim: current) } icon: { Image(systemName: "folder") }
                                        .font(.caption)
                                        .foregroundStyle(paper(.datePillText))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "plus.circle")
                                .foregroundStyle(paper(.brand))
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(paper(.incomingBubble))
                    .accessibilityIdentifier("category-add-friend-row")
                }
            }
            .scrollContentBackground(.hidden)
            .background(paper(.background).ignoresSafeArea())
            .navigationTitle("Add friends")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .paperMode(.live)
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 360)
        #endif
    }
}
