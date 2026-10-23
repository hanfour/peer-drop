import SwiftUI
import Combine
import PeerDropCore

/// 紙條: first-row notes inbox + conversation list (friends and groups with messages, newest first).
/// Expects to be hosted in a NavigationStack that the container owns. It registers the
/// `ChatTarget` destination itself (`.chatTargetDestination()`); the container must NOT add one.
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
    /// Incremented by the container to ask for the inbox to be pushed (notification deep link).
    var inboxRequest: Int = 0
    @ViewBuilder var inbox: () -> Inbox
    @State private var showInbox = false
    @State private var handledInboxRequest = 0

    @State private var query = ""
    @StateObject private var hub = RefreshHub()
    @State private var showPicker = false
    /// Last-message summaries, rebuilt on appear and (debounced) on change signals — never inside `body`.
    @State private var peerSummaries: [String: ConversationSummary] = [:]
    @State private var groupSummaries: [String: ConversationSummary] = [:]
    /// False until the first synchronous seed, so the empty state never flashes.
    @State private var hasLoaded = false
    #if os(iOS)
    @State private var pickedTarget: ChatTarget?
    @State private var showPicked = false
    /// Chosen in the picker sheet; pushed from the sheet's onDismiss.
    @State private var pendingTarget: ChatTarget?
    #endif

    private var chatManager: ChatManager { connectionManager.chatManager }

    /// Chat files are keyed by the live peer id when connected, else the record id (same rule as HomeTab).
    private func chatKey(for recordID: String) -> String {
        connectionManager.connection(for: recordID)?.peerIdentity.id ?? recordID
    }

    private func refreshSummaries() {
        var peers: [String: ConversationSummary] = [:]
        for r in connectionManager.deviceStore.records {
            peers[r.id] = chatManager.summary(forPeer: chatKey(for: r.id))
        }
        var groups: [String: ConversationSummary] = [:]
        for g in connectionManager.groupStore.groups {
            groups[g.id] = chatManager.summary(forGroup: g.id)
        }
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
        ])) { refreshSummaries() }
    }

    private func rows() -> [ConversationRowModel] {
        ConversationsLogic.rows(
            records: connectionManager.deviceStore.records,
            groups: connectionManager.groupStore.groups,
            summaryForPeer: { peerSummaries[$0] ?? ConversationSummary(id: $0, isGroup: false, lastMessage: nil, unread: 0) },
            summaryForGroup: { groupSummaries[$0] ?? ConversationSummary(id: $0, isGroup: true, lastMessage: nil, unread: 0) },
            query: query)
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
            inboxRow
            if rowModels.isEmpty {
                if !hasLoaded { EmptyView() } else if searching { noResults } else { emptyState }
            } else {
                ForEach(rowModels) { model in
                    row(model, presence: presenceMap[model.sourceID])
                        .listRowBackground(paper(.incomingBubble))
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
                ChatView(chatManager: chatManager, peerID: t.peerID, peerName: t.name)
                    .environmentObject(connectionManager)
            }
        }
        #endif
        .chatTargetDestination()
        .navigationDestination(isPresented: $showInbox) { inbox() }
        .onChange(of: inboxRequest) { _ in consumeInboxRequest() }
        .onAppear {
            refreshSummaries()
            bindRefreshHub()
            consumeInboxRequest()
        }
    }

    private func consumeInboxRequest() {
        guard inboxRequest != handledInboxRequest else { return }
        handledInboxRequest = inboxRequest
        showInbox = true
    }

    // MARK: - Rows

    private var inboxRow: some View {
        NavigationLink {
            inbox()
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
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(paper(.incomingBubble))
    }

    @ViewBuilder
    private func row(_ model: ConversationRowModel, presence: PeerPresence?) -> some View {
        if model.isGroup {
            if let group = connectionManager.groupStore.groups.first(where: { $0.id == model.sourceID }) {
                NavigationLink(destination: GroupChatView(group: group)) {
                    ConversationRow(model: model, presence: nil)
                }
            }
        } else {
            Button {
                openChat(recordID: model.sourceID, name: model.name)
            } label: {
                HStack(spacing: 8) {
                    ConversationRow(model: model, presence: presence)
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
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
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
                            PeerAvatar(name: record.displayName, size: 44).accessibilityHidden(true)
                            Text(record.displayName)
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
        pendingTarget = ChatTarget(peerID: chatKey(for: record.id), name: record.displayName)
        showPicker = false
        #else
        showPicker = false
        openChat(recordID: record.id, name: record.displayName)
        #endif
    }
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
