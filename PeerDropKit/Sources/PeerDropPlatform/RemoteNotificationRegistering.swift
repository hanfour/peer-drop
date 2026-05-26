import Foundation

/// Abstracts the platform-specific APNs token registration call.
/// iOS: UIApplication.shared.registerForRemoteNotifications()
/// macOS (M2): NSApplication.shared.registerForRemoteNotifications()
public protocol RemoteNotificationRegistering {
    @MainActor
    func registerForRemoteNotifications()
}
