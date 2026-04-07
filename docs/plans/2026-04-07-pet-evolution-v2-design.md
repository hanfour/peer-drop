# Pet Evolution v2: Pixel Pals-Grade Pet System

**Date:** 2026-04-07
**Status:** Approved
**Approach:** Sprite Sheet + Palette Swap (方案 B)

## Overview

Full overhaul of the PeerDrop pet system, inspired by Pixel Pals and Pixel Shimeji. Upgrades sprite resolution strategy to 16x16, adds full Shimeji screen physics, expands to 10 body types with 19 animated actions, and integrates Dynamic Island via Live Activities.

## Key Design Decisions

- **16x16 base sprites** — intentionally small for retro charm and Dynamic Island compatibility, scaled up with nearest-neighbor rendering
- **Sprite sheet PNGs + palette swap** — visual quality via pixel art tools, programmatic color diversity via indexed color palette swap at runtime
- **Modular overlays** — body (includes limbs) + eyes + pattern layers composited at render time
- **Full Shimeji physics** — gravity, surface detection, climbing, hanging, falling, throw with velocity
- **Dual rendering** — CADisplayLink physics (60 FPS) + 6 FPS sprite animation in-app; static pose snapshots for Dynamic Island
- **Body type fixed after hatch** — identity anchored to body, only eyes/pattern/palette can mutate

## Sprite System

### Resolution & Frame Rate

- Canvas: 16x16 pixels
- Display sizes: 128px (in-app), ~36px (Dynamic Island)
- Animation: 6 FPS (~166ms/frame)
- Rendering: nearest-neighbor upscale (no anti-aliasing)

### Color System

- 4-bit indexed color (up to 16 slots)
- 8 color palettes, decoupled from body type via hash
- Palette swap at runtime: load indexed PNG → map color indices → output CGImage
- LRU sprite cache (key: body_stage_action_frame_paletteIndex, max 200 entries)

### Sprite Sheet Format

Each action is a horizontal strip PNG: `(16 × frameCount) × 16`.
Only right-facing sprites stored; left-facing via horizontal flip.

```
Sprites/
├── Egg/
│   ├── egg_idle.png (2 frames)
│   └── egg_tap.png (3 frames)
├── Bodies/{BodyType}/{Stage}/
│   ├── {body}_{stage}_{action}.png
│   └── {body}_{stage}_meta.json    # anchor points
├── Eyes/ (4 types × mood variants)
├── Patterns/ (stripe, spot)
└── Particles/ (heart, zzz, sweat, poop, star)
```

### Modular Composition

1. **Body** — base layer, defines silhouette (ears, tail, etc.), includes limbs
2. **Eyes** — overlay at body's eyeAnchor position (4x4 area)
3. **Pattern** — mask overlay, only affects body-region pixels

### Body Metadata

```swift
struct BodyMeta {
    let eyeAnchor: (x: Int, y: Int)
    let patternMask: [[Bool]]       // which pixels accept pattern overlay
    let groundY: Int                // foot position for physics
    let hangAnchor: (x: Int, y: Int)
    let climbOffset: (x: Int, y: Int)
}
```

## Body Types (10)

| # | Type | Silhouette | Rarity |
|---|------|-----------|--------|
| 1 | Cat | Pointed ears + raised tail | 14% |
| 2 | Dog | Floppy ears + wagging tail | 14% |
| 3 | Rabbit | Long ears (3-4px tall) | 12% |
| 4 | Bird | Wings + beak | 12% |
| 5 | Frog | Wide flat body + big eyes | 10% |
| 6 | Bear | Round ears + thick body | 10% |
| 7 | Dragon | Horns + wings + tail | 8% |
| 8 | Octopus | Round head + tentacles | 7% |
| 9 | Ghost | Legless, wavy bottom edge | 6% |
| 10 | Slime | Droplet shape, jelly bounce | 7% |

Body type determined by `personalityGene` range at hatch. Dragon/Ghost rarer for collectibility.

## Animation System

### Actions (19 total)

| Category | Action | Frames | Trigger |
|----------|--------|--------|---------|
| Movement | idle | 4 | Default state |
| | walk | 4 | Wander / move to target |
| | run | 6 | Zoomies / post-throw |
| | jump | 4 | Jump onto platform / happy |
| Edge | climb | 4 | Touch screen side edge |
| | hang | 2 | Reached top while climbing |
| | fall | 3 | Lost support / released from drag |
| | sit_edge | 2 | On top edge or Dynamic Island |
| Life | sleep | 2 | PetLifeState = sleeping |
| | eat | 4 | Feed interaction (future) |
| | yawn | 3 | sleep → waking transition |
| | poop | 4 | Timed after eating, squat + sweat + 💩 |
| Emotion | happy | 3 | mood = happy, small jump + heart particles |
| | scared | 2 | mood = startled, shake |
| | angry | 3 | Mood or shaken |
| | love | 3 | petMeeting / petted |
| Interact | tap_react | 3 | Tapped, turn + bounce |
| | picked_up | 2 | During drag |
| | thrown | 3 | Released from drag, parabolic arc |
| | petted | 3 | Swipe gesture |

