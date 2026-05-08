# v5 Multi-Frame Sprite Animation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace v4's static-PNG-per-direction sprite system with multi-frame walk + idle animations across all 33 species × 3 stages, killing the "paws sliding" architectural limitation.

**Architecture:** Per design doc `2026-05-08-v5-multi-frame-sprite-design.md` (commit `7f00910`): zip layout extended with `animations/walk/` + `animations/idle/`; `PetRendererV3` → `PetRendererV4` with `action`+`frameIndex` params; `SpriteService` caches `CGImage[]` arrays per (species, stage, dir, action); inert `PetAnimationController` finally wired into `PetEngine.tick()` via Combine `@Published currentFrame`.

**Tech Stack:** Swift 5.9, SwiftUI, Combine, XCTest, ZIPFoundation, fastlane, PixelLab Pixel Apprentice tier.

**Files affected (overview):**
- 3 model: `PetAction.swift` (semantic tightening), `Direction.swift` (no-op), spritezip metadata schema
- 5 renderer/engine: `SpriteService.swift`, `SpriteAssetResolver.swift`, `PetRendererV3.swift` (renamed), `PetAnimationController.swift`, `PetEngine.swift`
- 1 UI: `FloatingPetView.swift` (re-render on `currentFrame` change)
- 1 new view: `V5UpgradeOnboardingView.swift`
- 324 asset zips (regenerated via PixelLab)
- 1 xcstrings update (~5 lang × 4 keys)
- 5 fastlane release notes
- project.yml version bump 4.0.x → 5.0.0

**Reference docs:**
- @ docs/plans/2026-05-08-v5-multi-frame-sprite-design.md (the design)
- @ docs/release/v4.0.2-reviewer-notes.md (template for v5.0)
- @ docs/pet-design/ai-brief/STATUS.md (PixelLab subscription state, character ID conventions)
- @ MEMORY.md (project memory; update post-ship)

---

## Phase 0 — Pre-flight gate (CRITICAL, ~2 days)

This phase has only ONE task and is a HARD gate. Do not proceed to Phase 1 until passed.

### Task 0.1: Verify PixelLab supports animation generation

**Files:** none (manual operator work)

**Steps:**

1. Log into PixelLab Pixel Apprentice account.
2. Open an existing v4 character (e.g. `cat-tabby-adult`) by character ID from `metadata.json`.
3. Look for "Animation" / "Add walk cycle" / similar UI affordances.
4. Generate a single test character WITH animation:
   - Skeleton: Cat
   - Animation: walk + idle (or whichever names PixelLab uses)
   - Frame count: 8 walk + 4 idle if available
5. Export the character as ZIP.
6. Inspect: `unzip -l test-anim.zip` should show animation/walk/<dir>_<frame>.png entries.
7. Open `metadata.json` from the zip; verify `frames.animations` has populated `walk` + `idle` keys.

**Decision gate:**

- ✅ **PixelLab supports it natively** → proceed to Phase 1 with All-in plan unchanged.
- ❌ **PixelLab does NOT support animation gen** → fall back per design doc Section 2 "Fallback if PixelLab fails":
  - Plan B: ImageMagick post-process — translate `rotations/east.png` ±2 px between frames; cheap walk cycle
  - Plan C: Downscope to B-standard (6 walk + 3 idle) which may be more tractable
  - Update design doc with chosen fallback before proceeding to Phase 1.

**Commit (only if pass):**

