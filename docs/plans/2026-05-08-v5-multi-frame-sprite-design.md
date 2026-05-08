# v5 — Multi-Frame Sprite Animation Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:writing-plans to convert this design into an implementation plan.

**Goal:** Eliminate the v4 "static-PNG-per-stage / paws don't move / pet just slides" architectural limitation by adding multi-frame walk + idle animations for all 33 species × 3 stages.

**User-facing pain killed:** "It doesn't move normally. Its paws don't move; they're just sliding." — root-caused as v4-architecture-wide single-PNG-per-direction; v5.0 replaces with per-direction × per-action frame arrays.

**Scope (B-premium, all-in):**
- Walk: 8 frames per direction
- Idle: 4 frames per direction
- Coverage: all 33 species × 3 stages = 324 zips (single-stage species like ghost = 1 zip)
- Bundle size delta: +30 MB (~14 MB → ~44 MB), well under iOS OTA limit

**Tech Stack:**
- Swift 5.9, SwiftUI, Combine
- Existing: `PetEngine`, `PetAnimationController` (currently inert), `PetRendererV3`, `SpriteService`, `SpeciesCatalog`, `SpriteAssetResolver`
- New: `PetRendererV4` (renames v3 with frame parameters), extended SpriteService cache, `PetAction.walk/.idle` semantic tightening
- PixelLab Pixel Apprentice tier: 2000 generations/month

---

## Section 1 — Architecture & Data Flow

### High-level pipeline

```
PixelLab (asset-gen sprint, ~2 weeks)
    └→ batch: 324 zips, each with rotations + walk × 8 + idle × 4

PeerDrop/Resources/Pets/<species>-<stage>.zip
    └→ on first access:
       SpriteAssetResolver → "ghost" / "cat-tabby-adult"
       SpriteService (actor) → decode ALL frames once → CGImage[]
       cache keyed by (species, stage, direction, action, frameIndex)

PetRendererV4
    inputs: (species, stage, direction, action, frameIndex, mood)
    output: composited CGImage (sprite + mood overlay)

PetAnimationController (was inert in v4 — wired up in v5)
    Timer-driven, separate from physics tick
    walk: 6 fps × 8 frames = 1.33 s cycle
    idle: 2 fps × 4 frames = 2 s cycle
    @Published currentFrame drives renderer

PetEngine.tick() (60 Hz physics)
    → derives action from velocity (|v| > threshold ? .walk : .idle)
    → calls animator.setAction(...) on action change
    → renders with animator.currentFrame

SwiftUI Image in FloatingPetView
```

### Key architectural decisions

| Axis | Choice | Why |
|---|---|---|
| Animator state | one `PetAnimationController` per pet (owned by `PetEngine`) | Reuses existing inert class; minimal new infrastructure |
| Frame timing | Timer-driven (`Combine.Timer.publish`), separate from physics 60 Hz | Animation cadence (2-6 Hz) ≠ physics cadence; decoupling avoids stutter |
| Cache lifecycle | SpriteService keeps decoded frames in memory; LRU evict at ~5 species | Most users have 1-2 active pets; 5-species LRU = 14 MB peak, acceptable |
| Mood overlay | unchanged (SF Symbol composited on top) | v4 already shipped this; rework not warranted |
| Direction logic | unchanged (8-way velocity → enum) | v4 has it; reuse |

### What v5 REPLACES vs KEEPS from v4

**Replaces:**
- Static single-PNG-per-direction → multi-frame array per direction × action
- `PetRendererV3` → `PetRendererV4` (additional `frameIndex:` and `action:` parameters)
- `PetAnimationController.setAction()` finally has production callers

**Keeps:**
- 8-direction rotation logic
- Mood overlay system (M3 SF Symbol pivot)
- Sprite zip per (species, stage) bundle layout
- `SpeciesCatalog` + `SpriteAssetResolver` structure
- `PetEngine` + `GhostBehavior` + species-specific behavior providers
- `PetWelcomeView` / `PetWelcomeFlag`
- App Group widget bridge (`SharedRenderedPet`)

---

## Section 2 — Zip Format & PixelLab Asset-Gen Sprint

### New zip layout

```
ghost.zip/
├── rotations/                           ← KEPT from v4 (static fallback, idle frame 1, etc.)
│   ├── south.png … south-west.png       (8 directions)
├── animations/
│   ├── walk/                            ← NEW
│   │   ├── south_001.png … south_008.png
│   │   ├── east_001.png … east_008.png
│   │   └── (8 dir × 8 frames = 64 PNGs)
│   └── idle/                            ← NEW
│       ├── south_001.png … south_004.png
│       └── (8 dir × 4 frames = 32 PNGs)
└── metadata.json                        ← EXTENDED
```

