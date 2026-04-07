import XCTest
@testable import PeerDrop

final class PetBehaviorControllerTests: XCTestCase {

    func testIdleTransitionsToWalk() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        // Run many times — at least one should suggest walk after 5+ seconds
        var sawWalk = false
        for _ in 0..<100 {
            let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .baby, elapsed: 6)
            if action == .walking { sawWalk = true; break }
        }
        XCTAssertTrue(sawWalk, "Should sometimes transition to walk after idle timeout")
    }

    func testEggNeverWanders() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        for _ in 0..<100 {
            let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .egg, elapsed: 100)
            XCTAssertEqual(action, .idle, "Egg should never wander")
        }
    }

    func testWalkToEdgeStartsClimb() {
        let state = PetPhysicsState(position: CGPoint(x: 0, y: 780), velocity: .zero, surface: .leftWall)
        var sawClimb = false
        for _ in 0..<100 {
            let action = PetBehaviorController.nextBehavior(current: .walking, physics: state, level: .baby, elapsed: 0)
            if action == .climb { sawClimb = true; break }
        }
        XCTAssertTrue(sawClimb, "Should sometimes start climbing at wall")
    }

    func testHangTransitionsToFallOrSit() {
        let state = PetPhysicsState(position: CGPoint(x: 0, y: 50), velocity: .zero, surface: .ceiling)
        var outcomes = Set<PetAction>()
        for _ in 0..<200 {
            let action = PetBehaviorController.nextBehavior(current: .hang, physics: state, level: .baby, elapsed: 3)
            outcomes.insert(action)
        }
        XCTAssertTrue(outcomes.contains(.fall) || outcomes.contains(.sitEdge) || outcomes.contains(.hang))
    }
}
