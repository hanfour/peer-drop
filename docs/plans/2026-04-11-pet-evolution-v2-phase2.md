# Pet Evolution v2 — Phase 2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete all 10 body types with baby + child sprites, add evolution mechanic, and implement pet/poop interactions.

**Architecture:** Each body type is a self-contained Swift enum with `baby` and `child` dictionaries mapping PetAction → frames. A `SpriteDataRegistry` replaces hardcoded fallbacks in PetRendererV2. Evolution triggers in PetEngine when XP+time thresholds are met.

**Tech Stack:** SwiftUI, XcodeGen, existing PetRendererV2/PetPhysicsEngine/PetBehaviorController

**Design doc:** `docs/plans/2026-04-11-pet-evolution-v2-phase2-design.md`

**Reference implementation:** `PeerDrop/Pet/Sprites/CatSpriteData.swift` — follow this exact pattern for all body types.

---

## Conventions

**Pixel index values:** 0=transparent, 1=outline, 2=primary body, 3=secondary, 4=highlight, 5=accent/eyes, 6=pattern slot

**Frame counts per action:** idle:4, walking:4, run:4, jump:3, climb:3, hang:2, fall:2, sitEdge:2, sleeping:2, eat:3, yawn:2, poop:3, happy:2, scared:2, angry:2, love:2, tapReact:2, pickedUp:2, thrown:2, petted:2

**Every frame:** Exactly 16 rows × 16 columns of UInt8 values.

**File naming:** `{BodyType}SpriteData.swift` for baby, child data in same file via `static let child: [PetAction: [[[UInt8]]]]`

**Test pattern:** Same as `PeerDropTests/CatSpriteDataTests.swift` — verify action count, frame dimensions, meta bounds.

---

### Task 1: Cat Child Sprites

**Files:**
- Modify: `PeerDrop/Pet/Sprites/CatSpriteData.swift`
- Test: `PeerDropTests/CatSpriteDataTests.swift`

**Step 1: Add test for child sprites**

Add to `CatSpriteDataTests.swift`:
```swift
func testCatChildHasAllActions() {
    let required: [PetAction] = [.idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
                                  .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
                                  .love, .tapReact, .pickedUp, .thrown, .petted]
    for action in required {
        XCTAssertNotNil(CatSpriteData.child[action], "Missing cat child sprite for \(action)")
    }
}

func testCatChildFramesAre16x16() {
    for (action, frames) in CatSpriteData.child {
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame.count, 16, "child \(action) frame \(i) rows")
            for (row, pixels) in frame.enumerated() {
                XCTAssertEqual(pixels.count, 16, "child \(action) frame \(i) row \(row) cols")
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:PeerDropTests/CatSpriteDataTests -quiet 2>&1 | tail -15`
Expected: Compile error — `CatSpriteData.child` doesn't exist

**Step 3: Implement cat child sprites**

Add `static let child: [PetAction: [[[UInt8]]]]` to `CatSpriteData`. Design child cat as sleeker version: ears 1px taller, body slightly narrower at waist, tail with more curve detail. Same 20 actions, same frame counts as baby.

Visual guide for child cat vs baby:
- Baby: row 2-3 ears (2px), rows 3-7 head (5px), rows 7-12 body (5px wide center)
- Child: row 1-3 ears (3px), rows 3-7 head (5px, slightly narrower), rows 7-13 body (6px tall, 4px wide), longer tail with bend

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:PeerDropTests/CatSpriteDataTests -quiet 2>&1 | tail -15`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Sprites/CatSpriteData.swift PeerDropTests/CatSpriteDataTests.swift
git commit -m "feat(pet): add Cat child sprites — all 20 actions"
```

---

### Task 2: Dog Sprites (Baby + Child)

