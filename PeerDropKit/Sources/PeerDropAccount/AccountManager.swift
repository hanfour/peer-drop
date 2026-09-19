import Foundation
import CryptoKit
import PeerDropTransport
import os

/// Everything `AccountManager` needs from the rest of the app to run the
/// anonymous-account registration flow, injected so the state machine can be
/// unit tested without touching Keychain, App Attest, or the network.
public protocol AccountRegistrationDependencies: Sendable {
    var deviceId: String { get }
    var platform: String { get }
    /// Can this build reach `/v3/account/register` at all? True when App
    /// Attest can mint a device token OR the build carries a worker key
    /// (peerdrop-cli, Debug, and the shipped Mac — see `WorkerAuthHelper`).
    /// False is terminal: the account UI says so and never retries.
    var registrationSupported: Bool { get }
    /// Narrower question than `registrationSupported`: will a Bearer token
    /// appear *on its own*? Only App Attest does that. When it is false the
    /// account token minted by `/v3/account/register` is the only Bearer
    /// this device will ever have, so it has to be re-minted (by re-running
    /// registration) before any Bearer-only route — see
    /// `ensureFreshTokenIfNeeded()`.
    var attestSupported: Bool { get }
    func identityKeys() throws -> (identity: Data, signing: Data)
    func sign(_ data: Data) throws -> Data
    /// The device's relay mailbox plus its ownership token — the worker
    /// requires the token to bind the mailbox to an account.
    func currentMailbox() async throws -> (id: String, token: String)
}

