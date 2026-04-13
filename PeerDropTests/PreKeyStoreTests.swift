import XCTest
import CryptoKit
@testable import PeerDrop

final class PreKeyStoreTests: XCTestCase {

    var store: PreKeyStore!

    override func setUp() {
        super.setUp()
        store = PreKeyStore(storageKey: "test-prekeys-\(UUID().uuidString)")
    }

    override func tearDown() {
        store.deleteAll()
        super.tearDown()
    }

    func testInitialSignedPreKeyGeneration() {
        XCTAssertNotNil(store.currentSignedPreKey)
        XCTAssertEqual(store.currentSignedPreKey.publicKey.count, 32)
    }

    func testInitialOneTimePreKeysGeneration() {
        XCTAssertEqual(store.availableOneTimePreKeyCount, PreKeyStore.initialOneTimePreKeyCount)
    }

    func testConsumeOneTimePreKey() throws {
        let initialCount = store.availableOneTimePreKeyCount
        let consumed = try store.consumeOneTimePreKey(id: 0)
        XCTAssertNotNil(consumed)
        XCTAssertEqual(store.availableOneTimePreKeyCount, initialCount - 1)
    }

    func testConsumeNonExistentKeyReturnsNil() throws {
        let consumed = try store.consumeOneTimePreKey(id: 99999)
        XCTAssertNil(consumed)
    }

    func testAutoReplenishAfterConsume() throws {
        // Consume keys until we cross the replenish threshold
        let threshold = PreKeyStore.replenishThreshold
        let initial = PreKeyStore.initialOneTimePreKeyCount
        for i in 0..<UInt32(initial - threshold) {
            _ = try store.consumeOneTimePreKey(id: i)
        }
        // Should still be at threshold (not yet triggered)
        XCTAssertEqual(store.availableOneTimePreKeyCount, threshold)

        // Consuming one more drops below threshold → auto-replenish fires
        let triggerKey = try store.consumeOneTimePreKey(id: UInt32(initial - threshold))
        XCTAssertNotNil(triggerKey)
        XCTAssertGreaterThanOrEqual(store.availableOneTimePreKeyCount, initial - 1)
    }

    func testExplicitReplenishWhenAlreadyFull() {
        let before = store.availableOneTimePreKeyCount
        store.replenishOneTimePreKeysIfNeeded()
        XCTAssertEqual(store.availableOneTimePreKeyCount, before)
    }

    func testGeneratePreKeyBundle() {
        let bundle = store.generatePreKeyBundle()
        XCTAssertEqual(bundle.identityKey.count, 32)
        XCTAssertEqual(bundle.signingKey.count, 32)
        XCTAssertFalse(bundle.signedPreKey.signature.isEmpty)
        XCTAssertEqual(bundle.oneTimePreKeys.count, PreKeyStore.initialOneTimePreKeyCount)
    }

    func testSignedPreKeyRotation() {
        let oldId = store.currentSignedPreKey.id
        store.rotateSignedPreKeyIfNeeded(forceRotate: true)
        let newId = store.currentSignedPreKey.id
        XCTAssertNotEqual(oldId, newId)
    }

    func testLookupSignedPreKeyById() throws {
        let currentId = store.currentSignedPreKey.id
        let found = try store.signedPreKey(for: currentId)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.publicKey, store.currentSignedPreKey.publicKey)
    }

    func testPersistenceRoundTrip() {
        let key = "test-persist-prekeys-\(UUID().uuidString)"
        let store1 = PreKeyStore(storageKey: key)
        let bundle1 = store1.generatePreKeyBundle()
        store1.flush()

        let store2 = PreKeyStore(storageKey: key)
        let bundle2 = store2.generatePreKeyBundle()

        XCTAssertEqual(bundle1.signedPreKey.id, bundle2.signedPreKey.id)
        XCTAssertEqual(bundle1.signedPreKey.publicKey, bundle2.signedPreKey.publicKey)

        store1.deleteAll()
    }
}
