import Foundation
import CryptoKit
import DeviceCheck
import os.log

/// Per-device bearer token cache backed by Apple App Attest.
///
/// First launch: generates a Secure Enclave-bound keypair via
/// `DCAppAttestService.generateKey()`, asks the worker for a server-side
/// challenge, attests the key, and trades the attestation for a
/// short-lived HMAC bearer token. The Secure Enclave key, the
/// Apple-issued `keyId`, and the current token live in Keychain via
/// `KeychainStore`.
///
/// Steady state: when callers ask for an `Authorization: Bearer …`
/// header, this actor checks token expiry, calls
/// `DCAppAttestService.generateAssertion(...)` + the worker's
/// `/v2/device/assert` route to refresh, and hands out the fresh
/// token. Concurrent callers share a single in-flight refresh task.
///
/// Fallback: if App Attest is unavailable (Simulator, dev builds without
/// entitlement, attestation rejected by Apple), this actor returns nil
/// and callers fall through to the legacy `X-API-Key` path the worker
/// still accepts during the v5.3 transition window.
@available(iOS 14.0, *)
actor DeviceTokenManager {

    static let shared = DeviceTokenManager()

    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "DeviceTokenManager")
    private let attestService = DCAppAttestService.shared
    private let session: URLSession

    // Token state — cached in memory; persisted via UserDefaults for the
    // non-sensitive metadata (keyId, expiry) and Keychain for the bearer
    // string itself.
    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private var inFlightRefresh: Task<String?, Never>?

    private init(session: URLSession = .shared) {
        self.session = session
        // Restore from disk so the token survives app restarts inside its
        // 15-minute TTL window.
        self.cachedToken = Self.readKeychainToken()
        if let raw = UserDefaults.standard.object(forKey: Self.expiryKey) as? Date {
            self.tokenExpiresAt = raw
        }
    }

    // MARK: - Public surface

    /// Returns `Authorization: Bearer <token>` ready for `setValue(_:forHTTPHeaderField:)`.
    /// Returns nil when App Attest is unavailable or the worker hasn't been
    /// upgraded yet — callers fall back to `X-API-Key`.
    func bearerHeader() async -> String? {
        guard let token = await ensureValidToken() else { return nil }
        return "Bearer \(token)"
    }

    /// True when the device has successfully completed the App Attest
    /// flow at least once. Used by the Settings push status surface to
    /// show "this device authenticates with the server via App Attest"
    /// instead of the legacy "API key" badge.
    func hasActiveToken() -> Bool {
        guard let _ = cachedToken, let exp = tokenExpiresAt else { return false }
        return exp > Date()
    }

    // MARK: - Core flow

    /// Returns a valid (non-expired) token, refreshing or attesting as
    /// needed. Shares a single in-flight refresh across concurrent
    /// callers via `inFlightRefresh`.
    private func ensureValidToken() async -> String? {
        if let cached = cachedToken, let exp = tokenExpiresAt, exp > Date().addingTimeInterval(60) {
            return cached  // > 1 minute of headroom
        }
        if let in_flight = inFlightRefresh {
            return await in_flight.value
        }
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.refreshOrAttest()
        }
        inFlightRefresh = task
        let result = await task.value
        inFlightRefresh = nil
        return result
    }

    private func refreshOrAttest() async -> String? {
        guard attestService.isSupported else {
            logger.info("App Attest unsupported on this device; bearer-token path disabled")
            return nil
        }

        // If we already have a stored keyId, try assertion first (fast
        // path). Fall back to a fresh attestation only when assertion
        // fails — e.g. the server forgot us after a TTL expiry, or the
        // device has been reinstalled.
        if let keyId = Self.readStoredKeyId() {
            if let token = await tryAssert(keyId: keyId) {
                return token
            }
            logger.info("Assertion path failed; falling back to fresh attestation")
        }
        return await freshAttest()
    }

    private func freshAttest() async -> String? {
        do {
            let keyId = try await attestService.generateKey()
            let challenge = try await fetchChallenge()
            let clientDataHash = SHA256.hash(data: challenge)
            let attestation = try await attestService.attestKey(
                keyId,
                clientDataHash: Data(clientDataHash),
            )
            let token = try await postAttest(keyId: keyId, attestation: attestation, challenge: challenge)
            Self.writeStoredKeyId(keyId)
            storeToken(token.token, expiresInSeconds: token.expiresInSeconds)
            return token.token
        } catch {
            logger.warning("Fresh attestation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func tryAssert(keyId: String) async -> String? {
        do {
            let challenge = try await fetchChallenge()
            let clientData = challenge  // any bytes; server hashes them itself
            let clientDataHash = SHA256.hash(data: clientData)
            let assertion = try await attestService.generateAssertion(
                keyId,
                clientDataHash: Data(clientDataHash),
            )
            let token = try await postAssert(assertion: assertion, clientData: clientData)
            storeToken(token.token, expiresInSeconds: token.expiresInSeconds)
            return token.token
        } catch {
            logger.warning("Assertion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - HTTP — calls into the worker

    private struct TokenResponse: Decodable {
        let token: String
        let expiresInSeconds: Int
    }

    private struct ChallengeResponse: Decodable {
        let challenge: String  // base64
    }

    private func fetchChallenge() async throws -> Data {
        let url = workerBaseURL.appendingPathComponent("v2/device/challenge")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": DeviceIdentity.deviceId])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "DeviceTokenManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "challenge fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            ])
        }
        let decoded = try JSONDecoder().decode(ChallengeResponse.self, from: data)
        guard let bytes = Data(base64Encoded: decoded.challenge) else {
            throw NSError(domain: "DeviceTokenManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "challenge base64 invalid"
            ])
        }
        return bytes
    }

    private func postAttest(keyId: String, attestation: Data, challenge: Data) async throws -> TokenResponse {
        let url = workerBaseURL.appendingPathComponent("v2/device/attest")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Send the raw server-issued challenge bytes — the worker
        // pulls the matching entry from KV (deleting it to prevent
        // replay) and recomputes the clientDataHash itself before
        // running the App Attest verifier.
        let body: [String: String] = [
            "deviceId": DeviceIdentity.deviceId,
            "keyId": keyId,                          // already base64 from DCAppAttestService
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await sendForToken(request: request)
    }

    private func postAssert(assertion: Data, clientData: Data) async throws -> TokenResponse {
        let url = workerBaseURL.appendingPathComponent("v2/device/assert")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "deviceId": DeviceIdentity.deviceId,
            "assertion": assertion.base64EncodedString(),
            "clientData": clientData.base64EncodedString(),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await sendForToken(request: request)
    }

    private func sendForToken(request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DeviceTokenManager", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "non-HTTP response"
            ])
        }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(domain: "DeviceTokenManager", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr.prefix(200))"
            ])
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private var workerBaseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev")!
    }

    // MARK: - Persistence

    private func storeToken(_ token: String, expiresInSeconds: Int) {
        cachedToken = token
        let exp = Date().addingTimeInterval(TimeInterval(expiresInSeconds))
        tokenExpiresAt = exp
        Self.writeKeychainToken(token)
        UserDefaults.standard.set(exp, forKey: Self.expiryKey)
    }

    // MARK: - Keychain / UserDefaults

    /// UserDefaults key for the cached token expiry (the timestamp is
    /// not sensitive; only the bearer string itself lives in Keychain).
    private static let expiryKey = "peerDropDeviceTokenExpiry"

    /// UserDefaults key for the App Attest `keyId` (also not sensitive
    /// — it's a public identifier — but keeping the keypair material
    /// inside the Secure Enclave means we never actually store the key
    /// itself, only Apple's handle to it).
    private static let keyIdKey = "peerDropDeviceAttestKeyId"

    private static let keychainTokenLabel = "peerDropDeviceToken"

    private static func readStoredKeyId() -> String? {
        UserDefaults.standard.string(forKey: keyIdKey)
    }

    private static func writeStoredKeyId(_ keyId: String) {
        UserDefaults.standard.set(keyId, forKey: keyIdKey)
    }

    /// Minimal Keychain wrapper for the bearer token. Token is sensitive
    /// even though short-lived; keeping it in Keychain avoids the
    /// UserDefaults plist file backup vector.
    private static func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: keychainTokenLabel,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychainToken(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: keychainTokenLabel,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
