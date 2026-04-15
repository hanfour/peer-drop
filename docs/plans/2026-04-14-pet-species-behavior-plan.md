# Pet Species-Specific Behavior Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give each of 10 pet species unique physics rules, behavior state machines, exit/enter animations, and chat room interactions.

**Architecture:** Hybrid Data Profile + Behavior Override. A `PetBehaviorProfile` struct holds physics parameters (gravity, surfaces, speed). A `PetBehaviorProvider` protocol lets each species override complex behavior (state machine, exit/enter sequences, chat interaction). `PetEngine`, `PetPhysicsEngine`, `PetBehaviorController`, and `FloatingPetView` are refactored to delegate to the provider.

**Tech Stack:** Swift 5.9, SwiftUI, CADisplayLink (60 FPS physics), XcodeGen

**Test command:** `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
**Build command:** `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
**Regenerate project:** `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate`

---

### Task 1: Add New PetAction Cases

**Files:**
- Modify: `PeerDrop/Pet/Model/PetAction.swift`
- Test: `PeerDropTests/PetActionTests.swift` (create)

**Step 1: Write the failing test**

```swift
// PeerDropTests/PetActionTests.swift
import XCTest
@testable import PeerDrop

final class PetActionTests: XCTestCase {
    func testSpeciesActionsExist() {
        // Cat
        XCTAssertNotNil(PetAction(rawValue: "scratch"))
        XCTAssertNotNil(PetAction(rawValue: "stretch"))
        XCTAssertNotNil(PetAction(rawValue: "groom"))
        XCTAssertNotNil(PetAction(rawValue: "nap"))
        // Dog
        XCTAssertNotNil(PetAction(rawValue: "dig"))
        XCTAssertNotNil(PetAction(rawValue: "fetchToy"))
        XCTAssertNotNil(PetAction(rawValue: "scratchWall"))
        // Rabbit
        XCTAssertNotNil(PetAction(rawValue: "burrow"))
        XCTAssertNotNil(PetAction(rawValue: "nibble"))
        XCTAssertNotNil(PetAction(rawValue: "alertEars"))
        XCTAssertNotNil(PetAction(rawValue: "binky"))
        // Bird
        XCTAssertNotNil(PetAction(rawValue: "perch"))
        XCTAssertNotNil(PetAction(rawValue: "peck"))
        XCTAssertNotNil(PetAction(rawValue: "preen"))
        XCTAssertNotNil(PetAction(rawValue: "dive"))
        XCTAssertNotNil(PetAction(rawValue: "glide"))
        // Frog
        XCTAssertNotNil(PetAction(rawValue: "tongueSnap"))
        XCTAssertNotNil(PetAction(rawValue: "croak"))
        XCTAssertNotNil(PetAction(rawValue: "swim"))
        XCTAssertNotNil(PetAction(rawValue: "stickyWall"))
        // Bear
        XCTAssertNotNil(PetAction(rawValue: "backScratch"))
        XCTAssertNotNil(PetAction(rawValue: "standUp"))
        XCTAssertNotNil(PetAction(rawValue: "pawSlam"))
        XCTAssertNotNil(PetAction(rawValue: "bigYawn"))
        // Dragon
        XCTAssertNotNil(PetAction(rawValue: "breathFire"))
        XCTAssertNotNil(PetAction(rawValue: "hover"))
        XCTAssertNotNil(PetAction(rawValue: "wingSpread"))
        XCTAssertNotNil(PetAction(rawValue: "roar"))
        // Octopus
        XCTAssertNotNil(PetAction(rawValue: "inkSquirt"))
        XCTAssertNotNil(PetAction(rawValue: "tentacleReach"))
        XCTAssertNotNil(PetAction(rawValue: "camouflage"))
        XCTAssertNotNil(PetAction(rawValue: "wallSuction"))
        // Ghost
        XCTAssertNotNil(PetAction(rawValue: "phaseThrough"))
        XCTAssertNotNil(PetAction(rawValue: "flicker"))
        XCTAssertNotNil(PetAction(rawValue: "spook"))
        XCTAssertNotNil(PetAction(rawValue: "vanish"))
        // Slime
        XCTAssertNotNil(PetAction(rawValue: "split"))
        XCTAssertNotNil(PetAction(rawValue: "melt"))
        XCTAssertNotNil(PetAction(rawValue: "absorb"))
        XCTAssertNotNil(PetAction(rawValue: "wallStick"))
    }

    func testAllActionsAreDecodable() {
        for action in PetAction.allCases {
            let data = try! JSONEncoder().encode(action)
            let decoded = try! JSONDecoder().decode(PetAction.self, from: data)
            XCTAssertEqual(action, decoded)
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetActionTests`
Expected: FAIL — "scratch", "dig", etc. rawValues don't exist yet

**Step 3: Write minimal implementation**

Replace the contents of `PeerDrop/Pet/Model/PetAction.swift`:

```swift
import Foundation

enum PetAction: String, Codable, CaseIterable {
    // Movement
    case idle, walking, run, jump
    // Edge
    case climb, hang, fall, sitEdge
    // Life
    case sleeping, eat, yawn, poop, evolving
    // Emotion
    case happy, scared, angry, love
    // Interaction
    case tapReact, pickedUp, thrown, petted
    // Legacy (kept for migration)
    case wagTail, freeze, hideInShell, zoomies
    case notifyMessage, climbOnBubble, blockText, bounceBetweenBubbles
    case tiltHead, stuffCheeks, ignore

    // --- Species-Specific Actions ---
    // Cat
    case scratch, stretch, groom, nap
    // Dog
    case dig, fetchToy, scratchWall
    // Rabbit
    case burrow, nibble, alertEars, binky
    // Bird
    case perch, peck, preen, dive, glide
    // Frog
    case tongueSnap, croak, swim, stickyWall
    // Bear
    case backScratch, standUp, pawSlam, bigYawn
    // Dragon
    case breathFire, hover, wingSpread, roar
    // Octopus
    case inkSquirt, tentacleReach, camouflage, wallSuction
    // Ghost
    case phaseThrough, flicker, spook, vanish
    // Slime
    case split, melt, absorb, wallStick

    // Alias for compatibility — old code references .walk
    static var walk: PetAction { .walking }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetActionTests`
