import XCTest
import CryptoKit
@testable import PeerDropSecurity

final class TrustedContactAccountBindingTests: XCTestCase {

    var store: TrustedContactStore!
    var storageKey: String!
    var tempDir: URL!
    let encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))

    override func setUp() {
        super.setUp()
        storageKey = "test-trusted-binding-\(UUID().uuidString)"
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-binding-\(UUID().uuidString)", isDirectory: true)
        store = TrustedContactStore(storageKey: storageKey, directory: tempDir, encryptor: encryptor)
    }

    override func tearDown() {
        store.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeContact(name: String, accountId: String? = nil) -> TrustedContact {
        TrustedContact(
            displayName: name,
            identityPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            trustLevel: .verified,
            accountId: accountId
        )
    }

    private func makePending(accountId: String = "acct-pending") -> PendingAccountBinding {
        PendingAccountBinding(
            accountId: accountId,
            signingKey: Data(repeating: 1, count: 32),
            handshakeKeyHash: Data(repeating: 2, count: 32),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testFindByAccountId() {
        let a = makeContact(name: "A")
        let b = makeContact(name: "B")
        store.add(a); store.add(b)
        store.setAccountBinding(for: b.id, accountId: "acct-b")
        XCTAssertEqual(store.find(byAccountId: "acct-b")?.id, b.id)
        XCTAssertNil(store.find(byAccountId: "acct-missing"))
    }

    func testSetBindingClearsSameAccountOnOtherContacts() {
        let a = makeContact(name: "A", accountId: "acct-x")
        let b = makeContact(name: "B")
        store.add(a); store.add(b)
        store.setAccountBinding(for: b.id, accountId: "acct-x")
        XCTAssertNil(store.find(byId: a.id)?.accountId)
        XCTAssertEqual(store.find(byId: b.id)?.accountId, "acct-x")
    }

    func testUnbindClearsAccount() {
        let a = makeContact(name: "A", accountId: "acct-x")
        store.add(a)
        store.setAccountBinding(for: a.id, accountId: nil)
        XCTAssertNil(store.find(byId: a.id)?.accountId)
    }

    func testBindingClearsPending() {
        let a = makeContact(name: "A")
        store.add(a)
        store.setPendingBinding(for: a.id, makePending())
        XCTAssertNotNil(store.find(byId: a.id)?.pendingAccountBinding)
        store.setAccountBinding(for: a.id, accountId: "acct-x")
        XCTAssertNil(store.find(byId: a.id)?.pendingAccountBinding)
    }

    func testKeyChangeClearsBindingAndPending() {
        let a = makeContact(name: "A", accountId: "acct-x")
        store.add(a)
        store.setPendingBinding(for: a.id, makePending())
        store.updatePublicKey(
            for: a.id,
            newKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            reason: .userAcceptedNewKey
        )
        let c = store.find(byId: a.id)
        XCTAssertNil(c?.accountId)
        XCTAssertNil(c?.pendingAccountBinding)
    }

    func testSameKeyUpdateKeepsBinding() {
        let a = makeContact(name: "A", accountId: "acct-x")
        store.add(a)
        store.setPendingBinding(for: a.id, makePending())
        store.updatePublicKey(for: a.id, newKey: a.identityPublicKey, trustLevel: .verified, reason: .detectedOnReconnect)
        let c = store.find(byId: a.id)
        XCTAssertEqual(c?.accountId, "acct-x")
        XCTAssertNotNil(c?.pendingAccountBinding)
    }

    func testLegacyJSONWithoutPendingDecodes() throws {
        let legacy = makeContact(name: "Legacy", accountId: "acct-legacy")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "pendingAccountBinding")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(TrustedContact.self, from: data)
        XCTAssertNil(decoded.pendingAccountBinding)
        XCTAssertEqual(decoded.accountId, "acct-legacy")
        XCTAssertNotNil(json["userId"], "accountId coding key must remain userId")
    }

    func testPendingRoundTripsEncrypted() {
        let a = makeContact(name: "A")
        store.add(a)
        let pending = makePending()
        store.setPendingBinding(for: a.id, pending)
        store.flushPendingSave()
        let reloaded = TrustedContactStore(storageKey: storageKey, directory: tempDir, encryptor: encryptor)
        XCTAssertEqual(reloaded.find(byId: a.id)?.pendingAccountBinding, pending)
    }

    func testSetDeviceIdOnlyWhenNil() {
        let a = makeContact(name: "A")
        store.add(a)
        store.setDeviceId(for: a.id, "dev-1")
        XCTAssertEqual(store.find(byId: a.id)?.deviceId, "dev-1")
        store.setDeviceId(for: a.id, "dev-2")
        XCTAssertEqual(store.find(byId: a.id)?.deviceId, "dev-1")
    }

    func testSetPendingNilClears() {
        let a = makeContact(name: "A")
        store.add(a)
        store.setPendingBinding(for: a.id, makePending())
        store.setPendingBinding(for: a.id, nil)
        XCTAssertNil(store.find(byId: a.id)?.pendingAccountBinding)
    }

    func testSetAccountBindingUnknownIdIsNoOp() {
        let a = makeContact(name: "A", accountId: "acct-x")
        store.add(a)
        store.setAccountBinding(for: UUID(), accountId: "acct-x")
        XCTAssertEqual(store.find(byId: a.id)?.accountId, "acct-x")
    }

    func testSameKeyUpdateLeavesKeyHistoryUnchanged() {
        let a = makeContact(name: "A")
        store.add(a)
        store.updatePublicKey(for: a.id, newKey: a.identityPublicKey, trustLevel: .verified, reason: .detectedOnReconnect)
        XCTAssertEqual(store.find(byId: a.id)?.keyHistory.count, 0)
    }

    func testAddClearsDuplicateAccountOnOtherContacts() {
        let a = makeContact(name: "A", accountId: "acct-x")
        let b = makeContact(name: "B", accountId: "acct-x")
        store.add(a); store.add(b)
        XCTAssertNil(store.find(byId: a.id)?.accountId)
        XCTAssertEqual(store.find(byAccountId: "acct-x")?.id, b.id)
    }
}
