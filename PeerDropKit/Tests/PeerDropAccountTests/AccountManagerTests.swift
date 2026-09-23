import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropAccount

@MainActor
final class AccountManagerTests: XCTestCase {
    struct Deps: AccountRegistrationDependencies {
        var deviceId = "dev-test-0001"; var platform = "ios"
        var registrationSupported = true
        var attestSupported = true
        var mailbox = "mbx1"
        var mailboxToken = "mbx-token-1"
        func identityKeys() throws -> (identity: Data, signing: Data) { (Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)) }
        func sign(_ data: Data) throws -> Data { Data(repeating: 9, count: 64) }
        func currentMailbox() async throws -> (id: String, token: String) { (mailbox, mailboxToken) }
    }
    private var dir: URL!
    /// Injected so `AccountStore.save()` never touches the Keychain — see
    /// `AccountStoreTests`. Without it these tests self-skipped on hosts
    /// where `swift test` runs unsigned.
    private var encryptor: ChatDataEncryptor!

    override func setUp() async throws {
        TestURLProtocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
    }

    private func makeManager(deps: Deps = Deps(),
                             adopted: @escaping @Sendable (String, Int) -> Void = { _, _ in },
                             tokenIsFresh: (@Sendable () async -> Bool)? = nil) -> AccountManager {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let client = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg),
                                   authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") }, tokenInvalidator: {})
        return AccountManager(client: client, store: AccountStore(storageKey: "am", directory: dir, encryptor: encryptor),
                              deps: deps, tokenAdopter: adopted, tokenIsFresh: tokenIsFresh)
    }

    private func store() -> AccountStore { AccountStore(storageKey: "am", directory: dir, encryptor: encryptor) }

    private static func nonceResponse() -> TestURLProtocol.Stub {
        .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8))
    }
    private static func registerResponse(_ accountId: String = "7K3MQ2ZD", nickname: String = "null", token: String = "acct-tok") -> TestURLProtocol.Stub {
        .init(status: 201, body: Data(#"{"accountId":"\#(accountId)","nickname":\#(nickname),"token":"\#(token)","expiresInSeconds":900}"#.utf8))
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
        TestURLProtocol.queue = [Self.nonceResponse(), Self.registerResponse()]
        let adopted = Box<(String, Int)>()
        let m = makeManager(adopted: { adopted.value = ($0, $1) })
        await m.bootstrap()
        XCTAssertEqual(adopted.value?.0, "acct-tok")
        XCTAssertEqual(m.account?.accountId.raw, "7K3MQ2ZD")
        XCTAssertEqual(store().load()?.accountId.raw, "7K3MQ2ZD")
        // second bootstrap uses the store, no network
        TestURLProtocol.reset()
        let m2 = makeManager()
        await m2.bootstrap()
        XCTAssertEqual(m2.account?.accountId.raw, "7K3MQ2ZD")
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }

    /// The register body must carry the mailbox token (the worker rejects
    /// it with 403 `mailbox_not_owned` otherwise) and a signature over the
    /// v2 message, which binds the identity key and mailbox id.
    func testRegisterSendsMailboxTokenAndSignsTheV2Message() async throws {
        TestURLProtocol.queue = [Self.nonceResponse(), Self.registerResponse()]
        let signed = Box<Data>()
        struct SigningDeps: AccountRegistrationDependencies {
            let recorder: @Sendable (Data) -> Void
            var deviceId: String { "dev-test-0001" }
            var platform: String { "ios" }
            var registrationSupported: Bool { true }
            var attestSupported: Bool { true }
            func identityKeys() throws -> (identity: Data, signing: Data) { (Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)) }
            func sign(_ data: Data) throws -> Data { recorder(data); return Data(repeating: 9, count: 64) }
            func currentMailbox() async throws -> (id: String, token: String) { ("mbx1", "mbx-token-1") }
        }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let client = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg),
                                   authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") }, tokenInvalidator: {})
        let m = AccountManager(client: client, store: store(), deps: SigningDeps(recorder: { signed.value = $0 }), tokenAdopter: { _, _ in })
        await m.bootstrap()
        XCTAssertNotNil(m.account)

        let nonce = Data(repeating: 5, count: 32)
        let expectedBound = Data(SHA256.hash(data: Data(repeating: 1, count: 32) + Data("mbx1".utf8)))
        XCTAssertEqual(signed.value, Data("peerdrop-account-v2".utf8) + nonce + Data("dev-test-0001".utf8) + expectedBound)

        let body = try XCTUnwrap(TestURLProtocol.requests.last?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["mailboxToken"] as? String, "mbx-token-1")
        XCTAssertEqual(json["mailboxId"] as? String, "mbx1")
    }

    func testRegistrationUnsupportedIsTerminal() async {
        let m = makeManager(deps: Deps(registrationSupported: false))
        await m.bootstrap()
        XCTAssertEqual(m.state, .unavailable(.attestUnsupported))
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }

    func testServerErrorBecomesFailedAndRetryable() async throws {
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        let m = makeManager()
        await m.bootstrap()
        guard case .unavailable(.failed) = m.state else { return XCTFail("expected failed, got \(m.state)") }
        TestURLProtocol.queue = [Self.nonceResponse(), Self.registerResponse(token: "t")]
        await m.registerIfNeeded()
        XCTAssertNotNil(m.account)
    }

    func testSetNicknameValidatesLocallyThenPersists() async throws {
        TestURLProtocol.queue = [
            Self.nonceResponse(),
            Self.registerResponse(token: "t"),
            .init(status: 200, body: Data(#"{"nickname":"mochi"}"#.utf8)),
        ]
        let m = makeManager()
        await m.bootstrap()
        // Nickname.validate runs before AccountManager touches the network
        // or requires a `.ready` account.
        await XCTAssertThrowsErrorAsync(try await m.setNickname("mo")) { XCTAssertEqual($0 as? AccountManager.NicknameError, .tooShort) }
        try await m.setNickname("mochi")
        XCTAssertEqual(m.account?.nickname, "mochi")
        XCTAssertEqual(store().load()?.nickname, "mochi")
    }

    /// Without an account these used to `return` silently, so the nickname
    /// editor dismissed itself as if the change had been saved.
    func testAccountlessOperationsThrowNoAccount() async throws {
        let m = makeManager()
        await XCTAssertThrowsErrorAsync(try await m.setNickname("mochi")) { XCTAssertEqual($0 as? AccountManager.AccountManagerError, .noAccount) }
        await XCTAssertThrowsErrorAsync(try await m.deleteAccount()) { XCTAssertEqual($0 as? AccountManager.AccountManagerError, .noAccount) }
        await XCTAssertThrowsErrorAsync(_ = try await m.lookup(handle: "mochi")) { XCTAssertEqual($0 as? AccountManager.AccountManagerError, .noAccount) }
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }

    /// A Mac has no App Attest, so the account token minted at
    /// registration is its only Bearer. When it has lapsed, the mutating
    /// routes must re-run challenge+register first — otherwise the worker
    /// answers 401 `bearer_required`.
    func testSetNicknameReMintsTheTokenWhenAppAttestIsUnavailable() async throws {
        TestURLProtocol.queue = [Self.nonceResponse(), Self.registerResponse(token: "first")]
        var deps = Deps(); deps.attestSupported = false; deps.platform = "macos"
        let m = makeManager(deps: deps, tokenIsFresh: { false })
        await m.bootstrap()
        XCTAssertNotNil(m.account)
        TestURLProtocol.reset()

        TestURLProtocol.queue = [
            Self.nonceResponse(),
            Self.registerResponse(token: "second"),
            .init(status: 200, body: Data(#"{"nickname":"mochi"}"#.utf8)),
        ]
        try await m.setNickname("mochi")
        let paths = TestURLProtocol.requests.map { $0.url?.path ?? "" }
        XCTAssertEqual(paths, ["/v3/account/challenge", "/v3/account/register", "/v3/account/nickname"],
                       "expected a challenge+register before the PUT, got \(paths)")
        XCTAssertEqual(m.account?.nickname, "mochi")
    }

    /// …and it must NOT re-register when the Bearer is still valid.
    func testSetNicknameSkipsReMintingWhenTheTokenIsFresh() async throws {
        TestURLProtocol.queue = [Self.nonceResponse(), Self.registerResponse(token: "first")]
        var deps = Deps(); deps.attestSupported = false
        let m = makeManager(deps: deps, tokenIsFresh: { true })
        await m.bootstrap()
        TestURLProtocol.reset()

        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"nickname":"mochi"}"#.utf8))]
        try await m.setNickname("mochi")
        XCTAssertEqual(TestURLProtocol.requests.map { $0.url?.path ?? "" }, ["/v3/account/nickname"])
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
        TestURLProtocol.queue = [Self.nonceResponse(), Self.registerResponse(token: "t")]
        // Simulates a later `.active` scene-phase transition, NOT a manual
        // retry call — this is the exact call `ConnectionManager` makes.
        await m.bootstrap()
        XCTAssertEqual(m.account?.accountId.raw, "7K3MQ2ZD")
    }

    func testRegistrationUnsupportedNeverRetries() async {
        let m = makeManager(deps: Deps(registrationSupported: false))
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