Expected: PASS

**Step 5: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: All 292+ tests PASS (existing tests should not break — new cases are additive)

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Model/PetAction.swift PeerDropTests/PetActionTests.swift
git commit -m "feat: add 41 species-specific PetAction cases"
```

---

### Task 2: Create PetBehaviorProvider Protocol & Profile Structs

**Files:**
- Create: `PeerDrop/Pet/Behavior/PetBehaviorProvider.swift`
- Create: `PeerDrop/Pet/Behavior/PetBehaviorProviderFactory.swift`
- Test: `PeerDropTests/PetBehaviorProviderTests.swift` (create)

**Step 1: Write the failing test**

```swift
// PeerDropTests/PetBehaviorProviderTests.swift
import XCTest
@testable import PeerDrop

final class PetBehaviorProviderTests: XCTestCase {
    func testFactoryReturnsProviderForAllBodies() {
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            XCTAssertFalse(provider.profile.baseSpeed <= 0, "\(body) should have positive baseSpeed")
        }
    }

    func testCatProfile() {
        let provider = PetBehaviorProviderFactory.create(for: .cat)
        XCTAssertEqual(provider.profile.physicsMode, .grounded)
        XCTAssertEqual(provider.profile.gravity, 800)
        XCTAssertTrue(provider.profile.canClimbWalls)
        XCTAssertTrue(provider.profile.canHangCeiling)
        XCTAssertFalse(provider.profile.canPassThroughWalls)
        XCTAssertEqual(provider.profile.movementStyle, .walk)
    }

    func testBirdProfile() {
        let provider = PetBehaviorProviderFactory.create(for: .bird)
        XCTAssertEqual(provider.profile.physicsMode, .flying)
        XCTAssertEqual(provider.profile.gravity, 0)
        XCTAssertEqual(provider.profile.movementStyle, .fly)
    }

    func testGhostProfile() {
        let provider = PetBehaviorProviderFactory.create(for: .ghost)
        XCTAssertEqual(provider.profile.physicsMode, .floating)
        XCTAssertTrue(provider.profile.canPassThroughWalls)
        XCTAssertEqual(provider.profile.gravity, 0)
    }

    func testSlimeProfile() {
        let provider = PetBehaviorProviderFactory.create(for: .slime)
        XCTAssertEqual(provider.profile.physicsMode, .bouncing)
        XCTAssertEqual(provider.profile.gravity, 600)
    }

    func testOctopusProfile() {
        let provider = PetBehaviorProviderFactory.create(for: .octopus)
        XCTAssertEqual(provider.profile.physicsMode, .crawling)
        XCTAssertTrue(provider.profile.canClimbWalls)
        XCTAssertEqual(provider.profile.gravity, 400)
    }

    func testDefaultNextBehaviorReturnsIdleForEgg() {
        let provider = PetBehaviorProviderFactory.create(for: .cat)
        let physics = PetPhysicsState(position: .zero, velocity: .zero, surface: .ground)
        let traits = PersonalityTraits(independence: 0.5, curiosity: 0.5, energy: 0.5, timidity: 0.5, mischief: 0.5)
        let action = provider.nextBehavior(current: .idle, physics: physics, level: .egg, elapsed: 100, foodTarget: nil, traits: traits)
        XCTAssertEqual(action, .idle)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetBehaviorProviderTests`
Expected: FAIL — types don't exist yet

**Step 3: Write minimal implementation**

Create directory: `mkdir -p "PeerDrop/Pet/Behavior"`

```swift
// PeerDrop/Pet/Behavior/PetBehaviorProvider.swift
import CoreGraphics
import Foundation

// MARK: - Physics Mode

enum PetPhysicsMode: String {
    case grounded   // gravity, ground/wall movement (cat, dog, rabbit, bear)
    case flying     // no gravity, free movement, can perch (bird, dragon)
    case floating   // no gravity, no collision, pass through walls (ghost)
    case bouncing   // gravity with bounce movement (frog, slime)
    case crawling   // reduced gravity, can attach to any surface (octopus)
}

// MARK: - Movement Style

enum MovementStyle: String {
    case walk       // cat, dog, bear
    case hop        // rabbit, frog
    case fly        // bird, dragon
    case slither    // octopus
    case float      // ghost
    case bounce     // slime
}

// MARK: - Exit/Enter Styles

enum PetExitStyle {
    case perspectiveWalk   // cat: walk away shrinking
    case digDown           // dog, rabbit: dig into ground
    case flyOff            // bird: fly off screen edge
    case hopOff            // frog: hop off screen
    case walkOff           // bear: walk off screen edge slowly
    case skyAscend         // dragon: fly up off screen
    case inkVanish         // octopus: ink cloud + fade
    case fadeOut           // ghost: flicker + fade
    case meltDown          // slime: melt into puddle
}

enum PetEnterStyle {
    case perspectiveReturn // cat: appear small, walk closer growing
    case digUp             // dog, rabbit: emerge from ground
    case flyIn             // bird: fly in from screen edge
    case hopIn             // frog: hop in from offscreen
    case walkIn            // bear: walk in from screen edge slowly
    case skyDescend        // dragon: dive down from sky
    case inkAppear         // octopus: ink cloud + fade in
    case fadeIn            // ghost: materialize
    case reformUp          // slime: puddle reforms
}

// MARK: - Chat Interaction

enum ChatPetPosition {
    case onTop(offset: CGFloat)
    case beside(leading: Bool)
    case stickedOn(leading: Bool)
    case wrappedAround
    case behind
    case above(height: CGFloat)
    case between(upperIndex: Int)
    case leaningOn(leading: Bool)
    case coiled
    case dripping
}

struct ChatPetAction {
    let targetMessageIndex: Int?
    let position: ChatPetPosition
    let action: PetAction
    let duration: TimeInterval
    let particles: [PetParticle]?
}

// MARK: - Animation Sequence

struct PetAnimationStep {
    let action: PetAction
    let duration: TimeInterval
    let positionDelta: CGPoint?
    let scaleDelta: CGFloat?
    let opacityDelta: CGFloat?
}

struct PetAnimationSequence {
    let steps: [PetAnimationStep]
}

// MARK: - Behavior Profile

struct PetBehaviorProfile {
    let physicsMode: PetPhysicsMode
    let gravity: CGFloat
    let canClimbWalls: Bool
    let canHangCeiling: Bool
    let canPassThroughWalls: Bool
    let baseSpeed: CGFloat
    let movementStyle: MovementStyle
    let idleDurationRange: ClosedRange<TimeInterval>
    let moveDurationRange: ClosedRange<TimeInterval>
    let uniqueActions: [PetAction]
    let exitStyle: PetExitStyle
    let enterStyle: PetEnterStyle
}

// MARK: - Provider Protocol

protocol PetBehaviorProvider {
    var profile: PetBehaviorProfile { get }

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence
    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence
    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction?
    func modifyPhysics(_ state: inout PetPhysicsState, deltaTime: CGFloat, surfaces: ScreenSurfaces)
}

// MARK: - Default Implementations

extension PetBehaviorProvider {
    func nextBehavior(current: PetAction, physics: PetPhysicsState, level: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        // Eggs never move
        guard level != .egg else { return .idle }

        // Chase food
        if let target = foodTarget, physics.surface == .ground {
            let dist = hypot(physics.position.x - target.x, physics.position.y - target.y)
            if dist > 8 { return .run }
        }

        // Airborne → fall (for grounded/bouncing types)
        if physics.surface == .airborne && profile.physicsMode != .flying && profile.physicsMode != .floating {
            return .fall
        }

        // Default idle→walk transition
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                return Bool.random() ? .walking : .idle
            }
        }

        // Walking duration
        if current == .walking && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        // Thrown/fall physics
        if current == .thrown || current == .fall { return current }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                           positionDelta: CGPoint(x: screenBounds.width, y: 0),
                           scaleDelta: nil, opacityDelta: 0.0)
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                           positionDelta: CGPoint(x: screenBounds.width / 2, y: screenBounds.height - 80),
                           scaleDelta: nil, opacityDelta: 1.0)
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        nil
    }

    func modifyPhysics(_ state: inout PetPhysicsState, deltaTime: CGFloat, surfaces: ScreenSurfaces) {
        // No modification by default
    }
}
```

```swift
// PeerDrop/Pet/Behavior/PetBehaviorProviderFactory.swift
import Foundation

