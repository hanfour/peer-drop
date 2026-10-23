// A media message must carry ONE id end to end. The sender's local message id
// rides the wire payload and the receiver stores the message under it, so the
// delivery/read receipts the receiver sends can be matched by the sender
// (otherwise the sender's media bubble stays at "sent" forever).
import XCTest
@testable import PeerDropCore
import PeerDropProtocol
import PeerDropSecurity

final class ChatManagerMediaMessageIDTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmmidkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmmidtest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    private func manager() -> ChatManager {
        ChatManager(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func payload(id: String?) -> MediaMessagePayload {
        MediaMessagePayload(mediaType: .voice, fileName: "v.m4a", fileSize: 3, mimeType: "audio/mp4",
                            duration: 1, thumbnailData: nil, fileData: Data([1, 2, 3]), id: id)
    }

    func test_payload_usesProvidedID_andMintsOneOtherwise() {
        XCTAssertEqual(payload(id: "shared-1").id, "shared-1")
        XCTAssertFalse(payload(id: nil).id.isEmpty)
    }

    @MainActor
    func test_saveOutgoingMedia_usesProvidedID() {
        let msg = manager().saveOutgoingMedia(
            mediaType: .voice, fileName: "v.m4a", fileSize: 3, mimeType: "audio/mp4", duration: 1,
            localFileURL: nil, thumbnailData: nil, peerID: "A", peerName: "A", id: "shared-2")
        XCTAssertEqual(msg.id, "shared-2")
    }

    @MainActor
    func test_saveIncomingMedia_storesUnderPayloadID() {
        let msg = manager().saveIncomingMedia(payload: payload(id: "shared-3"), fileData: Data([1, 2, 3]), peerID: "A", peerName: "A")
        XCTAssertEqual(msg.id, "shared-3")
    }

    /// A redelivery carries the same id: it must not be stored twice, but still
    /// returns the message so the caller sends another delivery receipt.
    @MainActor
    func test_saveIncomingMedia_duplicateIsNotStoredTwice() {
        let m = manager()
        m.loadMessages(forPeer: "A")
        let first = m.saveIncomingMedia(payload: payload(id: "shared-4"), fileData: Data([1, 2, 3]), peerID: "A", peerName: "A")
        let again = m.saveIncomingMedia(payload: payload(id: "shared-4"), fileData: Data([1, 2, 3]), peerID: "A", peerName: "A")
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(m.messages.filter { $0.id == "shared-4" }.count, 1)
    }
}
