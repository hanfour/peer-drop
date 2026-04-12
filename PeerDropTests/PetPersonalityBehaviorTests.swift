import XCTest
@testable import PeerDrop

final class PetPersonalityBehaviorTests: XCTestCase {
    func testHighEnergyIdleShorter() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        let highEnergy = PersonalityTraits(independence: 0.5, curiosity: 0.5, energy: 0.9, timidity: 0.5, mischief: 0.5)
        var gotWalk = false
        for _ in 0..<100 {
            let action = PetBehaviorController.nextBehavior(
                current: .idle, physics: state, level: .baby, elapsed: 3, traits: highEnergy)
            if action == .walking { gotWalk = true; break }
        }
        XCTAssertTrue(gotWalk, "High energy should walk after shorter idle")
    }

    func testHighMischiefClimbsMore() {
        let state = PetPhysicsState(position: CGPoint(x: 0, y: 780), velocity: .zero, surface: .leftWall)
        let mischievous = PersonalityTraits(independence: 0.5, curiosity: 0.5, energy: 0.5, timidity: 0.5, mischief: 0.9)
        var climbCount = 0
        for _ in 0..<200 {
            let action = PetBehaviorController.nextBehavior(
                current: .walking, physics: state, level: .baby, elapsed: 0, traits: mischievous)
            if action == .climb { climbCount += 1 }
        }
        XCTAssertGreaterThan(climbCount, 120, "High mischief should climb >60%")
    }

    func testEggIgnoresPersonality() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        let hyper = PersonalityTraits(independence: 0, curiosity: 1, energy: 1, timidity: 0, mischief: 1)
        let action = PetBehaviorController.nextBehavior(
            current: .idle, physics: state, level: .egg, elapsed: 100, traits: hyper)
        XCTAssertEqual(action, .idle)
    }
}