**Files:**
- Create: `PeerDrop/Pet/Sprites/DogSpriteData.swift`
- Create: `PeerDropTests/DogSpriteDataTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/DogSpriteDataTests.swift
import XCTest
@testable import PeerDrop

final class DogSpriteDataTests: XCTestCase {

    private let requiredActions: [PetAction] = [
        .idle, .walking, .run, .jump, .climb, .hang, .fall, .sitEdge,
        .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
        .love, .tapReact, .pickedUp, .thrown, .petted
    ]

    func testDogBabyHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(DogSpriteData.baby[action], "Missing dog baby \(action)")
        }
    }

    func testDogChildHasAllActions() {
        for action in requiredActions {
            XCTAssertNotNil(DogSpriteData.child[action], "Missing dog child \(action)")
        }
    }

    func testDogBabyFramesAre16x16() {
        for (action, frames) in DogSpriteData.baby {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "baby \(action) frame \(i)")
                for pixels in frame { XCTAssertEqual(pixels.count, 16) }
            }
        }
    }

    func testDogChildFramesAre16x16() {
        for (action, frames) in DogSpriteData.child {
            for (i, frame) in frames.enumerated() {
                XCTAssertEqual(frame.count, 16, "child \(action) frame \(i)")
                for pixels in frame { XCTAssertEqual(pixels.count, 16) }
            }
        }
    }

    func testDogMetaInBounds() {
        let meta = DogSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: Compile error — `DogSpriteData` not found

**Step 3: Implement DogSpriteData**

Create `PeerDrop/Pet/Sprites/DogSpriteData.swift`:

```swift
enum DogSpriteData {
    static let meta = BodyMeta(
        eyeAnchor: (x: 4, y: 5),
        patternMask: (0..<16).map { y in (0..<16).map { x in y >= 4 && y <= 12 && x >= 3 && x <= 12 } },
        groundY: 14,
        hangAnchor: (x: 8, y: 1),
        climbOffset: (x: 2, y: 0)
    )

