import Foundation

/// The server-side account settings the app can change. `AccountClient` is the production
/// conformance; tests inject a fake.
public protocol AccountSettingsService: Sendable {
    func fetchNotePush() async throws -> Bool
    func updateNotePush(_ on: Bool) async throws -> Bool
}

extension AccountClient: AccountSettingsService {}

/// 「紙條通知」: the global, per-account switch for note push (default on). The truth lives on the
/// server; this model shows the last value it knew (cached in `UserDefaults`) and only ever
/// changes what it shows after the server confirmed - a failed request leaves everything as it was.
@MainActor
public final class NotePushSetting: ObservableObject {
    public static let cacheKey = "peerDropNotePushCached"

    @Published public private(set) var notePush: Bool
    @Published public private(set) var isUpdating = false
    /// Set when the last `set` or `refresh` failed; cleared by the next success.
    @Published public private(set) var lastError: String?

    private let service: AccountSettingsService
    private let defaults: UserDefaults

    public init(service: AccountSettingsService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        // Absent key = never fetched = the server default (on).
        self.notePush = defaults.object(forKey: Self.cacheKey) as? Bool ?? true
    }

    /// Adopts the server's value. A failure keeps the cached value on screen.
    public func refresh() async {
        guard !isUpdating else { return }
        do {
            adopt(try await service.fetchNotePush())
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Optimistic: the switch flips at once, then reverts (and the cache stays put) if the
    /// server does not confirm. A second change while one is in flight is ignored.
    public func set(_ on: Bool) async {
        guard !isUpdating, on != notePush else { return }
        let previous = notePush
        isUpdating = true
        notePush = on
        defer { isUpdating = false }
        do {
            adopt(try await service.updateNotePush(on))
            lastError = nil
        } catch {
            notePush = previous
            lastError = String(describing: error)
        }
    }

    private func adopt(_ value: Bool) {
        notePush = value
        defaults.set(value, forKey: Self.cacheKey)
    }
}