### Animation State Machine

```
IDLE ←── default, all done transitions return here
 ├─ wander → WALK ─→ edge? → CLIMB → HANG → sit/fall
 ├─ sleep trigger → SLEEP → YAWN → IDLE
 ├─ edge contact → CLIMB → HANG → FALL → IDLE
 ├─ drag start → HELD → release → THROWN → FALL → IDLE
 ├─ mood trigger → EMOTION → IDLE
 ├─ tap → TAP_REACT → IDLE
 └─ poop timer → POOP → IDLE (💩 stays on screen)
```

### Stage Differences

| Stage | Animation Character |
|-------|-------------------|
| Egg | Only idle (wobble 2 frames) + tap_react (crack increase), no movement |
| Baby | All 19 actions, clumsy/cute (large amplitude, bouncy) |
| Child | All 19 actions, smoother/confident (refined motion, secondary animation on ears/tail) |

### Direction

Right-facing sprites only. Left = horizontal flip. Direction determined by movement vector.

## Screen Physics Engine (Shimeji)

### World Model

```
┌─ TOP EDGE (sit, hang) ─────────────────┐
│  ┌── Dynamic Island (sit) ──┐          │
│  └──────────────────────────┘          │
│ LEFT WALL              RIGHT WALL      │
│ (climb)                (climb)         │
│           airborne space               │
│ BOTTOM EDGE (ground, primary walk) ────│
└────────────────────────────────────────┘
```

### Physics Parameters

```swift
struct PetPhysics {
    let gravity: CGFloat = 800          // px/s²
    let walkSpeed: CGFloat = 30         // px/s
    let runSpeed: CGFloat = 80          // px/s
    let climbSpeed: CGFloat = 20        // px/s
    let jumpVelocity: CGFloat = -300    // px/s (upward)
    let throwDecay: CGFloat = 0.95      // velocity decay per frame
    let bounceRestitution: CGFloat = 0.3
}
```

### Surface Detection

```swift
enum PetSurface {
    case ground, leftWall, rightWall, ceiling, dynamicIsland, airborne
}
```

Surfaces computed from `UIScreen.main.bounds` + `safeAreaInsets`.
Physics updated at 60 FPS via CADisplayLink; sprite animation at 6 FPS.

### Drag & Throw

1. Drag start → `picked_up` animation, track finger velocity (last 3 frames)
2. During drag → follow finger
3. Release → initial velocity = finger velocity, play `thrown`
4. Airborne → gravity + throwDecay on horizontal velocity
5. Land → bounce (restitution), return to idle

### Behavior Logic

| State | Behavior | Transitions |
|-------|----------|-------------|
| ground + idle | Stand, play idle | Random → walk / sleep / jump |
| ground + walk | Walk along bottom | Hit edge → 50% turn, 50% climb |
| wall + climb | Climb up edge | Top → hang/sit_edge; random → fall |
| ceiling + sit_edge | Sit on top | Random → hang → fall, or walk along top |
| dynamicIsland + sit_edge | Sit on island | Syncs with island pose |
| airborne + fall | Gravity descent | Hit surface → bounce → surface state |
| held | Follow finger | Release → thrown → fall |

## Genome & Evolution

### Expanded PetGenome

```swift
struct PetGenome {
    var body: BodyGene       // 10 types (cat...slime)
    var eyes: EyeGene        // 4 types (unchanged)
    var pattern: PatternGene // 3 types (unchanged)
    var personalityGene: Double
}
```

LimbGene removed — limbs are part of body sprites.

Palette index decoupled from body type:
```swift
var paletteIndex: Int {
    Int((personalityGene * 137).truncatingRemainder(dividingBy: 1.0) * 8)
}
```

### Evolution (3 stages)

| Stage | Level | Requirements | Visual Change |
|-------|-------|-------------|---------------|
| Egg | Lv.1 | — | White egg, cracks increase with XP |
| Baby | Lv.2 | 100 XP + 24h | Full character revealed, clumsy animations |
| Child | Lv.3 | 500 XP + 72h | Same character refined, smoother animations, more expressions |

- Body type fixed after hatch (never mutates)
- Egg → Baby: 5% gene mutation
- Baby → Child: 10% eyes/pattern mutation, body unchanged

## Interaction System

### Gestures

