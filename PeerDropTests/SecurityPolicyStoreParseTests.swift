import XCTest
import CryptoKit
@testable import PeerDrop

final class SecurityPolicyStoreParseTests: XCTestCase {

    private func loadTestPublicKey() throws -> Data {
        let url = Bundle(for: type(of: self)).url(
            forResource: "test-signing-key",
            withExtension: "json",
            subdirectory: "policy"
        ) ?? Bundle(for: type(of: self)).url(
            forResource: "test-signing-key",
            withExtension: "json"
        )!
        struct KeyFile: Codable { let public_key_base64: String }
        let data = try Data(contentsOf: url)
        let key = try JSONDecoder().decode(KeyFile.self, from: data)
        return Data(base64Encoded: key.public_key_base64)!
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = Bundle(for: type(of: self)).url(
            forResource: name,
            withExtension: "json",
            subdirectory: "policy"
        ) ?? Bundle(for: type(of: self)).url(
            forResource: name,
            withExtension: "json"
        )!
        return try Data(contentsOf: url)
    }

    func test_valid_fixture_parses_andReturnsBundledDefault() throws {
        let pubKey = try loadTestPublicKey()
        let data = try loadFixture("valid")
        let result = try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: [pubKey])
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.policy, .bundledDefault)
    }

    func test_tamperedSig_fixture_throws_invalidSignature() throws {
        let pubKey = try loadTestPublicKey()
        let data = try loadFixture("tampered-sig")
        XCTAssertThrowsError(try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: [pubKey])) { error in
            guard case SecurityPolicyStore.ParseError.invalidSignature = error else {
                return XCTFail("expected invalidSignature, got \(error)")
            }
        }
    }

    func test_malformedJson_fixture_throws_malformedJSON() throws {
        let pubKey = try loadTestPublicKey()
        let data = try loadFixture("malformed-json")
        XCTAssertThrowsError(try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: [pubKey])) { error in
            guard case SecurityPolicyStore.ParseError.malformedJSON = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    func test_unsupportedVersion_fixture_throws_unsupportedSchemaVersion() throws {
        let pubKey = try loadTestPublicKey()
        let data = try loadFixture("unsupported-version")
        XCTAssertThrowsError(try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: [pubKey])) { error in
            guard case SecurityPolicyStore.ParseError.unsupportedSchemaVersion(let v) = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(v, 999)
        }
    }

    func test_expired_fixture_parses_but_isStillReturned() throws {
        // Expiration is informational at the parse layer — `expired.json` is
        // signed correctly and has schemaVersion=1, so parseSignedPolicy
        // returns it. The CALLER (SecurityPolicyStore.fetchAndUpdate, Task 4.6)
        // decides what to do based on expiresAt vs Date().
        let pubKey = try loadTestPublicKey()
        let data = try loadFixture("expired")
        let result = try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: [pubKey])
        XCTAssertLessThan(TimeInterval(result.expiresAt), Date().timeIntervalSince1970)
    }

    func test_emptyPublicKeys_throws_invalidSignature() throws {
        let data = try loadFixture("valid")
        XCTAssertThrowsError(try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: [])) { error in
            guard case SecurityPolicyStore.ParseError.invalidSignature = error else {
                return XCTFail("expected invalidSignature, got \(error)")
            }
        }
    }

    func test_invariantViolation_throws() throws {
        // Construct a signed payload with a policy that violates the
        // pruneWindow >= spkMaxAge * 4 invariant. We need to sign it ourselves
        // with the test-only signing key.
        let url = Bundle(for: type(of: self)).url(
            forResource: "test-signing-key", withExtension: "json", subdirectory: "policy"
        ) ?? Bundle(for: type(of: self)).url(
            forResource: "test-signing-key", withExtension: "json"
        )!
        struct KeyFile: Codable {
            let private_key_base64: String
            let public_key_base64: String
        }
        let keyData = try Data(contentsOf: url)
        let key = try JSONDecoder().decode(KeyFile.self, from: keyData)
        let privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: key.private_key_base64)!)
        let pubKey = Data(base64Encoded: key.public_key_base64)!

        // Invariant-violating policy: spkMaxAgeDays=30 → required pruneWindow=120 > 90
        let badPolicy = SecurityPolicy(
            spkMaxAgeDays: 30,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90  // < 30 * 4 = 120, violates invariant
        )

        // Build the signed envelope manually so we control the bytes.
        let policyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(badPolicy)) as! [String: Any]
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "issuedAt": 1_748_000_000,
            "expiresAt": 1_750_592_000,
            "policy": policyJSON
        ]
        let payload = try CanonicalJSON.serialize(payloadDict)
        let signature = try privKey.signature(for: payload)

        var blobDict = payloadDict
        blobDict["signature"] = signature.base64EncodedString()
        let blobData = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])

        XCTAssertThrowsError(try SecurityPolicyStore.parseSignedPolicy(blobData, publicKeys: [pubKey])) { error in
            guard case SecurityPolicyStore.ParseError.invariantViolation = error else {
                return XCTFail("expected invariantViolation, got \(error)")
            }
        }
    }
}
