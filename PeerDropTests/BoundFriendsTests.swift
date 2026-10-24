import XCTest
import CryptoKit
import PeerDropCore
import PeerDropSecurity
@testable import PeerDrop

@MainActor
final class BoundFriendsTests: XCTestCase {
    private var store: TrustedContactStore!
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bf-\(UUID().uuidString)", isDirectory: true)
        store = TrustedContactStore(storageKey: "bf-\(UUID().uuidString)", directory: dir,
                                    encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
    }
    override func tearDown() { store.removeAll(); try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func add(device: String, account: String? = nil, pending: Bool = false, blocked: Bool = false) -> TrustedContact {
        let c = TrustedContact(deviceId: device, displayName: device,
                               identityPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                               trustLevel: .linked, accountId: account, isBlocked: blocked,
                               pendingAccountBinding: pending
                                   ? PendingAccountBinding(accountId: account ?? "PENDING1", signingKey: Data(repeating: 1, count: 32),
                                                           handshakeKeyHash: Data(repeating: 2, count: 32), receivedAt: Date())
                                   : nil)
        store.add(c)
        return c
    }

    private func map(_ records: [String]) -> [String: String] {
        let binding = FriendBinding(contacts: { self.store.contacts }, live: { _ in .none })
        return BoundFriends.recordIDByAccount(recordIDs: records, chatKey: { $0 }, binding: binding)
    }

    func testOnlyVerifiedContactsAreBound() {
        add(device: "ver", account: "VERIFIED")
        add(device: "pend", account: "OLDACCT1", pending: true)   // old id still stored but a claim is pending
        add(device: "pendnew", account: nil, pending: true)
        add(device: "none")
        add(device: "blk", account: "BLOCKED1", blocked: true)
        XCTAssertEqual(map(["ver", "pend", "pendnew", "none", "blk"]), ["VERIFIED": "ver"])
    }

    func testUnbindRemovesFromMapAndPendingNeverFolds() {
        let c = add(device: "a", account: "ACCT0001")
        XCTAssertEqual(map(["a"]), ["ACCT0001": "a"])
        store.setPendingBinding(for: c.id, PendingAccountBinding(accountId: "ACCT0001", signingKey: Data(repeating: 1, count: 32),
                                                                handshakeKeyHash: Data(repeating: 2, count: 32), receivedAt: Date()))
        XCTAssertTrue(map(["a"]).isEmpty)
        store.setAccountBinding(for: c.id, accountId: nil)
        XCTAssertTrue(map(["a"]).isEmpty)
    }

    func testTwoRecordsResolvingToSameAccountYieldOneDeterministicRow() {
        // Bypass the store's uniqueness by feeding contacts directly.
        let k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32)
        let cs = [TrustedContact(deviceId: "r1", displayName: "a", identityPublicKey: k1, trustLevel: .linked, accountId: "SAMEACCT"),
                  TrustedContact(deviceId: "r2", displayName: "b", identityPublicKey: k2, trustLevel: .linked, accountId: "SAMEACCT")]
        let binding = FriendBinding(contacts: { cs }, live: { _ in .none })
        XCTAssertEqual(BoundFriends.recordIDByAccount(recordIDs: ["r1", "r2"], chatKey: { $0 }, binding: binding), ["SAMEACCT": "r1"])
        XCTAssertEqual(BoundFriends.recordIDByAccount(recordIDs: ["r2", "r1"], chatKey: { $0 }, binding: binding), ["SAMEACCT": "r2"])
    }
}
