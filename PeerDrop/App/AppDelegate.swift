import UIKit
import CallKit
import UserNotifications

extension Notification.Name {
    static let didReceiveRelayPush = Notification.Name("didReceiveRelayPush")
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var callKitManager: CallKitManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        callKitManager = CallKitManager()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushNotificationManager.shared.handleDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Silently ignore — push is a nice-to-have
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Post to NotificationCenter so PeerDropApp (which owns inboxService) can handle it
        NotificationCenter.default.post(
            name: .didReceiveRelayPush,
            object: nil,
            userInfo: userInfo as? [String: Any] ?? [:]
        )
        completionHandler(.newData)
    }
}
