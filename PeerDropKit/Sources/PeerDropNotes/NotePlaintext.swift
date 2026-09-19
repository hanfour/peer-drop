import Foundation

public enum NoteKind: String, Codable, Sendable {
    case note, diaryKey, system
}

/// Inner, encrypted sender attestation. Absent on anonymous notes.
///
/// **UNVERIFIED until `NoteCrypto.verifySender` succeeds — never display
/// `accountId`/`nickname` from this block directly.** `NoteCrypto.open`
/// only checks the AEAD tag on the envelope; the sender fields inside are
/// whatever the encrypting party chose to put there, so a malicious or
/// compromised sender can claim any `accountId`/`nickname` here. Callers
/// MUST call `NoteCrypto.verifySender(_:recipientAccountId:directorySigningKey:)`
/// with the directory's signing key for the claimed `accountId` before
/// showing these fields to a user.
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
