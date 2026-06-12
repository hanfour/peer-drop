import Foundation

public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard
    public var haptics: () -> HapticFeedback
    public var deviceName: () -> DeviceNameProvider
    public var systemInfo: () -> SystemInfoProvider
    public var remoteNotifications: () -> RemoteNotificationRegistering
    public var callProvider: () -> CallProvider
    public var audioSession: () -> AudioSessionConfiguring
    public var backgroundTaskHandler: @MainActor () -> BackgroundTaskHandling
    public var platformIdentifier: () -> String

    public init(
        pasteboard: (() -> PlatformPasteboard)? = nil,
        haptics: (() -> HapticFeedback)? = nil,
        deviceName: (() -> DeviceNameProvider)? = nil,
        systemInfo: (() -> SystemInfoProvider)? = nil,
        remoteNotifications: (() -> RemoteNotificationRegistering)? = nil,
        callProvider: (() -> CallProvider)? = nil,
        audioSession: (() -> AudioSessionConfiguring)? = nil,
        backgroundTaskHandler: (@MainActor () -> BackgroundTaskHandling)? = nil,
        platformIdentifier: (() -> String)? = nil
    ) {
        self.pasteboard = pasteboard ?? { PlatformDependencies.makePasteboard() }
        self.haptics = haptics ?? { PlatformDependencies.makeHaptics() }
        self.deviceName = deviceName ?? { PlatformDependencies.makeDeviceName() }
        self.systemInfo = systemInfo ?? { PlatformDependencies.makeSystemInfo() }
        self.remoteNotifications = remoteNotifications ?? { PlatformDependencies.makeRemoteNotifications() }
        self.callProvider = callProvider ?? { PlatformDependencies.makeCallProvider() }
        self.audioSession = audioSession ?? { PlatformDependencies.makeAudioSession() }
        self.backgroundTaskHandler = backgroundTaskHandler ?? { PlatformDependencies.makeBackgroundTaskHandler() }
        self.platformIdentifier = platformIdentifier ?? { PlatformDependencies.makePlatformIdentifier() }
    }

    public static var shared = PlatformDependencies()

    // Default factories — iOS adapter on iOS, falls back to a no-op on
    // other platforms until M2 wires AppKit adapters.
    private static func makePasteboard() -> PlatformPasteboard {
        #if canImport(UIKit)
        return UIKitPasteboard()
        #else
        return NoOpPasteboard()
        #endif
    }

    private static let _defaultHaptics: HapticFeedback = {
        #if canImport(UIKit)
        return UIKitHapticFeedback()
        #else
        return NoOpHapticFeedback()
        #endif
    }()

    private static func makeHaptics() -> HapticFeedback { _defaultHaptics }

    private static let _defaultDeviceName: DeviceNameProvider = {
        #if canImport(UIKit)
        return UIKitDeviceNameProvider()
        #else
        return HostnameDeviceNameProvider()
        #endif
    }()

    private static func makeDeviceName() -> DeviceNameProvider { _defaultDeviceName }

    private static let _defaultSystemInfo: SystemInfoProvider = {
        #if canImport(UIKit)
        return UIKitSystemInfoProvider()
        #else
        return SysctlSystemInfoProvider()
        #endif
    }()

    private static func makeSystemInfo() -> SystemInfoProvider { _defaultSystemInfo }

    private static let _defaultRemoteNotifications: RemoteNotificationRegistering = {
        #if canImport(UIKit)
        return UIKitRemoteNotificationRegistering()
        #else
        return NoOpRemoteNotificationRegistering()
        #endif
    }()

    private static func makeRemoteNotifications() -> RemoteNotificationRegistering { _defaultRemoteNotifications }

    /// IMPORTANT: callProvider default is AlwaysNoOpCallProvider on BOTH platforms.
    /// On iOS, AppDelegate is the sole creator of the real CallKitManager
    /// (because CallKit needs a CXProvider delegate wired to the app's UI).
    /// AppDelegate must pass the instance via ConnectionManager.configureVoiceCalling(callProvider:).
    /// If callProvider() is read before AppDelegate runs, the NoOp prevents
    /// silent double-instantiation of CXProvider. macOS (M3) likewise creates
    /// the real implementation in its NSApplicationDelegate.
    private static let _defaultCallProvider: CallProvider = AlwaysNoOpCallProvider()
    private static func makeCallProvider() -> CallProvider { _defaultCallProvider }

    private static let _defaultAudioSession: AudioSessionConfiguring = {
        #if canImport(UIKit)
        return UIKitAudioSession()
        #elseif os(macOS)
        // Real adapter, not NoOp: chat voice messages route mic permission
        // through audioSession(), and the NoOp's `requestRecordPermission
        // → false` made recording permanently impossible on the Mac
        // (audit round 16 live-verification finding).
        return MacAudioSession()
        #else
        return NoOpAudioSession()
        #endif
    }()
    private static func makeAudioSession() -> AudioSessionConfiguring { _defaultAudioSession }

    /// BackgroundTaskHandling is `@MainActor`-isolated (UIKit's
    /// `beginBackgroundTask` must run on main), so the default factory is
    /// also MainActor-isolated and constructs the adapter lazily per call.
    /// Consumers that hold a reference (e.g. `ConnectionManager`) cache
    /// the instance via `lazy var` to avoid re-allocating per call.
    @MainActor
    private static func makeBackgroundTaskHandler() -> BackgroundTaskHandling {
        #if canImport(UIKit)
        return UIKitBackgroundTaskHandler()
        #else
        return NoOpBackgroundTaskHandler()
        #endif
    }

    /// Returns a stable string identifying the current platform for use in
    /// the worker's `/v2/device/register` payload.
    ///
    /// NOTE: `canImport(UIKit)` is checked first because Mac Catalyst builds
    /// import UIKit while also running on macOS — for M3 we don't ship
    /// Catalyst, so the ordering is moot, but it's correct practice and
    /// keeps the guard future-safe if a Catalyst target is ever added.
    private static func makePlatformIdentifier() -> String {
        #if canImport(UIKit)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }
}

