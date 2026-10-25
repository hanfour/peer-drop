// Project F1 / Task 2: a category's notification switch mutes LOCAL
// presentation (banner/sound) for every alias of its friends; messages and
// unread counts are unaffected.
import XCTest
import CryptoKit
import PeerDropProtocol
@testable import PeerDropTransport
@testable import PeerDropCore
@testable import PeerDropSecurity

@MainActor
final class CategoryNotificationMuteTests: XCTestCase {
    private final class Loop: TransportProtocol {
        var isReady = true
        var onStateChange: ((TransportState) -> Void)?
        func send(_ message: PeerMessage) async throws {}
        func receive() async throws -> PeerMessage { throw CancellationError() }
        func close() {}
    }

    private var cm: ConnectionManager!
    private var keyDir: URL!
    private var catDir: URL!
    private var suite: String!
    private var touched: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("catmute-\(UUID().uuidString)")
        catDir = FileManager.default.temporaryDirectory.appendingPathComponent("catmute-cat-\(UUID().uuidString)")
        suite = "catmute-\(UUID().uuidString)"
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "catmutetest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        let store = FriendCategoryStore(directory: catDir,
                                        encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)),
                                        migrationDefaults: UserDefaults(suiteName: suite)!)
        cm = ConnectionManager(categoryStore: store)
    }

    override func tearDown() async throws {
        for id in touched {
            cm.chatManager.deleteMessages(forPeer: id)
            cm.deviceStore.remove(id: id)
        }
        touched = []
        cm = nil
        UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
        UserDefaults().removePersistentDomain(forName: suite)
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try? FileManager.default.removeItem(at: catDir)
        try await super.tearDown()
    }

    // MARK: Helpers

    private func addRecord(_ id: String = "dev-\(UUID().uuidString)", identity: String? = nil) -> String {
        touched.append(id)
        // Unique names: the store merges records that share a display name.
        cm.deviceStore.addOrUpdate(id: id, displayName: "Friend \(id)", sourceType: "bonjour", host: nil, port: nil)
        if let identity { _ = cm.deviceStore.setPeerIdentityId(for: id, identityId: identity) }
        return id
    }

    private func mutedCategory(with friendID: String) {
        let cat = cm.categoryStore.create(name: "安靜")!
        cm.categoryStore.assign(friendID: friendID, to: cat.id)
        cm.categoryStore.setNotificationsEnabled(false, for: cat.id)
    }

    private func installConnection(id: String, identityID: String? = nil) -> PeerConnection {
        let pc = PeerConnection(peerID: id, transport: Loop(),
                                peerIdentity: PeerIdentity(id: identityID ?? id, displayName: "Friend"),
                                localIdentity: cm.localIdentity, state: .connected)
        cm._setConnectionForTesting(peerID: id, pc)
        touched.append(identityID ?? id)
        return pc
    }

    // MARK: Tests

    func testMutedCategoryMutesChatNotification() {
        let rid = addRecord()
        mutedCategory(with: rid)
        XCTAssertTrue(cm.isNotificationMuted(forPeer: [rid]))
        XCTAssertFalse(cm.shouldPresentNotification(forPeer: [rid]))
        let pc = installConnection(id: rid)
        XCTAssertFalse(cm.shouldPresentNotification(for: pc))
    }

    func testUncategorizedFriendNotMuted() {
        let rid = addRecord()
        XCTAssertTrue(cm.shouldPresentNotification(forPeer: [rid]))
        // A friend in a category whose notifications are on is not muted either.
        let cat = cm.categoryStore.create(name: "家人")!
        cm.categoryStore.assign(friendID: rid, to: cat.id)
        XCTAssertTrue(cm.shouldPresentNotification(forPeer: [rid]))
        XCTAssertTrue(cm.shouldPresentNotification(for: installConnection(id: rid)))
        // Muting someone else leaves this friend alone.
        mutedCategory(with: addRecord())
        XCTAssertTrue(cm.shouldPresentNotification(forPeer: [rid]))
    }

    func testSecondRecordOfSamePersonIsMutedToo() {
        // Relay record carries the real identity; the same friend's LAN record
        // is keyed by that identity UUID. Only the relay record is categorized.
        let identity = UUID().uuidString
        let relayID = addRecord("relay-\(UUID().uuidString.prefix(6))", identity: identity)
        let lanID = addRecord(identity)
        mutedCategory(with: relayID)
        XCTAssertFalse(cm.shouldPresentNotification(forPeer: [lanID]))
        XCTAssertFalse(cm.shouldPresentNotification(for: installConnection(id: lanID)))

        // The other way round: categorize the LAN record, message arrives on relay.
        let identity2 = UUID().uuidString
        let relay2 = addRecord("relay-\(UUID().uuidString.prefix(6))", identity: identity2)
        let lan2 = addRecord(identity2)
        mutedCategory(with: lan2)
        XCTAssertFalse(cm.shouldPresentNotification(forPeer: [relay2]))
        XCTAssertFalse(cm.shouldPresentNotification(for: installConnection(id: relay2, identityID: identity2)))

        // A record known by its peerDeviceId alias.
        let rid = addRecord()
        cm.deviceStore.updatePeerDeviceId(for: rid, deviceId: "devalias-\(rid)")
        mutedCategory(with: rid)
        XCTAssertFalse(cm.shouldPresentNotification(forPeer: ["devalias-\(rid)"]))
    }

    func testPinnedKeyContactsAreTheSamePerson() {
        // Two contacts pinning the same identity key (e.g. the key moved to a
        // new device id) are one friend.
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let oldDevice = addRecord(), newDevice = "dev-new-\(UUID().uuidString)"
        cm.trustedContactStore.add(TrustedContact(deviceId: oldDevice, displayName: "K", identityPublicKey: key, trustLevel: .linked))
        cm.trustedContactStore.add(TrustedContact(deviceId: newDevice, displayName: "K", identityPublicKey: key, trustLevel: .linked))
        defer { cm.trustedContactStore.removeAll() }
        mutedCategory(with: oldDevice)
        XCTAssertFalse(cm.shouldPresentNotification(forPeer: [newDevice]))
        // A connection whose identity carries that key, with an unrelated id.
        let pc = PeerConnection(peerID: "other-\(UUID().uuidString)", transport: Loop(),
                                peerIdentity: PeerIdentity(id: "other-ident", displayName: "K", identityPublicKey: key),
                                localIdentity: cm.localIdentity, state: .connected)
        XCTAssertFalse(cm.shouldPresentNotification(for: pc))
    }

    func testMutingDoesNotChangeUnreadCounts() throws {
        let muted = addRecord(), loud = addRecord()
        mutedCategory(with: muted)
        let pcMuted = installConnection(id: muted), pcLoud = installConnection(id: loud)
        for pc in [pcMuted, pcLoud] {
            cm.handleMessageForPeer(try PeerMessage.textMessage(TextMessagePayload(text: "hi", messageID: UUID().uuidString),
                                                                senderID: pc.peerIdentity.id),
                                    peerConnection: pc)
        }
        XCTAssertFalse(cm.shouldPresentNotification(for: pcMuted))
        XCTAssertEqual(cm.chatManager.unreadCounts[muted], 1)
        XCTAssertEqual(cm.chatManager.unreadCounts[loud], 1)
    }
}
