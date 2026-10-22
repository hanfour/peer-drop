import XCTest
import PeerDropPlatform
import PeerDropProtocol
@testable import PeerDropTransport
@testable import PeerDropCore
@testable import PeerDrop

/// Phase-0 baseline (docs/plans/2026-08-11-mainactor-offload-design.md): how much
/// main-thread time the receive pipeline and chat persistence cost today.
/// Prints a `[perf-baseline-app]` report; re-run after each phase to compare.
@MainActor
final class MainThreadBaselineAppTests: XCTestCase {
    override func setUp() async throws { PerfSignpost.reset() }

    func testFileChunkReceiveBaseline() {
        let session = FileTransferSession(peerID: "baseline-peer")
        let chunkCount = 256                                  // 256 x 64 KB = 16 MB
        let chunk = Data(repeating: 0xAB, count: Data.defaultChunkSize)
        let metadata = TransferMetadata(
            fileName: "baseline.bin", fileSize: Int64(chunkCount * chunk.count),
            mimeType: nil, sha256Hash: "deadbeef", isDirectory: false)
        session.handleFileOffer(PeerMessage(type: .fileOffer, payload: try! JSONEncoder().encode(metadata), senderID: "remote"))

        for _ in 0..<chunkCount {
            session.handleFileChunk(PeerMessage(type: .fileChunk, payload: chunk, senderID: "remote"))
        }
        XCTAssertNil(session.lastError)
        session.cancelTransfer()

        let s = PerfSignpost.snapshot()[.fileChunkReceive]
        XCTAssertEqual(s?.count, chunkCount)
        XCTAssertEqual(s?.mainThreadCount, chunkCount, "today every chunk is handled on main")
        print("[perf-baseline-app] receive 16MB\n" + PerfSignpost.report())
    }

    func testChatPersistenceBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatManager(rootDirectory: root)
        let peer = "baseline-peer"

        var lastID = ""
        for i in 0..<300 {
            lastID = chat.saveIncoming(text: "message \(i) " + String(repeating: "x", count: 200), peerID: peer, peerName: "Peer").id
            chat.flushAllPendingPersists()     // real usage persists after the 500 ms debounce
        }
        chat.loadMessages(forPeer: peer)
        chat.updateStatus(messageID: lastID, status: .read)

        let snap = PerfSignpost.snapshot()
        XCTAssertEqual(snap[.chatLoad]?.mainThreadCount, snap[.chatLoad]?.count)
        XCTAssertGreaterThan(snap[.chatPersist]?.count ?? 0, 0)
        print("[perf-baseline-app] chat 300 msgs\n" + PerfSignpost.report())
    }
}