Per-zip totals: 8 + 64 + 32 = **104 PNGs** + metadata. ~106 KB per zip × 324 zips = ~34 MB total.

### Updated `metadata.json` schema

```json
{
  "character": { ...same as v4... },
  "frames": {
    "rotations": { ...same as v4... },
    "animations": {
      "walk": {
        "fps": 6,
        "frame_count": 8,
        "loops": true,
        "directions": {
          "south": ["animations/walk/south_001.png", "...", "animations/walk/south_008.png"],
          "east": [...],
          ...
        }
      },
      "idle": {
        "fps": 2,
        "frame_count": 4,
        "loops": true,
        "directions": { ... }
      }
    }
  },
  "export_version": "3.0",   ← bumped from "2.0"
  "v5_compatible": true
}
```

### PixelLab sprint structure (4 weeks)

**Pre-flight gate (Day 1-2):** Verify PixelLab supports animation frame generation (likely yes — `frames.animations` exists in their schema, just empty in v4 batch). If not, fall back to ImageMagick post-processing or scope to B-standard.

**Week 1:** Foundation + 5-species spike. Generate cat × 5 breeds + dog × 5 breeds (30 zips) as proof-of-concept.

**Week 2:** Mass generation (~150-200 zips at 8/day fast tier).

**Week 3:** Cleanup + retries. ~30% retry rate per v4 batch experience. Quota math: 324 base + ~100 retries = 21% of 2000/mo.

**Consistency strategy:** Reuse v4 character IDs in PixelLab when generating animations (if supported). Otherwise regenerate from prompt; accept 20-30% drift requiring retry.

**Fallback if PixelLab fails:**
- Plan B: ImageMagick post-process — translate paws ±2 px between frames. Cheap walk cycle, passable visual.
- Plan C: Downscope to B-standard (6 walk + 3 idle) which may be more tractable.

---

## Section 3 — Renderer + Animation Controller Wiring

### `PetRendererV4` API

```swift
// v3 (current)
func render(species: SpeciesID, stage: PetLevel, direction: Direction, mood: PetMood) -> CGImage?

// v4 (new in v5)
func render(
    species: SpeciesID,
    stage: PetLevel,
    direction: Direction,
    action: PetAction,           // NEW (.walk or .idle for v5.0)
    frameIndex: Int,             // NEW — wraps mod frameCount
    mood: PetMood
) -> CGImage?
```

Backward-compat overload: `render(...)` without `action`/`frameIndex` defaults to `(.idle, 0)`.

### `SpriteService` cache extension

```swift
// v4
typealias SpriteCache = [CacheKey: CGImage]
struct CacheKey { let species, stage, direction }

// v5
typealias SpriteCache = [CacheKey: AnimationFrames]
struct CacheKey { let species, stage, direction, action }
struct AnimationFrames {
    let images: [CGImage]
    let fps: Int
    let loops: Bool
}
```

- First-access decode: ~10 ms for 12 frames on iPhone 16 (background actor)
- LRU evict at 5 species cap: ~14 MB peak in-memory, fine for 4-8 GB iPhones
- Single-stage species (ghost): cache key's `stage` is constant; no extra logic needed

### `PetAnimationController` wiring

```swift
final class PetAnimationController: ObservableObject {
    @Published private(set) var currentFrame: Int = 0
    private(set) var currentAction: PetAction = .idle
    private var frameCount: Int = 4
    private var fps: Int = 2
    private var timer: Timer?

    func setAction(_ action: PetAction, frameCount: Int, fps: Int) {
        guard action != currentAction else { return }   // de-dupe
        self.currentAction = action
        self.frameCount = frameCount
        self.fps = fps
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

Pause on app background; resume on foreground (battery savings).

### `PetEngine.tick()` integration

```swift
let velocity = physicsState.velocity
let speed = velocity.magnitude

let nextAction: PetAction = (speed > walkThreshold) ? .walk : .idle

if nextAction != animator.currentAction {
    let metadata = SpriteService.metadata(for: species, stage: stage)
    let anim = metadata.animations[nextAction.rawValue]
    animator.setAction(nextAction, frameCount: anim.frame_count, fps: anim.fps)
}

let direction = Direction.from(velocity: velocity)

