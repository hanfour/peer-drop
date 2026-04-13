import Foundation
import os.log

/// HTTP client for the v2 zero-knowledge relay API.
/// Handles pre-key registration, message delivery, and mailbox management.
actor MailboxClient {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "MailboxClient")

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? URL(string:
            UserDefaults.standard.string(forKey: "workerBaseURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        )!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Pre-Key Management

    func registerPreKeys(mailboxId: String, bundle: PreKeyBundle, token: String? = nil) async throws -> String {
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

    func fetchPreKeyBundle(mailboxId: String) async throws -> FetchedPreKeyBundle {
        let url = baseURL.appendingPathComponent("v2/keys/\(mailboxId)")
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try JSONDecoder().decode(FetchedPreKeyBundle.self, from: data)
    }

    // MARK: - Message Delivery

    func sendMessage(to mailboxId: String, ciphertext: Data, pow: ProofOfWorkToken) async throws {
        let url = baseURL.appendingPathComponent("v2/messages/\(mailboxId)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = SendMessageRequest(
            ciphertext: ciphertext.base64EncodedString(),
            pow: pow
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func fetchMessages(mailboxId: String, token: String) async throws -> [MailboxMessage] {
        let url = baseURL.appendingPathComponent("v2/messages")
        var request = URLRequest(url: url)
        request.setValue(mailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(token, forHTTPHeaderField: "X-Mailbox-Token")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([MailboxMessage].self, from: data)
    }

    // MARK: - Mailbox Management

    func rotateMailbox(oldMailboxId: String, oldToken: String) async throws -> MailboxRotationResult {
        let url = baseURL.appendingPathComponent("v2/mailbox/rotate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(oldMailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(oldToken, forHTTPHeaderField: "X-Mailbox-Token")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(MailboxRotationResult.self, from: data)
    }

    func revokeKeys(mailboxId: String, token: String) async throws {
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
    let token: String
}

/// Server returns a single one-time pre-key (consumed), not the full array
struct FetchedPreKeyBundle: Codable {
    let identityKey: Data
    let signingKey: Data
    let signedPreKey: PublicSignedPreKey
    let oneTimePreKey: PublicOneTimePreKey?
}

struct SendMessageRequest: Codable {
    let ciphertext: String
    let pow: ProofOfWorkToken
}

struct ProofOfWorkToken: Codable {
    let challenge: String
    let proof: UInt64
}

struct MailboxMessage: Codable, Identifiable {
    let id: String
    let ciphertext: String
    let timestamp: String
}

struct MailboxRotationResult: Codable {
    let newMailboxId: String
    let newToken: String
}

enum MailboxError: Error {
    case invalidResponse
    case httpError(Int)
}
