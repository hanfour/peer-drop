import Foundation

/// Single source of truth for the relay worker base URL (UserDefaults-overridable).
public enum WorkerURL {
    public static let defaultsKey = "peerDropWorkerURL"
    public static let legacyDefaultsKey = "workerBaseURL"   // pre-6.1 MailboxClient key
    public static let production = URL(string: "https://peerdrop-signal.hanfourhuang.workers.dev")!

    public static func current(defaults: UserDefaults = .standard) -> URL {
        if let s = defaults.string(forKey: defaultsKey), let u = URL(string: s), !s.isEmpty { return u }
        return production
    }

    /// One-shot: move a value stored under the legacy key to the canonical key.
    public static func migrateLegacyKey(defaults: UserDefaults = .standard) {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey) else { return }
        if defaults.string(forKey: defaultsKey) == nil { defaults.set(legacy, forKey: defaultsKey) }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}
