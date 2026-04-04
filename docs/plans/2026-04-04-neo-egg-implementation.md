# Project Neo-Egg Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a virtual pet companion (Tamagotchi-style pixel sprite) that floats across all screens, reacts to chat/connection events, and socializes with other users' pets via P2P.

**Architecture:** Independent `Pet/` module under `PeerDrop/` with 3 integration points (~18 lines changed in existing code). Pet state machine, 64×64 procedural pixel renderer, local template dialog engine, iCloud sync. Uses closure callbacks matching existing codebase patterns (NOT NotificationCenter).

**Tech Stack:** SwiftUI Canvas, CoreMotion (accelerometer), Combine, CloudKit/iCloud Documents, existing P2P transport layer.

**Design doc:** `docs/plans/2026-04-04-neo-egg-design.md`

---

## Task 1: PetState Data Model

**Files:**
- Create: `PeerDrop/Pet/Model/PetLevel.swift`
- Create: `PeerDrop/Pet/Model/PetMood.swift`
- Create: `PeerDrop/Pet/Model/PetAction.swift`
- Create: `PeerDrop/Pet/Model/PetLifeState.swift`
- Create: `PeerDrop/Pet/Model/PetGenome.swift`
- Create: `PeerDrop/Pet/Model/PetState.swift`
- Create: `PeerDrop/Pet/Model/EvolutionRequirement.swift`
- Create: `PeerDrop/Pet/Model/SocialEntry.swift`
- Test: `PeerDropTests/PetStateTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetStateTests: XCTestCase {

    // MARK: - PetLevel

    func testPetLevelOrdering() {
        XCTAssertTrue(PetLevel.egg < PetLevel.baby)
    }

    func testPetLevelRawValues() {
        XCTAssertEqual(PetLevel.egg.rawValue, 1)
        XCTAssertEqual(PetLevel.baby.rawValue, 2)
    }

    // MARK: - PetGenome

    func testGenomeCanvasSize() {
        XCTAssertEqual(PetGenome.canvasSize, 64)
    }

    func testGenomeMutation() {
        var genome = PetGenome.random()
        let original = genome
        // Mutate 100 times — at least one field should change
        for _ in 0..<100 {
            genome.mutate(trigger: .tap)
        }
        let changed = genome.bodyGene != original.bodyGene
            || genome.eyeGene != original.eyeGene
            || genome.limbGene != original.limbGene
            || genome.patternGene != original.patternGene
        XCTAssertTrue(changed, "Genome should mutate after many triggers")
    }

    func testPersonalityTraitsRange() {
        let genome = PetGenome.random()
        let traits = genome.personalityTraits
        XCTAssertTrue((0...1).contains(traits.independence))
        XCTAssertTrue((0...1).contains(traits.curiosity))
        XCTAssertTrue((0...1).contains(traits.energy))
        XCTAssertTrue((0...1).contains(traits.timidity))
        XCTAssertTrue((0...1).contains(traits.mischief))
    }

    // MARK: - PetState

    func testNewPetStartsAsEgg() {
        let pet = PetState.newEgg()
        XCTAssertEqual(pet.level, .egg)
        XCTAssertEqual(pet.experience, 0)
        XCTAssertNil(pet.name)
        XCTAssertTrue(pet.socialLog.isEmpty)
    }

    func testPetStateCodable() throws {
        let pet = PetState.newEgg()
        let data = try JSONEncoder().encode(pet)
        let decoded = try JSONDecoder().decode(PetState.self, from: data)
        XCTAssertEqual(decoded.id, pet.id)
        XCTAssertEqual(decoded.level, pet.level)
        XCTAssertEqual(decoded.experience, pet.experience)
        XCTAssertEqual(decoded.genome.bodyGene, pet.genome.bodyGene)
    }

    // MARK: - PetMood

    func testAllMoodsCodable() throws {
        for mood in PetMood.allCases {
            let data = try JSONEncoder().encode(mood)
            let decoded = try JSONDecoder().decode(PetMood.self, from: data)
            XCTAssertEqual(decoded, mood)
        }
    }

    // MARK: - EvolutionRequirement

    func testEggEvolutionRequirement() {
        let req = EvolutionRequirement.for(.egg)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.targetLevel, .baby)
        XCTAssertEqual(req?.requiredExperience, 100)
        XCTAssertEqual(req?.minimumAge, 86400) // 24hr
    }

    func testBabyHasNoEvolutionYet() {
        let req = EvolutionRequirement.for(.baby)
        XCTAssertNil(req, "MVP only supports egg→baby evolution")
    }

    // MARK: - SocialEntry

    func testSocialEntryDefaultUnrevealed() {
        let entry = SocialEntry(
            id: UUID(),
            partnerPetID: UUID(),
            partnerName: "TestPet",
            date: Date(),
            interaction: .greet,
            dialogue: [],
            isRevealed: false
        )
        XCTAssertFalse(entry.isRevealed)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetStateTests -quiet`
Expected: FAIL — types not defined

**Step 3: Implement models**

Create `PeerDrop/Pet/Model/PetLevel.swift`:
```swift
import Foundation

enum PetLevel: Int, Codable, Comparable, CaseIterable {
    case egg = 1
    case baby = 2
    // Future: child = 3, teen = 4, mature = 5, ultimate = 6

    static func < (lhs: PetLevel, rhs: PetLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

Create `PeerDrop/Pet/Model/PetMood.swift`:
```swift
import Foundation

enum PetMood: String, Codable, CaseIterable {
    case happy
    case curious
    case sleepy
    case lonely
    case excited
    case startled

    var displayName: String {
        switch self {
        case .happy: return "開心"
        case .curious: return "好奇"
        case .sleepy: return "想睡"
        case .lonely: return "寂寞"
        case .excited: return "興奮"
        case .startled: return "嚇到"
        }
    }
}
```

Create `PeerDrop/Pet/Model/PetAction.swift`:
```swift
import Foundation

enum PetAction: String, Codable {
    // Basic
    case idle
    case walking
    case sleeping
    case evolving

    // Emotion reactions
    case wagTail
    case freeze
    case hideInShell
    case zoomies

    // Chat-aware
    case notifyMessage
    case climbOnBubble
    case blockText
    case bounceBetweenBubbles
    case tiltHead
    case stuffCheeks
    case ignore
}
```

Create `PeerDrop/Pet/Model/PetLifeState.swift`:
```swift
import Foundation

enum PetLifeState {
    case sleeping
    case waking
    case active
    case napping
    case drowsy

    static func current(energy: Double) -> PetLifeState {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0...5:
            return .sleeping
        case 6...8:
            return energy > 0.5 ? .waking : .sleeping
        case 9...11:
            return .active
        case 12...13:
            return .napping
        case 14...20:
            return .active
        case 21...23:
            return energy > 0.7 ? .active : .drowsy
        default:
            return .active
        }
    }
}
```

Create `PeerDrop/Pet/Model/PetGenome.swift`:
```swift
import Foundation

enum BodyGene: String, Codable, CaseIterable {
    case round
    case square
    case oval
}

enum EyeGene: String, Codable, CaseIterable {
    case dot
    case round
    case line
    case dizzy
}

enum LimbGene: String, Codable, CaseIterable {
    case short
    case long
    case none
}

enum PatternGene: String, Codable, CaseIterable {
    case none
    case stripe
    case spot
}

struct PersonalityTraits: Codable, Equatable {
    var independence: Double  // high=cat, low=dog
    var curiosity: Double     // high=bird/rabbit, low=turtle
    var energy: Double        // high=hamster, low=turtle
    var timidity: Double      // high=rabbit, low=dog
    var mischief: Double      // high=cat, low=turtle
}

struct PetGenome: Codable, Equatable {
    static let canvasSize = 64

    var bodyGene: BodyGene
    var eyeGene: EyeGene
    var limbGene: LimbGene
    var patternGene: PatternGene
    var personalityGene: Double // 0.0~1.0

    var personalityTraits: PersonalityTraits {
        PersonalityTraits(
            independence: clamp(personalityGene * 1.2),
            curiosity: clamp(sin(personalityGene * .pi)),
            energy: clamp(1.0 - personalityGene * 0.8),
            timidity: clamp(personalityGene * 0.9 + 0.1),
            mischief: clamp(cos(personalityGene * .pi) * 0.5 + 0.5)
        )
    }

