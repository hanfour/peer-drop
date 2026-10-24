import XCTest
import CryptoKit
@testable import PeerDropSecurity

/// Project E — per-contact "always connected" opt-in (`rendezvousEnabled`).
final class TrustedContactRendezvousTests: XCTestCase {

    var store: TrustedContactStore!
    var storageKey: String!
    var tempDir: URL!
    let encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))

    override func setUp() {
        super.setUp()
        storageKey = "test-trusted-rv-\(UUID().uuidString)"
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-rv-\(UUID().uuidString)", isDirectory: true)
        store = TrustedContactStore(storageKey: storageKey, directory: tempDir, encryptor: encryptor)
    }

    override func tearDown() {
        store.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func newKey() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }

    @discardableResult
    private func addBound(_ name: String, key: Data? = nil) -> TrustedContact {
        let c = TrustedContact(deviceId: "dev-\(name)", displayName: name, identityPublicKey: key ?? newKey(),
                               trustLevel: .verified, accountId: "acct-\(name)")
        store.add(c)
        return c
    }

    private func pending() -> PendingAccountBinding {
        PendingAccountBinding(accountId: "acct-p", signingKey: Data(repeating: 1, count: 32),
                              handshakeKeyHash: Data(repeating: 2, count: 32),
                              receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Codable compatibility

    func testDefaultIsNilOff() {
        let c = addBound("a")
        XCTAssertNil(store.find(byId: c.id)?.rendezvousEnabled)
        XCTAssertFalse(store.find(byId: c.id)!.isRendezvousEnabled)
    }

    func testOldJSONWithoutFieldDecodesAsNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","displayName":"Old","identityPublicKey":"\(newKey().base64EncodedString())",
         "trustLevel":"verified","firstConnected":0}
        """
        let c = try JSONDecoder().decode(TrustedContact.self, from: Data(json.utf8))
        XCTAssertNil(c.rendezvousEnabled)
    }

    func testNilIsNotEncodedSoOldBuildsIgnoreIt() throws {
        let c = TrustedContact(displayName: "x", identityPublicKey: newKey(), trustLevel: .verified)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        XCTAssertNil(obj["rendezvousEnabled"])
    }

    func testEnabledRoundTripsAndIsEncodedUnderStableKey() throws {
        var c = TrustedContact(displayName: "x", identityPublicKey: newKey(), trustLevel: .verified)
        c.rendezvousEnabled = true
        let data = try JSONEncoder().encode(c)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["rendezvousEnabled"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(TrustedContact.self, from: data).rendezvousEnabled, true)
    }

    // MARK: - setRendezvousEnabled

    func testEnableBoundContact() throws {
        let c = addBound("a")
        try store.setRendezvousEnabled(for: c.id, true)
        XCTAssertEqual(store.find(byId: c.id)?.rendezvousEnabled, true)
        XCTAssertEqual(store.rendezvousEnabledContacts.map(\.id), [c.id])
    }

    func testDisableClearsToNil() throws {
        let c = addBound("a")
        try store.setRendezvousEnabled(for: c.id, true)
        try store.setRendezvousEnabled(for: c.id, false)
        XCTAssertNil(store.find(byId: c.id)?.rendezvousEnabled)
    }

    func testUnknownContactIsTypedError() {
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: UUID(), true)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .unknownContact)
        }
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: UUID(), false)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .unknownContact)
        }
    }

    func testUnboundContactRefused() {
        let c = TrustedContact(deviceId: "d", displayName: "u", identityPublicKey: newKey(), trustLevel: .verified)
        store.add(c)
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: c.id, true)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .notBound)
        }
        XCTAssertNil(store.find(byId: c.id)?.rendezvousEnabled)
    }

    func testPendingBindingRefusedEvenWithAccountId() {
        let c = addBound("p")
        store.setPendingBinding(for: c.id, pending())
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: c.id, true)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .notBound)
        }
    }

    func testBlockedRefused() {
        let c = addBound("b")
        store.setBlocked(c.id, blocked: true)
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: c.id, true)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .notBound)
        }
    }

    func testDuplicatedKeyRefusedLikeFriendBinding() {
        let key = newKey()
        let c = addBound("d1", key: key)
        store.add(TrustedContact(displayName: "dup", identityPublicKey: key, trustLevel: .unknown))
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: c.id, true)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .notBound)
        }
    }

    func testMissingDeviceIdRefused() {
        let c = TrustedContact(displayName: "n", identityPublicKey: newKey(), trustLevel: .verified, accountId: "acct-n")
        store.add(c)
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: c.id, true)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .notBound)
        }
    }

    func testLimitOfFiveIsAnErrorNotSilent() throws {
        let contacts = (0..<6).map { addBound("c\($0)") }
        for c in contacts.prefix(5) { try store.setRendezvousEnabled(for: c.id, true) }
        XCTAssertThrowsError(try store.setRendezvousEnabled(for: contacts[5].id, true)) {
            XCTAssertEqual($0 as? RendezvousOptInError, .limitExceeded)
        }
        XCTAssertNil(store.find(byId: contacts[5].id)?.rendezvousEnabled)
        XCTAssertEqual(store.rendezvousEnabledContacts.count, 5)
        XCTAssertEqual(TrustedContactStore.maxRendezvousContacts, 5)
        // Re-enabling an already-enabled one at the limit is idempotent.
        XCTAssertNoThrow(try store.setRendezvousEnabled(for: contacts[0].id, true))
        // Freeing a slot allows the sixth.
        try store.setRendezvousEnabled(for: contacts[0].id, false)
        XCTAssertNoThrow(try store.setRendezvousEnabled(for: contacts[5].id, true))
    }

    func testDisableAlwaysAllowedEvenWhenNoLongerBound() throws {
        let c = addBound("x")
        try store.setRendezvousEnabled(for: c.id, true)
        store.setPendingBinding(for: c.id, pending())
        XCTAssertNoThrow(try store.setRendezvousEnabled(for: c.id, false))
        XCTAssertNil(store.find(byId: c.id)?.rendezvousEnabled)
    }

    // MARK: - Auto-disable

    func testKeyChangeDisablesAndClears() throws {
        let c = addBound("k")
        try store.setRendezvousEnabled(for: c.id, true)
        store.updatePublicKey(for: c.id, newKey: newKey(), reason: .detectedOnReconnect)
        XCTAssertNil(store.find(byId: c.id)?.rendezvousEnabled)
        XCTAssertTrue(store.rendezvousEnabledContacts.isEmpty)
    }

    func testSameKeyUpdateKeepsFlag() throws {
        let c = addBound("s")
        try store.setRendezvousEnabled(for: c.id, true)
        store.updatePublicKey(for: c.id, newKey: c.identityPublicKey, trustLevel: .verified, reason: .detectedOnReconnect)
        XCTAssertEqual(store.find(byId: c.id)?.rendezvousEnabled, true)
    }

    func testUnbindClearsFlag() throws {
        let c = addBound("u")
        try store.setRendezvousEnabled(for: c.id, true)
        store.setAccountBinding(for: c.id, accountId: nil)
        XCTAssertNil(store.find(byId: c.id)?.rendezvousEnabled)
    }

    func testAccountMovedToAnotherContactClearsFlagOnOldOne() throws {
        let c = addBound("m")
        try store.setRendezvousEnabled(for: c.id, true)
        let other = TrustedContact(deviceId: "o", displayName: "o", identityPublicKey: newKey(), trustLevel: .verified)
        store.add(other)
        store.setAccountBinding(for: other.id, accountId: "acct-m")
        XCTAssertNil(store.find(byId: c.id)?.rendezvousEnabled)
    }

    /// Enabled-but-ineligible (e.g. pending re-exchange) is not reported as active.
    func testEnabledContactsListExcludesIneligible() throws {
        let c = addBound("e")
        try store.setRendezvousEnabled(for: c.id, true)
        store.setPendingBinding(for: c.id, pending())
        XCTAssertTrue(store.rendezvousEnabledContacts.isEmpty)
        XCTAssertFalse(TrustedContactStore.isRendezvousEligible(store.find(byId: c.id)!, among: store.contacts))
    }

    func testPersistsAcrossReload() throws {
        let c = addBound("r")
        try store.setRendezvousEnabled(for: c.id, true)
        store.flushPendingSave()
        let reloaded = TrustedContactStore(storageKey: storageKey, directory: tempDir, encryptor: encryptor)
        XCTAssertEqual(reloaded.find(byId: c.id)?.rendezvousEnabled, true)
    }
}
