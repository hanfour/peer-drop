# Project Neo-Egg: Virtual Pet System Design

**Date:** 2026-04-04
**Status:** Approved
**Scope:** MVP (Sprint 1) — Lv.1 Egg → Lv.2 Baby

---

## 1. Overview

PeerDrop gains a virtual pet companion that lives as a floating pixel sprite across all screens. The pet reacts to user interactions, chat activity, and P2P connections. When two devices connect, their pets meet and have private conversations the user can unlock through a "sneak peek" mechanic.

**Positioning:** Social enhancement layer — P2P core functionality remains untouched. Pet adds emotional value to the otherwise utilitarian chat experience.

**Key principles:**
- Pet behaves like a real-world pet (cat/dog/rabbit/turtle/hamster/bird personality spectrum)
- Visual style: monochrome LCD Tamagotchi, 64×64 internal grid, procedurally generated
- AI: pure local templates, no cloud dependency
- Architecture: independent `Pet/` module, only 3 integration points with existing code (~18 lines changed)

---

## 2. Data Model

### PetState — Core State

```swift
struct PetState: Codable {
    let id: UUID
    var name: String?                    // User naming (unlocked at Lv.2+)
    var birthDate: Date
    var level: PetLevel                  // .egg, .baby
    var experience: Int                  // Interaction accumulated XP
    var genome: PetGenome               // Determines appearance + personality
    var mood: PetMood                   // Current emotion
    var socialLog: [SocialEntry]        // Pet-to-pet interaction records
    var lastInteraction: Date           // For loneliness calculation

    // Reserved for future (not implemented in MVP):
    // var hunger: Double
    // var cleanliness: Double
    // var attribute: AttributeType     // .vaccine, .data, .virus
    // var battleStats: BattleStats
}
```

### PetGenome — Gene System

```swift
struct PetGenome: Codable {
    static let canvasSize = 64          // 64×64 pixel internal precision

    var bodyGene: BodyGene              // round / square / oval
    var eyeGene: EyeGene               // dot / round / line / dizzy
    var limbGene: LimbGene              // short / long / none
    var patternGene: PatternGene        // none / stripe / spot
    var personalityGene: Double         // 0.0~1.0, maps to personality spectrum

    mutating func mutate(trigger: InteractionType) { ... }
}
```

Gene enums (e.g., `BodyGene`, `EyeGene`) each have 3-4 variants. The `PixelRenderer` maps them to drawing rules on the 64×64 grid.

### PersonalityTraits — Continuous Spectrum

```swift
struct PersonalityTraits: Codable {
    var independence: Double  // high=cat, low=dog
    var curiosity: Double     // high=bird/rabbit, low=turtle
    var energy: Double        // high=hamster, low=turtle
    var timidity: Double      // high=rabbit, low=dog
    var mischief: Double      // high=cat, low=turtle
}
```

Derived from `personalityGene`. Not a discrete label — every pet is a unique blend.

### PetLevel

```swift
enum PetLevel: Int, Codable, Comparable {
    case egg = 1        // Vibration/glow only
    case baby = 2       // Single syllables
    // Future: child(3), teen(4), mature(5), ultimate(6)
}
```

### Evolution Requirement

- egg → baby: 100 XP, social bonus 1.5x, minimum age 24hr
- Interaction accumulation is primary trigger; social meetings accelerate but are not required

### SocialEntry

```swift
struct SocialEntry: Codable, Identifiable {
    let id: UUID
    let partnerPetID: UUID
    let partnerName: String?
    let date: Date
    let interaction: SocialInteraction  // .greet, .chat, .play
    var dialogue: [DialogueLine]
    var isRevealed: Bool                // Sneak peek unlock status
}
```

---

## 3. Pixel Rendering Engine

### PixelGrid

- 64×64 `[[Bool]]` array (true = black pixel)
- Basic drawing ops: circle, rect, line, fill, mirror
- 512 bytes per frame — extremely lightweight

### PetRenderer

- Takes `PetGenome` + `PetLevel` + `PetMood` + animation frame → produces `PixelGrid`
- Egg: ellipse + cracks (more cracks as XP increases)
- Baby: body + eyes + limbs + pattern, mood overrides eye expression

### PixelView (SwiftUI)

- Uses `Canvas` for rendering (not Image)
- `Image(interpolation: .none)` style — sharp pixel edges when scaled
- Display size configurable (default 64pt for own pet, 48pt for guest)

### Animation

- 2 FPS frame rate — authentic LCD feel
- 2-4 frames per action (idle/walk/bounce/sleep)
- `PetAnimationController` manages timer + frame cycling

---

## 4. Pet Engine & Interaction System

### PetEngine — State Machine

- `@MainActor class`, `ObservableObject`
- Handles all interactions → accumulates XP → checks evolution
- 5% gene mutation chance per interaction
- Mood calculated from `InteractionTracker.recentHistory`

### InteractionType & XP Values

| Type | XP | Source |
|---|---|---|
| tap | +2 | User taps pet |
| shake | +3 | Accelerometer |
| charge | +1/min | Charging state |
| steps | +1/100 | Pedometer |
| peerConnected | +5 | P2P connection |
| chatActive | +2 | Chat message |
| fileTransfer | +3 | Transfer complete |
| petMeeting | +10 | Pet social encounter |

### PetMood

Six moods: happy, curious, sleepy, lonely, excited, startled. Derived from recent interaction patterns:
- 5+ interactions in 1hr → happy
- New peer connection → curious
- 4hr no interaction → sleepy
- 24hr no social → lonely
- Nearby BLE pet detected → excited
- Sudden shake → startled

### PetDialogEngine

- Local template system, no cloud AI
- Lv.1 (egg): no speech
- Lv.2 (baby): single syllables/onomatopoeia mapped by mood

