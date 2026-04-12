# Pet Evolution v2 — Phase 5: Behavior AI, Social, Pet Tab, App Store

**Date:** 2026-04-12
**Status:** Approved
**Depends on:** Phase 1-4 (merged)

## Goal

Complete pet behavior AI (sleep/feed/poop cycle, personality-driven behavior, CADisplayLink), add Pet Info Tab with food inventory and drag-to-feed, improve social features, and prepare for App Store.

## 1. Pet Info Tab

New bottom tab "寵物" with full pet profile.

### Layout

```
┌─────────────────────────────────┐
│  [Pet Sprite 128px]              │
│  ✏️ "Pixel"  Lv.2 Baby          │
│  ━━━━━━━━━━━━━━ EXP 340/500    │
│                                  │
│  ┌──────┐ ┌──────┐ ┌──────┐    │
│  │🍚 x5 │ │🐟 x2 │ │🍎 x3 │    │  ← drag food out
│  └──────┘ └──────┘ └──────┘    │
│                                  │
│  📋 基因資訊                      │
│  Body/Eyes/Pattern/Palette       │
│  Personality traits bars         │
│                                  │
│  📖 祕密日記                      │
│  [entries with partner sprites]  │
│                                  │
│  📊 統計                         │
│  Age / Interactions / Poops / Met│
└─────────────────────────────────┘
```

### Naming

- Egg → Baby evolution: force naming dialog (required)
- Pet Tab: tap name to edit anytime

### Food Inventory

```swift
struct FoodItem: Codable, Identifiable {
    let type: FoodType
    var count: Int
}

enum FoodType: String, Codable, CaseIterable {
    case rice   // 🍚 +3 XP, digest 30-120min
    case fish   // 🐟 +5 XP, mood → happy, digest 30-120min
    case apple  // 🍎 +4 XP, digest 15-60min (fast)
}
```

Food acquisition (initial):
- Daily login: rice ×3, apple ×1
- Peer connection: random ×1
- Poop cleaning: 10% chance → fish ×1

### Feed Drag Flow

1. Long-press food item in inventory → drag out
2. Food emoji appears on FloatingPetView at drop position
3. Pet detects food → runs toward it (physics-based movement)
4. Distance < 8px → eat action (3s) → food disappears
5. -1 inventory, +XP, mood effect, start digest timer
6. Cooldown: max 1 feed per 30 minutes

## 2. Behavior AI

### PetLifeState

```swift
enum PetLifeState: String, Codable {
    case idle
    case eating
    case digesting
    case pooping
    case sleeping
}
```

### Feed → Poop Cycle

```
feed → .eating (3s) → .digesting (30-120min based on food) →
.pooping action (2s) → 💩 drops at position → .idle
```

Digest timer stored in PetEngine. On poop: `poopState.drop(at: physicsState.position)`.

### Food Chase AI

```
food dropped at position P →
PetBehaviorController overrides: action = .run, target = P →
PetPhysicsEngine.applyWalk toward P each frame →
when distance(pet, P) < 8 → action = .eat → consume food
```

### Personality-Driven Behavior

| Trait | Effect |
|-------|--------|
| energy > 0.7 | idle duration halved, walk/run 2× more likely |
| timidity > 0.7 | .scared duration doubled after throw |
| mischief > 0.7 | 2× more likely to climb walls |
| curiosity > 0.7 | food chase speed 1.5× |
| independence > 0.7 | ignore tap 50% (already exists) |

Applied in `PetBehaviorController.nextBehavior` via `PersonalityTraits` parameter.

### CADisplayLink

Replace Timer-based physics loop in FloatingPetView with CADisplayLink:

```swift
private class DisplayLinkTarget {
    let update: (TimeInterval) -> Void
    init(update: @escaping (TimeInterval) -> Void) { self.update = update }
    @objc func tick(_ link: CADisplayLink) {
        update(link.targetTimestamp - link.timestamp)
    }
}
```

Use actual dt instead of fixed 1/60.

### Sleep Behavior

- Time-of-day mood already forces `.sleepy` at night
- New: when mood is `.sleepy` for >2 minutes, behavior transitions to `.sleeping` action
- Wake on tap or feed

## 3. Social Features

### Pet Meeting Flow

Already implemented: `PetSocialEngine.onPetMeeting` generates `SocialEntry` on peer connection.

Improvements:
- Trigger `.love` action + 3 heart particles on pet meeting
- Show partner pet sprite in social diary entries (render via `PetSnapshotRenderer` from `PetGreeting.genome`)

### Social Diary UI

In Pet Tab, replace simple list with:
- Partner pet mini sprite (32px) + partner name + date
- Revealed entries: full dialogue
- Unrevealed entries: blurred text + 🔒 icon
- Tap revealed entry → expand dialogue lines

## 4. App Store Preparation

- Widget strings localized (5 languages: en, zh-Hant, zh-Hans, ja, ko)
- `MARKETING_VERSION` → `2.1.0`
- Verify SpriteCache hit rate via DEBUG logs
- Remove debug prints and TODOs
- Update Fastlane metadata if needed

## Data Persistence

### New fields in PetState

```swift
struct PetState: Codable {
    // ... existing fields ...
    var foodInventory: [FoodItem]
    var lifeState: PetLifeState
    var lastFedAt: Date?
    var digestEndTime: Date?
    var stats: PetStats
}

struct PetStats: Codable {
    var totalInteractions: Int
    var poopsCleaned: Int
    var petsMet: Int
    var foodsEaten: Int
}
```

### Daily Login Refresh

Check `lastLoginDate` in PetEngine. If new day → add rice ×3, apple ×1 to inventory.
