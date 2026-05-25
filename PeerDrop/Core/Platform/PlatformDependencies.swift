import Foundation

public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard
    public var haptics: () -> HapticFeedback
    public var deviceName: () -> DeviceNameProvider

    public init(
        pasteboard: (() -> PlatformPasteboard)? = nil,
        haptics: (() -> HapticFeedback)? = nil,
        deviceName: (() -> DeviceNameProvider)? = nil
    ) {
        self.pasteboard = pasteboard ?? { PlatformDependencies.makePasteboard() }
        self.haptics = haptics ?? { PlatformDependencies.makeHaptics() }
        self.deviceName = deviceName ?? { PlatformDependencies.makeDeviceName() }
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
#endif
