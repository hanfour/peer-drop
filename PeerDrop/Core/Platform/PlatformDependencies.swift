import Foundation

public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard
    public var haptics: () -> HapticFeedback
    public var deviceName: () -> DeviceNameProvider
    public var systemInfo: () -> SystemInfoProvider
    public var remoteNotifications: () -> RemoteNotificationRegistering

    public init(
        pasteboard: (() -> PlatformPasteboard)? = nil,
        haptics: (() -> HapticFeedback)? = nil,
        deviceName: (() -> DeviceNameProvider)? = nil,
        systemInfo: (() -> SystemInfoProvider)? = nil,
        remoteNotifications: (() -> RemoteNotificationRegistering)? = nil
    ) {
        self.pasteboard = pasteboard ?? { PlatformDependencies.makePasteboard() }
        self.haptics = haptics ?? { PlatformDependencies.makeHaptics() }
        self.deviceName = deviceName ?? { PlatformDependencies.makeDeviceName() }
        self.systemInfo = systemInfo ?? { PlatformDependencies.makeSystemInfo() }
        self.remoteNotifications = remoteNotifications ?? { PlatformDependencies.makeRemoteNotifications() }
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
#endif
