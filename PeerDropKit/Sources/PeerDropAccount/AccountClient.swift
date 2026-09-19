import Foundation
import PeerDropTransport

/// Registration payload for `POST /v3/account/register`. `Data` fields are
/// encoded as base64 strings via `JSONEncoder.dataEncodingStrategy = .base64`.
public struct RegisterRequest: Encodable, Sendable {
    public var deviceId: String
    public var platform: String
    public var identityKey: Data
    public var signingKey: Data
    public var mailboxId: String
    /// The mailbox's ownership token (`MailboxManager.mailboxToken`). The
    /// worker refuses to bind a mailbox the caller can't prove it owns.
    public var mailboxToken: String
    public var nonce: Data
    public var signature: Data

    public init(deviceId: String, platform: String, identityKey: Data, signingKey: Data, mailboxId: String, mailboxToken: String, nonce: Data, signature: Data) {
        self.deviceId = deviceId
        self.platform = platform
        self.identityKey = identityKey
        self.signingKey = signingKey
        self.mailboxId = mailboxId
        self.mailboxToken = mailboxToken
        self.nonce = nonce
        self.signature = signature
    }
}

public struct RegisterResponse: Decodable, Sendable {
    public let accountId: AccountID
    public let nickname: String?
    public let token: String
    public let expiresInSeconds: Int
}

public struct MeResponse: Decodable, Sendable {
    public let accountId: AccountID
    public let nickname: String?
    public let mailboxId: String
}

public struct DirectoryEntry: Decodable, Equatable, @unchecked Sendable {
    public let accountId: AccountID
    public let nickname: String?
    public let identityKey: Data
    public let signingKey: Data
    public let mailboxId: String
    /// Present only for `lookup(handle:includeBundle: true)`; the worker
    /// consumes one of the recipient's one-time pre-keys to produce it, so
    /// callers must request it only when they are about to send.
    public let preKeyBundle: FetchedPreKeyBundle?

    public init(accountId: AccountID, nickname: String?, identityKey: Data, signingKey: Data, mailboxId: String, preKeyBundle: FetchedPreKeyBundle? = nil) {
        self.accountId = accountId; self.nickname = nickname; self.identityKey = identityKey
        self.signingKey = signingKey; self.mailboxId = mailboxId; self.preKeyBundle = preKeyBundle
    }
}

public enum AccountClientError: Error, Equatable {
    case unauthorized
    case forbidden
    case conflict(String)
    case invalid(String)
    case rateLimited
    case http(Int)
    case invalidResponse
}

/// HTTP client for the worker's `/v3/account/*` and `/v3/directory/*`
/// routes. A plain-old dictionary can't express an explicit JSON `null`
/// (it just omits the key), so `setNickname` sends a small `Encodable`
/// struct instead — see `NicknameBody` below.
public actor AccountClient {
    private let baseURL: URL
    private let session: URLSession
    private let authProvider: @Sendable (inout URLRequest) async -> Void
    private let tokenInvalidator: @Sendable () async -> Void

    /// Default `tokenInvalidator`, hoisted to a static property rather than
    /// an inline closure literal: a closure written directly as an actor
    /// init's default argument spuriously trips
    /// "no 'async' operations occur within 'await' expression" on the
    /// actor-isolated (but synchronous) `DeviceTokenManager.invalidate()`
    /// call, even though the cross-actor call is real and the `await` is
    /// required.
    public static let defaultTokenInvalidator: @Sendable () async -> Void = {
        if #available(iOS 14.0, macOS 11.0, *) {
            await DeviceTokenManager.shared.invalidate()
        }
    }

    public init(
        baseURL: URL? = nil,
        session: URLSession? = nil,
        authProvider: @escaping @Sendable (inout URLRequest) async -> Void = { await WorkerAuthHelper.applyAuth(to: &$0) },
        tokenInvalidator: @escaping @Sendable () async -> Void = AccountClient.defaultTokenInvalidator
    ) {
        self.baseURL = baseURL ?? WorkerURL.current()
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: cfg)
        }
        self.authProvider = authProvider
        self.tokenInvalidator = tokenInvalidator
    }

    // MARK: - Public surface

    public func challenge(deviceId: String) async throws -> Data {
        struct Body: Encodable { let deviceId: String }
        struct R: Decodable { let nonce: String }
        let r: R = try await send("POST", "v3/account/challenge", body: Body(deviceId: deviceId))
        guard let d = Data(base64Encoded: r.nonce), d.count == 32 else { throw AccountClientError.invalidResponse }
        return d
    }

    public func register(_ req: RegisterRequest) async throws -> RegisterResponse {
        try await send("POST", "v3/account/register", body: req)
    }

    public func me() async throws -> MeResponse {
        try await send("GET", "v3/account/me", body: Optional<Empty>.none)
    }

    public func setNickname(_ nickname: String?) async throws -> String? {
        // Swift's synthesized `Encodable` uses `encodeIfPresent` for
        // Optional stored properties, which OMITS the key entirely when
        // nil — the worker requires the `nickname` key to be present
        // (400 `missing_fields` otherwise), even when clearing it to
        // `null`. An explicit `encode(to:)` using the generic
        // `encode(_:forKey:)` overload writes a real JSON `null` instead.
        struct NicknameBody: Encodable {
            let nickname: String?
            enum CodingKeys: String, CodingKey { case nickname }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(nickname, forKey: .nickname)
            }
        }
        struct R: Decodable { let nickname: String? }
        let r: R = try await send("PUT", "v3/account/nickname", body: NicknameBody(nickname: nickname))
        return r.nickname
    }

    public func lookup(handle: String, includeBundle: Bool) async throws -> DirectoryEntry? {
        let escaped = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        let path = "v3/directory/\(escaped)" + (includeBundle ? "?bundle=1" : "")
        do {
            return try await send("GET", path, body: Optional<Empty>.none)
        } catch AccountClientError.http(404) {
            return nil
        }
    }

    public func deleteAccount() async throws {
        let _: Empty = try await send("DELETE", "v3/account", body: Optional<Empty>.none)
    }

    // MARK: - HTTP plumbing

    private struct Empty: Codable {}
    private struct ErrorBody: Decodable { let error: String }

    private func send<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B?, retrying: Bool = true) async throws -> R {
        // `lookup` feeds a user-typed handle into `path`; percent-encoding
        // it can still leave a string URL(string:) rejects, and a force
        // unwrap there would crash the app on a malformed search rather
        // than surfacing an error the UI can show.
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AccountClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            let enc = JSONEncoder()
            enc.dataEncodingStrategy = .base64
            request.httpBody = try enc.encode(body)
        }
        await authProvider(&request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountClientError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            if data.isEmpty, R.self == Empty.self {
                return Empty() as! R
            }
            let dec = JSONDecoder()
            dec.dataDecodingStrategy = .base64
            return try dec.decode(R.self, from: data)
        case 401:
            if retrying {
                await tokenInvalidator()
                return try await send(method, path, body: body, retrying: false)
            }
            throw AccountClientError.unauthorized
        case 403:
            throw AccountClientError.forbidden
        case 404:
            throw AccountClientError.http(404)
        case 409:
            throw AccountClientError.conflict(Self.code(data))
        case 400, 413:
            throw AccountClientError.invalid(Self.code(data))
        case 429:
            throw AccountClientError.rateLimited
        default:
            throw AccountClientError.http(http.statusCode)
        }
    }

    private static func code(_ data: Data) -> String {
        (try? JSONDecoder().decode(ErrorBody.self, from: data).error) ?? "unknown"
    }
}
