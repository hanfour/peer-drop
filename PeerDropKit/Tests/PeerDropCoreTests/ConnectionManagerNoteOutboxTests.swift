import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropNotes
import PeerDropAccount
import Network
@testable import PeerDropCore

@MainActor
final class ConnectionManagerNoteOutboxTests: XCTestCase {
    private var cm: ConnectionManager!
    private var keyDir: URL!
    private var outboxDir: URL!
    private let key = Data(repeating: 5, count: 32)

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmob-\(UUID().uuidString)")
        outboxDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmob-o-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmobtest")
        cm = ConnectionManager()
        cm.trustedContactStore.removeAll()
        cm.noteOutbox = NoteOutboxStore(directory: outboxDir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
    }
    override func tearDown() async throws {
        cm.trustedContactStore.removeAll()
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir); try? FileManager.default.removeItem(at: outboxDir)
        try await super.tearDown()
    }

    private func bound(blocked: Bool = false) -> TrustedContact {
        let c = TrustedContact(deviceId: "dev-\(UUID().uuidString)", displayName: "F", identityPublicKey: key, trustLevel: .unknown, accountId: "FRND2345")
        cm.trustedContactStore.add(c)
        if blocked { cm.trustedContactStore.setBlocked(c.id, blocked: true) }
        return c
    }

    func testQueueNoteRefusedForBlockedContact() {
        let c = bound(blocked: true)
        XCTAssertThrowsError(try cm.queueNote(text: "x", toContact: c.id)) { XCTAssertEqual($0 as? ConnectionManager.QueueNoteError, .blocked) }
        XCTAssertTrue(cm.noteOutbox.all.isEmpty)
    }

    func testQueueNoteRefusedWithoutBinding() {
        let c = TrustedContact(deviceId: "d", displayName: "F", identityPublicKey: key, trustLevel: .unknown)
        cm.trustedContactStore.add(c)
        XCTAssertThrowsError(try cm.queueNote(text: "x", toContact: c.id)) { XCTAssertEqual($0 as? ConnectionManager.QueueNoteError, .notBound) }
    }

    func testBlockingAfterQueueingFailsEntryWithoutSending() async throws {
        let c = bound()
        let e = cm.noteOutbox.enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "x")
        cm.trustedContactStore.setBlocked(c.id, blocked: true)
        XCTAssertEqual(cm.noteOutbox.all.count, 1)   // blocking keeps the entry (as failed), never deletes it
        await cm.flushNoteOutbox()
        let got = cm.noteOutbox.all.first { $0.id == e.id }
        XCTAssertEqual(got?.state, .failed); XCTAssertEqual(got?.attempts, 0)
    }

    func testBindingLookupComparesKey() {
        var c = bound()
        XCTAssertEqual(ConnectionManager.outboxBinding(for: c), .verified(accountId: "FRND2345", identityKey: key))
        c.identityPublicKey = Data(repeating: 9, count: 32)
        XCTAssertEqual(ConnectionManager.outboxBinding(for: c), .verified(accountId: "FRND2345", identityKey: Data(repeating: 9, count: 32)))
        XCTAssertEqual(ConnectionManager.outboxBinding(for: nil), .none)
    }

    func testUnbindNotesFailsQueuedEntries() {
        let c = bound()
        cm.noteOutbox.enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "x")
        cm.unbindNotes(contactID: c.id)
        XCTAssertEqual(cm.noteOutbox.all.first?.state, .failed)
        XCTAssertEqual(cm.noteOutbox.all.first?.failReason, "綁定已取消")
    }

    func testQueueNoteThrowsWhenOutboxUnavailable() {
        let c = bound()
        let dir = outboxDir!
        NoteOutboxStore(directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
            .enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "old")
        cm.noteOutbox = NoteOutboxStore(directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)),
                                        reader: { _ in throw ChatDataEncryptor.EncryptionError.keychainError(-25308) })
        XCTAssertThrowsError(try cm.queueNote(text: "x", toContact: c.id)) {
            XCTAssertEqual($0 as? ConnectionManager.QueueNoteError, .outboxUnavailable)
        }
        XCTAssertTrue(cm.noteOutbox.all.isEmpty)
    }

}

// MARK: - Final-fix wave (outbox lifecycle, ambiguity, account availability, security epoch)

