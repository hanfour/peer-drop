import UIKit
import PeerDropCore
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if case .note(let id) = RelayPushKind.classify(userInfo) {
            NotificationCenter.default.post(name: .openNote, object: nil, userInfo: ["id": id ?? ""])
            NotificationCenter.default.post(name: .didReceiveNotePush, object: nil, userInfo: ["inboxItemId": id ?? ""])
        }
        completionHandler()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushNotificationManager.shared.handleDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotificationManager.shared.handleRegistrationFailure(error) }
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
