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

    public init(client: AccountClient, store: AccountStore, deps: AccountRegistrationDependencies,
                tokenAdopter: @escaping @Sendable (String, Int) async -> Void) {
        self.client = client; self.store = store; self.deps = deps; self.tokenAdopter = tokenAdopter
    }

    public var account: Account? { if case .ready(let a) = state { return a } else { return nil } }

    /// Loads a persisted account if present; otherwise attempts registration.
    /// Idempotent — safe to call from multiple scene-phase transitions.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        if let saved = store.load() { state = .ready(saved); return }
        await registerIfNeeded()
    }

    public func registerIfNeeded() async {
        if case .ready = state { return }
        if case .registering = state { return }
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
            state = .ready(account)
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .timedOut {
            state = .unavailable(.offline)
        } catch {
            Self.logger.error("registration failed: \(String(describing: error), privacy: .public)")
            state = .unavailable(.failed(String(describing: error)))
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
        state = .idle
        didBootstrap = false
    }
}