```bash
git commit --allow-empty -m "gate(v5): PixelLab animation generation verified

PixelLab Pixel Apprentice tier confirmed to support animation
frame generation per character (walk + idle, 8 + 4 frames × 8
directions). Test character exported successfully with populated
metadata.json frames.animations block.

Phase 0 gate passed. Proceeding to Phase 1 (code foundations).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1 — Code foundations (no assets yet, ~3 days)

Build the renderer + animator infrastructure first. Tests use synthetic test fixtures (small hand-crafted v3.0 metadata zips). Real assets land in Phase 3.

### Task 1.1: Failing test — metadata v3.0 schema parser

**Files:**
- Create: `PeerDropTests/Pet/MetadataV3SchemaTests.swift`
- Test fixture: `PeerDropTests/Resources/Pets/test-anim-v3.zip` (hand-craft, small)

**Step 1: Hand-craft test fixture**

Create `test-anim-v3.zip` with:
- `rotations/south.png` (any 8×8 black PNG)
- `animations/walk/south_001.png` … `south_008.png` (any tiny PNGs)
- `animations/idle/south_001.png` … `south_004.png`
- `metadata.json`:

```json
{
  "character": { "id": "test-anim", "name": "test", "size": {"width": 8, "height": 8}, "directions": 8 },
  "frames": {
    "rotations": { "south": "rotations/south.png" },
    "animations": {
      "walk": { "fps": 6, "frame_count": 8, "loops": true,
        "directions": { "south": ["animations/walk/south_001.png", "animations/walk/south_002.png", "animations/walk/south_003.png", "animations/walk/south_004.png", "animations/walk/south_005.png", "animations/walk/south_006.png", "animations/walk/south_007.png", "animations/walk/south_008.png"] } },
      "idle": { "fps": 2, "frame_count": 4, "loops": true,
        "directions": { "south": ["animations/idle/south_001.png", "animations/idle/south_002.png", "animations/idle/south_003.png", "animations/idle/south_004.png"] } }
    }
  },
  "export_version": "3.0",
  "v5_compatible": true
}
```

**Step 2: Add failing tests**

```swift
import XCTest
@testable import PeerDrop

final class MetadataV3SchemaTests: XCTestCase {
    func test_parseV3Metadata_returnsAnimationDescriptors() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "test-anim-v3", withExtension: "zip")!
        let metadata = try SpriteMetadata.parse(zipURL: url)
        XCTAssertEqual(metadata.exportVersion, "3.0")
        XCTAssertNotNil(metadata.animations["walk"])
        XCTAssertEqual(metadata.animations["walk"]?.fps, 6)
        XCTAssertEqual(metadata.animations["walk"]?.frameCount, 8)
        XCTAssertEqual(metadata.animations["idle"]?.frameCount, 4)
    }

    func test_parseV2Metadata_returnsEmptyAnimations() throws {
        // Existing v4 zip with export_version "2.0" should parse without error,
        // animations dict empty
        let url = Bundle(for: type(of: self)).url(forResource: "cat-tabby-adult", withExtension: "zip")!
        let metadata = try SpriteMetadata.parse(zipURL: url)
        XCTAssertEqual(metadata.exportVersion, "2.0")
        XCTAssertTrue(metadata.animations.isEmpty)
    }
}
```

**Step 3: Verify failure**

`xcodebuild test ... -only-testing:PeerDropTests/MetadataV3SchemaTests` → expect compile fail (no `SpriteMetadata` type).

### Task 1.2: Implement `SpriteMetadata` parser

**Files:**
- Create: `PeerDrop/Pet/Sprites/SpriteMetadata.swift`

```swift
import Foundation
import ZIPFoundation

struct SpriteMetadata {
    let exportVersion: String
    let rotations: [String: String]                         // direction → relative path
    let animations: [String: AnimationDescriptor]            // "walk", "idle" → desc

    struct AnimationDescriptor {
        let fps: Int
        let frameCount: Int
        let loops: Bool
        let directions: [String: [String]]                   // direction → frame paths
    }

    static func parse(zipURL: URL) throws -> SpriteMetadata {
        let archive = try Archive(url: zipURL, accessMode: .read)
        guard let entry = archive["metadata.json"] else {
            throw SpriteMetadataError.metadataMissing
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return try JSONDecoder().decode(RawV3Metadata.self, from: data).toSpriteMetadata()
    }
}

private struct RawV3Metadata: Decodable {
    let frames: Frames
    let export_version: String

