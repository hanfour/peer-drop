import XCTest
@testable import PeerDrop

final class PetSpeciesBehaviorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTraits(energy: Double = 0.5, mischief: Double = 0.5) -> PersonalityTraits {
        PersonalityTraits(independence: 0.5, curiosity: 0.5,
                          energy: energy, timidity: 0.5, mischief: mischief)
    }

    private func makePhysics(surface: PetSurface = .ground,
                             position: CGPoint = .zero) -> PetPhysicsState {
        PetPhysicsState(position: position, velocity: .zero, surface: surface)
    }

    // MARK: - Cat: wall -> climb or walking; idle long enough -> species action sometimes

    func testCatWallBehaviorReturnsClimbOrWalking() {
        let cat = CatBehavior()
        let traits = makeTraits(mischief: 1.0) // maximize climb chance
        var results = Set<PetAction>()

        for _ in 0..<100 {
            let physics = makePhysics(surface: .leftWall)
            let result = cat.nextBehavior(current: .idle, physics: physics,
                                          level: .baby, elapsed: 0.0,
                                          foodTarget: nil, traits: traits)
            results.insert(result)
        }
        // Should see climb and/or walking
        let expected: Set<PetAction> = [.climb, .walking]
        XCTAssertFalse(results.intersection(expected).isEmpty,
                       "Cat on wall should climb or walk, got: \(results)")
    }

    func testCatIdleLongEnoughTriggersSpeciesAction() {
        let cat = CatBehavior()
        let traits = makeTraits(energy: 0.9) // lower idle threshold
        var sawSpeciesAction = false
        let speciesActions: Set<PetAction> = [.scratch, .stretch, .groom, .nap]

        for _ in 0..<200 {
            let physics = makePhysics(surface: .ground)
            let result = cat.nextBehavior(current: .idle, physics: physics,
                                          level: .baby, elapsed: 10.0,
                                          foodTarget: nil, traits: traits)
            if speciesActions.contains(result) {
                sawSpeciesAction = true
                break
            }
        }
        XCTAssertTrue(sawSpeciesAction, "Cat should sometimes perform species action after long idle")
    }

    // MARK: - Dog: canClimbWalls false; idle -> species action sometimes

    func testDogCannotClimbWalls() {
        let dog = DogBehavior()
        XCTAssertFalse(dog.profile.canClimbWalls)
    }

    func testDogIdleTriggersSpeciesAction() {
        let dog = DogBehavior()
        let traits = makeTraits(energy: 0.9)
        var sawSpeciesAction = false
        let speciesActions: Set<PetAction> = [.dig, .fetchToy, .wagTail, .scratchWall]

        for _ in 0..<200 {
            let physics = makePhysics(surface: .ground)
            let result = dog.nextBehavior(current: .idle, physics: physics,
                                          level: .baby, elapsed: 10.0,
                                          foodTarget: nil, traits: traits)
            if speciesActions.contains(result) {
                sawSpeciesAction = true
                break
            }
        }
        XCTAssertTrue(sawSpeciesAction, "Dog should sometimes perform species action after long idle")
    }

    // MARK: - Bird: airborne -> NOT fall

    func testBirdAirborneDoesNotFall() {
        let bird = BirdBehavior()
        let traits = makeTraits()
        let physics = makePhysics(surface: .airborne)

        for _ in 0..<100 {
            let result = bird.nextBehavior(current: .idle, physics: physics,
                                           level: .baby, elapsed: 0.0,
                                           foodTarget: nil, traits: traits)
            XCTAssertNotEqual(result, .fall, "Bird should NEVER fall when airborne")
        }
    }

    func testBirdAirborneFromFallConvertsToGlideOrHover() {
        let bird = BirdBehavior()
        let traits = makeTraits()
        let physics = makePhysics(surface: .airborne)

        let result = bird.nextBehavior(current: .fall, physics: physics,
                                       level: .baby, elapsed: 0.0,
                                       foodTarget: nil, traits: traits)
        XCTAssertTrue(result == .glide || result == .hover,
                      "Bird should convert fall to glide/hover, got: \(result)")
    }

    // MARK: - Ghost: airborne -> NOT fall; canPassThroughWalls true

    func testGhostAirborneDoesNotFall() {
        let ghost = GhostBehavior()
        let traits = makeTraits()
        let physics = makePhysics(surface: .airborne)

        for _ in 0..<100 {
            let result = ghost.nextBehavior(current: .idle, physics: physics,
                                            level: .baby, elapsed: 0.0,
                                            foodTarget: nil, traits: traits)
            XCTAssertNotEqual(result, .fall, "Ghost should NEVER fall when airborne")
        }
    }

    func testGhostCanPassThroughWalls() {
        let ghost = GhostBehavior()
        XCTAssertTrue(ghost.profile.canPassThroughWalls)
    }

    func testGhostConvertsFallToIdle() {
        let ghost = GhostBehavior()
        let traits = makeTraits()
        let physics = makePhysics(surface: .airborne)

        let result = ghost.nextBehavior(current: .fall, physics: physics,
                                        level: .baby, elapsed: 0.0,
                                        foodTarget: nil, traits: traits)
        XCTAssertNotEqual(result, .fall, "Ghost should convert fall to idle")
    }

    // MARK: - Frog: bouncing mode; canClimbWalls

    func testFrogBouncingMode() {
        let frog = FrogBehavior()
        XCTAssertEqual(frog.profile.physicsMode, .bouncing)
    }

    func testFrogCanClimbWalls() {
        let frog = FrogBehavior()
        XCTAssertTrue(frog.profile.canClimbWalls)
    }

    func testFrogWallReturnsStickyWall() {
        let frog = FrogBehavior()
        let traits = makeTraits()
        let physics = makePhysics(surface: .leftWall)

        let result = frog.nextBehavior(current: .idle, physics: physics,
                                       level: .baby, elapsed: 0.0,
                                       foodTarget: nil, traits: traits)
        XCTAssertEqual(result, .stickyWall)
    }

    // MARK: - Dragon: flying mode; 0 gravity

    func testDragonFlyingMode() {
        let dragon = DragonBehavior()
        XCTAssertEqual(dragon.profile.physicsMode, .flying)
    }

    func testDragonZeroGravity() {
        let dragon = DragonBehavior()
        XCTAssertEqual(dragon.profile.gravity, 0)
    }

    func testDragonAirborneDoesNotFall() {
        let dragon = DragonBehavior()
        let traits = makeTraits()
        let physics = makePhysics(surface: .airborne)

        for _ in 0..<100 {
            let result = dragon.nextBehavior(current: .idle, physics: physics,
                                             level: .baby, elapsed: 0.0,
                                             foodTarget: nil, traits: traits)
            XCTAssertNotEqual(result, .fall, "Dragon should NEVER fall when airborne")
        }
    }

    // MARK: - Slime: bouncing mode; gravity 600

    func testSlimeBouncingMode() {
        let slime = SlimeBehavior()
        XCTAssertEqual(slime.profile.physicsMode, .bouncing)
    }

    func testSlimeGravity600() {
        let slime = SlimeBehavior()
        XCTAssertEqual(slime.profile.gravity, 600)
    }

    // MARK: - Exit Sequence Tests

    func testCatExitHasScaleDelta() {
        let cat = CatBehavior()
        let seq = cat.exitSequence(from: CGPoint(x: 200, y: 700),
                                   screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        let hasScale = seq.steps.contains { $0.scaleDelta != nil }
        XCTAssertTrue(hasScale, "Cat exit should have scaleDelta (perspective walk)")
    }

    func testDogExitStartsWithDig() {
        let dog = DogBehavior()
        let seq = dog.exitSequence(from: CGPoint(x: 200, y: 700),
                                   screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        XCTAssertEqual(seq.steps.first?.action, .dig, "Dog exit should start with .dig")
    }

    func testGhostExitStartsWithFlicker() {
        let ghost = GhostBehavior()
        let seq = ghost.exitSequence(from: CGPoint(x: 200, y: 400),
                                     screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        XCTAssertEqual(seq.steps.first?.action, .flicker, "Ghost exit should start with .flicker")
    }

    // MARK: - Enter Sequence Tests

    func testAllEnterSequencesNotEmpty() {
        let screenBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let allBehaviors: [PetBehaviorProvider] = [
            CatBehavior(), DogBehavior(), RabbitBehavior(), BirdBehavior(),
            FrogBehavior(), BearBehavior(), DragonBehavior(), OctopusBehavior(),
            GhostBehavior(), SlimeBehavior(),
        ]

        for behavior in allBehaviors {
            let seq = behavior.enterSequence(screenBounds: screenBounds)
            XCTAssertFalse(seq.steps.isEmpty,
                           "\(type(of: behavior)) enter sequence should not be empty")
        }
    }

    // MARK: - Chat Behavior Tests

    func testCatChatReturnsOnTop() {
        let cat = CatBehavior()
        let frames = [CGRect(x: 0, y: 100, width: 200, height: 40)]
        let result = cat.chatBehavior(messageFrames: frames, petPosition: .zero)
        XCTAssertNotNil(result)
        if case .onTop = result?.position {
            // expected
        } else {
            XCTFail("Cat chat should use .onTop position, got: \(String(describing: result?.position))")
        }
    }

    func testSlimeChatReturnsDripping() {
        let slime = SlimeBehavior()
        let frames = [CGRect(x: 0, y: 100, width: 200, height: 40)]
        let result = slime.chatBehavior(messageFrames: frames, petPosition: .zero)
        XCTAssertNotNil(result)
        if case .dripping = result?.position {
            // expected
        } else {
            XCTFail("Slime chat should use .dripping position, got: \(String(describing: result?.position))")
        }
    }

    func testGhostChatReturnsBehind() {
        let ghost = GhostBehavior()
        let frames = [CGRect(x: 0, y: 100, width: 200, height: 40)]
        let result = ghost.chatBehavior(messageFrames: frames, petPosition: .zero)
        XCTAssertNotNil(result)
        if case .behind = result?.position {
            // expected
        } else {
            XCTFail("Ghost chat should use .behind position, got: \(String(describing: result?.position))")
        }
    }
}
