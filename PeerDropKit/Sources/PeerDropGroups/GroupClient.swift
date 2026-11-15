import Foundation
import PeerDropAccount
import PeerDropNotes

public actor GroupClient {
    private let account: AccountClient

    public init(account: AccountClient = AccountClient()) {
        self.account = account
    }

    public func create(
        groupId: String,
        memberId: String,
        pubKey: String,
        pubKeySig: String,
        ownerWrap: (wrapped: String, sig: String),
        metaCipher: String,
        joinPolicy: String
    ) async throws -> (groupId: String, inviteCode: String) {
        let pathId = try Self.pathSafeGroupId(groupId)
        struct OwnerWrap: Encodable { let wrapped: String; let sig: String }
        struct Body: Encodable {
            let groupId: String
            let memberId: String
            let pubKey: String
            let pubKeySig: String
            let ownerWrap: OwnerWrap
            let metaCipher: String
            let joinPolicy: String
        }
        struct Response: Decodable { let groupId: String; let inviteCode: String }
        let response: Response = try await request(
            "POST", "v3/groups",
            body: Body(groupId: pathId, memberId: memberId, pubKey: pubKey, pubKeySig: pubKeySig,
                       ownerWrap: OwnerWrap(wrapped: ownerWrap.wrapped, sig: ownerWrap.sig), metaCipher: metaCipher,
                       joinPolicy: joinPolicy),
            memberId: memberId
        )
        return (response.groupId, response.inviteCode)
    }

    public func list() async throws -> [GroupListRow] {
        struct Response: Decodable { let groupId: String; let joinedAt: Int }
        let rows: [Response] = try await request("GET", "v3/groups", body: Optional<EmptyBody>.none, memberId: nil)
        return rows.map {
            GroupListRow(groupId: $0.groupId, joinedAt: Date(timeIntervalSince1970: Double($0.joinedAt) / 1000))
        }
    }

    public func view(id: String, memberId: String) async throws -> GroupView {
        let pathId = try Self.pathSafeGroupId(id)
        return try await request("GET", "v3/groups/\(pathId)", body: Optional<EmptyBody>.none, memberId: memberId)
    }

    public func join(
        id: String,
        memberId: String,
        pubKey: String,
        pubKeySig: String?,
        as joinAs: String,
        inviteCode: String
    ) async throws -> JoinResult {
        let pathId = try Self.pathSafeGroupId(id)
        return try await joinRequest("v3/groups/\(pathId)/join", memberId: memberId, pubKey: pubKey,
                                     pubKeySig: pubKeySig, as: joinAs, inviteCode: inviteCode)
    }

    public func joinByCode(
        memberId: String,
        pubKey: String,
        pubKeySig: String?,
        as joinAs: String,
        inviteCode: String
    ) async throws -> JoinResult {
        try await joinRequest("v3/groups/join", memberId: memberId, pubKey: pubKey,
                              pubKeySig: pubKeySig, as: joinAs, inviteCode: inviteCode)
    }

    public func leave(id: String, memberId: String) async throws {
        let pathId = try Self.pathSafeGroupId(id)
        let _: EmptyBody = try await request("POST", "v3/groups/\(pathId)/leave", body: Optional<EmptyBody>.none, memberId: memberId)
    }

    public func close(id: String, memberId: String) async throws {
        let pathId = try Self.pathSafeGroupId(id)
        let _: EmptyBody = try await request("POST", "v3/groups/\(pathId)/close", body: Optional<EmptyBody>.none, memberId: memberId)
    }

    public func kick(id: String, memberId: String, target: String) async throws {
        let pathId = try Self.pathSafeGroupId(id)
        struct Body: Encodable { let memberId: String }
        let _: EmptyBody = try await request("POST", "v3/groups/\(pathId)/kick", body: Body(memberId: target), memberId: memberId)
    }

    public func resetInvite(id: String, memberId: String) async throws -> String {
        let pathId = try Self.pathSafeGroupId(id)
        struct Response: Decodable { let inviteCode: String }
        let response: Response = try await request("POST", "v3/groups/\(pathId)/invite/reset", body: Optional<EmptyBody>.none, memberId: memberId)
        return response.inviteCode
    }

    public func events(id: String, memberId: String, since: Int, limit: Int = 100) async throws -> EventsPage {
        let pathId = try Self.pathSafeGroupId(id)
        return try await request("GET", "v3/groups/\(pathId)/events?since=\(since)&limit=\(limit)",
                                 body: Optional<EmptyBody>.none, memberId: memberId)
    }

    public func postMessage(id: String, memberId: String, eventId: String, epoch: UInt32, payloadCipher: String) async throws -> Int {
        let pathId = try Self.pathSafeGroupId(id)
        struct Body: Encodable { let eventId: String; let epoch: UInt32; let payloadCipher: String }
        struct Response: Decodable { let seq: Int }
        let response: Response = try await request("POST", "v3/groups/\(pathId)/events",
                                                   body: Body(eventId: eventId, epoch: epoch, payloadCipher: payloadCipher),
                                                   memberId: memberId)
        return response.seq
    }

    public func metaCipher(id: String, memberId: String) async throws -> (metaCipher: String, metaVersion: Int) {
        let pathId = try Self.pathSafeGroupId(id)
        struct Response: Decodable { let metaCipher: String; let metaVersion: Int }
        let response: Response = try await request("GET", "v3/groups/\(pathId)/meta", body: Optional<EmptyBody>.none, memberId: memberId)
        return (response.metaCipher, response.metaVersion)
    }

    public func putMeta(
        id: String,
        memberId: String,
        eventId: String,
        metaCipher: String,
        joinPolicy: String? = nil,
        removeAnonymous: Bool = false
    ) async throws -> (seq: Int, metaVersion: Int) {
        let pathId = try Self.pathSafeGroupId(id)
        struct Body: Encodable { let eventId: String; let metaCipher: String; let joinPolicy: String?; let removeAnonymous: Bool }
        struct Response: Decodable { let seq: Int; let metaVersion: Int }
        let response: Response = try await request(
            "PUT", "v3/groups/\(pathId)/meta",
            body: Body(eventId: eventId, metaCipher: metaCipher, joinPolicy: joinPolicy, removeAnonymous: removeAnonymous),
            memberId: memberId
        )
        return (response.seq, response.metaVersion)
    }

    public func rotate(
        id: String,
        memberId: String,
        eventId: String,
        epoch: UInt32,
        metaCipher: String,
        wraps: [WrapIn]
    ) async throws -> (seq: Int, epoch: UInt32) {
        let pathId = try Self.pathSafeGroupId(id)
        struct Body: Encodable { let eventId: String; let epoch: UInt32; let metaCipher: String; let wraps: [WrapIn] }
        struct Response: Decodable { let seq: Int; let epoch: UInt32 }
        let response: Response = try await request(
            "POST", "v3/groups/\(pathId)/rotate",
            body: Body(eventId: eventId, epoch: epoch, metaCipher: metaCipher, wraps: wraps),
            memberId: memberId
        )
        return (response.seq, response.epoch)
    }

    public func myKeys(id: String, memberId: String) async throws -> [WireWrap] {
        let pathId = try Self.pathSafeGroupId(id)
        struct Response: Decodable { let wraps: [WireWrap] }
        let response: Response = try await request("GET", "v3/groups/\(pathId)/keys", body: Optional<EmptyBody>.none, memberId: memberId)
        return response.wraps
    }

    public func putKeys(id: String, memberId: String, epoch: UInt32, wraps: [WrapIn]) async throws -> (written: [String], skipped: [String]) {
        let pathId = try Self.pathSafeGroupId(id)
        struct Body: Encodable { let epoch: UInt32; let wraps: [WrapIn] }
        struct Response: Decodable { let written: [String]; let skipped: [String] }
        let response: Response = try await request("PUT", "v3/groups/\(pathId)/keys",
                                                   body: Body(epoch: epoch, wraps: wraps), memberId: memberId)
        return (response.written, response.skipped)
    }

    public func requestKey(id: String, memberId: String) async throws {
        let pathId = try Self.pathSafeGroupId(id)
        let _: EmptyBody = try await request("POST", "v3/groups/\(pathId)/request-key", body: Optional<EmptyBody>.none, memberId: memberId)
    }

    public func wsTicket(id: String, memberId: String) async throws -> String {
        let pathId = try Self.pathSafeGroupId(id)
        struct Response: Decodable { let ticket: String }
        let response: Response = try await request("POST", "v3/groups/\(pathId)/ws-ticket", body: Optional<EmptyBody>.none, memberId: memberId)
        return response.ticket
    }

    public func report(id: String, memberId: String, seq: Int, reason: ReportReason, excerpt: String?) async throws -> String {
        let pathId = try Self.pathSafeGroupId(id)
        struct Body: Encodable { let reason: ReportReason; let excerpt: String? }
        struct Response: Decodable { let id: String }
        let response: Response = try await request("POST", "v3/groups/\(pathId)/events/\(seq)/report",
                                                   body: Body(reason: reason, excerpt: excerpt), memberId: memberId)
        return response.id
    }

    private func joinRequest(
        _ path: String,
        memberId: String,
        pubKey: String,
        pubKeySig: String?,
        as joinAs: String,
        inviteCode: String
    ) async throws -> JoinResult {
        struct Body: Encodable {
            let memberId: String
            let pubKey: String
            let pubKeySig: String?
            let joinAs: String
            let inviteCode: String
            enum CodingKeys: String, CodingKey { case memberId, pubKey, pubKeySig, joinAs = "as", inviteCode }
        }
        return try await request("POST", path,
                                 body: Body(memberId: memberId, pubKey: pubKey, pubKeySig: pubKeySig,
                                            joinAs: joinAs, inviteCode: inviteCode),
                                 memberId: memberId)
    }

    private func request<B: Encodable, R: Decodable>(
        _ method: String,
        _ path: String,
        body: B?,
        memberId: String?
    ) async throws -> R {
        let headers = memberId.map { ["X-Group-Member-Id": $0] } ?? [:]
        do {
            return try await account.request(method, path, body: body, headers: headers)
        } catch {
            throw GroupError.from(error)
        }
    }

    private static let groupIdPattern = "^[0-9A-HJKMNP-TV-Z]{26}$"

    /// The id goes into a URL path, so it is checked against the server's ULID shape first
    /// (rejects `/`, `?`, `#`, whitespace and a trailing newline that `$` would let through).
    private static func pathSafeGroupId(_ id: String) throws -> String {
        guard id.count == 26, id.range(of: groupIdPattern, options: .regularExpression) != nil else {
            throw GroupError.badId
        }
        return id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}
