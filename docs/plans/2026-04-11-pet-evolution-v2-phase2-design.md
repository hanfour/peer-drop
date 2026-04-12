# Pet Evolution v2 — Phase 2: All Body Types + Evolution + Interactions

**Date:** 2026-04-11
**Status:** Approved
**Depends on:** Phase 1 (merged)

## Goal

Complete all 10 body types with baby + child sprites (~1,140 frames), add baby→child evolution mechanic, and implement remaining gesture interactions (pet stroke, poop cleaning).

## Architecture

### Sprite Data Organization

```
PeerDrop/Pet/Sprites/
├── CatSpriteData.swift       (existing, baby only)
├── CatChildSpriteData.swift  (new)
├── DogSpriteData.swift       (baby + child + meta)
├── RabbitSpriteData.swift
├── BirdSpriteData.swift
├── FrogSpriteData.swift
├── BearSpriteData.swift
├── DragonSpriteData.swift
├── OctopusSpriteData.swift
├── GhostSpriteData.swift
├── SlimeSpriteData.swift
└── SpriteDataRegistry.swift  (unified lookup)
```

Each file exports:
- `static let meta: BodyMeta`
- `static let baby: [PetAction: [[[UInt8]]]]` (20 actions)
- `static let child: [PetAction: [[[UInt8]]]]` (20 actions)

### SpriteDataRegistry

Replaces the `switch body { default: fallback }` in PetRendererV2:

```swift
enum SpriteDataRegistry {
    static func sprites(for body: BodyGene, stage: PetLevel) -> [PetAction: [[[UInt8]]]]?
    static func meta(for body: BodyGene) -> BodyMeta
    static func frameCount(for body: BodyGene, stage: PetLevel, action: PetAction) -> Int
}
```

### Evolution Mechanic

Trigger conditions (baby → child):
- `experience >= 500`
- `age >= 259200` (3 days since hatch)
- Both conditions must be met simultaneously

Flow:
1. PetEngine detects threshold met on XP gain
2. Transition to `.evolving` action (flash animation, 2s)
3. Haptic feedback (heavy impact)
4. `pet.level = .child`
5. 10% chance of eyes/pattern mutation
6. Renderer switches to child sprites
7. Particle burst (star × 5)

### Gesture Interactions

**Pet stroke (swipe):**
- Horizontal DragGesture on pet with velocity > threshold
- Triggers `.petted` action
- Spawns love particles (heart × 3)
- +3 XP

**Poop cleaning:**
- Poop sprites rendered as tappable overlays in FloatingPetView
- Tap → `PoopState.clean(id:)` 
- Star particles + 1 XP
- Poops decay visually after 10 min (mood penalty kicks in)

## Body Type Visual Design (16×16)

| Body | Baby Silhouette | Child Silhouette |
|------|----------------|-----------------|
| Cat | Pointed ears, round head, raised tail | Sleeker, ears taller, tail more defined |
| Dog | Floppy ears, round body, wagging tail | Longer snout, ears more pronounced |
| Rabbit | Long ears (3-4px), round body, tiny tail | Ears with curve, body slightly elongated |
| Bird | Small wings, beak, round body | Wings larger/spread, tail feathers, crest |
| Frog | Wide flat body, large eye area | More streamlined, visible legs |
| Bear | Round ears, thick square body | Larger body, visible paw details |
| Dragon | Small horns, tiny wings, tail | Longer horns, wings spread, spiny tail |
| Octopus | Round head, short tentacles (4px) | Tentacles longer, more expressive |
| Ghost | Legless, wavy bottom edge, simple | More ethereal, trailing wisps |
| Slime | Droplet shape, jelly bounce | Larger, visible core highlight, stretch |

## Frame Counts Per Action

Standard across all body types:
- idle: 4, walking: 4, run: 4, jump: 3
- climb: 3, hang: 2, fall: 2, sitEdge: 2
- sleeping: 2, eat: 3, yawn: 2, poop: 3
- happy: 2, scared: 2, angry: 2, love: 2
- tapReact: 2, pickedUp: 2, thrown: 2, petted: 2

**Total per stage per body:** ~49 frames
**Grand total:** 10 bodies × 2 stages × 49 frames = **980 frames**

## Testing Strategy

Each body type gets a test file verifying:
- All 20 actions present
- All frames are 16×16
- Meta anchors in bounds
- Frame counts match expected

Integration test verifies:
- SpriteDataRegistry resolves all body × stage combinations
- Evolution trigger works end-to-end
- Gesture interactions update state correctly
