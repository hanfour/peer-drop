import XCTest
@testable import PeerDrop

@available(iOS 16.2, *)
@MainActor
final class PetActivityManagerTests: XCTestCase {
    func testContentStateFromSnapshot() {
        let snapshot = PetSnapshot(
            name: "Pixel", bodyType: .cat, eyeType: .dot, patternType: .none,
            level: .baby, mood: .happy, paletteIndex: 0, experience: 100, maxExperience: 500)
        let state = PetActivityManager.contentState(from: snapshot)
        XCTAssertEqual(state.pose, .happy)
        XCTAssertEqual(state.mood, .happy)
        XCTAssertEqual(state.level, .baby)
        XCTAssertEqual(state.expProgress, 0.2, accuracy: 0.01)
    }

    func testContentStateExpProgressClamped() {
        let snapshot = PetSnapshot(
            name: nil, bodyType: .slime, eyeType: .dot, patternType: .none,
            level: .baby, mood: .curious, paletteIndex: 0, experience: 600, maxExperience: 500)
        let state = PetActivityManager.contentState(from: snapshot)
        XCTAssertEqual(state.expProgress, 1.0, accuracy: 0.01)
    }
}
