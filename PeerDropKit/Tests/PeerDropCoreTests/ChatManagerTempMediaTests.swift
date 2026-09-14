// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerTempMediaTests.swift
//
// writeMediaToTempFile decrypts media into the temporary directory for playback
// but nothing ever cleaned it up, so plaintext copies of private media lingered
// across launches — defeating the at-rest encryption for anyone with file /
// backup access. The cache must be purged on launch.
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerTempMediaTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmtmkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmtmtest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    func test_tempMedia_isPurgedOnNextLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmtm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Session 1: store media, then materialise a decrypted temp copy.
        let session1 = ChatManager(rootDirectory: root)
        let rel = session1.saveMediaFile(data: Data("secret video".utf8), fileName: "v.mp4", peerID: "A")
        let tempURL = try XCTUnwrap(session1.writeMediaToTempFile(relativePath: rel))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        // Session 2 (relaunch): the decrypted temp copy must be gone.
        _ = ChatManager(rootDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "decrypted media lingered in the temp directory across launches")
    }
}
