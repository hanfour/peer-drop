# Pet Colorful Sprite Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the pet from a solid black blob into a colorful, cute pixel art companion with hand-crafted templates and palette system.

**Architecture:** Upgrade PixelGrid from `[[Bool]]` to `[[Int]]` (palette index), add 8 fixed ColorPalettes, replace algorithmic PetRenderer with a 4-layer template stamping system (body/eyes/limbs/pattern), and render at 4x scale (32×32 logical → 128×128 display).

**Tech Stack:** Swift 5.9, SwiftUI Canvas, XCTest

**Design doc:** `docs/plans/2026-04-05-pet-colorful-sprite-design.md`

---

### Task 1: Upgrade PixelGrid from Bool to Int

**Files:**
- Modify: `PeerDrop/Pet/Renderer/PixelGrid.swift`
- Modify: `PeerDropTests/PixelGridTests.swift`

**Step 1: Update tests for Int-based grid**

In `PeerDropTests/PixelGridTests.swift`, update all tests to work with `[[Int]]` instead of `[[Bool]]`:

```swift
import XCTest
@testable import PeerDrop

final class PixelGridTests: XCTestCase {

    func testEmptyGrid() {
        let grid = PixelGrid.empty()
        XCTAssertEqual(grid.size, 32)
        XCTAssertEqual(grid.activePixelCount, 0)
        for row in grid.pixels {
            for pixel in row {
                XCTAssertEqual(pixel, 0)
            }
        }
    }

    func testSetPixel() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 10, y: 20, value: 2)
        XCTAssertEqual(grid.pixels[20][10], 2)
        XCTAssertEqual(grid.activePixelCount, 1)
    }

    func testSetPixelDefaultValue() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 5, y: 5)
        XCTAssertEqual(grid.pixels[5][5], 1)
    }

    func testSetPixelOutOfBoundsIsIgnored() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 100, y: 100, value: 1)
        grid.setPixel(x: -1, y: 0, value: 1)
        grid.setPixel(x: 0, y: -1, value: 1)
        grid.setPixel(x: 32, y: 0, value: 1)
        XCTAssertEqual(grid.activePixelCount, 0)
    }

    func testDrawCircle() {
        var grid = PixelGrid.empty()
        grid.drawCircle(center: (16, 16), radius: 5, value: 2)
        XCTAssertEqual(grid.pixels[16][16], 2)
        XCTAssertFalse(grid.pixels[0][0] != 0)
        XCTAssertTrue(grid.activePixelCount > 0)
    }

    func testDrawRect() {
        var grid = PixelGrid.empty()
        grid.drawRect(origin: (10, 10), size: (4, 3), value: 3)
        XCTAssertEqual(grid.pixels[10][10], 3)
        XCTAssertEqual(grid.pixels[10][13], 3)
        XCTAssertEqual(grid.pixels[12][10], 3)
        XCTAssertEqual(grid.pixels[12][13], 3)
        XCTAssertEqual(grid.pixels[9][10], 0)
        XCTAssertEqual(grid.pixels[10][14], 0)
    }

    func testMirrorHorizontal() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 0, y: 0, value: 1)
        grid.mirror(axis: .horizontal)
        XCTAssertEqual(grid.pixels[0][0], 1)
        XCTAssertEqual(grid.pixels[0][31], 1)
    }

    func testPixelCount() {
        var grid = PixelGrid.empty()
        XCTAssertEqual(grid.activePixelCount, 0)
        grid.drawRect(origin: (0, 0), size: (2, 2), value: 1)
        XCTAssertEqual(grid.activePixelCount, 4)
    }

    func testDrawLine() {
        var grid = PixelGrid.empty()
        grid.drawLine(from: (0, 0), to: (5, 0), value: 4)
        for x in 0...5 {
            XCTAssertEqual(grid.pixels[0][x], 4, "Pixel at (\(x), 0) should be 4")
        }
        XCTAssertEqual(grid.activePixelCount, 6)
    }

    func testDrawEllipse() {
        var grid = PixelGrid.empty()
        grid.drawEllipse(center: (16, 16), rx: 8, ry: 4, value: 2)
        XCTAssertEqual(grid.pixels[16][16], 2)
        XCTAssertTrue(grid.activePixelCount > 0)
        XCTAssertEqual(grid.pixels[16][8], 2)  // cx - rx
        XCTAssertEqual(grid.pixels[16][24], 2)  // cx + rx
        XCTAssertEqual(grid.pixels[6][16], 0)   // cy - 10 should not be set (ry=4)
    }

    func testMirrorVertical() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 5, y: 0, value: 1)
        grid.mirror(axis: .vertical)
        XCTAssertEqual(grid.pixels[0][5], 1)
        XCTAssertEqual(grid.pixels[31][5], 1)
    }

    func testStampTemplate() {
        var grid = PixelGrid.empty()
        let template: [[Int]] = [
            [0, 1, 0],
            [1, 2, 1],
            [0, 1, 0]
        ]
        grid.stamp(template: template, at: (10, 10))
        XCTAssertEqual(grid.pixels[10][11], 1)
        XCTAssertEqual(grid.pixels[11][11], 2)
        XCTAssertEqual(grid.pixels[10][10], 0) // transparent stays 0
    }

    func testStampTemplateSkipsZero() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 10, y: 10, value: 3) // pre-existing pixel
        let template: [[Int]] = [[0]]
        grid.stamp(template: template, at: (10, 10))
        XCTAssertEqual(grid.pixels[10][10], 3) // should NOT be overwritten
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PixelGridTests -quiet 2>&1 | tail -20`

Expected: Build fails — `PixelGrid` still uses `[[Bool]]`

**Step 3: Implement PixelGrid upgrade**

Replace `PeerDrop/Pet/Renderer/PixelGrid.swift`:

