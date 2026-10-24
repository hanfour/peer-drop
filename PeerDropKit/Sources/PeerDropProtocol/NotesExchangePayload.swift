import Foundation

/// Phases of the mutual notes-account exchange. Compared as strings on the
/// wire so an unknown phase from a newer peer decodes fine and is a no-op.
public enum NotesExchangePhase: String, Sendable {
    case intent, reveal, cancel, unavailable
}

/// Wire payload for `MessageType.notesExchange`. Every field except `phase`
/// is optional so a newer/older peer's payload never fails to decode.
public struct NotesExchangePayload: Codable, Equatable {
    public var phase: String
    public var nonce: Data?
    public var accountId: String?
    public var signingKey: Data?
    public var signature: Data?

    public init(phase: String, nonce: Data? = nil, accountId: String? = nil,
                signingKey: Data? = nil, signature: Data? = nil) {
        self.phase = phase
        self.nonce = nonce
        self.accountId = accountId
        self.signingKey = signingKey
        self.signature = signature
    }
}
