#if canImport(UIKit)
import UIKit

final class UIKitRemoteNotificationRegistering: RemoteNotificationRegistering {
    @MainActor
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
#endif
