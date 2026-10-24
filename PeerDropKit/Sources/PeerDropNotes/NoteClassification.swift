import Foundation

/// Where an inbound note belongs on this device (spec §4.5, 陌生人匣).
public enum NoteClass: Equatable, Sendable {
    /// From someone in the user's small circle (their own friends, diary mates, people they signed a note to).
    case circle
    /// Anonymous, unverified or from a verified account the user has no relationship with.
    case stranger
    /// Anonymous, and the user chose 「不接收匿名紙條」: hidden on THIS device only. The note stays in storage.
    case hiddenAnonymous
}

/// The relationships a note's AUTHENTICATED sender is checked against, plus the local hide option.
/// Built entirely from local state; nothing here is ever uploaded.
public struct CircleMembership: Equatable, Sendable {
    /// Account ids of friends with a verified notes-account binding.
    public var friendAccountIds: Set<String>
    /// Account ids of members of any exchange diary this account belongs to.
    public var diaryMemberAccountIds: Set<String>
    /// Account ids this user has sent a signed (non-anonymous) note to.
    public var sentSignedToAccountIds: Set<String>
    /// 「不接收匿名紙條」: local-only hide partition for anonymous notes.
    public var hideAnonymous: Bool

    public init(friendAccountIds: Set<String> = [], diaryMemberAccountIds: Set<String> = [],
                sentSignedToAccountIds: Set<String> = [], hideAnonymous: Bool = false) {
        self.friendAccountIds = friendAccountIds
        self.diaryMemberAccountIds = diaryMemberAccountIds
        self.sentSignedToAccountIds = sentSignedToAccountIds
        self.hideAnonymous = hideAnonymous
    }

    func contains(_ accountId: String) -> Bool {
        friendAccountIds.contains(accountId) || diaryMemberAccountIds.contains(accountId) || sentSignedToAccountIds.contains(accountId)
    }

    /// Recipients of the user's own signed (non-anonymous) outbound notes.
    public static func signedRecipients(in sent: [NoteRecord]) -> Set<String> {
        Set(sent.compactMap { r in
            guard r.direction == .outbound, r.sender != .anonymous else { return nil }
            return r.recipientAccountId
        })
    }
}

public enum NoteClassification {
    /// Pure. Only a `.verified` sender (signature checked against the directory by `NotesStore`) can be
    /// in the circle; the sender's nickname/display name is never consulted, and an anonymous note's
    /// sender is unknowable, so nothing here tries to identify it.
    public static func classify(note: NoteRecord, circle: CircleMembership) -> NoteClass {
        guard note.direction == .inbound else { return .circle }
        switch note.sender {
        case .verified(let accountId, _):
            return circle.contains(accountId) ? .circle : .stranger
        case .anonymous:
            return circle.hideAnonymous ? .hiddenAnonymous : .stranger
        case .unverified:
            return .stranger
        }
    }
}
