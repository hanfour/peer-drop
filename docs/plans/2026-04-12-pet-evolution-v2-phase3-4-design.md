# Pet Evolution v2 — Phase 3+4: Dynamic Island, Widget, Polish

**Date:** 2026-04-12
**Status:** Approved
**Depends on:** Phase 1 + Phase 2 (merged)

## Goal

Add Dynamic Island Live Activity, Home Screen + Lock Screen widgets, evolution haptic/flash effects, time-of-day mood reactions, and clean up legacy v1 renderer.

## Project Structure

```
PeerDrop/                          (main app)
├── Pet/Shared/                    (shared with widget via file references)
│   ├── PetActivityAttributes.swift  (ActivityKit model)
│   ├── PetSnapshotRenderer.swift    (static pose → CGImage for widget)
│   └── SharedPetState.swift         (App Group read/write)
│
PeerDropWidget/                    (new Widget Extension target)
├── PeerDropWidgetBundle.swift
├── PetWidget.swift                (Home + Lock Screen widget)
├── PetLiveActivity.swift          (Dynamic Island Live Activity)
└── Info.plist
```

## App Group

- ID: `group.com.hanfour.peerdrop`
- Main app writes pet state JSON + snapshot image
- Widget/Live Activity reads from shared container
- `SharedPetState` wraps `UserDefaults(suiteName: "group.com.hanfour.peerdrop")`

## Live Activity (Dynamic Island)

### Model

```swift
struct PetActivityAttributes: ActivityAttributes {
    let petName: String
    let bodyType: BodyGene

    struct ContentState: Codable, Hashable {
        let pose: IslandPose
        let mood: PetMood
        let level: PetLevel
        let expProgress: Double
    }
}

enum IslandPose: String, Codable, Hashable {
    case sitting, sleeping, happy, eating, pooping, lonely
}
```

### Layouts

| Context | Content |
|---------|---------|
| Compact leading | 16×16 pet sprite |
| Compact trailing | Mood emoji text |
| Expanded | Pet sprite + name + level + EXP bar + mood |
| Minimal | Static 16×16 sprite |

### Lifecycle

- App enters background → start Live Activity
- State change (mood, XP, evolution, poop) → update activity
- App returns foreground → end activity
- Activity auto-expires after 8 hours

## Widget

### Home Screen (systemSmall)

- Pet sprite (128px centered)
- Name label below
- Mood + level badge
- Tap → opens app via deep link

### Lock Screen (accessoryCircular)

- 16×16 pet sprite upscaled to fill circle
- Monochrome/tinted for lock screen appearance

### Timeline

- `TimelineProvider` with 15-minute refresh
- Reads `SharedPetState` from App Group
- Uses `PetSnapshotRenderer` to produce static image

## PetSnapshotRenderer

Renders a static idle-frame CGImage from pet state without needing the full PetEngine:

```swift
enum PetSnapshotRenderer {
    static func render(body: BodyGene, level: PetLevel, mood: PetMood,
                       eyes: EyeGene, pattern: PatternGene,
                       paletteIndex: Int, scale: Int) -> CGImage?
}
```

Uses SpriteDataRegistry + PaletteSwapRenderer + SpriteCompositor. Frame always 0 (idle pose).

## Phase 4 Polish

### Evolution Effects

- `UIImpactFeedbackGenerator(.heavy)` on evolution trigger
- White flash overlay (0.3s fade out) on FloatingPetView
- 5 star particles (already implemented)

### Time-of-Day Mood

- 22:00–06:00: auto-set mood to `.sleepy` if not interacted recently
- 06:00–22:00: restore previous mood
- Check on behavior tick (1s interval, already exists)

### Legacy Cleanup

Remove:
- `PeerDrop/Pet/Renderer/PetRenderer.swift` (v1 32×32 renderer)
- `PeerDrop/Pet/Renderer/PetSpriteTemplates.swift` (v1 sprite data)
- `PeerDrop/Pet/Renderer/PixelGrid.swift` (v1 grid model)
- `PeerDrop/Pet/UI/PixelView.swift` → remove old `PixelView`, keep `SpriteImageView`
- `PetEngine.renderedGrid` property and `updateRenderedGrid()` method
- Update any remaining references

### Performance

- Log SpriteCache hit/miss ratio in DEBUG builds
- Verify memory footprint < 50MB for sprite cache at capacity
- Profile FloatingPetView render cycle
