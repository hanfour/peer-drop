import XCTest
@testable import PeerDrop

/// Comprehensive integration tests for all Phase 2 (v1.2.0) features.
@MainActor
final class Phase2IntegrationTests: XCTestCase {

    // MARK: - New MessageType round-trip encoding

    func testAllNewMessageTypesEncodable() throws {
        let newTypes: [MessageType] = [
            .messageEdit, .messageDelete,
            .clipboardSync,
            .fileResume, .fileResumeAck
        ]
        for type in newTypes {
            let msg = PeerMessage(type: type, senderID: "test")
            let data = try msg.encoded()
            let decoded = try PeerMessage.decoded(from: data)
            XCTAssertEqual(decoded.type, type, "Round-trip failed for \(type)")
        }
    }

    // MARK: - Clipboard Sync Payload

    func testClipboardSyncTextRoundTrip() throws {
        let payload = ClipboardSyncPayload(contentType: .text, textContent: "Hello World")
        let msg = try PeerMessage.clipboardSync(payload, senderID: "sender1")
        let data = try msg.encoded()
        let decoded = try PeerMessage.decoded(from: data)
        let p = try decoded.decodePayload(ClipboardSyncPayload.self)
        XCTAssertEqual(p.contentType, .text)
        XCTAssertEqual(p.textContent, "Hello World")
        XCTAssertNil(p.imageData)
    }

    func testClipboardSyncURLRoundTrip() throws {
        let payload = ClipboardSyncPayload(contentType: .url, textContent: "https://example.com/path?q=1&lang=zh")
        let msg = try PeerMessage.clipboardSync(payload, senderID: "s")
        let decoded = try PeerMessage.decoded(from: try msg.encoded())
        let p = try decoded.decodePayload(ClipboardSyncPayload.self)
        XCTAssertEqual(p.contentType, .url)
        XCTAssertEqual(p.textContent, "https://example.com/path?q=1&lang=zh")
    }

    func testClipboardSyncImageRoundTrip() throws {
        let imageData = Data(repeating: 0xAB, count: 500)
        let payload = ClipboardSyncPayload(contentType: .image, imageData: imageData)
        let msg = try PeerMessage.clipboardSync(payload, senderID: "s")
        let decoded = try PeerMessage.decoded(from: try msg.encoded())
        let p = try decoded.decodePayload(ClipboardSyncPayload.self)
        XCTAssertEqual(p.contentType, .image)
        XCTAssertEqual(p.imageData, imageData)
    }

