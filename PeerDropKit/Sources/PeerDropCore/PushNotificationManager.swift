import Foundation
import PeerDropTransport
import PeerDropPlatform
import UserNotifications
import os.log

/// Handles APNs registration and invite push payload parsing.
@MainActor
public final class PushNotificationManager: NSObject, ObservableObject {
    public static let shared = PushNotificationManager()
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PushNotificationManager")

    /// Emits when a push-delivered invite arrives (App in background or tap on notification).
    @Published public var receivedInvite: RelayInvite?

    /// User-grant status from `UNUserNotificationCenter`. Refreshed by
    /// `refreshAuthorizationStatus()` on app foreground.
    @Published public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Where the APNs registration handshake stands. Drives the Settings
    /// "Push notification status" row — without this, the v5.0–v5.2 silent
    /// swallow on `didFailToRegisterForRemoteNotificationsWithError` made
    /// the entire push pipeline broken-by-default invisible to the user.
    @Published public private(set) var registrationState: RegistrationState = .notRequested

    public enum RegistrationState: Equatable {
        /// Permission never asked, or permission denied — no registration attempted.
        case notRequested
        /// `registerForRemoteNotifications()` called, awaiting iOS callback.
        case registering
        /// APNs token received and POST'd to the worker. Stores the leading
        /// 8 hex chars for user-visible identification (full token never
        /// surfaces in UI for security; it's already in worker storage).
        case registered(tokenPrefix: String, syncedWithWorker: Bool)
        /// iOS rejected the registration — usually missing `aps-environment`
        /// entitlement, network failure during init, or rate-limit.
        case failed(reason: String)
    }

    /// Called by InboxService when it flushes queued invites after push-triggered reconnect.
    var onInboxFlush: ((RelayInvite) -> Void)?

    private override init() { super.init() }

    /// Re-read permission status from the system. Cheap; safe to call
    /// every time the app foregrounds. Catches the case where the user
    /// toggled the system permission outside the app between sessions.
    public func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            self.authorizationStatus = settings.authorizationStatus
        }
    }

    public func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            guard granted else {
                logger.info("Push permission denied")
                registrationState = .notRequested
                return
            }
            registrationState = .registering
            await MainActor.run {
                PlatformDependencies.shared.remoteNotifications().registerForRemoteNotifications()
            }
        } catch {
            logger.error("Push authorization failed: \(error.localizedDescription)")
            registrationState = .failed(reason: error.localizedDescription)
        }
    }

    /// Called by AppDelegate's `didFailToRegisterForRemoteNotificationsWithError`.
    /// Replaces the prior silent-ignore — failure is now visible in the
    /// Settings row and the logger subsystem. The most common cause is the
    /// `aps-environment` entitlement missing from the build (the bug present
    /// in v5.0–v5.2 that this method was added to catch).
    public func handleRegistrationFailure(_ error: Error) {
        let nsError = error as NSError
        // NSError code 3000 from NSCocoaErrorDomain on this callback is iOS's
        // way of saying "no aps-environment entitlement" — surface it
        // explicitly so the next operator doesn't have to spelunk.
        let hint: String
        if nsError.domain == "NSCocoaErrorDomain" && nsError.code == 3000 {
            hint = "Missing aps-environment entitlement"
        } else {
            hint = error.localizedDescription
        }
        logger.error("APNs registration failed: \(hint, privacy: .public) (\(nsError.domain) #\(nsError.code))")
        registrationState = .failed(reason: hint)
    }

    public func handleDeviceToken(_ deviceToken: Data) async {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let tokenPrefix = String(tokenHex.prefix(8))
        logger.info("APNs token: \(tokenPrefix)...")
        // Surface "got token, syncing" before the network call so a slow /
        // failing worker doesn't keep the UI in a misleading "registering"
        // state for seconds.
        registrationState = .registered(tokenPrefix: tokenPrefix, syncedWithWorker: false)

        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard let url = URL(string: "\(baseURL)/v2/device/register") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await WorkerAuthHelper.applyAuth(to: &request)
        let body: [String: String] = [
            "deviceId": DeviceIdentity.deviceId,
            "pushToken": tokenHex,
            "platform": PlatformDependencies.shared.platformIdentifier(),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                logger.info("Device registered with worker")
                registrationState = .registered(tokenPrefix: tokenPrefix, syncedWithWorker: true)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.warning("Device register returned HTTP \(status)")
            }
        } catch {
            logger.error("Device register failed: \(error.localizedDescription)")
        }
    }

    /// Handle a background push notification.
    /// The push only contains roomCode + senderName (no roomToken for security).
    /// Triggers InboxService reconnect to fetch the full invite from the DO queue.
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any], inboxService: InboxService) {
        switch RelayPushKind.classify(userInfo) {
        case .note(let itemId):
            logger.info("Push received for a note")
            NotificationCenter.default.post(name: .didReceiveNotePush, object: nil, userInfo: ["inboxItemId": itemId ?? ""])
            return
        case .diary(let kind, let diaryId, let seq):
            // Spec §4: diary → DiaryStore.sync(diaryId); diaryKeyRequest
            // additionally force-relays (handled inside DiaryStore.handlePush).
            // accountId travels straight from the raw payload — RelayPushKind
            // itself only carries kind/diaryId/seq (spec §1/§4 interface).
            logger.info("Push received for diary kind=\(kind, privacy: .public)")
            var info: [String: Any] = ["kind": kind, "diaryId": diaryId]
            if let seq { info["seq"] = seq }
            if let accountId = userInfo["accountId"] as? String { info["accountId"] = accountId }
            NotificationCenter.default.post(name: .didReceiveDiaryPush, object: nil, userInfo: info)
            return
        case .diaryKey:
            // Spec §4: a `diaryKey` push is the silent relay-note wake-up —
            // it must drive NotesStore.sync() (which decodes the diaryKey
            // note and hands it to NotesStore.diaryKeyHandler), never
            // DiaryStore directly.
            logger.info("Push received for a diary key relay")
            NotificationCenter.default.post(name: .didReceiveNotePush, object: nil, userInfo: ["inboxItemId": ""])
            return
        case .chatInvite, .other:
            break
        }
        guard let roomCode = userInfo["roomCode"] as? String else {
            logger.warning("Ignoring push without roomCode")
            return
        }
        let senderName = userInfo["senderName"] as? String
            ?? (userInfo["aps"] as? [String: Any]).flatMap { ($0["alert"] as? [String: Any])?["body"] as? String }
            ?? "Unknown"
        let senderId = userInfo["senderId"] as? String ?? ""

        logger.info("Push received for room \(roomCode) from \(senderName) — reconnecting inbox to fetch token")

        // Reconnect inbox WS — the DO will flush the queued invite (which has the roomToken)
        inboxService.connect()

        // Also emit a partial invite so the UI can show a "connecting..." state if needed
        // The full invite (with roomToken) will arrive via InboxService once WS connects
        receivedInvite = RelayInvite(
            roomCode: roomCode,
            roomToken: "", // empty — will be filled by inbox WS flush
            senderName: senderName,
            senderId: senderId,
            source: .apns
        )
    }
}

