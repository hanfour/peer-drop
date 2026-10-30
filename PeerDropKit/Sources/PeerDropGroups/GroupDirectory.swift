import Foundation
import PeerDropAccount

/// Looks up account signing keys used to verify group member signatures.
public protocol GroupDirectory: Sendable {
    func signingKey(accountId: String) async -> Data?
}

/// Resolves signing keys through the account directory and caches successful lookups in memory.
public actor LiveGroupDirectory: GroupDirectory {
    private let account: AccountClient
    private var cache: [String: Data] = [:]

    /// Creates a directory backed by the account API.
    public init(account: AccountClient) {
        self.account = account
    }

    /// Returns nil when lookup fails or the returned entry does not match the requested account.
    public func signingKey(accountId: String) async -> Data? {
        if let cached = cache[accountId] { return cached }
        guard let entry = try? await account.lookup(handle: accountId, includeBundle: false),
              entry.accountId.raw == accountId,
              entry.signingKey.count == 32 else { return nil }
        cache[accountId] = entry.signingKey
        return entry.signingKey
    }
}