enum PetBehaviorProviderFactory {
    static func create(for body: BodyGene) -> PetBehaviorProvider {
        switch body {
        case .cat:      return CatBehavior()
        case .dog:      return DogBehavior()
        case .rabbit:   return RabbitBehavior()
        case .bird:     return BirdBehavior()
        case .frog:     return FrogBehavior()
        case .bear:     return BearBehavior()
        case .dragon:   return DragonBehavior()
        case .octopus:  return OctopusBehavior()
        case .ghost:    return GhostBehavior()
        case .slime:    return SlimeBehavior()
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetBehaviorProviderTests`
Expected: PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Behavior/ PeerDropTests/PetBehaviorProviderTests.swift
git commit -m "feat: add PetBehaviorProvider protocol, profile structs, and factory"
```

---

### Task 3: Implement 10 Species Behavior Files

Each species behavior file implements `PetBehaviorProvider` with its unique profile and behavior overrides. Create all 10 files in `PeerDrop/Pet/Behavior/`. Each file is a struct conforming to `PetBehaviorProvider`.

**Files:**
- Create: `PeerDrop/Pet/Behavior/CatBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/DogBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/RabbitBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/BirdBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/FrogBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/BearBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/DragonBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/OctopusBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/GhostBehavior.swift`
- Create: `PeerDrop/Pet/Behavior/SlimeBehavior.swift`
- Test: `PeerDropTests/PetSpeciesBehaviorTests.swift` (create)

**Step 1: Write the failing test**

```swift
// PeerDropTests/PetSpeciesBehaviorTests.swift
import XCTest
@testable import PeerDrop

final class PetSpeciesBehaviorTests: XCTestCase {

    private let groundState = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
    private let airborneState = PetPhysicsState(position: CGPoint(x: 200, y: 300), velocity: .zero, surface: .airborne)
    private let wallState = PetPhysicsState(position: CGPoint(x: 20, y: 400), velocity: .zero, surface: .leftWall)
    private let defaultTraits = PersonalityTraits(independence: 0.5, curiosity: 0.5, energy: 0.5, timidity: 0.5, mischief: 0.5)

    // MARK: - Cat

    func testCatClimbsWall() {
        let cat = CatBehavior()
        let action = cat.nextBehavior(current: .walking, physics: wallState, level: .baby,
                                       elapsed: 0, foodTarget: nil, traits: defaultTraits)
        // Cat should try to climb or keep walking on wall
        XCTAssertTrue(action == .climb || action == .walking)
    }

    func testCatIdleToSpeciesAction() {
        let cat = CatBehavior()
        var gotSpecies = false
        for _ in 0..<200 {
            let action = cat.nextBehavior(current: .idle, physics: groundState, level: .baby,
                                           elapsed: 8, foodTarget: nil, traits: defaultTraits)
            if [.scratch, .stretch, .groom, .nap].contains(action) {
                gotSpecies = true; break
            }
        }
        XCTAssertTrue(gotSpecies, "Cat should sometimes do species-specific idle actions")
    }

    // MARK: - Dog

    func testDogCannotClimb() {
        let dog = DogBehavior()
        XCTAssertFalse(dog.profile.canClimbWalls)
    }

    func testDogIdleToSpeciesAction() {
        let dog = DogBehavior()
        var gotSpecies = false
        for _ in 0..<200 {
            let action = dog.nextBehavior(current: .idle, physics: groundState, level: .baby,
                                           elapsed: 8, foodTarget: nil, traits: defaultTraits)
            if [.dig, .fetchToy, .wagTail, .scratchWall].contains(action) {
                gotSpecies = true; break
            }
        }
        XCTAssertTrue(gotSpecies, "Dog should sometimes do species-specific idle actions")
    }

    // MARK: - Bird

    func testBirdFliesWhenAirborne() {
        let bird = BirdBehavior()
        let action = bird.nextBehavior(current: .idle, physics: airborneState, level: .baby,
                                        elapsed: 0, foodTarget: nil, traits: defaultTraits)
        // Bird should NOT fall — it flies
        XCTAssertNotEqual(action, .fall)
    }

    func testBirdIdleToFly() {
        let bird = BirdBehavior()
        var gotFly = false
        for _ in 0..<200 {
            let action = bird.nextBehavior(current: .idle, physics: groundState, level: .baby,
                                            elapsed: 8, foodTarget: nil, traits: defaultTraits)
            if [.glide, .dive, .preen, .peck, .perch].contains(action) || action == .walking {
                gotFly = true; break
            }
        }
        XCTAssertTrue(gotFly, "Bird should transition from idle")
    }

    // MARK: - Ghost

    func testGhostNoGravityNoFall() {
        let ghost = GhostBehavior()
        let action = ghost.nextBehavior(current: .idle, physics: airborneState, level: .baby,
                                         elapsed: 0, foodTarget: nil, traits: defaultTraits)
        XCTAssertNotEqual(action, .fall, "Ghost should not fall — it floats")
    }

    func testGhostCanPassThroughWalls() {
        let ghost = GhostBehavior()
        XCTAssertTrue(ghost.profile.canPassThroughWalls)
    }

    // MARK: - Frog

    func testFrogBouncingMode() {
        let frog = FrogBehavior()
        XCTAssertEqual(frog.profile.physicsMode, .bouncing)
        XCTAssertTrue(frog.profile.canClimbWalls)
    }

    // MARK: - Dragon

    func testDragonFlying() {
        let dragon = DragonBehavior()
        XCTAssertEqual(dragon.profile.physicsMode, .flying)
        XCTAssertEqual(dragon.profile.gravity, 0)
    }

    // MARK: - Slime

    func testSlimeBouncing() {
        let slime = SlimeBehavior()
        XCTAssertEqual(slime.profile.physicsMode, .bouncing)
        XCTAssertEqual(slime.profile.gravity, 600)
        XCTAssertEqual(slime.profile.movementStyle, .bounce)
    }

    // MARK: - Exit sequences

    func testCatExitIsPerspective() {
        let cat = CatBehavior()
        let seq = cat.exitSequence(from: CGPoint(x: 200, y: 700), screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        // Cat exit should include scale change
        XCTAssertNotNil(seq.steps.last?.scaleDelta)
    }

    func testDogExitIsDig() {
        let dog = DogBehavior()
        let seq = dog.exitSequence(from: CGPoint(x: 200, y: 700), screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        XCTAssertEqual(seq.steps.first?.action, .dig)
    }

    func testGhostExitIsFade() {
        let ghost = GhostBehavior()
        let seq = ghost.exitSequence(from: CGPoint(x: 200, y: 400), screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        XCTAssertEqual(seq.steps.first?.action, .flicker)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetSpeciesBehaviorTests`
Expected: FAIL — CatBehavior, DogBehavior, etc. don't exist yet

**Step 3: Write all 10 species behavior files**

Each file follows this pattern — profile with species data, `nextBehavior` override with species-specific idle actions and movement logic, `exitSequence`/`enterSequence` overrides. The profiles match the physics table from the design doc.

Key behavior patterns per species:
- **CatBehavior:** grounded + climb walls. Idle → scratch/stretch/groom/nap (20% each vs walk). Wall → climb (mischief-dependent). Exit: perspectiveWalk (scale 1→0.3).
- **DogBehavior:** grounded, no climb. Idle → dig/fetchToy/wagTail/scratchWall. Near wall → scratchWall. Exit: dig down.
- **RabbitBehavior:** grounded, hop movement. Idle → nibble/alertEars/binky. Move via hop. Exit: burrow.
- **BirdBehavior:** flying, no gravity. Override: airborne is normal — glide/dive/perch/peck/preen. Never fall. Exit: flyOff. `modifyPhysics`: sinusoidal vertical drift.
- **FrogBehavior:** bouncing + sticky walls. Idle → tongueSnap/croak. Move via hop+jump. Exit: hop off.
- **BearBehavior:** grounded, slow. Idle → backScratch/standUp/pawSlam/bigYawn. Exit: walkOff slowly.
- **DragonBehavior:** flying. Idle → hover/breathFire/wingSpread/roar. Exit: skyAscend.
- **OctopusBehavior:** crawling, low gravity, sticky surfaces. Idle → inkSquirt/tentacleReach/camouflage. Exit: inkVanish.
- **GhostBehavior:** floating, no collision. Override: never fall, phaseThrough/flicker/spook/vanish. `modifyPhysics`: drift through walls. Exit: fade.
- **SlimeBehavior:** bouncing, low gravity. Idle → split/melt/absorb/wallStick. `modifyPhysics`: extra bounce. Exit: meltDown.

Each file is ~80-120 lines. Implementation should follow the protocol with default fallbacks for unneeded methods.

**Step 4: Run test to verify it passes**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetSpeciesBehaviorTests`
Expected: PASS

**Step 5: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Behavior/*.swift PeerDropTests/PetSpeciesBehaviorTests.swift
git commit -m "feat: implement 10 species-specific behavior providers"
```

---

### Task 4: Refactor PetPhysicsEngine to Use Provider Profile

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetPhysicsEngine.swift` (75 lines)
- Modify: `PeerDropTests/PetPhysicsEngineTests.swift` (63 lines)

**Step 1: Write the failing test**

Add new tests to existing `PetPhysicsEngineTests.swift`:

```swift
// Add to PetPhysicsEngineTests.swift

func testNoGravityForFlyingMode() {
    var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
    let surfaces = ScreenSurfaces.test(ground: 800)
    let birdProfile = PetBehaviorProviderFactory.create(for: .bird).profile
    PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: birdProfile)
    // Bird has 0 gravity — should not accelerate downward
    XCTAssertEqual(state.velocity.dy, 0, accuracy: 0.01)
}

func testGhostPassesThroughWalls() {
    var state = PetPhysicsState(position: CGPoint(x: -10, y: 400), velocity: CGVector(dx: -50, dy: 0), surface: .airborne)
    let surfaces = ScreenSurfaces.test(leftWall: 0, rightWall: 400)
    let ghostProfile = PetBehaviorProviderFactory.create(for: .ghost).profile
    PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: ghostProfile)
    // Ghost should pass through — position should NOT be clamped to wall
    XCTAssertLessThan(state.position.x, 0)
}

func testReducedGravityForCrawling() {
    var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
    let surfaces = ScreenSurfaces.test(ground: 800)
    let octopusProfile = PetBehaviorProviderFactory.create(for: .octopus).profile
    PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: octopusProfile)
    // Octopus gravity is 400 (half of default 800)
    let expectedDy = 400.0 / 60.0
    XCTAssertEqual(state.velocity.dy, expectedDy, accuracy: 0.5)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetPhysicsEngineTests`
Expected: FAIL — `update` doesn't accept `profile` parameter yet

**Step 3: Write minimal implementation**

Modify `PetPhysicsEngine.swift`:
- Add `profile` parameter to `update()` with default value for backward compatibility
- Use `profile.gravity` instead of hardcoded `gravity`
- Add `profile.canPassThroughWalls` check in `resolveCollision`
- Keep the old static `gravity` constant for backward-compatible callers

```swift
// Key changes to PetPhysicsEngine:

static func update(_ state: inout PetPhysicsState, dt: CGFloat, surfaces: ScreenSurfaces,
                   profile: PetBehaviorProfile? = nil) {
    let effectiveGravity = profile?.gravity ?? gravity
    let passThrough = profile?.canPassThroughWalls ?? false

    guard state.surface == .airborne else { return }
    state.velocity.dy += effectiveGravity * dt
    state.velocity.dx *= throwDecay
    state.position.x += state.velocity.dx * dt
    state.position.y += state.velocity.dy * dt
    resolveCollision(&state, surfaces: surfaces, canPassThroughWalls: passThrough)
}

static func resolveCollision(_ state: inout PetPhysicsState, surfaces: ScreenSurfaces,
                              canPassThroughWalls: Bool = false) {
    // Ground collision — always applies (even ghosts land eventually)
    if !canPassThroughWalls {
        if state.position.y >= surfaces.ground {
            state.position.y = surfaces.ground
            if abs(state.velocity.dy) > 20 {
                state.velocity.dy = -state.velocity.dy * bounceRestitution
            } else {
                state.velocity = .zero
                state.surface = .ground
            }
        }
        if state.position.y <= surfaces.ceiling {
            state.position.y = surfaces.ceiling
            state.velocity.dy = 0
            state.surface = .ceiling
        }
        if state.position.x <= surfaces.leftWall {
            state.position.x = surfaces.leftWall
            state.velocity.dx = 0
            state.surface = .leftWall
        }
        if state.position.x >= surfaces.rightWall - petSize {
            state.position.x = surfaces.rightWall - petSize
            state.velocity.dx = 0
            state.surface = .rightWall
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetPhysicsEngineTests`
Expected: ALL PASS (old tests still pass via default nil profile, new tests pass with profile)

**Step 5: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Engine/PetPhysicsEngine.swift PeerDropTests/PetPhysicsEngineTests.swift
git commit -m "refactor: PetPhysicsEngine accepts BehaviorProfile for per-species physics"
```

---

### Task 5: Add Flying & Floating Physics Methods

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetPhysicsEngine.swift`
- Test: `PeerDropTests/PetPhysicsEngineTests.swift`

**Step 1: Write the failing test**

```swift
// Add to PetPhysicsEngineTests.swift

func testApplyFly() {
    var state = PetPhysicsState(position: CGPoint(x: 200, y: 300), velocity: .zero, surface: .airborne)
    let surfaces = ScreenSurfaces.test()
    PetPhysicsEngine.applyFly(&state, direction: CGVector(dx: 1, dy: -0.5), speed: 90, dt: 1.0 / 60.0, surfaces: surfaces)
    XCTAssertGreaterThan(state.position.x, 200)
    XCTAssertLessThan(state.position.y, 300)
}

func testApplyFloat() {
    var state = PetPhysicsState(position: CGPoint(x: 200, y: 300), velocity: .zero, surface: .airborne)
    PetPhysicsEngine.applyFloat(&state, direction: CGVector(dx: 0.7, dy: 0.3), speed: 55, dt: 1.0 / 60.0)
    XCTAssertGreaterThan(state.position.x, 200)
    XCTAssertGreaterThan(state.position.y, 300)
}

func testApplyHop() {
    var state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
    PetPhysicsEngine.applyHop(&state, direction: .right, speed: 75, jumpVelocity: -250)
    XCTAssertEqual(state.surface, .airborne)
    XCTAssertLessThan(state.velocity.dy, 0, "Should have upward velocity")
    XCTAssertGreaterThan(state.velocity.dx, 0, "Should have rightward velocity")
}

func testApplyBounce() {
    var state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
    PetPhysicsEngine.applyBounce(&state, jumpVelocity: -200)
    XCTAssertEqual(state.surface, .airborne)
    XCTAssertLessThan(state.velocity.dy, 0)
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `applyFly`, `applyFloat`, `applyHop`, `applyBounce` don't exist

**Step 3: Write minimal implementation**

Add to `PetPhysicsEngine`:

```swift
/// Flying movement — free directional movement, no gravity
static func applyFly(_ state: inout PetPhysicsState, direction: CGVector,
                     speed: CGFloat, dt: CGFloat, surfaces: ScreenSurfaces) {
    let len = hypot(direction.dx, direction.dy)
    guard len > 0 else { return }
    let nx = direction.dx / len
    let ny = direction.dy / len
    state.position.x += nx * speed * dt
    state.position.y += ny * speed * dt
    state.facingRight = nx >= 0
    // Soft boundary — stay within screen but allow edge
    state.position.x = max(surfaces.leftWall, min(state.position.x, surfaces.rightWall - petSize))
    state.position.y = max(surfaces.ceiling, min(state.position.y, surfaces.ground))
}

/// Floating movement — free directional, ignores all surfaces
static func applyFloat(_ state: inout PetPhysicsState, direction: CGVector,
                       speed: CGFloat, dt: CGFloat) {
    let len = hypot(direction.dx, direction.dy)
    guard len > 0 else { return }
    state.position.x += (direction.dx / len) * speed * dt
    state.position.y += (direction.dy / len) * speed * dt
    state.facingRight = direction.dx >= 0
}

/// Hop movement — horizontal jump from ground
static func applyHop(_ state: inout PetPhysicsState, direction: HorizontalDirection,
                     speed: CGFloat, jumpVelocity: CGFloat = -250) {
    state.velocity.dy = jumpVelocity
    state.velocity.dx = direction == .right ? speed : -speed
    state.surface = .airborne
    state.facingRight = direction == .right
}

/// Bounce — vertical bounce in place or with slight drift
static func applyBounce(_ state: inout PetPhysicsState, jumpVelocity: CGFloat = -200) {
    state.velocity.dy = jumpVelocity
    state.surface = .airborne
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet -only-testing:PeerDropTests/PetPhysicsEngineTests`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Engine/PetPhysicsEngine.swift PeerDropTests/PetPhysicsEngineTests.swift
git commit -m "feat: add applyFly, applyFloat, applyHop, applyBounce physics methods"
```

---

### Task 6: Wire PetEngine to Use BehaviorProvider

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift` (lines 6-40, 226-237)
- Test: `PeerDropTests/PetEngineTests.swift`

**Step 1: Write the failing test**

```swift
// Add to PeerDropTests/PetEngineTests.swift

func testEngineHasBehaviorProvider() async {
    let engine = await PetEngine()
    let provider = await engine.behaviorProvider
    XCTAssertNotNil(provider)
}

func testEngineProviderMatchesBody() async {
    var genome = PetGenome.random()
    genome.body = .bird
    let pet = PetState.newEgg(genome: genome)
    let engine = await PetEngine(pet: pet)
    let profile = await engine.behaviorProvider.profile
    XCTAssertEqual(profile.physicsMode, .flying)
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `behaviorProvider` property doesn't exist on PetEngine

**Step 3: Write minimal implementation**

Add to `PetEngine` class (around line 28):

```swift
// In PetEngine, add after existing properties:
private(set) var behaviorProvider: PetBehaviorProvider

// In init, add:
self.behaviorProvider = PetBehaviorProviderFactory.create(for: pet.genome.body)
```

Also update `triggerChatBehavior()` (lines 226-237) to delegate to `behaviorProvider.chatBehavior()` — but keep existing behavior as fallback.

**Step 4: Run test to verify it passes**

**Step 5: Run full test suite**

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift PeerDropTests/PetEngineTests.swift
git commit -m "feat: wire PetEngine to PetBehaviorProvider via factory"
```

---

### Task 7: Refactor FloatingPetView Physics & Behavior Loops

**Files:**
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift` (lines 150-230)

This is the integration task — connect the physics loop and behavior loop to use the provider.

**Step 1: Update physicsStep to use provider**

In `physicsStep(dt:)` (line 150), change:
- Pass `engine.behaviorProvider.profile` to `PetPhysicsEngine.update()`
- Use `profile.baseSpeed` instead of hardcoded 60/100/120
- Use `profile.movementStyle` to select the right physics method (applyWalk/applyFly/applyFloat/applyHop)
- Call `engine.behaviorProvider.modifyPhysics()` at end of physics step

**Step 2: Update startBehaviorLoop to use provider**

In `startBehaviorLoop()` (line 198), change:
- Replace `PetBehaviorController.nextBehavior(...)` call with `engine.behaviorProvider.nextBehavior(...)`
- Use `profile.movementStyle` for direction logic (flying pets pick random 2D direction, etc.)

**Step 3: Build and verify**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: BUILD SUCCEEDED

**Step 4: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: All tests PASS (existing behavior tests may need updates — PetBehaviorControllerTests still test the old static method which still exists)

**Step 5: Commit**

```bash
git add PeerDrop/Pet/UI/FloatingPetView.swift
git commit -m "refactor: FloatingPetView uses BehaviorProvider for physics and behavior"
```

---

### Task 8: Implement Exit/Enter Animation System in FloatingPetView

**Files:**
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift`
- Test: `PeerDropTests/PetExitEnterTests.swift` (create)

**Step 1: Write the failing test**

```swift
// PeerDropTests/PetExitEnterTests.swift
import XCTest
@testable import PeerDrop

final class PetExitEnterTests: XCTestCase {
    func testCatExitHasScaleStep() {
        let cat = CatBehavior()
        let seq = cat.exitSequence(from: CGPoint(x: 200, y: 700),
                                    screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertFalse(seq.steps.isEmpty)
        let hasScale = seq.steps.contains { $0.scaleDelta != nil }
        XCTAssertTrue(hasScale, "Cat exit should include scale change for perspective walk")
    }

    func testDogExitStartsWithDig() {
        let dog = DogBehavior()
        let seq = dog.exitSequence(from: CGPoint(x: 200, y: 700),
                                    screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(seq.steps.first?.action, .dig)
    }

    func testBirdExitIsGlide() {
        let bird = BirdBehavior()
        let seq = bird.exitSequence(from: CGPoint(x: 200, y: 300),
                                     screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(seq.steps.first?.action, .glide)
    }

    func testGhostExitIsFlicker() {
        let ghost = GhostBehavior()
        let seq = ghost.exitSequence(from: CGPoint(x: 200, y: 400),
                                      screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(seq.steps.first?.action, .flicker)
        let hasFade = seq.steps.contains { $0.opacityDelta != nil }
        XCTAssertTrue(hasFade)
    }

    func testSlimeExitIsMelt() {
        let slime = SlimeBehavior()
        let seq = slime.exitSequence(from: CGPoint(x: 200, y: 700),
                                      screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(seq.steps.first?.action, .melt)
    }

    func testEnterSequenceNotEmpty() {
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            let seq = provider.enterSequence(screenBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
            XCTAssertFalse(seq.steps.isEmpty, "\(body) enter sequence should not be empty")
        }
    }
}
```

**Step 2: Verify exit/enter overrides are implemented in species files (Task 3)**

These tests should already pass if Task 3 implemented the `exitSequence`/`enterSequence` overrides correctly.

**Step 3: Add exit/enter state machine to FloatingPetView**

Add to `FloatingPetView`:
- `@State private var isAbsent = false` — pet has exited
- `@State private var exitScale: CGFloat = 1.0`
- `@State private var exitOpacity: CGFloat = 1.0`
- `@State private var absentTimer: Timer?`
- Timer in behavior loop: if idle > 30-60s, trigger exit. After 15-45s absent, trigger enter.
- During exit: play `PetAnimationSequence` steps sequentially (animate position/scale/opacity)
- During absent: hide pet, show "○○ 出去散步了" label
- During enter: play enter sequence, then resume normal behavior

**Step 4: Build and verify**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`

**Step 5: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`

**Step 6: Commit**

```bash
git add PeerDrop/Pet/UI/FloatingPetView.swift PeerDropTests/PetExitEnterTests.swift
git commit -m "feat: implement exit/enter animation system with per-species sequences"
```

---

### Task 9: Implement Chat Room Pet Interaction

**Files:**
- Modify: `PeerDrop/UI/Chat/ChatView.swift` (lines 77-148)
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift`
- Test: `PeerDropTests/PetChatInteractionTests.swift` (create)

**Step 1: Write the failing test**

```swift
// PeerDropTests/PetChatInteractionTests.swift
import XCTest
@testable import PeerDrop

final class PetChatInteractionTests: XCTestCase {
    func testCatChatBehaviorTargetsMessage() {
        let cat = CatBehavior()
        let frames = [
            CGRect(x: 20, y: 100, width: 200, height: 40),
            CGRect(x: 20, y: 160, width: 200, height: 40),
        ]
        let result = cat.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if let chatAction = result {
            XCTAssertNotNil(chatAction.targetMessageIndex)
            // Cat should be on top of a message
            if case .onTop = chatAction.position { } else {
                XCTFail("Cat should use .onTop position in chat")
            }
        }
    }

    func testDogChatBehaviorIsBeside() {
        let dog = DogBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40)]
        let result = dog.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if let chatAction = result {
            if case .beside = chatAction.position { } else {
                XCTFail("Dog should use .beside position in chat")
            }
        }
    }

    func testGhostChatBehaviorIsBehind() {
        let ghost = GhostBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40)]
        let result = ghost.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if let chatAction = result {
            if case .behind = chatAction.position { } else {
                XCTFail("Ghost should use .behind position in chat")
            }
        }
    }

    func testEmptyFramesReturnsNil() {
        let cat = CatBehavior()
        let result = cat.chatBehavior(messageFrames: [], petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNil(result, "No messages = no chat interaction")
    }
}
```

**Step 2: Verify chatBehavior overrides (from Task 3)**

**Step 3: Integrate into ChatView**

In `ChatView.swift`, inside the `ScrollView` / `LazyVStack` (around line 79):
- Add `GeometryReader` preference key to collect visible message frames
- Pass collected frames to `FloatingPetView` (add `chatMode` + `messageFrames` parameters)

In `FloatingPetView`:
- Add `var chatMode = false` and `var messageFrames: [CGRect] = []`
- In behavior loop: if `chatMode`, call `provider.chatBehavior()` and position pet accordingly
- Pet renders on top of messages with `opacity(0.85)`, `allowsHitTesting(false)` for tap passthrough

**Step 4: Build and verify**

**Step 5: Run full test suite**

**Step 6: Commit**

```bash
git add PeerDrop/UI/Chat/ChatView.swift PeerDrop/Pet/UI/FloatingPetView.swift PeerDropTests/PetChatInteractionTests.swift
git commit -m "feat: implement per-species chat room pet interaction"
```

---

### Task 10: Update SpriteDataRegistry Fallback for New Actions

**Files:**
- Modify: `PeerDrop/Pet/Sprites/SpriteDataRegistry.swift` (lines 31-59)
- Test: `PeerDropTests/PetSpriteRegistryTests.swift` (create)

**Step 1: Write the failing test**

```swift
// PeerDropTests/PetSpriteRegistryTests.swift
import XCTest
@testable import PeerDrop

final class PetSpriteRegistryTests: XCTestCase {
    func testSpeciesActionsFallbackToIdle() {
        // New species actions don't have sprites yet — they should fallback to idle
        let catSprites = SpriteDataRegistry.sprites(for: .cat, stage: .baby)
        XCTAssertNotNil(catSprites)

        // .scratch doesn't have a sprite sheet yet — frameCount should fallback
        let scratchFrames = SpriteDataRegistry.frameCount(for: .cat, stage: .baby, action: .scratch)
        let idleFrames = SpriteDataRegistry.frameCount(for: .cat, stage: .baby, action: .idle)
        XCTAssertGreaterThan(scratchFrames, 0, "Should fallback to idle frame count")
        XCTAssertEqual(scratchFrames, idleFrames, "Unknown action should fallback to idle")
    }

    func testAllBodiesHaveFallbackForNewActions() {
        let newActions: [PetAction] = [.scratch, .dig, .glide, .hover, .flicker, .melt]
        for body in BodyGene.allCases {
            for action in newActions {
                let frames = SpriteDataRegistry.frameCount(for: body, stage: .baby, action: action)
                XCTAssertGreaterThan(frames, 0, "\(body).\(action) should have fallback frameCount > 0")
            }
        }
    }
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `frameCount` returns 0 for unknown actions

**Step 3: Write minimal implementation**

Modify `SpriteDataRegistry.frameCount()` (line 27-29) to fallback to `.idle` frame count when action not found:

```swift
static func frameCount(for body: BodyGene, stage: PetLevel, action: PetAction) -> Int {
    if let sprites = sprites(for: body, stage: stage),
       let frames = sprites[action] {
        return frames.count
    }
    // Fallback: use idle frames for unimplemented species actions
    if let sprites = sprites(for: body, stage: stage),
       let idleFrames = sprites[.idle] {
        return idleFrames.count
    }
    return 1
}
```

Also add a `resolvedAction` helper for the renderer to use:

```swift
static func resolvedAction(for body: BodyGene, stage: PetLevel, action: PetAction) -> PetAction {
    if let sprites = sprites(for: body, stage: stage),
       sprites[action] != nil {
        return action
    }
    return .idle  // fallback
}
```

**Step 4: Run test to verify it passes**

**Step 5: Run full test suite**

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Sprites/SpriteDataRegistry.swift PeerDropTests/PetSpriteRegistryTests.swift
git commit -m "feat: SpriteDataRegistry fallback to idle for unimplemented species actions"
```

---

### Task 11: Integration Test & Full Verification

**Files:**
- Test: `PeerDropTests/PetSpeciesIntegrationTests.swift` (create)

**Step 1: Write integration test**

```swift
// PeerDropTests/PetSpeciesIntegrationTests.swift
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
            // Should not crash — nil is acceptable (some might not have chat behavior in edge cases)
            _ = provider.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        }
    }

