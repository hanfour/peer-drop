import XCTest
@testable import PeerDropCore
@testable import PeerDropSecurity

/// `reconnect(to:)` used to do nothing, silently, when the peer was neither
/// discovered nor had a stored address, so the chat's "Reconnect" button looked
/// broken. It now reports whether it had anything to try.
@MainActor
final class ConnectionManagerReconnectTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmreconkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmrecontest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    func test_reconnect_unknownPeer_returnsFalse() {
        let cm = ConnectionManager()
        XCTAssertFalse(cm.reconnect(to: "never-seen-\(UUID().uuidString)"))
    }
}
