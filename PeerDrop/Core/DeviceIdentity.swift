import Foundation

/// Stable per-install device identifier used for routing invites and APNs pushes.
enum DeviceIdentity {
    private static let key = "peerDropDeviceId"

    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}
