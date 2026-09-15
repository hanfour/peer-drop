import XCTest
import PeerDropSecurity
@testable import PeerDropAccount

final class AccountStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AccountStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRoundTripAndClear() throws {
        let store = AccountStore(storageKey: "account-test", directory: dir)
        XCTAssertNil(store.load())
        let account = Account(accountId: AccountID(raw: "7K3MQ2ZD")!, nickname: "mochi", mailboxId: "abc123", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        do {
            try store.save(account)
        } catch ChatDataEncryptor.EncryptionError.keychainError(let status) {
            // ChatDataEncryptor.shared needs keychain access to mint/read its
            // AES key. Some sandboxes running `swift test` (unsigned test
            // binary, no keychain entitlement) fail here with
            // errSecMissingEntitlement (-34018) — a pre-existing environment
            // limitation (see PeerDropSecurityTests.TrustedContactStoreTests.
            // testPersistenceRoundTrip, which fails the same way on such
            // hosts), not a defect in AccountStore. Skip only this specific
            // error; any other failure must propagate and fail the test.
            throw XCTSkip("keychain unavailable under swift test on this host (OSStatus \(status))")
        }
        XCTAssertEqual(AccountStore(storageKey: "account-test", directory: dir).load(), account)
        let raw = try Data(contentsOf: dir.appendingPathComponent("account-test.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("7K3MQ2ZD"), "file must be encrypted at rest")
        try store.clear()
        XCTAssertNil(store.load())
    }
    func testCorruptFileLoadsAsNil() throws {
        let store = AccountStore(storageKey: "account-corrupt", directory: dir)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("account-corrupt.enc"))
        XCTAssertNil(store.load())
    }
}
