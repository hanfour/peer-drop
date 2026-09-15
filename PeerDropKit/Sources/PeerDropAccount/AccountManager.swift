import Foundation
import os

/// Everything `AccountManager` needs from the rest of the app to run the
/// anonymous-account registration flow, injected so the state machine can be
/// unit tested without touching Keychain, App Attest, or the network.
public protocol AccountRegistrationDependencies: Sendable {
    var deviceId: String { get }
    var platform: String { get }
    var attestSupported: Bool { get }
    func identityKeys() throws -> (identity: Data, signing: Data)
    func sign(_ data: Data) throws -> Data
    func currentMailboxId() async throws -> String
}

@MainActor
public final class AccountManager: ObservableObject {
    public enum Unavailable: Equatable { case attestUnsupported, offline, failed(String) }
    public enum State: Equatable { case idle, registering, ready(Account), unavailable(Unavailable) }
    public enum NicknameError: Error, Equatable { case tooShort, tooLong, invalidCharacters, reserved }

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "AccountManager")
    @Published public private(set) var state: State = .idle
    private let client: AccountClient
    private let store: AccountStore
    private let deps: AccountRegistrationDependencies
    private let tokenAdopter: @Sendable (String, Int) async -> Void
    private var didBootstrap = false
    /// Single in-flight auto-retry, scheduled after a transient (offline or
    /// server-side) failure. Cancelled on success and on `deleteAccount()`.
    private var retryTask: Task<Void, Never>?
    private static let retryDelayNanoseconds: UInt64 = 60_000_000_000

    public init(client: AccountClient, store: AccountStore, deps: AccountRegistrationDependencies,
                tokenAdopter: @escaping @Sendable (String, Int) async -> Void) {
        self.client = client; self.store = store; self.deps = deps; self.tokenAdopter = tokenAdopter
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
        // Terminal: this device/build can never satisfy App Attest, so
        // there is nothing a retry could change. Checked before re-reading
        // `deps.attestSupported` so this state never re-probes.
        if case .unavailable(.attestUnsupported) = state { return }
        guard deps.attestSupported else { state = .unavailable(.attestUnsupported); return }
        state = .registering
        do {
            let mailboxId = try await deps.currentMailboxId()
            let keys = try deps.identityKeys()
            let nonce = try await client.challenge(deviceId: deps.deviceId)
            let message = Data("peerdrop-account-v1".utf8) + nonce + Data(deps.deviceId.utf8)
            let signature = try deps.sign(message)
            let resp = try await client.register(RegisterRequest(deviceId: deps.deviceId, platform: deps.platform,
                identityKey: keys.identity, signingKey: keys.signing, mailboxId: mailboxId, nonce: nonce, signature: signature))
            await tokenAdopter(resp.token, resp.expiresInSeconds)
            let account = Account(accountId: resp.accountId, nickname: resp.nickname, mailboxId: mailboxId, createdAt: Date())
            try store.save(account)
            retryTask?.cancel(); retryTask = nil
            state = .ready(account)
        } catch let e as URLError where Self.isOffline(e) {
            state = .unavailable(.offline)
            scheduleRetry()
        } catch let e as AccountClientError where Self.isUserActionable(e) {
            // 4xx-shaped failures (bad/expired credentials, conflicting
            // state, rejected input, rate limiting the caller itself caused)
            // — the user (or a "Retry" button) drives the next attempt, not
            // a timer.
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
        guard var account = account else { return }
        let confirmed = try await client.setNickname(value)
        account.nickname = confirmed
        try store.save(account)
        state = .ready(account)
    }

    public func lookup(handle: String) async throws -> DirectoryEntry? { try await client.lookup(handle: handle, includeBundle: false) }

    public func refreshFromServer() async {
        guard var account = account, let me = try? await client.me() else { return }
        account.nickname = me.nickname; account.mailboxId = me.mailboxId
        try? store.save(account)   // best-effort cache refresh; failures surface on next explicit save
        state = .ready(account)
    }

    public func deleteAccount() async throws {
        try await client.deleteAccount()
        try store.clear()
        retryTask?.cancel(); retryTask = nil
        state = .idle
        didBootstrap = false
    }
}
