import XCTest
@testable import PeerDropCore

final class ChatMessageRunsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // 2026-01-01 12:00:00 UTC
    private let base = Date(timeIntervalSince1970: 1_767_268_800)

    private func msg(_ id: String, at offset: TimeInterval, from: Date? = nil,
                     senderID: String? = "a", isOutgoing: Bool = false,
                     isDeleted: Bool = false) -> ChatMessage {
        ChatMessage(
            id: id, text: "hi", isMedia: false, mediaType: nil, fileName: nil,
            fileSize: nil, mimeType: nil, duration: nil, thumbnailData: nil,
            localFileURL: nil, isOutgoing: isOutgoing, peerName: "P", status: .sent,
            timestamp: (from ?? base).addingTimeInterval(offset),
            senderID: senderID, isDeleted: isDeleted)
    }

    private func runs(_ m: [ChatMessage]) -> Set<String> {
        ChatMessageRuns.firstInRunIDs(in: m, calendar: cal)
    }

    func testEmptyReturnsEmpty() {
        XCTAssertTrue(runs([]).isEmpty)
        XCTAssertTrue(ChatMessageRuns.dayStartIDs(in: [], calendar: cal).isEmpty)
    }

    func testFirstMessageIsAlwaysRunStart() {
        let m = [msg("1", at: 0)]
        XCTAssertEqual(runs(m), ["1"])
        XCTAssertEqual(ChatMessageRuns.dayStartIDs(in: m, calendar: cal), ["1"])
    }

    func testSameSenderWithinGapIsOneRun() {
        let m = [msg("1", at: 0), msg("2", at: 60), msg("3", at: 120)]
        XCTAssertEqual(runs(m), ["1"])
    }

    func testSenderChangeStartsNewRun() {
        let m = [msg("1", at: 0, senderID: "a"), msg("2", at: 10, senderID: "b")]
        XCTAssertEqual(runs(m), ["1", "2"])
    }

    func testExactly300SecondsStaysInRun() {
        XCTAssertEqual(runs([msg("1", at: 0), msg("2", at: 300)]), ["1"])
    }

    func test301SecondsStartsNewRun() {
        XCTAssertEqual(runs([msg("1", at: 0), msg("2", at: 301)]), ["1", "2"])
    }

    func testCrossingMidnightStartsNewRunAndNewDay() {
        let late = cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2026, month: 1, day: 1, hour: 23, minute: 59))!
        let m = [msg("1", at: 0, from: late), msg("2", at: 120, from: late)]
        XCTAssertEqual(runs(m), ["1", "2"])
        XCTAssertEqual(ChatMessageRuns.dayStartIDs(in: m, calendar: cal), ["1", "2"])
    }

    func testGroupSendersDistinguishedBySenderID() {
        let m = [msg("1", at: 0, senderID: "x"), msg("2", at: 5, senderID: "y")]
        XCTAssertEqual(runs(m), ["1", "2"])
    }

    func testLegacyMessagesWithoutSenderIDFallBackToIsOutgoing() {
        let diff = [msg("1", at: 0, senderID: nil, isOutgoing: true),
                    msg("2", at: 5, senderID: nil, isOutgoing: false)]
        XCTAssertEqual(runs(diff), ["1", "2"])
        let same = [msg("1", at: 0, senderID: nil, isOutgoing: true),
                    msg("2", at: 5, senderID: nil, isOutgoing: true)]
        XCTAssertEqual(runs(same), ["1"])
    }

    func testDeletedMessagesStillParticipate() {
        let m = [msg("1", at: 0), msg("2", at: 30, isDeleted: true), msg("3", at: 60)]
        XCTAssertEqual(runs(m), ["1"])
    }
}
