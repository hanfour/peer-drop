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
        s.recordAttempt(id: e.id, nextAttemptAt: Date(timeIntervalSince1970: 2000))
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

    func testCorruptFileYieldsEmptyStoreAndRecovers() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("outbox.enc"))
        let s = NoteOutboxStore(directory: dir, encryptor: enc)
        XCTAssertTrue(s.all.isEmpty)
        XCTAssertNotNil(s.lastError)
        s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "x")
        XCTAssertEqual(NoteOutboxStore(directory: dir, encryptor: enc).all.count, 1)
    }

    func testMarkFailedRemoveRetryAndFailedCount() {
        let s = NoteOutboxStore(directory: dir, encryptor: enc)
        let a = s.enqueue(contactID: contact, accountId: "ABCD2345", expectedIdentityKey: Data(), text: "a", now: Date(timeIntervalSince1970: 0))
        let b = s.enqueue(contactID: UUID(), accountId: "ABCD2345", expectedIdentityKey: Data(), text: "b")
        s.recordAttempt(id: a.id, nextAttemptAt: nil)
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
