// MainActor-offload phase 3: the debounced chat write runs on a background
// queue. These pin the invariants that make that safe — nothing lost, nothing
// duplicated, deletes stay deleted, and the write really is off the main thread.
import XCTest
import PeerDropPlatform
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerBackgroundPersistTests: XCTestCase {
    private var keyDir: URL!
    private var root: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmbgtest")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmroot-\(UUID().uuidString)")
        PerfSignpost.reset()
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @MainActor
    private func makeManager() -> ChatManager {
        let m = ChatManager(rootDirectory: root)
        m.persistDebounceNanoseconds = 1_000_000   // 1 ms
        m.activeChatPeerID = "peerX"
        return m
    }

    @MainActor
    private func reloaded(_ peer: String) -> [ChatMessage] {
        let fresh = ChatManager(rootDirectory: root)
        fresh.loadMessages(forPeer: peer)
        return fresh.messages
    }

    @MainActor
    func test_debouncedPersist_writesOffMainThread_andIsNotDuplicatedByFlush() async throws {
        let m = makeManager()
        for i in 0..<20 { _ = m.saveIncoming(text: "m\(i)", peerID: "peerX", peerName: "X") }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the debounce + background write run
        m.flushAllPendingPersists()                       // races/overlaps the already-written snapshot

        XCTAssertEqual(reloaded("peerX").map(\.text), (0..<20).map { "m\($0)" })
        let s = PerfSignpost.snapshot()[.chatPersist]
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.mainThreadCount, 0, "debounced write must not run on the main thread")
    }

    @MainActor
    func test_flushImmediatelyAfterSave_persistsEverythingExactlyOnce() async throws {
        let m = makeManager()
        for i in 0..<50 {
            _ = m.saveIncoming(text: "m\(i)", peerID: "peerX", peerName: "X")
            if i % 7 == 0 { m.flushAllPendingPersists() }
        }
        m.flushAllPendingPersists()
        XCTAssertEqual(reloaded("peerX").count, 50)
    }

    @MainActor
    func test_deleteAfterBackgroundWriteStarted_doesNotResurrectFile() async throws {
        let m = makeManager()
        for i in 0..<30 { _ = m.saveIncoming(text: "m\(i)", peerID: "peerX", peerName: "X") }
        try await Task.sleep(nanoseconds: 5_000_000)      // debounce fires, write likely in flight
        m.deleteMessages(forPeer: "peerX")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(reloaded("peerX").isEmpty)
    }

    @MainActor
    func test_messagesAppendedWhileWriteInFlight_arePersistedLater() async throws {
        let m = makeManager()
        for round in 0..<5 {
            for i in 0..<10 { _ = m.saveIncoming(text: "r\(round)-\(i)", peerID: "peerX", peerName: "X") }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        m.flushAllPendingPersists()
        XCTAssertEqual(reloaded("peerX").count, 50)
    }
}