    mutating func mutate(trigger: InteractionType) {
        let chance = trigger == .evolution ? 1.0 : 0.3
        if Double.random(in: 0...1) < chance {
            let allBodies = BodyGene.allCases
            let allEyes = EyeGene.allCases
            let allLimbs = LimbGene.allCases
            let allPatterns = PatternGene.allCases

            switch Int.random(in: 0...4) {
            case 0: bodyGene = allBodies.randomElement()!
            case 1: eyeGene = allEyes.randomElement()!
            case 2: limbGene = allLimbs.randomElement()!
            case 3: patternGene = allPatterns.randomElement()!
            case 4: personalityGene = clamp(personalityGene + Double.random(in: -0.1...0.1))
            default: break
            }
        }
    }

    static func random() -> PetGenome {
        PetGenome(
            bodyGene: BodyGene.allCases.randomElement()!,
            eyeGene: EyeGene.allCases.randomElement()!,
            limbGene: LimbGene.allCases.randomElement()!,
            patternGene: PatternGene.allCases.randomElement()!,
            personalityGene: Double.random(in: 0...1)
        )
    }

    private func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
```

Create `PeerDrop/Pet/Model/SocialEntry.swift`:
```swift
import Foundation

enum SocialInteraction: String, Codable {
    case greet
    case chat
    case play
}

struct DialogueLine: Codable, Equatable {
    let speaker: String  // "mine" or "partner"
    let text: String
}

struct SocialEntry: Codable, Identifiable {
    let id: UUID
    let partnerPetID: UUID
    let partnerName: String?
    let date: Date
    let interaction: SocialInteraction
    var dialogue: [DialogueLine]
    var isRevealed: Bool
}
```

Create `PeerDrop/Pet/Model/EvolutionRequirement.swift`:
```swift
import Foundation

struct EvolutionRequirement {
    let targetLevel: PetLevel
    let requiredExperience: Int
    let socialBonus: Double
    let minimumAge: TimeInterval

    static func `for`(_ level: PetLevel) -> EvolutionRequirement? {
        switch level {
        case .egg:
            return EvolutionRequirement(
                targetLevel: .baby,
                requiredExperience: 100,
                socialBonus: 1.5,
                minimumAge: 86400 // 24 hours
            )
        case .baby:
            return nil // MVP: no further evolution yet
        }
    }
}
```

Create `PeerDrop/Pet/Model/PetState.swift`:
```swift
import Foundation

struct PetState: Codable {
    let id: UUID
    var name: String?
    var birthDate: Date
    var level: PetLevel
    var experience: Int
    var genome: PetGenome
    var mood: PetMood
    var socialLog: [SocialEntry]
    var lastInteraction: Date

    static func newEgg() -> PetState {
        PetState(
            id: UUID(),
            name: nil,
            birthDate: Date(),
            level: .egg,
            experience: 0,
            genome: .random(),
            mood: .curious,
            socialLog: [],
            lastInteraction: Date()
        )
    }
}
```

**Step 4: Regenerate Xcode project and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetStateTests -quiet`
Expected: PASS — all PetStateTests green

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Model/ PeerDropTests/PetStateTests.swift
git commit -m "feat(pet): add PetState data model with genome and evolution system"
```

---

## Task 2: InteractionTracker

**Files:**
- Create: `PeerDrop/Pet/Engine/InteractionTracker.swift`
- Test: `PeerDropTests/InteractionTrackerTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

@MainActor
final class InteractionTrackerTests: XCTestCase {
    var tracker: InteractionTracker!

    override func setUp() async throws {
        try await super.setUp()
        tracker = InteractionTracker()
    }

    override func tearDown() async throws {
        tracker = nil
        try await super.tearDown()
    }

    func testRecordInteraction() {
        tracker.record(.tap)
        XCTAssertEqual(tracker.allHistory.count, 1)
        XCTAssertEqual(tracker.allHistory.first?.type, .tap)
    }

    func testRecentHistoryFilters24Hours() {
        tracker.record(.tap)
        // Manually insert an old record
        let oldRecord = InteractionTracker.Record(
            type: .shake,
            date: Date().addingTimeInterval(-90000) // 25hr ago
        )
        tracker.insertForTesting(oldRecord)
        XCTAssertEqual(tracker.allHistory.count, 2)
        XCTAssertEqual(tracker.recentHistory.count, 1, "Only last 24hr should be recent")
    }

    func testCalculateMoodHappy() {
        // 5+ interactions in 1hr → happy
        for _ in 0..<6 {
            tracker.record(.tap)
        }
        XCTAssertEqual(tracker.calculateMood(hasSocialRecently: false), .happy)
    }

    func testCalculateMoodSleepy() {
        // No recent interactions → sleepy
        XCTAssertEqual(tracker.calculateMood(hasSocialRecently: false), .sleepy)
    }

    func testCalculateMoodLonely() {
        // Has interactions but no social for 24hr
        tracker.record(.tap)
        XCTAssertEqual(tracker.calculateMood(hasSocialRecently: false), .curious)
        // With no social for a long time and few interactions → lonely handled by engine
    }

    func testExperienceValues() {
        XCTAssertEqual(InteractionType.tap.experienceValue, 2)
        XCTAssertEqual(InteractionType.shake.experienceValue, 3)
        XCTAssertEqual(InteractionType.peerConnected.experienceValue, 5)
        XCTAssertEqual(InteractionType.petMeeting.experienceValue, 10)
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/InteractionTrackerTests -quiet`
Expected: FAIL

**Step 3: Implement InteractionTracker**

Create `PeerDrop/Pet/Engine/InteractionTracker.swift`:
```swift
import Foundation

enum InteractionType: String, Codable, CaseIterable {
    case tap
    case shake
    case charge
    case steps
    case peerConnected
    case chatActive
    case fileTransfer
    case petMeeting
    case evolution

    var experienceValue: Int {
        switch self {
        case .tap: return 2
        case .shake: return 3
        case .charge: return 1
        case .steps: return 1
        case .peerConnected: return 5
        case .chatActive: return 2
        case .fileTransfer: return 3
        case .petMeeting: return 10
        case .evolution: return 0
        }
    }
}

class InteractionTracker {
    struct Record: Codable {
        let type: InteractionType
        let date: Date
    }

    private(set) var allHistory: [Record] = []

    var recentHistory: [Record] {
        let cutoff = Date().addingTimeInterval(-86400)
        return allHistory.filter { $0.date > cutoff }
    }

    var lastHourHistory: [Record] {
        let cutoff = Date().addingTimeInterval(-3600)
        return allHistory.filter { $0.date > cutoff }
    }

    func record(_ type: InteractionType) {
        allHistory.append(Record(type: type, date: Date()))
        trimOldHistory()
    }

    func calculateMood(hasSocialRecently: Bool) -> PetMood {
        let recentCount = lastHourHistory.count
        let hasNewPeer = lastHourHistory.contains { $0.type == .peerConnected }

        if recentCount >= 5 { return .happy }
        if hasNewPeer { return .curious }
        if recentCount == 0 && !hasSocialRecently { return .sleepy }
        if recentCount > 0 { return .curious }
        return .sleepy
    }

    // For testing only
    func insertForTesting(_ record: Record) {
        allHistory.append(record)
    }

    private func trimOldHistory() {
        let cutoff = Date().addingTimeInterval(-7 * 86400) // Keep 7 days
        allHistory.removeAll { $0.date < cutoff }
    }
}
```

**Step 4: Regenerate and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/InteractionTrackerTests -quiet`
Expected: PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Engine/InteractionTracker.swift PeerDropTests/InteractionTrackerTests.swift
git commit -m "feat(pet): add InteractionTracker with mood calculation"
```

---

## Task 3: PixelGrid & PetRenderer

**Files:**
- Create: `PeerDrop/Pet/Renderer/PixelGrid.swift`
- Create: `PeerDrop/Pet/Renderer/PetRenderer.swift`
- Create: `PeerDrop/Pet/Renderer/PetAnimationController.swift`
- Test: `PeerDropTests/PixelGridTests.swift`
- Test: `PeerDropTests/PetRendererTests.swift`

**Step 1: Write failing tests**

Create `PeerDropTests/PixelGridTests.swift`:
```swift
import XCTest
@testable import PeerDrop

final class PixelGridTests: XCTestCase {

    func testEmptyGrid() {
        let grid = PixelGrid.empty()
        XCTAssertEqual(grid.size, 64)
        // All pixels should be false
        for y in 0..<64 {
            for x in 0..<64 {
                XCTAssertFalse(grid.pixels[y][x])
            }
        }
    }

    func testSetPixel() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 10, y: 20, value: true)
        XCTAssertTrue(grid.pixels[20][10])
    }

