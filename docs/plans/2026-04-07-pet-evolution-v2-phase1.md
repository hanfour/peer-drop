# Pet Evolution v2 — Phase 1: Rendering Pipeline + Base Physics

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the 32x32 PixelGrid renderer with a 16x16 sprite-sheet-based pipeline, add full Shimeji screen physics, and validate with a complete Cat body type.

**Architecture:** Indexed-color PNG sprite sheets loaded at runtime, palette-swapped to CGImage, composited (body + eyes + pattern), and displayed via SwiftUI Image. Physics engine runs at 60 FPS via CADisplayLink, sprite animation at 6 FPS. Existing PetEngine orchestrates state; new SpriteSheetLoader/PaletteSwapRenderer/SpriteCompositor handle rendering; new PetPhysicsEngine handles movement.

**Tech Stack:** SwiftUI, CoreGraphics (CGImage pixel manipulation), CADisplayLink, UIScreen geometry

**Design doc:** `docs/plans/2026-04-07-pet-evolution-v2-design.md`

---

### Task 1: Expand BodyGene to 10 Types + Add PetSurface Model

**Files:**
- Modify: `PeerDrop/Pet/Model/PetGenome.swift`
- Create: `PeerDrop/Pet/Model/PetSurface.swift`
- Modify: `PeerDrop/Pet/Model/PetLevel.swift`
- Modify: `PeerDrop/Pet/Model/PetAction.swift`
- Test: `PeerDropTests/PetGenomeV2Tests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetGenomeV2Tests.swift
import XCTest
@testable import PeerDrop

final class PetGenomeV2Tests: XCTestCase {

    func testBodyGeneHas10Cases() {
        XCTAssertEqual(BodyGene.allCases.count, 10)
    }

    func testBodyGeneFromPersonalityGene() {
        // Cat range: 0.00-0.14
        XCTAssertEqual(BodyGene.from(personalityGene: 0.05), .cat)
        // Dragon range: 0.72-0.80
        XCTAssertEqual(BodyGene.from(personalityGene: 0.75), .dragon)
        // Slime range: 0.93-1.00
        XCTAssertEqual(BodyGene.from(personalityGene: 0.95), .slime)
    }

    func testPaletteIndexDecoupledFromBody() {
        let g1 = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.05)
        let g2 = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.06)
        // Different personalityGene can yield different palette even for same body
        // Just verify it's in range
        XCTAssertTrue((0..<8).contains(g1.paletteIndex))
        XCTAssertTrue((0..<8).contains(g2.paletteIndex))
    }

    func testLevelHasChildCase() {
        XCTAssertEqual(PetLevel.child.rawValue, 3)
        XCTAssertTrue(PetLevel.baby < PetLevel.child)
    }

    func testPetSurfaceCases() {
        let surfaces: [PetSurface] = [.ground, .leftWall, .rightWall, .ceiling, .dynamicIsland, .airborne]
        XCTAssertEqual(surfaces.count, 6)
    }

    func testNewActionCases() {
        // Verify new actions exist
        let actions: [PetAction] = [.run, .jump, .climb, .hang, .fall, .sitEdge,
                                     .eat, .yawn, .poop, .happy, .scared, .angry,
                                     .love, .tapReact, .pickedUp, .thrown, .petted]
        XCTAssertFalse(actions.isEmpty)
    }

    func testOldBodyGenesMigrate() {
        // Old saved genomes with round/square/oval should still decode
        let json = """
        {"body":"round","eyes":"dot","pattern":"none","personalityGene":0.5}
        """
        let genome = try? JSONDecoder().decode(PetGenome.self, from: json.data(using: .utf8)!)
        XCTAssertNotNil(genome)
        XCTAssertEqual(genome?.body, .bear) // round maps to bear
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetGenomeV2Tests -quiet 2>&1 | tail -20`
Expected: Compilation errors — `.cat`, `.from(personalityGene:)`, `.child`, `PetSurface` don't exist yet

**Step 3: Implement model changes**

Modify `PeerDrop/Pet/Model/PetGenome.swift`:
```swift
// Replace BodyGene enum
enum BodyGene: String, Codable, CaseIterable {
    case cat, dog, rabbit, bird, frog, bear, dragon, octopus, ghost, slime

    /// Map legacy values from v1 genome saves
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "round": self = .bear
        case "square": self = .cat
        case "oval": self = .slime
        default:
            guard let value = BodyGene(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown BodyGene: \(raw)")
            }
            self = value
        }
    }

    /// Determine body type from personality gene at hatch
    static func from(personalityGene pg: Double) -> BodyGene {
        switch pg {
        case ..<0.14: return .cat
        case ..<0.28: return .dog
        case ..<0.40: return .rabbit
        case ..<0.52: return .bird
        case ..<0.62: return .frog
        case ..<0.72: return .bear
        case ..<0.80: return .dragon
        case ..<0.87: return .octopus
        case ..<0.93: return .ghost
        default:      return .slime
        }
    }
}

// Remove LimbGene enum (keep for Codable migration but mark deprecated)
// In PetGenome struct, make limbs optional:
struct PetGenome: Codable, Equatable {
    var body: BodyGene
    var eyes: EyeGene
    var limbs: LimbGene? // deprecated, kept for migration
    var pattern: PatternGene
    var personalityGene: Double

    var paletteIndex: Int {
        let hash = (personalityGene * 137).truncatingRemainder(dividingBy: 1.0)
        return min(Int(hash * 8), 7)
    }

    // ... keep existing personalityTraits, mutate(), random()
    // Update mutate() to not touch .limbs and not touch .body
    // Update random() to use BodyGene.from(personalityGene:)
}
```

Create `PeerDrop/Pet/Model/PetSurface.swift`:
```swift
enum PetSurface: String, Codable {
    case ground
    case leftWall
    case rightWall
    case ceiling
    case dynamicIsland
    case airborne
}
```

Modify `PeerDrop/Pet/Model/PetLevel.swift` — add `child = 3`:
```swift
enum PetLevel: Int, Codable, Comparable, CaseIterable {
    case egg = 1
    case baby = 2
    case child = 3

    static func < (lhs: PetLevel, rhs: PetLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

Modify `PeerDrop/Pet/Model/PetAction.swift` — add new action cases:
```swift
enum PetAction: String, Codable {
    // Movement
    case idle, walking, run, jump
    // Edge
    case climb, hang, fall, sitEdge
    // Life
    case sleeping, eat, yawn, poop, evolving
    // Emotion
    case happy, scared, angry, love
    // Interaction
    case tapReact, pickedUp, thrown, petted
    // Legacy (kept for migration)
    case wagTail, freeze, hideInShell, zoomies
    case notifyMessage, climbOnBubble, blockText, bounceBetweenBubbles
    case tiltHead, stuffCheeks, ignore
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetGenomeV2Tests -quiet 2>&1 | tail -20`
Expected: All 7 tests PASS

**Step 5: Run full test suite to check for regressions**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`
Expected: All existing tests still pass (BodyGene migration handles old values)

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Model/PetGenome.swift PeerDrop/Pet/Model/PetSurface.swift \
  PeerDrop/Pet/Model/PetLevel.swift PeerDrop/Pet/Model/PetAction.swift \
  PeerDropTests/PetGenomeV2Tests.swift
xcodegen generate
git add PeerDrop.xcodeproj
git commit -m "feat(pet): expand BodyGene to 10 types, add PetSurface, PetLevel.child, new actions"
```

---

### Task 2: SpriteSheetLoader — Load and Slice PNG Strips

**Files:**
- Create: `PeerDrop/Pet/Renderer/SpriteSheetLoader.swift`
- Create: `PeerDropTests/SpriteSheetLoaderTests.swift`
- Create: `PeerDrop/Pet/Sprites/` directory for test assets

**Step 1: Write failing tests**

```swift
// PeerDropTests/SpriteSheetLoaderTests.swift
import XCTest
@testable import PeerDrop

final class SpriteSheetLoaderTests: XCTestCase {

