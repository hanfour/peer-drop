import XCTest
@testable import PeerDropSecurity

/// Pivot 2026-09: `petSnapshot` was removed from `TrustedContact`. Records
/// persisted by v4–v5 still carry the key; they must keep decoding, and a
/// re-encode must not resurrect it.
final class TrustedContactLegacyPetSnapshotTests: XCTestCase {

    private func legacyJSON() -> Data {
        let key = Data(repeating: 0x42, count: 32).base64EncodedString()
        return """
        {
          "id": "7B4F1C2A-0000-4000-8000-000000000001",
          "displayName": "Old Peer",
          "identityPublicKey": "\(key)",
          "trustLevel": "linked",
          "firstConnected": 0,
          "petSnapshot": "3q2+7w=="
        }
        """.data(using: .utf8)!
    }

    func testLegacyRecordWithPetSnapshotStillDecodes() throws {
        let contact = try JSONDecoder().decode(TrustedContact.self, from: legacyJSON())
        XCTAssertEqual(contact.displayName, "Old Peer")
        XCTAssertEqual(contact.trustLevel, .linked)
        XCTAssertEqual(contact.identityPublicKey.count, 32)
        XCTAssertFalse(contact.isBlocked)
        XCTAssertTrue(contact.keyHistory.isEmpty)
    }

    func testReencodedRecordDoesNotContainPetSnapshot() throws {
        let contact = try JSONDecoder().decode(TrustedContact.self, from: legacyJSON())
        let out = try JSONEncoder().encode(contact)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertFalse(text.contains("petSnapshot"), "petSnapshot must not be re-encoded: \(text)")
    }
}
