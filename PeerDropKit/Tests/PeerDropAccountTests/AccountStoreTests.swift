import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropAccount

final class AccountStoreTests: XCTestCase {
    private var dir: URL!
    /// One injected AES key for the whole test case, so the two
    /// `AccountStore` instances in the round-trip test share it.
    ///
    /// These tests used to go through `ChatDataEncryptor.shared`, which
    /// mints its key in the Keychain — unavailable to the unsigned binary
    /// `swift test` produces on some hosts (errSecMissingEntitlement,
    /// -34018) — and therefore self-skipped, silently disabling the only
    /// coverage of encrypted account persistence. The injected key
    /// exercises the identical encrypt/decrypt path with no Keychain.
    private var encryptor: ChatDataEncryptor!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AccountStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRoundTripAndClear() throws {
        let store = AccountStore(storageKey: "account-test", directory: dir, encryptor: encryptor)
        XCTAssertNil(store.load())
        let account = Account(accountId: AccountID(raw: "7K3MQ2ZD")!, nickname: "mochi", mailboxId: "abc123", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(account)
        XCTAssertEqual(AccountStore(storageKey: "account-test", directory: dir, encryptor: encryptor).load(), account)
        let raw = try Data(contentsOf: dir.appendingPathComponent("account-test.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("7K3MQ2ZD"), "file must be encrypted at rest")
        try store.clear()
        XCTAssertNil(store.load())
    }

    func testCorruptFileLoadsAsNil() throws {
        let store = AccountStore(storageKey: "account-corrupt", directory: dir, encryptor: encryptor)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("account-corrupt.enc"))
        XCTAssertNil(store.load())
    }

    /// A file written under a different key must read as "no account" —
    /// not crash, and not leak anything.
    func testWrongKeyLoadsAsNil() throws {
        let store = AccountStore(storageKey: "account-key", directory: dir, encryptor: encryptor)
        try store.save(Account(accountId: AccountID(raw: "7K3MQ2ZD")!, nickname: nil, mailboxId: "abc123", createdAt: Date()))
        let other = AccountStore(storageKey: "account-key", directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        XCTAssertNil(other.load())
    }
}
