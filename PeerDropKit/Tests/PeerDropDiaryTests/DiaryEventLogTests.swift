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

    private func event(_ seq: Int, type: DiaryEventType = .entry, payload: DiaryPayload? = nil) -> DiaryEvent {
        DiaryEvent(seq: seq, eventId: "E\(seq)", type: type, authorAccountId: "A1", payload: payload, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(seq)))
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
        XCTAssertEqual(try log.append(event(1)), 1)
        XCTAssertEqual(try log.append(event(2, type: .comment)), 2)
        XCTAssertEqual(try log.append(event(3, type: .pass)), 3)

        // A brand-new instance pointed at the same file — simulates an app
        // restart, since DiaryEventLog itself caches nothing in memory.
        let reloaded = DiaryEventLog(url: logURL, encryptor: encryptor)
        let result = reloaded.load()
        XCTAssertEqual(result.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(result.events.map(\.type), [.entry, .comment, .pass])
        XCTAssertEqual(result.skippedFrames, 0)
        XCTAssertEqual(result.truncatedBytes, 0)
        XCTAssertEqual(result.maxSeq, 3)
    }

    func testMissingFileLoadsEmptyWithNoError() {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        let result = log.load()
        XCTAssertEqual(result.events, [])
        XCTAssertEqual(result.skippedFrames, 0)
        XCTAssertEqual(result.truncatedBytes, 0)
        XCTAssertEqual(result.maxSeq, 0)
    }

    /// Spec §3.5 (amended 2026-09-23): "同 seq 以檔案後者為準" — two frames
    /// for the same `seq` (a local resend/overwrite) fold into ONE record,
    /// the later frame in the file winning.
    func testDuplicateSeqFoldsToTheLaterFrame() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(5, payload: DiaryPayload(kind: .entry, text: "first")))
        try log.append(event(5, payload: DiaryPayload(kind: .entry, text: "second")))

        let result = log.load()
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].seq, 5)
        XCTAssertEqual(result.events[0].payload, DiaryPayload(kind: .entry, text: "second"))
        XCTAssertEqual(result.maxSeq, 5)
    }

    func testDuplicateSeqAmongOtherEventsStillDedupesAndSorts() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))
        try log.append(event(2, payload: DiaryPayload(kind: .entry, text: "old")))
        try log.append(event(3))
        try log.append(event(2, payload: DiaryPayload(kind: .entry, text: "new")))

        let result = log.load()
        XCTAssertEqual(result.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(result.events[1].payload, DiaryPayload(kind: .entry, text: "new"))
    }

    /// A frame whose declared length is readable but whose bytes fail to
    /// decrypt (wrong key / corrupted ciphertext) is skipped — reading
    /// resumes at the next frame, so events written after it still load.
    /// This is a CONTENT-level failure, not a length/tail problem, so it
    /// must not trigger truncation.
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
        let sizeBeforeLoad = try Data(contentsOf: logURL).count

        let result = log.load()
        XCTAssertEqual(result.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(result.skippedFrames, 1)
        XCTAssertEqual(result.truncatedBytes, 0)
        // A content-level poison frame is NOT a tail problem — the file is
        // untouched (still contains the poison frame's bytes).
        XCTAssertEqual(try Data(contentsOf: logURL).count, sizeBeforeLoad)
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

        let result = log.load()
        XCTAssertEqual(result.events.map(\.seq), [1, 2])
        XCTAssertEqual(result.skippedFrames, 1)
        XCTAssertEqual(result.truncatedBytes, 0)
    }

    /// Spec §3.5 (amended 2026-09-23): a declared frame length that runs
    /// past the end of the file (a crash mid-`append`) TRUNCATES the file
    /// to the last complete frame boundary — the events parsed before the
    /// bad tail are kept, and a subsequent `append` works normally
    /// (previously this only stopped reading and left the dangling bytes
    /// in place, which would have jammed every future `load()`/`append`).
    func testInvalidTailIsTruncatedAndSubsequentAppendWorks() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))
        try log.append(event(2))
        let goodBytesSize = try Data(contentsOf: logURL).count

        // A dangling partial frame: a length prefix claiming far more
        // bytes than actually follow (simulates a crash mid-append).
        var danglingLength = UInt32(9_999).bigEndian
        let dangling = Data(bytes: &danglingLength, count: 4) + Data(repeating: 0xCD, count: 5)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: dangling)
        try handle.close()
        XCTAssertGreaterThan(try Data(contentsOf: logURL).count, goodBytesSize)

        let result = log.load()
        XCTAssertEqual(result.events.map(\.seq), [1, 2])
        XCTAssertEqual(result.truncatedBytes, dangling.count)

        // The file itself is now exactly the two good frames — truncated,
        // not just "stopped short of".
        XCTAssertEqual(try Data(contentsOf: logURL).count, goodBytesSize)

        // A later append must work normally against the truncated file.
        try log.append(event(3))
        let reloaded = log.load()
        XCTAssertEqual(reloaded.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(reloaded.truncatedBytes, 0)
    }

    func testTruncatedLengthPrefixItselfIsTruncatedAndKeepsEarlierEvents() throws {
        let log = DiaryEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))
        let goodBytesSize = try Data(contentsOf: logURL).count

        // Fewer than 4 bytes trailing — can't even read a length prefix.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00, 0x01]))
        try handle.close()

        let result = log.load()
        XCTAssertEqual(result.events.map(\.seq), [1])
        XCTAssertEqual(result.truncatedBytes, 2)
        XCTAssertEqual(try Data(contentsOf: logURL).count, goodBytesSize)
    }

    func testAppendCreatesIntermediateDirectories() throws {
        let nested = tempDir.appendingPathComponent("a/b/c/events.log")
        let log = DiaryEventLog(url: nested, encryptor: encryptor)
        try log.append(event(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(log.load().events.map(\.seq), [1])
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
        XCTAssertEqual(log.load().events.map(\.seq), [1, 2, 3])
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

        let loaded = log.load().events
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].payload, DiaryPayload(kind: .entry, text: "hello"))
        XCTAssertEqual(loaded[0].createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 0.001)
    }
}