    static let baby: [PetAction: [[[UInt8]]]] = [/* all 20 actions */]
    static let child: [PetAction: [[[UInt8]]]] = [/* all 20 actions */]
}
```

**Dog visual design:**
- Baby: Floppy ears (3px, droop down from sides of head), round head (rows 3-7), stocky body (rows 7-12), short legs, wagging tail (right side, 2-3px, curves down then up)
- Child: Ears more defined (4px, still floppy), longer snout (1px forward), body slightly leaner, tail longer with more wag amplitude

**Step 4: Run tests, verify pass**

**Step 5: xcodegen + commit**

```bash
xcodegen generate
git add PeerDrop/Pet/Sprites/DogSpriteData.swift PeerDropTests/DogSpriteDataTests.swift PeerDrop.xcodeproj
git commit -m "feat(pet): add Dog baby + child sprites — all 20 actions"
```

---

### Task 3: Rabbit Sprites (Baby + Child)

Same test pattern as Task 2. Create `RabbitSpriteData.swift` + tests.

**Rabbit visual design:**
- Baby: Very long ears (4-5px tall, rows 0-4), round compact head (rows 4-7), round body (rows 7-11), tiny ball tail (1px, back), short legs
- Child: Ears with slight forward curve (5px), head/body more distinguished separation, longer hind legs (visible when jumping), tail slightly larger

**Meta:** eyeAnchor (x:5, y:5), groundY: 13 (shorter legs)

---

### Task 4: Bird Sprites (Baby + Child)

Same test pattern. Create `BirdSpriteData.swift` + tests.

**Bird visual design:**
- Baby: Small wings (2px out each side, rows 6-8), pointed beak (1px forward, row 5), round body, no visible legs (tucked), short tail feather
- Child: Wings larger (3px out, slightly spread), beak more defined, visible tail feathers (2-3px), thinner body, visible feet when grounded

**Meta:** eyeAnchor (x:5, y:4), groundY: 14

---

### Task 5: Frog Sprites (Baby + Child)

Same test pattern. Create `FrogSpriteData.swift` + tests.

**Frog visual design:**
- Baby: Wide flat body (wider than tall, 10px wide × 7px tall), very large eye area (rows 3-5 protruding up), no neck, short stubby legs, no tail
- Child: Slightly taller (8px body), visible hind legs (folded, ready to jump), smoother outline, throat detail (secondary color)

**Meta:** eyeAnchor (x:3, y:3), groundY: 14 (wide stance)

---

### Task 6: Bear Sprites (Baby + Child)

Same test pattern. Create `BearSpriteData.swift` + tests.

**Bear visual design:**
- Baby: Round ears (2px, rows 2-3, set wide apart), large round head (rows 3-8), thick body (rows 8-13, 8px wide), short thick legs
- Child: Ears slightly more defined, broader shoulders, visible paw pads (accent color), body 1px taller

**Meta:** eyeAnchor (x:4, y:5), groundY: 15 (heavy)

---

### Task 7: Dragon Sprites (Baby + Child)

Same test pattern. Create `DragonSpriteData.swift` + tests.

**Dragon visual design:**
- Baby: Small horns (1px, rows 1-2), round head, tiny bat wings (2px, rows 6-8), spiny tail (3px with 1px spikes), stubby legs
- Child: Horns taller (2-3px, row 0-2), wings spread wider (4px), longer neck, tail with more spines, visible claws

**Meta:** eyeAnchor (x:4, y:4), groundY: 14

---

### Task 8: Octopus Sprites (Baby + Child)

Same test pattern. Create `OctopusSpriteData.swift` + tests.

**Octopus visual design:**
- Baby: Large round head (rows 2-8, 8px wide), 4 short tentacles (rows 9-13, 2px each curving outward), no distinct body separate from head
- Child: Head same, 6 longer tentacles (rows 9-14, with curl detail), more personality in tentacle poses per action

**Meta:** eyeAnchor (x:4, y:4), groundY: 14

---

### Task 9: Ghost Sprites (Baby + Child)

Same test pattern. Create `GhostSpriteData.swift` + tests.

**Ghost visual design:**
- Baby: Round head (rows 2-7), body widens then tapers (rows 7-12), NO legs — bottom edge is wavy (alternating 1px up/down), slight transparency effect (use more index-0 pixels scattered in body)
- Child: More elongated (taller), trailing wisps at bottom (3-4px wavy tail), secondary color glow effect around edges

**Special:** Ghost has no `.climb` action — reuse `.fall` frames. `.walking` is floating (body stays same Y, slight bob animation).

**Meta:** eyeAnchor (x:5, y:4), groundY: 14 (floats just above)

---

### Task 10: Slime Sprites (Baby + Child)

Same test pattern. Create `SlimeSpriteData.swift` + tests.

**Slime visual design:**
- Baby: Droplet/blob shape (wide at bottom rows 8-13, narrow at top rows 4-7), jelly bounce (idle frames show squish/stretch cycle), no limbs, moves by oozing
- Child: Larger droplet, visible core highlight (4 color, center pixel cluster), more pronounced stretch on movement, surface tension detail on outline

**Special:** Slime `.walking` is ooze movement (body stretches forward then snaps). `.climb` is body stretching up the wall. `.jump` is maximum stretch then launch.

**Meta:** eyeAnchor (x:5, y:5), groundY: 14

---

### Task 11: SpriteDataRegistry + PetRendererV2 Integration

**Files:**
- Create: `PeerDrop/Pet/Sprites/SpriteDataRegistry.swift`
- Modify: `PeerDrop/Pet/Renderer/PetRendererV2.swift`
- Test: `PeerDropTests/SpriteDataRegistryTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/SpriteDataRegistryTests.swift
import XCTest
@testable import PeerDrop

final class SpriteDataRegistryTests: XCTestCase {

