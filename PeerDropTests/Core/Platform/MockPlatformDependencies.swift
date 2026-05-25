import Foundation
import XCTest
@testable import PeerDrop

final class MockPasteboard: PlatformPasteboard {
    var changeCount: Int = 0
    var stringContent: String?
    var imageContent: PlatformImage?
    let changedNotificationName: Notification.Name = Notification.Name("MockPasteboardChanged")

    func simulateChange(string: String? = nil, image: PlatformImage? = nil) {
        changeCount += 1
        if let string { stringContent = string }
        if let image { imageContent = image }
        NotificationCenter.default.post(name: changedNotificationName, object: nil)
    }
}

final class MockHaptics: HapticFeedback {
    private(set) var invocations: [String] = []

    func peerDiscovered() { invocations.append("peerDiscovered") }
    func connectionAccepted() { invocations.append("connectionAccepted") }
    func connectionRejected() { invocations.append("connectionRejected") }
    func transferComplete() { invocations.append("transferComplete") }
    func transferFailed() { invocations.append("transferFailed") }
    func incomingRequest() { invocations.append("incomingRequest") }
    func callStarted() { invocations.append("callStarted") }
    func callEnded() { invocations.append("callEnded") }
    func tap() { invocations.append("tap") }
}

final class MockDeviceNameProvider: DeviceNameProvider {
    var name: String = "Mock Device"

    @MainActor
    var currentName: String { name }
}

final class MockSystemInfoProvider: SystemInfoProvider {
    var model: String = "MockDevice"
    var os: String = "MockOS 1.0"

    @MainActor
    var deviceModel: String { model }

    @MainActor
    var osVersion: String { os }
}

final class MockRemoteNotificationRegistering: RemoteNotificationRegistering {
    private(set) var registerCalled = false

    @MainActor
    func registerForRemoteNotifications() {
        registerCalled = true
    }
}

extension PlatformDependencies {
    /// Convenience factory for tests. Returns a registry with all-mock factories.
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard(),
        haptics: MockHaptics = MockHaptics(),
        deviceName: MockDeviceNameProvider = MockDeviceNameProvider(),
        systemInfo: MockSystemInfoProvider = MockSystemInfoProvider(),
        remoteNotifications: MockRemoteNotificationRegistering = MockRemoteNotificationRegistering()
    ) -> PlatformDependencies {
        PlatformDependencies(
            pasteboard: { pasteboard },
            haptics: { haptics },
            deviceName: { deviceName },
            systemInfo: { systemInfo },
            remoteNotifications: { remoteNotifications }
        )
    }
}

@MainActor
final class HapticManagerInjectionTests: XCTestCase {
    func test_tapForwardsToInjectedFeedback() {
        let originalDeps = PlatformDependencies.shared
        defer { PlatformDependencies.shared = originalDeps }

        let mock = MockHaptics()
        PlatformDependencies.shared = .mock(haptics: mock)

        HapticManager.tap()
        HapticManager.transferComplete()

        XCTAssertEqual(mock.invocations, ["tap", "transferComplete"])
    }
}

@MainActor
final class DeviceNameInjectionTests: XCTestCase {
    func test_userProfileCurrentReadsFromInjectedDeviceName() {
        let originalDeps = PlatformDependencies.shared
        defer { PlatformDependencies.shared = originalDeps }

        // Clear any saved display name so the fallback is exercised
        UserDefaults.standard.removeObject(forKey: "peerDropDisplayName")
        defer { UserDefaults.standard.removeObject(forKey: "peerDropDisplayName") }

        let mock = MockDeviceNameProvider()
        mock.name = "Test Mac"
        PlatformDependencies.shared = .mock(deviceName: mock)

        XCTAssertEqual(UserProfile.current.displayName, "Test Mac")
    }
}

@MainActor
final class ClipboardSyncManagerInjectionTests: XCTestCase {
    func test_buildPayload_readsFromInjectedPasteboard() {
        let mock = MockPasteboard()
        mock.stringContent = "https://example.com/test"
        let manager = ClipboardSyncManager(pasteboard: mock)

        let exp = expectation(description: "payload arrives")
        var received: ClipboardSyncPayload?
        manager.onClipboardChanged = {
            received = $0
            exp.fulfill()
        }
        manager.startMonitoring()
        defer { manager.stopMonitoring() }

        mock.simulateChange(string: "https://example.com/test")

        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(received?.contentType, .url)
        XCTAssertEqual(received?.textContent, "https://example.com/test")
    }
}
