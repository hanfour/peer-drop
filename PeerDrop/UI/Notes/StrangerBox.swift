import Foundation
import PeerDropNotes

/// The 陌生人匣: pure, local-only partitioning of the notes inbox. Nothing here sends anything:
/// no read receipt, no reply, no "seen" signal. Hiding anonymous notes only changes what this
/// device shows; the notes stay in storage so un-hiding brings them straight back.
enum StrangerBox {
    /// UserDefaults key of the local 「不接收匿名紙條」 switch (`@AppStorage` in the views).
    static let hideAnonymousKey = "peerDropHideAnonymousNotes"

    struct Partition: Equatable {
        /// Circle members that are not bound friends (bound friends' notes live in their thread).
        let circle: [NoteRecord]
        let strangers: [NoteRecord]
        let hidden: [NoteRecord]
    }

    /// `NotesInboxFilter` first (Project C's dedupe: bound friends' notes are not inbox notes), then classify.
    static func partition(_ notes: [NoteRecord], boundAccounts: Set<String>, circle: CircleMembership) -> Partition {
        var c: [NoteRecord] = [], s: [NoteRecord] = [], h: [NoteRecord] = []
        for note in NotesInboxFilter.inbox(notes, boundAccounts: boundAccounts) {
            switch NoteClassification.classify(note: note, circle: circle) {
            case .circle: c.append(note)
            case .stranger: s.append(note)
            case .hiddenAnonymous: h.append(note)
            }
        }
        return Partition(circle: c, strangers: s, hidden: h)
    }

    /// The unread numbers, kept apart on purpose. Project C's invariant still holds:
    /// `tabBadge == friendRows + inboxRemainder`. Hidden anonymous notes count nowhere.
    struct Unread: Equatable {
        let tabBadge: Int
        let inboxRemainder: Int
        let friendRows: Int
        /// Unread notes in the 陌生人 section (already included in `inboxRemainder` and `tabBadge`).
        let strangerUnread: Int
        let hiddenUnread: Int
    }

    static func unread(_ notes: [NoteRecord], boundAccounts: Set<String>, circle: CircleMembership) -> Unread {
        let unread = notes.filter(\.isUnread)
        let hiddenUnread = unread.filter { NoteClassification.classify(note: $0, circle: circle) == .hiddenAnonymous }.count
        let boundUnread = unread.filter { NotesInboxFilter.isInThread($0, boundAccounts: boundAccounts) }.count
        let base = ConversationsLogic.unread(total: unread.count - hiddenUnread, boundUnread: boundUnread)
        let strangerUnread = partition(notes, boundAccounts: boundAccounts, circle: circle).strangers.filter(\.isUnread).count
        return Unread(tabBadge: base.tabBadge, inboxRemainder: base.inboxRemainder, friendRows: base.friendRows,
                      strangerUnread: strangerUnread, hiddenUnread: hiddenUnread)
    }

    static func membership(friendAccounts: Set<String>, diaryMemberLists: [[String]], sent: [NoteRecord], hideAnonymous: Bool) -> CircleMembership {
        CircleMembership(friendAccountIds: friendAccounts,
                         diaryMemberAccountIds: Set(diaryMemberLists.joined()),
                         sentSignedToAccountIds: CircleMembership.signedRecipients(in: sent),
                         hideAnonymous: hideAnonymous)
    }

    /// A tapped notification opens its note unless the note is a hidden anonymous one (it stays hidden).
    static func opensFromNotification(_ note: NoteRecord, circle: CircleMembership) -> Bool {
        NoteClassification.classify(note: note, circle: circle) != .hiddenAnonymous
    }

    /// Hidden anonymous notes that are not yet read on the SERVER. They get a server read mark (never
    /// visible to senders) so the inbox's unread-first eviction can reclaim them, while staying stored
    /// and unread on this device.
    static func hiddenIDsToMarkOnServer(_ notes: [NoteRecord], circle: CircleMembership) -> [String] {
        notes.filter { $0.isUnread && NoteClassification.classify(note: $0, circle: circle) == .hiddenAnonymous }.map(\.id)
    }
}
