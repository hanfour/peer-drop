# Pet Colorful Sprite Redesign

> Date: 2026-04-05
> Status: Approved
> Supersedes rendering portion of: 2026-04-04-neo-egg-design.md

## Problem

Current pet rendering produces a solid black blob. `PixelGrid` is `[[Bool]]` (on/off), all pixels render as `.primary` (black), shapes are filled solid with no outline/fill distinction. The pet looks like a black dot, not a cute companion.

## Design Decisions

| Item | Decision |
|------|----------|
| Approach | Hybrid — pre-made pixel templates + gene-controlled variation |
| Canvas | 128×128 actual, 32×32 logical pixels, 4x upscale |
| Color | 8 fixed hand-designed palettes, mapped by personalityGene |
| Data format | Swift hardcoded `[[Int]]`, index = palette slot |
| Components | 4-layer templates: body, eyes, limbs, pattern |
| Animation | Keep 2 frames, 2 FPS |
| Template source | Hand-crafted in Swift, referencing itch.io asset pack style |

## Architecture

### Color System

#### Palette Slots

```
0 = transparent (don't draw)
1 = outline (dark border)
2 = primary (body fill)
3 = secondary (belly/inner area)
4 = highlight (eye shine, reflection)
5 = accent (pupils, blush)
6 = pattern (stripes, spots)
```

#### ColorPalette Struct

```swift
struct ColorPalette {
    let outline: Color    // slot 1
    let primary: Color    // slot 2
    let secondary: Color  // slot 3
    let highlight: Color  // slot 4
    let accent: Color     // slot 5
    let pattern: Color    // slot 6
}
```

#### 8 Palette Definitions

| # | Name | Outline | Primary | Secondary | Highlight | Accent | Pattern | Feel |
|---|------|---------|---------|-----------|-----------|--------|---------|------|
| 0 | Warm Orange | #5C3A1E | #F4A041 | #FEDE8A | #FFF5D6 | #E85D3A | #D4853A | Playful puppy |
| 1 | Sky Blue | #2A4066 | #6CB4EE | #B8E0FF | #E8F4FF | #3A7BD5 | #4A90D9 | Water spirit |
| 2 | Lavender | #4A3560 | #B08CD8 | #D8C0F0 | #F0E8FF | #8B5FC7 | #9B70D0 | Dreamy |
| 3 | Fresh Green | #2D5A1E | #7EC850 | #B8E890 | #E0FFD0 | #4CAF50 | #5DBF60 | Grass sprite |
| 4 | Cherry Pink | #6B3040 | #F08080 | #FFB8C0 | #FFE8EC | #E85080 | #E86888 | Cute girl |
| 5 | Caramel | #4A2810 | #C87830 | #E8B878 | #FFF0D8 | #A05828 | #B06838 | Brown bear |
| 6 | Slate Gray | #2A2A3A | #7888A0 | #A8B8C8 | #D8E0E8 | #5068A0 | #6078A8 | Cool type |
| 7 | Lemon Yellow | #5A5020 | #E8D44A | #F0E888 | #FFFFF0 | #C8A830 | #D0B838 | Energetic |

#### Gene → Palette Mapping

```swift
extension PetGenome {
    var paletteIndex: Int {
        min(Int(personalityGene * 8), 7)
    }
}
```

Evolution continuity: mutation limits palette shift to ±1 of current index.

### Template System

#### BodyTemplate Struct

```swift
struct BodyTemplate {
    let pixels: [[Int]]                    // body pixel data
    let eyeAnchor: (x: Int, y: Int)        // eye layer top-left
    let limbLeftAnchor: (x: Int, y: Int)   // left limb anchor
    let limbRightAnchor: (x: Int, y: Int)  // right limb anchor
    let patternRegion: CGRect              // drawable pattern area
}
```

#### Layer Inventory

**Body (3 types × 2 frames = 6 templates)**

- `round` (~18×20 px) — hamster/owl, fattest silhouette
- `square` (~18×18 px) — robot/block cat, angular
- `oval` (~14×22 px) — penguin/water drop, tall and slim

