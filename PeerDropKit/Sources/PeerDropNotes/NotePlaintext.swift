import Foundation

public enum NoteKind: String, Codable, Sendable {
    case note, diaryKey, system
}

/// Inner, encrypted sender attestation. Absent on anonymous notes.
public struct NoteSenderBlock: Codable, Equatable, Sendable {
    public var accountId: String
    public var nickname: String?
    public var signingKey: Data
    public var signature: Data
    public init(accountId: String, nickname: String?, signingKey: Data, signature: Data) {
        self.accountId = accountId; self.nickname = nickname; self.signingKey = signingKey; self.signature = signature
    }
}

public struct NotePlaintext: Codable, Equatable, Sendable {
    public var kind: NoteKind
    public var text: String
    public var sentAt: Int64          // unix seconds
    public var sender: NoteSenderBlock?
    public init(kind: NoteKind, text: String, sentAt: Int64, sender: NoteSenderBlock?) {
        self.kind = kind; self.text = text; self.sentAt = sentAt; self.sender = sender
    }
}
