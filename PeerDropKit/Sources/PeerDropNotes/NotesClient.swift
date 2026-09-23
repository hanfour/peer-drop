import Foundation
import PeerDropAccount

public struct InboxItemDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let envelope: String     // base64 NoteEnvelope JSON
    public let createdAt: Int       // unix ms (server)
    public let readAt: Int?
    public init(id: String, kind: String, envelope: String, createdAt: Int, readAt: Int?) {
        self.id = id; self.kind = kind; self.envelope = envelope; self.createdAt = createdAt; self.readAt = readAt
    }
}
public struct InboxPageDTO: Decodable, Equatable, Sendable {
    public let items: [InboxItemDTO]
    public let nextAfter: String?
}
public struct BlockDTO: Decodable, Equatable, Sendable {
    public let senderHash: String
    public let createdAt: Int
    public init(senderHash: String, createdAt: Int) { self.senderHash = senderHash; self.createdAt = createdAt }
}
public enum ReportReason: String, Codable, CaseIterable, Sendable {
    case spam, harassment, other
}

/// HTTP client for the worker's notes routes. Wraps an `AccountClient` for
/// its auth/401-retry/error-mapping plumbing (`AccountClient.request`).
public actor NotesClient {
    private let account: AccountClient

    public init(account: AccountClient = AccountClient()) { self.account = account }

    public func powChallenge() async throws -> String {
        struct R: Decodable { let challenge: String }
        let r: R = try await account.request("GET", "v3/pow/challenge", body: Optional<EmptyBody>.none)
        return r.challenge
    }

    public func send(to recipientAccountId: String, envelopeBase64: String, challenge: String, nonce: UInt64) async throws -> String {
        struct PoW: Encodable { let challenge: String; let nonce: UInt64 }
        struct Body: Encodable { let envelope: String; let pow: PoW }
        struct R: Decodable { let id: String }
        let r: R = try await account.request("POST", "v3/notes/\(recipientAccountId)", body: Body(envelope: envelopeBase64, pow: PoW(challenge: challenge, nonce: nonce)))
        return r.id
    }

    public func inbox(after: String?, limit: Int = 50) async throws -> InboxPageDTO {
        var path = "v3/inbox?limit=\(limit)"
        if let after { path = "v3/inbox?after=\(after)&limit=\(limit)" }
        return try await account.request("GET", path, body: Optional<EmptyBody>.none)
    }

    public func markRead(id: String) async throws {
        let _: EmptyBody = try await account.request("POST", "v3/inbox/\(id)/read", body: Optional<EmptyBody>.none)
    }

    public func delete(id: String) async throws {
        let _: EmptyBody = try await account.request("DELETE", "v3/inbox/\(id)", body: Optional<EmptyBody>.none)
    }

    public func block(itemId: String) async throws -> String {
        struct R: Decodable { let blocked: String }
        let r: R = try await account.request("POST", "v3/inbox/\(itemId)/block", body: Optional<EmptyBody>.none)
        return r.blocked
    }

    public func blocks() async throws -> [BlockDTO] {
        try await account.request("GET", "v3/blocks", body: Optional<EmptyBody>.none)
    }

    public func unblock(senderHash: String) async throws {
        let _: EmptyBody = try await account.request("DELETE", "v3/blocks/\(senderHash)", body: Optional<EmptyBody>.none)
    }

    public func report(itemId: String, reason: ReportReason, excerpt: String?) async throws -> String {
        struct Body: Encodable { let reason: ReportReason; let excerpt: String? }   // nil → key omitted (worker treats absent and null alike)
        struct R: Decodable { let id: String }
        let r: R = try await account.request("POST", "v3/inbox/\(itemId)/report", body: Body(reason: reason, excerpt: excerpt))
        return r.id
    }

    public func lookup(handle: String, includeBundle: Bool) async throws -> DirectoryEntry? {
        try await account.lookup(handle: handle, includeBundle: includeBundle)
    }
}