    func testAllBodyTypesHaveBabySprites() {
        for body in BodyGene.allCases {
            let sprites = SpriteDataRegistry.sprites(for: body, stage: .baby)
            XCTAssertNotNil(sprites, "\(body) missing baby sprites")
            XCTAssertNotNil(sprites?[.idle], "\(body) baby missing idle")
        }
    }

    func testAllBodyTypesHaveChildSprites() {
        for body in BodyGene.allCases {
            let sprites = SpriteDataRegistry.sprites(for: body, stage: .child)
            XCTAssertNotNil(sprites, "\(body) missing child sprites")
            XCTAssertNotNil(sprites?[.idle], "\(body) child missing idle")
        }
    }

    func testAllBodyTypesHaveMeta() {
        for body in BodyGene.allCases {
            let meta = SpriteDataRegistry.meta(for: body)
            XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
            XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
        }
    }

    func testEggReturnsNilSprites() {
        let sprites = SpriteDataRegistry.sprites(for: .cat, stage: .egg)
        XCTAssertNil(sprites, "Egg uses EggSpriteData, not body sprites")
    }

    func testFrameCountReturnsCorrectValue() {
        let count = SpriteDataRegistry.frameCount(for: .cat, stage: .baby, action: .idle)
        XCTAssertEqual(count, 4)
    }
}
```

**Step 2: Implement SpriteDataRegistry**

```swift
// PeerDrop/Pet/Sprites/SpriteDataRegistry.swift
enum SpriteDataRegistry {

    static func sprites(for body: BodyGene, stage: PetLevel) -> [PetAction: [[[UInt8]]]]? {
        switch stage {
        case .egg: return nil
        case .baby: return babySprites(for: body)
        case .child: return childSprites(for: body)
        }
    }

    static func meta(for body: BodyGene) -> BodyMeta {
        switch body {
        case .cat: return CatSpriteData.meta
        case .dog: return DogSpriteData.meta
        case .rabbit: return RabbitSpriteData.meta
        case .bird: return BirdSpriteData.meta
        case .frog: return FrogSpriteData.meta
        case .bear: return BearSpriteData.meta
        case .dragon: return DragonSpriteData.meta
        case .octopus: return OctopusSpriteData.meta
        case .ghost: return GhostSpriteData.meta
        case .slime: return SlimeSpriteData.meta
        }
    }

    static func frameCount(for body: BodyGene, stage: PetLevel, action: PetAction) -> Int {
        sprites(for: body, stage: stage)?[action]?.count ?? 2
    }

    private static func babySprites(for body: BodyGene) -> [PetAction: [[[UInt8]]]] {
        switch body {
        case .cat: return CatSpriteData.baby
        case .dog: return DogSpriteData.baby
        case .rabbit: return RabbitSpriteData.baby
        case .bird: return BirdSpriteData.baby
        case .frog: return FrogSpriteData.baby
        case .bear: return BearSpriteData.baby
        case .dragon: return DragonSpriteData.baby
        case .octopus: return OctopusSpriteData.baby
        case .ghost: return GhostSpriteData.baby
        case .slime: return SlimeSpriteData.baby
        }
    }

    private static func childSprites(for body: BodyGene) -> [PetAction: [[[UInt8]]]] {
        switch body {
        case .cat: return CatSpriteData.child
        case .dog: return DogSpriteData.child
        case .rabbit: return RabbitSpriteData.child
        case .bird: return BirdSpriteData.child
        case .frog: return FrogSpriteData.child
        case .bear: return BearSpriteData.child
        case .dragon: return DragonSpriteData.child
        case .octopus: return OctopusSpriteData.child
        case .ghost: return GhostSpriteData.child
        case .slime: return SlimeSpriteData.child
        }
    }
}
```

**Step 3: Update PetRendererV2**

Replace `spriteData(for:stage:action:)` and `bodyMeta(for:)` in PetRendererV2.swift:

```swift
private func spriteData(for body: BodyGene, stage: PetLevel, action: PetAction) -> [[[UInt8]]]? {
    SpriteDataRegistry.sprites(for: body, stage: stage)?[action]
}