| Gesture | Recognition | Action | XP |
|---------|------------|--------|-----|
| Tap | TapGesture | tap_react | 2 |
| Drag & drop | DragGesture | picked_up → thrown → fall | 3 |
| Pet/stroke | Horizontal swipe on pet | petted → love particles | 3 |
| Shake | CMMotionManager | scared or zoomies | 3 |
| Long press | LongPressGesture | Open interaction panel | 0 |

### Passive Events

| Event | Trigger | Reaction |
|-------|---------|----------|
| Peer connected | onPeerConnected | happy + wagTail |
| Message received | onMessageReceived | tiltHead or climbOnBubble |
| File transfer | onFileTransfer | eat animation |
| Pet meeting | onPetMeeting | love particles + social diary |
| Neglect (>2h) | No interaction timer | sleep → lonely on wake |
| Poop | 30-120 min after eat | poop → 💩 on screen |
| Evolution | XP + time threshold | flash + haptic |

### Poop Mechanic

```swift
struct PoopState {
    var poops: [(position: CGPoint, droppedAt: Date)]
    let maxPoops = 3
    let moodPenaltyDelay: TimeInterval = 600  // 10 min
}
```

- Tap 💩 to clean (star particles, 1 XP)
- 3 uncleaned poops → pet refuses to eat
- >10 min uncleaned → mood → angry

### Particle Effects

Types: heart, zzz, sweat, poop, star
Rendered as SwiftUI-animated 16x16 sprites with lifetime (0.5-1.5s).

## Dynamic Island / Live Activities

### Rendering Mode

| Context | Method | Frame Rate |
|---------|--------|-----------|
| In-app | CADisplayLink + 6 FPS sprite | 60 FPS physics / 6 FPS sprite |
| Dynamic Island | Static pose image swap | ~0.25 FPS (every 4s update) |
| Widget | Static snapshot | Every 15 min |

### Island Layout

- **Compact**: Pet sprite (leading) + mood icon (trailing)
- **Expanded**: Pet sprite + name + level + EXP bar + mood
- **Minimal**: Static 16x16 pet sprite

### Island Poses

```swift
enum IslandPose: Codable {
    case sitting, sleeping, happy, eating, pooping, lonely
}
```

### ActivityKit Integration

```swift
struct PetActivityAttributes: ActivityAttributes {
    let petID: UUID
    let bodyType: BodyGene
    struct ContentState: Codable, Hashable {
        let pose: IslandPose
        let mood: PetMood
        let level: PetLevel
        let name: String?
        let expProgress: Double
    }
}
```

- Start: app enters background (pet jumps to island)
- End: app returns to foreground (pet jumps back)
- Update: on mood change, interaction, evolution, poop

### Widget Extension

```
PeerDropWidgetExtension/
├── PetWidget.swift
├── PetLiveActivity.swift
└── Shared/PetSpriteLoader.swift
```

Shared via App Group for pet state + sprite resources.

## Implementation Phases

### Phase 1: Rendering Pipeline + Base Physics

- SpriteSheetLoader, PaletteSwapRenderer, SpriteCache, SpriteCompositor
- PetPhysicsEngine (gravity, surfaces, collision)
- FloatingPetView rewrite (physics-driven)
- Image-based PixelView replacement
- Particle effect system
- **Cat body type only** — all 19 actions as validation
- **Deliverable:** One cat with full Shimeji physics

### Phase 2: All Body Types + Evolution

- Remaining 9 body type baby sprites (~530 frames)
- All 10 body type child sprites (~590 frames)
- 16x16 egg sprite
- PetGenome expansion (10 body types)
- Baby → Child evolution
- All gesture interactions (pet, poop mechanic)
- **Deliverable:** 10 pets, 3 evolution stages, all interactions

### Phase 3: Dynamic Island + Widget

- WidgetExtension target
- ActivityKit Live Activity
- Island compact/expanded/minimal layouts
- Lock Screen + Home Screen widgets
- App Group sharing
- Foreground ↔ background transition animation
- **Deliverable:** Pet on Dynamic Island and widgets

### Phase 4: Polish

- Evolution special effects (flash + haptic)
- Sound effects (optional)
- Weather/time reactions
- Performance profiling
- Comprehensive testing

## Resource Estimates

| Item | Count |
|------|-------|
| Body types × stages × actions × avg frames | 10 × 2 × 19 × 3.1 ≈ 1,180 |
| Egg + eyes + patterns + particles | ~28 |
| Island poses | ~20 |
| **Total sprites** | **~1,230** |
| Total PNG size (16x16, ~300 bytes each) | **~370 KB** |

## Migration

- Old 3 BodyGene values map to new types: round→bear, square→cat, oval→slime
- Old PixelGrid/PetSpriteTemplates retained until Phase 1 complete, then removed
- Old save files auto-migrate via PetStore