self.renderedImage = renderer.render(
    species: species,
    stage: stage,
    direction: direction,
    action: animator.currentAction,
    frameIndex: animator.currentFrame,
    mood: pet.mood
)
```

`animator.currentFrame` is `@Published` → engine listens via Combine `.sink` → re-renders on every animator tick (decoupled from physics 60 Hz).

### Threading model

- Physics tick: MainActor, 60 Hz
- Animator timer: MainActor, 2-6 Hz
- SpriteService decode: background Actor (CGImage hand-back to main on completion)
- Renderer: MainActor, pure cache lookup → SwiftUI Image refresh

### Resilience

- Action requested but only `.idle` exists in zip → fall back to idle frames
- Invalid frame_count metadata → use 1 (single static frame)
- PNG decode failure → substitute corresponding rotation PNG

---

## Section 4 — Migration & Cross-Version Peer Compatibility

### v4.0.x → v5 user-device migration

**No PetState schema change.** v5 is purely render-side.

```
v4.0.x device                         v5.0 device
PetState { genome, mood, level, ...}  PetState { ...UNCHANGED... }
+ 324 zips (rotations only)           + 324 zips (rotations + walk + idle)
                                      + PetAnimationController wired
                                      + PetRendererV4
```

**Invalidation on first v5.0 launch:**
- App Group rendered-image cache (`SharedRenderedPet`): `@AppStorage("renderedImageVersion")` bumps "v4" → "v5"; widget re-renders idle frame 0
- SpriteService cache: in-memory only, flushed on app restart; nothing to do
- PetState: no migration needed

### `V5UpgradeOnboardingView`

Recommended (Option α): mirror `V4UpgradeOnboardingView` pattern:
- Gated by `@AppStorage("v5UpgradeShown")`
- One screen: "Your pet got new animations 🎬" + auto-playing demo of user's actual pet walking
- CTA: "See it"
- Same dismiss/persist semantics as v4

(Option β — silent ship — was considered but rejected; users may not notice the change without prompt.)

### Cross-version peer compat matrix

| Sender → Receiver | Behavior |
|---|---|
| v5 → v5 | both pets walking with full animations ✅ |
| v5 → v4.0.x | sender's pet renders static (v4 receiver lacks animation frames) ✅ |
| v4.0.x → v5 | sender's pet renders walking (v5 receiver uses v5 bundle for any received species) ✅ |
| v3.x → v5 | level=1 → .baby decoder; renders v5 baby walking ✅ |
| v5 → v3.x | sender's pet visible; v3 has its own rendering ✅ |

**No `protocolVersion` bump needed.** Wire format unchanged (bundle assets are local-only).

### iCloud sync compat

PetState syncs unchanged. Multi-device with mixed v4/v5 versions: each device renders the synced PetState using its own local bundle. Works.

### Edge case: v5.x adds new species (post-v5.0)

Not in v5.0 scope, but for future planning: v4 receiver of new-species payload → species-not-found in catalog → falls back to cat-tabby (existing v4 behavior). Consider sending fallback species hint in payload at that time.

---

## Section 5 — Testing + Acceptance + Sprint Timeline

### Test layers

**Layer 1 — Unit tests (~15-20 new):**
- `PetAnimationControllerTests` (extend): timer fires correct interval, frameIndex wraps, setAction de-dupes, pause/resume preserves state
- `SpriteServiceAnimationTests` (new): decode all walk + idle frames, cache keyed by (species, stage, dir, action), LRU evicts at cap
- `PetRendererV4Tests` (new): render(action, frameIndex) returns correct frame, out-of-bounds wraps, missing action → idle fallback
- `PetEngineActionSelectionTests` (new): velocity → action threshold + hysteresis
- `MetadataV3SchemaTests` (new): parse export_version 3.0, reject malformed animation block

**Layer 2 — Integration tests (~5 new):**
- Engine tick with velocity → animator advances → renderer emits different CGImages
- Engine tick at rest → idle animation cycles at 2 fps
- Direction change preserves animation continuity (only resets on action change, not direction)
- v4-format zip (no animations block) → renders rotation as single-frame "animation" (graceful degrade)
- Widget bridge captures idle frame 0

**Layer 3 — Manual / visual (3 cases):**
- Walk visible: nudge pet → walks → 8-frame walk cycle in 1.3 s
- Idle breathing: 10 s at rest → subtle 2-frame cycle
- Direction handling: pet rotates mid-walk → paws still animate (no freeze on rotation)

### Acceptance criteria

```
Code:
[ ] PetAnimationController.setAction has ≥1 production caller
[ ] PetRendererV4 added with frame parameters
[ ] SpriteService caches CGImage[] per (species, stage, dir, action)
[ ] All 324 zips include rotations + walk + idle
[ ] metadata.json export_version: "3.0" on all v5 zips