    struct Frames: Decodable {
        let rotations: [String: String]
        let animations: [String: AnimDesc]?
    }

    struct AnimDesc: Decodable {
        let fps: Int
        let frame_count: Int
        let loops: Bool
        let directions: [String: [String]]
    }

    func toSpriteMetadata() -> SpriteMetadata {
        let animMap: [String: SpriteMetadata.AnimationDescriptor] =
            (frames.animations ?? [:]).mapValues { ad in
                .init(fps: ad.fps, frameCount: ad.frame_count, loops: ad.loops, directions: ad.directions)
            }
        return SpriteMetadata(
            exportVersion: export_version,
            rotations: frames.rotations,
            animations: animMap
        )
    }
}

enum SpriteMetadataError: Error {
    case metadataMissing
}
```

**Step 4-5: Run tests, verify pass, commit**

```bash
xcodebuild test ... -only-testing:PeerDropTests/MetadataV3SchemaTests
git add PeerDrop/Pet/Sprites/SpriteMetadata.swift PeerDropTests/Pet/MetadataV3SchemaTests.swift PeerDropTests/Resources/Pets/test-anim-v3.zip
git commit -m "feat(pet): SpriteMetadata parser supports v3.0 animation schema

Phase 1 of v5 multi-frame sprite implementation.
- SpriteMetadata struct + parse(zipURL:) API
- Decodes rotations + animations (walk, idle) + fps + frame_count
- Backward compat: v2.0 zips parse with empty animations dict
- Test fixture test-anim-v3.zip hand-crafted (8×8 PNGs)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 1.3: Failing test — SpriteService cache for animation frames

**Files:**
- Create: `PeerDropTests/Pet/SpriteServiceAnimationTests.swift`

```swift
final class SpriteServiceAnimationTests: XCTestCase {
    func test_decode_v3Zip_cachesAllFramesPerActionDirection() async throws {
        let service = SpriteService.shared
        let species = SpeciesID("test-anim")
        // Pre-load the test-anim-v3 zip
        let frames = try await service.frames(for: SpriteRequest(
            species: species, stage: .baby, direction: .south, action: .walk
        ))
        XCTAssertEqual(frames.images.count, 8, "walk has 8 frames")
        XCTAssertEqual(frames.fps, 6)
    }

    func test_decode_v2Zip_returnsRotationAsSingleFrame() async throws {
        let service = SpriteService.shared
        let species = SpeciesID("cat-tabby")
        let frames = try await service.frames(for: SpriteRequest(
            species: species, stage: .adult, direction: .south, action: .idle
        ))
        XCTAssertEqual(frames.images.count, 1, "v2 zip has no animations; treated as single-frame static")
        XCTAssertEqual(frames.fps, 1)
    }
}
```

**Step 2: Verify failure**

`SpriteService.frames(for:)` returns `AnimationFrames`, not yet defined. Expect compile fail.

### Task 1.4: Extend `SpriteService` with `frames(for:)` API

**Files:**
- Modify: `PeerDrop/Pet/Sprites/SpriteService.swift`

Add type:

```swift
struct AnimationFrames {
    let images: [CGImage]
    let fps: Int
    let loops: Bool
}
```

Extend the actor:

```swift
extension SpriteService {
    func frames(for request: SpriteRequest) async throws -> AnimationFrames {
        let key = AnimationCacheKey(species: request.species, stage: request.stage,
                                     direction: request.direction, action: request.action)
        if let cached = animCache[key] { return cached }

        let zipURL = try assetURL(for: request)
        let metadata = try SpriteMetadata.parse(zipURL: zipURL)

        if metadata.exportVersion == "3.0", let anim = metadata.animations[request.action.rawValue] {
            let dirKey = request.direction.rawValue
            guard let paths = anim.directions[dirKey] else {
                throw SpriteServiceError.directionMissing(dirKey)
            }
            let images = try paths.map { try decodePNG(in: zipURL, at: $0) }
            let frames = AnimationFrames(images: images, fps: anim.fps, loops: anim.loops)
            animCache[key] = frames
            return frames
        }

        // v2 fallback: single-frame from rotations/<dir>.png
        let dirKey = request.direction.rawValue
        guard let path = metadata.rotations[dirKey] else {
            throw SpriteServiceError.directionMissing(dirKey)
        }
        let image = try decodePNG(in: zipURL, at: path)
        let frames = AnimationFrames(images: [image], fps: 1, loops: false)
        animCache[key] = frames
        return frames
    }

    // LRU eviction at 5-species cap
    private func evictIfNeeded() {
        let speciesCount = Set(animCache.keys.map(\.species)).count
        if speciesCount > 5 {
            // Remove oldest insertion (use ordered dict in production)
        }
    }
}

private struct AnimationCacheKey: Hashable {
    let species: SpeciesID
    let stage: PetLevel
    let direction: Direction
    let action: PetAction
}
```

Adapt to actual SpriteService structure when reading.

**Step 4-5: Run tests, verify pass, commit**

```bash
git add PeerDrop/Pet/Sprites/SpriteService.swift PeerDropTests/Pet/SpriteServiceAnimationTests.swift
git commit -m "feat(pet): SpriteService.frames(for:) caches multi-frame animations

Phase 1.3-1.4. Returns AnimationFrames (CGImage[] + fps + loops).
v3.0 zips: decode all frames per (species, stage, dir, action).
v2 zips: rotations/<dir>.png treated as 1-frame static (graceful degrade).
LRU evict at 5-species cap (~14 MB peak in-memory).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 1.5: PetRendererV4 with frame parameters

**Files:**
- Modify (rename internally): `PeerDrop/Pet/Renderer/PetRendererV3.swift` → keep file name; change class name to `PetRendererV4` OR add `render(action:frameIndex:)` overload to PetRendererV3.

Decision: keep file name `PetRendererV3.swift` but add a new method signature. The old method delegates with default `.idle, 0`.

```swift
class PetRendererV3 {  // file/class kept; v4 is a semantic rename in code comments + docs
    /// v5: render with action + frameIndex
    func render(species: SpeciesID, stage: PetLevel, direction: Direction,
                action: PetAction, frameIndex: Int, mood: PetMood) -> CGImage? {
        let request = SpriteRequest(species: species, stage: stage, direction: direction, action: action)
        do {
            let frames = try await service.frames(for: request)   // synchronous lookup if cached
            let safeIndex = frames.images.indices.contains(frameIndex) ? frameIndex : 0
            let base = frames.images[safeIndex]
            return composite(base: base, mood: mood)
        } catch {
            return ultimateFallbackImage()
        }
    }

