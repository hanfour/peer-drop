// Tests that exercise PeerDropPlatform injection against concrete app-target types
// (HapticManager, UserProfile, ClipboardSyncManager). They stay in PeerDropTests
// because those types live in the PeerDrop app target, not in PeerDropPlatform.
import Foundation
import PeerDropPlatform
import PeerDropProtocol
import XCTest
@testable import PeerDrop

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

    func test_evolutionTriggeredForwardsToInjectedFeedback() {
        let originalDeps = PlatformDependencies.shared
        defer { PlatformDependencies.shared = originalDeps }

        let mock = MockHaptics()
        PlatformDependencies.shared = .mock(haptics: mock)

        HapticManager.evolutionTriggered()

        XCTAssertEqual(mock.invocations, ["evolutionTriggered"])
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