### Life Rhythm

Pets have daily schedules based on real time:
- 0-5: sleeping
- 6-8: waking (high energy pets only)
- 9-11: active
- 12-13: napping
- 14-20: active
- 21-23: drowsy (high energy stay active)

Sleeping pets show ZZZ animation and don't respond to interactions (unless tapped repeatedly).

---

## 5. Floating Sprite UI

### FloatingPetView

- Overlay on all screens via `PeerDropApp.overlay()`
- Draggable positioning
- Auto-wander along screen edges (5s interval), avoids center content area
- Tap = interaction, long press = open interaction panel
- `PetInteractionView` sheet: status display, XP progress bar, secret diary

### Chat-Aware Behaviors

Pet reacts to incoming messages with personality-driven behavior:

| Behavior | Trigger Chance | Duration | Dismiss |
|---|---|---|---|
| Notify (jump to bubble) | 80% | 2s | Auto |
| Climb on bubble | 15% | 5s | Auto slide off |
| Block text | 5% | Until tapped | Tap to shoo |
| Bounce between bubbles | 30% (excited) | 3s | Auto |

- 30s cooldown between behaviors
- Long press pet → sleep mode (no more active positioning)
- Tapping to shoo → mood becomes startled (pet runs away looking hurt)

### Real Pet Behavior Examples

| Real Behavior | In-Game | Trigger |
|---|---|---|
| Cat kneading | Pixel feet alternating on bubble | Happy + on bubble |
| Dog tail wag | Pixel tail sways, follows finger | User touch / app open |
| Rabbit freeze | Motionless 2s, ears up | Shake / sudden touch |
| Turtle retract | Only shell visible, slowly peeks | First touch after long absence |
| Hamster cheek stuff | Face pixels expand | File transfer complete |
| Bird head tilt | Head rotates 45° | New message |
| Cat knocking things | Pushes notification off-screen | Random (happy, 3%) |
| Dog separation anxiety | Trembling in corner | 48hr+ without opening app |

### Guest Pet (During P2P Connection)

- Rendered at 48pt, 80% opacity (smaller + translucent = clearly visitor)
- Two pets interact: chase, circle, approach based on mood
- Excited → chase partner; curious → slowly approach; sleepy → ignore; startled → flee

---

## 6. Social Protocol & P2P Integration

### Pet Payload

```swift
enum PetPayloadType: String, Codable {
    case greeting       // Exchange pet info on connection
    case socialChat     // Pet private conversation
    case reaction       // Real-time pet reactions
}
```

### Social Flow

1. Device A connects to Device B
2. Both exchange `PetGreeting` (petID, name, level, mood, genome)
3. Both trigger `.petMeeting` (+10 XP)
4. `PetSocialEngine` generates private dialogue based on both pets' mood + level
5. Dialogue stored in `socialLog` with `isRevealed: false`
6. During connection: new dialogue every ~60s
7. On disconnect: pet shows farewell reaction

### Sneak Peek Unlock

- When pet mood is `.happy`, 30% chance per interaction to reveal one unrevealed `SocialEntry`
- Pet "tells you" what it said — displayed as notification + unlocked in secret diary

### Integration with Existing Protocol

- Pet packets use the same P2P data channel as chat/file/voice
- `ConnectionManager` adds one `if` to route `PetPayload` via `NotificationCenter`
- No new connections, no new protocols

---

## 7. Persistence & iCloud Sync

### Local Storage

```
Documents/PetData/
  pet.json              ← Main PetState
  social/               ← Monthly social logs
    2026-04.json
  snapshots/            ← Pre-evolution snapshots
    lv1_egg.json
```

- Debounced save (500ms) on interaction
- Immediate save on app background
- Evolution snapshot for future "growth album"

### iCloud Sync

- **iCloud Documents**: full PetState sync
- **NSUbiquitousKeyValueStore**: lightweight metadata (level, XP)
- **Conflict resolution**: higher XP wins (the device that played more)
- Requires iCloud entitlement: `iCloud.com.hanfour.peerdrop`

---

## 8. Integration Points (3 total, ~18 lines)

| File | Change | Lines |
|---|---|---|
| `PeerDropApp.swift` | Add `PetEngine` + `.overlay(FloatingPetView)` | 3 |
| `ConnectionManager.swift` | Post Notification on connect/disconnect | 4 |
| `ChatManager.swift` | Post Notification on message send/receive | 2 |
| `ChatBubbleView.swift` | GeometryReader for bubble frame reporting | 6 |
| `project.yml` | Pet/ auto-included, add iCloud entitlement | 3 |

---

## 9. Module File List (MVP)

20 new Swift files, 0 art assets, 0 new dependencies.

```
Pet/
├── Model/          (7 files) PetState, PetGenome, PetLevel, PetMood, PetAction, PetLifeState, EvolutionRequirement, SocialEntry
├── Engine/         (4 files) PetEngine, InteractionTracker, PetDialogEngine, PetSocialEngine
├── Renderer/       (3 files) PixelGrid, PetRenderer, PetAnimationController
├── UI/             (5 files) FloatingPetView, GuestPetView, PetBubbleView, PetInteractionView, PetSecretChatRow
├── Persistence/    (2 files) PetStore, PetCloudSync
└── Protocol/       (2 files) PetPayload, PetGreeting
```

---

## 10. Future Sprints (Not in MVP)

| Sprint | Features |
|---|---|
| Sprint 2 | Dynamic Island, Lv.3-6 evolution, care system (feed/clean/train) |
| Sprint 3 | Battle system (vaccine/data/virus), sticker engine, animated stickers |
| Sprint 4 | Achievement wall, marketplace, gene inheritance, fusion evolution |