    /// Legacy v4 entry point — defaults action to idle, frame 0
    func render(species: SpeciesID, stage: PetLevel, direction: Direction, mood: PetMood) -> CGImage? {
        render(species: species, stage: stage, direction: direction, action: .idle, frameIndex: 0, mood: mood)
    }
}
```

Note: actor cross calls — the existing `PetRendererV3` is `@MainActor`; `SpriteService.frames` is async actor. Renderer needs to either be async or pre-cache frames. Choose: pre-cache before render (engine triggers `service.preload(species:)` on PetEngine init). Renderer's `render(...)` becomes synchronous against the cache.

**Tests:** add `PetRendererV4Tests.swift` (or extend existing `PetRendererV3Tests`) for new signature + frame index wrapping.

**Commit:**

```bash
git commit -m "feat(pet): PetRendererV3 gains action+frameIndex API (v5)

Backward-compat: existing render(species,stage,direction,mood:)
delegates to new entry with .idle action + frame 0. Frame index
wraps to 0 if out of bounds. Pre-cache via SpriteService.preload(...)
expected by caller; renderer itself stays synchronous against cache."
```

### Task 1.6: PetAnimationController production wiring

**Files:**
- Modify: `PeerDrop/Pet/Renderer/PetAnimationController.swift` (or wherever it lives)

Replace the inert class with the wired version per design Section 3:

```swift
@MainActor
final class PetAnimationController: ObservableObject {
    @Published private(set) var currentFrame: Int = 0
    private(set) var currentAction: PetAction = .idle
    private var frameCount: Int = 4
    private var fps: Int = 2
    private var timer: Timer?