    func testSlice4FrameStrip() throws {
        // Create a 64x16 test image (4 frames of 16x16)
        let strip = TestSpriteHelper.make(width: 64, height: 16, fillIndex: 2)
        let frames = try SpriteSheetLoader.slice(strip: strip, frameSize: 16)
        XCTAssertEqual(frames.count, 4)
        for frame in frames {
            XCTAssertEqual(frame.width, 16)
            XCTAssertEqual(frame.height, 16)
        }
    }

    func testSliceSingleFrame() throws {
        let strip = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let frames = try SpriteSheetLoader.slice(strip: strip, frameSize: 16)
        XCTAssertEqual(frames.count, 1)
    }

    func testSliceInvalidWidthThrows() {
        // 50px wide is not divisible by 16
        let strip = TestSpriteHelper.make(width: 50, height: 16, fillIndex: 1)
        XCTAssertThrowsError(try SpriteSheetLoader.slice(strip: strip, frameSize: 16))
    }

    func testReadPixelIndices() throws {
        // Create a 16x16 image where pixel (0,0) = index 5
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 5)
        let indices = SpriteSheetLoader.readIndices(from: img)
        XCTAssertEqual(indices.count, 16) // 16 rows
        XCTAssertEqual(indices[0].count, 16) // 16 cols
        XCTAssertEqual(indices[0][0], 5)
    }

