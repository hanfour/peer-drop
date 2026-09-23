import Foundation

/// In-memory cache of directory lookups used to verify signed senders
/// (spec §2.1: 24 h TTL). Per-process; a relaunch simply refetches.
public final class DirectoryCache {
    public struct Entry: Equatable { public let signingKey: Data; public let nickname: String?; public let fetchedAt: Date }
    private let ttl: TimeInterval
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init(ttl: TimeInterval = 86_400, now: @escaping () -> Date = Date.init) { self.ttl = ttl; self.now = now }

    public func get(_ accountId: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[accountId] else { return nil }
        if now().timeIntervalSince(e.fetchedAt) > ttl { entries[accountId] = nil; return nil }
        return e
    }
    public func set(_ accountId: String, signingKey: Data, nickname: String?) {
        lock.lock(); defer { lock.unlock() }
        entries[accountId] = Entry(signingKey: signingKey, nickname: nickname, fetchedAt: now())
    }
}
