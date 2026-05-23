import XCTest
@testable import PeerDrop

final class SignedCryptoPolicyTests: XCTestCase {

    func test_signedPolicy_roundTrips() throws {
        let blob = SignedCryptoPolicy(
            schemaVersion: 1,
            issuedAt: 1748000000,
            expiresAt: 1750592000,
            policy: .bundledDefault,
            signature: "AAA="
        )
        let encoded = try JSONEncoder().encode(blob)
        let decoded = try JSONDecoder().decode(SignedCryptoPolicy.self, from: encoded)
        XCTAssertEqual(decoded.schemaVersion, blob.schemaVersion)
        XCTAssertEqual(decoded.issuedAt, blob.issuedAt)
        XCTAssertEqual(decoded.expiresAt, blob.expiresAt)
        XCTAssertEqual(decoded.policy, blob.policy)
        XCTAssertEqual(decoded.signature, blob.signature)
    }

    func test_signedPolicy_jsonShape() throws {
        let blob = SignedCryptoPolicy(
            schemaVersion: 1,
            issuedAt: 1748000000,
            expiresAt: 1750592000,
            policy: .bundledDefault,
            signature: "AAA="
        )
        let data = try JSONEncoder().encode(blob)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["issuedAt"] as? UInt64, 1748000000)
        XCTAssertEqual(json["expiresAt"] as? UInt64, 1750592000)
        XCTAssertEqual(json["signature"] as? String, "AAA=")
        XCTAssertNotNil(json["policy"] as? [String: Any], "policy must be a nested JSON object (spec §5.1)")
    }
}