@MainActor
final class ConnectionManagerFinalFixTests: XCTestCase {
    private var cm: ConnectionManager!
    private var keyDir: URL!
    private var outboxDir: URL!
    private let key = Data(repeating: 5, count: 32)

    override func setUp() async throws {
        try await super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmff-\(UUID().uuidString)")
        outboxDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmff-o-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmfftest")
        cm = ConnectionManager()
        cm.trustedContactStore.removeAll()
        cm.noteOutbox = NoteOutboxStore(directory: outboxDir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
    }
    override func tearDown() async throws {
        cm.trustedContactStore.removeAll()
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir); try? FileManager.default.removeItem(at: outboxDir)
        try await super.tearDown()
    }

    private func bound(key k: Data? = nil) -> TrustedContact {
        let c = TrustedContact(deviceId: "dev-\(UUID().uuidString)", displayName: "F", identityPublicKey: k ?? key, trustLevel: .unknown, accountId: "FRND2345")
        cm.trustedContactStore.add(c)
        return c
    }

    // Item 6

    func testBlockingFailsQueuedEntriesImmediatelyWithoutFlush() {
        let c = bound()
        let e = cm.noteOutbox.enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "x")
        cm.trustedContactStore.setBlocked(c.id, blocked: true)
        let got = cm.noteOutbox.all.first { $0.id == e.id }
        XCTAssertEqual(got?.state, .failed)
        XCTAssertEqual(NoteOutboxFailure(reason: got?.failReason), .blocked)
    }

    func testKeyChangeFailsQueuedEntriesImmediately() {
        let c = bound()
        let e = cm.noteOutbox.enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "x")
        cm.trustedContactStore.updatePublicKey(for: c.id, newKey: Data(repeating: 9, count: 32), trustLevel: .linked, reason: .userAcceptedNewKey)
        let got = cm.noteOutbox.all.first { $0.id == e.id }
        XCTAssertEqual(got?.state, .failed)
        XCTAssertEqual(NoteOutboxFailure(reason: got?.failReason), .recipientChanged)
    }

    func testUnrelatedContactChangeLeavesQueuedEntriesAlone() {
        let c = bound()
        let e = cm.noteOutbox.enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "x")
        cm.trustedContactStore.updateMailboxId(for: c.id, mailboxId: "m")
        XCTAssertEqual(cm.noteOutbox.all.first { $0.id == e.id }?.state, .queued)
    }

    func testForgetDeviceDeletesThatContactsOutboxEntriesOnly() {
        let c = bound()
        let other = bound(key: Data(repeating: 8, count: 32))
        cm.noteOutbox.enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "plaintext-to-purge")
        cm.noteOutbox.enqueue(contactID: other.id, accountId: "FRND2345", expectedIdentityKey: Data(repeating: 8, count: 32), text: "keep")
        cm.forgetDevice(id: c.deviceId!)
        XCTAssertNil(cm.trustedContactStore.find(byId: c.id))
        XCTAssertEqual(cm.noteOutbox.all.map(\.text), ["keep"])
    }

    // Item 8

    func testQueueNoteRefusesAmbiguousKey() {
        let c = bound()
        let dup = TrustedContact(deviceId: "dev-dup", displayName: "G", identityPublicKey: key, trustLevel: .unknown, accountId: "OTHR2345")
        cm.trustedContactStore.add(dup)
        XCTAssertThrowsError(try cm.queueNote(text: "x", toContact: c.id)) { XCTAssertEqual($0 as? ConnectionManager.QueueNoteError, .notBound) }
        XCTAssertTrue(cm.noteOutbox.all.isEmpty)
        XCTAssertEqual(ConnectionManager.outboxBinding(for: c, among: [c, dup]), .none)
        XCTAssertEqual(ConnectionManager.outboxBinding(for: c, among: [c]), .verified(accountId: "FRND2345", identityKey: key))
    }

    // Item 5

    func testQueueNoteRefusedWhenAccountPermanentlyUnavailable() async throws {
        let c = bound()
        struct NoAuthDeps: AccountRegistrationDependencies {
            var deviceId: String { "d" }
            var platform: String { "ios" }
            var registrationSupported: Bool { false }
            var attestSupported: Bool { false }
            func identityKeys() throws -> (identity: Data, signing: Data) { (Data(), Data()) }
            func sign(_ data: Data) throws -> Data { Data() }
            func currentMailbox() async throws -> (id: String, token: String) { ("", "") }
        }
        let store = AccountStore(storageKey: "ff-\(UUID().uuidString)", directory: keyDir.appendingPathComponent("acct"),
                                 encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        let manager = AccountManager(client: AccountClient(baseURL: URL(string: "https://worker.test")!), store: store,
                                     deps: NoAuthDeps(), tokenAdopter: { _, _ in }, tokenIsFresh: { true })
        await manager.registerIfNeeded()
        XCTAssertEqual(manager.state, .unavailable(.attestUnsupported))
        cm._setAccountManagerForTesting(manager)
        XCTAssertThrowsError(try cm.queueNote(text: "x", toContact: c.id)) { XCTAssertEqual($0 as? ConnectionManager.QueueNoteError, .accountUnavailable) }
        XCTAssertTrue(cm.noteOutbox.all.isEmpty)
    }

    func testQueueNoteStillQueuesWhileAccountIsUnavailableFailed() async throws {
        let c = bound()
        struct FlakyDeps: AccountRegistrationDependencies {
            var deviceId: String { "d" }
            var platform: String { "ios" }
            var registrationSupported: Bool { true }
            var attestSupported: Bool { true }
            func identityKeys() throws -> (identity: Data, signing: Data) { (Data(), Data()) }
            func sign(_ data: Data) throws -> Data { Data() }
            func currentMailbox() async throws -> (id: String, token: String) { throw CocoaError(.fileReadUnknown) }
        }
        let store = AccountStore(storageKey: "ff2-\(UUID().uuidString)", directory: keyDir.appendingPathComponent("acct2"),
                                 encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        let manager = AccountManager(client: AccountClient(baseURL: URL(string: "https://worker.test")!), store: store,
                                     deps: FlakyDeps(), tokenAdopter: { _, _ in }, tokenIsFresh: { true })
        await manager.registerIfNeeded()
        guard case .unavailable(.failed) = manager.state else { return XCTFail("expected .unavailable(.failed), got \(manager.state)") }
        cm._setAccountManagerForTesting(manager)
        let entry = try cm.queueNote(text: "x", toContact: c.id)
        XCTAssertEqual(cm.noteOutbox.all.first?.id, entry.id)
    }

    func testAccountPermanenceClassification() {
        XCTAssertTrue(ConnectionManager.noteAccountIsPermanentlyUnavailable(.unavailable(.attestUnsupported)))
        // `.failed` also covers transient errors (5xx/429/decode) that auto-retry: it is NOT permanent.
        XCTAssertFalse(ConnectionManager.noteAccountIsPermanentlyUnavailable(.unavailable(.failed("x"))))
        XCTAssertFalse(ConnectionManager.noteAccountIsPermanentlyUnavailable(.unavailable(.offline)))
        XCTAssertFalse(ConnectionManager.noteAccountIsPermanentlyUnavailable(.registering))
        XCTAssertFalse(ConnectionManager.noteAccountIsPermanentlyUnavailable(.idle))
    }

    // Item 7

    func testSecurityEpochIncrementsWhenSecureChannelEstablishedForKnownContact() throws {
        let k = Data(repeating: 3, count: 32)
        let c = TrustedContact(deviceId: "dev-s", displayName: "S", identityPublicKey: k, trustLevel: .linked)
        cm.trustedContactStore.add(c)
        let identity = PeerIdentity(id: "dev-s", displayName: "S", identityPublicKey: k)
        let pc = PeerConnection(peerID: "dev-s", connection: NWConnection(host: "127.0.0.1", port: 9, using: .peerDrop()),
                                peerIdentity: identity, localIdentity: cm.localIdentity, state: .connected)
        let before = cm.securityEpoch
        var published = 0
        let sub = cm.objectWillChange.sink { published += 1 }
        cm.handleSecureChannelEstablished(for: pc, fingerprint: "fp")
        XCTAssertEqual(pc.pinningVerdict, .matched)
        XCTAssertGreaterThan(cm.securityEpoch, before)
        XCTAssertGreaterThan(published, 0, "views observing the connection manager must be told")
        sub.cancel()
    }
}
