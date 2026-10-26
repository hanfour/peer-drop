import Foundation

public struct GroupView: Codable, Equatable, Sendable {
    public let groupId: String
    public let ownerMemberId: String?
    public let members: [WireMember]
    public let joinPolicy: String
    public let state: String
    public let epoch: UInt32
    public let seq: Int
    public let firstSeq: Int
    public let metaVersion: Int
    public let rotationDue: Bool
    public let inviteCode: String?

    public init(groupId: String, ownerMemberId: String?, members: [WireMember], joinPolicy: String, state: String, epoch: UInt32, seq: Int, firstSeq: Int, metaVersion: Int, rotationDue: Bool, inviteCode: String? = nil) {
        self.groupId = groupId
        self.ownerMemberId = ownerMemberId
        self.members = members
        self.joinPolicy = joinPolicy
        self.state = state
        self.epoch = epoch
        self.seq = seq
        self.firstSeq = firstSeq
        self.metaVersion = metaVersion
        self.rotationDue = rotationDue
        self.inviteCode = inviteCode
    }
}

public struct WireMember: Codable, Equatable, Sendable {
    public let memberId: String
    public let kind: String
    public let accountId: String?
    public let joinedAt: Int
    public let pubKey: String
    public let pubKeySig: String?
    public let hasKey: Bool

    public init(memberId: String, kind: String, accountId: String? = nil, joinedAt: Int, pubKey: String, pubKeySig: String? = nil, hasKey: Bool) {
        self.memberId = memberId
        self.kind = kind
        self.accountId = accountId
        self.joinedAt = joinedAt
        self.pubKey = pubKey
        self.pubKeySig = pubKeySig
        self.hasKey = hasKey
    }
}

public struct WireEvent: Codable, Equatable, Sendable {
    public let seq: Int
    public let eventId: String
    public let type: String
    public let authorMemberId: String
    public let epoch: UInt32
    public let payloadCipher: String?
    public let targetMemberId: String?
    public let ownerMemberId: String?
    public let metaVersion: Int?
    public let rotated: Bool?
    public let createdAt: Int

    public init(seq: Int, eventId: String, type: String, authorMemberId: String, epoch: UInt32, payloadCipher: String? = nil, targetMemberId: String? = nil, ownerMemberId: String? = nil, metaVersion: Int? = nil, rotated: Bool? = nil, createdAt: Int) {
        self.seq = seq
        self.eventId = eventId
        self.type = type
        self.authorMemberId = authorMemberId
        self.epoch = epoch
        self.payloadCipher = payloadCipher
        self.targetMemberId = targetMemberId
        self.ownerMemberId = ownerMemberId
        self.metaVersion = metaVersion
        self.rotated = rotated
        self.createdAt = createdAt
    }
}

public struct EventsPage: Codable, Equatable, Sendable {
    public let events: [WireEvent]
    public let firstSeq: Int
    public let nextSince: Int?

    public init(events: [WireEvent], firstSeq: Int, nextSince: Int? = nil) {
        self.events = events
        self.firstSeq = firstSeq
        self.nextSince = nextSince
    }
}

public struct WireWrap: Codable, Equatable, Sendable {
    public let epoch: UInt32
    public let wrapped: String
    public let wrappedBy: String
    public let sig: String

    public init(epoch: UInt32, wrapped: String, wrappedBy: String, sig: String) {
        self.epoch = epoch
        self.wrapped = wrapped
        self.wrappedBy = wrappedBy
        self.sig = sig
    }
}

public struct WrapIn: Codable, Equatable, Sendable {
    public let memberId: String
    public let wrapped: String
    public let sig: String

    public init(memberId: String, wrapped: String, sig: String) {
        self.memberId = memberId
        self.wrapped = wrapped
        self.sig = sig
    }
}

public struct GroupListRow: Codable, Equatable, Sendable {
    public let groupId: String
    public let joinedAt: Date

    public init(groupId: String, joinedAt: Date) {
        self.groupId = groupId
        self.joinedAt = joinedAt
    }
}

public struct JoinResult: Codable, Equatable, Sendable {
    public let groupId: String
    public let memberId: String
    public let epoch: UInt32
    public let state: String
    public let ownerMemberId: String?

    public init(groupId: String, memberId: String, epoch: UInt32, state: String, ownerMemberId: String?) {
        self.groupId = groupId
        self.memberId = memberId
        self.epoch = epoch
        self.state = state
        self.ownerMemberId = ownerMemberId
    }
}