    func setAction(_ action: PetAction, frameCount: Int, fps: Int) {
        guard action != currentAction else { return }
        self.currentAction = action
        self.frameCount = max(frameCount, 1)
        self.fps = max(fps, 1)
        self.currentFrame = 0
        restartTimer()
    }

    func pause() { timer?.invalidate(); timer = nil }
    func resume() { restartTimer() }

    private func restartTimer() {
        timer?.invalidate()
        let interval = 1.0 / Double(fps)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentFrame = (self.currentFrame + 1) % self.frameCount
        }
    }
}
```

**Tests:** extend `PetAnimationControllerTests`:

```swift
func test_setAction_changesActionAndResetsFrame() { /* ... */ }
func test_setAction_sameAction_noOp() { /* ... */ }
func test_currentFrame_advancesAtFPSRate() async { /* ... use Combine to await */ }
func test_pause_haltsFrameAdvance() { /* ... */ }
```

**Commit:**

```bash
git commit -m "feat(pet): PetAnimationController wired for production use

Phase 1.6. setAction(action:frameCount:fps:) deduplicates same-action
calls (preserves frame index). pause/resume for app background.
Timer-driven; @Published currentFrame for SwiftUI observation.
Tests verify timer firing rate, dedup, pause behavior."
```

### Task 1.7: PetEngine action selection

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`

In `tick(...)`:

```swift
let velocity = physicsState.velocity
let speed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
let walkThreshold: Double = 5.0  // tune; px/sec

let nextAction: PetAction = (speed > walkThreshold) ? .walk : .idle

if nextAction != animator.currentAction {
    Task {
        let metadata = try? await SpriteService.shared.metadata(for: pet.species, stage: pet.level)
        let anim = metadata?.animations[nextAction.rawValue]
        animator.setAction(nextAction,
                           frameCount: anim?.frameCount ?? 1,
                           fps: anim?.fps ?? 1)
    }
}
```

Add `animator: PetAnimationController` property to PetEngine. Subscribe to `animator.$currentFrame` via Combine; on each emit, call `updateRenderedImage(...)`.

**Tests:** integration test in PetEngine — inject high velocity → animator goes to .walk; zero velocity → .idle.

**Commit:**

```bash
git commit -m "feat(pet): PetEngine drives PetAnimationController from velocity

Phase 1.7. Engine.tick() derives action from physics velocity
magnitude (walkThreshold = 5 px/s; tune later). Animator setAction
on transition, with frame_count/fps from metadata. Combine
subscription on animator.$currentFrame triggers re-render."
```

---

## Phase 2 — End-to-end integration with first asset (~2 days)

After Phase 1 lands, the code can render multi-frame animations IF a v3 zip is bundled. This phase generates ONE real zip via PixelLab and verifies the full pipeline.

### Task 2.1: Generate cat-tabby-adult v5 zip via PixelLab

**Files:** `PeerDrop/Resources/Pets/cat-tabby-adult.zip` (replace v4)

**Operator steps:**
1. Open PixelLab
2. Load existing cat-tabby-adult character by ID (from old metadata.json)
3. Add walk animation: 8 frames, 8 directions
4. Add idle animation: 4 frames, 8 directions
5. Export ZIP
6. Replace `PeerDrop/Resources/Pets/cat-tabby-adult.zip`

### Task 2.2: Manual smoke — cat-tabby walks in simulator