    func testClipboardSyncEmptyTextContent() throws {
        let payload = ClipboardSyncPayload(contentType: .text, textContent: "")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipboardSyncPayload.self, from: data)
        XCTAssertEqual(decoded.textContent, "")
    }

    func testClipboardSyncTimestamp() throws {
        let before = Date()
        let payload = ClipboardSyncPayload(contentType: .text, textContent: "test")
        let after = Date()
        XCTAssertGreaterThanOrEqual(payload.timestamp, before)
        XCTAssertLessThanOrEqual(payload.timestamp, after)
    }

    // MARK: - Message Edit Payload

    func testMessageEditRoundTrip() throws {
        let payload = MessageEditPayload(messageID: "msg-123", newText: "Updated content", groupID: "group-1")
        let msg = try PeerMessage.messageEdit(payload, senderID: "s")
        let decoded = try PeerMessage.decoded(from: try msg.encoded())
        let p = try decoded.decodePayload(MessageEditPayload.self)
        XCTAssertEqual(p.messageID, "msg-123")
        XCTAssertEqual(p.newText, "Updated content")
        XCTAssertEqual(p.groupID, "group-1")
        XCTAssertNotNil(p.editedAt)
    }

    func testMessageEditWithoutGroupID() throws {
        let payload = MessageEditPayload(messageID: "msg-1", newText: "New")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageEditPayload.self, from: data)
        XCTAssertNil(decoded.groupID)
    }

    func testMessageEditUnicodeContent() throws {
        let payload = MessageEditPayload(messageID: "m1", newText: "你好世界 🌍 こんにちは 안녕")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageEditPayload.self, from: data)
        XCTAssertEqual(decoded.newText, "你好世界 🌍 こんにちは 안녕")
    }

    // MARK: - Message Delete Payload

    func testMessageDeleteRoundTrip() throws {
        let payload = MessageDeletePayload(messageID: "msg-456", groupID: "g1")
        let msg = try PeerMessage.messageDelete(payload, senderID: "s")
        let decoded = try PeerMessage.decoded(from: try msg.encoded())
        let p = try decoded.decodePayload(MessageDeletePayload.self)
        XCTAssertEqual(p.messageID, "msg-456")
        XCTAssertEqual(p.groupID, "g1")
    }

    // MARK: - File Resume Payload

    func testFileResumeRoundTrip() throws {
        let payload = FileResumePayload(
            fileName: "bigfile.zip",
            fileSize: 104_857_600,
            sha256Hash: "abc123def456",
            resumeOffset: 52_428_800
        )
        let msg = try PeerMessage.fileResume(payload, senderID: "s")
        let decoded = try PeerMessage.decoded(from: try msg.encoded())
        let p = try decoded.decodePayload(FileResumePayload.self)
        XCTAssertEqual(p.fileName, "bigfile.zip")
        XCTAssertEqual(p.fileSize, 104_857_600)
        XCTAssertEqual(p.sha256Hash, "abc123def456")
        XCTAssertEqual(p.resumeOffset, 52_428_800)
    }

    func testFileResumeAckAccepted() throws {
        let payload = FileResumeAckPayload(accepted: true, resumeOffset: 1024)
        let msg = try PeerMessage.fileResumeAck(payload, senderID: "s")
        let decoded = try PeerMessage.decoded(from: try msg.encoded())
        let p = try decoded.decodePayload(FileResumeAckPayload.self)
        XCTAssertTrue(p.accepted)
        XCTAssertEqual(p.resumeOffset, 1024)
    }

    func testFileResumeAckRejected() throws {
        let payload = FileResumeAckPayload(accepted: false, resumeOffset: 0)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(FileResumeAckPayload.self, from: data)
        XCTAssertFalse(decoded.accepted)
    }

    // MARK: - TransferMetadata Backward Compatibility

    func testTransferMetadataWithResumeOffset() throws {
        let metadata = TransferMetadata(
            fileName: "test.bin",
            fileSize: 2048,
            mimeType: nil,
            sha256Hash: "hash",
            resumeOffset: 1024
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TransferMetadata.self, from: data)
        XCTAssertEqual(decoded.resumeOffset, 1024)
    }

    func testTransferMetadataWithoutResumeOffset() throws {
        let metadata = TransferMetadata(
            fileName: "test.bin",
            fileSize: 2048,
            mimeType: nil,
            sha256Hash: "hash"
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TransferMetadata.self, from: data)
        XCTAssertNil(decoded.resumeOffset)
    }

    func testTransferMetadataOldFormatWithoutResumeOffset() throws {
        // Simulate old format JSON without resumeOffset or isDirectory
        let json: [String: Any] = [
            "fileName": "old.txt",
            "fileSize": 100,
            "sha256Hash": "oldhash"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(TransferMetadata.self, from: data)
        XCTAssertEqual(decoded.fileName, "old.txt")
        XCTAssertNil(decoded.resumeOffset)
        XCTAssertFalse(decoded.isDirectory)
    }

    // MARK: - ChatMessage Edit/Delete Fields

    func testChatMessageEditedAtPreservedInCoding() throws {
        let editDate = Date()
        let msg = ChatMessage(
            id: "m1", text: "Edited", isMedia: false, mediaType: nil,
            fileName: nil, fileSize: nil, mimeType: nil, duration: nil,
            thumbnailData: nil, localFileURL: nil, isOutgoing: true,
            peerName: "P", status: .sent, timestamp: Date(),
            editedAt: editDate, isDeleted: false
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNotNil(decoded.editedAt)
        // Compare with 1-second tolerance
        XCTAssertEqual(decoded.editedAt!.timeIntervalSince1970, editDate.timeIntervalSince1970, accuracy: 1.0)
    }

    func testChatMessageIsDeletedPreservedInCoding() throws {
        var msg = ChatMessage.text(text: "Will delete", isOutgoing: true, peerName: "P")
        msg.isDeleted = true
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertTrue(decoded.isDeleted)
    }

    func testChatMessageOldFormatBackwardCompat() throws {
        // Minimal old-format JSON without editedAt, isDeleted, reactions, groupReadStatus
        let json: [String: Any] = [
            "id": "old-1",
            "text": "Old message",
            "isMedia": false,
            "isOutgoing": false,
            "peerName": "OldPeer",
            "status": "delivered",
            "timestamp": Date().timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(decoded.editedAt)
        XCTAssertFalse(decoded.isDeleted)
        XCTAssertNil(decoded.reactions)
        XCTAssertNil(decoded.groupReadStatus)
        XCTAssertNil(decoded.replyToMessageID)
        XCTAssertNil(decoded.groupID)
    }

    func testCanEditOrDeleteBoundary() {
        // Exactly at 5-minute boundary
        let justUnder = ChatMessage(
            id: "m1", text: "Test", isMedia: false, mediaType: nil,
            fileName: nil, fileSize: nil, mimeType: nil, duration: nil,
            thumbnailData: nil, localFileURL: nil, isOutgoing: true,
            peerName: "P", status: .sent,
            timestamp: Date().addingTimeInterval(-299) // 4:59
        )
        XCTAssertTrue(justUnder.canEditOrDelete)

        let justOver = ChatMessage(
            id: "m2", text: "Test", isMedia: false, mediaType: nil,
            fileName: nil, fileSize: nil, mimeType: nil, duration: nil,
            thumbnailData: nil, localFileURL: nil, isOutgoing: true,
            peerName: "P", status: .sent,
            timestamp: Date().addingTimeInterval(-301) // 5:01
        )
        XCTAssertFalse(justOver.canEditOrDelete)
    }

    // MARK: - ChatManager Edit/Delete Integration

    func testApplyEditPreservesAllFields() {
        let chatManager = ChatManager()
        let original = chatManager.saveOutgoing(text: "Original", peerID: "p1", peerName: "Peer")

        chatManager.applyEdit(messageID: original.id, newText: "Edited", editedAt: Date(), peerID: "p1")

        guard let edited = chatManager.messages.first(where: { $0.id == original.id }) else {
            XCTFail("Message not found"); return
        }
        XCTAssertEqual(edited.text, "Edited")
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.isOutgoing, original.isOutgoing)
        XCTAssertEqual(edited.peerName, original.peerName)
        XCTAssertEqual(edited.timestamp, original.timestamp)
        XCTAssertNotNil(edited.editedAt)
        XCTAssertFalse(edited.isDeleted)
    }

    func testApplyDeleteMarksDeleted() {
        let chatManager = ChatManager()
        let msg = chatManager.saveOutgoing(text: "To delete", peerID: "p1", peerName: "Peer")

        chatManager.applyDelete(messageID: msg.id, peerID: "p1")

        guard let deleted = chatManager.messages.first(where: { $0.id == msg.id }) else {
            XCTFail("Message not found"); return
        }
        XCTAssertTrue(deleted.isDeleted)
        // Text should still be there (we just mark it deleted)
        XCTAssertEqual(deleted.text, "To delete")
    }

    func testApplyEditNonexistentMessageNoOp() {
        let chatManager = ChatManager()
        _ = chatManager.saveOutgoing(text: "Existing", peerID: "p1", peerName: "Peer")

        // Should not crash
        chatManager.applyEdit(messageID: "nonexistent-id", newText: "Whatever", editedAt: Date(), peerID: "p1")

        // Existing message unchanged
        XCTAssertEqual(chatManager.messages.first?.text, "Existing")
    }

    func testApplyDeleteNonexistentMessageNoOp() {
        let chatManager = ChatManager()
        _ = chatManager.saveOutgoing(text: "Existing", peerID: "p1", peerName: "Peer")

        // Should not crash
        chatManager.applyDelete(messageID: "nonexistent-id", peerID: "p1")

        XCTAssertFalse(chatManager.messages.first!.isDeleted)
    }

    func testMultipleEditsPreserveLatest() {
        let chatManager = ChatManager()
        let msg = chatManager.saveOutgoing(text: "V1", peerID: "p1", peerName: "P")

        chatManager.applyEdit(messageID: msg.id, newText: "V2", editedAt: Date(), peerID: "p1")
        chatManager.applyEdit(messageID: msg.id, newText: "V3", editedAt: Date(), peerID: "p1")

        XCTAssertEqual(chatManager.messages.first?.text, "V3")
        XCTAssertNotNil(chatManager.messages.first?.editedAt)
    }

    func testEditThenDeleteShowsDeleted() {
        let chatManager = ChatManager()
        let msg = chatManager.saveOutgoing(text: "Original", peerID: "p1", peerName: "P")

        chatManager.applyEdit(messageID: msg.id, newText: "Edited", editedAt: Date(), peerID: "p1")
        chatManager.applyDelete(messageID: msg.id, peerID: "p1")

        let final = chatManager.messages.first!
        XCTAssertTrue(final.isDeleted)
        XCTAssertFalse(final.canEditOrDelete, "Deleted messages should not be editable")
    }

    // MARK: - FileTransferSession Resume State

    func testFileTransferSessionInitialState() {
        let session = FileTransferSession(peerID: "p1")
        XCTAssertNil(session.lastInterruptedTransfer)
        XCTAssertFalse(session.isTransferring)
        XCTAssertEqual(session.progress, 0)
    }

    func testCanResumeWithNoInterruptedTransfer() {
        let session = FileTransferSession(peerID: "p1")
        let metadata = TransferMetadata(fileName: "a.txt", fileSize: 100, mimeType: nil, sha256Hash: "h")
        XCTAssertFalse(session.canResume(metadata: metadata))
    }

    // MARK: - PeerConnection Properties

    func testPeerConnectionConnectedSinceSetOnConnect() {
        let transport = StubTransport()
        let peerConn = PeerConnection(
            peerID: "p1",
            transport: transport,
            peerIdentity: PeerIdentity(displayName: "Peer"),
            localIdentity: PeerIdentity(displayName: "Local"),
            state: .connecting
        )
        XCTAssertNil(peerConn.connectedSince)

        peerConn.updateState(.connected)
        XCTAssertNotNil(peerConn.connectedSince)
    }

    func testPeerConnectionConnectedSinceClearedOnDisconnect() {
        let transport = StubTransport()
        let peerConn = PeerConnection(
            peerID: "p1",
            transport: transport,
            peerIdentity: PeerIdentity(displayName: "Peer"),
            localIdentity: PeerIdentity(displayName: "Local"),
            state: .connecting
        )
        peerConn.updateState(.connected)
        XCTAssertNotNil(peerConn.connectedSince)

        peerConn.updateState(.disconnected)
        XCTAssertNil(peerConn.connectedSince)
    }

    func testPeerConnectionTransferSpeedDefaultZero() {
        let transport = StubTransport()
        let peerConn = PeerConnection(
            peerID: "p1",
            transport: transport,
            peerIdentity: PeerIdentity(displayName: "Peer"),
            localIdentity: PeerIdentity(displayName: "Local")
        )
        XCTAssertEqual(peerConn.transferSpeed, 0)
    }

    // MARK: - FeatureSettings Defaults

    func testRelayEnabledDefaultTrue() {
        UserDefaults.standard.removeObject(forKey: "peerDropRelayEnabled")
        XCTAssertTrue(FeatureSettings.isRelayEnabled)
    }

    func testClipboardSyncEnabledDefaultTrue() {
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        XCTAssertTrue(FeatureSettings.isClipboardSyncEnabled)
    }

    func testRelayCanBeDisabled() {
        UserDefaults.standard.set(false, forKey: "peerDropRelayEnabled")
        XCTAssertFalse(FeatureSettings.isRelayEnabled)
        UserDefaults.standard.removeObject(forKey: "peerDropRelayEnabled")
    }

    func testClipboardSyncCanBeDisabled() {
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        XCTAssertFalse(FeatureSettings.isClipboardSyncEnabled)
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
    }

    // MARK: - ClipboardSyncManager State

    func testClipboardSyncManagerApplyText() {
        let manager = ClipboardSyncManager()
        let payload = ClipboardSyncPayload(contentType: .text, textContent: "Synced text")
        manager.applyReceivedClipboard(payload)
        XCTAssertEqual(manager.lastSyncedContent, "Synced text")
    }

    func testClipboardSyncManagerApplyURL() {
        let manager = ClipboardSyncManager()
        let payload = ClipboardSyncPayload(contentType: .url, textContent: "https://apple.com")
        manager.applyReceivedClipboard(payload)
        XCTAssertEqual(manager.lastSyncedContent, "https://apple.com")
    }

    func testClipboardSyncManagerClearPending() {
        let manager = ClipboardSyncManager()
        manager.pendingClipboardContent = ClipboardSyncPayload(contentType: .text, textContent: "Pending")
        manager.clearPending()
        XCTAssertNil(manager.pendingClipboardContent)
    }

    func testClipboardSyncManagerStopMonitoring() {
        let manager = ClipboardSyncManager()
        manager.startMonitoring()
        manager.stopMonitoring()
        // Should not crash — idempotent
        manager.stopMonitoring()
    }

    // MARK: - DiscoveredPeer Direction

    func testDiscoveredPeerWithDirection() {
        let dir = SIMD3<Float>(x: 0.5, y: 0, z: 0.5)
        var peer = DiscoveredPeer(
            id: "p1",
            displayName: "Test",
            endpoint: .manual(host: "127.0.0.1", port: 54321),
            source: .bonjour,
            distance: 1.5
        )
        peer.direction = dir
        XCTAssertNotNil(peer.direction)
        XCTAssertEqual(peer.direction?.x, 0.5)
    }
}

// MARK: - Stub Transport for PeerConnection tests

private final class StubTransport: TransportProtocol, @unchecked Sendable {
    var isReady: Bool = true
    var onStateChange: ((TransportState) -> Void)?
    func send(_ message: PeerMessage) async throws {}
    func receive() async throws -> PeerMessage {
        try await Task.sleep(nanoseconds: 100_000_000_000) // hang indefinitely
        throw ConnectionError.notConnected
    }
    func close() {}
}
