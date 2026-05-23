import XCTest
@testable import PeerDrop

/// PR2 shape-only tests for the 5 signed-policy JSON fixtures.
///
/// These tests verify that each fixture file is present in the test bundle and
/// exhibits the structural characteristic that PR4's SecurityPolicyStore.parseSignedPolicy()
/// will exercise (valid shape, expired timestamp, signature byte mutation, JSON parse
/// failure, unsupported schemaVersion). The actual signature verification and error-branch
/// tests land in PR4's SecurityPolicyStoreParseTests.
final class PolicyFixtureTests: XCTestCase {

    // MARK: - Bundle lookup helper

    /// Look up a JSON resource by name, trying the "policy" subdirectory first
    /// (for bundle layouts that preserve directory structure) and falling back
    /// to the bundle root (for flat-bundle layouts produced by xcodegen).
    private func policyURL(named name: String) -> URL? {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "json", subdirectory: "policy")
            ?? bundle.url(forResource: name, withExtension: "json")
    }

    // MARK: - test-signing-key.json

    func test_signingKey_isPresent() throws {
        let url = policyURL(named: "test-signing-key")
        XCTAssertNotNil(url, "test-signing-key.json missing from test bundle")

        let data = try Data(contentsOf: url!)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Must carry both key halves and the TEST-ONLY label.
        XCTAssertNotNil(obj["private_key_base64"] as? String, "private_key_base64 missing")
        XCTAssertNotNil(obj["public_key_base64"] as? String, "public_key_base64 missing")
        let comment = obj["comment"] as? String ?? ""
        XCTAssertTrue(
            comment.contains("TEST-ONLY"),
            "comment must contain \"TEST-ONLY\" to clearly mark the key as non-production"
        )
    }

    // MARK: - valid.json

    func test_validFixture_decodes_andPreservesShape() throws {
        let url = policyURL(named: "valid")
        XCTAssertNotNil(url, "valid.json missing from test bundle")

        let data = try Data(contentsOf: url!)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(obj["signature"] as? String, "signature field missing")

        let policy = try XCTUnwrap(obj["policy"] as? [String: Any])
        XCTAssertEqual(policy["spkMaxAgeDays"] as? Int, 21)
        XCTAssertEqual(policy["spkExpirationBehavior"] as? String, "warn")

        let opkB = try XCTUnwrap(policy["opkExhaustionBehavior"] as? [String: String])
        XCTAssertEqual(opkB["legacy"], "proceedWithoutDH4")
        XCTAssertEqual(opkB["strict"], "failClosed")
    }

    // MARK: - expired.json

    func test_expiredFixture_hasExpiredTimestamp() throws {
        let url = policyURL(named: "expired")
        XCTAssertNotNil(url, "expired.json missing from test bundle")

        let data = try Data(contentsOf: url!)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // expiresAt must be genuinely in the past.
        let exp = (obj["expiresAt"] as? Int)
            ?? (obj["expiresAt"] as? Double).flatMap { Int($0) }
            ?? 0
        XCTAssertLessThan(
            TimeInterval(exp),
            Date().timeIntervalSince1970,
            "expired.json's expiresAt must be in the past (got \(exp))"
        )

        // The fixture must still carry a signature field — PR4 will verify it
        // is valid before checking the timestamp.
        XCTAssertNotNil(obj["signature"] as? String, "expired.json must have a signature field")
    }

    // MARK: - tampered-sig.json

    func test_tamperedSigFixture_hasSignatureDifferentFromValid() throws {
        let validURL = policyURL(named: "valid")
        let tamperedURL = policyURL(named: "tampered-sig")
        XCTAssertNotNil(validURL, "valid.json missing from test bundle")
        XCTAssertNotNil(tamperedURL, "tampered-sig.json missing from test bundle")

        let validObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: validURL!)) as! [String: Any]
        let tamperedObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: tamperedURL!)) as! [String: Any]

        let validSig = try XCTUnwrap(validObj["signature"] as? String)
        let tamperedSig = try XCTUnwrap(tamperedObj["signature"] as? String)

        XCTAssertNotEqual(
            validSig, tamperedSig,
            "tampered-sig.json must carry a different signature than valid.json"
        )

        // Both decode from base64 without error (the mutation is a byte flip,
        // not truncation, so the length and base64 alphabet are unchanged).
        let validBytes = try XCTUnwrap(Data(base64Encoded: validSig))
        let tamperedBytes = try XCTUnwrap(Data(base64Encoded: tamperedSig))
        XCTAssertEqual(validBytes.count, tamperedBytes.count,
                       "tampered signature must have the same byte length as the valid one")
    }

    // MARK: - malformed-json.json

    func test_malformedFixture_failsToDecode() throws {
        let url = policyURL(named: "malformed-json")
        XCTAssertNotNil(url, "malformed-json.json missing from test bundle")

        let data = try Data(contentsOf: url!)
        XCTAssertThrowsError(
            try JSONSerialization.jsonObject(with: data),
            "malformed-json.json must not parse as valid JSON"
        )
    }

    // MARK: - unsupported-version.json

    func test_unsupportedVersionFixture_hasVersion999() throws {
        let url = policyURL(named: "unsupported-version")
        XCTAssertNotNil(url, "unsupported-version.json missing from test bundle")

        let data = try Data(contentsOf: url!)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(
            obj["schemaVersion"] as? Int, 999,
            "unsupported-version.json must have schemaVersion=999"
        )
        // Must also carry a signature so PR4 can confirm the rejection is for
        // version, not for missing/invalid sig.
        XCTAssertNotNil(obj["signature"] as? String, "unsupported-version.json must have a signature field")
    }
}
