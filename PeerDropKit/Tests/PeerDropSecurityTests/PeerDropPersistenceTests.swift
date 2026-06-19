import XCTest
@testable import PeerDropSecurity

final class PeerDropPersistenceTests: XCTestCase {

    // MARK: - Helpers

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerDropPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        // Ensure fileStore is nil at the start of every test (app default path).
        PeerDropPersistence.fileStore = nil
    }

    override func tearDown() {
        // CRITICAL: always reset to nil so other tests (and the app default path)
        // are unaffected.
        PeerDropPersistence.fileStore = nil
        if let dir = tmpDir {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    private func activateStore(namespace: String = "test") {
        PeerDropPersistence.fileStore = .init(directory: tmpDir, namespace: namespace)
    }

    // MARK: - sanitize

    func testSanitize_mixedSeparators() {
        XCTAssertEqual(PeerDropPersistence.sanitize("mac · claude"), "mac-claude")
    }

    func testSanitize_atSign() {
        XCTAssertEqual(PeerDropPersistence.sanitize("claude@proj"), "claude-proj")
    }

    func testSanitize_empty() {
        XCTAssertEqual(PeerDropPersistence.sanitize(""), "default")
    }

    func testSanitize_underscore() {
        XCTAssertEqual(PeerDropPersistence.sanitize("A_B"), "a-b")
    }

    func testSanitize_collapsesMultipleSeparators() {
        // "a---b" should collapse to "a-b"
        XCTAssertEqual(PeerDropPersistence.sanitize("a!!!b"), "a-b")
    }

    func testSanitize_trailingAndLeadingDashes() {
        XCTAssertEqual(PeerDropPersistence.sanitize("!hello!"), "hello")
    }

    func testSanitize_numericOnly() {
        XCTAssertEqual(PeerDropPersistence.sanitize("123"), "123")
    }

    // MARK: - scopedKey

    func testScopedKey_withNilFileStore_returnsBase() {
        // fileStore is nil (set in setUp)
        XCTAssertEqual(PeerDropPersistence.scopedKey("trusted-contacts"), "trusted-contacts")
        XCTAssertEqual(PeerDropPersistence.scopedKey("prekey-store"), "prekey-store")
    }

    func testScopedKey_withFileStore_returnsScopedKey() {
        activateStore(namespace: "alpha")
        XCTAssertEqual(PeerDropPersistence.scopedKey("base"), "base-alpha")
        XCTAssertEqual(PeerDropPersistence.scopedKey("trusted-contacts"), "trusted-contacts-alpha")
    }

    // MARK: - writeKeyFile / readKeyFile — with fileStore nil

    func testReadKeyFile_withNilFileStore_returnsNil() {
        XCTAssertNil(PeerDropPersistence.readKeyFile("any.key"))
    }

    func testWriteKeyFile_withNilFileStore_returnsFalse() {
        let result = PeerDropPersistence.writeKeyFile("any.key", Data([0x01, 0x02]))
        XCTAssertFalse(result)
    }

    // MARK: - writeKeyFile / readKeyFile — with fileStore set

    func testWriteAndReadKeyFile_roundtrip() {
        activateStore()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let writeResult = PeerDropPersistence.writeKeyFile("test.key", payload)
        XCTAssertTrue(writeResult, "write should succeed when fileStore is set")
        let readBack = PeerDropPersistence.readKeyFile("test.key")
        XCTAssertEqual(readBack, payload, "read-back data must equal written data")
    }

    func testWriteKeyFile_setsPermissions0600() throws {
        activateStore()
        let payload = Data([0xAA, 0xBB])
        PeerDropPersistence.writeKeyFile("perms.key", payload)
        let filePath = tmpDir.appendingPathComponent("perms.key").path
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "key file permissions must be 0600")
    }

    func testReadKeyFile_missingName_returnsNil() {
        activateStore()
        XCTAssertNil(PeerDropPersistence.readKeyFile("nonexistent.key"))
    }

    func testWriteKeyFile_createsDirectoryWith0700Permissions() throws {
        activateStore()
        PeerDropPersistence.writeKeyFile("dir-test.key", Data([0x01]))
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700, "key directory permissions must be 0700")
    }

    // MARK: - deleteKeyFile

    func testDeleteKeyFile_withFileStore_removesFile() {
        activateStore()
        PeerDropPersistence.writeKeyFile("to-delete.key", Data([0xFF]))
        PeerDropPersistence.deleteKeyFile("to-delete.key")
        XCTAssertNil(PeerDropPersistence.readKeyFile("to-delete.key"))
    }

    func testDeleteKeyFile_withNilFileStore_isNoOp() {
        // Should not crash when fileStore is nil.
        PeerDropPersistence.deleteKeyFile("no-crash.key")
    }

    // MARK: - Isolation: fileStore reset in tearDown protects other tests

    func testFileStore_isNilAtStartOfEachTest() {
        // This test relies on setUp/tearDown resetting fileStore.
        XCTAssertNil(PeerDropPersistence.fileStore)
    }
}
