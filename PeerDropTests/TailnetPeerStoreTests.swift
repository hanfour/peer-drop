import XCTest
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
}
