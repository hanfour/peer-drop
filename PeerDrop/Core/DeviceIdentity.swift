import Foundation

/// Stable per-install device identifier used for routing invites and APNs pushes.
/// Thread-safe: uses a lock to guarantee exactly one UUID is generated on first access.
enum DeviceIdentity {
    private static let key = "peerDropDeviceId"
    private static let lock = NSLock()
    private static var cached: String?

    static var deviceId: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let existing = UserDefaults.standard.string(forKey: key) {
            cached = existing
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        cached = newId
        return newId
    }
}
