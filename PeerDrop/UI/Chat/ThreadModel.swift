import Foundation
import Combine
import PeerDropCore
import PeerDropNotes

/// What the composer of a friend thread looks like. Pure mapping of
/// `ThreadTransport.Decision` so the view (and tests) never re-derive it.
struct ComposerMode: Equatable {
    enum Kind: Equatable { case live, note, locked(LockReason) }

    let kind: Kind
    /// Note mode while our own account cannot send right now: the note is queued.
    let queuesUntilOnline: Bool

    init(_ decision: ThreadTransport.Decision) {
        switch decision {
        case .live: kind = .live; queuesUntilOnline = false
        case .note(let canSendNow): kind = .note; queuesUntilOnline = !canSendNow
        case .locked(let reason): kind = .locked(reason); queuesUntilOnline = false
        }
    }

    var isLive: Bool { kind == .live }
    var isNote: Bool { kind == .note }
    var isLocked: Bool { if case .locked = kind { return true } else { return false } }
    /// The text field accepts input (live or note).
    var acceptsInput: Bool { !isLocked }
    /// Voice and attachment controls exist only for live chat.
    var showsLiveControls: Bool { isLive }
    /// Notes longer than this are refused by the server.
    static let noteScalarLimit = 2_000
    /// The counter appears only when close to the limit.
    static let counterThreshold = 1_800

    static func scalarCount(_ text: String) -> Int { text.unicodeScalars.count }
    static func showsCounter(forText text: String) -> Bool { scalarCount(text) >= counterThreshold }
    static func isOverLimit(_ text: String) -> Bool { scalarCount(text) > noteScalarLimit }
}

/// The merged friend thread (chat + notes + outbox) for one chat peer.
///
/// Rebuilt only when a source changes, coalesced onto the main queue; never
/// computed per row inside a view `body`. Only notes of the VERIFIED bound
/// account are merged (a pending claim shows none).
@MainActor
final class ThreadModel: ObservableObject {
    @Published private(set) var items: [ThreadItem] = []
    @Published private(set) var binding: BindingState = .none
    @Published private(set) var decision: ThreadTransport.Decision = .locked(reason: .notExchanged)
    @Published private(set) var unreadNoteIDs: [String] = []
    @Published private(set) var queuedEntries: [NoteOutboxEntry] = []
    @Published private(set) var failedEntries: [NoteOutboxEntry] = []
    @Published private(set) var sendingIDs: Set<UUID> = []
    @Published private(set) var contactID: UUID?
    /// The unsent-notes list could not be loaded or had to be quarantined (a banner explains it).
    @Published private(set) var outboxProblem = false
    /// False until the first decision exists, so the view shows nothing instead of a wrong composer.
    @Published private(set) var isReady = false
    /// Run / day grouping for `items`, computed once per rebuild (never per row in a view body).
    @Published private(set) var runStartIDs: Set<String> = []
    @Published private(set) var dayStartIDs: Set<String> = []
    /// The message being replied to. Owned here so a flip away from live chat clears it.
    @Published var replyingToMessage: ChatMessage?

    /// Number of item rebuilds (test observability).
    private(set) var rebuildCount = 0

    var mode: ComposerMode { ComposerMode(decision) }
    var verifiedAccountID: String? { verified?.accountId }

    private var peerID = ""
    private var verified: VerifiedAccount?
    private var chatManager: ChatManager?
    private var notesStore: NotesStore?
    private var outbox: NoteOutboxStore?
    private var friend: FriendBinding?
    private var presence: () -> PeerPresence = { .offline }
    private var accountReady: () -> Bool = { false }
    private var accountUnavailable: () -> Bool = { false }
    private var throttle: TimeInterval = 0.05
    private var cancellables = Set<AnyCancellable>()
    private var attached = false
    private var itemsDirty = false
    private var markRead: (String) async -> Void = { _ in }
    /// Notes whose server mark-read was already issued (once per note).
    private var markedNoteIDs = Set<String>()
    private var refreshScheduled = false