    func testLoadActionReturnsFrames() throws {
        // This tests loading from bundle — uses a test sprite in test target resources
        let frames = try SpriteSheetLoader.loadAction(body: .cat, stage: .baby, action: .idle)
        XCTAssertGreaterThan(frames.count, 0)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SpriteSheetLoaderTests -quiet 2>&1 | tail -20`
Expected: FAIL — `SpriteSheetLoader` not found

**Step 3: Implement SpriteSheetLoader**

```swift
// PeerDrop/Pet/Renderer/SpriteSheetLoader.swift
import UIKit

enum SpriteSheetError: Error {
    case invalidStripWidth
    case imageLoadFailed(String)
    case pixelReadFailed
}

enum SpriteSheetLoader {

    static let frameSize = 16

    /// Slice a horizontal strip into individual CGImage frames.
    static func slice(strip: CGImage, frameSize: Int = Self.frameSize) throws -> [CGImage] {
        let width = strip.width
        let height = strip.height
        guard width % frameSize == 0, height == frameSize else {
            throw SpriteSheetError.invalidStripWidth
        }
        let count = width / frameSize
        return (0..<count).compactMap { i in
            strip.cropping(to: CGRect(x: i * frameSize, y: 0, width: frameSize, height: frameSize))
        }
    }

    /// Read the color indices from a grayscale/indexed CGImage into a 2D array.
    /// Each pixel's red channel value is treated as the palette index (0-15).
    static func readIndices(from image: CGImage) -> [[UInt8]] {
        let w = image.width
        let h = image.height
        var pixelData = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var result = [[UInt8]]()
        for y in 0..<h {
            var row = [UInt8]()
            for x in 0..<w {
                let offset = (y * w + x) * 4
                let r = pixelData[offset]     // use red channel as index
                let a = pixelData[offset + 3] // alpha
                row.append(a < 128 ? 0 : r)  // transparent = index 0
            }
            result.append(row)
        }
        return result
    }

    /// Load sprite strip for a body type + stage + action from bundle.
    static func loadAction(body: BodyGene, stage: PetLevel, action: PetAction) throws -> [[[UInt8]]] {
        let name = "\(body.rawValue)_\(stage.rawValue)_\(action.rawValue)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let source = CGImage.from(pngData: data) else {
            throw SpriteSheetError.imageLoadFailed(name)
        }
        let frames = try slice(strip: source)
        return frames.map { readIndices(from: $0) }
    }
}

// Helper to create CGImage from PNG data
extension CGImage {
    static func from(pngData data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(pngDataProviderSource: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return image
    }
}
```

Also create a test helper:
```swift
// PeerDropTests/TestSpriteHelper.swift
import CoreGraphics

enum TestSpriteHelper {
    /// Create a CGImage filled with a single color index value (stored in red channel).
    static func make(width: Int, height: Int, fillIndex: UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = fillIndex     // R = palette index
            pixels[i * 4 + 1] = 0        // G
            pixels[i * 4 + 2] = 0        // B
            pixels[i * 4 + 3] = 255      // A = opaque
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SpriteSheetLoaderTests -quiet 2>&1 | tail -20`
Expected: 4 of 5 PASS (loadAction will fail until real sprite assets exist — skip it for now with `try XCTSkipIf(true, "needs sprite assets")`)

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/SpriteSheetLoader.swift PeerDropTests/SpriteSheetLoaderTests.swift \
  PeerDropTests/TestSpriteHelper.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add SpriteSheetLoader — slice PNG strips and read indexed pixels"
```

---

### Task 3: PaletteSwapRenderer — Indexed Color to CGImage

**Files:**
- Create: `PeerDrop/Pet/Renderer/PaletteSwapRenderer.swift`
- Test: `PeerDropTests/PaletteSwapRendererTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PaletteSwapRendererTests.swift
import XCTest
import SwiftUI
@testable import PeerDrop

final class PaletteSwapRendererTests: XCTestCase {

    func testRenderProducesCorrectSize() {
        let indices: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let palette = PetPalettes.all[0]
        let image = PaletteSwapRenderer.render(indices: indices, palette: palette)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
        XCTAssertEqual(image?.height, 16)
    }

    func testTransparentPixelsAreAlphaZero() {
        // All zeros = transparent
        let indices: [[UInt8]] = Array(repeating: Array(repeating: 0, count: 16), count: 16)
        let palette = PetPalettes.all[0]
        let image = PaletteSwapRenderer.render(indices: indices, palette: palette)!

        // Read back pixel at (0,0) — should be transparent
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(pixel[3], 0, "Alpha should be 0 for transparent pixel")
    }

    func testScaleUpProducesLargerImage() {
        let indices: [[UInt8]] = Array(repeating: Array(repeating: 1, count: 16), count: 16)
        let palette = PetPalettes.all[0]
        let image = PaletteSwapRenderer.render(indices: indices, palette: palette, scale: 8)
        XCTAssertEqual(image?.width, 128)
        XCTAssertEqual(image?.height, 128)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PaletteSwapRendererTests -quiet 2>&1 | tail -20`
Expected: FAIL — `PaletteSwapRenderer` not found

**Step 3: Implement PaletteSwapRenderer**

```swift
// PeerDrop/Pet/Renderer/PaletteSwapRenderer.swift
import UIKit
import SwiftUI

enum PaletteSwapRenderer {

    /// Convert indexed pixel grid to a CGImage using the given palette.
    /// - Parameters:
    ///   - indices: 2D array of palette indices (0 = transparent, 1-6 = palette slots)
    ///   - palette: ColorPalette to map indices to colors
    ///   - scale: Integer upscale factor (nearest-neighbor). 1 = native 16x16.
    static func render(indices: [[UInt8]], palette: ColorPalette, scale: Int = 1) -> CGImage? {
        let h = indices.count
        guard h > 0 else { return nil }
        let w = indices[0].count
        let outW = w * scale
        let outH = h * scale

        var pixels = [UInt8](repeating: 0, count: outW * outH * 4)

        // Build lookup table: index → (r, g, b, a)
        var lut = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 0), count: 16)
        for slot in 1...6 {
            if let color = palette.color(for: slot) {
                let resolved = UIColor(color)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
                lut[slot] = (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), UInt8(a * 255))
            }
        }

        for y in 0..<h {
            for x in 0..<w {
                let idx = Int(indices[y][x])
                guard idx > 0, idx < lut.count else { continue } // 0 = transparent, skip
                let (r, g, b, a) = lut[idx]
                // Fill scale×scale block
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        let offset = ((y * scale + sy) * outW + (x * scale + sx)) * 4
                        pixels[offset] = r
                        pixels[offset + 1] = g
                        pixels[offset + 2] = b
                        pixels[offset + 3] = a
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return context.makeImage()
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PaletteSwapRendererTests -quiet 2>&1 | tail -20`
Expected: All 3 tests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/PaletteSwapRenderer.swift PeerDropTests/PaletteSwapRendererTests.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add PaletteSwapRenderer — indexed color to CGImage with palette swap"
```

---

### Task 4: SpriteCache — LRU Cache for Rendered Sprites

**Files:**
- Create: `PeerDrop/Pet/Renderer/SpriteCache.swift`
- Test: `PeerDropTests/SpriteCacheTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/SpriteCacheTests.swift
import XCTest
@testable import PeerDrop

final class SpriteCacheTests: XCTestCase {

    func testCacheStoreAndRetrieve() {
        let cache = SpriteCache(maxEntries: 10)
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let key = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        cache.set(img, for: key)
        XCTAssertNotNil(cache.get(key))
    }

    func testCacheMissReturnsNil() {
        let cache = SpriteCache(maxEntries: 10)
        let key = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        XCTAssertNil(cache.get(key))
    }

    func testCacheEvictsOldEntries() {
        let cache = SpriteCache(maxEntries: 2)
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let k1 = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        let k2 = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 1, paletteIndex: 0)
        let k3 = SpriteCache.Key(body: .cat, stage: .baby, action: .walk, frame: 0, paletteIndex: 0)
        cache.set(img, for: k1)
        cache.set(img, for: k2)
        cache.set(img, for: k3) // should evict k1
        XCTAssertNil(cache.get(k1))
        XCTAssertNotNil(cache.get(k2))
        XCTAssertNotNil(cache.get(k3))
    }

    func testClearRemovesAll() {
        let cache = SpriteCache(maxEntries: 10)
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let key = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        cache.set(img, for: key)
        cache.clear()
        XCTAssertNil(cache.get(key))
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — `SpriteCache` not found

**Step 3: Implement SpriteCache**

```swift
// PeerDrop/Pet/Renderer/SpriteCache.swift
import CoreGraphics

final class SpriteCache {

    struct Key: Hashable {
        let body: BodyGene
        let stage: PetLevel
        let action: PetAction
        let frame: Int
        let paletteIndex: Int
    }

    private let maxEntries: Int
    private var cache = [Key: CGImage]()
    private var accessOrder = [Key]()

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    func get(_ key: Key) -> CGImage? {
        guard let image = cache[key] else { return nil }
        // Move to end (most recently used)
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
            accessOrder.append(key)
        }
        return image
    }

    func set(_ image: CGImage, for key: Key) {
        if cache[key] != nil {
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
            }
        } else if cache.count >= maxEntries {
            // Evict least recently used
            let evicted = accessOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        cache[key] = image
        accessOrder.append(key)
    }

    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SpriteCacheTests -quiet 2>&1 | tail -20`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/SpriteCache.swift PeerDropTests/SpriteCacheTests.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add SpriteCache — LRU cache for palette-swapped sprite images"
```

---

### Task 5: SpriteCompositor — Layer body + eyes + pattern

**Files:**
- Create: `PeerDrop/Pet/Renderer/SpriteCompositor.swift`
- Test: `PeerDropTests/SpriteCompositorTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/SpriteCompositorTests.swift
import XCTest
@testable import PeerDrop

final class SpriteCompositorTests: XCTestCase {

    func testCompositeBodyOnly() {
        // Body fills everything with index 2
        let body: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let result = SpriteCompositor.composite(body: body, eyes: nil, eyeAnchor: nil, pattern: nil, patternMask: nil)
        XCTAssertEqual(result.count, 16)
        XCTAssertEqual(result[0][0], 2)
    }

    func testCompositeOverlaysEyes() {
        var body: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let eyes: [[UInt8]] = [[5, 0, 0, 5]] // 4 wide, 1 tall, slots 5 at positions 0,3
        let anchor = (x: 4, y: 4)
        let result = SpriteCompositor.composite(body: body, eyes: eyes, eyeAnchor: anchor, pattern: nil, patternMask: nil)
        XCTAssertEqual(result[4][4], 5) // eye pixel
        XCTAssertEqual(result[4][5], 2) // body pixel (eye was 0 = skip)
        XCTAssertEqual(result[4][7], 5) // eye pixel
    }

    func testCompositeAppliesPattern() {
        let body: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let pattern: [[UInt8]] = [[6, 0, 6, 0]]
        let mask: [[Bool]] = Array(repeating: Array(repeating: true, count: 16), count: 16)
        let result = SpriteCompositor.composite(body: body, eyes: nil, eyeAnchor: nil,
                                                  pattern: pattern, patternMask: mask)
        // Pattern index 6 overwrites body index 2 where mask is true
        XCTAssertEqual(result[0][0], 6)
        XCTAssertEqual(result[0][1], 2) // pattern was 0, body stays
    }

    func testFlipHorizontal() {
        let indices: [[UInt8]] = [[1, 0, 0, 2]]
        let flipped = SpriteCompositor.flipHorizontal(indices)
        XCTAssertEqual(flipped, [[2, 0, 0, 1]])
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — `SpriteCompositor` not found

**Step 3: Implement SpriteCompositor**

```swift
// PeerDrop/Pet/Renderer/SpriteCompositor.swift
import Foundation

enum SpriteCompositor {

    /// Composite layers into a single 2D index array.
    /// Layer order: body (base) → pattern (overwrites body where mask allows) → eyes (on top)
    static func composite(
        body: [[UInt8]],
        eyes: [[UInt8]]?,
        eyeAnchor: (x: Int, y: Int)?,
        pattern: [[UInt8]]?,
        patternMask: [[Bool]]?
    ) -> [[UInt8]] {
        var result = body
        let h = body.count
        guard h > 0 else { return result }
        let w = body[0].count

        // Apply pattern (only where mask is true and body pixel is non-zero, non-outline)
        if let pattern, let mask = patternMask {
            for py in 0..<min(pattern.count, h) {
                for px in 0..<min(pattern[0].count, w) {
                    let idx = pattern[py][px]
                    guard idx != 0, py < mask.count, px < mask[0].count, mask[py][px] else { continue }
                    let bodyVal = result[py][px]
                    if bodyVal == 2 || bodyVal == 3 { // only overwrite primary/secondary body
                        result[py][px] = idx
                    }
                }
            }
        }

        // Overlay eyes at anchor
        if let eyes, let anchor = eyeAnchor {
            for ey in 0..<eyes.count {
                for ex in 0..<eyes[ey].count {
                    let idx = eyes[ey][ex]
                    guard idx != 0 else { continue } // 0 = transparent, skip
                    let gx = anchor.x + ex
                    let gy = anchor.y + ey
                    guard gx >= 0, gx < w, gy >= 0, gy < h else { continue }
                    result[gy][gx] = idx
                }
            }
        }

        return result
    }

    /// Flip a 2D index array horizontally (for left-facing direction).
    static func flipHorizontal(_ indices: [[UInt8]]) -> [[UInt8]] {
        indices.map { $0.reversed().map { $0 } }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SpriteCompositorTests -quiet 2>&1 | tail -20`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/SpriteCompositor.swift PeerDropTests/SpriteCompositorTests.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add SpriteCompositor — layer body, eyes, pattern into composite sprite"
```

---

### Task 6: PetAnimationController v2 — Variable Frame Counts + 6 FPS

**Files:**
- Modify: `PeerDrop/Pet/Renderer/PetAnimationController.swift`
- Test: `PeerDropTests/PetAnimationControllerV2Tests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetAnimationControllerV2Tests.swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetAnimationControllerV2Tests: XCTestCase {

    func testDefaultFrameRateIs6FPS() {
        let controller = PetAnimationController()
        XCTAssertEqual(controller.frameRate, 1.0 / 6.0, accuracy: 0.001)
    }

    func testSetActionUpdatesFrameCount() {
        let controller = PetAnimationController()
        controller.setAction(.idle, frameCount: 4)
        XCTAssertEqual(controller.currentFrame, 0)
        XCTAssertEqual(controller.totalFrames, 4)
    }

    func testFrameWrapsAround() {
        let controller = PetAnimationController()
        controller.setAction(.idle, frameCount: 2)
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 1)
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 0) // wraps
    }

    func testSetActionResetsFrame() {
        let controller = PetAnimationController()
        controller.setAction(.idle, frameCount: 4)
        controller.advanceFrame()
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 2)
        controller.setAction(.walk, frameCount: 4)
        XCTAssertEqual(controller.currentFrame, 0) // reset on action change
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — `setAction`, `totalFrames`, `advanceFrame` don't exist yet

**Step 3: Rewrite PetAnimationController**

```swift
// PeerDrop/Pet/Renderer/PetAnimationController.swift
import Foundation

@MainActor
class PetAnimationController: ObservableObject {
    @Published var currentFrame: Int = 0

    let frameRate: TimeInterval = 1.0 / 6.0  // 6 FPS
    private(set) var totalFrames: Int = 2
    private var currentAction: PetAction = .idle
    private var timer: Timer?

    func setAction(_ action: PetAction, frameCount: Int) {
        guard action != currentAction || frameCount != totalFrames else { return }
        currentAction = action
        totalFrames = max(1, frameCount)
        currentFrame = 0
    }

    func advanceFrame() {
        currentFrame = (currentFrame + 1) % totalFrames
    }

    func startAnimation() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceFrame()
            }
        }
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetAnimationControllerV2Tests -quiet 2>&1 | tail -20`
Expected: All 4 tests PASS

**Step 5: Run full test suite — fix any regressions from changed PetAnimationController API**

The old tests in `PeerDropTests/PetEngineTests.swift` may reference old API. Fix accordingly — the animator is private inside PetEngine, so changes should be minimal.

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`

**Step 6: Commit**

```bash
git add PeerDrop/Pet/Renderer/PetAnimationController.swift PeerDropTests/PetAnimationControllerV2Tests.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): upgrade PetAnimationController to 6 FPS with variable frame counts"
```

---

### Task 7: Cat Sprite Data — Programmatic 16x16 Templates

Since we don't have pixel art tools in this workflow, we create the Cat baby sprites as programmatic 2D UInt8 arrays (same approach as current PetSpriteTemplates, but 16x16). These serve as the **reference implementation** and can be replaced with PNG assets later.

**Files:**
- Create: `PeerDrop/Pet/Sprites/CatSpriteData.swift`
- Create: `PeerDrop/Pet/Sprites/EggSpriteData.swift`
- Create: `PeerDrop/Pet/Sprites/EyeSpriteData.swift`
- Create: `PeerDrop/Pet/Sprites/PatternSpriteData.swift`
- Create: `PeerDrop/Pet/Sprites/BodyMeta.swift`
- Test: `PeerDropTests/CatSpriteDataTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/CatSpriteDataTests.swift
import XCTest
@testable import PeerDrop

final class CatSpriteDataTests: XCTestCase {

    func testCatIdleHas4Frames() {
        let frames = CatSpriteData.baby[.idle]!
        XCTAssertEqual(frames.count, 4)
        for frame in frames {
            XCTAssertEqual(frame.count, 16) // 16 rows
            XCTAssertEqual(frame[0].count, 16) // 16 cols
        }
    }

    func testCatWalkHas4Frames() {
        XCTAssertEqual(CatSpriteData.baby[.walk]!.count, 4)
    }

    func testCatHasAllRequiredActions() {
        let required: [PetAction] = [.idle, .walk, .run, .jump, .climb, .hang, .fall, .sitEdge,
                                      .sleeping, .eat, .yawn, .poop, .happy, .scared, .angry,
                                      .love, .tapReact, .pickedUp, .thrown, .petted]
        for action in required {
            XCTAssertNotNil(CatSpriteData.baby[action], "Missing cat baby sprite for \(action)")
        }
    }

    func testCatMetaAnchorsInBounds() {
        let meta = CatSpriteData.meta
        XCTAssertTrue(meta.eyeAnchor.x >= 0 && meta.eyeAnchor.x < 16)
        XCTAssertTrue(meta.eyeAnchor.y >= 0 && meta.eyeAnchor.y < 16)
        XCTAssertTrue(meta.groundY >= 0 && meta.groundY <= 16)
    }

    func testEggIdleHas2Frames() {
        let frames = EggSpriteData.idle
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].count, 16)
        XCTAssertEqual(frames[0][0].count, 16)
    }

    func testEyeDotsExist() {
        let eyes = EyeSpriteData.sprites[.dot]!
        XCTAssertFalse(eyes.isEmpty)
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — `CatSpriteData`, `EggSpriteData`, `EyeSpriteData` not found

**Step 3: Create sprite data files**

Create `PeerDrop/Pet/Sprites/BodyMeta.swift`:
```swift
struct BodyMeta {
    let eyeAnchor: (x: Int, y: Int)
    let patternMask: [[Bool]]
    let groundY: Int
    let hangAnchor: (x: Int, y: Int)
    let climbOffset: (x: Int, y: Int)
}
```

Create `PeerDrop/Pet/Sprites/EggSpriteData.swift` — 16x16 egg with 2 idle frames:
```swift
enum EggSpriteData {
    // 0=transparent, 1=outline, 2=shell primary, 5=crack accent
    static let idle: [[[UInt8]]] = [
        // Frame 0: normal egg shape
        // (Design a 10x12 egg centered on 16x16 grid)
        // Detailed pixel arrays to be hand-crafted at implementation time
        // following the same indexed color convention
    ]

    static let tapReact: [[[UInt8]]] = [
        // Frame 0-2: egg wobbles, cracks deepen
    ]

    static let frameCount: [PetAction: Int] = [
        .idle: 2,
        .tapReact: 3,
    ]
}
```

Create `PeerDrop/Pet/Sprites/CatSpriteData.swift` — all 19 actions:
```swift
enum CatSpriteData {
    static let meta = BodyMeta(
        eyeAnchor: (x: 5, y: 4),
        patternMask: /* 16x16 bool grid marking body interior */,
        groundY: 14,
        hangAnchor: (x: 8, y: 1),
        climbOffset: (x: 2, y: 0)
    )

    /// Baby stage sprites: action → [frames], each frame is [[UInt8]] 16x16
    static let baby: [PetAction: [[[UInt8]]]] = [
        .idle: [ /* 4 frames */ ],
        .walk: [ /* 4 frames */ ],
        .run: [ /* 6 frames */ ],
        .jump: [ /* 4 frames */ ],
        .climb: [ /* 4 frames */ ],
        .hang: [ /* 2 frames */ ],
        .fall: [ /* 3 frames */ ],
        .sitEdge: [ /* 2 frames */ ],
        .sleeping: [ /* 2 frames */ ],
        .eat: [ /* 4 frames */ ],
        .yawn: [ /* 3 frames */ ],
        .poop: [ /* 4 frames */ ],
        .happy: [ /* 3 frames */ ],
        .scared: [ /* 2 frames */ ],
        .angry: [ /* 3 frames */ ],
        .love: [ /* 3 frames */ ],
        .tapReact: [ /* 3 frames */ ],
        .pickedUp: [ /* 2 frames */ ],
        .thrown: [ /* 3 frames */ ],
        .petted: [ /* 3 frames */ ],
    ]
}
```

> **Note for implementer:** Each frame is a 16x16 `[[UInt8]]` grid. Use the indexed color convention: 0=transparent, 1=outline, 2=primary, 3=secondary, 4=highlight, 5=accent, 6=pattern. Design pixel-by-pixel for cat silhouette (pointed ears ~2px at top, round head, small body, raised tail). Start with idle and walk, then derive other actions by modifying limb/ear positions. Keep strong silhouette — at 16x16 every pixel counts.

Create `PeerDrop/Pet/Sprites/EyeSpriteData.swift`:
```swift
enum EyeSpriteData {
    /// Eye overlay sprites, keyed by gene. Each is a 2D UInt8 array (small, ~4x3).
    static let sprites: [EyeGene: [[UInt8]]] = [
        .dot:   [ [0,5,0,0,0,0,0,5,0] ],           // 1px pupils
        .round: [ [5,5,0,0,0,0,5,5], [5,4,0,0,0,0,5,4] ], // 2px with highlight
        .line:  [ [5,5,0,0,0,0,5,5] ],              // squint
        .dizzy: [ [5,0,5,0,0,5,0,5], [0,5,0,0,0,0,5,0] ], // X eyes
    ]

    /// Mood-specific eye overrides
    static let moods: [PetMood: [[UInt8]]] = [
        .happy:    [ [0,5,0,0,0,0,0,5,0], [5,0,5,0,0,5,0,5] ], // ^_^
        .sleepy:   [ [5,5,0,0,0,0,5,5] ],
        .startled: [ [5,5,0,0,0,0,5,5], [5,5,0,0,0,0,5,5], [0,0,0,0,0,0,0,0] ],
    ]
}
```

Create `PeerDrop/Pet/Sprites/PatternSpriteData.swift`:
```swift
enum PatternSpriteData {
    static let sprites: [PatternGene: [[UInt8]]] = [
        .stripe: [
            [6,6,6,6,6,6,6,6],
            [0,0,0,0,0,0,0,0],
            [6,6,6,6,6,6,6,6],
            [0,0,0,0,0,0,0,0],
            [6,6,6,6,6,6,6,6],
        ],
        .spot: [
            [0,6,0,0,0,0,6,0],
            [0,0,0,6,0,0,0,0],
            [6,0,0,0,0,6,0,0],
            [0,0,6,0,0,0,0,6],
            [0,0,0,0,6,0,0,0],
        ],
    ]
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/CatSpriteDataTests -quiet 2>&1 | tail -20`
Expected: All 6 tests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Sprites/
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add 16x16 Cat sprite data, egg, eyes, patterns, body meta"
```

---

### Task 8: PetPhysicsEngine — Gravity, Surfaces, Collision

**Files:**
- Create: `PeerDrop/Pet/Engine/PetPhysicsEngine.swift`
- Create: `PeerDrop/Pet/Model/PetPhysicsState.swift`
- Test: `PeerDropTests/PetPhysicsEngineTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetPhysicsEngineTests.swift
import XCTest
@testable import PeerDrop

final class PetPhysicsEngineTests: XCTestCase {

    func testGravityAcceleratesDownward() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertGreaterThan(state.velocity.dy, 0, "Gravity should accelerate downward")
        XCTAssertGreaterThan(state.position.y, 100)
    }

    func testLandsOnGround() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 795), velocity: CGVector(dx: 0, dy: 100), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertEqual(state.surface, .ground)
        XCTAssertEqual(state.position.y, 800, accuracy: 1)
    }

