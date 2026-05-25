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

extension PlatformDependencies {
    /// Convenience factory for tests. Returns a registry with all-mock factories.
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard()
    ) -> PlatformDependencies {
        PlatformDependencies(pasteboard: { pasteboard })
    }
}

@MainActor
final class ClipboardSyncManagerInjectionTests: XCTestCase {
    func test_buildPayload_readsFromInjectedPasteboard() {
        let mock = MockPasteboard()
        mock.stringContent = "https://example.com/test"
        let manager = ClipboardSyncManager(pasteboard: mock)

        var received: ClipboardSyncPayload?
        manager.onClipboardChanged = { received = $0 }
        manager.startMonitoring()
        defer { manager.stopMonitoring() }

        mock.simulateChange(string: "https://example.com/test")

        // Allow the @objc selector + Task @MainActor to run
        let exp = expectation(description: "payload arrives")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(received?.contentType, .url)
        XCTAssertEqual(received?.textContent, "https://example.com/test")
    }
}
