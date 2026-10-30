import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropGroups

final class GroupSecretsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var encryptor: ChatDataEncryptor!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIdentityRoundTrips() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        let identity = GroupIdentity(
            memberId: "M1",
            kind: .account,
            roomPrivateKey: Data(repeating: 0x21, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOwner: true
        )

        try store.saveIdentity(identity, for: "G1")

        XCTAssertEqual(store.identity(for: "G1"), identity)
    }

    func testRoomKeysRoundTripAcrossEpochsAndLatestEpoch() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        let keys = [
            (epoch: UInt32(3), key: Data(repeating: 0x33, count: 32)),
            (epoch: UInt32(1), key: Data(repeating: 0x11, count: 32)),
            (epoch: UInt32(2), key: Data(repeating: 0x22, count: 32)),
        ]

        for entry in keys {
            try store.saveRoomKey(SymmetricKey(data: entry.key), for: "G1", epoch: entry.epoch)
        }

        XCTAssertEqual(store.epochs(for: "G1"), [1, 2, 3])
        XCTAssertEqual(store.latestEpoch(for: "G1"), 3)
        for entry in keys {
            XCTAssertEqual(
                store.roomKey(for: "G1", epoch: entry.epoch)?.withUnsafeBytes { Data($0) },
                entry.key
            )
        }
    }

    func testStoredKeysWithInvalidLengthsAreMissing() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        let groupDirectory = tempDir.appendingPathComponent("G1", isDirectory: true)
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)

        let invalidIdentity = GroupIdentity(
            memberId: "M1",
            kind: .anon,
            roomPrivateKey: Data(repeating: 0x41, count: 31),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOwner: false
        )
        try encryptor.encryptAndWrite(
            JSONEncoder().encode(invalidIdentity),
            to: groupDirectory.appendingPathComponent("identity.enc")
        )
        try encryptor.encryptAndWrite(
            JSONEncoder().encode(["4": Data(repeating: 0x44, count: 31).base64EncodedString()]),
            to: groupDirectory.appendingPathComponent("keys.enc")
        )

        XCTAssertNil(store.identity(for: "G1"))
        XCTAssertNil(store.roomKey(for: "G1", epoch: 4))
        XCTAssertEqual(store.epochs(for: "G1"), [])
        XCTAssertNil(store.latestEpoch(for: "G1"))
    }

    func testRemoveDeletesIdentityAndAllRoomKeys() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        let identity = GroupIdentity(
            memberId: "M1",
            kind: .account,
            roomPrivateKey: Data(repeating: 0x51, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOwner: false
        )
        try store.saveIdentity(identity, for: "G1")
        try store.saveRoomKey(SymmetricKey(data: Data(repeating: 0x61, count: 32)), for: "G1", epoch: 1)
        XCTAssertTrue(store.allGroupIds().contains("G1"))

        try store.remove(group: "G1")

        XCTAssertNil(store.identity(for: "G1"))
        XCTAssertNil(store.roomKey(for: "G1", epoch: 1))
        XCTAssertEqual(store.epochs(for: "G1"), [])
        XCTAssertNil(store.latestEpoch(for: "G1"))
        XCTAssertFalse(store.allGroupIds().contains("G1"))
    }

    func testEncryptedFilesDoNotContainPlaintextRoomKey() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        let privateKey = Data(repeating: 0x17, count: 32)
        let roomKey = Data(repeating: 0x72, count: 32)
        try store.saveIdentity(
            GroupIdentity(
                memberId: "M1",
                kind: .anon,
                roomPrivateKey: privateKey,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOwner: false
            ),
            for: "G1"
        )
        try store.saveRoomKey(SymmetricKey(data: roomKey), for: "G1", epoch: 1)

        let groupDirectory = tempDir.appendingPathComponent("G1", isDirectory: true)
        let encryptedIdentity = try Data(contentsOf: groupDirectory.appendingPathComponent("identity.enc"))
        let encryptedKeys = try Data(contentsOf: groupDirectory.appendingPathComponent("keys.enc"))

        XCTAssertNil(encryptedIdentity.range(of: privateKey))
        XCTAssertNil(encryptedKeys.range(of: roomKey))
        XCTAssertNil(encryptedKeys.range(of: Data(roomKey.base64EncodedString().utf8)))
    }

    func testGroupsAreIsolatedAndEpochsDoNotLeak() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        let a = SymmetricKey(data: Data(repeating: 0xA1, count: 32))
        let b = SymmetricKey(data: Data(repeating: 0xB2, count: 32))
        try store.saveRoomKey(a, for: "G1", epoch: 1)
        try store.saveRoomKey(b, for: "G2", epoch: 1)

        XCTAssertNil(store.roomKey(for: "G1", epoch: 2))
        XCTAssertEqual(store.roomKey(for: "G1", epoch: 1).map { $0.withUnsafeBytes { Data($0) } }, Data(repeating: 0xA1, count: 32))
        try store.remove(group: "G1")
        XCTAssertNil(store.roomKey(for: "G1", epoch: 1))
        XCTAssertEqual(store.roomKey(for: "G2", epoch: 1).map { $0.withUnsafeBytes { Data($0) } }, Data(repeating: 0xB2, count: 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("G1").path))
        XCTAssertNoThrow(try store.remove(group: "never-existed"))
    }

    func testSameEpochOverwriteKeepsLatestValue() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        try store.saveRoomKey(SymmetricKey(data: Data(repeating: 1, count: 32)), for: "G1", epoch: 1)
        try store.saveRoomKey(SymmetricKey(data: Data(repeating: 2, count: 32)), for: "G1", epoch: 1)
        XCTAssertEqual(store.roomKey(for: "G1", epoch: 1).map { $0.withUnsafeBytes { Data($0) } }, Data(repeating: 2, count: 32))
        XCTAssertEqual(store.epochs(for: "G1"), [1])
    }

    func testWrongKeyLengthsAndUnsafeIdsAreRejected() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        XCTAssertThrowsError(try store.saveRoomKey(SymmetricKey(data: Data(repeating: 1, count: 16)), for: "G1", epoch: 1)) {
            XCTAssertEqual($0 as? GroupSecretsStoreError, .invalidKeyLength)
        }
        let identity = GroupIdentity(memberId: "M", kind: .anon, roomPrivateKey: Data(repeating: 1, count: 31), createdAt: Date(), isOwner: false)
        XCTAssertThrowsError(try store.saveIdentity(identity, for: "G1")) {
            XCTAssertEqual($0 as? GroupSecretsStoreError, .invalidKeyLength)
        }
        for bad in ["", "../x", "a/b", ".."] {
            XCTAssertThrowsError(try store.remove(group: bad)) { XCTAssertEqual($0 as? GroupSecretsStoreError, .invalidGroupId) }
        }
    }

    func testUnreadableKeysFileIsNotOverwritten() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        try store.saveRoomKey(SymmetricKey(data: Data(repeating: 1, count: 32)), for: "G1", epoch: 1)
        let file = tempDir.appendingPathComponent("G1").appendingPathComponent("keys.enc")
        try Data("garbage".utf8).write(to: file)

        XCTAssertThrowsError(try store.saveRoomKey(SymmetricKey(data: Data(repeating: 2, count: 32)), for: "G1", epoch: 2)) {
            XCTAssertEqual($0 as? GroupSecretsStoreError, .unreadableKeys)
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("garbage".utf8))
    }

    func testCorruptIdentityReadsAsNilAndNoTempFilesRemain() throws {
        let store = GroupSecretsStore(directory: tempDir, encryptor: encryptor)
        try store.saveRoomKey(SymmetricKey(data: Data(repeating: 1, count: 32)), for: "G1", epoch: 1)
        let dir = tempDir.appendingPathComponent("G1")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("identity.enc"))
        XCTAssertNil(store.identity(for: "G1"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }
}
