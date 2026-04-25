import XCTest
@testable import PeerDrop

/// Verifies the transactional consume path added in v3.4 (Task A.3):
/// consumed OTP ids must be persisted synchronously before in-memory removal,
/// so a crash can never expose a consumed OTP for replay on next launch.
final class PreKeyStoreTransactionalTests: XCTestCase {
    private static let testStorageKey = "test-prekey-store-transactional"

    override func setUp() {
        super.setUp()
        cleanup()
    }

    override func tearDown() {
        cleanup()
        super.tearDown()
    }

    private func cleanup() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(Self.testStorageKey).enc"))
    }

    func test_consumedOTP_persistsImmediately() throws {
        let store = PreKeyStore(storageKey: Self.testStorageKey)
        // The fresh store schedules a debounced save in init; flush it so the
        // disk image exists before we test the consume path.
        store.flush()
        let bundle = store.generatePreKeyBundle()
        let firstOtpId = bundle.oneTimePreKeys.first!.id

        let consumed = try store.consumeOneTimePreKey(id: firstOtpId)
        XCTAssertNotNil(consumed)

        // No flush() — verify save was synchronous by reloading immediately.
        let reloaded = PreKeyStore(storageKey: Self.testStorageKey)
        let reloadedBundle = reloaded.generatePreKeyBundle()
        XCTAssertFalse(
            reloadedBundle.oneTimePreKeys.contains { $0.id == firstOtpId },
            "Consumed OTP must not reappear after reload"
        )
    }

    func test_doubleConsume_returnsNil() throws {
        let store = PreKeyStore(storageKey: Self.testStorageKey)
        let bundle = store.generatePreKeyBundle()
        let id = bundle.oneTimePreKeys.first!.id

        let first = try store.consumeOneTimePreKey(id: id)
        XCTAssertNotNil(first)
        let second = try store.consumeOneTimePreKey(id: id)
        XCTAssertNil(second, "Re-consuming a consumed OTP must return nil")
    }

    func test_unknownIdConsume_returnsNil() throws {
        let store = PreKeyStore(storageKey: Self.testStorageKey)
        XCTAssertNil(try store.consumeOneTimePreKey(id: 999_999))
    }

    func test_consumedSet_evictsLeakedOTPOnLoad() throws {
        // Simulate a crash scenario: the OTP id is recorded in the consumed
        // set, and on the next launch we reload. The OTP must not surface.
        let store = PreKeyStore(storageKey: Self.testStorageKey)
        let bundle = store.generatePreKeyBundle()
        let leakedId = bundle.oneTimePreKeys.first!.id
        // Consume normally first to register the id in the consumed set
        _ = try store.consumeOneTimePreKey(id: leakedId)

        // Verify reloading does NOT surface that id
        let reloaded = PreKeyStore(storageKey: Self.testStorageKey)
        XCTAssertFalse(
            reloaded.generatePreKeyBundle().oneTimePreKeys.contains { $0.id == leakedId }
        )
        // And reloaded store rejects re-consume
        XCTAssertNil(try reloaded.consumeOneTimePreKey(id: leakedId))
    }
}
