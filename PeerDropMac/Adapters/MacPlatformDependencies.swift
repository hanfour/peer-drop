import Foundation
import PeerDropPlatform

enum MacPlatformDependencies {
    /// Called from `MacAppDelegate.applicationDidFinishLaunching`.
    ///
    /// Registers macOS-specific adapters into the `PlatformDependencies`
    /// registry. iOS-specific adapters (`UIKit*`) are guarded by
    /// `#if canImport(UIKit)` inside the registry and never reach the macOS
    /// build, so this overrides the kit's no-op / sysctl fallbacks with the
    /// real AppKit-backed implementations.
    ///
    /// `BackgroundTaskHandling` already defaults to `NoOpBackgroundTaskHandler`
    /// on macOS via `PlatformDependencies.makeBackgroundTaskHandler` — no
    /// explicit registration needed. `CallProvider` defaults to
    /// `AlwaysNoOpCallProvider` on both platforms until M3 ships the
    /// macOS NSWindow-based call UI (matching the iOS rule where
    /// `MacAppDelegate` would be the sole creator of the real implementation).
    static func register() {
        PlatformDependencies.shared.pasteboard = { NSPasteboardAdapter() }
        PlatformDependencies.shared.deviceName = { HostDeviceNameProvider() }
        PlatformDependencies.shared.systemInfo = { MacSystemInfoProvider() }
    }
}
