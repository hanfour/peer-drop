import XCTest
@testable import PeerDrop

final class PetSpeciesIntegrationTests: XCTestCase {

    func testAllSpeciesHaveValidProfiles() {
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            let profile = provider.profile
            XCTAssertGreaterThan(profile.baseSpeed, 0, "\(body) baseSpeed")
            XCTAssertFalse(profile.uniqueActions.isEmpty, "\(body) should have unique actions")
            XCTAssertGreaterThanOrEqual(profile.idleDurationRange.lowerBound, 0)
            XCTAssertGreaterThan(profile.moveDurationRange.upperBound, 0)
        }
    }

    func testAllSpeciesProduceExitEnterSequences() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            let exit = provider.exitSequence(from: CGPoint(x: 200, y: 700), screenBounds: bounds)
            let enter = provider.enterSequence(screenBounds: bounds)
            XCTAssertFalse(exit.steps.isEmpty, "\(body) exit")
            XCTAssertFalse(enter.steps.isEmpty, "\(body) enter")
        }
    }

    func testAllSpeciesChatBehaviorWithMessages() {
        let frames = [
            CGRect(x: 20, y: 100, width: 200, height: 40),
            CGRect(x: 20, y: 160, width: 200, height: 40),
        ]
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            // Should not crash
            _ = provider.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        }
    }

    func testFlyingSpeciesNeverFall() {
        let flyingBodies: [BodyGene] = [.bird, .dragon]
        let traits = PersonalityTraits(independence: 0.5, curiosity: 0.5, energy: 0.5, timidity: 0.5, mischief: 0.5)
        let airborne = PetPhysicsState(position: CGPoint(x: 200, y: 300), velocity: .zero, surface: .airborne)

        for body in flyingBodies {
            let provider = PetBehaviorProviderFactory.create(for: body)
            for _ in 0..<100 {
                let action = provider.nextBehavior(current: .idle, physics: airborne, level: .baby,
                                                    elapsed: 0, foodTarget: nil, traits: traits)
                XCTAssertNotEqual(action, .fall, "\(body) should never fall")
            }
        }
    }

    func testFloatingSpeciesNeverFall() {
        let traits = PersonalityTraits(independence: 0.5, curiosity: 0.5, energy: 0.5, timidity: 0.5, mischief: 0.5)
        let airborne = PetPhysicsState(position: CGPoint(x: 200, y: 300), velocity: .zero, surface: .airborne)
        let ghost = PetBehaviorProviderFactory.create(for: .ghost)
        for _ in 0..<100 {
            let action = ghost.nextBehavior(current: .idle, physics: airborne, level: .baby,
                                             elapsed: 0, foodTarget: nil, traits: traits)
            XCTAssertNotEqual(action, .fall, "Ghost should never fall")
        }
    }

    func testPhysicsProfileIntegration() {
        // Test that physics engine respects profile gravity
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)

        let birdProfile = PetBehaviorProviderFactory.create(for: .bird).profile
        PetPhysicsEngine.update(&state, dt: 1.0/60.0, surfaces: surfaces, profile: birdProfile)
        XCTAssertEqual(state.velocity.dy, 0, accuracy: 0.01, "Bird with 0 gravity should not accelerate")

        var state2 = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let catProfile = PetBehaviorProviderFactory.create(for: .cat).profile
        PetPhysicsEngine.update(&state2, dt: 1.0/60.0, surfaces: surfaces, profile: catProfile)
        XCTAssertGreaterThan(state2.velocity.dy, 0, "Cat with 800 gravity should accelerate down")
    }

}
