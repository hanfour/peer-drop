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

        // M4 Task 6 follow-up: respect the -AppleInterfaceStyle launch
        // argument so MacSnapshotTestsDark captures actually render in
        // dark mode. macOS doesn't auto-flip NSApp.appearance based on
        // this arg — it only steers the system appearance for processes
        // that opt in. We force the override here.
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-AppleInterfaceStyle"),
           idx + 1 < args.count {
            let style = args[idx + 1]
            if style.caseInsensitiveCompare("Dark") == .orderedSame {
                logger.info("Launch arg requested Dark appearance")
                NSApp.appearance = NSAppearance(named: .darkAqua)
            } else if style.caseInsensitiveCompare("Light") == .orderedSame {
                logger.info("Launch arg requested Light (Aqua) appearance")
                NSApp.appearance = NSAppearance(named: .aqua)
            }
        }
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

    /// Stay running when the last window closes — the menu bar item is
    /// the primary affordance for receiving file drops and incoming
    /// calls, so quitting after the main window closes would defeat
    /// that. Matches the Slack / Discord / Telegram desktop pattern.
    /// Users quit explicitly via ⌘Q or the menu bar Quit entry.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
    ///   - chat invite (`roomCode` present) — forwarded via NotificationCenter
    ///     so PeerDropMacApp's `.onReceive(.didReceiveRelayPush)` can call
    ///     `PushNotificationManager.handleRemoteNotification` with the
    ///     live InboxService instance (which lives in PeerDropMacApp,
    ///     not in AppDelegate). Mirror of iOS AppDelegate.swift:42-47.
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        let type = userInfo["type"] as? String ?? (userInfo["roomCode"] != nil ? "chatInvite" : "unknown")
        logger.info("APNs push received: type=\(type, privacy: .public)")

        if type == "callRequest" {
            let callerName = userInfo["callerName"] as? String ?? NSLocalizedString("Unknown", comment: "Caller name fallback")
            macCallProvider.handleColdLaunchPush(callerName: callerName)
            return
        }

        // Chat invites + any other relay-pushed payload that's not handled
        // internally: forward to the app shell.
        NotificationCenter.default.post(
            name: .didReceiveRelayPush,
            object: nil,
            userInfo: userInfo
        )
    }
}

extension Notification.Name {
    /// Cross-platform marker for relay-pushed payloads that the AppDelegate
    /// hands off to the app shell. Same string as iOS at
    /// PeerDrop/App/AppDelegate.swift:7 — listeners on either platform see
    /// the same notification.
    static let didReceiveRelayPush = Notification.Name("didReceiveRelayPush")
}
