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

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("macOS app finished launching")
        // Register the macOS-specific PlatformDependencies adapters.
        // (Task 4 fills MacPlatformDependencies.register() with real adapters.)
        MacPlatformDependencies.register()
    }

    /// Finder drop / open-with handler. Files arrive via NSURL array.
    /// Task 10 routes through MacDropHandler so Dock drops, Finder
    /// "Open With PeerDrop", and the `open:` lifecycle all share one
    /// logger path. The MacDropHandler TODO comments document the
    /// post-M2 peer-selection-sheet wiring (App Review compliance:
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

    /// Inbound APNs alert push. Two payload types matter for M3:
    ///   - `type: "callRequest"` — voice-call wake (Task 11 routes to MacCallProvider)
    ///   - chat invite (`roomCode` present) — reuse iOS handleRemoteNotification path
    ///
    /// For Task 5 we just log + structurally route. The MacCallProvider hook
    /// is wired in Task 11.
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        let type = userInfo["type"] as? String ?? (userInfo["roomCode"] != nil ? "chatInvite" : "unknown")
        logger.info("APNs push received: type=\(type, privacy: .public)")
        // Task 11 will route callRequest payloads to MacCallProvider here.
        // Chat invites route through the same path as iOS once relay reconnects.
    }
}