All bodies feature:
- 1px outline (index 1)
- Primary fill (index 2)
- Secondary belly region (index 3)
- Blush spots (index 5)

**Eyes (4 gene types + 3 mood overrides)**

| Type | Description | Size |
|------|-------------|------|
| dot | 1px pupil + 1px highlight | Smallest, cutest |
| round | 2px circular pupil + highlight | Classic cute |
| line | Squinting horizontal line | Lazy vibe |
| dizzy | X-shape | Dizzy/funny |
| happy (mood) | Inverted U arc | Happy curved eyes |
| sleepy (mood) | Horizontal line + ZZZ | Drowsy |
| startled (mood) | Large circles, no highlight | Shocked |

**Limbs (2 types × 2 frames = 4 templates, + none)**

- `short` — small rectangular stubs, alternate Y per frame
- `long` — diagonal lines extending from body, alternate angle per frame
- Drawn with index 2 (primary) + index 1 (outline)

**Pattern (2 types, + none)**

- `stripe` — horizontal lines on belly area (index 3) using index 6
- `spot` — 3-4 scattered dots on body using index 6
- Only drawn over existing non-zero pixels

### Egg Templates

Simpler than baby — one body template + crack overlays:

```swift
struct EggTemplate {
    let pixels: [[Int]]                      // 2 frames (breathing)
    let crackLeftPixels: [(x: Int, y: Int)]  // left crack coordinates
    let crackRightPixels: [(x: Int, y: Int)] // right crack coordinates
}
```

- Uses only 3 palette slots: outline (1), shell (2), cracks (5)
- Crack visibility: personalityGene > 0.3 → left, > 0.6 → right

### Rendering Pipeline

```
1. Create empty PixelGrid(size: 32)
2. Select BodyTemplate by genome.body + animationFrame
3. Stamp body pixels at grid center
4. Select eye template by genome.eyes (or mood override)
5. Stamp eyes at bodyTemplate.eyeAnchor
6. Select limb template by genome.limbs + animationFrame
7. Stamp limbs at bodyTemplate.limbLeftAnchor / limbRightAnchor
8. Select pattern by genome.pattern
9. Apply pattern within bodyTemplate.patternRegion (only on existing pixels)
10. PixelView maps index → ColorPalette → Color, renders at 4x scale
```

### Design Principles (from asset pack references)

- Head-to-body ratio ~1.2:1, head occupies 55% of height
- 1px outline for all shapes
- Eyes occupy 30-40% of face
- Secondary-color belly for depth
- Blush spots (index 5) under eyes for cuteness
- Round shapes preferred, avoid sharp angles

## File Changes

### Modified (6 files)

| File | Change |
|------|--------|
| `PixelGrid.swift` | `[[Bool]]` → `[[Int]]`, drawing methods accept `value: Int`, default size 32 |
| `PixelView.swift` | Accept `ColorPalette`, map index → Color, 4x upscale rendering |
| `PetRenderer.swift` | Replace algorithmic drawing with template stamping + anchor system |
| `PetEngine.swift` | Pass palette to UI, update renderedGrid type |
| `FloatingPetView.swift` | Pass palette to PixelView, displaySize → 128 |
| `GuestPetView.swift` | Same palette support for visiting pets |

### New (3 files)

| File | Purpose |
|------|---------|
| `PetPalettes.swift` | 8 ColorPalette definitions + genome mapping |
| `PetSpriteTemplates.swift` | All `[[Int]]` template data for body/eyes/limbs/pattern |
| `BodyTemplate.swift` | BodyTemplate struct with anchor points |

### Unchanged

- `PetGenome.swift` — only add `paletteIndex` computed property
- `PetState.swift` — no structural change
- `PetAnimationController.swift` — keep 2 frames, 2 FPS
- `PetMood.swift` / `PetLevel.swift` — unchanged
- `PetStore.swift` / `PetCloudSync.swift` — unchanged (PetState Codable intact)
- All Engine files — unchanged

### Backward Compatibility

- PetState Codable structure unchanged — existing saves work as-is
- Old pets automatically get colorful appearance (same genes → same palette → same templates)
- No data migration needed