public extension Notification.Name {
    /// A `type: "note"` APNs payload arrived; userInfo `["inboxItemId": String]`
    /// (may be empty). Listeners run `NotesStore.sync()`.
    static let didReceiveNotePush = Notification.Name("com.hanfour.peerdrop.didReceiveNotePush")
    /// The user tapped a note notification; userInfo `["id": String]`.
    static let openNote = Notification.Name("com.hanfour.peerdrop.openNote")
    /// A diary push arrived (spec §4: `diaryTurn`/`diaryEntry`/`diaryJoin`/
    /// `diaryReaction`/`diaryKeyRequest`); userInfo `["kind": String,
    /// "diaryId": String, "seq": Int?, "accountId": String?]`. Listeners
    /// call `DiaryStore.handlePush(kind:diaryId:accountId:)`.
    static let didReceiveDiaryPush = Notification.Name("com.hanfour.peerdrop.didReceiveDiaryPush")
    /// The user tapped a diary notification; userInfo `["diaryId": String,
    /// "seq": Int?]`.
    static let openDiary = Notification.Name("com.hanfour.peerdrop.openDiary")
}

/// What kind of relay push a payload is — kept pure so it is unit-testable.
public enum RelayPushKind: Equatable {
    case note(inboxItemId: String?)
    /// One of the five visible diary pushes (spec §4) — `kind` is the raw
    /// `type` string (`"diaryTurn"`/`"diaryEntry"`/`"diaryJoin"`/
    /// `"diaryReaction"`/`"diaryKeyRequest"`), `seq` present only for
    /// `diaryEntry`/`diaryReaction`.
    case diary(kind: String, diaryId: String, seq: Int?)
    /// The silent `{type:"diaryKey"}` relay-note wake-up (spec §3.3/§4) —
    /// carries no diaryId of its own; it just means "run NotesStore.sync()".
    case diaryKey
    case chatInvite(roomCode: String)
    case other

    /// The five `type` values that fan out as a visible diary push (spec
    /// §4's table, minus `diaryKey` which is its own case).
    private static let diaryKinds: Set<String> = [
        "diaryTurn", "diaryEntry", "diaryJoin", "diaryReaction", "diaryKeyRequest",
    ]

    /// Diary classification runs BEFORE the `roomCode` fallback (spec §1
    /// row "推播分類"/§4), same precedence `note` already has — a diary
    /// push payload must never be misread as a chat invite even if it
    /// happened to also carry a `roomCode` key.
    public static func classify(_ userInfo: [AnyHashable: Any]) -> RelayPushKind {
        if userInfo["type"] as? String == "note" { return .note(inboxItemId: userInfo["inboxItemId"] as? String) }
        if let type = userInfo["type"] as? String {
            if type == "diaryKey" { return .diaryKey }
            if diaryKinds.contains(type) {
                return .diary(kind: type, diaryId: userInfo["diaryId"] as? String ?? "", seq: userInfo["seq"] as? Int)
            }
        }
        if let room = userInfo["roomCode"] as? String { return .chatInvite(roomCode: room) }
        return .other
    }
}

/// Shared invite payload model.
public struct RelayInvite: Identifiable, Equatable {
    public enum Source { case websocket, apns }
    public var id: String { roomCode + ":" + (senderId.isEmpty ? senderName : senderId) }
    public let roomCode: String
    public let roomToken: String
    public let senderName: String
    public let senderId: String
    public let source: Source

    public init(roomCode: String, roomToken: String, senderName: String, senderId: String, source: Source) {
        self.roomCode = roomCode
        self.roomToken = roomToken
        self.senderName = senderName
        self.senderId = senderId
        self.source = source
    }

    /// Whether this invite has a valid room token (APNs push invites may not).
    public var hasToken: Bool { !roomToken.isEmpty }
}