    init() {}

    /// Wires the model to the app's live objects. Idempotent per peer.
    func attach(connectionManager cm: ConnectionManager, chatManager: ChatManager, peerID: String) {
        guard !attached || self.peerID != peerID else { return }
        let account = cm.accountManager
        attach(peerID: peerID, chatManager: chatManager, notesStore: cm.notesStore, outbox: cm.noteOutbox,
               friend: FriendBinding(connectionManager: cm),
               presence: { [weak cm] in
                   guard let cm else { return .offline }
                   return PeerPresenceResolver.presence(ids: [peerID], sources: cm.presenceSources())
               },
               accountReady: { [weak account] in account?.account != nil },
               accountUnavailable: { [weak account] in account.map { ConnectionManager.noteAccountIsPermanentlyUnavailable($0.state) } ?? false },
               signals: [
                   // Presence / secure-channel changes only touch the decision, unless the resolved friend changes.
                   cm.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                   account.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
               ],
               itemSignals: [
                   cm.trustedContactStore.$contacts.dropFirst().map { _ in () }.eraseToAnyPublisher(),
               ])
    }

    /// Explicit wiring (tests, and the app overload above).
    func attach(peerID: String, chatManager: ChatManager, notesStore: NotesStore, outbox: NoteOutboxStore,
                friend: FriendBinding, presence: @escaping () -> PeerPresence, accountReady: @escaping () -> Bool,
                accountUnavailable: @escaping () -> Bool = { false },
                signals: [AnyPublisher<Void, Never>] = [], itemSignals: [AnyPublisher<Void, Never>] = [],
                throttle: TimeInterval = 0.05, markRead: ((String) async -> Void)? = nil) {
        cancellables.removeAll()
        self.markRead = markRead ?? { [weak notesStore] id in await notesStore?.markRead(id) }
        self.peerID = peerID; self.chatManager = chatManager; self.notesStore = notesStore; self.outbox = outbox
        self.friend = friend; self.presence = presence; self.accountReady = accountReady
        self.accountUnavailable = accountUnavailable; self.throttle = throttle
        attached = true

        // @Published publishers replay their current value on subscribe: skip it. Caller signals
        // must already be change-only.
        let itemSources: [AnyPublisher<Void, Never>] = [
            chatManager.$messages.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            notesStore.$inbox.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            notesStore.$sent.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            outbox.$entries.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ] + itemSignals
        for p in itemSources {
            p.sink { [weak self] in self?.itemsDirty = true; self?.scheduleRefresh() }.store(in: &cancellables)
        }
        outbox.$sendingIDs.dropFirst().sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        outbox.$loadError.dropFirst().sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        for p in signals {
            p.sink { [weak self] in self?.scheduleRefresh() }.store(in: &cancellables)
        }
        itemsDirty = true
        refresh()
    }

    /// Coalesces bursts of source changes into one refresh on the main queue.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + throttle) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Recomputes the decision always (cheap) and the merged items only when a source changed
    /// or the resolved friend changed.
    func refresh() {
        refreshScheduled = false
        guard attached, let friend, let outbox else { return }
        let newVerified = friend.verifiedAccount(forChatPeerID: peerID)
        if newVerified != verified { verified = newVerified; itemsDirty = true }

        let newBinding = friend.bindingState(forChatPeerID: peerID)
        if newBinding != binding { binding = newBinding }
        let availability: AccountAvailability = accountUnavailable() ? .unavailable : (accountReady() ? .ready : .notReady)
        let newDecision = ThreadTransport.decide(presence: presence(), binding: newBinding, account: availability)
        let problem = outbox.loadError != nil
        if problem != outboxProblem { outboxProblem = problem }
        if newDecision != decision { decision = newDecision }
        if !isReady { isReady = true }
        if !newDecision.isLive, replyingToMessage != nil { replyingToMessage = nil }

        let newSending = outbox.sendingIDs
        if newSending != sendingIDs { sendingIDs = newSending }
        if itemsDirty { rebuildItems() }
    }