    func testEggAlwaysIdle() {
        let traits = PersonalityTraits(independence: 0.5, curiosity: 0.5, energy: 0.5, timidity: 0.5, mischief: 0.5)
        let physics = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        for body in BodyGene.allCases {
            let provider = PetBehaviorProviderFactory.create(for: body)
            for _ in 0..<50 {
                let action = provider.nextBehavior(current: .idle, physics: physics, level: .egg,
                                                    elapsed: 100, foodTarget: nil, traits: traits)
                XCTAssertEqual(action, .idle, "\(body) egg should always idle")
            }
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
}
```

**Step 2: Run test**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: ALL PASS

**Step 3: Commit**

```bash
git add PeerDropTests/PetSpeciesIntegrationTests.swift
git commit -m "test: add species behavior integration tests"
```

---

## Task Summary

| Task | Description | New Files | Modified Files | Tests |
|------|------------|-----------|---------------|-------|
| 1 | Add 41 PetAction cases | - | PetAction.swift | PetActionTests.swift |
| 2 | PetBehaviorProvider protocol + factory | PetBehaviorProvider.swift, Factory.swift | - | PetBehaviorProviderTests.swift |
| 3 | 10 species behavior implementations | Cat/Dog/Rabbit/Bird/Frog/Bear/Dragon/Octopus/Ghost/SlimeBehavior.swift | - | PetSpeciesBehaviorTests.swift |
| 4 | Refactor PetPhysicsEngine for profiles | - | PetPhysicsEngine.swift | PetPhysicsEngineTests.swift |
| 5 | Add flying/floating/hop/bounce physics | - | PetPhysicsEngine.swift | PetPhysicsEngineTests.swift |
| 6 | Wire PetEngine to provider | - | PetEngine.swift | PetEngineTests.swift |
| 7 | Refactor FloatingPetView loops | - | FloatingPetView.swift | (build verify) |
| 8 | Exit/enter animation system | - | FloatingPetView.swift | PetExitEnterTests.swift |
| 9 | Chat room pet interaction | - | ChatView.swift, FloatingPetView.swift | PetChatInteractionTests.swift |
| 10 | SpriteDataRegistry fallback | - | SpriteDataRegistry.swift | PetSpriteRegistryTests.swift |
| 11 | Integration tests | - | - | PetSpeciesIntegrationTests.swift |

**Total: 15 new files, 6 modified files, 7 new test files**
