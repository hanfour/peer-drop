import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropNotes

@MainActor
final class NoteOutboxStoreTests: XCTestCase {
    private var dir: URL!
    private var enc: ChatDataEncryptor!
    private let contact = UUID()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        enc = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testPersistenceRoundTrip() throws {
        let s = NoteOutboxStore(directory: dir, encryptor: enc)
        let e = s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data([1, 2, 3]), text: "hi", now: Date(timeIntervalSince1970: 1000))
        s.beginAttempt(id: e.id, nextAttemptAt: Date(timeIntervalSince1970: 2000)); s.endSending(id: e.id)
        let s2 = NoteOutboxStore(directory: dir, encryptor: enc)
        XCTAssertEqual(s2.all.count, 1)
        XCTAssertEqual(s2.all[0].text, "hi")
        XCTAssertEqual(s2.all[0].attempts, 1)
        XCTAssertEqual(s2.all[0].expectedIdentityKey, Data([1, 2, 3]))
        XCTAssertEqual(s2.all[0].nextAttemptAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(s2.entries(forContact: contact).count, 1)
        XCTAssertTrue(s2.entries(forContact: UUID()).isEmpty)
    }

    func testFileIsEncrypted() throws {
        let s = NoteOutboxStore(directory: dir, encryptor: enc)
        s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "plaintext-secret")
        let raw = try Data(contentsOf: dir.appendingPathComponent("outbox.enc"))
        XCTAssertNil(raw.range(of: Data("plaintext-secret".utf8)))
    }

    private func corruptFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("outbox.enc.corrupt-") }
    }

    func testCorruptFileIsQuarantinedWithBytesPreserved() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = Data("garbage".utf8)
        try bad.write(to: dir.appendingPathComponent("outbox.enc"))
        let s = NoteOutboxStore(directory: dir, encryptor: enc)
        XCTAssertTrue(s.all.isEmpty)
        XCTAssertNotNil(s.loadError); XCTAssertEqual(s.quarantinedCount, 1); XCTAssertFalse(s.isLoadFailed)
        XCTAssertEqual(corruptFiles().count, 1)
        XCTAssertEqual(try Data(contentsOf: corruptFiles()[0]), bad)
        s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "x")
        XCTAssertEqual(NoteOutboxStore(directory: dir, encryptor: enc).all.count, 1)
        XCTAssertEqual(try Data(contentsOf: corruptFiles()[0]), bad)   // never overwritten
    }

    func testSecondCorruptionDoesNotOverwriteFirstQuarantine() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for g in ["one", "two"] {
            try Data(g.utf8).write(to: dir.appendingPathComponent("outbox.enc"))
            _ = NoteOutboxStore(directory: dir, encryptor: enc)
        }
        XCTAssertEqual(corruptFiles().count, 2)
    }

    func testTransientFailureThenSuccessRestoresEntriesAndBlocksSaves() throws {
        let seed = NoteOutboxStore(directory: dir, encryptor: enc)
        let kept = seed.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "keep", now: Date())
        let original = try Data(contentsOf: dir.appendingPathComponent("outbox.enc"))
        var fail = true
        let reader: (URL) throws -> Data = { [enc] url in
            if fail { throw ChatDataEncryptor.EncryptionError.keychainError(-25308) }
            return try enc!.readAndDecrypt(from: url)
        }
        let s = NoteOutboxStore(directory: dir, encryptor: enc, reader: reader)
        XCTAssertTrue(s.isLoadFailed); XCTAssertNotNil(s.loadError); XCTAssertTrue(corruptFiles().isEmpty)
        // a new note while load failed is kept in memory but the file is NOT rewritten
        let fresh = s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "new", now: Date())
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("outbox.enc")), original)
        fail = false
        s.reloadIfNeeded()
        XCTAssertFalse(s.isLoadFailed); XCTAssertNil(s.loadError)
        XCTAssertEqual(Set(s.all.map(\.id)), [kept.id, fresh.id])
        XCTAssertEqual(Set(NoteOutboxStore(directory: dir, encryptor: enc).all.map(\.id)), [kept.id, fresh.id])
    }

    func testFailQueuedEntriesForContactKeepsThem() {
        let s = NoteOutboxStore(directory: dir, encryptor: enc)
        let a = s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "a")
        let b = s.enqueue(contactID: UUID(), accountId: "ABCD2345", expectedIdentityKey: Data(), text: "b")
        s.failQueuedEntries(forContact: contact, reason: "綁定已取消")
        XCTAssertEqual(s.all.first { $0.id == a.id }?.state, .failed)
        XCTAssertEqual(s.all.first { $0.id == b.id }?.state, .queued)
    }

    func testMarkFailedRemoveRetryAndFailedCount() {
        let s = NoteOutboxStore(directory: dir, encryptor: enc)
        let a = s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "a", now: Date(timeIntervalSince1970: 0))
        let b = s.enqueue(contactID: UUID(), accountId: "ABCD2345", expectedIdentityKey: Data(), text: "b")
        s.beginAttempt(id: a.id, nextAttemptAt: nil)
        s.markFailed(id: a.id, reason: "r")
        XCTAssertEqual(s.failedCount(), 1)
        XCTAssertEqual(s.failedCount(forContact: contact), 1)
        XCTAssertEqual(s.failedCount(forContact: b.contactID), 0)
        XCTAssertEqual(s.all[0].failReason, "r")
        s.retry(id: a.id, now: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(s.all[0].state, .queued); XCTAssertEqual(s.all[0].attempts, 0)
        XCTAssertNil(s.all[0].failReason); XCTAssertEqual(s.all[0].createdAt, Date(timeIntervalSince1970: 500))
        s.retry(id: b.id)  // not failed: no-op
        XCTAssertEqual(s.all[1].state, .queued)
        s.remove(id: a.id)
        XCTAssertEqual(s.all.map(\.id), [b.id])
    }
}