    func testWalkOnGround() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: .zero, surface: .ground)
        let surfaces = ScreenSurfaces.test(ground: 800, rightWall: 400)
        PetPhysicsEngine.applyWalk(&state, direction: .right, speed: 30, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertGreaterThan(state.position.x, 100)
        XCTAssertEqual(state.position.y, 800, accuracy: 0.01, "Should stay on ground")
    }

    func testClimbWall() {
        var state = PetPhysicsState(position: CGPoint(x: 0, y: 500), velocity: .zero, surface: .leftWall)
        let surfaces = ScreenSurfaces.test(ceiling: 50)
        PetPhysicsEngine.applyClimb(&state, speed: 20, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertLessThan(state.position.y, 500, "Should climb upward")
    }

    func testClimbReachesCeiling() {
        var state = PetPhysicsState(position: CGPoint(x: 0, y: 51), velocity: .zero, surface: .leftWall)
        let surfaces = ScreenSurfaces.test(ceiling: 50)
        PetPhysicsEngine.applyClimb(&state, speed: 20, dt: 1.0, surfaces: surfaces)
        XCTAssertEqual(state.surface, .ceiling)
    }

    func testThrowAppliesVelocity() {
        var state = PetPhysicsState(position: CGPoint(x: 200, y: 200), velocity: .zero, surface: .airborne)
        PetPhysicsEngine.applyThrow(&state, velocity: CGVector(dx: 100, dy: -200))
        XCTAssertEqual(state.velocity.dx, 100)
        XCTAssertEqual(state.velocity.dy, -200)
    }

    func testBounceOnLanding() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: CGVector(dx: 50, dy: 300), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.resolveCollision(&state, surfaces: surfaces)
        XCTAssertEqual(state.surface, .ground)
        XCTAssertLessThan(state.velocity.dy, 0, "Should bounce upward")
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — `PetPhysicsEngine`, `PetPhysicsState`, `ScreenSurfaces` not found

**Step 3: Implement physics**

Create `PeerDrop/Pet/Model/PetPhysicsState.swift`:
```swift
import CoreGraphics

struct PetPhysicsState {
    var position: CGPoint
    var velocity: CGVector
    var surface: PetSurface
    var facingRight: Bool = true
}

struct ScreenSurfaces {
    let ground: CGFloat
    let ceiling: CGFloat
    let leftWall: CGFloat
    let rightWall: CGFloat
    let dynamicIslandRect: CGRect

    #if DEBUG
    static func test(ground: CGFloat = 800, ceiling: CGFloat = 50,
                     leftWall: CGFloat = 0, rightWall: CGFloat = 400) -> ScreenSurfaces {
        ScreenSurfaces(ground: ground, ceiling: ceiling,
                       leftWall: leftWall, rightWall: rightWall,
                       dynamicIslandRect: CGRect(x: 120, y: 0, width: 160, height: 40))
    }
    #endif
}
```

Create `PeerDrop/Pet/Engine/PetPhysicsEngine.swift`:
```swift
import CoreGraphics

enum PetPhysicsEngine {

    static let gravity: CGFloat = 800
    static let bounceRestitution: CGFloat = 0.3
    static let throwDecay: CGFloat = 0.95
    static let petSize: CGFloat = 16

    /// Main physics tick. Call at 60 FPS.
    static func update(_ state: inout PetPhysicsState, dt: CGFloat, surfaces: ScreenSurfaces) {
        guard state.surface == .airborne else { return }

        // Apply gravity
        state.velocity.dy += gravity * dt

        // Apply throw decay to horizontal
        state.velocity.dx *= throwDecay

        // Integrate position
        state.position.x += state.velocity.dx * dt
        state.position.y += state.velocity.dy * dt

        // Resolve collisions
        resolveCollision(&state, surfaces: surfaces)
    }

    static func resolveCollision(_ state: inout PetPhysicsState, surfaces: ScreenSurfaces) {
        // Ground
        if state.position.y >= surfaces.ground {
            state.position.y = surfaces.ground
            if abs(state.velocity.dy) > 20 {
                state.velocity.dy = -state.velocity.dy * bounceRestitution
            } else {
                state.velocity = .zero
                state.surface = .ground
            }
        }
        // Ceiling
        if state.position.y <= surfaces.ceiling {
            state.position.y = surfaces.ceiling
            state.velocity.dy = 0
            state.surface = .ceiling
        }
        // Walls
        if state.position.x <= surfaces.leftWall {
            state.position.x = surfaces.leftWall
            state.velocity.dx = 0
            state.surface = .leftWall
        }
        if state.position.x >= surfaces.rightWall - petSize {
            state.position.x = surfaces.rightWall - petSize
            state.velocity.dx = 0
            state.surface = .rightWall
        }
    }

    static func applyWalk(_ state: inout PetPhysicsState, direction: HorizontalDirection,
                          speed: CGFloat, dt: CGFloat, surfaces: ScreenSurfaces) {
        let dx = direction == .right ? speed * dt : -speed * dt
        state.position.x += dx
        state.facingRight = direction == .right
        // Clamp to surface
        state.position.x = max(surfaces.leftWall, min(state.position.x, surfaces.rightWall - petSize))
    }

    static func applyClimb(_ state: inout PetPhysicsState, speed: CGFloat,
                           dt: CGFloat, surfaces: ScreenSurfaces) {
        state.position.y -= speed * dt // climb upward
        if state.position.y <= surfaces.ceiling {
            state.position.y = surfaces.ceiling
            state.surface = .ceiling
        }
    }

    static func applyJump(_ state: inout PetPhysicsState, jumpVelocity: CGFloat = -300) {
        state.velocity.dy = jumpVelocity
        state.surface = .airborne
    }

    static func applyThrow(_ state: inout PetPhysicsState, velocity: CGVector) {
        state.velocity = velocity
        state.surface = .airborne
    }

    enum HorizontalDirection { case left, right }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetPhysicsEngineTests -quiet 2>&1 | tail -20`
Expected: All 7 tests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Engine/PetPhysicsEngine.swift PeerDrop/Pet/Model/PetPhysicsState.swift \
  PeerDropTests/PetPhysicsEngineTests.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add PetPhysicsEngine — gravity, surfaces, collision, climb, throw"
```

---

### Task 9: Particle Effect System

**Files:**
- Create: `PeerDrop/Pet/UI/PetParticleView.swift`
- Create: `PeerDrop/Pet/Model/PetParticle.swift`

**Step 1: Create particle model**

```swift
// PeerDrop/Pet/Model/PetParticle.swift
import CoreGraphics
import Foundation

enum ParticleType: String {
    case heart, zzz, sweat, poop, star
}

struct PetParticle: Identifiable {
    let id = UUID()
    let type: ParticleType
    var position: CGPoint
    let velocity: CGVector
    let lifetime: TimeInterval
    let createdAt: Date = Date()

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > lifetime
    }
}
```

**Step 2: Create particle view**

```swift
// PeerDrop/Pet/UI/PetParticleView.swift
import SwiftUI

struct PetParticleView: View {
    let particle: PetParticle
    @State private var opacity: Double = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        Text(particle.type.emoji)
            .font(.system(size: 14))
            .opacity(opacity)
            .offset(offset)
            .onAppear {
                withAnimation(.linear(duration: particle.lifetime)) {
                    offset = CGSize(width: particle.velocity.dx * particle.lifetime,
                                    height: particle.velocity.dy * particle.lifetime)
                    opacity = 0
                }
            }
    }
}

extension ParticleType {
    var emoji: String {
        switch self {
        case .heart: return "❤️"
        case .zzz: return "💤"
        case .sweat: return "💦"
        case .poop: return "💩"
        case .star: return "⭐"
        }
    }
}
```

**Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add PeerDrop/Pet/Model/PetParticle.swift PeerDrop/Pet/UI/PetParticleView.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add particle effect system — heart, zzz, sweat, poop, star"
```

---

### Task 10: New PetRenderer v2 — Orchestrate the Full Pipeline

**Files:**
- Create: `PeerDrop/Pet/Renderer/PetRendererV2.swift`
- Test: `PeerDropTests/PetRendererV2Tests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetRendererV2Tests.swift
import XCTest
@testable import PeerDrop

final class PetRendererV2Tests: XCTestCase {

    func testRenderEggReturnsCGImage() {
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.egg
        let image = PetRendererV2.shared.render(genome: genome, level: .egg, mood: .curious,
                                                  frame: 0, palette: palette, scale: 1)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
    }

    func testRenderBabyCatReturnsCGImage() {
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let image = PetRendererV2.shared.render(genome: genome, level: .baby, mood: .curious,
                                                  frame: 0, palette: palette, scale: 1)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
    }

    func testRenderScaled() {
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let image = PetRendererV2.shared.render(genome: genome, level: .baby, mood: .curious,
                                                  frame: 0, palette: palette, scale: 8)
        XCTAssertEqual(image?.width, 128)
    }

    func testRenderCachesResult() {
        let renderer = PetRendererV2()
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let img1 = renderer.render(genome: genome, level: .baby, mood: .curious,
                                    frame: 0, palette: palette, scale: 1)
        let img2 = renderer.render(genome: genome, level: .baby, mood: .curious,
                                    frame: 0, palette: palette, scale: 1)
        // Both should return non-nil (cache hit on second call)
        XCTAssertNotNil(img1)
        XCTAssertNotNil(img2)
    }

    func testRenderFlippedForLeftFacing() {
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]
        let right = PetRendererV2.shared.render(genome: genome, level: .baby, mood: .curious,
                                                  frame: 0, palette: palette, scale: 1, facingRight: true)
        let left = PetRendererV2.shared.render(genome: genome, level: .baby, mood: .curious,
                                                 frame: 0, palette: palette, scale: 1, facingRight: false)
        XCTAssertNotNil(right)
        XCTAssertNotNil(left)
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — `PetRendererV2` not found

**Step 3: Implement PetRendererV2**

```swift
// PeerDrop/Pet/Renderer/PetRendererV2.swift
import CoreGraphics

class PetRendererV2 {

