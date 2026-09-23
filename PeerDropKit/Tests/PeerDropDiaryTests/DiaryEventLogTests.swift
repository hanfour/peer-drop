import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropDiary

final class DiaryEventLogTests: XCTestCase {
    private var tempDir: URL!
    private var logURL: URL!
    private var encryptor: ChatDataEncryptor!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        logURL = tempDir.appendingPathComponent("events.log")
        encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func event(_ seq: Int, type: DiaryEventType = .entry) -> DiaryEvent {
        DiaryEvent(seq: seq, eventId: "E\(seq)", type: type, authorAccountId: "A1", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(seq)))
    }

    /// Builds a raw length-prefixed frame the same way `DiaryEventLog.append`
    /// would, so tests can hand-craft a log file byte-for-byte.
    private func frame(_ payload: Data) -> Data {
        var out = Data()
        var length = UInt32(payload.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(payload)
        return out
    }

    private func validEncryptedFrame(_ e: DiaryEvent) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        let json = try enc.encode(e)
        return frame(try encryptor.encrypt(json))
    }

    func testAppendThreeThenReloadFromANewInstance() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))
        try log.append(event(2, type: .comment))
        try log.append(event(3, type: .pass))

        // A brand-new instance pointed at the same file — simulates an app
        // restart, since DiaryEventLog itself caches nothing in memory.
        let reloaded = DiaryEventLog(url: logURL, encryptor: encryptor)
        let events = reloaded.load()
        XCTAssertEqual(events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(events.map(\.type), [.entry, .comment, .pass])
        XCTAssertNil(reloaded.lastLoadError)
        XCTAssertEqual(reloaded.maxSeq, 3)
    }

    func testMissingFileLoadsEmptyWithNoError() {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        XCTAssertEqual(log.load(), [])
        XCTAssertNil(log.lastLoadError)
        XCTAssertEqual(log.maxSeq, 0)
    }

    /// A frame whose declared length is readable but whose bytes fail to
    /// decrypt (wrong key / corrupted ciphertext) is skipped — reading
    /// resumes at the next frame, so events written after it still load.
    func testPoisonFrameInTheMiddleIsSkippedWithoutLosingSurroundingEvents() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))

        // A poison frame: correctly length-prefixed, but its "ciphertext"
        // is garbage that will fail ChatDataEncryptor.decrypt (or, if it
        // happens to lack the magic header, decrypt to non-JSON bytes that
        // fail to decode as DiaryEvent either way).
        let poison = frame(Data(repeating: 0xAB, count: 40))
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: poison)
        try handle.close()

        try log.append(event(2))
        try log.append(event(3))

        let events = log.load()
        XCTAssertEqual(events.map(\.seq), [1, 2, 3])
        XCTAssertNotNil(log.lastLoadError)
        XCTAssertTrue(log.lastLoadError?.contains("poison") ?? false)
    }

    /// A decryptable-but-non-JSON frame is also poison (covers
    /// `ChatDataEncryptor.decrypt` returning its input unchanged when the
    /// magic header is absent — exactly why the log must decrypt and
    /// decode per-record rather than trusting the header alone).
    func testFrameThatDecryptsToNonJSONIsTreatedAsPoison() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))

        // No ChatDataEncryptor magic header → decrypt(_:) returns this
        // unchanged, and it isn't valid DiaryEvent JSON either.
        let plainGarbage = frame(Data("not encrypted, not json".utf8))
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: plainGarbage)
        try handle.close()

        try log.append(event(2))

        let events = log.load()
        XCTAssertEqual(events.map(\.seq), [1, 2])
        XCTAssertNotNil(log.lastLoadError)
    }

    /// A declared frame length that runs past the end of the file (a crash
    /// mid-append) stops the read right there instead of throwing — the
    /// events parsed before the truncated tail are not discarded.
    func testTruncatedTailStopsReadingButKeepsEarlierEvents() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))
        try log.append(event(2))

        // Half-written trailing frame: a length prefix claiming far more
        // bytes than actually follow.
        var danglingLength = UInt32(9_999).bigEndian
        let dangling = Data(bytes: &danglingLength, count: 4) + Data(repeating: 0xCD, count: 5)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: dangling)
        try handle.close()

        let events = log.load()
        XCTAssertEqual(events.map(\.seq), [1, 2])
        XCTAssertNotNil(log.lastLoadError)
        XCTAssertTrue(log.lastLoadError?.contains("truncated") ?? false)
    }

    func testTruncatedLengthPrefixItselfStopsReadingButKeepsEarlierEvents() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))

        // Fewer than 4 bytes trailing — can't even read a length prefix.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00, 0x01]))
        try handle.close()

        let events = log.load()
        XCTAssertEqual(events.map(\.seq), [1])
        XCTAssertNotNil(log.lastLoadError)
    }

    func testAppendCreatesIntermediateDirectories() throws {
        let nested = tempDir.appendingPathComponent("a/b/c/events.log")
        let log = DiaryEventLog(url: nested, encryptor: encryptor)
        try log.append(event(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(log.load().map(\.seq), [1])
    }

    func testLoadReturnsEventsSortedBySeqEvenIfFramesArentInOrder() throws {
        // Hand-craft a log with frames out of seq order to make sure
        // `load()` sorts rather than trusting on-disk order.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let h = try FileHandle(forWritingTo: logURL)
        try h.write(contentsOf: try validEncryptedFrame(event(3)))
        try h.write(contentsOf: try validEncryptedFrame(event(1)))
        try h.write(contentsOf: try validEncryptedFrame(event(2)))
        try h.close()

        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        XCTAssertEqual(log.load().map(\.seq), [1, 2, 3])
    }

    /// The payload/createdAt round trip through the log preserves a
    /// locally-decrypted `payload` (deliberately persisted in plaintext at
    /// the JSON layer since the whole record is encrypted at rest by
    /// `ChatDataEncryptor` — same pattern as `NoteRecord.text`).
    func testAppendPreservesDecryptedPayloadAndCreatedAt() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_123)
        let e = DiaryEvent(seq: 1, eventId: "E1", type: .entry, authorAccountId: "A1", payload: DiaryPayload(kind: .entry, text: "hello"), createdAt: createdAt)
        try log.append(e)

        let loaded = log.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].payload, DiaryPayload(kind: .entry, text: "hello"))
        XCTAssertEqual(loaded[0].createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 0.001)
    }
}
