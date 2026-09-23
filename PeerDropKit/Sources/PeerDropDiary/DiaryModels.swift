import Foundation

/// Wire-identical to the worker's `DiaryEventType` union (`diaryRoom.ts`).
/// `join`/`leave` are server-minted (via the dedicated join/leave routes,
/// never `POST /events`) but still appear in the event stream, so every
/// case is representable here.
public enum DiaryEventType: String, Codable, Hashable, Sendable {
    case entry, comment, like, pass, skip, join, leave
}

/// The plaintext an `entry`/`comment` event's `payloadCipher` decrypts to
/// (spec §3.1). Never sent over the wire itself.
public struct DiaryPayload: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case entry, comment }
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// One entry in a diary's event log. `payloadCipher` is the opaque
/// base64 blob as received from (or sent to) the worker; `payload` is
/// populated only once something has locally decrypted it (`DiaryCrypto.open`)
/// — it is never present on the wire and is nil for a `pass`/`skip`/`join`/
/// `leave`/`like` event (those never carry a payload) or before decryption.
public struct DiaryEvent: Codable, Hashable, Identifiable, Sendable {
    public let seq: Int
    public let eventId: String
    public let type: DiaryEventType
    public let authorAccountId: String
    public let refSeq: Int?
    public let payloadCipher: String?
    public var payload: DiaryPayload?
    public let createdAt: Date
    /// Set by the server on a `skip` event to the accountId of the holder
    /// who was skipped; nil for every other event type.
    public let skipped: String?

    public var id: String { eventId }

    public init(
        seq: Int, eventId: String, type: DiaryEventType, authorAccountId: String,
        refSeq: Int? = nil, payloadCipher: String? = nil, payload: DiaryPayload? = nil,
        createdAt: Date, skipped: String? = nil
    ) {
        self.seq = seq
        self.eventId = eventId
        self.type = type
        self.authorAccountId = authorAccountId
        self.refSeq = refSeq
        self.payloadCipher = payloadCipher
        self.payload = payload
        self.createdAt = createdAt
        self.skipped = skipped
    }
}

/// A diary's turn-order/membership state, as `GET /v3/diaries/:id` (the
/// turn-order source of truth — spec §5.1) returns it. `inviteCode` is
/// present only for the owner (or omitted entirely by a join response —
/// see `DiaryClient`). `name` is populated locally once `metaCipher` has
/// been opened (`DiaryCrypto.openMeta`); it is never on the wire.
public struct DiaryMeta: Codable, Hashable, Sendable {
    public let diaryId: String
    public let ownerAccountId: String
    public let members: [String]
    public let holderIndex: Int
    public let seq: Int
    public let state: String
    public let keyEpoch: Int
    public let metaCipher: String
    public let inviteCode: String?
    public var name: String?

    public init(
        diaryId: String, ownerAccountId: String, members: [String], holderIndex: Int,
        seq: Int, state: String, keyEpoch: Int, metaCipher: String,
        inviteCode: String? = nil, name: String? = nil
    ) {
        self.diaryId = diaryId
        self.ownerAccountId = ownerAccountId
        self.members = members
        self.holderIndex = holderIndex
        self.seq = seq
        self.state = state
        self.keyEpoch = keyEpoch
        self.metaCipher = metaCipher
        self.inviteCode = inviteCode
        self.name = name
    }

    public var isClosed: Bool { state == "closed" }
}

/// A row of `GET /v3/diaries` — this account's diary list.
public struct DiarySummary: Codable, Hashable, Sendable {
    public let diaryId: String
    public let joinedAt: Date
    public init(diaryId: String, joinedAt: Date) {
        self.diaryId = diaryId
        self.joinedAt = joinedAt
    }
}

/// Client-facing errors — `DiaryClient` maps every `AccountClientError`
/// (via its body error code) into one of these; `DiaryCrypto`/`DiaryStore`
/// raise `.noKey`/`.network` directly for local conditions the server never
/// reports. `.network(String)` is the catch-all for any body code, HTTP
/// status, or transport failure not otherwise named here — callers that
/// need the raw code/description can pattern-match its payload.
public enum DiaryError: Error, Equatable, Sendable {
    case notMember
    case notHolder
    case notOwner
    case skipSelf
    case closed
    case badCode
    case badRef
    case full
    case limit
    case membersFull
    case exists
    case tooLarge
    case noKey
    case network(String)
}
