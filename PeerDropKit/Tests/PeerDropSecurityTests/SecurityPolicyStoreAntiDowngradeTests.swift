// PeerDropKit/Tests/PeerDropSecurityTests/SecurityPolicyStoreAntiDowngradeTests.swift
//
// Downgrade protection for the crypto-policy channel: a validly-signed but
// OLDER policy blob must never replace a newer one already in effect. Without
// this, an attacker (or a stale CDN edge) can replay a captured warn-mode blob
// to roll a client back off a stricter policy — the core of the "no rollback"
// gap in the strict-policy rollout.
import XCTest
import CryptoKit
@testable import PeerDropSecurity

@MainActor
final class SecurityPolicyStoreAntiDowngradeTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func devKeyPair() throws -> (priv: Curve25519.Signing.PrivateKey, pub: Data) {
        let workspaceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        struct Key: Codable { let private_key_base64: String; let public_key_base64: String }
        let key = try JSONDecoder().decode(Key.self, from: try Data(contentsOf: workspaceURL.appendingPathComponent("cloudflare-worker/dev-signing-key.json")))
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: key.private_key_base64)!)
        return (priv, Data(base64Encoded: key.public_key_base64)!)
    }

    private func signedBlob(priv: Curve25519.Signing.PrivateKey,
                            issuedAt: UInt64,
                            expiresAt: UInt64,
                            behavior: SecurityPolicy.SPKExpirationBehavior) throws -> Data {
        let policy = SecurityPolicy(
            spkMaxAgeDays: 21,
            spkExpirationBehavior: behavior,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let policyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "issuedAt": issuedAt,
            "expiresAt": expiresAt,
            "policy": policyJSON
        ]
        let canonical = try CanonicalJSON.serialize(payloadDict)
        let signature = try priv.signature(for: canonical).base64EncodedString()
        var blobDict = payloadDict
        blobDict["signature"] = signature
        return try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])
    }

    func test_fetch_olderIssuedAt_isRejected() async throws {
        let (priv, pub) = try devKeyPair()
        let farFuture: UInt64 = 9_000_000_000
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pub],
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )

        // Apply a newer, stricter policy (issuedAt 2000, reject).
        MockURLProtocol.responseData = try signedBlob(priv: priv, issuedAt: 2000, expiresAt: farFuture, behavior: .reject)
        MockURLProtocol.responseStatusCode = 200
        let applied = await store.fetchAndUpdate()
        XCTAssertTrue(applied)
        XCTAssertEqual(store.current.spkExpirationBehavior, .reject)

        // Replay an OLDER (issuedAt 1000) warn policy — must be refused.
        MockURLProtocol.responseData = try signedBlob(priv: priv, issuedAt: 1000, expiresAt: farFuture, behavior: .warn)
        let rolledBack = await store.fetchAndUpdate()
        XCTAssertFalse(rolledBack, "an older-issuedAt policy must not be applied")
        XCTAssertEqual(store.current.spkExpirationBehavior, .reject,
                       "downgrade replay rolled the client back off the stricter policy")
    }
}
