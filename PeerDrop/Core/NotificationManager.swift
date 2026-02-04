import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch { return false }
    }

    func postIncomingConnection(from peerName: String) {
        guard UserDefaults.standard.bool(forKey: "peerDropNotificationsEnabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Incoming Connection"
        content.body = "\(peerName) wants to connect"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "incoming-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func postChatMessage(from peerName: String, text: String) {
        guard UserDefaults.standard.bool(forKey: "peerDropNotificationsEnabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = peerName
        content.body = String(text.prefix(100))
        content.sound = .default
        let request = UNNotificationRequest(identifier: "chat-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func postTransferComplete(fileName: String, success: Bool) {
        guard UserDefaults.standard.bool(forKey: "peerDropNotificationsEnabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = success ? "Transfer Complete" : "Transfer Failed"
        content.body = fileName
        content.sound = .default
        let request = UNNotificationRequest(identifier: "transfer-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
