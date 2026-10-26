import CryptoKit
import Foundation
import PeerDropSecurity
import XCTest
@testable import PeerDropGroups

final class GroupEventLogTests: XCTestCase {
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

    private func event(_ seq: Int, eventId: String? = nil, authorMemberId: String = "MEMBER1") -> WireEvent {
        WireEvent(
            seq: seq,
            eventId: eventId ?? "EVENT\(seq)",
            type: "msg",
            authorMemberId: authorMemberId,
            epoch: 1,
            payloadCipher: "opaque-ciphertext",
            createdAt: 1_700_000_000_000 + seq
        )
    }

    private func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }

    private func encryptedFrame(_ event: WireEvent) throws -> Data {
        frame(try encryptor.encrypt(JSONEncoder().encode(event)))
    }

    func testAppendReloadsEncryptedEventsAndTracksLastSeq() throws {
        let log = GroupEventLog(url: logURL, encryptor: encryptor)
        let first = event(1, eventId: "EVENT_ID_SECRET_1")
        let second = event(2, eventId: "EVENT_ID_SECRET_2")

        try log.append(first)
        try log.append(second)

        let bytes = try Data(contentsOf: logURL)
        XCTAssertNil(bytes.range(of: Data(first.eventId.utf8)))
        XCTAssertNil(bytes.range(of: Data(second.eventId.utf8)))

        let reloaded = GroupEventLog(url: logURL, encryptor: encryptor)
        XCTAssertEqual(reloaded.load().events, [first, second])
        XCTAssertEqual(reloaded.lastSeq, 2)
    }

    func testGroupsAreIsolatedByLogURL() throws {
        let firstLog = GroupEventLog(url: tempDir.appendingPathComponent("group-a/events.log"), encryptor: encryptor)
        let secondLog = GroupEventLog(url: tempDir.appendingPathComponent("group-b/events.log"), encryptor: encryptor)
        let first = event(1, eventId: "SHARED_EVENT_ID", authorMemberId: "MEMBER_A")
        let second = event(1, eventId: "SHARED_EVENT_ID", authorMemberId: "MEMBER_B")

        try firstLog.append(first)
        try secondLog.append(second)

        XCTAssertEqual(firstLog.load().events, [first])
        XCTAssertEqual(secondLog.load().events, [second])
    }

    func testDuplicateEventIdIsIdempotent() throws {
        let log = GroupEventLog(url: logURL, encryptor: encryptor)
        let original = event(1, eventId: "SAME_EVENT_ID", authorMemberId: "ORIGINAL")
        let duplicate = event(9, eventId: "SAME_EVENT_ID", authorMemberId: "DUPLICATE")
        try log.append(original)
        let originalSize = try Data(contentsOf: logURL).count

        try log.append(duplicate)

        XCTAssertEqual(log.load().events, [original])
        XCTAssertEqual(try Data(contentsOf: logURL).count, originalSize)
    }

    func testLoadSortsOutOfOrderFramesBySeq() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bytes = try encryptedFrame(event(3)) + encryptedFrame(event(1)) + encryptedFrame(event(2))
        try bytes.write(to: logURL)

        let log = GroupEventLog(url: logURL, encryptor: encryptor)
        XCTAssertEqual(log.load().events.map(\.seq), [1, 2, 3])
    }

    func testCorruptMiddleFrameIsSkippedAndOtherEventsLoad() throws {
        var corrupt = [UInt8](try encryptedFrame(event(2)))
        corrupt[corrupt.count - 1] ^= 0x01
        let bytes = try encryptedFrame(event(1)) + Data(corrupt) + encryptedFrame(event(3))
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try bytes.write(to: logURL)

        let result = GroupEventLog(url: logURL, encryptor: encryptor).load()

        XCTAssertEqual(result.events.map(\.seq), [1, 3])
        XCTAssertEqual(result.droppedTailBytes, 0)
    }

    func testTruncatedTailIsRemovedAndDoesNotLeaveTemporaryFiles() throws {
        let log = GroupEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))
        try log.append(event(2))
        let completeFileSize = try Data(contentsOf: logURL).count

        var danglingLength = UInt32(1_000).bigEndian
        let dangling = Data(bytes: &danglingLength, count: 4) + Data([0xAB, 0xCD])
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: dangling)
        try handle.close()

        let result = log.load()

        XCTAssertEqual(result.events.map(\.seq), [1, 2])
        XCTAssertEqual(result.droppedTailBytes, dangling.count)
        XCTAssertEqual(try Data(contentsOf: logURL).count, completeFileSize)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["events.log"])
    }

    func testPartialLengthPrefixIsDroppedAndAppendAfterRepairKeepsAllEvents() throws {
        let log = GroupEventLog(url: logURL, encryptor: encryptor)
        try log.append(event(1))
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00, 0x00]))
        try handle.close()

        try log.append(event(2))

        let result = log.load()
        XCTAssertEqual(result.events.map(\.seq), [1, 2])
        XCTAssertEqual(result.droppedTailBytes, 0)
    }

    func testAppendDoesNotReplaceAnUnreadableExistingPath() throws {
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        let sentinelURL = logURL.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinelURL)

        let log = GroupEventLog(url: logURL, encryptor: encryptor)
        XCTAssertThrowsError(try log.append(event(1))) {
            XCTAssertEqual($0 as? GroupEventLog.EventLogError, .unreadableFile)
        }
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("preserve".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["events.log"])
    }
}
