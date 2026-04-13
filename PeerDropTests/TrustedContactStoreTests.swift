import XCTest
import CryptoKit
@testable import PeerDrop

final class TrustedContactStoreTests: XCTestCase {

    var store: TrustedContactStore!

    override func setUp() {
        super.setUp()
        store = TrustedContactStore(storageKey: "test-trusted-contacts-\(UUID().uuidString)")
    }

    override func tearDown() {
        store.removeAll()
        super.tearDown()
    }

    private func makeContact(name: String, trust: TrustLevel = .verified) -> TrustedContact {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return TrustedContact(
            displayName: name,
            identityPublicKey: key.publicKey.rawRepresentation,
            trustLevel: trust
        )
    }

    func testAddAndRetrieve() {
        let contact = makeContact(name: "Alice")
        store.add(contact)
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.all.first?.displayName, "Alice")
    }

    func testFindByPublicKey() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            displayName: "Bob",
            identityPublicKey: key.publicKey.rawRepresentation,
            trustLevel: .linked
        )
        store.add(contact)

        let found = store.find(byPublicKey: key.publicKey.rawRepresentation)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.displayName, "Bob")
    }

    func testFindByPublicKeyReturnsNilForUnknown() {
        let unknownKey = Curve25519.KeyAgreement.PrivateKey()
        let found = store.find(byPublicKey: unknownKey.publicKey.rawRepresentation)
        XCTAssertNil(found)
    }

    func testUpdateTrustLevel() {
        let contact = makeContact(name: "Carol", trust: .linked)
        store.add(contact)

        store.updateTrustLevel(for: contact.id, to: .verified)
        let updated = store.find(byId: contact.id)
        XCTAssertEqual(updated?.trustLevel, .verified)
        XCTAssertNotNil(updated?.lastVerified)
    }

    func testBlockContact() {
        let contact = makeContact(name: "Dave")
        store.add(contact)

        store.setBlocked(contact.id, blocked: true)
        XCTAssertTrue(store.find(byId: contact.id)?.isBlocked == true)
    }

    func testRemoveContact() {
        let contact = makeContact(name: "Eve")
        store.add(contact)
        XCTAssertEqual(store.all.count, 1)

        store.remove(contact.id)
        XCTAssertEqual(store.all.count, 0)
    }

    func testDetectKeyChange() {
        let oldKey = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            displayName: "Frank",
            identityPublicKey: oldKey.publicKey.rawRepresentation,
            trustLevel: .verified
        )
        store.add(contact)

        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let change = store.detectKeyChange(
            contactId: contact.id,
            newPublicKey: newKey.publicKey.rawRepresentation
        )
        XCTAssertTrue(change)
    }

    func testDetectKeyChangeReturnsFalseWhenSame() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            displayName: "Grace",
            identityPublicKey: key.publicKey.rawRepresentation,
            trustLevel: .verified
        )
        store.add(contact)

        let change = store.detectKeyChange(
            contactId: contact.id,
            newPublicKey: key.publicKey.rawRepresentation
        )
        XCTAssertFalse(change)
    }

    func testNonBlockedContacts() {
        let c1 = makeContact(name: "A")
        let c2 = makeContact(name: "B")
        store.add(c1)
        store.add(c2)
        store.setBlocked(c1.id, blocked: true)

        XCTAssertEqual(store.nonBlocked.count, 1)
        XCTAssertEqual(store.nonBlocked.first?.displayName, "B")
    }

    func testPersistenceRoundTrip() {
        let key = "test-persist-\(UUID().uuidString)"
        let store1 = TrustedContactStore(storageKey: key)
        let contact = makeContact(name: "Persist")
        store1.add(contact)
        store1.flushPendingSave()

        let store2 = TrustedContactStore(storageKey: key)
        XCTAssertEqual(store2.all.count, 1)
        XCTAssertEqual(store2.all.first?.displayName, "Persist")

        store1.removeAll()
    }
}
