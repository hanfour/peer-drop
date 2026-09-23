import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropDiary

final class DiaryKeyStoreTests: XCTestCase {
    private var tempDir: URL!
    private var encryptor: ChatDataEncryptor!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testKeyForUnknownDiaryIsNil() {
        let store = DiaryKeyStore(directory: tempDir, encryptor: encryptor)
        XCTAssertNil(store.key(for: "D1"))
    }

    func testSaveThenKeyRoundTrips() throws {
        let store = DiaryKeyStore(directory: tempDir, encryptor: encryptor)
        let key = SymmetricKey(size: .bits256)
        try store.save(key: key, for: "D1")

        let loaded = store.key(for: "D1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
    }

    func testKeysForDifferentDiariesAreIndependent() throws {
        let store = DiaryKeyStore(directory: tempDir, encryptor: encryptor)
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        try store.save(key: k1, for: "D1")
        try store.save(key: k2, for: "D2")

        XCTAssertEqual(store.key(for: "D1")?.withUnsafeBytes { Data($0) }, k1.withUnsafeBytes { Data($0) })
        XCTAssertEqual(store.key(for: "D2")?.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
    }

    func testSaveOverwritesAPreviousKeyForTheSameDiary() throws {
        let store = DiaryKeyStore(directory: tempDir, encryptor: encryptor)
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        try store.save(key: k1, for: "D1")
        try store.save(key: k2, for: "D1")

        XCTAssertEqual(store.key(for: "D1")?.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
    }

    /// The write goes through `ChatDataEncryptor.encryptAndWrite`, which
    /// writes via `Data.write(options: .atomic)` — assert the on-disk file
    /// is a single complete write (no `.tmp` sibling left behind) rather
    /// than re-testing atomicity semantics the OS already guarantees.
    func testSaveWritesASingleCompleteFileNoTemporarySiblings() throws {
        let store = DiaryKeyStore(directory: tempDir, encryptor: encryptor)
        try store.save(key: SymmetricKey(size: .bits256), for: "D1")

        let dir = tempDir.appendingPathComponent("D1", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["key.enc"])
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let nestedRoot = tempDir.appendingPathComponent("nested/does/not/exist/yet", isDirectory: true)
        let store = DiaryKeyStore(directory: nestedRoot, encryptor: encryptor)
        try store.save(key: SymmetricKey(size: .bits256), for: "D1")
        XCTAssertNotNil(store.key(for: "D1"))
    }

    func testRemoveKeyDeletesItAndIsANoOpWhenAlreadyAbsent() throws {
        let store = DiaryKeyStore(directory: tempDir, encryptor: encryptor)
        try store.save(key: SymmetricKey(size: .bits256), for: "D1")
        XCTAssertNotNil(store.key(for: "D1"))

        try store.removeKey(for: "D1")
        XCTAssertNil(store.key(for: "D1"))

        // Removing again must not throw.
        try store.removeKey(for: "D1")
    }
}
