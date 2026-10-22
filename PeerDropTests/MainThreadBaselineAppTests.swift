import XCTest
import CryptoKit
import PeerDropPlatform
import PeerDropSecurity
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

    /// The real-world path: messages arrive, the 500 ms debounce fires, the write
    /// runs on the background persist queue. After phase 3 none of it is on main.
    func testChatDebouncedPersistRunsOffMain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatManager(rootDirectory: root)
        chat.persistDebounceNanoseconds = 1_000_000

        for i in 0..<300 {
            _ = chat.saveIncoming(text: "message \(i) " + String(repeating: "x", count: 200), peerID: "baseline-peer", peerName: "Peer")
            try await Task.sleep(nanoseconds: 3_000_000)   // let the debounce fire between arrivals
        }
        // Sample before the explicit (synchronous, on-main by design) final flush.
        let s = PerfSignpost.snapshot()[.chatPersist]
        print("[perf-baseline-app] chat 300 msgs, debounced\n" + PerfSignpost.report())
        XCTAssertGreaterThan(s?.count ?? 0, 0)
        XCTAssertEqual(s?.mainThreadCount, 0, "debounced persists must stay off main")
        chat.flushAllPendingPersists()
        chat.loadMessages(forPeer: "baseline-peer")
        XCTAssertEqual(chat.messages.count, 50)   // first page
    }

    /// Secure-channel chunk path: what each 64 KB chunk costs on the main actor in
    /// PeerConnection (JSON+base64 encode/decode, ratchet encrypt/decrypt). The
    /// ratchet is stateful, so any offload has to keep it serial and in order.
    func testSecureChunkPipelineBaseline() async throws {
        struct Ident: LocalChannelIdentity {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
            func deriveSharedSecret(with peer: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
                try privateKey.sharedSecretFromKeyAgreement(with: peer)
            }
        }
        final class Loop: TransportProtocol {
            var isReady = true
            var onStateChange: ((TransportState) -> Void)?
            var sent: [PeerMessage] = []
            func send(_ message: PeerMessage) async throws { sent.append(message) }
            func receive() async throws -> PeerMessage { throw CancellationError() }
            func close() {}
        }
        var i1 = Ident(), i2 = Ident()
        if !Array(i1.publicKey.rawRepresentation).lexicographicallyPrecedes(Array(i2.publicKey.rawRepresentation)) { swap(&i1, &i2) }
        let (ta, tb) = (Loop(), Loop())
        let la = PeerIdentity(id: "A", displayName: "A"), lb = PeerIdentity(id: "B", displayName: "B")
        let a = PeerConnection(peerID: "b", transport: ta, peerIdentity: lb, localIdentity: la, state: .connected)
        let b = PeerConnection(peerID: "a", transport: tb, peerIdentity: la, localIdentity: lb, state: .connected)
        try await a.initiateSecureHandshake(identity: i1)
        try await b.handleIncomingSecureHandshake(ta.sent[0], identity: i2)
        try await a.handleIncomingSecureHandshake(tb.sent[0], identity: i1)
        PerfSignpost.reset()

        let chunk = Data(repeating: 0xAB, count: Data.defaultChunkSize)
        var received = 0
        b.onMessageReceived = { _ in received += 1 }
        let n = 256                                        // 16 MB
        for _ in 0..<n {
            try await a.sendMessage(PeerMessage.fileChunk(chunk, senderID: "A"))
            try await b.handleIncomingMessage(ta.sent.removeLast())
        }
        XCTAssertEqual(received, n)
        print("[perf-baseline-app] secure chunk pipeline 16MB\n" + PerfSignpost.report())
    }
}
