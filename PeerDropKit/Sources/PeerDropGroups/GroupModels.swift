import Foundation

/// The identity mode a member chose when joining a group.
public enum IdentityKind: String, Codable, Equatable, Sendable {
    case account
    case anon
}

/// One member visible in the local group state.
public struct GroupMember: Equatable {
    public let memberId: String
    public let kind: IdentityKind
    public let accountId: String?
    public var nickname: String?
    public let hasKey: Bool
    public let isOwner: Bool
    public let pubKeyVerified: Bool

    public init(
        memberId: String,
        kind: IdentityKind,
        accountId: String? = nil,
        nickname: String? = nil,
        hasKey: Bool,
        isOwner: Bool,
        pubKeyVerified: Bool
    ) {
        self.memberId = memberId
        self.kind = kind
        self.accountId = accountId
        self.nickname = nickname
        self.hasKey = hasKey
        self.isOwner = isOwner
        self.pubKeyVerified = pubKeyVerified
    }
}

/// One locally decrypted group message.
public struct GroupMessage: Equatable {
    public let eventId: String
    public let seq: Int
    public let authorMemberId: String
    public let text: String
    public let createdAt: Date
    public let isMine: Bool

    public init(eventId: String, seq: Int, authorMemberId: String, text: String, createdAt: Date, isMine: Bool) {
        self.eventId = eventId
        self.seq = seq
        self.authorMemberId = authorMemberId
        self.text = text
        self.createdAt = createdAt
        self.isMine = isMine
    }
}

/// The locally available metadata and content state for one group.
public struct GroupState: Equatable {
    public let groupId: String
    public var meta: GroupMetaPlaintext?
    public var members: [GroupMember]
    public var messages: [GroupMessage]
    public var pendingDecryptCount: Int
    public var isOwner: Bool
    public var myMemberId: String
    public var identityKind: IdentityKind
    public var joinPolicy: String
    public var state: GroupSummary.State
    public var epoch: UInt32
    public var rotationDue: Bool
    public var hasGap: Bool
    public var supersededElsewhere: Bool

    public init(
        groupId: String,
        meta: GroupMetaPlaintext? = nil,
        members: [GroupMember],
        messages: [GroupMessage] = [],
        pendingDecryptCount: Int = 0,
        isOwner: Bool,
        myMemberId: String,
        identityKind: IdentityKind,
        joinPolicy: String,
        state: GroupSummary.State,
        epoch: UInt32,
        rotationDue: Bool = false,
        hasGap: Bool = false,
        supersededElsewhere: Bool = false
    ) {
        self.groupId = groupId
        self.meta = meta
        self.members = members
        self.messages = messages
        self.pendingDecryptCount = pendingDecryptCount
        self.isOwner = isOwner
        self.myMemberId = myMemberId
        self.identityKind = identityKind
        self.joinPolicy = joinPolicy
        self.state = state
        self.epoch = epoch
        self.rotationDue = rotationDue
        self.hasGap = hasGap
        self.supersededElsewhere = supersededElsewhere
    }
}

/// A compact row for the group list, rebuilt from encrypted local metadata.
public struct GroupSummary: Codable, Equatable, Identifiable {
    public enum State: String, Codable, Equatable {
        case open
        case closed
        case removed
    }

    public let groupId: String
    public var name: String?
    public var memberCount: Int
    public var unread: Int
    public var lastActivity: Date?
    public var state: State
    public var awaitingKey: Bool

    public var id: String { groupId }

    public init(
        groupId: String,
        name: String?,
        memberCount: Int,
        unread: Int = 0,
        lastActivity: Date? = nil,
        state: State,
        awaitingKey: Bool
    ) {
        self.groupId = groupId
        self.name = name
        self.memberCount = memberCount
        self.unread = unread
        self.lastActivity = lastActivity
        self.state = state
        self.awaitingKey = awaitingKey
    }
}