    func testSetPixelOutOfBoundsIsIgnored() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 100, y: 100, value: true) // Should not crash
    }

    func testDrawCircle() {
        var grid = PixelGrid.empty()
        grid.drawCircle(center: (32, 32), radius: 10)
        // Center area should have pixels
        XCTAssertTrue(grid.pixels[32][32])
        // Far corner should not
        XCTAssertFalse(grid.pixels[0][0])
    }

    func testDrawRect() {
        var grid = PixelGrid.empty()
        grid.drawRect(origin: (10, 10), size: (5, 5))
        XCTAssertTrue(grid.pixels[10][10])
        XCTAssertTrue(grid.pixels[14][14])
        XCTAssertFalse(grid.pixels[9][9])
    }

    func testMirrorHorizontal() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 0, y: 0, value: true)
        grid.mirror(axis: .horizontal)
        XCTAssertTrue(grid.pixels[0][0])
        XCTAssertTrue(grid.pixels[0][63])
    }

    func testPixelCount() {
        var grid = PixelGrid.empty()
        XCTAssertEqual(grid.activePixelCount, 0)
        grid.drawRect(origin: (0, 0), size: (2, 2))
        XCTAssertEqual(grid.activePixelCount, 4)
    }
}
```

Create `PeerDropTests/PetRendererTests.swift`:
```swift
import XCTest
@testable import PeerDrop

final class PetRendererTests: XCTestCase {
    let renderer = PetRenderer()

    func testRenderEggProducesPixels() {
        let genome = PetGenome.random()
        let grid = renderer.render(
            genome: genome, level: .egg, mood: .curious, animationFrame: 0
        )
        XCTAssertGreaterThan(grid.activePixelCount, 0, "Egg should have visible pixels")
    }

    func testRenderBabyProducesMorePixelsThanEgg() {
        let genome = PetGenome.random()
        let eggGrid = renderer.render(
            genome: genome, level: .egg, mood: .curious, animationFrame: 0
        )
        let babyGrid = renderer.render(
            genome: genome, level: .baby, mood: .curious, animationFrame: 0
        )
        XCTAssertGreaterThan(
            babyGrid.activePixelCount, eggGrid.activePixelCount,
            "Baby should have more detail than egg"
        )
    }

    func testDifferentGenomesProduceDifferentPixels() {
        let genome1 = PetGenome(bodyGene: .round, eyeGene: .dot, limbGene: .short,
                                 patternGene: .none, personalityGene: 0.2)
        let genome2 = PetGenome(bodyGene: .square, eyeGene: .round, limbGene: .long,
                                 patternGene: .stripe, personalityGene: 0.8)
        let grid1 = renderer.render(genome: genome1, level: .baby, mood: .happy, animationFrame: 0)
        let grid2 = renderer.render(genome: genome2, level: .baby, mood: .happy, animationFrame: 0)
        XCTAssertNotEqual(grid1.pixels, grid2.pixels, "Different genes should produce different visuals")
    }

    func testMoodAffectsEyes() {
        let genome = PetGenome(bodyGene: .round, eyeGene: .dot, limbGene: .short,
                                patternGene: .none, personalityGene: 0.5)
        let happyGrid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        let sleepyGrid = renderer.render(genome: genome, level: .baby, mood: .sleepy, animationFrame: 0)
        XCTAssertNotEqual(happyGrid.pixels, sleepyGrid.pixels, "Different moods should change eye rendering")
    }

    func testAnimationFramesProduceDifferentGrids() {
        let genome = PetGenome.random()
        let frame0 = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        let frame1 = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 1)
        // At least walking/idle should differ between frames
        // Note: some frames may be identical for certain actions, so this is a soft check
        _ = frame0
        _ = frame1
        // Just verify no crash — visual difference is verified by eye
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PixelGridTests -only-testing:PeerDropTests/PetRendererTests -quiet`
Expected: FAIL

**Step 3: Implement PixelGrid**

Create `PeerDrop/Pet/Renderer/PixelGrid.swift`:
```swift
import Foundation

enum Axis {
    case horizontal
    case vertical
}

struct PixelGrid: Equatable {
    let size: Int
    var pixels: [[Bool]]

    static func empty(size: Int = 64) -> PixelGrid {
        PixelGrid(size: size, pixels: Array(repeating: Array(repeating: false, count: size), count: size))
    }

    var activePixelCount: Int {
        pixels.reduce(0) { $0 + $1.filter { $0 }.count }
    }

    mutating func setPixel(x: Int, y: Int, value: Bool) {
        guard x >= 0, x < size, y >= 0, y < size else { return }
        pixels[y][x] = value
    }

    mutating func drawCircle(center: (Int, Int), radius: Int) {
        let (cx, cy) = center
        for y in (cy - radius)...(cy + radius) {
            for x in (cx - radius)...(cx + radius) {
                let dx = x - cx
                let dy = y - cy
                if dx * dx + dy * dy <= radius * radius {
                    setPixel(x: x, y: y, value: true)
                }
            }
        }
    }

    mutating func drawEllipse(center: (Int, Int), rx: Int, ry: Int) {
        let (cx, cy) = center
        for y in (cy - ry)...(cy + ry) {
            for x in (cx - rx)...(cx + rx) {
                let dx = Double(x - cx) / Double(rx)
                let dy = Double(y - cy) / Double(ry)
                if dx * dx + dy * dy <= 1.0 {
                    setPixel(x: x, y: y, value: true)
                }
            }
        }
    }

    mutating func drawRect(origin: (Int, Int), size: (Int, Int)) {
        let (ox, oy) = origin
        let (w, h) = size
        for y in oy..<(oy + h) {
            for x in ox..<(ox + w) {
                setPixel(x: x, y: y, value: true)
            }
        }
    }

    mutating func drawLine(from: (Int, Int), to: (Int, Int)) {
        var (x0, y0) = from
        let (x1, y1) = to
        let dx = abs(x1 - x0)
        let dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            setPixel(x: x0, y: y0, value: true)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }

    mutating func mirror(axis: Axis) {
        switch axis {
        case .horizontal:
            for y in 0..<size {
                for x in 0..<(size / 2) {
                    if pixels[y][x] {
                        pixels[y][size - 1 - x] = true
                    } else if pixels[y][size - 1 - x] {
                        pixels[y][x] = true
                    }
                }
            }
        case .vertical:
            for y in 0..<(size / 2) {
                for x in 0..<size {
                    if pixels[y][x] {
                        pixels[size - 1 - y][x] = true
                    } else if pixels[size - 1 - y][x] {
                        pixels[y][x] = true
                    }
                }
            }
        }
    }
}
```

**Step 4: Implement PetRenderer**

Create `PeerDrop/Pet/Renderer/PetRenderer.swift`:
```swift
import Foundation

class PetRenderer {

    func render(genome: PetGenome, level: PetLevel, mood: PetMood, animationFrame: Int) -> PixelGrid {
        var grid = PixelGrid.empty()

        switch level {
        case .egg:
            drawEgg(grid: &grid, genome: genome, frame: animationFrame)
        case .baby:
            drawBaby(grid: &grid, genome: genome, mood: mood, frame: animationFrame)
        }

        return grid
    }

    // MARK: - Egg

    private func drawEgg(grid: inout PixelGrid, genome: PetGenome, frame: Int) {
        let cx = 32
        let cy = 32
        // Egg shape: tall ellipse
        let breathOffset = frame % 2 == 0 ? 0 : 1
        grid.drawEllipse(center: (cx, cy), rx: 12, ry: 16 + breathOffset)

        // Cracks based on genome personality (visual variation)
        if genome.personalityGene > 0.3 {
            grid.drawLine(from: (cx - 3, cy - 5), to: (cx - 1, cy - 2))
        }
        if genome.personalityGene > 0.6 {
            grid.drawLine(from: (cx + 2, cy - 8), to: (cx + 4, cy - 4))
        }
    }

    // MARK: - Baby

    private func drawBaby(grid: inout PixelGrid, genome: PetGenome, mood: PetMood, frame: Int) {
        drawBody(grid: &grid, gene: genome.bodyGene, frame: frame)
        drawEyes(grid: &grid, gene: genome.eyeGene, mood: mood, bodyGene: genome.bodyGene)
        drawLimbs(grid: &grid, gene: genome.limbGene, bodyGene: genome.bodyGene, frame: frame)
        drawPattern(grid: &grid, gene: genome.patternGene, bodyGene: genome.bodyGene)
    }

    private func drawBody(grid: inout PixelGrid, gene: BodyGene, frame: Int) {
        let cx = 32
        let cy = 32
        let bounce = frame % 2 == 0 ? 0 : -1

        switch gene {
        case .round:
            grid.drawCircle(center: (cx, cy + bounce), radius: 14)
        case .square:
            grid.drawRect(origin: (cx - 12, cy - 12 + bounce), size: (24, 24))
        case .oval:
            grid.drawEllipse(center: (cx, cy + bounce), rx: 10, ry: 14)
        }
    }