Bundle:
[ ] PeerDrop/Resources/Pets/ size < 50 MB
[ ] xcodebuild test passes (count = v4.0.2 + new tests)
[ ] Cross-version compat test passes (v4 zip → v5 receiver)

Visual:
[ ] Manual smoke: 3 cases all pass on iPhone 16 simulator
[ ] Walk cycle plays at 6 fps (visually verified)
[ ] Idle breathing plays at 2 fps
[ ] No regression in mood overlay alignment

Performance:
[ ] iPhone 8 frame budget: render call < 16 ms
[ ] 1-hour battery drain: < 5%

Operational:
[ ] PixelLab quota used: < 50% monthly (~1000/2000)
[ ] All species × stages have visual review pass
[ ] V5UpgradeOnboardingView gated by @AppStorage flag
[ ] Reviewer notes (v5.0-reviewer-notes.md) drafted
[ ] 5-lang release notes drafted
```

### Sprint timeline (4 weeks)

```
Week 1 — Foundation + 5-species spike
  Day 1-2  PixelLab UI exploration; verify animation generation viability (CRITICAL gate)
  Day 3    Generate cat-tabby-adult v5 zip; manual visual review
  Day 4-5  PetRendererV4 + SpriteService changes; PetAnimationController wiring
  Day 6-7  Generate top 5 species fully (cat × 5 breeds + dog × 5 breeds = 30 zips)
  ── Gate: walk visible in simulator with 5 species → proceed; else fall back B/C

Week 2 — Mass asset gen
  Day 8-12 Generate ~150-200 zips (~8/day, fast tier ~2 min each)
  Day 13   Bulk visual review on grid contact sheet; identify retries
  Day 14   Run retries

Week 3 — Code finish + remaining assets
  Day 15-16 PetEngine action selection + integration tests
  Day 17-18 Generate remaining ~120-150 zips + retries
  Day 19   Full visual QA pass; bundle size verification
  Day 20-21 V5UpgradeOnboardingView + 5-lang release notes + reviewer notes

Week 4 — Soak + ship
  Day 22-24 Internal soak (you + ≥1 friend with v3.x pet)
  Day 25-26 External soak via TestFlight (5-10 testers if possible)
  Day 27   Final smoke + fastlane release
  Day 28   ASC review (~24 h based on v4.0.x cadence)
  ── Ship: ~28 days from kickoff
```

### Risks + mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| PixelLab can't generate animations natively | medium (unknown) | high | Day 1-2 verification gate; ImageMagick fallback or scope reduction |
| Character drift between v4 static and v5 animated | medium | medium | Reuse v4 character IDs if PixelLab supports; else accept drift, document |
| 30 %+ retry rate blows quota | low | medium | 6× quota buffer (324 / 2000); plenty of headroom |
| Animation timer drains battery | low | medium | Pause on background; LRU cache caps memory; perf test gate |
| User notices animations but complains paw style | medium | low | Stardew Valley reference documented; v5.x can iterate |
| Apple reviewer flags rapid v4.0.x → v5 cadence | low | low | Reviewer notes contextualize: hotfixes responding to user reports; v5.0 = planned major upgrade |

### Out of scope for v5.0 (deferred to v5.1+)

- Per-action sprites for `.scratch / .eat / .sleep` (only walk + idle in v5.0)
- Per-species behavior-tuned animations (e.g. ghost float frames) — would re-introduce ad-hoc complexity
- Variable FPS per species (uniform 6 fps walk, 2 fps idle in v5.0)
- Multi-frame mood overlay (keep static SF Symbol)

---

## Decisions made during brainstorming

1. **Scope = B (walk + idle)**, not A (walk-only) or C/D (more actions). User chose for "feel alive" without runaway scope.
2. **Frame counts = B-premium** (8 walk + 4 idle). User chose Pokémon HG/SS-class smoothness over minimum-viable.
3. **Rollout = All-in v5.0** (33 species × 3 stages all animated at launch), not Phased or Hybrid. User chose one-shot wow over staggered rollout.
4. **Architecture = A (replace + pre-decode)**, not B (additive zips) or C (sprite atlas). User chose cleanest structure matching v4 patterns.

---

## Reference docs

- @ docs/pet-design/v4-submission-checklist.md (M12.3 ship gates pattern to mirror)
- @ docs/release/v4.0-reviewer-notes.md, @ docs/release/v4.0.1-reviewer-notes.md, @ docs/release/v4.0.2-reviewer-notes.md (templates for v5.0)
- @ docs/pet-design/ai-brief/STATUS.md (PixelLab subscription state, character ID conventions, batch protocol)
- @ MEMORY.md (project memory; update post-ship)
