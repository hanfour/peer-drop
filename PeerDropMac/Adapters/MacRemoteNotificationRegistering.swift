#if canImport(AppKit)
import AppKit
import PeerDropPlatform

/// macOS adapter for `RemoteNotificationRegistering`.
///
/// Wraps `NSApplication.shared.registerForRemoteNotifications()`, the
/// AppKit equivalent of UIKit's same-named method. After invocation, the
/// system delivers either `didRegisterForRemoteNotificationsWithDeviceToken`
/// or `didFailToRegisterForRemoteNotificationsWithError` to `MacAppDelegate`.
@MainActor
final class MacRemoteNotificationRegistering: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        NSApplication.shared.registerForRemoteNotifications()
    }
}
#endif