```swift
import Foundation

// MARK: - Axis

enum Axis {
    case horizontal
    case vertical
}

// MARK: - PixelGrid

struct PixelGrid: Equatable {
    let size: Int
    var pixels: [[Int]]

    static func empty(size: Int = 32) -> PixelGrid {
        PixelGrid(size: size, pixels: Array(repeating: Array(repeating: 0, count: size), count: size))
    }

    var activePixelCount: Int {
        pixels.reduce(0) { $0 + $1.filter { $0 != 0 }.count }
    }

    // MARK: - Drawing Primitives

    mutating func setPixel(x: Int, y: Int, value: Int = 1) {
        guard x >= 0, x < size, y >= 0, y < size else { return }
        pixels[y][x] = value
    }

    mutating func drawCircle(center: (Int, Int), radius: Int, value: Int = 1) {
        drawEllipse(center: center, rx: radius, ry: radius, value: value)
    }

    mutating func drawEllipse(center: (Int, Int), rx: Int, ry: Int, value: Int = 1) {
        let cx = center.0
        let cy = center.1
        guard rx > 0, ry > 0 else { return }
        for y in (cy - ry)...(cy + ry) {
            for x in (cx - rx)...(cx + rx) {
                let dx = x - cx
                let dy = y - cy
                if dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry {
                    setPixel(x: x, y: y, value: value)
                }
            }
        }
    }

    mutating func drawRect(origin: (Int, Int), size rectSize: (Int, Int), value: Int = 1) {
        let ox = origin.0
        let oy = origin.1
        for y in oy..<(oy + rectSize.1) {
            for x in ox..<(ox + rectSize.0) {
                setPixel(x: x, y: y, value: value)
            }
        }
    }

    mutating func drawLine(from: (Int, Int), to: (Int, Int), value: Int = 1) {
        var x0 = from.0
        var y0 = from.1
        let x1 = to.0
        let y1 = to.1

        let dx = abs(x1 - x0)
        let dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx + dy

        while true {
            setPixel(x: x0, y: y0, value: value)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy {
                err += dy
                x0 += sx
            }
            if e2 <= dx {
                err += dx
                y0 += sy
            }
        }
    }

    /// Stamps a 2D template onto the grid at the given top-left position.
    /// Zeros in the template are transparent (do not overwrite existing pixels).
    mutating func stamp(template: [[Int]], at origin: (Int, Int)) {
        for (row, line) in template.enumerated() {
            for (col, val) in line.enumerated() {
                guard val != 0 else { continue }
                setPixel(x: origin.0 + col, y: origin.1 + row, value: val)
            }
        }
    }

    mutating func mirror(axis: Axis) {
        switch axis {
        case .horizontal:
            for y in 0..<size {
                for x in 0..<(size / 2) {
                    let mirrorX = size - 1 - x
                    if pixels[y][x] != 0 {
                        pixels[y][mirrorX] = pixels[y][x]
                    } else if pixels[y][mirrorX] != 0 {
                        pixels[y][x] = pixels[y][mirrorX]
                    }
                }
            }
        case .vertical:
            for y in 0..<(size / 2) {
                let mirrorY = size - 1 - y
                for x in 0..<size {
                    if pixels[y][x] != 0 {
                        pixels[mirrorY][x] = pixels[y][x]
                    } else if pixels[mirrorY][x] != 0 {
                        pixels[y][x] = pixels[mirrorY][x]
                    }
                }
            }
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PixelGridTests -quiet 2>&1 | tail -20`

Expected: All PixelGridTests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/PixelGrid.swift PeerDropTests/PixelGridTests.swift
git commit -m "refactor: upgrade PixelGrid from Bool to Int for color palette support"
```

---

### Task 2: Add ColorPalette and PetPalettes

**Files:**
- Create: `PeerDrop/Pet/Renderer/PetPalettes.swift`
- Modify: `PeerDrop/Pet/Model/PetGenome.swift:56-57`
- Create: `PeerDropTests/PetPalettesTests.swift`

**Step 1: Write tests**

```swift
import XCTest
@testable import PeerDrop

final class PetPalettesTests: XCTestCase {

    func testPaletteCount() {
        XCTAssertEqual(PetPalettes.all.count, 8)
    }

    func testColorForValidIndex() {
        let palette = PetPalettes.all[0]
        XCTAssertNotNil(palette.color(for: 1)) // outline
        XCTAssertNotNil(palette.color(for: 6)) // pattern
    }

    func testColorForZeroReturnsNil() {
        let palette = PetPalettes.all[0]
        XCTAssertNil(palette.color(for: 0)) // transparent
    }

    func testColorForOutOfRangeReturnsNil() {
        let palette = PetPalettes.all[0]
        XCTAssertNil(palette.color(for: 99))
    }

    func testGenomePaletteIndex() {
        let low = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 0.0)
        XCTAssertEqual(low.paletteIndex, 0)

