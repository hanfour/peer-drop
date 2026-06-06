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
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("Open URLs: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        // TODO Task 10 — wire to a peer-selection sheet via ConnectionManager.
        // Task 3 just logs to confirm the AppDelegate hook fires.
        // The peer-selection sheet ALWAYS appears before send (App Review compliance).
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
}