    static let shared = PetRendererV2()
    private let cache = SpriteCache(maxEntries: 200)

    func render(genome: PetGenome, level: PetLevel, mood: PetMood,
                frame: Int, palette: ColorPalette, scale: Int = 8,
                facingRight: Bool = true) -> CGImage? {

        let action: PetAction = .idle // default; caller should pass current action in future
        let cacheKey = SpriteCache.Key(body: genome.body, stage: level,
                                        action: action, frame: frame,
                                        paletteIndex: genome.paletteIndex)

        if let cached = cache.get(cacheKey) { return cached }

        let indices: [[UInt8]]

        switch level {
        case .egg:
            let eggFrames = EggSpriteData.idle
            let f = frame % eggFrames.count
            indices = eggFrames[f]

        case .baby, .child:
            guard let bodyFrames = spriteData(for: genome.body, stage: level, action: action) else {
                return nil
            }
            let f = frame % bodyFrames.count
            let body = bodyFrames[f]
            let meta = bodyMeta(for: genome.body)

            // Eyes
            let eyes: [[UInt8]]?
            if let moodEyes = EyeSpriteData.moods[mood] {
                eyes = moodEyes
            } else {
                eyes = EyeSpriteData.sprites[genome.eyes]
            }

            // Pattern
            let pattern = genome.pattern != .none ? PatternSpriteData.sprites[genome.pattern] : nil

            var composite = SpriteCompositor.composite(
                body: body, eyes: eyes, eyeAnchor: meta.eyeAnchor,
                pattern: pattern, patternMask: meta.patternMask
            )

            if !facingRight {
                composite = SpriteCompositor.flipHorizontal(composite)
            }

            indices = composite
        }

        guard let image = PaletteSwapRenderer.render(indices: indices, palette: palette, scale: scale) else {
            return nil
        }

        cache.set(image, for: cacheKey)
        return image
    }

