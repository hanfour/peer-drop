import XCTest
import PeerDropSecurity
@testable import PeerDropCore

@MainActor
final class FriendBindingTests: XCTestCase {
    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    private func contact(key: Data, deviceId: String? = nil, name: String = "Bob", account: String? = nil,
                         pending: PendingAccountBinding? = nil, blocked: Bool = false) -> TrustedContact {
        TrustedContact(deviceId: deviceId, displayName: name, identityPublicKey: key, trustLevel: .linked,
                       accountId: account, isBlocked: blocked, pendingAccountBinding: pending)
    }
    private func record(_ id: String, _ name: String = "Bob") -> DeviceRecord {
        DeviceRecord(id: id, displayName: name, sourceType: "bonjour", lastConnected: Date())
    }
    private func resolve(_ peer: String, live: Data? = nil, _ contacts: [TrustedContact], _ records: [DeviceRecord] = []) -> TrustedContact? {
        FriendBindingResolver.resolve(peerID: peer, liveHandshakeKey: live, contacts: contacts, records: records)
    }

    func testLiveConnectionResolvesByHandshakeKey() {
        let c = contact(key: keyA, deviceId: "other-id")
        XCTAssertEqual(resolve("p1", live: keyA, [c, contact(key: keyB)])?.id, c.id)
    }

    func testLiveKeyWithNoMatchingContactDoesNotFallBackToDeviceId() {
        let c = contact(key: keyB, deviceId: "p1")
        XCTAssertNil(resolve("p1", live: keyA, [c]))
    }

    func testOfflineResolvesByDeviceId() {
        let c = contact(key: keyA, deviceId: "p1")
        XCTAssertEqual(resolve("p1", [c, contact(key: keyB, deviceId: "p2")], [record("p1")])?.id, c.id)
    }

    func testRecordNameMergedWithAnotherRecordIsAmbiguous() {
        let c = contact(key: keyA, deviceId: "p1")
        XCTAssertNil(resolve("p1", [c], [record("p1", "Bob"), record("p9", "bob")]))
    }

    func testSeveralCandidatesReturnNil() {
        let a = contact(key: keyA, deviceId: "p1"), b = contact(key: keyB, deviceId: "p1")
        XCTAssertNil(resolve("p1", [a, b]))
        XCTAssertNil(resolve("p1", live: keyA, [a, contact(key: keyA)]))
    }

    func testBlockedContactReturnsNil() {
        XCTAssertNil(resolve("p1", [contact(key: keyA, deviceId: "p1", blocked: true)]))
        XCTAssertNil(resolve("p1", live: keyA, [contact(key: keyA, blocked: true)]))
    }

    func testRecordPeerDeviceIdIsNeverUsed() {
        // peerDeviceId is a relay DeviceIdentity id, not PeerIdentity.id space.
        var r = record("bonjour-name"); r.peerDeviceId = "p1"
        XCTAssertNil(resolve("bonjour-name", [contact(key: keyA, deviceId: "p1")], [r]))
    }

    func testUnknownPeerReturnsNil() {
        XCTAssertNil(resolve("nobody", [contact(key: keyA, deviceId: "p1")]))
    }

    func testBoundAccountVerifiedAndPending() {
        let verified = contact(key: keyA, deviceId: "p1", account: "ABCD1234")
        let pending = contact(key: keyB, deviceId: "p2", account: "WXYZ5678",
                              pending: PendingAccountBinding(accountId: "WXYZ5678", signingKey: Data(repeating: 1, count: 32),
                                                             handshakeKeyHash: Data(repeating: 2, count: 32), receivedAt: Date()))
        let none = contact(key: Data(repeating: 3, count: 32), deviceId: "p3")
        let fb = FriendBinding(contacts: { [verified, pending, none] }, records: { [] }, liveHandshakeKey: { _ in nil })
        let v = fb.boundAccount(forChatPeerID: "p1")
        XCTAssertEqual(v?.accountId, "ABCD1234"); XCTAssertEqual(v?.verified, true)
        XCTAssertEqual(v?.contactID, verified.id); XCTAssertEqual(v?.identityKey, keyA)
        XCTAssertEqual(fb.boundAccount(forChatPeerID: "p2")?.verified, false)
        XCTAssertNil(fb.boundAccount(forChatPeerID: "p3"))
        XCTAssertEqual(fb.bindingState(forChatPeerID: "p1"), .verified)
        XCTAssertEqual(fb.bindingState(forChatPeerID: "p2"), .pending)
        XCTAssertEqual(fb.bindingState(forChatPeerID: "p3"), .none)
        XCTAssertEqual(fb.bindingState(forChatPeerID: "zzz"), .none)
        XCTAssertNil(fb.boundAccount(forChatPeerID: "zzz"))
    }

    func testConnectionManagerConvenienceInit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: dir, namespace: "fbtest")
        defer { PeerDropPersistence.fileStore = nil; try? FileManager.default.removeItem(at: dir) }
        let cm = ConnectionManager()
        cm.trustedContactStore.removeAll()
        let c = contact(key: keyA, deviceId: "fb-peer", account: "ABCD1234")
        cm.trustedContactStore.add(c)
        defer { cm.trustedContactStore.removeAll() }
        let fb = FriendBinding(connectionManager: cm)
        XCTAssertEqual(fb.contact(forChatPeerID: "fb-peer")?.id, c.id)
        XCTAssertEqual(fb.boundAccount(forChatPeerID: "fb-peer")?.accountId, "ABCD1234")
        XCTAssertNil(fb.contact(forChatPeerID: "other"))
    }
}