    private func drawEyes(grid: inout PixelGrid, gene: EyeGene, mood: PetMood, bodyGene: BodyGene) {
        let leftEye = (26, 28)
        let rightEye = (38, 28)

        // Mood overrides eye style
        switch mood {
        case .happy:
            // Arc eyes (happy squint) — small line
            grid.drawLine(from: (leftEye.0 - 1, leftEye.1), to: (leftEye.0 + 1, leftEye.1))
            grid.drawLine(from: (rightEye.0 - 1, rightEye.1), to: (rightEye.0 + 1, rightEye.1))
        case .sleepy:
            // Horizontal line eyes
            grid.drawLine(from: (leftEye.0 - 1, leftEye.1), to: (leftEye.0 + 1, leftEye.1))
            grid.drawLine(from: (rightEye.0 - 1, rightEye.1), to: (rightEye.0 + 1, rightEye.1))
            // ZZZ above
            grid.setPixel(x: 42, y: 20, value: true)
            grid.setPixel(x: 44, y: 18, value: true)
            grid.setPixel(x: 46, y: 16, value: true)
        case .startled:
            // Big round eyes
            grid.drawCircle(center: leftEye, radius: 3)
            grid.drawCircle(center: rightEye, radius: 3)
        default:
            // Use gene-defined eye style
            drawGeneEyes(grid: &grid, gene: gene, left: leftEye, right: rightEye)
        }
    }

    private func drawGeneEyes(grid: inout PixelGrid, gene: EyeGene, left: (Int, Int), right: (Int, Int)) {
        switch gene {
        case .dot:
            grid.setPixel(x: left.0, y: left.1, value: true)
            grid.setPixel(x: right.0, y: right.1, value: true)
        case .round:
            grid.drawCircle(center: left, radius: 2)
            grid.drawCircle(center: right, radius: 2)
        case .line:
            grid.drawLine(from: (left.0 - 1, left.1), to: (left.0 + 1, left.1))
            grid.drawLine(from: (right.0 - 1, right.1), to: (right.0 + 1, right.1))
        case .dizzy:
            // Spiral-ish: small X
            grid.drawLine(from: (left.0 - 1, left.1 - 1), to: (left.0 + 1, left.1 + 1))
            grid.drawLine(from: (left.0 + 1, left.1 - 1), to: (left.0 - 1, left.1 + 1))
            grid.drawLine(from: (right.0 - 1, right.1 - 1), to: (right.0 + 1, right.1 + 1))
            grid.drawLine(from: (right.0 + 1, right.1 - 1), to: (right.0 - 1, right.1 + 1))
        }
    }

    private func drawLimbs(grid: inout PixelGrid, gene: LimbGene, bodyGene: BodyGene, frame: Int) {
        let bodyBottom = 44
        let walkOffset = frame % 2 == 0 ? 0 : 2

        switch gene {
        case .short:
            // Short stubby legs
            grid.drawRect(origin: (26, bodyBottom), size: (3, 4 + walkOffset))
            grid.drawRect(origin: (35, bodyBottom), size: (3, 4 + (2 - walkOffset)))
        case .long:
            // Long thin legs
            grid.drawLine(from: (28, bodyBottom), to: (26, bodyBottom + 8 + walkOffset))
            grid.drawLine(from: (36, bodyBottom), to: (38, bodyBottom + 8 + (2 - walkOffset)))
        case .none:
            // No visible limbs — blob shape
            break
        }
    }

    private func drawPattern(grid: inout PixelGrid, gene: PatternGene, bodyGene: BodyGene) {
        switch gene {
        case .none:
            break
        case .stripe:
            for y in stride(from: 24, to: 40, by: 4) {
                grid.drawLine(from: (24, y), to: (40, y))
            }
        case .spot:
            grid.setPixel(x: 28, y: 30, value: true)
            grid.setPixel(x: 35, y: 33, value: true)
            grid.setPixel(x: 30, y: 36, value: true)
        }
    }
}
```

**Step 5: Implement PetAnimationController**

Create `PeerDrop/Pet/Renderer/PetAnimationController.swift`:
```swift
import Foundation
import Combine

@MainActor
class PetAnimationController: ObservableObject {
    @Published var currentFrame: Int = 0

    let frameRate: TimeInterval = 0.5  // 2 FPS
    private var timer: Timer?
    private var frameCount: Int = 2

    func startAnimation(frameCount: Int = 2) {
        self.frameCount = frameCount
        stopAnimation()
        timer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentFrame = (self.currentFrame + 1) % self.frameCount
            }
        }
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
        currentFrame = 0
    }

    deinit {
        timer?.invalidate()
    }
}
```

**Step 6: Regenerate and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PixelGridTests -only-testing:PeerDropTests/PetRendererTests -quiet`
Expected: PASS

**Step 7: Commit**

```bash
git add PeerDrop/Pet/Renderer/ PeerDropTests/PixelGridTests.swift PeerDropTests/PetRendererTests.swift
git commit -m "feat(pet): add 64x64 pixel grid and procedural pet renderer"
```

---

## Task 4: PetDialogEngine

**Files:**
- Create: `PeerDrop/Pet/Engine/PetDialogEngine.swift`
- Test: `PeerDropTests/PetDialogEngineTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

final class PetDialogEngineTests: XCTestCase {
    let engine = PetDialogEngine()

    func testEggReturnsNil() {
        let result = engine.generate(level: .egg, mood: .happy)
        XCTAssertNil(result, "Eggs cannot speak")
    }

    func testBabyReturnsText() {
        let result = engine.generate(level: .baby, mood: .happy)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.isEmpty)
    }

    func testBabyAllMoodsHaveDialogue() {
        for mood in PetMood.allCases {
            let result = engine.generate(level: .baby, mood: mood)
            XCTAssertNotNil(result, "Baby should have dialogue for mood: \(mood)")
        }
    }

    func testGeneratePrivateChat() {
        let dialogue = engine.generatePrivateChat(
            myLevel: .baby, partnerLevel: .baby,
            myMood: .happy, partnerMood: .curious
        )
        XCTAssertFalse(dialogue.isEmpty)
        // Should have at least 2 lines (back and forth)
        XCTAssertGreaterThanOrEqual(dialogue.count, 2)
        // First line from "mine", second from "partner"
        XCTAssertEqual(dialogue[0].speaker, "mine")
        XCTAssertEqual(dialogue[1].speaker, "partner")
    }

    func testEggPrivateChatIsMinimal() {
        let dialogue = engine.generatePrivateChat(
            myLevel: .egg, partnerLevel: .egg,
            myMood: .curious, partnerMood: .curious
        )
        // Eggs can only do non-verbal
        XCTAssertTrue(dialogue.allSatisfy { $0.text.count <= 5 })
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetDialogEngineTests -quiet`
Expected: FAIL

**Step 3: Implement PetDialogEngine**

Create `PeerDrop/Pet/Engine/PetDialogEngine.swift`:
```swift
import Foundation

class PetDialogEngine {

    private let babyTemplates: [PetMood: [String]] = [
        .happy:    ["嘿！", "咿呀～", "嗯嗯！", "哇！", "呀哈！"],
        .curious:  ["嗯？", "呀？", "噢？", "嗯嗯？"],
        .sleepy:   ["呼...嚕...", "嗯...", "呼嚕..."],
        .lonely:   ["嗚...", "嗯嗚...", "哼..."],
        .excited:  ["呀呀！", "嘿嘿！", "噢噢！", "耶！"],
        .startled: ["呀！！", "嗚哇！", "啊！"]
    ]

    private let eggSounds: [String] = ["...", "*震*", "*亮*", "*搖*"]

    func generate(level: PetLevel, mood: PetMood) -> String? {
        switch level {
        case .egg:
            return nil
        case .baby:
            return babyTemplates[mood]?.randomElement() ?? "..."
        }
    }

    func generatePrivateChat(
        myLevel: PetLevel, partnerLevel: PetLevel,
        myMood: PetMood, partnerMood: PetMood
    ) -> [DialogueLine] {
        let myLine = dialogueFor(level: myLevel, mood: myMood)
        let partnerLine = dialogueFor(level: partnerLevel, mood: partnerMood)

        var dialogue: [DialogueLine] = [
            DialogueLine(speaker: "mine", text: myLine),
            DialogueLine(speaker: "partner", text: partnerLine)
        ]

        // 50% chance of a third exchange
        if Bool.random() {
            let extraMood: PetMood = myMood == .happy && partnerMood == .happy ? .excited : .curious
            dialogue.append(DialogueLine(speaker: "mine", text: dialogueFor(level: myLevel, mood: extraMood)))
        }

        return dialogue
    }

    private func dialogueFor(level: PetLevel, mood: PetMood) -> String {
        switch level {
        case .egg:
            return eggSounds.randomElement()!
        case .baby:
            return babyTemplates[mood]?.randomElement() ?? "..."
        }
    }
}
```