private func bodyMeta(for body: BodyGene) -> BodyMeta {
    SpriteDataRegistry.meta(for: body)
}
```

**Step 4: Run tests, verify pass**

**Step 5: xcodegen + commit**

```bash
xcodegen generate
git add PeerDrop/Pet/Sprites/SpriteDataRegistry.swift PeerDrop/Pet/Renderer/PetRendererV2.swift \
  PeerDropTests/SpriteDataRegistryTests.swift PeerDrop.xcodeproj
git commit -m "feat(pet): add SpriteDataRegistry, remove fallback-to-cat in renderer"
```

---

### Task 12: Evolution Mechanic (Baby → Child)

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`
- Modify: `PeerDrop/Pet/Model/EvolutionRequirement.swift`
- Test: `PeerDropTests/PetEvolutionTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetEvolutionTests.swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetEvolutionTests: XCTestCase {

    func testBabyEvolvesToChildAtThreshold() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 499
        pet.hatchedAt = Date().addingTimeInterval(-259201) // >3 days ago
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap) // +2 XP → 501 ≥ 500
        XCTAssertEqual(engine.pet.level, .child)
    }

    func testBabyDoesNotEvolveWithoutEnoughTime() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 600
        pet.hatchedAt = Date() // just hatched
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby, "Should not evolve without 3 days")
    }

    func testBabyDoesNotEvolveWithoutEnoughXP() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 10
        pet.hatchedAt = Date().addingTimeInterval(-300000)
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby, "Should not evolve without 500 XP")
    }

    func testEvolutionMutatesEyesOrPattern() {
        // Run evolution 100 times, verify at least one mutation occurs
        var mutationOccurred = false
        for _ in 0..<100 {
            var pet = PetState.newEgg()
            pet.level = .baby
            pet.genome.body = .cat
            pet.genome.eyes = .dot
            pet.genome.pattern = .none
            pet.experience = 499
            pet.hatchedAt = Date().addingTimeInterval(-259201)
            let engine = PetEngine(pet: pet)
            engine.handleInteraction(.tap)
            if engine.pet.genome.eyes != .dot || engine.pet.genome.pattern != .none {
                mutationOccurred = true
                break
            }
        }
        XCTAssertTrue(mutationOccurred, "10% mutation should eventually occur")
    }
}
```

**Step 2: Implement evolution in PetEngine**

Add to PetEngine after XP gain logic:

```swift
private func checkEvolution() {
    guard let requirement = EvolutionRequirement.for(pet.level) else { return }
    guard pet.experience >= requirement.requiredExperience else { return }

    // Check time requirement
    let age: TimeInterval
    if pet.level == .egg {
        age = Date().timeIntervalSince(pet.createdAt)
    } else {
        age = Date().timeIntervalSince(pet.hatchedAt ?? pet.createdAt)
    }
    guard age >= requirement.minimumAge else { return }

    // Evolve!
    pet.level = requirement.targetLevel

    // 10% mutation on baby → child
    if requirement.targetLevel == .child && Double.random(in: 0...1) < 0.1 {
        pet.genome.mutate(trigger: .evolution)
    }

    // Trigger evolving animation
    currentAction = .evolving
    // Spawn star particles
    for _ in 0..<5 {
        let offset = CGVector(dx: Double.random(in: -30...30), dy: Double.random(in: -50...(-10)))
        particles.append(PetParticle(type: .star, position: physicsState.position, velocity: offset, lifetime: 1.2))
    }
}
```

Call `checkEvolution()` after every XP gain in `handleInteraction(_:)`.

**Step 3: Run tests, verify pass**

