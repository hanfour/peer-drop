import XCTest
@testable import PeerDrop

final class PetBehaviorProviderTests: XCTestCase {

    // MARK: - Factory Tests

    func testFactoryReturnsProviderForAllBodyGenes() {
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            XCTAssertFalse(provider.profile.uniqueActions.isEmpty,
                           "\(body) should have unique actions")
        }
    }

    // MARK: - Cat Profile

    func testCatProfileValues() {
        let cat = PetBehaviorProviderFactory.create(for: .cat)
        let p = cat.profile
        XCTAssertEqual(p.physicsMode, .grounded)
        XCTAssertEqual(p.gravity, 800)
        XCTAssertTrue(p.canClimbWalls)
        XCTAssertTrue(p.canHangCeiling)
        XCTAssertFalse(p.canPassThroughWalls)
        XCTAssertEqual(p.baseSpeed, 70)
        XCTAssertEqual(p.movementStyle, .walk)
        XCTAssertEqual(p.uniqueActions, [.scratch, .stretch, .groom, .nap])
    }

    // MARK: - Bird Profile (flying, 0 gravity)

    func testBirdProfileValues() {
        let bird = PetBehaviorProviderFactory.create(for: .bird)
        let p = bird.profile
        XCTAssertEqual(p.physicsMode, .flying)
        XCTAssertEqual(p.gravity, 0)
        XCTAssertFalse(p.canClimbWalls)
        XCTAssertFalse(p.canHangCeiling)
        XCTAssertFalse(p.canPassThroughWalls)
        XCTAssertEqual(p.baseSpeed, 90)
        XCTAssertEqual(p.movementStyle, .fly)
        XCTAssertEqual(p.uniqueActions, [.perch, .peck, .preen, .dive, .glide])
    }

    // MARK: - Ghost Profile (floating, passThrough)

    func testGhostProfileValues() {
        let ghost = PetBehaviorProviderFactory.create(for: .ghost)
        let p = ghost.profile
        XCTAssertEqual(p.physicsMode, .floating)
        XCTAssertEqual(p.gravity, 0)
        XCTAssertFalse(p.canClimbWalls)
        XCTAssertFalse(p.canHangCeiling)
        XCTAssertTrue(p.canPassThroughWalls)
        XCTAssertEqual(p.baseSpeed, 55)
        XCTAssertEqual(p.movementStyle, .float)
        XCTAssertEqual(p.uniqueActions, [.phaseThrough, .flicker, .spook, .vanish])
    }

    // MARK: - Slime Profile (bouncing, 600 gravity)

    func testSlimeProfileValues() {
        let slime = PetBehaviorProviderFactory.create(for: .slime)
        let p = slime.profile
        XCTAssertEqual(p.physicsMode, .bouncing)
        XCTAssertEqual(p.gravity, 600)
        XCTAssertFalse(p.canClimbWalls)
        XCTAssertFalse(p.canHangCeiling)
        XCTAssertFalse(p.canPassThroughWalls)
        XCTAssertEqual(p.baseSpeed, 40)
        XCTAssertEqual(p.movementStyle, .bounce)
        XCTAssertEqual(p.uniqueActions, [.split, .melt, .absorb, .wallStick])
    }

    // MARK: - Octopus Profile (crawling, 400 gravity, climbWalls)

    func testOctopusProfileValues() {
        let octopus = PetBehaviorProviderFactory.create(for: .octopus)
        let p = octopus.profile
        XCTAssertEqual(p.physicsMode, .crawling)
        XCTAssertEqual(p.gravity, 400)
        XCTAssertTrue(p.canClimbWalls)
        XCTAssertTrue(p.canHangCeiling)
        XCTAssertFalse(p.canPassThroughWalls)
        XCTAssertEqual(p.baseSpeed, 50)
        XCTAssertEqual(p.movementStyle, .slither)
        XCTAssertEqual(p.uniqueActions, [.inkSquirt, .tentacleReach, .camouflage, .wallSuction])
    }

    // MARK: - Default nextBehavior

    func testDefaultNextBehaviorReturnsFallForAirborneGroundedPet() {
        let provider = PetBehaviorProviderFactory.create(for: .cat)
        let physics = PetPhysicsState(position: .zero, velocity: .zero, surface: .airborne)
        let traits = PersonalityTraits(independence: 0.5, curiosity: 0.5,
                                       energy: 0.5, timidity: 0.5, mischief: 0.5)

        let result = provider.nextBehavior(current: .idle, physics: physics,
                                           level: .baby, elapsed: 0.0,
                                           foodTarget: nil, traits: traits)
        XCTAssertEqual(result, .fall)
    }
}