Build + run on iPhone 16 simulator. Force pet species = cat-tabby (debug flag or seed). Move pet. Observe walk animation in 1.3s cycle.

**If broken:** debug. Possible issues — direction enum naming mismatch with metadata; frame index not wrapping; SwiftUI Image not refreshing on `@Published` change.

### Task 2.3: Performance check

Profile with Instruments: render time per frame, memory growth from cache.

Target: render call < 5ms; memory < 10 MB per active species.

**Commit (sanity gate, not full feature):**

```bash
git add PeerDrop/Resources/Pets/cat-tabby-adult.zip
git commit -m "feat(pet): first v5 asset — cat-tabby-adult animated

Phase 2 sanity gate. Bundled v5-format ZIP; walk + idle visible
in simulator with new pipeline. Render perf under 5 ms; memory
under 10 MB. Confirms Phase 1 code wires end-to-end."
```

---

## Phase 3 — Mass asset gen sprint (~10 days, mostly operator)

Generate the remaining 323 zips. This is operator-driven; not bite-sized code tasks.

Per design doc Section 2 sprint structure:
- Days 8–12 (Week 2): ~150-200 zips at ~8/day
- Day 13: bulk visual review
- Day 14: retries
- Days 15-18 (Week 3): remaining ~120-150 + retries

**Per-batch operator protocol:**
- Generate species (e.g. dog × 5 breeds × 3 stages = 15 zips)
- Drop into `PeerDrop/Resources/Pets/`
- Quick smoke: build + verify no missing-asset warnings
- Commit per species batch:

```bash
git add PeerDrop/Resources/Pets/dog-*.zip
git commit -m "asset(v5): dog × 5 breeds × 3 stages animated (15 zips)

PixelLab batch N — dog (shiba/collie/dachshund/labrador/husky)
walk + idle frames generated. Identity drift checks: all 15 read
clearly as dogs."
```

Scope: **all 324 zips ultimately must have v5 metadata + animation frames** before Phase 4 starts.

---

## Phase 4 — Bundle verification + asset coverage tests (~1 day)

### Task 4.1: Asset coverage test passes for all species

**Files:**
- Modify: `PeerDropTests/Pet/MainBundleAssetCoverageTests.swift`

Replace v4's `test_mainBundle_fullCoverage_forEveryMultiVarietySpecies` with v5 version that asserts:

```swift
func test_mainBundle_v5_everyZip_hasV3Metadata_with_walk_and_idle() throws {
    let species = SpeciesCatalog.allIDs
    for s in species {
        for stage in PetLevel.allCases {
            let zipURL = bundleURL(for: s, stage: stage)
            let metadata = try SpriteMetadata.parse(zipURL: zipURL)
            XCTAssertEqual(metadata.exportVersion, "3.0",
                          "\(s)-\(stage) must be v3.0 metadata")
            XCTAssertNotNil(metadata.animations["walk"], "missing walk: \(s)-\(stage)")
            XCTAssertNotNil(metadata.animations["idle"], "missing idle: \(s)-\(stage)")
        }
    }
}
```

Adapt for single-stage species (ghost). After Phase 3 all zips are v5; this test passes.

### Task 4.2: Bundle size verification

```bash
du -sh PeerDrop/Resources/Pets/   # expect < 50 MB
```

Add a script `Scripts/verify-bundle-size.sh` to CI gate.

### Task 4.3: Commit Phase 4

```bash
git commit -m "test(pet): v5 asset coverage suite — every zip has walk + idle

Phase 4. Replaces v4 single-frame coverage test with v3.0-metadata
+ animation block presence asserts. Bundle size verified < 50 MB."
```

---

## Phase 5 — V5UpgradeOnboardingView (~2 days)

### Task 5.1: Failing test — V5UpgradeOnboardingView gate

**Files:**
- Create: `PeerDropTests/Pet/V5UpgradeOnboardingTests.swift`

