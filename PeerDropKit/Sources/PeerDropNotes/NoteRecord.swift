import Foundation

public enum NoteDirection: String, Codable, Sendable { case inbound, outbound }

/// Who a note is from, after the recipient verified the inner signature
/// against the directory. Custom Codable keeps the on-disk form explicit.
public enum NoteSenderState: Hashable, Sendable {
    case anonymous
    case verified(accountId: String, nickname: String?)
    case unverified(accountId: String)

    public var accountId: String? {
        switch self {
        case .anonymous: return nil
        case .verified(let id, _), .unverified(let id): return id
        }
    }
}

extension NoteSenderState: Codable {
    private enum CodingKeys: String, CodingKey { case state, accountId, nickname }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "anonymous": self = .anonymous
        case "verified": self = .verified(accountId: try c.decode(String.self, forKey: .accountId), nickname: try c.decodeIfPresent(String.self, forKey: .nickname))
        case "unverified": self = .unverified(accountId: try c.decode(String.self, forKey: .accountId))
        default: throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "unknown sender state")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anonymous: try c.encode("anonymous", forKey: .state)
        case .verified(let id, let nick): try c.encode("verified", forKey: .state); try c.encode(id, forKey: .accountId); try c.encodeIfPresent(nick, forKey: .nickname)
        case .unverified(let id): try c.encode("unverified", forKey: .state); try c.encode(id, forKey: .accountId)
        }
    }
}

/// A decrypted (or undecryptable) note as the app stores and shows it.
public struct NoteRecord: Codable, Hashable, Identifiable, Sendable {   // Hashable: used as a NavigationLink value
    public let id: String                 // server ULID
    public let direction: NoteDirection
    public var text: String?              // nil = could not be decrypted
    public let sentAt: Date
    public var sender: NoteSenderState
    public let recipientAccountId: String?   // outbound only
    public var readAt: Date?
    public let receivedAt: Date
    /// The inner sender attestation as received, kept even when unverified
    /// (or when verification failed only because the directory lookup was
    /// transiently unavailable) so a later sync can re-verify it without
    /// re-fetching the envelope. **Still unverified** unless `sender` is
    /// `.verified` — never display these fields directly.
    public var senderBlock: NoteSenderBlock?

    public init(id: String, direction: NoteDirection, text: String?, sentAt: Date, sender: NoteSenderState, recipientAccountId: String?, readAt: Date?, receivedAt: Date, senderBlock: NoteSenderBlock? = nil) {
        self.id = id; self.direction = direction; self.text = text; self.sentAt = sentAt; self.sender = sender
        self.recipientAccountId = recipientAccountId; self.readAt = readAt; self.receivedAt = receivedAt; self.senderBlock = senderBlock
    }

    public var isUnread: Bool { direction == .inbound && readAt == nil }
    public var isUndecryptable: Bool { text == nil }
}
