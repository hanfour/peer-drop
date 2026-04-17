import Foundation
import UIKit
import UserNotifications
import os.log

/// Handles APNs registration and invite push payload parsing.
@MainActor
final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PushNotificationManager")

    /// Emits when a push-delivered invite arrives (App in background or tap on notification).
    @Published var receivedInvite: RelayInvite?

    private override init() { super.init() }

    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { logger.info("Push permission denied"); return }
            await UIApplication.shared.registerForRemoteNotifications()
        } catch {
            logger.error("Push authorization failed: \(error.localizedDescription)")
        }
    }

    func handleDeviceToken(_ deviceToken: Data) async {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.info("APNs token: \(tokenHex.prefix(8))...")

        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard let url = URL(string: "\(baseURL)/v2/device/register") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "deviceId": DeviceIdentity.deviceId,
            "pushToken": tokenHex,
            "platform": "ios",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                logger.info("Device registered with worker")
            }
        } catch {
            logger.error("Device register failed: \(error.localizedDescription)")
        }
    }

    /// Parse an APNs payload into a RelayInvite.
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard let roomCode = userInfo["roomCode"] as? String,
              let roomToken = userInfo["roomToken"] as? String else {
            logger.warning("Ignoring push without invite fields")
            return
        }
        let senderName = (userInfo["aps"] as? [String: Any])
            .flatMap { ($0["alert"] as? [String: String])?["body"] }
            ?? "Unknown"
        let senderId = userInfo["senderId"] as? String ?? ""
        receivedInvite = RelayInvite(
            roomCode: roomCode,
            roomToken: roomToken,
            senderName: senderName,
            senderId: senderId,
            source: .apns
        )
    }
}

/// Shared invite payload model.
struct RelayInvite: Identifiable, Equatable {
    enum Source { case websocket, apns }
    var id: String { roomCode + ":" + (senderId.isEmpty ? senderName : senderId) }
    let roomCode: String
    let roomToken: String
    let senderName: String
    let senderId: String
    let source: Source
}