        let mid = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 0.5)
        XCTAssertEqual(mid.paletteIndex, 4)

        let high = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 0.99)
        XCTAssertEqual(high.paletteIndex, 7)

        let max = PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 1.0)
        XCTAssertEqual(max.paletteIndex, 7)
    }

    func testAllPalettesHaveSixColors() {
        for (i, palette) in PetPalettes.all.enumerated() {
            for slot in 1...6 {
                XCTAssertNotNil(palette.color(for: slot), "Palette \(i) missing color for slot \(slot)")
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetPalettesTests -quiet 2>&1 | tail -20`

Expected: Build fails — `PetPalettes` and `ColorPalette` don't exist yet

**Step 3: Create PetPalettes.swift**

Create `PeerDrop/Pet/Renderer/PetPalettes.swift`:

```swift
import SwiftUI

struct ColorPalette: Equatable {
    let outline: Color    // slot 1
    let primary: Color    // slot 2
    let secondary: Color  // slot 3
    let highlight: Color  // slot 4
    let accent: Color     // slot 5
    let pattern: Color    // slot 6

    func color(for index: Int) -> Color? {
        switch index {
        case 1: return outline
        case 2: return primary
        case 3: return secondary
        case 4: return highlight
        case 5: return accent
        case 6: return pattern
        default: return nil
        }
    }
}

enum PetPalettes {
    static let all: [ColorPalette] = [
        // 0: Warm Orange — playful puppy
        ColorPalette(
            outline:   Color(red: 0x5C/255, green: 0x3A/255, blue: 0x1E/255),
            primary:   Color(red: 0xF4/255, green: 0xA0/255, blue: 0x41/255),
            secondary: Color(red: 0xFE/255, green: 0xDE/255, blue: 0x8A/255),
            highlight: Color(red: 0xFF/255, green: 0xF5/255, blue: 0xD6/255),
            accent:    Color(red: 0xE8/255, green: 0x5D/255, blue: 0x3A/255),
            pattern:   Color(red: 0xD4/255, green: 0x85/255, blue: 0x3A/255)
        ),
        // 1: Sky Blue — water spirit
        ColorPalette(
            outline:   Color(red: 0x2A/255, green: 0x40/255, blue: 0x66/255),
            primary:   Color(red: 0x6C/255, green: 0xB4/255, blue: 0xEE/255),
            secondary: Color(red: 0xB8/255, green: 0xE0/255, blue: 0xFF/255),
            highlight: Color(red: 0xE8/255, green: 0xF4/255, blue: 0xFF/255),
            accent:    Color(red: 0x3A/255, green: 0x7B/255, blue: 0xD5/255),
            pattern:   Color(red: 0x4A/255, green: 0x90/255, blue: 0xD9/255)
        ),
        // 2: Lavender — dreamy
        ColorPalette(
            outline:   Color(red: 0x4A/255, green: 0x35/255, blue: 0x60/255),
            primary:   Color(red: 0xB0/255, green: 0x8C/255, blue: 0xD8/255),
            secondary: Color(red: 0xD8/255, green: 0xC0/255, blue: 0xF0/255),
            highlight: Color(red: 0xF0/255, green: 0xE8/255, blue: 0xFF/255),
            accent:    Color(red: 0x8B/255, green: 0x5F/255, blue: 0xC7/255),
            pattern:   Color(red: 0x9B/255, green: 0x70/255, blue: 0xD0/255)
        ),
        // 3: Fresh Green — grass sprite
        ColorPalette(
            outline:   Color(red: 0x2D/255, green: 0x5A/255, blue: 0x1E/255),
            primary:   Color(red: 0x7E/255, green: 0xC8/255, blue: 0x50/255),
            secondary: Color(red: 0xB8/255, green: 0xE8/255, blue: 0x90/255),
            highlight: Color(red: 0xE0/255, green: 0xFF/255, blue: 0xD0/255),
            accent:    Color(red: 0x4C/255, green: 0xAF/255, blue: 0x50/255),
            pattern:   Color(red: 0x5D/255, green: 0xBF/255, blue: 0x60/255)
        ),
        // 4: Cherry Pink — cute girl
        ColorPalette(
            outline:   Color(red: 0x6B/255, green: 0x30/255, blue: 0x40/255),
            primary:   Color(red: 0xF0/255, green: 0x80/255, blue: 0x80/255),
            secondary: Color(red: 0xFF/255, green: 0xB8/255, blue: 0xC0/255),
            highlight: Color(red: 0xFF/255, green: 0xE8/255, blue: 0xEC/255),
            accent:    Color(red: 0xE8/255, green: 0x50/255, blue: 0x80/255),
            pattern:   Color(red: 0xE8/255, green: 0x68/255, blue: 0x88/255)
        ),
        // 5: Caramel — brown bear
        ColorPalette(
            outline:   Color(red: 0x4A/255, green: 0x28/255, blue: 0x10/255),
            primary:   Color(red: 0xC8/255, green: 0x78/255, blue: 0x30/255),
            secondary: Color(red: 0xE8/255, green: 0xB8/255, blue: 0x78/255),
            highlight: Color(red: 0xFF/255, green: 0xF0/255, blue: 0xD8/255),
            accent:    Color(red: 0xA0/255, green: 0x58/255, blue: 0x28/255),
            pattern:   Color(red: 0xB0/255, green: 0x68/255, blue: 0x38/255)
        ),
        // 6: Slate Gray — cool type
        ColorPalette(
            outline:   Color(red: 0x2A/255, green: 0x2A/255, blue: 0x3A/255),
            primary:   Color(red: 0x78/255, green: 0x88/255, blue: 0xA0/255),
            secondary: Color(red: 0xA8/255, green: 0xB8/255, blue: 0xC8/255),
            highlight: Color(red: 0xD8/255, green: 0xE0/255, blue: 0xE8/255),
            accent:    Color(red: 0x50/255, green: 0x68/255, blue: 0xA0/255),
            pattern:   Color(red: 0x60/255, green: 0x78/255, blue: 0xA8/255)
        ),
        // 7: Lemon Yellow — energetic
        ColorPalette(
            outline:   Color(red: 0x5A/255, green: 0x50/255, blue: 0x20/255),
            primary:   Color(red: 0xE8/255, green: 0xD4/255, blue: 0x4A/255),
            secondary: Color(red: 0xF0/255, green: 0xE8/255, blue: 0x88/255),
            highlight: Color(red: 0xFF/255, green: 0xFF/255, blue: 0xF0/255),
            accent:    Color(red: 0xC8/255, green: 0xA8/255, blue: 0x30/255),
            pattern:   Color(red: 0xD0/255, green: 0xB8/255, blue: 0x38/255)
        ),
    ]

    static func palette(for genome: PetGenome) -> ColorPalette {
        all[genome.paletteIndex]
    }
}
```

**Step 4: Add paletteIndex to PetGenome**

In `PeerDrop/Pet/Model/PetGenome.swift`, add after `static let canvasSize = 64`:

```swift
static let canvasSize = 32

var paletteIndex: Int {
    min(Int(personalityGene * 8), 7)
}
```

Note: also change `canvasSize` from 64 to 32.

**Step 5: Run xcodegen and tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetPalettesTests -quiet 2>&1 | tail -20`

Expected: All PetPalettesTests PASS

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Renderer/PetPalettes.swift PeerDrop/Pet/Model/PetGenome.swift PeerDropTests/PetPalettesTests.swift
git commit -m "feat: add ColorPalette system with 8 hand-designed palettes"
```

---

### Task 3: Create BodyTemplate and Sprite Templates

**Files:**
- Create: `PeerDrop/Pet/Renderer/BodyTemplate.swift`
- Create: `PeerDrop/Pet/Renderer/PetSpriteTemplates.swift`
- Create: `PeerDropTests/PetSpriteTemplatesTests.swift`

**Step 1: Write tests**

```swift
import XCTest
@testable import PeerDrop

final class PetSpriteTemplatesTests: XCTestCase {

    // MARK: - Egg templates

    func testEggTemplateHasTwoFrames() {
        XCTAssertEqual(PetSpriteTemplates.egg.count, 2)
    }

    func testEggTemplatesAreNonEmpty() {
        for (i, frame) in PetSpriteTemplates.egg.enumerated() {
            let hasPixels = frame.pixels.flatMap { $0 }.contains(where: { $0 != 0 })
            XCTAssertTrue(hasPixels, "Egg frame \(i) should have non-zero pixels")
        }
    }

    func testEggCrackCoordinatesExist() {
        let egg = PetSpriteTemplates.egg[0]
        XCTAssertFalse(egg.crackLeftPixels.isEmpty)
        XCTAssertFalse(egg.crackRightPixels.isEmpty)
    }

    // MARK: - Body templates

    func testAllBodyTypesHaveTemplates() {
        for body in BodyGene.allCases {
            let templates = PetSpriteTemplates.body(for: body)
            XCTAssertEqual(templates.count, 2, "\(body) should have 2 frames")
            for (i, t) in templates.enumerated() {
                let hasPixels = t.pixels.flatMap { $0 }.contains(where: { $0 != 0 })
                XCTAssertTrue(hasPixels, "\(body) frame \(i) should have pixels")
            }
        }
    }

    func testBodyTemplatesHaveAnchors() {
        for body in BodyGene.allCases {
            let t = PetSpriteTemplates.body(for: body)[0]
            // Anchors should be within reasonable range (0-31)
            XCTAssertTrue(t.eyeAnchor.x >= 0 && t.eyeAnchor.x < 32)
            XCTAssertTrue(t.eyeAnchor.y >= 0 && t.eyeAnchor.y < 32)
            XCTAssertTrue(t.limbLeftAnchor.x >= 0 && t.limbLeftAnchor.x < 32)
            XCTAssertTrue(t.limbRightAnchor.x >= 0 && t.limbRightAnchor.x < 32)
        }
    }

    // MARK: - Eye templates

    func testAllEyeTypesHaveTemplates() {
        for eye in EyeGene.allCases {
            let template = PetSpriteTemplates.eyes(for: eye)
            let hasPixels = template.flatMap { $0 }.contains(where: { $0 != 0 })
            XCTAssertTrue(hasPixels, "\(eye) eyes should have pixels")
        }
    }

    func testMoodEyeOverrides() {
        let happy = PetSpriteTemplates.eyesMood(.happy)
        let sleepy = PetSpriteTemplates.eyesMood(.sleepy)
        let startled = PetSpriteTemplates.eyesMood(.startled)
        XCTAssertNotNil(happy)
        XCTAssertNotNil(sleepy)
        XCTAssertNotNil(startled)
        XCTAssertNil(PetSpriteTemplates.eyesMood(.curious)) // no override
    }

    // MARK: - Limb templates

    func testLimbTemplates() {
        let short = PetSpriteTemplates.limbs(for: .short, frame: 0)
        XCTAssertNotNil(short)
        let long = PetSpriteTemplates.limbs(for: .long, frame: 0)
        XCTAssertNotNil(long)
        let none = PetSpriteTemplates.limbs(for: .none, frame: 0)
        XCTAssertNil(none)
    }

    // MARK: - Pattern templates

    func testPatternTemplates() {
        XCTAssertNotNil(PetSpriteTemplates.pattern(for: .stripe))
        XCTAssertNotNil(PetSpriteTemplates.pattern(for: .spot))
        XCTAssertNil(PetSpriteTemplates.pattern(for: .none))
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetSpriteTemplatesTests -quiet 2>&1 | tail -20`

Expected: Build fails

**Step 3: Create BodyTemplate.swift**

Create `PeerDrop/Pet/Renderer/BodyTemplate.swift`:

```swift
import Foundation

struct BodyTemplate {
    let pixels: [[Int]]
    let eyeAnchor: (x: Int, y: Int)
    let limbLeftAnchor: (x: Int, y: Int)
    let limbRightAnchor: (x: Int, y: Int)
    let patternOrigin: (x: Int, y: Int)
    let patternSize: (w: Int, h: Int)
}

struct EggTemplate {
    let pixels: [[Int]]
    let crackLeftPixels: [(x: Int, y: Int)]
    let crackRightPixels: [(x: Int, y: Int)]
}

struct LimbTemplate {
    let left: [[Int]]
    let right: [[Int]]
    let leftOffset: (x: Int, y: Int)
    let rightOffset: (x: Int, y: Int)
}
```

**Step 4: Create PetSpriteTemplates.swift**

Create `PeerDrop/Pet/Renderer/PetSpriteTemplates.swift`.

This file contains all the hand-crafted `[[Int]]` pixel data. The templates use the palette index convention:
- 0 = transparent
- 1 = outline
- 2 = primary
- 3 = secondary (belly)
- 4 = highlight (eye shine)
- 5 = accent (pupils, blush)
- 6 = pattern

The actual pixel data arrays will be large (~200-400 lines total). Each template should be designed following the design doc principles: 1px outline, large head, belly region, blush spots.

```swift
import Foundation

enum PetSpriteTemplates {

    // MARK: - Egg

    static let egg: [EggTemplate] = [
        // Frame 0: normal
        EggTemplate(
            pixels: [
                // ~12×16 egg shape, centered for stamping at (10, 7)
                // Row-by-row pixel data with outline (1), shell fill (2)
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
            ],
            crackLeftPixels: [(3, 6), (4, 7), (3, 8)],
            crackRightPixels: [(10, 5), (9, 6), (10, 7)]
        ),
        // Frame 1: breathing (slightly taller)
        EggTemplate(
            pixels: [
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,2,2,2,2,2,2,1,0,0,0],
                [0,0,0,0,1,1,1,1,1,1,0,0,0,0],
            ],
            crackLeftPixels: [(3, 6), (4, 7), (3, 8)],
            crackRightPixels: [(10, 5), (9, 6), (10, 7)]
        ),
    ]

    // MARK: - Body

    static func body(for gene: BodyGene) -> [BodyTemplate] {
        switch gene {
        case .round: return bodyRound
        case .square: return bodySquare
        case .oval: return bodyOval
        }
    }

    // Round: ~18×18, hamster/owl style, large head ratio
    // Frame 0 and Frame 1 (bounce offset built into Y placement, not template)
    private static let bodyRound: [BodyTemplate] = [
        BodyTemplate(
            pixels: [
                [0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0],
                [0,0,0,0,1,1,2,2,2,2,2,2,1,1,0,0,0,0],
                [0,0,0,1,2,2,2,2,2,2,2,2,2,2,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,5,2,2,2,2,2,2,5,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,3,3,3,3,3,3,2,2,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,3,3,2,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,3,3,2,2,2,2,1],
                [0,1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1,0],
                [0,1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,2,2,2,2,2,2,2,2,2,2,1,0,0,0],
                [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
            ],
            eyeAnchor: (x: 4, y: 4),
            limbLeftAnchor: (x: -3, y: 7),
            limbRightAnchor: (x: 18, y: 7),
            patternOrigin: (x: 6, y: 8),
            patternSize: (w: 6, h: 4)
        ),
        // Frame 1: same shape (bounce handled by render offset)
        BodyTemplate(
            pixels: [
                [0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0],
                [0,0,0,0,1,1,2,2,2,2,2,2,1,1,0,0,0,0],
                [0,0,0,1,2,2,2,2,2,2,2,2,2,2,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,5,2,2,2,2,2,2,5,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,3,3,3,3,3,3,2,2,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,3,3,2,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,3,3,2,2,2,2,1],
                [0,1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1,0],
                [0,1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,2,2,2,2,2,2,2,2,2,2,1,0,0,0],
                [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
            ],
            eyeAnchor: (x: 4, y: 4),
            limbLeftAnchor: (x: -3, y: 7),
            limbRightAnchor: (x: 18, y: 7),
            patternOrigin: (x: 6, y: 8),
            patternSize: (w: 6, h: 4)
        ),
    ]

    // Square: ~16×16, block cat / robot style
    private static let bodySquare: [BodyTemplate] = [
        BodyTemplate(
            pixels: [
                [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,5,2,2,2,2,2,2,5,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
            ],
            eyeAnchor: (x: 3, y: 3),
            limbLeftAnchor: (x: -3, y: 6),
            limbRightAnchor: (x: 16, y: 6),
            patternOrigin: (x: 5, y: 7),
            patternSize: (w: 6, h: 4)
        ),
        BodyTemplate(
            pixels: [
                [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,5,2,2,2,2,2,2,5,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,3,3,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
            ],
            eyeAnchor: (x: 3, y: 3),
            limbLeftAnchor: (x: -3, y: 6),
            limbRightAnchor: (x: 16, y: 6),
            patternOrigin: (x: 5, y: 7),
            patternSize: (w: 6, h: 4)
        ),
    ]

    // Oval: ~14×20, penguin/water drop style
    private static let bodyOval: [BodyTemplate] = [
        BodyTemplate(
            pixels: [
                [0,0,0,1,1,1,1,1,1,1,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,5,2,2,2,2,5,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,2,2,2,2,1],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,1,1,1,1,1,1,1,0,0,0],
            ],
            eyeAnchor: (x: 3, y: 3),
            limbLeftAnchor: (x: -3, y: 7),
            limbRightAnchor: (x: 14, y: 7),
            patternOrigin: (x: 3, y: 7),
            patternSize: (w: 8, h: 5)
        ),
        BodyTemplate(
            pixels: [
                [0,0,0,1,1,1,1,1,1,1,1,0,0,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,5,2,2,2,2,5,2,2,2,1],
                [1,2,2,2,2,2,2,2,2,2,2,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,3,3,3,3,3,3,3,3,2,2,1],
                [1,2,2,2,3,3,3,3,3,3,2,2,2,1],
                [1,2,2,2,2,3,3,3,3,2,2,2,2,1],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,1,2,2,2,2,2,2,2,2,2,2,1,0],
                [0,0,1,2,2,2,2,2,2,2,2,1,0,0],
                [0,0,0,1,1,1,1,1,1,1,1,0,0,0],
            ],
            eyeAnchor: (x: 3, y: 3),
            limbLeftAnchor: (x: -3, y: 7),
            limbRightAnchor: (x: 14, y: 7),
            patternOrigin: (x: 3, y: 7),
            patternSize: (w: 8, h: 5)
        ),
    ]

    // MARK: - Eyes

    static func eyes(for gene: EyeGene) -> [[Int]] {
        switch gene {
        case .dot: return eyesDot
        case .round: return eyesRound
        case .line: return eyesLine
        case .dizzy: return eyesDizzy
        }
    }

    static func eyesMood(_ mood: PetMood) -> [[Int]]? {
        switch mood {
        case .happy: return eyesHappy
        case .sleepy: return eyesSleepy
        case .startled: return eyesStartled
        default: return nil
        }
    }

    // Eyes are ~10×3 (both eyes in one template)
    // Left eye at col 0-3, right eye at col 6-9

    // Dot: tiny 1px pupil (5) + 1px highlight (4)
    private static let eyesDot: [[Int]] = [
        [0,4,0,0,0,0,0,4,0,0],
        [0,5,0,0,0,0,0,5,0,0],
    ]

    // Round: 2px circle eyes with highlight
    private static let eyesRound: [[Int]] = [
        [0,5,5,0,0,0,0,5,5,0],
        [5,5,4,0,0,0,5,5,4,0],
        [0,5,5,0,0,0,0,5,5,0],
    ]

    // Line: squinting horizontal
    private static let eyesLine: [[Int]] = [
        [5,5,5,0,0,0,5,5,5,0],
    ]

    // Dizzy: X-shaped
    private static let eyesDizzy: [[Int]] = [
        [5,0,5,0,0,0,5,0,5,0],
        [0,5,0,0,0,0,0,5,0,0],
        [5,0,5,0,0,0,5,0,5,0],
    ]

    // Happy: inverted U arcs (^_^)
    private static let eyesHappy: [[Int]] = [
        [5,0,5,0,0,0,5,0,5,0],
        [0,5,0,0,0,0,0,5,0,0],
    ]

    // Sleepy: horizontal line + ZZZ
    private static let eyesSleepy: [[Int]] = [
        [0,0,0,0,0,0,0,0,0,5],
        [0,0,0,0,0,0,0,0,5,0],
        [5,5,5,0,0,0,5,5,5,0],
    ]

    // Startled: large circle eyes, no highlight
    private static let eyesStartled: [[Int]] = [
        [0,5,5,0,0,0,0,5,5,0],
        [5,0,0,5,0,0,5,0,0,5],
        [5,0,0,5,0,0,5,0,0,5],
        [0,5,5,0,0,0,0,5,5,0],
    ]

    // MARK: - Limbs

    static func limbs(for gene: LimbGene, frame: Int) -> LimbTemplate? {
        switch gene {
        case .short: return frame % 2 == 0 ? limbsShortF0 : limbsShortF1
        case .long: return frame % 2 == 0 ? limbsLongF0 : limbsLongF1
        case .none: return nil
        }
    }

    // Short: small 3×4 stubs
    private static let limbsShortF0 = LimbTemplate(
        left:  [[1,2,2],[1,2,2],[1,2,2],[1,1,1]],
        right: [[2,2,1],[2,2,1],[2,2,1],[1,1,1]],
        leftOffset: (x: 0, y: 0),
        rightOffset: (x: 0, y: 2)
    )
    private static let limbsShortF1 = LimbTemplate(
        left:  [[1,2,2],[1,2,2],[1,2,2],[1,1,1]],
        right: [[2,2,1],[2,2,1],[2,2,1],[1,1,1]],
        leftOffset: (x: 0, y: 2),
        rightOffset: (x: 0, y: 0)
    )

    // Long: diagonal lines (5×6)
    private static let limbsLongF0 = LimbTemplate(
        left:  [[0,0,1,2,2],[0,1,2,2,0],[1,2,2,0,0],[1,2,0,0,0],[1,2,0,0,0],[1,1,0,0,0]],
        right: [[2,2,1,0,0],[0,2,2,1,0],[0,0,2,2,1],[0,0,0,2,1],[0,0,0,2,1],[0,0,0,1,1]],
        leftOffset: (x: 0, y: 0),
        rightOffset: (x: 0, y: 0)
    )
    private static let limbsLongF1 = LimbTemplate(
        left:  [[1,2,2,0,0],[0,1,2,2,0],[0,0,1,2,2],[0,0,1,2,0],[0,0,1,2,0],[0,0,1,1,0]],
        right: [[0,0,2,2,1],[0,2,2,1,0],[2,2,1,0,0],[0,2,1,0,0],[0,2,1,0,0],[0,1,1,0,0]],
        leftOffset: (x: 0, y: 0),
        rightOffset: (x: 0, y: 0)
    )

    // MARK: - Pattern

    static func pattern(for gene: PatternGene) -> [[Int]]? {
        switch gene {
        case .stripe: return patternStripe
        case .spot: return patternSpot
        case .none: return nil
        }
    }

    // Stripe: horizontal lines using pattern color (6)
    // Applied within body's patternRegion, only on existing pixels
    private static let patternStripe: [[Int]] = [
        [6,6,6,6,6,6,6,6],
        [0,0,0,0,0,0,0,0],
        [6,6,6,6,6,6,6,6],
        [0,0,0,0,0,0,0,0],
        [6,6,6,6,6,6,6,6],
    ]

    // Spot: scattered dots
    private static let patternSpot: [[Int]] = [
        [0,0,6,0,0,0,0,0],
        [0,0,0,0,0,6,0,0],
        [0,0,0,0,0,0,0,0],
        [0,6,0,0,0,0,6,0],
        [0,0,0,0,6,0,0,0],
    ]
}
```

**Step 5: Run xcodegen and tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetSpriteTemplatesTests -quiet 2>&1 | tail -20`

Expected: All PetSpriteTemplatesTests PASS

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Renderer/BodyTemplate.swift PeerDrop/Pet/Renderer/PetSpriteTemplates.swift PeerDropTests/PetSpriteTemplatesTests.swift
git commit -m "feat: add hand-crafted sprite templates for egg, body, eyes, limbs, pattern"
```

---

### Task 4: Rewrite PetRenderer to Use Templates

**Files:**
- Modify: `PeerDrop/Pet/Renderer/PetRenderer.swift`
- Modify: `PeerDropTests/PetRendererTests.swift`

**Step 1: Update PetRendererTests**

```swift
import XCTest
@testable import PeerDrop

final class PetRendererTests: XCTestCase {

    private let renderer = PetRenderer()

    private func makeGenome(
        body: BodyGene = .round,
        eyes: EyeGene = .dot,
        limbs: LimbGene = .short,
        pattern: PatternGene = .none,
        personality: Double = 0.5
    ) -> PetGenome {
        PetGenome(body: body, eyes: eyes, limbs: limbs, pattern: pattern, personalityGene: personality)
    }

    func testRenderEggProducesPixels() {
        let genome = makeGenome()
        let grid = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        XCTAssertEqual(grid.size, 32)
        XCTAssertTrue(grid.activePixelCount > 0, "Egg should produce visible pixels")
    }

    func testRenderBabyProducesMorePixelsThanEgg() {
        let genome = makeGenome()
        let egg = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        let baby = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        XCTAssertGreaterThan(baby.activePixelCount, egg.activePixelCount)
    }

    func testDifferentGenomesProduceDifferentPixels() {
        let genome1 = makeGenome(body: .round, eyes: .dot, limbs: .short)
        let genome2 = makeGenome(body: .square, eyes: .dizzy, limbs: .long)
        let grid1 = renderer.render(genome: genome1, level: .baby, mood: .curious, animationFrame: 0)
        let grid2 = renderer.render(genome: genome2, level: .baby, mood: .curious, animationFrame: 0)
        XCTAssertNotEqual(grid1, grid2)
    }

    func testMoodAffectsEyes() {
        let genome = makeGenome()
        let happy = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        let sleepy = renderer.render(genome: genome, level: .baby, mood: .sleepy, animationFrame: 0)
        XCTAssertNotEqual(happy, sleepy)
    }

    func testEggBreathAnimation() {
        let genome = makeGenome()
        let frame0 = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 0)
        let frame1 = renderer.render(genome: genome, level: .egg, mood: .happy, animationFrame: 1)
        XCTAssertNotEqual(frame0, frame1)
    }

    func testEggCrackLinesAppearWithHighPersonality() {
        let lowPG = makeGenome(personality: 0.1)
        let highPG = makeGenome(personality: 0.8)
        let gridLow = renderer.render(genome: lowPG, level: .egg, mood: .happy, animationFrame: 0)
        let gridHigh = renderer.render(genome: highPG, level: .egg, mood: .happy, animationFrame: 0)
        XCTAssertGreaterThan(gridHigh.activePixelCount, gridLow.activePixelCount)
    }

    func testAllBodyTypesRender() {
        for body in BodyGene.allCases {
            let genome = makeGenome(body: body)
            let grid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
            XCTAssertTrue(grid.activePixelCount > 0, "Body type \(body) should produce pixels")
        }
    }

    func testAllLimbTypesRender() {
        for limb in LimbGene.allCases {
            let genome = makeGenome(limbs: limb)
            let grid = renderer.render(genome: genome, level: .baby, mood: .curious, animationFrame: 0)
            XCTAssertTrue(grid.activePixelCount > 0)
        }
    }

    func testGridSizeIs32() {
        let genome = makeGenome()
        let grid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        XCTAssertEqual(grid.size, 32)
    }

    func testRenderUsesMultipleColorIndices() {
        let genome = makeGenome()
        let grid = renderer.render(genome: genome, level: .baby, mood: .happy, animationFrame: 0)
        let uniqueValues = Set(grid.pixels.flatMap { $0 }.filter { $0 != 0 })
        XCTAssertTrue(uniqueValues.count >= 3, "Baby should use at least 3 color indices, got \(uniqueValues)")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetRendererTests -quiet 2>&1 | tail -20`

Expected: Fails — old renderer still uses Bool-based drawing

**Step 3: Rewrite PetRenderer.swift**

```swift
import Foundation

class PetRenderer {

    func render(genome: PetGenome, level: PetLevel, mood: PetMood, animationFrame: Int) -> PixelGrid {
        switch level {
        case .egg:
            return renderEgg(genome: genome, frame: animationFrame)
        case .baby:
            return renderBaby(genome: genome, mood: mood, frame: animationFrame)
        }
    }

    // MARK: - Egg

    private func renderEgg(genome: PetGenome, frame: Int) -> PixelGrid {
        var grid = PixelGrid.empty()
        let eggTemplate = PetSpriteTemplates.egg[frame % PetSpriteTemplates.egg.count]

        // Center the egg template on the 32×32 grid
        let templateWidth = eggTemplate.pixels[0].count
        let templateHeight = eggTemplate.pixels.count
        let ox = (32 - templateWidth) / 2
        let oy = (32 - templateHeight) / 2

        grid.stamp(template: eggTemplate.pixels, at: (ox, oy))

        // Crack lines based on personality gene
        let pg = genome.personalityGene
        if pg > 0.3 {
            for p in eggTemplate.crackLeftPixels {
                grid.setPixel(x: ox + p.x, y: oy + p.y, value: 5)
            }
        }
        if pg > 0.6 {
            for p in eggTemplate.crackRightPixels {
                grid.setPixel(x: ox + p.x, y: oy + p.y, value: 5)
            }
        }

        return grid
    }

    // MARK: - Baby

    private func renderBaby(genome: PetGenome, mood: PetMood, frame: Int) -> PixelGrid {
        var grid = PixelGrid.empty()
        let bounce = frame % 2

        // 1. Body
        let bodyTemplates = PetSpriteTemplates.body(for: genome.body)
        let bodyTemplate = bodyTemplates[frame % bodyTemplates.count]
        let bodyWidth = bodyTemplate.pixels[0].count
        let bodyHeight = bodyTemplate.pixels.count
        let bodyX = (32 - bodyWidth) / 2
        let bodyY = (32 - bodyHeight) / 2 + bounce

        grid.stamp(template: bodyTemplate.pixels, at: (bodyX, bodyY))

        // 2. Eyes
        let eyeTemplate: [[Int]]
        if let moodOverride = PetSpriteTemplates.eyesMood(mood) {
            eyeTemplate = moodOverride
        } else {
            eyeTemplate = PetSpriteTemplates.eyes(for: genome.eyes)
        }
        let eyeX = bodyX + bodyTemplate.eyeAnchor.x
        let eyeY = bodyY + bodyTemplate.eyeAnchor.y
        grid.stamp(template: eyeTemplate, at: (eyeX, eyeY))

        // 3. Limbs
        if let limbTemplate = PetSpriteTemplates.limbs(for: genome.limbs, frame: frame) {
            let leftX = bodyX + bodyTemplate.limbLeftAnchor.x + limbTemplate.leftOffset.x
            let leftY = bodyY + bodyTemplate.limbLeftAnchor.y + limbTemplate.leftOffset.y
            grid.stamp(template: limbTemplate.left, at: (leftX, leftY))

            let rightX = bodyX + bodyTemplate.limbRightAnchor.x + limbTemplate.rightOffset.x
            let rightY = bodyY + bodyTemplate.limbRightAnchor.y + limbTemplate.rightOffset.y
            grid.stamp(template: limbTemplate.right, at: (rightX, rightY))
        }

        // 4. Pattern (only overwrite existing non-zero pixels within pattern region)
        if let patternTemplate = PetSpriteTemplates.pattern(for: genome.pattern) {
            let px = bodyX + bodyTemplate.patternOrigin.x
            let py = bodyY + bodyTemplate.patternOrigin.y
            for (row, line) in patternTemplate.enumerated() {
                for (col, val) in line.enumerated() {
                    guard val != 0 else { continue }
                    let gx = px + col
                    let gy = py + row
                    guard gx >= 0, gx < 32, gy >= 0, gy < 32 else { continue }
                    // Only apply pattern on existing body pixels (not outline)
                    if grid.pixels[gy][gx] == 2 || grid.pixels[gy][gx] == 3 {
                        grid.setPixel(x: gx, y: gy, value: val)
                    }
                }
            }
        }

        return grid
    }
}
```

**Step 4: Run tests**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetRendererTests -quiet 2>&1 | tail -20`

Expected: All PetRendererTests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/PetRenderer.swift PeerDropTests/PetRendererTests.swift
git commit -m "feat: rewrite PetRenderer to use template stamping with color indices"
```

---

### Task 5: Update PixelView for Color Rendering

**Files:**
- Modify: `PeerDrop/Pet/UI/PixelView.swift`

**Step 1: Rewrite PixelView.swift**

```swift
import SwiftUI

struct PixelView: View {
    let grid: PixelGrid
    let palette: ColorPalette
    let displaySize: CGFloat

    private let scaleFactor: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let pixelSize = size.width / CGFloat(grid.size)
            for y in 0..<grid.size {
                for x in 0..<grid.size {
                    let index = grid.pixels[y][x]
                    guard index != 0, let color = palette.color(for: index) else { continue }
                    let rect = CGRect(
                        x: CGFloat(x) * pixelSize,
                        y: CGFloat(y) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: displaySize, height: displaySize)
    }
}
```

**Step 2: Build to check compilation**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -20`

Expected: Build fails — callers of `PixelView` don't pass `palette` yet. That's expected; we fix callers in Task 6.

**Step 3: Commit PixelView change**

```bash
git add PeerDrop/Pet/UI/PixelView.swift
git commit -m "feat: upgrade PixelView to render color palette indices at 4x scale"
```

---

### Task 6: Update All UI Callers

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift`
- Modify: `PeerDrop/Pet/UI/GuestPetView.swift`
- Modify: `PeerDrop/Pet/UI/PetInteractionView.swift`

**Step 1: Add palette to PetEngine**

In `PeerDrop/Pet/Engine/PetEngine.swift`, add a computed property:

```swift
var palette: ColorPalette {
    PetPalettes.palette(for: pet.genome)
}
```

**Step 2: Update FloatingPetView**

In `PeerDrop/Pet/UI/FloatingPetView.swift`, change:

```swift
// Old:
PixelView(grid: engine.renderedGrid, displaySize: 64)

// New:
PixelView(grid: engine.renderedGrid, palette: engine.palette, displaySize: 128)
```

Also update the bubble offset from `-44` to `-72` (since pet is now 128pt tall):

```swift
.offset(y: -72)
```

**Step 3: Update GuestPetView**

In `PeerDrop/Pet/UI/GuestPetView.swift`, change:

```swift
// Old:
PixelView(
    grid: renderer.render(genome: greeting.genome, level: greeting.level,
                           mood: greeting.mood, animationFrame: frame),
    displaySize: 48
)

// New:
PixelView(
    grid: renderer.render(genome: greeting.genome, level: greeting.level,
                           mood: greeting.mood, animationFrame: frame),
    palette: PetPalettes.palette(for: greeting.genome),
    displaySize: 64
)
```

**Step 4: Update PetInteractionView**

In `PeerDrop/Pet/UI/PetInteractionView.swift`, change:

```swift
// Old:
PixelView(grid: engine.renderedGrid, displaySize: 96)

// New:
PixelView(grid: engine.renderedGrid, palette: engine.palette, displaySize: 128)
```

**Step 5: Build and run all tests**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`

Expected: Full build succeeds, all tests pass

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift PeerDrop/Pet/UI/FloatingPetView.swift PeerDrop/Pet/UI/GuestPetView.swift PeerDrop/Pet/UI/PetInteractionView.swift
git commit -m "feat: wire color palette through all pet UI views"
```

---

### Task 7: Fix Remaining Compilation and Run Full Test Suite

**Files:**
- Any files with compilation errors referencing old `PixelGrid` Bool API or old `PixelView` signature

**Step 1: Full build**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`

Fix any remaining compilation errors. Common issues:
- `PetGenome.canvasSize` used elsewhere (search for `canvasSize`)
- Any code calling `PixelView` without `palette` parameter
- Any code checking `grid.pixels[y][x]` as `Bool`
- Screenshot mode mock data if it creates PixelGrid or uses PixelView

**Step 2: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`

Expected: All 292+ tests pass

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve remaining compilation issues from PixelGrid Bool-to-Int migration"
```

---

### Task 8: Visual Verification

**Step 1: Run app in simulator**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && xcrun simctl boot "iPhone 16" 2>/dev/null; xcrun simctl install "iPhone 16" $(xcodebuild -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -showBuildSettings 2>/dev/null | grep -m1 BUILT_PRODUCTS_DIR | awk '{print $3}')/PeerDrop.app && xcrun simctl launch "iPhone 16" com.hanfour.peerdrop`

**Step 2: Verify visually**

Check:
- [ ] Pet displays in color (not black blob)
- [ ] Egg stage shows colored shell with crack lines
- [ ] Baby stage shows body with outline, fill, belly, blush, eyes
- [ ] Different personality genes show different color palettes
- [ ] Breathing/bounce animation still works
- [ ] Pet interaction panel shows colored pet
- [ ] Pet size is 128pt (larger than before)

**Step 3: Take a screenshot for reference**

Run: `xcrun simctl io "iPhone 16" screenshot /tmp/pet-colorful-test.png`

**Step 4: Final commit if any visual tweaks needed**

Adjust template coordinates, anchor points, or colors as needed based on visual inspection.