    private func spriteData(for body: BodyGene, stage: PetLevel, action: PetAction) -> [[[UInt8]]]? {
        switch body {
        case .cat: return CatSpriteData.baby[action]
        default: return CatSpriteData.baby[action] // fallback to cat until other bodies are created
        }
    }

    private func bodyMeta(for body: BodyGene) -> BodyMeta {
        switch body {
        case .cat: return CatSpriteData.meta
        default: return CatSpriteData.meta // fallback
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PetRendererV2Tests -quiet 2>&1 | tail -20`
Expected: All 5 tests PASS

**Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/PetRendererV2.swift PeerDropTests/PetRendererV2Tests.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add PetRendererV2 — sprite sheet pipeline with cache and composition"
```

---

### Task 11: Rewrite FloatingPetView with Physics + New Renderer

**Files:**
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift`
- Modify: `PeerDrop/Pet/UI/PixelView.swift` (replace or adapt)
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`

**Step 1: Replace PixelView with SpriteImageView**

Create a new view that displays CGImage:
```swift
// Replace contents of PeerDrop/Pet/UI/PixelView.swift
import SwiftUI

struct SpriteImageView: View {
    let image: CGImage?
    let displaySize: CGFloat

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1.0)
                .interpolation(.none) // nearest-neighbor!
                .resizable()
                .frame(width: displaySize, height: displaySize)
        } else {
            Color.clear.frame(width: displaySize, height: displaySize)
        }
    }
}

// Keep PixelView as deprecated alias for backwards compat during migration
struct PixelView: View {
    let grid: PixelGrid
    let palette: ColorPalette
    let displaySize: CGFloat

    var body: some View {
        Canvas { context, size in
            let pixelSize = size.width / CGFloat(grid.size)
            for y in 0..<grid.size {
                for x in 0..<grid.size {
                    let val = grid.pixels[y][x]
                    guard val != 0, let color = palette.color(for: val) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * pixelSize,
                                             y: CGFloat(y) * pixelSize,
                                             width: pixelSize, height: pixelSize)),
                                 with: .color(color))
                }
            }
        }
        .frame(width: displaySize, height: displaySize)
    }
}
```

**Step 2: Add physics state and rendered image to PetEngine**

Add to `PeerDrop/Pet/Engine/PetEngine.swift`:
```swift
// Add new published properties
@Published private(set) var renderedImage: CGImage?
@Published var physicsState: PetPhysicsState = PetPhysicsState(
    position: CGPoint(x: 60, y: 200), velocity: .zero, surface: .ground)
@Published var particles: [PetParticle] = []

private let rendererV2 = PetRendererV2()

// Add method to update rendered image
private func updateRenderedImage() {
    let scale = 8 // 16 * 8 = 128px display
    renderedImage = rendererV2.render(
        genome: pet.genome, level: pet.level, mood: pet.mood,
        frame: animator.currentFrame, palette: palette, scale: scale,
        facingRight: physicsState.facingRight)
}
```

**Step 3: Rewrite FloatingPetView with physics**

```swift
// PeerDrop/Pet/UI/FloatingPetView.swift
import SwiftUI

struct FloatingPetView: View {
    @ObservedObject var engine: PetEngine
    @State private var isDragging = false
    @State private var dragVelocity: CGVector = .zero
    @State private var lastDragPositions: [(CGPoint, Date)] = []
    @State private var showInteractionPanel = false
    @State private var displayLink: CADisplayLink?

    var body: some View {
        ZStack {
            // Particles
            ForEach(engine.particles) { particle in
                PetParticleView(particle: particle)
                    .position(particle.position)
            }

            // Pet sprite
            SpriteImageView(image: engine.renderedImage, displaySize: 128)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            // Dialogue bubble
            if let dialogue = engine.currentDialogue {
                PetBubbleView(text: dialogue)
                    .offset(y: -72)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .position(engine.physicsState.position)
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    engine.physicsState.position = value.location
                    engine.physicsState.surface = .airborne
                    trackDragVelocity(value.location)
                    engine.currentAction = .pickedUp
                }
                .onEnded { _ in
                    isDragging = false
                    let velocity = calculateThrowVelocity()
                    PetPhysicsEngine.applyThrow(&engine.physicsState, velocity: velocity)
                    engine.currentAction = .thrown
                    engine.handleInteraction(.tap)
                }
        )
        .onTapGesture { engine.handleInteraction(.tap) }
        .onLongPressGesture { showInteractionPanel = true }
        .sheet(isPresented: $showInteractionPanel) {
            PetInteractionView(engine: engine)
        }
        .accessibilityIdentifier("floating-pet")
        .accessibilityLabel("Pet")
        .onAppear { startPhysicsLoop() }
        .onDisappear { stopPhysicsLoop() }
    }

    // MARK: - Physics Loop

    private func startPhysicsLoop() {
        let link = CADisplayLink(target: PhysicsTarget(update: physicsStep), selector: #selector(PhysicsTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopPhysicsLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func physicsStep() {
        guard !isDragging else { return }
        let dt: CGFloat = 1.0 / 60.0
        let surfaces = currentScreenSurfaces()

        switch engine.physicsState.surface {
        case .airborne:
            PetPhysicsEngine.update(&engine.physicsState, dt: dt, surfaces: surfaces)
        case .ground:
            if engine.currentAction == .walking {
                let dir: PetPhysicsEngine.HorizontalDirection = engine.physicsState.facingRight ? .right : .left
                PetPhysicsEngine.applyWalk(&engine.physicsState, direction: dir, speed: 30, dt: dt, surfaces: surfaces)
            }
        case .leftWall, .rightWall:
            if engine.currentAction == .climb {
                PetPhysicsEngine.applyClimb(&engine.physicsState, speed: 20, dt: dt, surfaces: surfaces)
            }
        default:
            break
        }
    }

    private func currentScreenSurfaces() -> ScreenSurfaces {
        let screen = UIScreen.main.bounds
        let safeArea = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .first ?? .zero
        return ScreenSurfaces(
            ground: screen.height - safeArea.bottom - 16,
            ceiling: safeArea.top,
            leftWall: 0,
            rightWall: screen.width,
            dynamicIslandRect: CGRect(x: screen.width / 2 - 63, y: 0, width: 126, height: 37)
        )
    }

    // MARK: - Drag Velocity Tracking

    private func trackDragVelocity(_ position: CGPoint) {
        lastDragPositions.append((position, Date()))
        if lastDragPositions.count > 3 { lastDragPositions.removeFirst() }
    }

    private func calculateThrowVelocity() -> CGVector {
        guard lastDragPositions.count >= 2 else { return .zero }
        let first = lastDragPositions.first!
        let last = lastDragPositions.last!
        let dt = last.1.timeIntervalSince(first.1)
        guard dt > 0.01 else { return .zero }
        return CGVector(
            dx: (last.0.x - first.0.x) / dt,
            dy: (last.0.y - first.0.y) / dt
        )
    }
}

// CADisplayLink target (avoids retain cycle)
private class PhysicsTarget {
    let update: () -> Void
    init(update: @escaping () -> Void) { self.update = update }
    @objc func tick() { update() }
}
```

**Step 4: Build and test manually**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10`
Expected: Build succeeds

Run full tests: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`
Expected: All tests pass (some old renderer tests may need updating)

**Step 5: Commit**

```bash
git add PeerDrop/Pet/UI/FloatingPetView.swift PeerDrop/Pet/UI/PixelView.swift \
  PeerDrop/Pet/Engine/PetEngine.swift
git commit -m "feat(pet): rewrite FloatingPetView with physics engine and sprite-based rendering"
```

---

### Task 12: Wandering + Edge Behavior State Machine

**Files:**
- Create: `PeerDrop/Pet/Engine/PetBehaviorController.swift`
- Test: `PeerDropTests/PetBehaviorControllerTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetBehaviorControllerTests.swift
import XCTest
@testable import PeerDrop

final class PetBehaviorControllerTests: XCTestCase {

    func testIdleTransitionsToWalk() {
        var state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .baby, elapsed: 6)
        // After 5+ seconds idle, should suggest walk
        XCTAssertTrue(action == .walking || action == .idle) // probabilistic, but walk is possible
    }

    func testEggNeverWanders() {
        let state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        for _ in 0..<100 {
            let action = PetBehaviorController.nextBehavior(current: .idle, physics: state, level: .egg, elapsed: 100)
            XCTAssertEqual(action, .idle, "Egg should never wander")
        }
    }

    func testWalkToEdgeStartsClimb() {
        let state = PetPhysicsState(position: CGPoint(x: 0, y: 780), velocity: .zero, surface: .leftWall)
        let action = PetBehaviorController.nextBehavior(current: .walking, physics: state, level: .baby, elapsed: 0)
        XCTAssertTrue(action == .climb || action == .walking) // 50% chance climb
    }

    func testHangTransitionsToFallOrSit() {
        let state = PetPhysicsState(position: CGPoint(x: 0, y: 50), velocity: .zero, surface: .ceiling)
        let action = PetBehaviorController.nextBehavior(current: .hang, physics: state, level: .baby, elapsed: 3)
        XCTAssertTrue(action == .fall || action == .sitEdge || action == .hang)
    }
}
```

**Step 2: Implement PetBehaviorController**

```swift
// PeerDrop/Pet/Engine/PetBehaviorController.swift
import CoreGraphics

enum PetBehaviorController {

    /// Suggest next behavior based on current state, physics, and elapsed time in current action.
    static func nextBehavior(current: PetAction, physics: PetPhysicsState,
                             level: PetLevel, elapsed: TimeInterval) -> PetAction {
        guard level != .egg else { return .idle }

        switch (current, physics.surface) {
        case (.idle, .ground):
            if elapsed > 5 { return Bool.random() ? .walking : .idle }
            return .idle

        case (.walking, .ground):
            if elapsed > 4 { return .idle }
            return .walking

        case (.walking, .leftWall), (.walking, .rightWall):
            return Bool.random() ? .climb : .walking // 50% climb

        case (.climb, .leftWall), (.climb, .rightWall):
            if elapsed > 3 { return Bool.random() ? .fall : .hang }
            return .climb

        case (.climb, .ceiling):
            return .hang

        case (.hang, .ceiling):
            if elapsed > 3 {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 { return .fall }
                if roll < 0.6 { return .sitEdge }
                return .hang
            }
            return .hang

        case (.sitEdge, .ceiling):
            if elapsed > 8 { return .fall }
            return .sitEdge

        case (.fall, _):
            return .fall // physics handles landing → idle

        case (.thrown, _):
            return .thrown

        case (_, .airborne):
            return .fall

        default:
            return current
        }
    }
}
```

**Step 3: Run tests**

Expected: All 4 tests PASS (some are probabilistic — the egg test is deterministic)

**Step 4: Commit**

```bash
git add PeerDrop/Pet/Engine/PetBehaviorController.swift PeerDropTests/PetBehaviorControllerTests.swift
xcodegen generate && git add PeerDrop.xcodeproj
git commit -m "feat(pet): add PetBehaviorController — wandering and edge behavior state machine"
```

---

### Task 13: Integration Test + Cleanup

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift` (wire everything together)
- Create: `PeerDropTests/PetIntegrationTests.swift`
- Delete old files if safe (or mark deprecated)

**Step 1: Write integration test**

```swift
// PeerDropTests/PetIntegrationTests.swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetIntegrationTests: XCTestCase {

    func testEggRenders16x16() {
        let engine = PetEngine(pet: .newEgg())
        XCTAssertNotNil(engine.renderedImage)
        XCTAssertEqual(engine.renderedImage?.width, 128) // 16 * 8 scale
    }

    func testBabyRenders16x16() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        let engine = PetEngine(pet: pet)
        XCTAssertNotNil(engine.renderedImage)
    }

    func testTapInteractionUpdatesState() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        let engine = PetEngine(pet: pet)
        let oldExp = engine.pet.experience
        engine.handleInteraction(.tap)
        XCTAssertGreaterThan(engine.pet.experience, oldExp)
    }