@MainActor
public final class AccountManager: ObservableObject {
    public enum Unavailable: Equatable { case attestUnsupported, offline, failed(String) }
    public enum State: Equatable { case idle, registering, ready(Account), unavailable(Unavailable) }
    public enum NicknameError: Error, Equatable { case tooShort, tooLong, invalidCharacters, reserved }
    /// Operations that need an account but were called without one. Used
    /// to be a silent `return`, which read to the UI as "saved" — the
    /// nickname editor dismissed itself having changed nothing.
    public enum AccountManagerError: Error, Equatable { case noAccount }

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "AccountManager")
    @Published public private(set) var state: State = .idle
    private let client: AccountClient
    private let store: AccountStore
    private let deps: AccountRegistrationDependencies
    private let tokenAdopter: @Sendable (String, Int) async -> Void
    /// "Is there a usable Bearer right now?" Injected so the no-App-Attest
    /// path can be tested without a Keychain-backed `DeviceTokenManager`.
    private let tokenIsFresh: @Sendable () async -> Bool
    private var didBootstrap = false
    /// Single in-flight auto-retry, scheduled after a transient (offline or
    /// server-side) failure. Cancelled on success and on `deleteAccount()`.
    private var retryTask: Task<Void, Never>?
    private static let retryDelayNanoseconds: UInt64 = 60_000_000_000

    /// `tokenIsFresh` defaults to `DeviceTokenManager.hasActiveToken()`.
    /// Passed as `nil` rather than a default closure expression because a
    /// default argument is evaluated in the *caller's* context, where this
    /// `@MainActor` type's statics aren't reachable — building it here,
    /// inside the init, keeps the default private to the type.
    public init(client: AccountClient, store: AccountStore, deps: AccountRegistrationDependencies,
                tokenAdopter: @escaping @Sendable (String, Int) async -> Void,
                tokenIsFresh: (@Sendable () async -> Bool)? = nil) {
        self.client = client; self.store = store; self.deps = deps
        self.tokenAdopter = tokenAdopter
        self.tokenIsFresh = tokenIsFresh ?? {
            if #available(iOS 14.0, macOS 11.0, *) {
                return await DeviceTokenManager.shared.hasActiveToken()
            }
            return false
        }
    }

    /// Dependencies that are never actually invoked: the mock init below
    /// jumps straight to `.ready`/`didBootstrap = true`, so nothing ever
    /// calls back into `registerIfNeeded()`'s network/keychain path.
    private struct NoopRegistrationDependencies: AccountRegistrationDependencies {
        var deviceId: String { "" }
        var platform: String { "" }
        var registrationSupported: Bool { true }
        var attestSupported: Bool { true }
        func identityKeys() throws -> (identity: Data, signing: Data) { (Data(), Data()) }
        func sign(_ data: Data) throws -> Data { Data() }
        func currentMailbox() async throws -> (id: String, token: String) { ("", "") }
    }

    /// Screenshot-mode convenience: seeds a manager that is already
    /// `.ready(account)` with `didBootstrap = true`, so `ConnectionManager`'s
    /// `handleScenePhaseChange(.active)` → `bootstrap()` call is a no-op and
    /// no real network/keychain access ever happens. The client points at an
    /// unroutable host and the store lives in a scratch temp directory as
    /// defensive belt-and-braces — neither is ever exercised.
    public convenience init(mock account: Account) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountManager-mock-\(UUID().uuidString)", isDirectory: true)
        self.init(
            client: AccountClient(baseURL: URL(string: "https://screenshot.invalid")!),
            store: AccountStore(storageKey: "mock-account", directory: tempDir),
            deps: NoopRegistrationDependencies(),
            tokenAdopter: { _, _ in },
            tokenIsFresh: { true }
        )
        state = .ready(account)
        didBootstrap = true
    }

    public var account: Account? { if case .ready(let a) = state { return a } else { return nil } }

    /// Loads a persisted account if present; otherwise attempts registration.
    /// Safe to call from multiple scene-phase transitions: once `didBootstrap`
    /// is set, later calls (e.g. every `.active`) delegate to
    /// `registerIfNeeded()` instead of no-op'ing, so a first-launch failure
    /// (offline, server error) gets a real retry the next time the app comes
    /// to the foreground rather than being stuck forever.
    public func bootstrap() async {
        guard !didBootstrap else {
            await registerIfNeeded()
            return
        }
        didBootstrap = true
        if let saved = store.load() { state = .ready(saved); return }
        await registerIfNeeded()
    }

    public func registerIfNeeded() async {
        if case .ready = state { return }
        if case .registering = state { return }
        // Terminal: this device/build has no way to authenticate to the
        // worker at all (no App Attest AND no bundled key), so there is
        // nothing a retry could change. Checked before re-reading
        // `deps.registrationSupported` so this state never re-probes.
        if case .unavailable(.attestUnsupported) = state { return }
        guard deps.registrationSupported else { state = .unavailable(.attestUnsupported); return }
        state = .registering
        do {
            let account = try await performRegistration()
            retryTask?.cancel(); retryTask = nil
            state = .ready(account)
        } catch let e as URLError where Self.isOffline(e) {
            state = .unavailable(.offline)
            scheduleRetry()
        } catch let e as AccountClientError where Self.isUserActionable(e) {
            // 4xx-shaped failures that a timer can't fix — bad/expired
            // credentials, conflicting state, rejected input. The user
            // (or a "Retry" button) drives the next attempt. Note 429 is
            // deliberately NOT in this set: rate limiting DOES clear on
            // its own, so it falls into the auto-retry branch below.
            Self.logger.error("registration rejected: \(String(describing: e), privacy: .public)")
            state = .unavailable(.failed(String(describing: e)))
        } catch {
            // Everything else — 5xx/other HTTP statuses, decode errors,
            // local persistence failures, unexpected errors — is treated as
            // transient and gets one delayed auto-retry.
            Self.logger.error("registration failed: \(String(describing: error), privacy: .public)")
            state = .unavailable(.failed(String(describing: error)))
            scheduleRetry()
        }
    }

    /// The challenge → sign → register round trip. Idempotent server-side
    /// for a signing key that already has an account (it re-binds the
    /// device and re-issues an account token), which is what lets
    /// `ensureFreshTokenIfNeeded()` use it purely to re-mint a Bearer.
    /// Persists the resulting account and returns it; every failure is
    /// thrown for the caller to classify.
    @discardableResult
    private func performRegistration() async throws -> Account {
        let mailbox = try await deps.currentMailbox()
        let keys = try deps.identityKeys()
        let nonce = try await client.challenge(deviceId: deps.deviceId)
        let signature = try deps.sign(Self.registrationMessage(
            nonce: nonce, deviceId: deps.deviceId, identityKey: keys.identity, mailboxId: mailbox.id))
        let resp = try await client.register(RegisterRequest(deviceId: deps.deviceId, platform: deps.platform,
            identityKey: keys.identity, signingKey: keys.signing, mailboxId: mailbox.id,
            mailboxToken: mailbox.token, nonce: nonce, signature: signature))
        await tokenAdopter(resp.token, resp.expiresInSeconds)
        let account = Account(accountId: resp.accountId, nickname: resp.nickname, mailboxId: mailbox.id, createdAt: Date())
        try store.save(account)
        return account
    }

    /// The exact bytes the worker's `verifyRegistrationSignature`
    /// reconstructs: `utf8("peerdrop-account-v2") ‖ nonce(32)
    /// ‖ utf8(deviceId) ‖ sha256(identityKey ‖ utf8(mailboxId))`. The
    /// trailing digest is what binds the identity key and the mailbox to
    /// the signature — v1 signed neither, so both were forgeable under a
    /// replayed (nonce, signature) pair.
    static func registrationMessage(nonce: Data, deviceId: String, identityKey: Data, mailboxId: String) -> Data {
        let bound = Data(SHA256.hash(data: identityKey + Data(mailboxId.utf8)))
        return Data("peerdrop-account-v2".utf8) + nonce + Data(deviceId.utf8) + bound
    }

    /// Mint a fresh account Bearer when this device can't get one from App
    /// Attest. Called before every Bearer-only route (nickname, delete)
    /// and before directory lookups, so a Mac whose 15-minute account
    /// token has lapsed doesn't simply fail with 401 `bearer_required`.
    /// A no-op wherever App Attest works, or while the current token is
    /// still valid.
    private func ensureFreshTokenIfNeeded() async throws {
        guard !deps.attestSupported else { return }
        if await tokenIsFresh() { return }
        try await performRegistration()
    }

    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private static func isUserActionable(_ error: AccountClientError) -> Bool {
        switch error {
        case .invalid, .conflict, .forbidden, .unauthorized:
            return true
        case .rateLimited, .http, .invalidResponse:
            return false
        }
    }

    /// Schedules exactly one delayed retry, replacing any previous one.
    /// Re-checks cancellation after the delay so cancelling (on success or
    /// `deleteAccount()`) actually suppresses the retry instead of firing it
    /// immediately (the naive `try? await Task.sleep(...)` swallows
    /// `CancellationError` and would otherwise call straight through).
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AccountManager.retryDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.registerIfNeeded()
        }
    }

    /// Validates `raw` locally first (so callers get instant, offline
    /// feedback on length/character/reserved-word problems) before touching
    /// the network — this ordering is deliberate and independent of whether
    /// an account is currently `.ready`.
    public func setNickname(_ raw: String?) async throws {
        var value: String? = nil
        if let raw {
            switch Nickname.validate(raw) {
            case .ok(let v): value = v
            case .tooShort: throw NicknameError.tooShort
            case .tooLong: throw NicknameError.tooLong
            case .invalidCharacters: throw NicknameError.invalidCharacters
            case .reserved: throw NicknameError.reserved
            }
        }
        guard account != nil else { throw AccountManagerError.noAccount }
        try await ensureFreshTokenIfNeeded()
        guard var account = account else { throw AccountManagerError.noAccount }
        let confirmed = try await client.setNickname(value)
        account.nickname = confirmed
        try store.save(account)
        state = .ready(account)
    }

    public func lookup(handle: String, includeBundle: Bool = false) async throws -> DirectoryEntry? {
        guard account != nil else { throw AccountManagerError.noAccount }
        try await ensureFreshTokenIfNeeded()
        return try await client.lookup(handle: handle, includeBundle: includeBundle)
    }

    public func refreshFromServer() async {
        guard var account = account, let me = try? await client.me() else { return }
        account.nickname = me.nickname; account.mailboxId = me.mailboxId
        try? store.save(account)   // best-effort cache refresh; failures surface on next explicit save
        state = .ready(account)
    }

    public func deleteAccount() async throws {
        guard account != nil else { throw AccountManagerError.noAccount }
        try await ensureFreshTokenIfNeeded()
        try await client.deleteAccount()
        try store.clear()
        retryTask?.cancel(); retryTask = nil
        state = .idle
        didBootstrap = false
    }
}
