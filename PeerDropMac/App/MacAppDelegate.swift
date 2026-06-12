import AppKit
import SwiftUI
import UserNotifications
import os
import PeerDropCore
import PeerDropPlatform

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
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

    /// Round 5 audit fix: buffer for APNs payloads that arrive before
    /// PeerDropMacApp's `.onReceive(.didReceiveRelayPush)` subscriber has
    /// attached. NotificationCenter posts are dropped if no subscriber
    /// exists — on cold launch the SwiftUI scene mounts AFTER
    /// `application(_:didReceiveRemoteNotification:)` fires. PeerDropMacApp
    /// drains this on its .onAppear.
    var pendingRelayPushPayloads: [[AnyHashable: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("macOS app finished launching")
        // Register macOS-specific PlatformDependencies adapters
        // (pasteboard / deviceName / systemInfo / remoteNotifications /
        // audioSession / platformIdentifier).
        MacPlatformDependencies.register()

        // Round 5 audit fix: become the UNUserNotificationCenter delegate
        // so APNs banners actually show while the app is foregrounded
        // (default macOS behavior is to suppress them). Mirrors iOS
        // PeerDrop/App/AppDelegate.swift:18. Without this, an iPhone
        // calling/messaging a foregrounded Mac shows nothing in the
        // system notification banner — only the in-band PeerMessage
        // eventually surfaces.
        UNUserNotificationCenter.current().delegate = self

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

    /// Finder drop / open-with / URL-scheme handler. Two URL classes
    /// arrive here:
    ///   - `file://` URLs from Finder drops, Dock drops, "Open With…".
    ///     Route to MacDropHandler.
    ///   - `peerdrop://` URLs from QR-code links, iMessage shares,
    ///     QR-code scanners. Route to MacDeepLinkHandler so the
    ///     relay-join / manual-connect / smart / invite flows actually
    ///     run instead of being treated as a file drop (round 8 audit
    ///     fix; previously every URL went to MacDropHandler and clicking
    ///     `peerdrop://invite/?…` triggered a confused "Send 1 file?"
    ///     confirmation).
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("Open URLs: \(urls.map(\.absoluteString).joined(separator: ", "), privacy: .public)")
        let fileURLs = urls.filter { $0.isFileURL }
        let deepLinks = urls.filter { $0.scheme == "peerdrop" }
        if !fileURLs.isEmpty {
            MacDropHandler.handle(urls: fileURLs)
        }
        for url in deepLinks {
            MacDeepLinkHandler.handle(url)
        }
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
        //
        // Cold-launch race: if this fires before PeerDropMacApp's body
        // has built and the .onReceive subscriber has attached, the
        // post is dropped. Buffer the payload so PeerDropMacApp can
        // drain it on .onAppear. Subsequent foreground pushes still
        // route via NotificationCenter as normal.
        pendingRelayPushPayloads.append(userInfo)
        NotificationCenter.default.post(
            name: .didReceiveRelayPush,
            object: nil,
            userInfo: userInfo
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show APNs banners while the app is foregrounded. Without this
    /// delegate, macOS suppresses banners for the active app and the
    /// user sees nothing. Mirrors iOS at PeerDrop/App/AppDelegate.swift:24.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    /// Cross-platform marker for relay-pushed payloads that the AppDelegate
    /// hands off to the app shell. Same string as iOS at
    /// PeerDrop/App/AppDelegate.swift:7 — listeners on either platform see
    /// the same notification.
    static let didReceiveRelayPush = Notification.Name("didReceiveRelayPush")
}
