import SwiftUI
import Combine
import PeerDropCore
import PeerDropNotes

/// 紙條: first-row notes inbox + conversation list (friends and groups with messages, newest first).
/// Expects to be hosted in a NavigationStack that the container owns. Chats are pushed through
/// `isPresented` destinations here (no `ChatTarget` value is pushed), so no `.chatTargetDestination()`.
/// The inbox row (first row of the list) pushes the injected `inbox` view (Task 9 wires NotesInboxView).
struct ConversationsTab<Inbox: View>: View, PaperThemed {
    @EnvironmentObject var connectionManager: ConnectionManager
    var paperMode: PaperMode { .live }
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// Number of unread remote notes, shown on the inbox row.
    var inboxUnread: Int = 0
    /// Switches to the Home tab (empty-state button; provided by the container).
    var onGoHome: () -> Void = {}
    /// Pending inbox-push requests from the container (notification deep link). Consumed (reset to 0)
    /// here, so a rebuilt view (Mac sidebar switch) never replays an already handled request.
    @Binding var inboxRequest: Int
    /// `DeviceRecord.id` of a friend whose thread should open (note deep link for a bound friend).
    /// Consumed (reset to nil) here, like `inboxRequest`.
    @Binding var threadRequest: ThreadRequest?
    /// Called when the requested friend vanished: the container shows the tapped note directly.
    var onThreadUnavailable: (String?) -> Void = { _ in }
    @ViewBuilder var inbox: () -> Inbox
    @State private var showInbox = false
    @State private var pickedGroup: DeviceGroup?
    @State private var showGroup = false

    @State private var query = ""
    @StateObject private var hub = RefreshHub()
    @State private var showPicker = false
    /// Last-message summaries, rebuilt on appear and (debounced) on change signals — never inside `body`.
    @State private var peerSummaries: [String: ConversationSummary] = [:]
    @State private var groupSummaries: [String: ConversationSummary] = [:]
    /// Records with a verified notes binding, computed with the summaries (never per row).
    @State private var reachableRecordIDs: Set<String> = []
    /// False until the first synchronous seed, so the empty state never flashes.
    @State private var hasLoaded = false
    /// Refresh work only runs while this list is on screen (a chat pushed on top must not trigger decrypts).
    @State private var refreshGate = ConversationsRefreshGate()
    #if os(iOS)
    @State private var pickedTarget: ChatTarget?
    @State private var showPicked = false
    /// Chosen in the picker sheet; pushed from the sheet's onDismiss.
    @State private var pendingTarget: ChatTarget?
    #endif

    private var chatManager: ChatManager { connectionManager.chatManager }

    /// Chat files are keyed by the live peer id when connected, else the record id (same rule as HomeTab).
    private func chatKey(for recordID: String) -> String {
        guard let record = connectionManager.deviceStore.records.first(where: { $0.id == recordID }) else { return recordID }
        return connectionManager.chatKey(forRecord: record)
    }

    private func refreshSummaries() {
        let peers: [String: ConversationSummary]
        let notesStore = connectionManager.notesStore
        // account -> record (first record wins), inverted: each account folds into exactly one row.
        var accountForRecord: [String: String] = [:]
        for (account, record) in BoundFriends.recordIDByAccount(connectionManager) { accountForRecord[record] = account }
        peers = ConversationsLogic.foldPeers(
            recordIDs: connectionManager.deviceStore.records.map(\.id),
            chatKey: { chatKey(for: $0) },
            base: { chatManager.summary(forPeer: $0) },
            accountForRecord: accountForRecord,
            notes: { notesStore.notes(forAccount: $0) },
            noteUnread: { notesStore.unreadCount(forAccount: $0) })
        var groups: [String: ConversationSummary] = [:]
        for g in connectionManager.groupStore.groups {
            groups[g.id] = chatManager.summary(forGroup: g.id)
        }
        let reachable = Set(accountForRecord.keys)
        if reachable != reachableRecordIDs { reachableRecordIDs = reachable }
        if peers != peerSummaries { peerSummaries = peers }
        if groups != groupSummaries { groupSummaries = groups }
        hasLoaded = true
    }

