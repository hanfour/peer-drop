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
    private func resolve(_ peer: String, live: LiveConnectionKey = .none, _ contacts: [TrustedContact]) -> TrustedContact? {
        FriendBindingResolver.resolve(peerID: peer, live: live, contacts: contacts)
    }
    private func pendingClaim(_ id: String) -> PendingAccountBinding {
        PendingAccountBinding(accountId: id, signingKey: Data(repeating: 1, count: 32), handshakeKeyHash: Data(repeating: 2, count: 32), receivedAt: Date())
    }

    func testSecuredLiveConnectionResolvesByHandshakeKey() {
        let c = contact(key: keyA, deviceId: "other-id")
        XCTAssertEqual(resolve("p1", live: .secured(keyA), [c, contact(key: keyB)])?.id, c.id)
    }

    func testSecuredKeyWithNoMatchingContactDoesNotFallBackToDeviceId() {
        XCTAssertNil(resolve("p1", live: .secured(keyA), [contact(key: keyB, deviceId: "p1")]))
    }

    func testUnsecuredLiveConnectionReturnsNil() {
        XCTAssertNil(resolve("p1", live: .unsecured, [contact(key: keyA, deviceId: "p1")]))
    }

    func testOfflineResolvesByDeviceId() {
        let c = contact(key: keyA, deviceId: "p1")
        XCTAssertEqual(resolve("p1", [c, contact(key: keyB, deviceId: "p2")])?.id, c.id)
    }

    func testOfflineRequiresKeyUniqueness() {
        let a = contact(key: keyA, deviceId: "p1"), dup = contact(key: keyA, deviceId: "p2")
        XCTAssertNil(resolve("p1", [a, dup]))
    }

    func testSeveralCandidatesReturnNil() {
        XCTAssertNil(resolve("p1", [contact(key: keyA, deviceId: "p1"), contact(key: keyB, deviceId: "p1")]))
        XCTAssertNil(resolve("p1", live: .secured(keyA), [contact(key: keyA), contact(key: keyA)]))
    }

    func testBlockedContactReturnsNil() {
        XCTAssertNil(resolve("p1", [contact(key: keyA, deviceId: "p1", blocked: true)]))
        XCTAssertNil(resolve("p1", live: .secured(keyA), [contact(key: keyA, blocked: true)]))
    }

    func testBlockedOfflineWithUnblockedDuplicateStillNil() {
        let blocked = contact(key: keyA, deviceId: "p1", blocked: true)
        let dup = contact(key: keyA, deviceId: "p1")
        XCTAssertNil(resolve("p1", [blocked, dup]))
    }

    func testUnknownPeerReturnsNil() {
        XCTAssertNil(resolve("nobody", [contact(key: keyA, deviceId: "p1")]))
    }

    // Name merges in DeviceRecordStore leave no marker, so they cannot be
    // detected; resolution is per identity (key / PeerIdentity.id) only.
    func testResolutionIgnoresDisplayNames() {
        let a = contact(key: keyA, deviceId: "p1", name: "Bob"), b = contact(key: keyB, deviceId: "p2", name: "Bob")
        XCTAssertEqual(resolve("p1", [a, b])?.id, a.id)
        XCTAssertEqual(resolve("p2", [a, b])?.id, b.id)
    }

    func testVerifiedAccountAndBindingState() {
        let verified = contact(key: keyA, deviceId: "p1", account: "ABCD1234")
        let pendingOnly = contact(key: keyB, deviceId: "p2", pending: pendingClaim("WXYZ5678"))
        let reExchange = contact(key: Data(repeating: 4, count: 32), deviceId: "p4", account: "OLDX2345", pending: pendingClaim("NEWY2345"))
        let none = contact(key: Data(repeating: 3, count: 32), deviceId: "p3")
        let all = [verified, pendingOnly, reExchange, none]
        let fb = FriendBinding(contacts: { all }, live: { _ in .none })
        let v = fb.verifiedAccount(forChatPeerID: "p1")
        XCTAssertEqual(v?.accountId, "ABCD1234"); XCTAssertEqual(v?.contactID, verified.id); XCTAssertEqual(v?.identityKey, keyA)
        XCTAssertEqual(fb.bindingState(forChatPeerID: "p1"), .verified)
        XCTAssertNil(fb.verifiedAccount(forChatPeerID: "p2"))
        XCTAssertEqual(fb.bindingState(forChatPeerID: "p2"), .pending)
        // old accountId X + pending Y: never expose X as verified
        XCTAssertNil(fb.verifiedAccount(forChatPeerID: "p4"))
        XCTAssertEqual(fb.bindingState(forChatPeerID: "p4"), .pending)
        XCTAssertNil(fb.verifiedAccount(forChatPeerID: "p3"))
        XCTAssertEqual(fb.bindingState(forChatPeerID: "p3"), .none)
        XCTAssertEqual(fb.bindingState(forChatPeerID: "zzz"), .none)
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
        XCTAssertEqual(fb.verifiedAccount(forChatPeerID: "fb-peer")?.accountId, "ABCD1234")
        XCTAssertNil(fb.contact(forChatPeerID: "other"))
    }
}