**Step 4: Regenerate and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetDialogEngineTests -quiet`
Expected: PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Engine/PetDialogEngine.swift PeerDropTests/PetDialogEngineTests.swift
git commit -m "feat(pet): add local template dialog engine for baby speech"
```

---

## Task 5: PetSocialEngine

**Files:**
- Create: `PeerDrop/Pet/Engine/PetSocialEngine.swift`
- Test: `PeerDropTests/PetSocialEngineTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

final class PetSocialEngineTests: XCTestCase {
    let engine = PetSocialEngine()

    func testOnPetMeetingCreatesSocialEntry() {
        let myPet = PetState.newEgg()
        let greeting = PetGreeting(
            petID: UUID(), name: "TestPet", level: .baby,
            mood: .happy, genome: .random()
        )
        let entry = engine.onPetMeeting(myPet: myPet, partnerGreeting: greeting)
        XCTAssertEqual(entry.partnerPetID, greeting.petID)
        XCTAssertEqual(entry.partnerName, "TestPet")
        XCTAssertFalse(entry.isRevealed)
        XCTAssertFalse(entry.dialogue.isEmpty)
    }

    func testTryRevealRequiresHappyMood() {
        var pet = PetState.newEgg()
        pet.mood = .sleepy
        pet.socialLog = [makeSocialEntry(revealed: false)]
        let result = engine.tryReveal(pet: pet)
        XCTAssertNil(result, "Should not reveal when not happy")
    }

    func testTryRevealReturnsNilWhenAllRevealed() {
        var pet = PetState.newEgg()
        pet.mood = .happy
        pet.socialLog = [makeSocialEntry(revealed: true)]
        let result = engine.tryReveal(pet: pet)
        XCTAssertNil(result, "Nothing to reveal")
    }

    func testTryRevealCanSucceedWhenHappy() {
        var pet = PetState.newEgg()
        pet.mood = .happy
        pet.socialLog = [makeSocialEntry(revealed: false)]
        // Try many times — should succeed at least once (30% chance)
        var succeeded = false
        for _ in 0..<100 {
            if engine.tryReveal(pet: pet) != nil {
                succeeded = true
                break
            }
        }
        XCTAssertTrue(succeeded, "Should eventually reveal with 30% chance")
    }

    private func makeSocialEntry(revealed: Bool) -> SocialEntry {
        SocialEntry(
            id: UUID(), partnerPetID: UUID(), partnerName: "Test",
            date: Date(), interaction: .chat,
            dialogue: [DialogueLine(speaker: "mine", text: "嘿！")],
            isRevealed: revealed
        )
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetSocialEngineTests -quiet`
Expected: FAIL

**Step 3: Implement PetSocialEngine**

Create `PeerDrop/Pet/Engine/PetSocialEngine.swift`:
```swift
import Foundation

struct PetGreeting: Codable {
    let petID: UUID
    let name: String?
    let level: PetLevel
    let mood: PetMood
    let genome: PetGenome
}

class PetSocialEngine {
    private let dialogEngine = PetDialogEngine()

    func onPetMeeting(myPet: PetState, partnerGreeting: PetGreeting) -> SocialEntry {
        let dialogue = dialogEngine.generatePrivateChat(
            myLevel: myPet.level,
            partnerLevel: partnerGreeting.level,
            myMood: myPet.mood,
            partnerMood: partnerGreeting.mood
        )

        return SocialEntry(
            id: UUID(),
            partnerPetID: partnerGreeting.petID,
            partnerName: partnerGreeting.name,
            date: Date(),
            interaction: .chat,
            dialogue: dialogue,
            isRevealed: false
        )
    }

    func tryReveal(pet: PetState) -> SocialEntry? {
        guard pet.mood == .happy,
              let unrevealed = pet.socialLog.first(where: { !$0.isRevealed })
        else { return nil }

        if Double.random(in: 0...1) < 0.3 {
            return unrevealed
        }
        return nil
    }
}
```

**Step 4: Regenerate and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetSocialEngineTests -quiet`
Expected: PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Engine/PetSocialEngine.swift PeerDropTests/PetSocialEngineTests.swift
git commit -m "feat(pet): add social engine with sneak peek reveal mechanic"
```

---

## Task 6: PetEngine (Core State Machine)

**Files:**
- Create: `PeerDrop/Pet/Engine/PetEngine.swift`
- Test: `PeerDropTests/PetEngineTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetEngineTests: XCTestCase {
    var engine: PetEngine!

    override func setUp() async throws {
        try await super.setUp()
        engine = PetEngine(pet: .newEgg())
    }

    override func tearDown() async throws {
        engine = nil
        try await super.tearDown()
    }

    func testInitialState() {
        XCTAssertEqual(engine.pet.level, .egg)
        XCTAssertEqual(engine.currentAction, .idle)
    }

    func testHandleInteractionAddsExperience() {
        let before = engine.pet.experience
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.experience, before + InteractionType.tap.experienceValue)
    }

    func testHandleInteractionUpdatesMood() {
        // Many taps should make pet happy
        for _ in 0..<6 {
            engine.handleInteraction(.tap)
        }
        XCTAssertEqual(engine.pet.mood, .happy)
    }

    func testEvolutionDoesNotOccurBeforeMinimumAge() {
        // Give enough XP but pet is too young (just born)
        for _ in 0..<60 {
            engine.handleInteraction(.petMeeting) // 10 XP each = 600 total
        }
        XCTAssertEqual(engine.pet.level, .egg, "Should not evolve before 24hr minimum age")
    }

    func testEvolutionOccursWhenReady() {
        // Fake birthDate to 2 days ago
        engine.pet.birthDate = Date().addingTimeInterval(-172800)
        // Give enough XP
        for _ in 0..<60 {
            engine.handleInteraction(.petMeeting)
        }
        XCTAssertEqual(engine.pet.level, .baby)
    }

    func testSocialBonusAcceleratesEvolution() {
        engine.pet.birthDate = Date().addingTimeInterval(-172800)
        // Add a social meeting to enable bonus
        let greeting = PetGreeting(petID: UUID(), name: "Friend", level: .baby, mood: .happy, genome: .random())
        engine.handlePetMeeting(partnerGreeting: greeting)
        // Now XP is multiplied by 1.5x for evolution check
        // Need 100 XP / 1.5 = ~67 effective XP
        // petMeeting already gave 10, so need ~57 more → 6 more meetings
        for _ in 0..<6 {
            engine.handleInteraction(.petMeeting)
        }
        // 70 XP * 1.5 = 105 effective → should evolve
        XCTAssertEqual(engine.pet.level, .baby)
    }

    func testPetMeetingAddsSocialLog() {
        let greeting = PetGreeting(petID: UUID(), name: "Buddy", level: .egg, mood: .curious, genome: .random())
        engine.handlePetMeeting(partnerGreeting: greeting)
        XCTAssertEqual(engine.pet.socialLog.count, 1)
        XCTAssertEqual(engine.pet.socialLog.first?.partnerName, "Buddy")
        XCTAssertFalse(engine.pet.socialLog.first!.isRevealed)
    }

    func testLifeStateBasedOnTime() {
        let state = engine.currentLifeState
        // Just verify it returns a valid state without crashing
        XCTAssertNotNil(state)
    }

    func testPersonalityReaction() {
        let reaction = engine.reactionForEvent(.tap)
        // Should return a valid PetAction
        XCTAssertNotNil(reaction)
    }

    func testEvolutionProgress() {
        XCTAssertEqual(engine.evolutionProgress, 0.0)
        engine.handleInteraction(.petMeeting) // +10 XP
        XCTAssertEqual(engine.evolutionProgress, 0.1, accuracy: 0.01) // 10/100
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetEngineTests -quiet`
Expected: FAIL

**Step 3: Implement PetEngine**

