import AppKit
import SwiftUI
import os
import PeerDropCore
import PeerDropPlatform

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "AppDelegate")

    /// Visibility of the menu bar item — toggled by the View menu command.
    @Published var menuBarVisible: Bool = true

    /// Wired by `PeerDropMacApp` at scene appearance time so AppDelegate
    /// lifecycle hooks (terminate flush, file open) can call into
    /// ConnectionManager. Weak to avoid retaining beyond scene scope.
    weak var connectionManager: ConnectionManager?

    /// M3: owns the macOS CallProvider implementation. Strong reference
    /// because PeerDropMacApp registers it via
    /// `ConnectionManager.configureVoiceCalling(callProvider:)` which
    /// stores the provider weakly via the VoiceCallManager chain. The
    /// AppDelegate is the canonical owner per the iOS pattern (where
    /// CallKitManager is held by the iOS PeerDropAppDelegate).
    let macCallProvider = MacCallProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("macOS app finished launching")
        // Register macOS-specific PlatformDependencies adapters
        // (pasteboard / deviceName / systemInfo / remoteNotifications /
        // audioSession / platformIdentifier).
        MacPlatformDependencies.register()
    }

    /// Finder drop / open-with handler. Files arrive via NSURL array.
    /// Routed through `MacDropHandler` so Dock drops, Finder
    /// "Open With PeerDrop", and the `open:` lifecycle all share one
    /// logger path. The MacDropHandler TODO comments document the
    /// future peer-selection-sheet wiring (App Review compliance:
    /// drops NEVER send silently).
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("Open URLs: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        MacDropHandler.handle(urls: urls)
    }

    /// Dock click when the main window is closed should reopen it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // No visible windows — present the main scene.
            NSApp.windows
                .first(where: { $0.identifier?.rawValue == "PeerDropMain" })?
                .makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// On quit, flush any pending persists (debounced chat saves, etc.).
    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Terminating — flushing pending persists")
        // `flushAllPendingPersists` lives on `ChatManager` (M1d-5 audit).
        // ConnectionManager exposes ChatManager via `public let chatManager`.
        connectionManager?.chatManager.flushAllPendingPersists()
    }

    // MARK: - M3: APNs registration

    /// Called by macOS after `NSApplication.shared.registerForRemoteNotifications()`
    /// succeeds. Forwards the binary token to PushNotificationManager which
    /// hex-encodes it and POSTs `/v2/device/register` on the Worker.
    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenPrefix = deviceToken.prefix(4).map { String(format: "%02x", $0) }.joined()
        logger.info("APNs token received (prefix=\(tokenPrefix, privacy: .public))")
        Task { @MainActor in
            await PushNotificationManager.shared.handleDeviceToken(deviceToken)
        }
    }

    /// Called when registerForRemoteNotifications fails (missing entitlement,
    /// dev sandbox unreachable, etc.). PushNotificationManager surfaces the
    /// failure into `registrationState`; the Mac PushStatusRow will read this.
    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        PushNotificationManager.shared.handleRegistrationFailure(error)
    }

    /// Inbound APNs alert push. Two payload types matter:
    ///   - `type: "callRequest"` — voice-call wake; routed to MacCallProvider
    ///     for the cold-launch grace flow.
    ///   - chat invite (`roomCode` present) — reuses the iOS
    ///     `handleRemoteNotification` path once relay reconnects via
    ///     `InboxService`. No work needed here.
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        let type = userInfo["type"] as? String ?? (userInfo["roomCode"] != nil ? "chatInvite" : "unknown")
        logger.info("APNs push received: type=\(type, privacy: .public)")

        if type == "callRequest" {
            let callerName = userInfo["callerName"] as? String ?? NSLocalizedString("Unknown", comment: "Caller name fallback")
            macCallProvider.handleColdLaunchPush(callerName: callerName)
        }
        // Chat invites route through the same path as iOS once relay
        // reconnects — InboxService picks up the queued PeerMessage.
    }
}
