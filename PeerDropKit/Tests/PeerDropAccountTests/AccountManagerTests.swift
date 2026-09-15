import XCTest
@testable import PeerDropAccount

@MainActor
final class AccountManagerTests: XCTestCase {
    struct Deps: AccountRegistrationDependencies {
        var deviceId = "dev-test-0001"; var platform = "ios"; var attestSupported = true
        var mailbox = "mbx1"
        func identityKeys() throws -> (identity: Data, signing: Data) { (Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)) }
        func sign(_ data: Data) throws -> Data { Data(repeating: 9, count: 64) }
        func currentMailboxId() async throws -> String { mailbox }
    }
    private var dir: URL!
    override func setUp() async throws {
        TestURLProtocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    private func makeManager(deps: Deps = Deps(), adopted: @escaping @Sendable (String, Int) -> Void = { _, _ in }) -> AccountManager {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let client = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg),
                                   authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") }, tokenInvalidator: {})
        return AccountManager(client: client, store: AccountStore(storageKey: "am", directory: dir), deps: deps, tokenAdopter: adopted)
    }

    /// `AccountStore.save()` reads/mints its AES key via `ChatDataEncryptor.shared`,
    /// which needs keychain access. Under `swift test` on a host without a
    /// keychain entitlement this throws `ChatDataEncryptor.EncryptionError
    /// .keychainError` — see `AccountStoreTests.testRoundTripAndClear` and
    /// `PeerDropSecurityTests.TrustedContactStoreTests.testPersistenceRoundTrip`
    /// for the identical, pre-existing environment limitation. `AccountManager
    /// .registerIfNeeded()` folds any `store.save` failure into
    /// `.unavailable(.failed(String(describing: error)))` (same catch-all as a
    /// network failure) rather than reaching `.ready(account)` — that is
    /// expected behaviour on this host, not a defect in `AccountManager`.
    ///
    /// Call this only when an assertion truly needs a `.ready`/persisted
    /// account; skip (via `XCTSkip`) only when the failure matches that
    /// specific keychain error, and fail hard otherwise so a real regression
    /// still gets caught.
    private func skipIfKeychainUnavailable(_ state: AccountManager.State, file: StaticString = #filePath, line: UInt = #line) throws {
        if case .unavailable(.failed(let message)) = state, message.contains("keychainError") {
            throw XCTSkip("AccountStore.save() needs keychain access unavailable under `swift test` on this host (state: \(state)); skipping assertions that require a ready/persisted account")
        }
        XCTFail("expected a ready account, got \(state)", file: file, line: line)
    }

    /// Tiny box so the `@Sendable` `tokenAdopter` closure below can record
    /// its arguments without the compiler flagging "mutation of captured
    /// var in concurrently-executing code" (an error under the Swift 6
    /// language mode) — `AccountManager` is `@MainActor`, so in practice
    /// `tokenAdopter` only ever runs on the main actor within these tests.
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    func testBootstrapRegistersAndPersists() async throws {
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8)),
            .init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"acct-tok","expiresInSeconds":900}"#.utf8)),
        ]
        let adopted = Box<(String, Int)>()
        let m = makeManager(adopted: { adopted.value = ($0, $1) })
        await m.bootstrap()
        // tokenAdopter runs before AccountStore.save(), so this holds even on
        // hosts where the keychain-backed store write fails (see
        // skipIfKeychainUnavailable above).
        XCTAssertEqual(adopted.value?.0, "acct-tok")
        guard m.account != nil else {
            try skipIfKeychainUnavailable(m.state)
            return
        }
        XCTAssertEqual(m.account?.accountId.raw, "7K3MQ2ZD")
        XCTAssertEqual(AccountStore(storageKey: "am", directory: dir).load()?.accountId.raw, "7K3MQ2ZD")
        // second bootstrap uses the store, no network
        TestURLProtocol.reset()
        let m2 = makeManager()
        await m2.bootstrap()
        XCTAssertEqual(m2.account?.accountId.raw, "7K3MQ2ZD")
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }
    func testAttestUnsupportedIsTerminal() async {
        let m = makeManager(deps: Deps(attestSupported: false))
        await m.bootstrap()
        XCTAssertEqual(m.state, .unavailable(.attestUnsupported))
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }
    func testServerErrorBecomesFailedAndRetryable() async throws {
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        let m = makeManager()
        await m.bootstrap()
        guard case .unavailable(.failed) = m.state else { return XCTFail("expected failed, got \(m.state)") }
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8)),
            .init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"t","expiresInSeconds":900}"#.utf8)),
        ]
        await m.registerIfNeeded()
        guard m.account != nil else {
            try skipIfKeychainUnavailable(m.state)
            return
        }
        XCTAssertNotNil(m.account)
    }
    func testSetNicknameValidatesLocallyThenPersists() async throws {
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8)),
            .init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"t","expiresInSeconds":900}"#.utf8)),
            .init(status: 200, body: Data(#"{"nickname":"mochi"}"#.utf8)),
        ]
        let m = makeManager()
        await m.bootstrap()
        // Nickname.validate runs before AccountManager touches the network or
        // requires a `.ready` account, so this assertion is host-independent
        // — it holds even when the keychain-backed store write above failed.
        await XCTAssertThrowsErrorAsync(try await m.setNickname("mo")) { XCTAssertEqual($0 as? AccountManager.NicknameError, .tooShort) }
        guard m.account != nil else {
            try skipIfKeychainUnavailable(m.state)
            return
        }
        try await m.setNickname("mochi")
        XCTAssertEqual(m.account?.nickname, "mochi")
        XCTAssertEqual(AccountStore(storageKey: "am", directory: dir).load()?.nickname, "mochi")
    }

    /// Regression test for the bug where a failed first-launch registration
    /// could never recover: `bootstrap()` used to set `didBootstrap = true`
    /// unconditionally and no-op on every later call, so a `.unavailable`
    /// device stayed stuck even once the network (or the server) recovered
    /// and a later `.active` scene-phase transition called `bootstrap()`
    /// again. `bootstrap()` must now delegate to `registerIfNeeded()` once
    /// `didBootstrap` is already set.
    func testActiveAfterFailureRetries() async throws {
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        let m = makeManager()
        await m.bootstrap()
        guard case .unavailable(.failed) = m.state else { return XCTFail("expected failed, got \(m.state)") }
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8)),
            .init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"t","expiresInSeconds":900}"#.utf8)),
        ]
        // Simulates a later `.active` scene-phase transition, NOT a manual
        // retry call — this is the exact call `ConnectionManager` makes.
        await m.bootstrap()
        guard m.account != nil else {
            try skipIfKeychainUnavailable(m.state)
            return
        }
        XCTAssertEqual(m.account?.accountId.raw, "7K3MQ2ZD")
    }

    func testAttestUnsupportedNeverRetries() async {
        let m = makeManager(deps: Deps(attestSupported: false))
        await m.bootstrap()
        XCTAssertEqual(m.state, .unavailable(.attestUnsupported))
        await m.bootstrap()
        XCTAssertEqual(m.state, .unavailable(.attestUnsupported))
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }

    /// `AccountManager(mock:)` (used by `ConnectionManager.accountManager` in
    /// screenshot mode) must start `.ready` and never touch the network:
    /// `bootstrap()`/`registerIfNeeded()` should both be no-ops on it, since
    /// `didBootstrap = true` and the `.ready` early-return guards in
    /// `registerIfNeeded()` short-circuit before the (dummy) deps or client
    /// are ever exercised.
    func testMockInitIsReadyAndNoop() async {
        let account = Account(accountId: AccountID(raw: "PDRPDEM0")!, nickname: "mochi", mailboxId: "screenshotmailbox", createdAt: Date())
        let m = AccountManager(mock: account)
        XCTAssertEqual(m.state, .ready(account))
        await m.bootstrap()
        await m.registerIfNeeded()
        XCTAssertEqual(m.state, .ready(account))
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }
}
