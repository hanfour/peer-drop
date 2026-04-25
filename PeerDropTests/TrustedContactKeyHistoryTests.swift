import XCTest
@testable import PeerDrop

final class TrustedContactKeyHistoryTests: XCTestCase {
    private let testStorageKey = "test-trusted-contacts-keyhistory-\(UUID().uuidString)"

    func test_updatePublicKey_recordsHistoryEntry() {
        let store = TrustedContactStore(storageKey: testStorageKey)
        defer { store.removeAll() }
        let contact = TrustedContact(
            displayName: "Alice",
            identityPublicKey: Data([0xAA]),
            trustLevel: .verified
        )
        store.add(contact)

        store.updatePublicKey(
            for: contact.id,
            newKey: Data([0xBB]),
            trustLevel: .unknown,
            reason: .detectedOnReconnect
        )

        let updated = store.find(byId: contact.id)!
        XCTAssertEqual(updated.keyHistory.count, 1)
        XCTAssertEqual(updated.keyHistory.first?.oldKey, Data([0xAA]))
        XCTAssertEqual(updated.keyHistory.first?.newKey, Data([0xBB]))
        XCTAssertEqual(updated.keyHistory.first?.reason, .detectedOnReconnect)
        XCTAssertEqual(updated.identityPublicKey, Data([0xBB]))
    }

    func test_updatePublicKey_sameKey_noHistoryEntry() {
        let store = TrustedContactStore(storageKey: testStorageKey)
        defer { store.removeAll() }
        let contact = TrustedContact(
            displayName: "Bob",
            identityPublicKey: Data([0xCC]),
            trustLevel: .verified
        )
        store.add(contact)
        store.updatePublicKey(
            for: contact.id,
            newKey: Data([0xCC]),
            trustLevel: .verified,
            reason: .userAcceptedNewKey
        )
        XCTAssertEqual(store.find(byId: contact.id)!.keyHistory.count, 0)
    }

    func test_keyHistory_cappedAt20Entries() {
        let store = TrustedContactStore(storageKey: testStorageKey)
        defer { store.removeAll() }
        let contact = TrustedContact(
            displayName: "Carol",
            identityPublicKey: Data([0x00]),
            trustLevel: .unknown
        )
        store.add(contact)
        // Rotate 25 times: keys 0x01..0x19
        for i in 1...25 {
            store.updatePublicKey(
                for: contact.id,
                newKey: Data([UInt8(i)]),
                trustLevel: .unknown,
                reason: .detectedOnReconnect
            )
        }
        let updated = store.find(byId: contact.id)!
        XCTAssertEqual(updated.keyHistory.count, 20, "history must be capped at 20")
        // The first 5 should have been dropped (rotations 1..5).
        // Oldest remaining is rotation 6: oldKey=Data([0x05]), newKey=Data([0x06]).
        XCTAssertEqual(updated.keyHistory.first?.oldKey, Data([0x05]))
        XCTAssertEqual(updated.keyHistory.first?.newKey, Data([0x06]))
        // Most recent is rotation 25: newKey=Data([0x19]).
        XCTAssertEqual(updated.keyHistory.last?.newKey, Data([0x19]))
    }

    func test_legacyContactWithoutKeyHistory_decodesSuccessfully() throws {
        // Encode a legacy-style JSON without keyHistory field.
        let legacyJSON = """
        {
          "id": "12345678-1234-1234-1234-123456789ABC",
          "displayName": "Legacy",
          "identityPublicKey": "AAEC",
          "trustLevel": "linked",
          "firstConnected": 1700000000,
          "isBlocked": false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let contact = try decoder.decode(TrustedContact.self, from: legacyJSON)
        XCTAssertEqual(contact.keyHistory, [])
        XCTAssertEqual(contact.displayName, "Legacy")
    }

    func test_keyChangeRecord_codable() throws {
        let record = KeyChangeRecord(
            oldKey: Data([0x01, 0x02]),
            newKey: Data([0x03, 0x04]),
            changedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reason: .userAcceptedNewKey
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(KeyChangeRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}