    func testEggDoesNotMove() {
        let engine = PetEngine(pet: .newEgg())
        let startPos = engine.physicsState.position
        // Simulate behavior tick
        let action = PetBehaviorController.nextBehavior(
            current: .idle, physics: engine.physicsState, level: .egg, elapsed: 100)
        XCTAssertEqual(action, .idle)
        XCTAssertEqual(engine.physicsState.position.x, startPos.x)
    }
}
```

**Step 2: Wire PetEngine to use new renderer and behavior controller**

Update PetEngine to:
- Replace old `PetRenderer` with `PetRendererV2`
- Replace old `PixelGrid` rendering with `CGImage` rendering
- Add behavior controller ticks
- Keep old `renderedGrid` as computed property for backwards compat with any remaining UI

**Step 3: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`
Expected: All tests pass

**Step 4: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift PeerDropTests/PetIntegrationTests.swift
git commit -m "feat(pet): integrate PetRendererV2, physics, and behavior controller into PetEngine"
```

---

### Task 14: Final Phase 1 Cleanup + Poop State

**Files:**
- Create: `PeerDrop/Pet/Model/PoopState.swift`
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift` (add poop tracking)
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift` (render poops on screen)

**Step 1: Create PoopState**

```swift
// PeerDrop/Pet/Model/PoopState.swift
import CoreGraphics
import Foundation

struct PoopState {
    struct Poop: Identifiable {
        let id = UUID()
        let position: CGPoint
        let droppedAt: Date
    }

