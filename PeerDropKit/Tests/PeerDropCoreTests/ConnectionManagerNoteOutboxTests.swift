import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropNotes
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
        XCTAssertEqual(cm.noteOutbox.all.count, 1)   // blocking itself clears nothing
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

    func testForgetDeviceFailsQueuedEntries() {
        let c = bound()
        cm.noteOutbox.enqueue(contactID: c.id, accountId: "FRND2345", expectedIdentityKey: key, text: "x")
        cm.forgetDevice(id: c.deviceId!)
        XCTAssertNil(cm.trustedContactStore.find(byId: c.id))
        XCTAssertEqual(cm.noteOutbox.all.first?.state, .failed)
        XCTAssertEqual(cm.noteOutbox.all.first?.failReason, "綁定已取消")
    }
}
