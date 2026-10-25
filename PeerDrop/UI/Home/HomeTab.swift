import SwiftUI
import PeerDropCore

/// 主頁: self row, connected / categories / friends (uncategorized), contacts, invite. Uses the `.live` look.
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
    /// Verified-bound record ids, refreshed on change signals (never recomputed per row).
    @StateObject private var bound = BoundFriendsModel()
    /// Mirrors `categoryStore.categories` so a category change re-renders Home.
    @State private var categories: [FriendCategory] = []
    /// The "New category" row is an inline text field while true.
    @State private var creatingCategory = false
    /// Friend whose "Move to category…" sheet is open.
    @State private var moveTarget: CategoryMoveTarget?
    #if os(macOS)
    @State private var openCategoryID: String?
    @State private var showCategory = false
    #endif
    /// Friend whose "Always connected" sheet is open (Project E).
    @State private var alwaysConnectedTarget: AlwaysConnectedTarget?
    #if os(iOS)
    @State private var showProfile = false
    @State private var showSettings = false
    @State private var isSearching = false
    @State private var collapsed: Set<String> = []
    @StateObject private var contacts = ContactsInviteModel()
    @State private var inviting: ContactsInviteModel.Entry?
    @State private var shareInvite: ContactsInviteModel.Entry?
    @FocusState private var searchFocused: Bool
    #endif

    private static let inviteURL = URL(string: "https://apps.apple.com/app/id6759594513")!

    private var categoryStore: FriendCategoryStore { connectionManager.categoryStore }

    /// Presence is resolved once per body update from a single `presenceSources()` snapshot.
    private struct Snapshot {
        let presence: [String: PeerPresence]
        let connecting: Set<String>
        let sections: HomeListLogic.HomeSections
        /// Records whose friend has a VERIFIED notes binding (offline thread still accepts notes).
        let notesReachable: Set<String>
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
        // Membership is checked across every alias of a friend, so two records of one person share a category.
        let assignment = HomeListLogic.categoryIDs(for: records, categories: categories,
                                                   aliases: { connectionManager.notificationAliasIDs(for: [$0.id]) })
        let sections = HomeListLogic.homeSections(records: records, presence: { map[$0.id] ?? .offline }, query: query,
                                                  name: { connectionManager.displayName(for: $0) },
                                                  categories: categories, categoryID: { assignment[$0.id] })
        return Snapshot(presence: map, connecting: connecting, sections: sections, notesReachable: bound.reachableRecordIDs)
    }

    private var hasAnyContent: Bool {
        !connectionManager.deviceStore.records.isEmpty || !categories.isEmpty
    }

    private var rowBackground: Color {
        #if os(iOS)
        return .clear      // flat rows on the page, like a messenger friends list
        #else
        return paper(.incomingBubble)
        #endif
    }

    var body: some View {
        let snap = snapshot()
        #if os(iOS)
        VStack(spacing: 0) {
            header
            if isSearching { searchField }
            friendsList(snap)
        }
        .background(paper(.background).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .paperMode(.live)
        .categorySheets(store: categoryStore, moveTarget: $moveTarget)
        .sheet(item: $alwaysConnectedTarget) { target in
            AlwaysConnectedFriendSheet(peerID: target.peerID, name: target.name)
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showProfile) { UserProfileView() }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(connectionManager) }
        .sheet(item: $inviting) { entry in
            InviteComposer(recipient: entry.phone) { inviting = nil }
                .ignoresSafeArea()
        }
        .sheet(item: $shareInvite) { _ in ShareSheet(items: [InviteMessage.body()]) }
        .chatTargetDestination()
        .navigationDestination(for: CategoryRoute.self) { route in
            CategoryDetailView(store: categoryStore, categoryID: route.id)
        }
        .onReceive(categoryStore.$categories) { categories = $0 }
        .onAppear { bound.bind(connectionManager); contacts.refresh(); if contacts.canAsk { contacts.requestAccess() } }
        #else
        friendsList(snap)
            .navigationTitle("Home")
            .searchable(text: $query, prompt: Text("Search friends"))
            .toolbar { toolbarContent }
            .categorySheets(store: categoryStore, moveTarget: $moveTarget)
            .sheet(item: $alwaysConnectedTarget) { target in
                AlwaysConnectedFriendSheet(peerID: target.peerID, name: target.name)
                    .environmentObject(connectionManager)
            }
            .chatTargetDestination()
            .navigationDestination(isPresented: $showCategory) {
                if let id = openCategoryID { CategoryDetailView(store: categoryStore, categoryID: id) }
            }
            .onReceive(categoryStore.$categories) { categories = $0 }
            .onAppear { bound.bind(connectionManager) }
        #endif
    }

    private func friendsList(_ snap: Snapshot) -> some View {
        let sections = snap.sections
        return List {
            selfRow
            if !hasAnyContent {
                emptyState
            } else if sections.connected.isEmpty && sections.friends.isEmpty && sections.categories.isEmpty && !query.isEmpty {
                Text("No results")
                    .foregroundStyle(paper(.datePillText))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
            if !sections.connected.isEmpty {
                section("connected", title: Text("Connected \(sections.connected.count)")) {
                    ForEach(sections.connected) { record in connectedRow(record) }
                }
            }
            if hasAnyContent && (query.isEmpty || !sections.categories.isEmpty) {
                categoriesSection(sections.categories)
            }
            if !sections.friends.isEmpty {
                section("friends", title: Text("Friends \(sections.friends.count)")) {
                    ForEach(sections.friends) { record in friendRow(record, snap) }
                }
            }
            #if os(iOS)
            contactsSection
            #endif
            inviteSection
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .scrollContentBackground(.hidden)
        .background(paper(.background).ignoresSafeArea())
        .paperMode(.live)
    }

    /// A list section whose header collapses it (messenger style) on iOS; the plain grouped section on Mac.
    @ViewBuilder
    private func section<Content: View>(_ key: String, title: Text, @ViewBuilder content: () -> Content) -> some View {
        #if os(iOS)
        Section {
            if !collapsed.contains(key) { content() }
        } header: {
            collapsibleHeader(key, title: title)
        }
        #else
        Section { content() } header: { title }
        #endif
    }

    #if os(iOS)
    // MARK: - Messenger-style header, search, sections, contacts

    private var header: some View {
        HStack(spacing: 18) {
            Text("Home")
                .font(.title2.weight(.bold))
                .foregroundStyle(paper(.incomingText))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                isSearching.toggle()
                if isSearching { searchFocused = true } else { query = "" }
            } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel(Text("Search friends"))
            Button(action: onAddFriend) { Image(systemName: "person.badge.plus") }
                .accessibilityLabel(Text("Add friend"))
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(Text("Settings"))
        }
        .font(.title3)
        .foregroundStyle(paper(.incomingText))
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(paper(.datePillText))
            TextField(text: $query) { Text("Search friends") }
                .focused($searchFocused)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(paper(.datePillText)) }
                    .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(paper(.incomingBubble)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func collapsibleHeader(_ key: String, title: Text) -> some View {
        let isCollapsed = collapsed.contains(key)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
            }
        } label: {
            HStack {
                title
                    .font(.footnote)
                    .foregroundStyle(paper(.datePillText))
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(paper(.datePillText))
                    .rotationEffect(.degrees(isCollapsed ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityHint(Text(isCollapsed ? "Expand section" : "Collapse section"))
    }

    /// Phone contacts, laid out like a messenger's "contact friends": a section whose first row invites
    /// someone by link, then every contact with an Invite button. Access is asked for once, the first
    /// time Home appears; if it is declined the section says how to turn it on.
    @ViewBuilder
    private var contactsSection: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = q.isEmpty ? contacts.entries : contacts.entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let title: Text = contacts.canList ? Text("Contacts \(shown.count)") : Text("Contacts")
        section("contacts", title: title) {
            if q.isEmpty { inviteByLinkRow }
            if contacts.canList {
                ForEach(shown) { entry in contactRow(entry) }
            } else if !contacts.canAsk && q.isEmpty {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.title3)
                            .foregroundStyle(paper(.brand))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow contacts access to invite friends")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(paper(.incomingText))
                            Text("Your contacts stay on this phone and are never uploaded.")
                                .font(.caption)
                                .foregroundStyle(paper(.datePillText))
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
                .accessibilityIdentifier("contacts-allow-row")
            }
        }
    }

    private var inviteByLinkRow: some View {
        ShareLink(item: Self.inviteURL) {
            HStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(paper(.incomingText).opacity(0.85)))
                    .accessibilityHidden(true)
                Text("Invite friends to PeerDrop")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(paper(.incomingText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(paper(.datePillText))
                    .accessibilityHidden(true)
            }
        }
        .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        .accessibilityIdentifier("invite-by-link-row")
    }

    private func contactRow(_ entry: ContactsInviteModel.Entry) -> some View {
        HStack(spacing: 12) {
            PeerAvatar(name: entry.name, size: 44)
                .accessibilityHidden(true)
            Text(verbatim: entry.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(paper(.incomingText))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if InviteComposer.canCompose, entry.phone != nil { inviting = entry } else { shareInvite = entry }
            } label: {
                Text("Invite")
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(paper(.datePillText).opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(paper(.incomingText))
            .accessibilityLabel(Text("Invite \(entry.name)"))
        }
        .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        .accessibilityIdentifier("contact-row")
    }
    #endif

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
            .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        #else
        return content.listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        #endif
    }

    private var selfAvatarSize: CGFloat {
        #if os(iOS)
        return 58
        #else
        return 44
        #endif
    }

    private func selfRowContent(_ name: String) -> some View {
        HStack(spacing: 14) {
                PeerAvatar(name: name, size: selfAvatarSize)
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
        connectionManager.chatKey(forRecord: record)
    }

    /// A verified cross-network ("always connected") friend: no manual disconnect (it would just reconnect),
    /// no ConnectionView (file transfer / calls are not offered over it).
    private func isCrossNetwork(_ record: DeviceRecord) -> Bool {
        connectionManager.connection(for: record)?.isRendezvousConnection == true
    }

    private func alwaysConnectedTarget(for record: DeviceRecord) -> AlwaysConnectedTarget {
        AlwaysConnectedTarget(peerID: peerID(for: record), name: connectionManager.displayName(for: record))
    }

    @ViewBuilder
    private func connectedRow(_ record: DeviceRecord) -> some View {
        if isCrossNetwork(record) {
            crossNetworkRow(record)
        } else {
            directConnectedRow(record)
        }
    }

    @ViewBuilder
    private func crossNetworkRow(_ record: DeviceRecord) -> some View {
        let row = FriendRow(record: record, name: connectionManager.displayName(for: record), presence: .online,
                            connection: connectionManager.connection(for: record))
        #if os(iOS)
        NavigationLink(value: ChatTarget(peerID: peerID(for: record), name: connectionManager.displayName(for: record))) { row }
            .accessibilityIdentifier("active-peer-row")
            .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
            .friendEntries(open: { alwaysConnectedTarget = $0 }, target: alwaysConnectedTarget(for: record), tint: paper(.brand),
                           moveToCategory: { moveTarget = moveTarget(for: record) })
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { forgetButton(record); moveButton(record) }
        #else
        Button { openWindow(id: "chat", value: peerID(for: record)) } label: { row }
            .buttonStyle(.plain)
            .accessibilityIdentifier("active-peer-row")
            .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
            .friendEntries(open: { alwaysConnectedTarget = $0 }, target: alwaysConnectedTarget(for: record), tint: paper(.brand),
                           moveToCategory: { moveTarget = moveTarget(for: record) })
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { forgetButton(record); moveButton(record) }
        #endif
    }

    @ViewBuilder
    private func directConnectedRow(_ record: DeviceRecord) -> some View {
        let row = FriendRow(record: record, name: connectionManager.displayName(for: record), presence: .online,
                            connection: connectionManager.connection(for: record))
        #if os(iOS)
        // A connected friend opens straight into the chat; files and calls live there.
        NavigationLink(value: ChatTarget(peerID: peerID(for: record), name: connectionManager.displayName(for: record))) { row }
            .accessibilityIdentifier("active-peer-row")
            .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
            .friendEntries(open: { alwaysConnectedTarget = $0 }, target: alwaysConnectedTarget(for: record), tint: paper(.brand),
                           moveToCategory: { moveTarget = moveTarget(for: record) })
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { disconnectAndForget(record); moveButton(record) }
        #else
        Button { openWindow(id: "chat", value: peerID(for: record)) } label: { row }
        .buttonStyle(.plain)
        .accessibilityIdentifier("active-peer-row")
        .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        .friendEntries(open: { alwaysConnectedTarget = $0 }, target: alwaysConnectedTarget(for: record), tint: paper(.brand),
                           moveToCategory: { moveTarget = moveTarget(for: record) })
        // Swiping a connected row disconnects; forgetting the device is a second, non-default action.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { disconnectAndForget(record); moveButton(record) }
        #endif
    }

    @ViewBuilder
    private func disconnectAndForget(_ record: DeviceRecord) -> some View {
        Button {
            let id = connectionManager.connection(for: record)?.id ?? record.id
            Task { await connectionManager.disconnect(from: id) }
        } label: {
            Label("Disconnect", systemImage: "xmark.circle.fill")
        }
        .tint(.orange)
        forgetButton(record)
    }

    @ViewBuilder
    private func friendRow(_ record: DeviceRecord, _ snap: Snapshot) -> some View {
        let presence = snap.presence[record.id] ?? .offline
        let isConnecting = snap.connecting.contains(record.id)
        let reachable = snap.notesReachable.contains(record.id)
        let connect: () -> Void = { _ = connectionManager.reconnect(to: record.id) }
        #if os(iOS)
        NavigationLink(value: ChatTarget(peerID: peerID(for: record), name: connectionManager.displayName(for: record))) {
            FriendRow(record: record, name: connectionManager.displayName(for: record), presence: presence, notesReachable: reachable, isConnecting: isConnecting, onConnect: connect,
                      categoryName: snap.sections.friendCategoryNames[record.id])
        }
        .accessibilityIdentifier("saved-device-row")
        .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        .friendEntries(open: { alwaysConnectedTarget = $0 }, target: alwaysConnectedTarget(for: record), tint: paper(.brand),
                           moveToCategory: { moveTarget = moveTarget(for: record) })
        .swipeActions(edge: .trailing) { forgetButton(record); moveButton(record) }
        #else
        Button {
            openWindow(id: "chat", value: peerID(for: record))
        } label: {
            FriendRow(record: record, name: connectionManager.displayName(for: record), presence: presence, notesReachable: reachable, isConnecting: isConnecting, onConnect: connect,
                      categoryName: snap.sections.friendCategoryNames[record.id])
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("saved-device-row")
        .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        .friendEntries(open: { alwaysConnectedTarget = $0 }, target: alwaysConnectedTarget(for: record), tint: paper(.brand),
                           moveToCategory: { moveTarget = moveTarget(for: record) })
        .swipeActions(edge: .trailing) { forgetButton(record); moveButton(record) }
        #endif
    }

    private func forgetButton(_ record: DeviceRecord) -> some View {
        Button(role: .destructive) {
            connectionManager.forgetDevice(id: record.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Categories / invite / empty

    /// 分類: one row per category (name, count, bell-slash when muted) pushing its page, then "New category".
    /// Shown even with no categories, so the first one can be made from here.
    private func categoriesSection(_ rows: [HomeListLogic.CategorySection]) -> some View {
        section("categories", title: Text("Categories")) {
            ForEach(rows) { row in categoryRow(row) }
            if query.isEmpty && categories.count < FriendCategoryStore.maxCategories {
                newCategoryRow
                    .listRowBackground(rowBackground)
                    .listRowSeparator(.hidden)
            }
        }
    }

    /// "New category": tapping turns the row into a text field; Return creates, anything else restores the row.
    @ViewBuilder
    private var newCategoryRow: some View {
        let icon = Image(systemName: "folder.badge.plus")
            .font(.title3)
            .foregroundStyle(paper(.brand))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
        if creatingCategory {
            HStack(spacing: 12) {
                icon
                InlineCategoryNameField(onCommit: { name in
                    categoryStore.create(name: name)
                    creatingCategory = false
                }, onCancel: { creatingCategory = false })
            }
        } else {
            Button { creatingCategory = true } label: {
                HStack(spacing: 12) {
                    icon
                    Text("New category")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(paper(.brand))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("category-add")
        }
    }

    @ViewBuilder
    private func categoryRow(_ row: HomeListLogic.CategorySection) -> some View {
        #if os(iOS)
        NavigationLink(value: CategoryRoute(id: row.id)) {
            CategoryRow(name: row.category.name, count: row.count, notificationsEnabled: row.category.notificationsEnabled,
                        presence: row.category.presence, hiddenNow: row.category.isHiddenNow())
        }
        .accessibilityIdentifier("category-row")
        .listRowBackground(rowBackground)
        .listRowSeparator(.hidden)
        #else
        Button {
            openCategoryID = row.id
            showCategory = true
        } label: {
            CategoryRow(name: row.category.name, count: row.count, notificationsEnabled: row.category.notificationsEnabled,
                        presence: row.category.presence, hiddenNow: row.category.isHiddenNow(), showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-row")
        .listRowBackground(rowBackground)
        .listRowSeparator(.hidden)
        #endif
    }

    private func moveTarget(for record: DeviceRecord) -> CategoryMoveTarget {
        CategoryMoveTarget(recordID: record.id, name: connectionManager.displayName(for: record),
                           person: connectionManager.notificationAliasIDs(for: [record.id]))
    }

    private func moveButton(_ record: DeviceRecord) -> some View {
        Button { moveTarget = moveTarget(for: record) } label: {
            Label("Move to category…", systemImage: "folder")
        }
        .tint(.indigo)
    }

    @ViewBuilder
    private var inviteSection: some View {
        #if os(macOS)
        Section {
            ShareLink(item: Self.inviteURL) {
                Label("Invite friends to PeerDrop", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(paper(.brand))
            }
            .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        }
        #endif
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// Entry points from a friend row: the long-press / right-click menu holds "Always connected" and
/// "Move to category…"; a leading swipe opens "Always connected" (the trailing swipe carries the move);
/// both are VoiceOver custom actions too (reachable without gestures; the Mac menu is keyboard-reachable).
private extension View {
    func friendEntries(open: @escaping (AlwaysConnectedTarget) -> Void, target: AlwaysConnectedTarget, tint: Color,
                       moveToCategory: @escaping () -> Void) -> some View {
        self
            .contextMenu {
                Button { open(target) } label: {
                    Label(LocalizedStringKey(AlwaysConnectedPresentation.titleKey), systemImage: "dot.radiowaves.left.and.right")
                }
                Button(action: moveToCategory) {
                    Label("Move to category…", systemImage: "folder")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { open(target) } label: {
                    Label(LocalizedStringKey(AlwaysConnectedPresentation.titleKey), systemImage: "dot.radiowaves.left.and.right")
                }
                .tint(tint)
            }
            .accessibilityAction(named: Text(LocalizedStringKey(AlwaysConnectedPresentation.titleKey))) { open(target) }
            .accessibilityAction(named: Text("Move to category…"), moveToCategory)
    }

    /// The "Move to category…" sheet, shared by both platforms.
    func categorySheets(store: FriendCategoryStore, moveTarget: Binding<CategoryMoveTarget?>) -> some View {
        self
            .sheet(item: moveTarget) { target in
                MoveToCategorySheet(store: store, target: target)
            }
    }
}
