import XCTest
import CryptoKit
@testable import PeerDrop

final class PreKeyBundleTimestampTests: XCTestCase {

    // MARK: - Helpers

    /// Construct a minimal PreKeyBundle with controlled timestamp/signature values.
    private func makeMinimalBundle(timestamp: UInt64?, signature: Data?) throws -> PreKeyBundle {
        let signedPreKey = try SignedPreKey.generate(id: 1, signingKey: IdentityKeyManager.shared)
        return PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: signedPreKey.asPublic(),
            oneTimePreKeys: [],
            signedPreKeyTimestamp: timestamp,
            signedPreKeyTimestampSignature: signature
        )
    }

    // MARK: - Tests

    /// v5.0–v5.3 wire format (no timestamp fields) must still decode.
    func test_legacy_bundle_decodes_without_timestamp() throws {
        let bundle = try makeMinimalBundle(timestamp: nil, signature: nil)
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)
        XCTAssertNil(decoded.signedPreKeyTimestamp)
        XCTAssertNil(decoded.signedPreKeyTimestampSignature)
    }

    /// Verify that JSON lacking the new keys also decodes correctly (simulates
    /// a v5.0–v5.3 emitter whose bundle never contained the new fields).
    func test_legacy_json_without_new_fields_decodes_to_nil() throws {
        // Build a v5.4 bundle, encode it, strip the new keys, then re-decode.
        let bundle = try makeMinimalBundle(timestamp: 1_748_000_000, signature: Data([0xAB]))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)) as! [String: Any]
        json.removeValue(forKey: "signedPreKeyTimestamp")
        json.removeValue(forKey: "signedPreKeyTimestampSignature")
        let strippedData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: strippedData)
        XCTAssertNil(decoded.signedPreKeyTimestamp)
        XCTAssertNil(decoded.signedPreKeyTimestampSignature)
    }

    /// v5.4+ wire format (both fields present) round-trips correctly.
    func test_v5_4_bundle_round_trips_timestamp_and_signature() throws {
        let expectedTimestamp: UInt64 = 1_748_000_000
        let expectedSig = Data([0xAB, 0xCD, 0xEF])
        let bundle = try makeMinimalBundle(timestamp: expectedTimestamp, signature: expectedSig)
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)
        XCTAssertEqual(decoded.signedPreKeyTimestamp, expectedTimestamp)
        XCTAssertEqual(decoded.signedPreKeyTimestampSignature, expectedSig)
    }

    /// Only the timestamp signature present (signature without timestamp) — both
    /// fields are independently optional so partial presence is also valid.
    func test_only_timestamp_present_roundtrips() throws {
        let bundle = try makeMinimalBundle(timestamp: 1_748_000_000, signature: nil)
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)
        XCTAssertEqual(decoded.signedPreKeyTimestamp, 1_748_000_000)
        XCTAssertNil(decoded.signedPreKeyTimestampSignature)
    }

    /// Decoding JSON that has the new fields but is missing `signedPreKey`
    /// (a required field) must still fail — the new optional fields must not
    /// accidentally loosen the requirement for the existing required fields.
    func test_missing_required_signedPreKey_still_fails() throws {
        let json = #"""
        {
          "identityKey": "AAA=",
          "signingKey": "AAA=",
          "oneTimePreKeys": [],
          "signedPreKeyTimestamp": 1748000000,
          "signedPreKeyTimestampSignature": "AA=="
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PreKeyBundle.self, from: json))
    }
}
