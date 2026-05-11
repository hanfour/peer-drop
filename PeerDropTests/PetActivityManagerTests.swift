import XCTest
@testable import PeerDrop

@available(iOS 16.2, *)
@MainActor
final class PetActivityManagerTests: XCTestCase {
    func testContentStateFromSnapshot() {
        let snapshot = PetSnapshot(
            name: "Pixel", bodyType: .cat, eyeType: .dot, patternType: .none,
            level: .baby, mood: .happy, paletteIndex: 0, evolutionProgress: 0.2)
        let state = PetActivityManager.contentState(from: snapshot)
        XCTAssertEqual(state.pose, .happy)
        XCTAssertEqual(state.mood, .happy)
        XCTAssertEqual(state.level, .baby)
        XCTAssertEqual(state.expProgress, 0.2, accuracy: 0.01)
    }

    func testContentStateExpProgressClamped() {
        // Out-of-range source value should clamp to [0, 1] in contentState.
        let snapshot = PetSnapshot(
            name: nil, bodyType: .slime, eyeType: .dot, patternType: .none,
            level: .baby, mood: .curious, paletteIndex: 0, evolutionProgress: 1.5)
        let state = PetActivityManager.contentState(from: snapshot)
        XCTAssertEqual(state.expProgress, 1.0, accuracy: 0.01)
    }

    func testContentStateExpProgressClampsNegative() {
        let snapshot = PetSnapshot(
            name: nil, bodyType: .slime, eyeType: .dot, patternType: .none,
            level: .baby, mood: .curious, paletteIndex: 0, evolutionProgress: -0.3)
        let state = PetActivityManager.contentState(from: snapshot)
        XCTAssertEqual(state.expProgress, 0.0, accuracy: 0.01)
    }
}
