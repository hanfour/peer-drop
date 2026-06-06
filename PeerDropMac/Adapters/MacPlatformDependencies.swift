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
    @MainActor
    static func register() {
        PlatformDependencies.shared.pasteboard = { NSPasteboardAdapter() }
        PlatformDependencies.shared.deviceName = { HostDeviceNameProvider() }
        PlatformDependencies.shared.systemInfo = { MacSystemInfoProvider() }
        // M3: APNs registration. PushNotificationManager will call this when
        // the user grants UN permission.
        PlatformDependencies.shared.remoteNotifications = { MacRemoteNotificationRegistering() }
        // M3: AVCaptureDevice-backed audio session for mic permission.
        // WebRTC self-manages voice-chat audio routing on macOS, so the
        // activate/deactivate/overrideOutputToSpeaker methods are no-ops.
        PlatformDependencies.shared.audioSession = { MacAudioSession() }
        // M3: platformIdentifier defaults to "macos" via #if guards in
        // PlatformDependencies — explicit registration here makes the
        // intent visible at the call site (and provides a single override
        // point if future variants are needed).
        PlatformDependencies.shared.platformIdentifier = { "macos" }
    }
}