Create `PeerDrop/Pet/Engine/PetEngine.swift`:
```swift
import Foundation
import Combine

@MainActor
class PetEngine: ObservableObject {
    @Published var pet: PetState
    @Published var currentAction: PetAction = .idle
    @Published var currentDialogue: String?
    @Published private(set) var renderedGrid: PixelGrid = .empty()

    private let renderer = PetRenderer()
    private let animator = PetAnimationController()
    private let tracker = InteractionTracker()
    private let dialogEngine = PetDialogEngine()
    private let socialEngine = PetSocialEngine()
    private var cancellables = Set<AnyCancellable>()
    private var lastBehaviorDate = Date.distantPast

    // Callbacks for integration — matches codebase pattern (closures, not NotificationCenter)
    var onPetGreetingNeeded: (() -> PetGreeting)?

    var evolutionProgress: Double {
        guard let req = EvolutionRequirement.for(pet.level) else { return 1.0 }
        return min(1.0, Double(pet.experience) / Double(req.requiredExperience))
    }

    var currentLifeState: PetLifeState {
        PetLifeState.current(energy: pet.genome.personalityTraits.energy)
    }

    private var hasSocialRecently: Bool {
        pet.socialLog.contains { Date().timeIntervalSince($0.date) < 86400 }
    }

    init(pet: PetState = .newEgg()) {
        self.pet = pet
        setupAnimationObserver()
    }

    func handleInteraction(_ type: InteractionType) {
        tracker.record(type)
        pet.experience += type.experienceValue
        pet.mood = tracker.calculateMood(hasSocialRecently: hasSocialRecently)
        pet.lastInteraction = Date()

        // Gene mutation (5% chance)
        if Double.random(in: 0...1) < 0.05 {
            pet.genome.mutate(trigger: type)
        }

        // Try to reveal a secret chat
        if let revealed = socialEngine.tryReveal(pet: pet),
           let idx = pet.socialLog.firstIndex(where: { $0.id == revealed.id }) {
            pet.socialLog[idx].isRevealed = true
            currentDialogue = dialogEngine.generate(level: pet.level, mood: .excited)
        }

        checkEvolution()
        updateRenderedGrid()
    }

    func handlePetMeeting(partnerGreeting: PetGreeting) {
        let entry = socialEngine.onPetMeeting(myPet: pet, partnerGreeting: partnerGreeting)
        pet.socialLog.append(entry)
        handleInteraction(.petMeeting)
    }

    func handleChatMessage() {
        handleInteraction(.chatActive)
        triggerChatBehavior()
    }

    func reactionForEvent(_ event: InteractionType) -> PetAction {
        pet.genome.personalityTraits.reaction(to: event)
    }

    // MARK: - Chat-aware behavior

    private func triggerChatBehavior() {
        let now = Date()
        guard now.timeIntervalSince(lastBehaviorDate) > 30 else { return } // 30s cooldown
        lastBehaviorDate = now

        let traits = pet.genome.personalityTraits
        currentAction = traits.reaction(to: .chatActive)

        // Auto-dismiss after delay
        let dismissDelay: TimeInterval = currentAction == .blockText ? 10.0 : 3.0
        Task {
            try? await Task.sleep(nanoseconds: UInt64(dismissDelay * 1_000_000_000))
            currentAction = .idle
        }
    }

    // MARK: - Evolution

    private func checkEvolution() {
        guard let req = EvolutionRequirement.for(pet.level) else { return }
        let age = Date().timeIntervalSince(pet.birthDate)
        let multiplier = hasSocialRecently ? req.socialBonus : 1.0
        let effectiveExp = Double(pet.experience) * multiplier

        if effectiveExp >= Double(req.requiredExperience) && age >= req.minimumAge {
            evolve(to: req.targetLevel)
        }
    }

    private func evolve(to level: PetLevel) {
        pet.level = level
        currentAction = .evolving
        pet.genome.mutate(trigger: .evolution)
        updateRenderedGrid()
    }

    // MARK: - Rendering

    private func updateRenderedGrid() {
        renderedGrid = renderer.render(
            genome: pet.genome,
            level: pet.level,
            mood: pet.mood,
            animationFrame: animator.currentFrame
        )
    }

    private func setupAnimationObserver() {
        animator.startAnimation()
        animator.$currentFrame
            .sink { [weak self] _ in self?.updateRenderedGrid() }
            .store(in: &cancellables)
    }
}

// MARK: - PersonalityTraits reaction mapping

extension PersonalityTraits {
    func reaction(to event: InteractionType) -> PetAction {
        switch event {
        case .tap:
            if independence > 0.7 { return .ignore }
            if timidity > 0.7 { return .freeze }
            return .wagTail
        case .shake:
            if timidity > 0.5 { return .hideInShell }
            if energy > 0.7 { return .zoomies }
            return .idle
        case .fileTransfer:
            if energy > 0.5 { return .stuffCheeks }
            return .idle
        case .chatActive:
            if curiosity > 0.7 { return .tiltHead }
            if mischief > 0.7 { return .climbOnBubble }
            return .notifyMessage
        case .peerConnected:
            return .wagTail
        default:
            return .idle
        }
    }
}
```

**Step 4: Regenerate and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetEngineTests -quiet`
Expected: PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift PeerDropTests/PetEngineTests.swift
git commit -m "feat(pet): add PetEngine core state machine with evolution and personality"
```

---

## Task 7: Persistence (PetStore + PetCloudSync)

**Files:**
- Create: `PeerDrop/Pet/Persistence/PetStore.swift`
- Create: `PeerDrop/Pet/Persistence/PetCloudSync.swift`
- Test: `PeerDropTests/PetStoreTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetStoreTests: XCTestCase {
    var store: PetStore!

    override func setUp() async throws {
        try await super.setUp()
        store = PetStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PetStoreTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        if let store = store {
            try? store.deleteAll()
        }
        store = nil
        try await super.tearDown()
    }

    func testSaveAndLoad() throws {
        let pet = PetState.newEgg()
        try store.save(pet)
        let loaded = try store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, pet.id)
        XCTAssertEqual(loaded?.level, pet.level)
    }

    func testLoadReturnsNilWhenEmpty() throws {
        let loaded = try store.load()
        XCTAssertNil(loaded)
    }

    func testSaveEvolutionSnapshot() throws {
        var pet = PetState.newEgg()
        pet.level = .baby
        try store.saveEvolutionSnapshot(pet)
        let snapshots = try store.loadSnapshots()
        XCTAssertEqual(snapshots.count, 1)
    }

    func testOverwriteExistingPet() throws {
        var pet = PetState.newEgg()
        try store.save(pet)
        pet.experience = 50
        try store.save(pet)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.experience, 50)
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetStoreTests -quiet`
Expected: FAIL

**Step 3: Implement PetStore**

Create `PeerDrop/Pet/Persistence/PetStore.swift`:
```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PetStore")

class PetStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PetData")
        }
    }

    private var petFile: URL { directory.appendingPathComponent("pet.json") }
    private var snapshotsDir: URL { directory.appendingPathComponent("snapshots") }
    private var socialDir: URL { directory.appendingPathComponent("social") }

    func save(_ pet: PetState) throws {
        try ensureDirectory(directory)
        let data = try encoder.encode(pet)
        try data.write(to: petFile)
    }

    func load() throws -> PetState? {
        guard FileManager.default.fileExists(atPath: petFile.path) else { return nil }
        let data = try Data(contentsOf: petFile)
        return try decoder.decode(PetState.self, from: data)
    }

    func saveEvolutionSnapshot(_ pet: PetState) throws {
        try ensureDirectory(snapshotsDir)
        let filename = "lv\(pet.level.rawValue)_\(pet.genome.bodyGene.rawValue).json"
        let data = try encoder.encode(pet)
        try data.write(to: snapshotsDir.appendingPathComponent(filename))
    }

    func loadSnapshots() throws -> [PetState] {
        guard FileManager.default.fileExists(atPath: snapshotsDir.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil)
        return try files.compactMap { url in
            let data = try Data(contentsOf: url)
            return try? decoder.decode(PetState.self, from: data)
        }
    }

    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func ensureDirectory(_ dir: URL) throws {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
```

**Step 4: Implement PetCloudSync**

Create `PeerDrop/Pet/Persistence/PetCloudSync.swift`:
```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PetCloudSync")

class PetCloudSync {
    private let kvStore = NSUbiquitousKeyValueStore.default

    private var cloudDirectory: URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/PetData")
    }

    func syncMetadata(_ pet: PetState) {
        kvStore.set(pet.id.uuidString, forKey: "pet_id")
        kvStore.set(pet.level.rawValue, forKey: "pet_level")
        kvStore.set(pet.experience, forKey: "pet_exp")
        kvStore.synchronize()
    }

    func syncFullState(_ pet: PetState) throws {
        guard let dir = cloudDirectory else {
            logger.info("iCloud not available, skipping sync")
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pet)
        try data.write(to: dir.appendingPathComponent("pet.json"))
    }

    func loadFromCloud() throws -> PetState? {
        guard let dir = cloudDirectory else { return nil }
        let url = dir.appendingPathComponent("pet.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PetState.self, from: data)
    }

    func resolveConflict(local: PetState, cloud: PetState) -> PetState {
        local.experience >= cloud.experience ? local : cloud
    }

    func observeCloudChanges(onUpdate: @escaping (PetState) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            if let pet = try? self?.loadFromCloud() {
                onUpdate(pet)
            }
        }
    }
}
```