```swift
func test_v5UpgradeShown_gateDefaultsFalse_thenSetsTrue() {
    UserDefaults.standard.removeObject(forKey: "v5UpgradeShown")
    XCTAssertFalse(UserDefaults.standard.bool(forKey: "v5UpgradeShown"))
    UserDefaults.standard.set(true, forKey: "v5UpgradeShown")
    XCTAssertTrue(UserDefaults.standard.bool(forKey: "v5UpgradeShown"))
}
```

Plus snapshot/visual test if time permits — usually skipped for SwiftUI reveal screens.

### Task 5.2: Create V5UpgradeOnboardingView

**Files:**
- Create: `PeerDrop/Pet/UI/V5UpgradeOnboarding.swift`

Mirror `V4UpgradeOnboardingView` pattern. Key copy:
- Title: "Pets Got New Animations"
- Subtitle: "Your pet now walks with full animations. Watch them in action!"
- Demo: auto-play user's actual pet doing walk + idle in a small preview area
- CTA: "See it"

Gate via `@AppStorage("v5UpgradeShown")`. On dismiss, set flag.

Wire into PetTabView's existing onboarding chain (V4UpgradeOnboarding → V5UpgradeOnboarding if v5UpgradeShown == false).

### Task 5.3: Commit

```bash
git commit -m "feat(pet): V5UpgradeOnboardingView reveal — animations demo

Phase 5. New view shown once on first v5 launch (gated by
v5UpgradeShown @AppStorage). Auto-plays user's actual pet through
walk + idle frames. CTA dismisses + persists. Same pattern as
V4UpgradeOnboardingView."
```

---

## Phase 6 — Widget bridge invalidation + 5-lang strings (~1 day)

### Task 6.1: Bump renderedImageVersion

**Files:**
- Modify: `PeerDrop/Pet/Shared/SharedRenderedPet.swift` (or wherever the widget bridge is)

Add:
```swift
@AppStorage("renderedImageVersion") private var renderedImageVersion: String = ""

// On first v5 launch, force re-render:
if renderedImageVersion != "v5" {
    forceRerender()
    renderedImageVersion = "v5"
}
```

### Task 6.2: 5-lang xcstrings additions

**Files:**
- Modify: `PeerDrop/App/Localizable.xcstrings`

Add 4 keys × 5 langs:
- `v5_upgrade_title`
- `v5_upgrade_subtitle`
- `v5_upgrade_cta`
- `v5_upgrade_demo_label`

Provide en, zh-Hant, zh-Hans, ja, ko translations.

**Commit:**

```bash
git commit -m "i18n + bridge: v5 upgrade strings + renderedImageVersion bump

Phase 6. 4 new welcome keys × 5 languages. Widget bridge re-renders
on first v5 launch (renderedImageVersion @AppStorage transitions
\"\" → \"v5\"). Existing v4 PNG in App Group is replaced."
```

---

## Phase 7 — Cross-version compat regression test (~1 day)

### Task 7.1: Test — v4 zip → v5 receiver renders correctly

**Files:**
- Modify: `PeerDropTests/Pet/PetRendererV3Tests.swift` (extend)

```swift
func test_v5renderer_canRender_v4FormatZip_asSingleFrame() async throws {
    // Use a v2 metadata zip (e.g. legacy ghost.zip if any v4 zips remain in test resources)
    let renderer = PetRendererV3()
    let image = renderer.render(
        species: SpeciesID("legacy-test"), stage: .baby, direction: .south,
        action: .walk, frameIndex: 5, mood: .happy
    )
    XCTAssertNotNil(image, "v2 zip should render at frameIndex 5 (clamps to single frame)")
}
```

### Task 7.2: Test — v3 peer payload with new species → graceful fallback

Confirms cross-version peer compat for hypothetical v5.x species additions (no-op for v5.0 itself; future-proofing).

**Commit:**