/// Always-no-op CallProvider. Used as the default for PlatformDependencies.callProvider
/// on BOTH platforms because AppDelegate (iOS) or NSApplicationDelegate (macOS M3)
/// is the sole creator of the real implementation. See PlatformDependencies
/// inline comment for the rationale.
private final class AlwaysNoOpCallProvider: CallProvider {
    var onAnswerCall: (() -> Void)?
    var onEndCall: (() -> Void)?
    func startOutgoingCall(to peerName: String) {}
    func reportOutgoingCallConnected() {}
    func reportIncomingCall(from peerName: String) async throws {}
    func endCall() {}
    func reportCallEnded(reason: CallEndReason) {}
    func configureAudioSession() {}
}

#if !canImport(UIKit)
private final class NoOpPasteboard: PlatformPasteboard {
    var changeCount: Int { 0 }
    var stringContent: String? { get { nil } set { } }
    var imageContent: PlatformImage? { get { nil } set { } }
    var changedNotificationName: Notification.Name { Notification.Name("NoOpPasteboardChanged") }
}

private final class NoOpHapticFeedback: HapticFeedback {
    func peerDiscovered() {}
    func connectionAccepted() {}
    func connectionRejected() {}
    func transferComplete() {}
    func transferFailed() {}
    func incomingRequest() {}
    func callStarted() {}
    func callEnded() {}
    func evolutionTriggered() {}
    func tap() {}
}

private final class HostnameDeviceNameProvider: DeviceNameProvider {
    @MainActor
    var currentName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}

private final class SysctlSystemInfoProvider: SystemInfoProvider {
    @MainActor
    var deviceModel: String {
        var size: Int = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Unknown" }
        return String(cString: bytes)
    }

    @MainActor
    var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

private final class NoOpRemoteNotificationRegistering: RemoteNotificationRegistering {
    @MainActor
    func registerForRemoteNotifications() {
        // M2 replaces with NSApplication.shared.registerForRemoteNotifications()
    }
}

private final class NoOpAudioSession: AudioSessionConfiguring {
    func activate(_ category: AudioSessionCategory) throws {}
    func deactivate() throws {}
    func overrideOutputToSpeaker(_ speaker: Bool) throws {}
    var recordPermissionGranted: Bool { false }
    func requestRecordPermission() async -> Bool { false }
}
#endif