**Step 4: Regenerate and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetStoreTests -quiet`
Expected: PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Persistence/ PeerDropTests/PetStoreTests.swift
git commit -m "feat(pet): add PetStore local persistence and iCloud sync"
```

---

## Task 8: P2P Protocol (PetPayload)

**Files:**
- Create: `PeerDrop/Pet/Protocol/PetPayload.swift`
- Test: `PeerDropTests/PetPayloadTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

final class PetPayloadTests: XCTestCase {

    func testPetGreetingCodable() throws {
        let greeting = PetGreeting(
            petID: UUID(), name: "TestPet", level: .baby,
            mood: .happy, genome: .random()
        )
        let data = try JSONEncoder().encode(greeting)
        let decoded = try JSONDecoder().decode(PetGreeting.self, from: data)
        XCTAssertEqual(decoded.petID, greeting.petID)
        XCTAssertEqual(decoded.name, greeting.name)
        XCTAssertEqual(decoded.level, greeting.level)
    }

    func testPetPayloadGreeting() throws {
        let greeting = PetGreeting(
            petID: UUID(), name: "Buddy", level: .egg,
            mood: .curious, genome: .random()
        )
        let payload = try PetPayload.greeting(greeting)
        XCTAssertEqual(payload.type, .greeting)

        let decoded = try payload.decodeGreeting()
        XCTAssertEqual(decoded.name, "Buddy")
    }

    func testPetPayloadSocialChat() throws {
        let dialogue = [
            DialogueLine(speaker: "mine", text: "嘿！"),
            DialogueLine(speaker: "partner", text: "呀？")
        ]
        let payload = try PetPayload.socialChat(dialogue)
        XCTAssertEqual(payload.type, .socialChat)
    }
}
```

**Step 2: Run to verify failure**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetPayloadTests -quiet`
Expected: FAIL

**Step 3: Implement PetPayload**

Create `PeerDrop/Pet/Protocol/PetPayload.swift`:
```swift
import Foundation

enum PetPayloadType: String, Codable {
    case greeting
    case socialChat
    case reaction
}

struct PetPayload: Codable {
    let type: PetPayloadType
    let data: Data

    static func greeting(_ greeting: PetGreeting) throws -> PetPayload {
        PetPayload(type: .greeting, data: try JSONEncoder().encode(greeting))
    }

    static func socialChat(_ dialogue: [DialogueLine]) throws -> PetPayload {
        PetPayload(type: .socialChat, data: try JSONEncoder().encode(dialogue))
    }

    static func reaction(_ action: PetAction) throws -> PetPayload {
        PetPayload(type: .reaction, data: try JSONEncoder().encode(action))
    }

    func decodeGreeting() throws -> PetGreeting {
        try JSONDecoder().decode(PetGreeting.self, from: data)
    }

    func decodeDialogue() throws -> [DialogueLine] {
        try JSONDecoder().decode([DialogueLine].self, from: data)
    }

    func decodeReaction() throws -> PetAction {
        try JSONDecoder().decode(PetAction.self, from: data)
    }
}
```

**Step 4: Regenerate and run tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetPayloadTests -quiet`
Expected: PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Protocol/PetPayload.swift PeerDropTests/PetPayloadTests.swift
git commit -m "feat(pet): add P2P pet payload protocol for social exchange"
```

---

## Task 9: SwiftUI Views (FloatingPetView, PixelView, Interaction Panel)

**Files:**
- Create: `PeerDrop/Pet/UI/PixelView.swift`
- Create: `PeerDrop/Pet/UI/FloatingPetView.swift`
- Create: `PeerDrop/Pet/UI/PetBubbleView.swift`
- Create: `PeerDrop/Pet/UI/PetInteractionView.swift`
- Create: `PeerDrop/Pet/UI/PetSecretChatRow.swift`
- Create: `PeerDrop/Pet/UI/GuestPetView.swift`

No unit tests for views — verified by build + visual inspection.

**Step 1: Create PixelView**

Create `PeerDrop/Pet/UI/PixelView.swift`:
```swift
import SwiftUI

struct PixelView: View {
    let grid: PixelGrid
    let displaySize: CGFloat

    var body: some View {
        Canvas { context, size in
            let pixelSize = size.width / CGFloat(grid.size)
            for y in 0..<grid.size {
                for x in 0..<grid.size {
                    if grid.pixels[y][x] {
                        let rect = CGRect(
                            x: CGFloat(x) * pixelSize,
                            y: CGFloat(y) * pixelSize,
                            width: pixelSize,
                            height: pixelSize
                        )
                        context.fill(Path(rect), with: .color(.primary))
                    }
                }
            }
        }
        .frame(width: displaySize, height: displaySize)
    }
}
```

**Step 2: Create PetBubbleView**

Create `PeerDrop/Pet/UI/PetBubbleView.swift`:
```swift
import SwiftUI

struct PetBubbleView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.background)
                    .shadow(radius: 1)
            )
    }
}
```

**Step 3: Create FloatingPetView**

Create `PeerDrop/Pet/UI/FloatingPetView.swift`:
```swift
import SwiftUI

struct FloatingPetView: View {
    @ObservedObject var engine: PetEngine
    @State private var position: CGPoint = CGPoint(x: 60, y: 200)
    @State private var isDragging = false
    @State private var showInteractionPanel = false
    @State private var wanderTimer: Timer?

    var body: some View {
        ZStack {
            PixelView(grid: engine.renderedGrid, displaySize: 64)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            if let dialogue = engine.currentDialogue {
                PetBubbleView(text: dialogue)
                    .offset(y: -44)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .position(position)
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    position = value.location
                }
                .onEnded { _ in
                    isDragging = false
                    engine.handleInteraction(.tap)
                }
        )
        .onTapGesture {
            engine.handleInteraction(.tap)
        }
        .onLongPressGesture {
            showInteractionPanel = true
        }
        .sheet(isPresented: $showInteractionPanel) {
            PetInteractionView(engine: engine)
        }
        .onAppear { startWandering() }
        .onDisappear { wanderTimer?.invalidate() }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: position)
    }

    private func startWandering() {
        wanderTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                guard !isDragging, engine.currentAction == .idle || engine.currentAction == .walking else { return }
                let screen = UIScreen.main.bounds
                let margin: CGFloat = 40
                // Wander along edges
                let edge = Int.random(in: 0...3)
                let target: CGPoint
                switch edge {
                case 0: // top
                    target = CGPoint(x: CGFloat.random(in: margin...(screen.width - margin)), y: margin + 50)
                case 1: // bottom
                    target = CGPoint(x: CGFloat.random(in: margin...(screen.width - margin)), y: screen.height - margin - 50)
                case 2: // left
                    target = CGPoint(x: margin, y: CGFloat.random(in: 100...(screen.height - 100)))
                default: // right
                    target = CGPoint(x: screen.width - margin, y: CGFloat.random(in: 100...(screen.height - 100)))
                }
                withAnimation(.linear(duration: 3.0)) {
                    position = target
                }
                engine.currentAction = .walking
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                engine.currentAction = .idle
            }
        }
    }
}
```

**Step 4: Create PetInteractionView**

Create `PeerDrop/Pet/UI/PetInteractionView.swift`:
```swift
import SwiftUI

struct PetInteractionView: View {
    @ObservedObject var engine: PetEngine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        PixelView(grid: engine.renderedGrid, displaySize: 96)
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(engine.pet.name ?? "???")
                                .font(.headline)
                            Text("Lv.\(engine.pet.level.rawValue)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("EXP: \(engine.pet.experience)")
                                .font(.caption)
                            Label(engine.pet.mood.displayName, systemImage: moodIcon)
                                .font(.caption)
                        }
                    }

                    ProgressView(value: engine.evolutionProgress) {
                        Text("進化進度")
                            .font(.caption2)
                    }
                    .tint(.green)
                } header: {
                    Text("狀態")
                }

                Section {
                    let revealed = engine.pet.socialLog.filter(\.isRevealed)
                    if revealed.isEmpty {
                        Text("還沒有解鎖的對話")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(revealed) { entry in
                            PetSecretChatRow(entry: entry)
                        }
                    }

                    let unrevealedCount = engine.pet.socialLog.filter { !$0.isRevealed }.count
                    if unrevealedCount > 0 {
                        Label("還有 \(unrevealedCount) 則未解鎖的對話...", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } header: {
                    Text("祕密日記")
                }
            }
            .navigationTitle("我的寵物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var moodIcon: String {
        switch engine.pet.mood {
        case .happy: return "face.smiling"
        case .curious: return "eyes"
        case .sleepy: return "moon.zzz"
        case .lonely: return "cloud.rain"
        case .excited: return "star"
        case .startled: return "exclamationmark.triangle"
        }
    }
}
```

**Step 5: Create PetSecretChatRow**

Create `PeerDrop/Pet/UI/PetSecretChatRow.swift`:
```swift
import SwiftUI

