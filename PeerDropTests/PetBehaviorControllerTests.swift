import XCTest
@testable import PeerDrop

final class PetBehaviorControllerTests: XCTestCase {

    func testIdleTransitionsToWalk() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        var gotWalk = false
        for _ in 0..<100 {
            let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .baby, elapsed: 6)
            if action == .walking { gotWalk = true; break }
        }
        XCTAssertTrue(gotWalk, "Should eventually transition to walk")
    }

    func testEggNeverWanders() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        for _ in 0..<100 {
            let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .egg, elapsed: 100)
            XCTAssertEqual(action, .idle, "Egg should never wander")
        }
    }

    func testAirborneReturnsFall() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 300), velocity: .zero, surface: .airborne)
        let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .baby, elapsed: 0)
        XCTAssertEqual(action, .fall)
    }

    func testGroundIdleBelow5SecondsStaysIdle() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .baby, elapsed: 2)
        XCTAssertEqual(action, .idle)
    }
}
