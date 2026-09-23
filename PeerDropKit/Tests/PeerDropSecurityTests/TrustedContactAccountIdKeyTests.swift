import XCTest
@testable import PeerDropSecurity

/// `TrustedContact.accountId` is a rename of the old `userId` property — the
/// on-disk / wire key stays `"userId"` (via an explicit `CodingKeys` case)
/// so existing persisted records keep decoding without a migration. These
/// tests pin that contract directly against raw JSON, independent of the
/// round-trip test in `TrustedContactTests`.
final class TrustedContactAccountIdKeyTests: XCTestCase {
    func testDecodesLegacyUserIdKeyIntoAccountId() throws {
        let fixture: [String: Any] = [
            "id": UUID().uuidString,
            "displayName": "Legacy Peer",
            "identityPublicKey": Data(repeating: 0xAB, count: 32).base64EncodedString(),
            "trustLevel": "linked",
            "firstConnected": 0,
            "userId": "7K3MQ2ZD",
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let contact = try JSONDecoder().decode(TrustedContact.self, from: data)
        XCTAssertEqual(contact.accountId, "7K3MQ2ZD")
    }

    func testEncodesAccountIdUnderTheUserIdKey() throws {
        let contact = TrustedContact(
            displayName: "Bob",
            identityPublicKey: Data(repeating: 0xCD, count: 32),
            trustLevel: .verified,
            accountId: "7K3MQ2ZD"
        )
        let data = try JSONEncoder().encode(contact)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""userId":"7K3MQ2ZD""#), "expected a literal userId key in \(json)")
        XCTAssertFalse(json.contains("accountId"), "the Swift property name must not leak into the on-disk JSON: \(json)")
    }
}
