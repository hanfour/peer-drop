import Foundation
import PeerDropPlatform

/// No-op platform providers for a headless CLI. ConnectionManager only needs
/// deviceName (for identity + Bonjour advertising) and platformIdentifier on
/// the connect path; the rest are inert stubs so nothing force-unwraps a nil
/// provider.
enum HeadlessPlatform {

    final class NoopPasteboard: PlatformPasteboard {
        var changeCount: Int = 0
        var stringContent: String? = nil
        var imageContent: PlatformImage? = nil
        var changedNotificationName = Notification.Name("peerdrop.cli.noop.pasteboard")
    }

    struct FixedDeviceName: DeviceNameProvider {
        let name: String
        @MainActor var currentName: String { name }
    }

    struct CLISystemInfo: SystemInfoProvider {
        @MainActor var deviceModel: String { "Mac (peerdrop-cli)" }
        @MainActor var osVersion: String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
    }

    final class NoopAudioSession: AudioSessionConfiguring {
        func activate(_ category: AudioSessionCategory) throws {}
        func deactivate() throws {}
        func overrideOutputToSpeaker(_ speaker: Bool) throws {}
        var recordPermissionGranted: Bool { false }
        func requestRecordPermission() async -> Bool { false }
    }

    struct NoopRemoteNotifications: RemoteNotificationRegistering {
        @MainActor func registerForRemoteNotifications() {}
    }

    @MainActor
    static func register(deviceName: String) {
        PlatformDependencies.shared.pasteboard = { NoopPasteboard() }
        PlatformDependencies.shared.deviceName = { FixedDeviceName(name: deviceName) }
        PlatformDependencies.shared.systemInfo = { CLISystemInfo() }
        PlatformDependencies.shared.audioSession = { NoopAudioSession() }
        PlatformDependencies.shared.remoteNotifications = { NoopRemoteNotifications() }
        PlatformDependencies.shared.platformIdentifier = { "macos-cli" }
    }
}
