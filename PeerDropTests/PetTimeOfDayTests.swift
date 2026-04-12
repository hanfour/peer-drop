import XCTest
@testable import PeerDrop

final class PetTimeOfDayTests: XCTestCase {
    func testNightTimeMoodIsSleepy() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 0
        let nightTime = Calendar.current.date(from: comps)!
        let result = PetTimeOfDayBehavior.suggestedMood(at: nightTime, lastInteraction: nightTime.addingTimeInterval(-7200))
        XCTAssertEqual(result, .sleepy)
    }

    func testDayTimeMoodIsNil() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 14; comps.minute = 0
        let dayTime = Calendar.current.date(from: comps)!
        let result = PetTimeOfDayBehavior.suggestedMood(at: dayTime, lastInteraction: dayTime)
        XCTAssertNil(result)
    }

    func testNightTimeWithRecentInteractionIsNil() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 0
        let nightTime = Calendar.current.date(from: comps)!
        let result = PetTimeOfDayBehavior.suggestedMood(at: nightTime, lastInteraction: nightTime)
        XCTAssertNil(result)
    }
}