**Step 4: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift PeerDropTests/PetEvolutionTests.swift
git commit -m "feat(pet): add baby→child evolution with XP+time threshold and mutation"
```

---

### Task 13: Gesture Interactions (Pet Stroke + Poop Cleaning)

**Files:**
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift`
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`
- Test: `PeerDropTests/PetInteractionTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetInteractionTests.swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetInteractionTests: XCTestCase {

    func testPoopCleaningGivesXP() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        engine.poopState.drop(at: CGPoint(x: 100, y: 700))
        let xpBefore = engine.pet.experience
        let poopID = engine.poopState.poops.first!.id
        engine.cleanPoop(id: poopID)
        XCTAssertEqual(engine.pet.experience, xpBefore + 1)
        XCTAssertTrue(engine.poopState.poops.isEmpty)
    }

    func testPetStrokeGivesXPAndAction() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        let xpBefore = engine.pet.experience
        engine.handlePetStroke()
        XCTAssertEqual(engine.pet.experience, xpBefore + 3)
        XCTAssertEqual(engine.currentAction, .petted)
    }

    func testPoopMoodPenalty() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        // Add old poop (>10 min ago)
        var oldPoop = PoopState.Poop(position: CGPoint(x: 100, y: 700))
        // Force droppedAt to past (via reflection or test helper)
        engine.poopState.poops.append(oldPoop)
        XCTAssertTrue(engine.poopState.hasUncleanedPoops)
    }
}
```

**Step 2: Implement in PetEngine**

Add methods:
```swift
/// Clean a poop and award XP.
func cleanPoop(id: UUID) {
    guard poopState.clean(id: id) else { return }
    pet.experience += 1
    // Star particles at poop location
    particles.append(PetParticle(type: .star, position: physicsState.position, velocity: CGVector(dx: 0, dy: -20), lifetime: 0.8))
}

/// Handle pet stroke gesture.
func handlePetStroke() {
    pet.experience += 3
    currentAction = .petted
    // Love particles
    for _ in 0..<3 {
        let offset = CGVector(dx: Double.random(in: -20...20), dy: Double.random(in: -40...(-10)))
        particles.append(PetParticle(type: .heart, position: physicsState.position, velocity: offset, lifetime: 1.0))
    }
    checkEvolution()
}

/// Published poop state for UI rendering.
@Published var poopState = PoopState()
```

**Step 3: Add gesture to FloatingPetView**

Add horizontal swipe detection (high velocity horizontal drag that doesn't move pet):
```swift
.gesture(
    DragGesture(minimumDistance: 30)
        .onEnded { value in
            let horizontal = abs(value.translation.width)
            let vertical = abs(value.translation.height)
            if horizontal > vertical * 2 && horizontal > 40 {
                engine.handlePetStroke()
            }
        }
)
```

Add poop rendering as tappable items:
```swift
ForEach(engine.poopState.poops) { poop in
    Text("💩")
        .font(.system(size: 20))
        .position(poop.position)
        .onTapGesture { engine.cleanPoop(id: poop.id) }
}
```

**Step 4: Run tests, verify pass**

**Step 5: Commit**

```bash
git add PeerDrop/Pet/UI/FloatingPetView.swift PeerDrop/Pet/Engine/PetEngine.swift \
  PeerDropTests/PetInteractionTests.swift
git commit -m "feat(pet): add pet stroke gesture + poop cleaning interaction

Phase 2 complete: all 10 body types, baby→child evolution, full interactions."
```

---

## Phase 2 Deliverables Checklist

After all 13 tasks:
- [ ] 10 body types with baby sprites (20 actions each)
- [ ] 10 body types with child sprites (20 actions each)
- [ ] SpriteDataRegistry — unified lookup, no fallbacks
- [ ] Baby → Child evolution (500 XP + 3 days + 10% mutation)
- [ ] Pet stroke gesture → petted action + heart particles + 3 XP
- [ ] Poop cleaning → tap to remove + star particles + 1 XP
- [ ] All existing tests still pass + new tests for every component
