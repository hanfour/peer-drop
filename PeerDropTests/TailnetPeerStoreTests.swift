import XCTest
import Network
@testable import PeerDrop

@MainActor
final class TailnetPeerStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "peerDropTailnetPeers")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "peerDropTailnetPeers")
        super.tearDown()
    }

    func test_addPersistsEntry() {
        let store = TailnetPeerStore()
        store.add(displayName: "Alice", ip: "100.64.1.1")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.displayName, "Alice")
        let reloaded = TailnetPeerStore()
        XCTAssertEqual(reloaded.entries.count, 1)
    }

    func test_removeDeletesEntry() {
        let store = TailnetPeerStore()
        store.add(displayName: "A", ip: "100.64.1.1")
        let id = store.entries.first!.id
        store.remove(id: id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_renameUpdatesName() {
        let store = TailnetPeerStore()
        store.add(displayName: "Old", ip: "100.64.1.1")
        let id = store.entries.first!.id
        store.rename(id: id, to: "New")
        XCTAssertEqual(store.entries.first?.displayName, "New")
    }

    func test_probeReachableLoopback() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let group = DispatchGroup(); group.enter()
        var boundPort: NWEndpoint.Port = .any
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port { boundPort = port; group.leave() }
        }
        listener.newConnectionHandler = { conn in conn.start(queue: .global()) }
        listener.start(queue: .global())
        group.wait()

        let store = TailnetPeerStore()
        store.add(displayName: "Loopback", ip: "127.0.0.1", port: boundPort.rawValue)
        await store.probeAll()
        XCTAssertNotNil(store.entries.first?.lastReachable)
        XCTAssertEqual(store.entries.first?.consecutiveFailures, 0)
        XCTAssertTrue(store.isReachable(store.entries.first!.id))
        listener.cancel()
    }

    func test_probeUnreachableMarksAfterTwoFailures() async {
        let store = TailnetPeerStore()
        store.add(displayName: "Nowhere", ip: "192.0.2.1", port: 9876) // RFC 5737 TEST-NET-1
        await store.probeAll()
        XCTAssertEqual(store.entries.first?.consecutiveFailures, 1)
        // isReachable requires lastReachable != nil — never connected, so false even with 1 failure
        await store.probeAll()
        XCTAssertEqual(store.entries.first?.consecutiveFailures, 2)
        XCTAssertFalse(store.isReachable(store.entries.first!.id))
    }
}