```bash
git commit -m "test(pet): cross-version compat — v4 zip + v3 peer payload guards

Phase 7. v5 renderer gracefully handles v4-format zips (single-frame
fallback). Peer payload regression guard for cross-version species
support hypothetically being added in v5.x."
```

---

## Phase 8 — Soak + ship (~3 days + 1 day Apple)

### Task 8.1: Bump version

**Files:** `project.yml`

```yaml
MARKETING_VERSION: "5.0.0"
CURRENT_PROJECT_VERSION: "1"
```

For both PeerDrop + PeerDropWidget targets. Run `xcodegen generate`.

### Task 8.2: Release notes (5 lang)

**Files:** `fastlane/metadata/{en-US,zh-Hant,zh-Hans,ja,ko}/release_notes.txt`

en-US example:
```
PeerDrop 5.0 — Pets Come Alive

What's new:
- All 33 species now walk with full multi-frame animations.
- Subtle idle breathing animations bring pets to life when at rest.
- Smoother direction handling: pets continue animating mid-turn.

Behind the scenes:
- 3,000+ new sprite frames generated and bundled.
- New sprite pipeline (PetRendererV4) supports per-action frame arrays.
- Bundle size +30 MB (still well under iOS download limits).
```

zh-Hant / zh-Hans / ja / ko equivalents — write following v4.0.x style.

### Task 8.3: v5.0 reviewer notes

**Files:** Create `docs/release/v5.0-reviewer-notes.md`

Mirror v4.0.2 structure. Highlight: major animation upgrade; no PetState schema change; no new permissions; cross-version peer compat preserved.

### Task 8.4: Soak (3 days)

- Day 1: internal soak — install on user's device(s); manual smoke 3 cases (walk visible, idle breathing, direction continuity)
- Day 2: external TestFlight 5 testers
- Day 3: review feedback + final fixes

### Task 8.5: Ship

```bash
fastlane release
```

Same auto-release / no-phased pattern as v4.0.x. Reviewer notes auto-loaded.

### Task 8.6: Update memory + STATUS

After ship:
- Update MEMORY.md App Store Status section
- Update `docs/pet-design/ai-brief/STATUS.md` with v5 frozen state
- Update `project-neo-egg.md` (memory) — note v5 animation pipeline shipped

---

## Acceptance criteria (from design doc Section 5)

```
Code:
[ ] PetAnimationController.setAction has ≥1 production caller
[ ] PetRendererV3 has render(...action:frameIndex:) overload
[ ] SpriteService caches CGImage[] per (species, stage, dir, action)
[ ] All 324 zips include rotations + walk + idle directories
[ ] metadata.json export_version: "3.0" on all v5 zips

Bundle:
[ ] PeerDrop/Resources/Pets/ size < 50 MB
[ ] xcodebuild test passes (count = v4.0.2 + ~25 new tests)
[ ] Cross-version compat test passes (v4 zip → v5 receiver)

Visual (manual):
[ ] Walk visible: tap-nudge → 8-frame cycle in 1.3 s
[ ] Idle breathing: 10 s at rest → subtle 2-frame cycle
[ ] Direction handling: rotate mid-walk, paws still animate

Performance:
[ ] iPhone 8 frame budget: render call < 16 ms
[ ] 1-hour battery drain: < 5 %

Operational:
[ ] PixelLab quota used: < 50 % of monthly (~1000 / 2000)
[ ] All species × stages have visual review pass
[ ] V5UpgradeOnboardingView gated by @AppStorage flag
[ ] Reviewer notes (v5.0-reviewer-notes.md) drafted
[ ] 5-lang release notes drafted
```

## Rollback plan

If ship-blocking bug surfaces post-release:
1. ASC pause via "Pause Phased Release" (v5 default phased:false; pause means stopping further downloads)
2. v5.0.1 hotfix branch
3. Don't roll back v4.0.x compat — v5 zips' v3.0 metadata is forward-only; downgrade users via TestFlight to v4.0.2 if needed (rare)