    /// Single entry point for opening a friend's chat (row tap and picker); resolves the chat key at call time.
    private func openChat(recordID: String, name: String) {
        let id = chatKey(for: recordID)
        #if os(iOS)
        pickedTarget = ChatTarget(peerID: id, name: name)
        showPicked = true
        #else
        openWindow(id: "chat", value: id)
        #endif
    }

    /// Builds the throttled change pipeline once (leading + trailing, so the last change always lands).
    private func bindRefreshHub() {
        hub.bind(RefreshHub.pipeline([
            connectionManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            chatManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            connectionManager.deviceStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            connectionManager.groupStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            connectionManager.notesStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            connectionManager.trustedContactStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ])) {
            if refreshGate.shouldRefreshOnChange { refreshSummaries() }
        }
    }

    private func rows() -> [ConversationRowModel] {
        ConversationsLogic.rows(
            records: connectionManager.deviceStore.records,
            groups: connectionManager.groupStore.groups,
            summaryForPeer: { peerSummaries[$0] ?? ConversationSummary(id: $0, isGroup: false, lastMessage: nil, unread: 0) },
            summaryForGroup: { groupSummaries[$0] ?? ConversationSummary(id: $0, isGroup: true, lastMessage: nil, unread: 0) },
            query: query,
            name: { connectionManager.displayName(for: $0) })
    }