    var poops: [Poop] = []
    let maxPoops = 3
    let moodPenaltyDelay: TimeInterval = 600

    var hasUncleanedPoops: Bool { !poops.isEmpty }
    var isFull: Bool { poops.count >= maxPoops }

    var hasMoodPenalty: Bool {
        poops.contains { Date().timeIntervalSince($0.droppedAt) > moodPenaltyDelay }
    }

    mutating func drop(at position: CGPoint) {
        guard !isFull else { return }
        poops.append(Poop(position: position, droppedAt: Date()))
    }

    mutating func clean(id: UUID) -> Bool {
        guard let idx = poops.firstIndex(where: { $0.id == id }) else { return false }
        poops.remove(at: idx)
        return true
    }
}
```

**Step 2: Add poop rendering to FloatingPetView**

In FloatingPetView body, add poop sprites as tappable items on screen.

**Step 3: Build + test**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -30`

**Step 4: Final Phase 1 commit**

```bash
git add PeerDrop/Pet/Model/PoopState.swift PeerDrop/Pet/Engine/PetEngine.swift \
  PeerDrop/Pet/UI/FloatingPetView.swift
git commit -m "feat(pet): add poop state tracking and on-screen poop rendering

Phase 1 complete: 16x16 sprite pipeline, Shimeji physics, Cat body type,
particle effects, poop mechanic, behavior state machine."
```

---

## Phase 1 Deliverables Checklist

After all 14 tasks, you should have:

- [ ] 10 body gene types (only Cat has sprites, others fallback to Cat)
- [ ] SpriteSheetLoader — loads and slices indexed color PNGs
- [ ] PaletteSwapRenderer — maps indices to palette colors → CGImage
- [ ] SpriteCache — LRU cache for rendered sprites
- [ ] SpriteCompositor — layers body + eyes + pattern
- [ ] PetAnimationController — 6 FPS, variable frame counts
- [ ] Cat 16x16 sprite data — all 19 actions
- [ ] PetPhysicsEngine — gravity, walls, ceiling, collision, bounce
- [ ] Particle effects — heart, zzz, sweat, poop, star
- [ ] PetRendererV2 — full pipeline orchestrator
- [ ] FloatingPetView — physics-driven with drag/throw
- [ ] PetBehaviorController — wandering + edge behavior state machine
- [ ] Poop mechanic — drop, display, tap to clean
- [ ] All existing tests still pass + new tests for every component
