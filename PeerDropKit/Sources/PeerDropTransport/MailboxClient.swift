import Foundation
import PeerDropSecurity
import os.log

/// HTTP client for the v2 zero-knowledge relay API.
/// Handles pre-key registration, message delivery, and mailbox management.
public actor MailboxClient {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "MailboxClient")

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL ?? WorkerURL.current()
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Pre-Key Management

    public func registerPreKeys(mailboxId: String, bundle: PreKeyBundle, token: String? = nil) async throws -> String {
        let url = baseURL.appendingPathComponent("v2/keys/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "mailboxId": mailboxId,
            "preKeyBundle": try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)),
        ]
        if let token { body["token"] = token }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        let result = try JSONDecoder().decode(RegisterKeysResponse.self, from: data)
        return result.token
    }

    public func fetchPreKeyBundle(mailboxId: String) async throws -> FetchedPreKeyBundle {
        let url = baseURL.appendingPathComponent("v2/keys/\(mailboxId)")
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try JSONDecoder().decode(FetchedPreKeyBundle.self, from: data)
    }

    // MARK: - Message Delivery

    /// Delivers `ciphertext` with a proof of work. A worker that issues challenges (`POST .../challenge`) gets a
    /// single-use, content-bound proof; a worker that predates that endpoint answers 404 and gets the legacy
    /// client-chosen challenge, which that worker still accepts.
    public func sendMessage(to mailboxId: String, ciphertext: Data) async throws {
        let encoded = ciphertext.base64EncodedString()
        if let issued = try await requestChallenge(for: mailboxId) {
            let difficulty = min(max(issued.difficulty, 1), Self.maxServerDifficulty)
            guard let proof = await MailboxProofOfWork.generate(
                challenge: issued.challenge, mailboxId: mailboxId, ciphertext: encoded, difficulty: difficulty
            ) else { throw MailboxError.invalidResponse }
            try await deliver(to: mailboxId, ciphertext: encoded, pow: ProofOfWorkToken(challenge: issued.challenge, proof: proof))
            return
        }
        let challenge = UUID().uuidString
        guard let proof = await ProofOfWork.generate(challenge: challenge) else { throw MailboxError.invalidResponse }
        try await deliver(to: mailboxId, ciphertext: encoded, pow: ProofOfWorkToken(challenge: challenge, proof: proof))
    }

    /// A worker cannot make the client grind longer than this many leading zero bits.
    private static let maxServerDifficulty = 24

    private func requestChallenge(for mailboxId: String) async throws -> IssuedChallenge? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/messages/\(mailboxId)/challenge"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MailboxError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw MailboxError.httpError(http.statusCode) }
        return try JSONDecoder().decode(IssuedChallenge.self, from: data)
    }

    private func deliver(to mailboxId: String, ciphertext: String, pow: ProofOfWorkToken) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/messages/\(mailboxId)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SendMessageRequest(ciphertext: ciphertext, pow: pow))
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    public func fetchMessages(mailboxId: String, token: String) async throws -> [MailboxMessage] {
        let url = baseURL.appendingPathComponent("v2/messages")
        var request = URLRequest(url: url)
        request.setValue(mailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(token, forHTTPHeaderField: "X-Mailbox-Token")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([MailboxMessage].self, from: data)
    }

    // MARK: - Mailbox Management

    public func rotateMailbox(oldMailboxId: String, oldToken: String) async throws -> MailboxRotationResult {
        let url = baseURL.appendingPathComponent("v2/mailbox/rotate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(oldMailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(oldToken, forHTTPHeaderField: "X-Mailbox-Token")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(MailboxRotationResult.self, from: data)
    }

    public func revokeKeys(mailboxId: String, token: String) async throws {
        let url = baseURL.appendingPathComponent("v2/keys")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(mailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(token, forHTTPHeaderField: "X-Mailbox-Token")

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Private

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MailboxError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MailboxError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Request/Response Models

private struct RegisterKeysResponse: Codable {
    public let token: String
}

/// Server returns a single one-time pre-key (consumed), not the full array
public struct FetchedPreKeyBundle: Codable, Equatable, Sendable {
    public let identityKey: Data
    public let signingKey: Data
    public let signedPreKey: PublicSignedPreKey
    public let oneTimePreKey: PublicOneTimePreKey?
    // v5.4 C1 — see PreKeyBundle for the wire contract. Optional so legacy
    // (v5.0–v5.3) responder bundles still decode.
    public let signedPreKeyTimestamp: UInt64?
    public let signedPreKeyTimestampSignature: Data?

    public init(identityKey: Data, signingKey: Data, signedPreKey: PublicSignedPreKey, oneTimePreKey: PublicOneTimePreKey?,
                signedPreKeyTimestamp: UInt64? = nil, signedPreKeyTimestampSignature: Data? = nil) {
        self.identityKey = identityKey; self.signingKey = signingKey; self.signedPreKey = signedPreKey
        self.oneTimePreKey = oneTimePreKey
        self.signedPreKeyTimestamp = signedPreKeyTimestamp; self.signedPreKeyTimestampSignature = signedPreKeyTimestampSignature
    }
}

private struct IssuedChallenge: Decodable {
    let challenge: String
    let difficulty: Int
}

public struct SendMessageRequest: Codable {
    public let ciphertext: String
    public let pow: ProofOfWorkToken
}

public struct ProofOfWorkToken: Codable {
    public let challenge: String
    public let proof: UInt64

    public init(challenge: String, proof: UInt64) {
        self.challenge = challenge
        self.proof = proof
    }
}

public struct MailboxMessage: Codable, Identifiable {
    public let id: String
    public let ciphertext: String
    public let timestamp: String

    public init(id: String, ciphertext: String, timestamp: String) {
        self.id = id
        self.ciphertext = ciphertext
        self.timestamp = timestamp
    }
}

public struct MailboxRotationResult: Codable {
    public let newMailboxId: String
    public let newToken: String

    public init(newMailboxId: String, newToken: String) {
        self.newMailboxId = newMailboxId
        self.newToken = newToken
    }
}

public enum MailboxError: Error {
    case invalidResponse
    case httpError(Int)
}