    var body: some View {
        // Presence resolved once per body from a single snapshot.
        let sources = connectionManager.presenceSources()
        let records = connectionManager.deviceStore.records
        var presenceMap: [String: PeerPresence] = [:]
        for r in records { presenceMap[r.id] = connectionManager.presence(for: r, sources: sources) }
        let rowModels = hasLoaded ? rows() : []
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return List {
            if rowModels.isEmpty {
                // Own section: a transparent empty-state row in the same section
                // leaves the inbox card with a squared-off bottom edge.
                Section { inboxRow }
                Section {
                    if !hasLoaded { EmptyView() } else if searching { noResults } else { emptyState }
                }
            } else {
                Section {
                    inboxRow
                    ForEach(rowModels) { model in
                        row(model, presence: presenceMap[model.sourceID])
                            .listRowBackground(paper(.incomingBubble))
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(paper(.background).ignoresSafeArea())
        .paperMode(.live)
        .navigationTitle("Notes")
        .searchable(text: $query, prompt: Text("Search friends"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showPicker = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(Text("New conversation"))
            }
        }
        .sheet(isPresented: $showPicker, onDismiss: {
            #if os(iOS)
            if let t = pendingTarget {
                pendingTarget = nil
                pickedTarget = t
                showPicked = true
            }
            #endif
        }) { friendPicker }
        #if os(iOS)
        .navigationDestination(isPresented: $showPicked) {
            if let t = pickedTarget {
                ChatView(chatManager: chatManager, peerID: t.peerID, peerName: t.name, showsConnectionInfo: true)
                    .environmentObject(connectionManager)
            }
        }
        #endif
        .navigationDestination(isPresented: $showInbox) { inbox() }
        .navigationDestination(isPresented: $showGroup) {
            if let g = pickedGroup { GroupChatView(group: g) }
        }
        .onChange(of: inboxRequest) { _ in consumeInboxRequest() }
        .onChange(of: threadRequest) { _ in consumeThreadRequest() }
        .onAppear {
            refreshGate.appear()
            refreshSummaries()
            bindRefreshHub()
            consumeInboxRequest()
            consumeThreadRequest()
        }
        .onDisappear { refreshGate.disappear() }
    }

    /// Single route to the inbox (row tap and deep link both drive `showInbox`).
    /// If the inbox is already visible nothing is pushed: the visible `NotesInboxView`
    /// consumes `openNoteID` itself. A chat pushed from this tab is dismissed first.
    private func consumeInboxRequest() {
        guard InboxDeepLink.shouldConsume(pending: inboxRequest) else { return }
        inboxRequest = 0
        #if os(iOS)
        let chatShowing = showPicked || showGroup
        #else
        let chatShowing = showGroup
        #endif
        switch InboxDeepLink.action(inboxShowing: showInbox, chatShowing: chatShowing) {
        case .none:
            break
        case .push:
            showInbox = true
        case .dismissChatThenPush:
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) {
                showGroup = false
                #if os(iOS)
                showPicked = false
                #endif
                showInbox = true
            }
        }
    }

    /// Opens a bound friend's thread (note deep link). Dismisses the inbox or another chat first.
    /// Mac chats live in their own window, so nothing needs dismissing there.
    private func consumeThreadRequest() {
        guard InboxDeepLink.shouldConsumeThread(pending: threadRequest), let request = threadRequest else { return }
        let recordID = request.recordID
        threadRequest = nil
        guard let record = connectionManager.deviceStore.records.first(where: { $0.id == recordID }) else {
            // Friend vanished since the decision: open the inbox and show the tapped note itself.
            if !showInbox { showInbox = true }
            onThreadUnavailable(request.noteID)
            return
        }
        let name = connectionManager.displayName(for: record)
        #if os(iOS)
        let same = showPicked && pickedTarget?.peerID == chatKey(for: recordID)
        switch InboxDeepLink.threadAction(inboxShowing: showInbox, chatShowing: showPicked || showGroup, sameThreadShowing: same) {
        case .none:
            break
        case .push:
            openChat(recordID: recordID, name: name)
        case .dismissThenPush:
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) {
                showInbox = false
                showGroup = false
                showPicked = false
            }
            DispatchQueue.main.async { openChat(recordID: recordID, name: name) }
        }
        #else
        openChat(recordID: recordID, name: name)
        #endif
    }

    // MARK: - Rows

    private var inboxRow: some View {
        Button {
            showInbox = true
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: PeerAvatarShape.cornerRadius(forSize: 44), style: .continuous)
                    .fill(paper(.noteFill))
                    .overlay(RoundedRectangle(cornerRadius: PeerAvatarShape.cornerRadius(forSize: 44), style: .continuous)
                        .stroke(paper(.noteBorder), lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "envelope.fill").foregroundStyle(paper(.noteText)))
                    .accessibilityHidden(true)
                Text(inboxUnread > 0
                     ? String(format: String(localized: "Notes inbox (%lld unread)"), inboxUnread)
                     : String(localized: "Notes inbox"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(paper(.incomingText))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #if os(iOS)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(paper(.datePillText))
                    .accessibilityHidden(true)
                #endif
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
        .listRowBackground(paper(.incomingBubble))
    }

    @ViewBuilder
    private func row(_ model: ConversationRowModel, presence: PeerPresence?) -> some View {
        if model.isGroup {
            if let group = connectionManager.groupStore.groups.first(where: { $0.id == model.sourceID }) {
                Button {
                    pickedGroup = group
                    showGroup = true
                } label: {
                    HStack(spacing: 8) {
                        ConversationRow(model: model, presence: nil)
                        #if os(iOS)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(paper(.datePillText))
                            .accessibilityHidden(true)
                        #endif
                    }
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                openChat(recordID: model.sourceID, name: model.name)
            } label: {
                HStack(spacing: 8) {
                    ConversationRow(model: model, presence: presence, notesReachable: reachableRecordIDs.contains(model.sourceID))
                    #if os(iOS)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(paper(.datePillText))
                        .accessibilityHidden(true)
                    #endif
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the conversation"))
        }
    }

    // MARK: - Empty / no results

    private var noResults: some View {
        Text("No results")
            .foregroundStyle(paper(.datePillText))
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(paper(.datePillText))
                .accessibilityHidden(true)
            Text("No conversations yet. Pick a friend on Home to start chatting.")
                .font(.headline)
                .foregroundStyle(paper(.incomingText))
                .multilineTextAlignment(.center)
            Button(action: onGoHome) {
                Text("Go to Home")
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

    // MARK: - New conversation picker

    private var friendPicker: some View {
        let records = connectionManager.deviceStore.records.sorted {
            connectionManager.displayName(for: $0).localizedCaseInsensitiveCompare(connectionManager.displayName(for: $1)) == .orderedAscending
        }
        return NavigationStack {
            List {
                if records.isEmpty {
                    Text("No friends yet")
                        .foregroundStyle(paper(.datePillText))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
                ForEach(records) { record in
                    Button {
                        pick(record)
                    } label: {
                        HStack(spacing: 12) {
                            PeerAvatar(name: connectionManager.displayName(for: record), size: 44).accessibilityHidden(true)
                            Text(connectionManager.displayName(for: record))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(paper(.incomingText))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(paper(.incomingBubble))
                }
            }
            .scrollContentBackground(.hidden)
            .background(paper(.background).ignoresSafeArea())
            .navigationTitle("New conversation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPicker = false }
                }
            }
        }
        .paperMode(.live)
        .environmentObject(connectionManager)
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 360)
        #endif
    }

    private func pick(_ record: DeviceRecord) {
        #if os(iOS)
        // Push only after the sheet has fully dismissed (see the sheet's onDismiss).
        pendingTarget = ChatTarget(peerID: chatKey(for: record.id), name: connectionManager.displayName(for: record))
        showPicker = false
        #else
        showPicker = false
        openChat(recordID: record.id, name: connectionManager.displayName(for: record))
        #endif
    }
}

/// What the notes deep link should do given what the Notes tab is currently showing.
enum InboxDeepLink {
    /// A pending request (> 0) is consumed once and reset by the tab, so it is never replayed.
    static func shouldConsume(pending: Int) -> Bool { pending > 0 }

    enum Action: Equatable { case none, push, dismissChatThenPush }

    static func action(inboxShowing: Bool, chatShowing: Bool) -> Action {
        if inboxShowing { return .none }
        return chatShowing ? .dismissChatThenPush : .push
    }

    /// Where a tapped note notification should land.
    enum Destination: Equatable { case inbox, thread(recordID: String) }

    /// A note from a VERIFIED sender whose account is bound to a friend opens that friend's thread;
    /// everything else (anonymous, unverified, unbound, unknown note id) keeps the inbox behaviour.
    /// `recordIDForAccount` must only know verified-bound accounts.
    static func destination(sender: NoteSenderState?, recordIDForAccount: (String) -> String?) -> Destination {
        guard case .verified(let id, _)? = sender, let record = recordIDForAccount(id) else { return .inbox }
        return .thread(recordID: record)
    }

    enum ThreadAction: Equatable { case none, push, dismissThenPush }

    /// Opening a friend thread: already on that thread -> nothing; the inbox or another chat is on
    /// top -> dismiss it first (no animation), then push.
    static func threadAction(inboxShowing: Bool, chatShowing: Bool, sameThreadShowing: Bool) -> ThreadAction {
        if sameThreadShowing && !inboxShowing { return .none }
        return (inboxShowing || chatShowing) ? .dismissThenPush : .push
    }

    /// A pending thread request (record id) is consumed once and reset, so it is never replayed.
    static func shouldConsumeThread(pending: ThreadRequest?) -> Bool { pending != nil }
}

/// Owns the Combine subscription so it is created once, not per `body` evaluation.
@MainActor
final class RefreshHub: ObservableObject {
    private var cancellable: AnyCancellable?

    /// Merges `objectWillChange`-style sources (which fire BEFORE the value is written),
    /// throttles them (leading + trailing so the last change lands), then hops to the next
    /// main-queue turn so the subscriber always reads post-mutation state.
    nonisolated static func pipeline(_ sources: [AnyPublisher<Void, Never>]) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(sources)
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func bind(_ publisher: AnyPublisher<Void, Never>, _ action: @escaping () -> Void) {
        guard cancellable == nil else { return }
        cancellable = publisher.sink { action() }
    }
}

/// Gates the throttled refresh so an off-screen conversations list (another tab, or a chat pushed
/// on top) does no summary work; appearing always refreshes once.
struct ConversationsRefreshGate {
    private(set) var isVisible = false
    var shouldRefreshOnChange: Bool { isVisible }
    mutating func appear() { isVisible = true }
    mutating func disappear() { isVisible = false }
}
