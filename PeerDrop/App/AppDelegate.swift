import UIKit
import PeerDropCore
import CallKit
import UserNotifications

extension Notification.Name {
    static let didReceiveRelayPush = Notification.Name("didReceiveRelayPush")
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var callKitManager: CallKitManager?
    /// Wired by `PeerDropApp.onAppear` once the `@StateObject` exists.
    /// `AppDelegate` doesn't own it — it's a weak observer used only so
    /// `didReceiveRemoteNotification` can await the diary/diaryKey sync
    /// directly (F2) instead of always going through NotificationCenter.
    weak var connectionManager: ConnectionManager?

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
        switch RelayPushKind.classify(userInfo) {
        case .note(let id):
            NotificationCenter.default.post(name: .openNote, object: nil, userInfo: ["id": id ?? ""])
            NotificationCenter.default.post(name: .didReceiveNotePush, object: nil, userInfo: ["inboxItemId": id ?? ""])
        case .diary(_, let diaryId, let seq):
            // Spec §4: tapping any diary notification opens that diary
            // (selectedTab = 4 on iOS) and scrolls to `seq` when present.
            var info: [String: Any] = ["diaryId": diaryId]
            if let seq { info["seq"] = seq }
            NotificationCenter.default.post(name: .openDiary, object: nil, userInfo: info)
        default:
            break
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
        switch RelayPushKind.classify(userInfo) {
        case .diary, .diaryKey:
            // Spec §4: the diary/diaryKey sync must finish (or time out)
            // BEFORE the completion handler runs — completing early let
            // iOS suspend the app mid-sync. `connectionManager` performs
            // the sync directly via `ConnectionManager.handleDiaryPush`
            // rather than round-tripping through NotificationCenter, so
            // this path is the sole trigger for this push — no
            // `.didReceiveRelayPush`/`.didReceiveDiaryPush` repost here,
            // which would just re-run the same sync a second time
            // (DiaryStore's per-diary serial gate + sync short-circuit
            // make that safe, but not preferred: running it once is
            // simpler to reason about, and DiaryStore/NotesStore are
            // `@Published`-observed directly by the UI so no separate
            // "refresh" notification is needed once the sync lands).
            guard let connectionManager else {
                // Not wired yet (e.g. a push arrives before
                // PeerDropApp.onAppear has run) — fall back to the pre-F2
                // broadcast path rather than dropping the push.
                NotificationCenter.default.post(
                    name: .didReceiveRelayPush, object: nil, userInfo: userInfo as? [String: Any] ?? [:])
                completionHandler(.newData)
                return
            }
            Task {
                await Self.runBounded(seconds: 25) {
                    await connectionManager.handleDiaryPush(userInfo: userInfo)
                }
                // The push itself is the "data" — a sync timeout/failure is
                // never reported as `.failed`, and the handler fires
                // exactly once on every path through this method.
                completionHandler(.newData)
            }
        case .note, .chatInvite, .other:
            // Post to NotificationCenter so PeerDropApp (which owns inboxService) can handle it
            NotificationCenter.default.post(
                name: .didReceiveRelayPush,
                object: nil,
                userInfo: userInfo as? [String: Any] ?? [:]
            )
            completionHandler(.newData)
        }
    }

    /// Runs `work` and returns as soon as it finishes or `seconds` elapses,
    /// whichever comes first — the loser is simply abandoned (never
    /// cancelled or awaited), which is what makes this an actual bound
    /// rather than `withTaskGroup`'s implicit "await every child task
    /// before returning" behaviour.
    private static func runBounded(seconds: UInt64, _ work: @escaping () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeGate()
            Task {
                await work()
                await gate.resumeOnce(continuation)
            }
            Task {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                await gate.resumeOnce(continuation)
            }
        }
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once even though two
/// independent unstructured `Task`s race to resume it.
private actor ResumeGate {
    private var didResume = false

    func resumeOnce(_ continuation: CheckedContinuation<Void, Never>) {
        guard !didResume else { return }
        didResume = true
        continuation.resume()
    }
}
