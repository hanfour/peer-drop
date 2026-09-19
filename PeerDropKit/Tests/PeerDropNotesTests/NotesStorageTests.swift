import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropNotes

final class NotesStorageTests: XCTestCase {
    private var dir: URL!
    private var storage: NotesStorage!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-storage-\(UUID().uuidString)", isDirectory: true)
        storage = NotesStorage(directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func record(_ id: String, _ direction: NoteDirection = .inbound) -> NoteRecord {
        NoteRecord(id: id, direction: direction, text: "t-\(id)", sentAt: Date(timeIntervalSince1970: 1_700_000_000), sender: .verified(accountId: "SENDR001", nickname: "alice"),
                   recipientAccountId: direction == .outbound ? "TESTRCPT" : nil, readAt: nil, receivedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testRoundTripAndRemove() throws {
        try storage.save(record("01A")); try storage.save(record("01B")); try storage.save(record("01S", .outbound))
        XCTAssertEqual(storage.loadInbox().map(\.id).sorted(), ["01A", "01B"])
        XCTAssertEqual(storage.loadSent().map(\.id), ["01S"])
        XCTAssertEqual(storage.loadInbox().first { $0.id == "01A" }, record("01A"))
        try storage.remove(id: "01A", direction: .inbound)
        XCTAssertEqual(storage.loadInbox().map(\.id), ["01B"])
        XCTAssertNoThrow(try storage.remove(id: "01A", direction: .inbound))   // idempotent
        let raw = try Data(contentsOf: dir.appendingPathComponent("inbox/01B.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("t-01B"))   // encrypted at rest
    }
    func testPoisonFileIsSkippedAndReported() throws {
        try storage.save(record("01A"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        let poisonURL = dir.appendingPathComponent("inbox/01Z.enc")
        try Data("garbage".utf8).write(to: poisonURL)
        XCTAssertEqual(storage.loadInbox().map(\.id), ["01A"])
        XCTAssertNotNil(storage.lastLoadError)
        try FileManager.default.removeItem(at: poisonURL)
        XCTAssertEqual(storage.loadInbox().map(\.id), ["01A"])
        XCTAssertNil(storage.lastLoadError)   // cleared by the later clean load, not latched
    }
    func testLastSeenInboxIdPersists() {
        XCTAssertNil(storage.lastSeenInboxId)
        storage.lastSeenInboxId = "01B"
        let reopened = NotesStorage(directory: dir, encryptor: storage.encryptor)
        XCTAssertEqual(reopened.lastSeenInboxId, "01B")
    }
    func testRoundTripPreservesSenderBlock() throws {
        let block = NoteSenderBlock(accountId: "SENDR001", nickname: "alice", signingKey: Data(repeating: 1, count: 32), signature: Data(repeating: 2, count: 64))
        var rec = record("01SB")
        rec.sender = .unverified(accountId: "SENDR001")
        rec.senderBlock = block
        try storage.save(rec)
        XCTAssertEqual(storage.loadInbox().first { $0.id == "01SB" }, rec)
        XCTAssertEqual(storage.loadInbox().first { $0.id == "01SB" }?.senderBlock, block)
    }
    func testSenderStateCodableRoundTrip() throws {
        for state in [NoteSenderState.anonymous, .verified(accountId: "A1", nickname: nil), .unverified(accountId: "A2")] {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(NoteSenderState.self, from: data), state)
        }
    }
    func testSenderStateUnknownTagThrows() {
        let data = Data(#"{"state":"bogus"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NoteSenderState.self, from: data))
    }
}