    private func rebuildItems() {
        guard let chatManager, let notesStore, let outbox, let friend else { return }
        itemsDirty = false
        rebuildCount += 1
        let contact = friend.contact(forChatPeerID: peerID)
        let notes = verified.map { notesStore.notes(forAccount: $0.accountId) } ?? []
        let entries = contact.map { outbox.entries(forContact: $0.id) } ?? []
        let merged = ThreadMerge.items(
            chat: chatManager.messages, notes: notes, queued: entries,
            oldestLoadedChatDate: chatManager.messages.first?.timestamp,
            hasMoreChat: chatManager.hasMoreMessages)
        if merged != items {
            items = merged
            runStartIDs = ThreadMerge.runStartIDs(in: merged)
            dayStartIDs = ThreadMerge.dayStartIDs(in: merged)
        }
        // Only notes inside the visible (unclamped) window count as unread-and-seen.
        let unread: [String] = merged.compactMap { if case .note(let n) = $0, n.isUnread { return n.id } else { return nil } }
        if unread != unreadNoteIDs { unreadNoteIDs = unread }
        let queued = entries.filter { $0.state == .queued }
        let failed = entries.filter { $0.state == .failed }
        if queued != queuedEntries { queuedEntries = queued }
        if failed != failedEntries { failedEntries = failed }
        if contact?.id != contactID { contactID = contact?.id }
    }

    /// Marks the visible unread notes of the bound account read, once per note. The server call runs in an
    /// unstructured task so a view update or rebuild can never cancel it. Does nothing while the app is inactive.
    func markVisibleNotesRead(isActive: Bool) {
        guard isActive else { return }
        for id in unreadNoteIDs where markedNoteIDs.insert(id).inserted {
            let markRead = self.markRead
            Task { await markRead(id) }
        }
    }
}

extension ThreadTransport.Decision {
    var isLive: Bool { if case .live = self { return true } else { return false } }
}

/// Result of pressing Send in note mode. The text is cleared only for `.sent`.
enum NoteSendOutcome: Equatable {
    case sent
    case tooLong
    case noContact
    case failed(ConnectionManager.QueueNoteError)
    case failedUnknown

    var clearsText: Bool { self == .sent }

    /// User-visible explanation, nil on success.
    var message: String? {
        switch self {
        case .sent: return nil
        case .tooLong: return String(localized: "The note is too long.")
        case .noContact: return String(localized: "Exchange notes with each other to stay in touch offline.")
        case .failedUnknown: return String(localized: "Something went wrong. Please try again.")
        case .failed(let error):
            switch error {
            case .contactNotFound, .notBound:
                return String(localized: "Exchange notes with each other to stay in touch offline.")
            case .bindingPending:
                return String(localized: "Checking their notes account…")
            case .blocked:
                return String(localized: "This contact is blocked.")
            case .outboxUnavailable:
                return String(localized: "Couldn't save the note on this device. Your text is still here. Try again.")
            case .unavailable:
                return String(localized: "Notes can't be sent right now.")
            case .accountUnavailable:
                return String(localized: "Notes can't be sent from this device.")
            }
        }
    }
}

enum NoteSender {
    /// Pure send decision: `queue` is `ConnectionManager.queueNote` in the app.
    @MainActor
    static func send(text: String, contactID: UUID?, queue: (String, UUID) throws -> Void) -> NoteSendOutcome {
        guard !ComposerMode.isOverLimit(text) else { return .tooLong }
        guard let contactID else { return .noContact }
        do {
            try queue(text, contactID)
            return .sent
        } catch let error as ConnectionManager.QueueNoteError {
            return .failed(error)
        } catch {
            return .failedUnknown
        }
    }
}