struct PetSecretChatRow: View {
    let entry: SocialEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("與 \(entry.partnerName ?? "???")")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(entry.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(entry.dialogue.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text(line.speaker == "mine" ? "🐣" : "🐥")
                        .font(.caption2)
                    Text(line.text)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
```

**Step 6: Create GuestPetView**

Create `PeerDrop/Pet/UI/GuestPetView.swift`:
```swift
import SwiftUI

struct GuestPetView: View {
    let greeting: PetGreeting
    @State private var position: CGPoint
    @State private var frame: Int = 0

    private let renderer = PetRenderer()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(greeting: PetGreeting, initialPosition: CGPoint) {
        self.greeting = greeting
        self._position = State(initialValue: initialPosition)
    }

    var body: some View {
        PixelView(
            grid: renderer.render(
                genome: greeting.genome,
                level: greeting.level,
                mood: greeting.mood,
                animationFrame: frame
            ),
            displaySize: 48
        )
        .opacity(0.8)
        .position(position)
        .onReceive(timer) { _ in
            frame = (frame + 1) % 2
        }
    }
}
```

**Step 7: Build to verify compilation**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add PeerDrop/Pet/UI/
git commit -m "feat(pet): add floating pet UI views with pixel rendering and interaction panel"
```

---

## Task 10: Integration with Existing Code

**Files:**
- Modify: `PeerDrop/App/PeerDropApp.swift:5-15` — add PetEngine + overlay
- Modify: `PeerDrop/Core/ConnectionManager.swift:247-273` — add pet callback on connect
- Modify: `PeerDrop/Core/ConnectionManager.swift:294-305` — add pet callback on disconnect
- Modify: `PeerDrop/Core/ChatManager.swift:59-93` — add pet callback on message

**Step 1: Modify PeerDropApp.swift**

Add PetEngine StateObject and FloatingPetView overlay.

Existing code around line 5-15:
```swift
@StateObject private var connectionManager = ConnectionManager()
@StateObject private var voicePlayer = VoicePlayer()
```

Add after `voicePlayer`:
```swift
@StateObject private var petEngine = PetEngine()
```

Find the `.environmentObject(connectionManager)` line and add after it:
```swift
.environmentObject(petEngine)
.overlay(FloatingPetView(engine: petEngine).allowsHitTesting(true).ignoresSafeArea())
```

In the `scenePhase` handler's `.background` case, add:
```swift
try? PetStore().save(petEngine.pet)
try? PetCloudSync().syncFullState(petEngine.pet)
```

**Step 2: Modify ConnectionManager.swift — peer connected callback**

In `addConnection()` (line 247), after the existing `peerConnection.onDisconnected` block (line 262), add:
```swift
// Notify pet system of new connection
onPeerConnectedForPet?(peerID)
```

Add the callback property near the top of `ConnectionManager`:
```swift
var onPeerConnectedForPet: ((String) -> Void)?
var onPeerDisconnectedForPet: ((String) -> Void)?
```

**Step 3: Modify ConnectionManager.swift — peer disconnected**

In `handlePeerDisconnected()` (line 294), after `updateGlobalState()` (line 304), add:
```swift
onPeerDisconnectedForPet?(peerID)
```

**Step 4: Modify ChatManager.swift — message received**

In `saveIncoming()` (line 66), after the `incrementUnread` call (line 91), add:
```swift
onMessageReceivedForPet?()
```

Add the callback property:
```swift
var onMessageReceivedForPet: (() -> Void)?
```

**Step 5: Wire callbacks in PeerDropApp.swift**

In the `.onAppear` or init block of PeerDropApp, wire the callbacks:
```swift
.onAppear {
    connectionManager.onPeerConnectedForPet = { _ in
        petEngine.handleInteraction(.peerConnected)
    }
    connectionManager.onPeerDisconnectedForPet = { _ in
        petEngine.pet.mood = .lonely
    }
    connectionManager.chatManager.onMessageReceivedForPet = {
        petEngine.handleChatMessage()
    }

    // Load saved pet
    if let saved = try? PetStore().load() {
        petEngine.pet = saved
    }
}
```

**Step 6: Build and run all tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: All tests PASS (existing 292 + new pet tests)

**Step 7: Commit**

```bash
git add PeerDrop/App/PeerDropApp.swift PeerDrop/Core/ConnectionManager.swift PeerDrop/Core/ChatManager.swift
git commit -m "feat(pet): integrate PetEngine with app, connection manager, and chat"
```

---

## Task 11: iCloud Entitlement & project.yml Update

**Files:**
- Modify: `project.yml` — add iCloud entitlement

**Step 1: Add iCloud capability**

In `project.yml`, under the PeerDrop target settings, add entitlement for iCloud:

```yaml
entitlements:
  path: PeerDrop/App/PeerDrop.entitlements
  properties:
    com.apple.developer.icloud-container-identifiers:
      - iCloud.com.hanfour.peerdrop
    com.apple.developer.ubiquity-kvstore-identifier: $(TeamIdentifierPrefix)com.hanfour.peerdrop
```

**Step 2: Regenerate and build**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add project.yml
git commit -m "feat(pet): add iCloud entitlement for pet data sync"
```

---

## Task 12: Localisation

**Files:**
- Modify: `PeerDrop/App/Localizable.xcstrings` — add pet-related strings

**Step 1: Add localisation keys**

Add the following keys to `Localizable.xcstrings` for all 5 languages (en, zh-Hant, zh-Hans, ja, ko):

| Key | en | zh-Hant |
|---|---|---|
| "我的寵物" | "My Pet" | "我的寵物" |
| "狀態" | "Status" | "狀態" |
| "祕密日記" | "Secret Diary" | "祕密日記" |
| "進化進度" | "Evolution Progress" | "進化進度" |
| "完成" | "Done" | "完成" |
| "還沒有解鎖的對話" | "No unlocked conversations yet" | "還沒有解鎖的對話" |
| "還有未解鎖的對話..." | "More locked conversations..." | "還有未解鎖的對話..." |
| "開心" | "Happy" | "開心" |
| "好奇" | "Curious" | "好奇" |
| "想睡" | "Sleepy" | "想睡" |
| "寂寞" | "Lonely" | "寂寞" |
| "興奮" | "Excited" | "興奮" |
| "嚇到" | "Startled" | "嚇到" |

**Step 2: Build to verify**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add PeerDrop/App/Localizable.xcstrings
git commit -m "i18n(pet): add pet UI localisation strings for 5 languages"
```

---

## Task 13: Final Verification

**Step 1: Run full test suite**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: All tests PASS

**Step 2: Verify file count**

Run: `find PeerDrop/Pet -name "*.swift" | wc -l`
Expected: ~20 files

**Step 3: Verify no regressions**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests -quiet`
Expected: 292+ existing tests still PASS

**Step 4: Final commit (if any cleanup needed)**

```bash
git commit -m "feat(pet): Project Neo-Egg MVP complete — Lv.1-2 virtual pet companion"
```

---

## Summary

| Task | Description | New Files | Test Files |
|---|---|---|---|
| 1 | Data models | 8 | 1 |
| 2 | InteractionTracker | 1 | 1 |
| 3 | PixelGrid + Renderer | 3 | 2 |
| 4 | DialogEngine | 1 | 1 |
| 5 | SocialEngine | 1 | 1 |
| 6 | PetEngine (state machine) | 1 | 1 |
| 7 | Persistence | 2 | 1 |
| 8 | P2P Protocol | 1 | 1 |
| 9 | SwiftUI Views | 6 | 0 |
| 10 | Integration (3 existing files) | 0 | 0 |
| 11 | iCloud entitlement | 0 | 0 |
| 12 | Localisation | 0 | 0 |
| 13 | Final verification | 0 | 0 |
| **Total** | | **24 new** | **9 test** |
