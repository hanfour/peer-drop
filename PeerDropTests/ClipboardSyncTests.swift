import XCTest
@testable import PeerDrop

@MainActor
final class ClipboardSyncTests: XCTestCase {

    func testClipboardSyncPayloadTextEncoding() throws {
        let payload = ClipboardSyncPayload(contentType: .text, textContent: "Hello clipboard")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipboardSyncPayload.self, from: data)
        XCTAssertEqual(decoded.contentType, .text)
        XCTAssertEqual(decoded.textContent, "Hello clipboard")
        XCTAssertNil(decoded.imageData)
    }

    func testClipboardSyncPayloadURLEncoding() throws {
        let payload = ClipboardSyncPayload(contentType: .url, textContent: "https://example.com")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipboardSyncPayload.self, from: data)
        XCTAssertEqual(decoded.contentType, .url)
        XCTAssertEqual(decoded.textContent, "https://example.com")
    }

    func testClipboardSyncPayloadImageEncoding() throws {
        let imageData = Data(repeating: 0xFF, count: 100)
        let payload = ClipboardSyncPayload(contentType: .image, imageData: imageData)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipboardSyncPayload.self, from: data)
        XCTAssertEqual(decoded.contentType, .image)
        XCTAssertEqual(decoded.imageData, imageData)
        XCTAssertNil(decoded.textContent)
    }

    func testClipboardSyncManagerInitialState() {
        let manager = ClipboardSyncManager()
        XCTAssertNil(manager.lastSyncedContent)
        XCTAssertNil(manager.pendingClipboardContent)
    }

    func testClipboardSyncPeerMessageCreation() throws {
        let payload = ClipboardSyncPayload(contentType: .text, textContent: "Test")
        let msg = try PeerMessage.clipboardSync(payload, senderID: "sender1")
        XCTAssertEqual(msg.type, .clipboardSync)
        XCTAssertEqual(msg.senderID, "sender1")
        XCTAssertNotNil(msg.payload)
    }

    func testFeatureSettingsClipboardSync() {
        // Default should be enabled
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        XCTAssertTrue(FeatureSettings.isClipboardSyncEnabled)
    }
}
