import XCTest
@testable import PeerDrop

@MainActor
final class InteractionTrackerTests: XCTestCase {
    var tracker: InteractionTracker!

    override func setUp() {
        super.setUp()
        tracker = InteractionTracker()
    }

    override func tearDown() {
        tracker = nil
        super.tearDown()
    }

    func testRecordInteraction() {
        tracker.record(.tap)
        XCTAssertEqual(tracker.allHistory.count, 1)
        XCTAssertEqual(tracker.allHistory.first?.type, .tap)
    }

    func testRecentHistoryFilters24Hours() {
        // Add a current record
        tracker.record(.tap)

        // Add a 25-hour-old record via testing helper
        let oldDate = Date().addingTimeInterval(-25 * 3600)
        tracker.insertForTesting(InteractionTracker.Record(type: .shake, date: oldDate))

        XCTAssertEqual(tracker.allHistory.count, 2)
        XCTAssertEqual(tracker.recentHistory.count, 1)
        XCTAssertEqual(tracker.recentHistory.first?.type, .tap)
    }

    func testLastHourHistoryFilters() {
        // Add a current record
        tracker.record(.tap)

        // Add a 2-hour-old record
        let oldDate = Date().addingTimeInterval(-2 * 3600)
        tracker.insertForTesting(InteractionTracker.Record(type: .shake, date: oldDate))

        XCTAssertEqual(tracker.lastHourHistory.count, 1)
        XCTAssertEqual(tracker.lastHourHistory.first?.type, .tap)
    }

    func testCalculateMoodHappy() {
        // 6 interactions in the last hour should yield .happy
        for _ in 0..<6 {
            tracker.record(.tap)
        }
        let mood = tracker.calculateMood(hasSocialRecently: false)
        XCTAssertEqual(mood, .happy)
    }

    func testCalculateMoodLonelyWithNoActivity() {
        // No interactions and no social → .lonely
        let mood = tracker.calculateMood(hasSocialRecently: false)
        XCTAssertEqual(mood, .lonely)
    }

    func testCalculateMoodSleepyWithSocial() {
        // No interactions but has social → .sleepy
        let mood = tracker.calculateMood(hasSocialRecently: true)
        XCTAssertEqual(mood, .sleepy)
    }

    func testCalculateMoodExcitedWithPeer() {
        // A peerConnected in last hour → .excited
        tracker.record(.peerConnected)
        let mood = tracker.calculateMood(hasSocialRecently: false)
        XCTAssertEqual(mood, .excited)
    }

    func testCalculateMoodCuriousWithActivity() {
        // Some activity (< 5) without peer → .curious
        tracker.record(.tap)
        let mood = tracker.calculateMood(hasSocialRecently: false)
        XCTAssertEqual(mood, .curious)
    }

    func testCalculateMoodDefaultSleepyWithSocial() {
        // No interactions but hasSocialRecently — falls through to .sleepy
        let mood = tracker.calculateMood(hasSocialRecently: true)
        XCTAssertEqual(mood, .sleepy)
    }

    func testExperienceValues() {
        XCTAssertEqual(InteractionType.tap.experienceValue, 2)
        XCTAssertEqual(InteractionType.shake.experienceValue, 3)
        XCTAssertEqual(InteractionType.peerConnected.experienceValue, 5)
        XCTAssertEqual(InteractionType.petMeeting.experienceValue, 10)
        XCTAssertEqual(InteractionType.charge.experienceValue, 1)
        XCTAssertEqual(InteractionType.steps.experienceValue, 1)
        XCTAssertEqual(InteractionType.chatActive.experienceValue, 2)
        XCTAssertEqual(InteractionType.fileTransfer.experienceValue, 3)
        XCTAssertEqual(InteractionType.evolution.experienceValue, 0)
    }

    func testTrimOldHistory() {
        // Insert a record older than 7 days
        let oldDate = Date().addingTimeInterval(-8 * 86400)
        tracker.insertForTesting(InteractionTracker.Record(type: .tap, date: oldDate))
        XCTAssertEqual(tracker.allHistory.count, 1)

        // Recording a new interaction triggers trimming
        tracker.record(.shake)
        XCTAssertEqual(tracker.allHistory.count, 1)
        XCTAssertEqual(tracker.allHistory.first?.type, .shake)
    }
}
