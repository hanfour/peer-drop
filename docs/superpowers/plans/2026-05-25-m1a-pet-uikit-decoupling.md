# M1a — Pet UIKit Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove direct UIKit imports from 6 files in `PeerDrop/Pet/` (5 in `Pet/Renderer/`, 1 in `Pet/Engine/`) by extending M0's `PlatformImage`/`PlatformColor` typealiases with the missing cross-platform helpers (`init(cgImage:)`, `init(systemName:)`, `withTintColor(_:)`, `PlatformGraphicsRenderer`), and routing PetEngine's heavy haptic through the existing `HapticFeedback` protocol.

**Architecture:** Build on M0's `PeerDrop/Core/Platform/` registry. Add platform-image init helpers + a new `PlatformGraphicsRenderer` wrapper around `UIGraphicsImageRenderer` (iOS) / `NSGraphicsContext` (macOS). Extend `HapticFeedback` protocol with `heavyImpact()`. iOS behaviour byte-for-byte preserved.

**Tech Stack:** Swift 5.9, iOS 16+, XCTest, XcodeGen. Builds: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`. Same for `test`.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1a section (post-restructuring 2026-05-25).

**Predecessor:** M0 shipped on `main` (tag `m0-core-uikit-decoupled`, merge commit `a3f6ba1`).

**Investigation findings (corrects spec):** Pet renderer was NOT UIKit-free as the original spec assumed. Actual UIKit usage:
- `PetRendererV3.swift` — `UIImage`, `UIGraphicsImageRenderer`, `UIGraphicsImageRendererFormat`, `UIImage(systemName:)`, `.withTintColor(...)`
- `AccessoryOverlay.swift` — `UIImage` return type
- `MoodOverlay.swift` — `UIColor` return type, `.systemYellow/Teal/Blue/Gray/Pink/Red`
- `RarityOverlay.swift` — `UIColor` return type
- `SpriteSheetLoader.swift` — DEAD `import UIKit` (the file actually only uses CoreGraphics)
- `PetEngine.swift` — `UIImpactFeedbackGenerator(style: .heavy)` at line 401 only

`PetPalettes.swift` uses SwiftUI.Color which is already cross-platform — no change needed.

---

## File Structure

**New files (3):**
- `PeerDrop/Core/Platform/PlatformGraphicsRenderer.swift` — cross-platform image-context renderer
- `PeerDrop/Core/Platform/iOS/UIKitGraphicsRenderer.swift` — iOS implementation
- `PeerDropTests/Core/Platform/PlatformGraphicsRendererTests.swift` — round-trip test

**Modified files (10):**
- `PeerDrop/Core/Platform/PlatformImage.swift` — gain `init(cgImage:)`, `init(systemName:)`, `withTintColor(_:)` helpers
- `PeerDrop/Core/Platform/HapticFeedback.swift` — gain `heavyImpact()` method
- `PeerDrop/Core/Platform/iOS/UIKitHapticFeedback.swift` — implement `heavyImpact()`
- `PeerDropTests/Core/Platform/MockPlatformDependencies.swift` — MockHaptics gains heavyImpact, PlatformDependencies NoOp gains heavyImpact
- `PeerDrop/Pet/Renderer/SpriteSheetLoader.swift` — drop dead `import UIKit`
- `PeerDrop/Pet/Renderer/MoodOverlay.swift` — `UIColor` → `PlatformColor`
- `PeerDrop/Pet/Renderer/RarityOverlay.swift` — `UIColor` → `PlatformColor`
- `PeerDrop/Pet/Renderer/AccessoryOverlay.swift` — `UIImage` → `PlatformImage`
- `PeerDrop/Pet/Renderer/PetRendererV3.swift` — use `PlatformGraphicsRenderer`, `PlatformImage(systemName:)`, `PlatformImage(cgImage:)`, drop UIKit
- `PeerDrop/Pet/Engine/PetEngine.swift` — replace `UIImpactFeedbackGenerator` with `HapticManager.evolutionTriggered()` (new method); also wraps the one `UIKit` import in `#if os(iOS)` if any other usage remains (verify)

**Note on `PlatformColor` system colors:** `UIColor.systemYellow` (and friends) have NSColor equivalents (`NSColor.systemYellow`) on macOS 11+. The M0 typealias `PlatformColor = UIColor / NSColor` makes `.systemYellow` resolve correctly on each platform — no extra extension needed.

**Note on `HapticManager` static facade extension:** PetEngine currently allocates `UIImpactFeedbackGenerator(style: .heavy)` directly. The cleanest fix is to add a new semantic method `evolutionTriggered()` to the protocol (mirroring M0's naming convention — `tap()`, `transferComplete()` etc, NOT the UIKit generator names). PetEngine then calls `HapticManager.evolutionTriggered()`. iOS impl uses `UIImpactFeedbackGenerator(style: .heavy)`. macOS no-op.

---

## Task 1: Add `PlatformImage(cgImage:)` + `PlatformImage(systemName:)` helpers

**Files:**
- Modify: `PeerDrop/Core/Platform/PlatformImage.swift`
- Test: `PeerDropTests/Core/Platform/PlatformImageTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `PeerDropTests/Core/Platform/PlatformImageTests.swift`:

```swift
    func test_initWithCGImage_roundTrips() {
        // 2x2 red pixel CGImage
        let width = 2, height = 2
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        var bytes: [UInt8] = [
            255, 0, 0, 255,   255, 0, 0, 255,
            255, 0, 0, 255,   255, 0, 0, 255,
        ]
        let provider = CGDataProvider(data: Data(bytes: &bytes, count: bytes.count) as CFData)!
        let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: bitsPerComponent, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let image = PlatformImage(platformCGImage: cgImage, size: CGSize(width: 2, height: 2))
        XCTAssertNotNil(image)
    }

    func test_initWithSystemName_returnsImageForKnownSymbol() {
        let image = PlatformImage(platformSystemName: "circle.fill")
        XCTAssertNotNil(image, "circle.fill should resolve to an SF Symbol")
    }

    func test_initWithSystemName_returnsNilForUnknownSymbol() {
        let image = PlatformImage(platformSystemName: "this.symbol.does.not.exist.12345")
        XCTAssertNil(image)
    }
```

(Method names use `platform` prefix to avoid colliding with `UIImage(systemName:)` which already exists on iOS.)

- [ ] **Step 2: Run tests, expect FAIL (method not found)**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformImageTests \
  -quiet 2>&1 | tail -10
```

Expected: compile error for `platformCGImage` / `platformSystemName`.

- [ ] **Step 3: Extend `PlatformImage.swift` with the helper inits**

Edit `PeerDrop/Core/Platform/PlatformImage.swift`. Append after the existing `platformJPEGData` extension:

```swift
extension PlatformImage {
    /// Cross-platform CGImage adapter. iOS uses `UIImage(cgImage:)` (size derived
    /// from CGImage); macOS uses `NSImage(cgImage:size:)` (size must be supplied).
    convenience init?(platformCGImage cgImage: CGImage, size: CGSize) {
        #if canImport(UIKit)
        self.init(cgImage: cgImage)
        #elseif canImport(AppKit)
        self.init(cgImage: cgImage, size: size)
        #else
        return nil
        #endif
    }

    /// Cross-platform SF Symbol loader. iOS uses `UIImage(systemName:)`;
    /// macOS uses `NSImage(systemSymbolName:accessibilityDescription:)` (macOS 11+).
    convenience init?(platformSystemName name: String) {
        #if canImport(UIKit)
        self.init(systemName: name)
        #elseif canImport(AppKit)
        self.init(systemSymbolName: name, accessibilityDescription: nil)
        #else
        return nil
        #endif
    }
}
```

Note: `UIImage.init(systemName:)` is a failable initializer; `NSImage.init?(systemSymbolName:accessibilityDescription:)` is also failable. Both return nil on bad input.

Also: `UIImage(cgImage:)` is a non-failable convenience init, but Swift's convenience-init forwarding rules mean a failable `init?` can call a non-failable `init` — the `return nil` path in `#else` exists only for the dead branch.

- [ ] **Step 4: Re-run tests, expect PASS**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformImageTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **` (5 tests total: 2 from M0 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/Platform/PlatformImage.swift PeerDropTests/Core/Platform/PlatformImageTests.swift
git commit -m "$(cat <<'EOF'
refactor(core): PlatformImage gains cgImage + systemName helpers (M1a)

Two convenience inits with `platform` prefix to avoid colliding with
UIImage(systemName:) on iOS. macOS branches use NSImage init APIs.
Foundation for Pet/Renderer decoupling (subsequent M1a tasks).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `PlatformImage.withTintColor(_:)` helper

**Files:**
- Modify: `PeerDrop/Core/Platform/PlatformImage.swift`
- Test: `PeerDropTests/Core/Platform/PlatformImageTests.swift`

UIImage has `withTintColor(_ color: UIColor, renderingMode: UIImage.RenderingMode) -> UIImage`. PetRendererV3 uses `UIImage(systemName: iconName)?.withTintColor(tint, renderingMode: .alwaysOriginal)`.

NSImage doesn't have a direct `withTintColor` — the closest is setting `isTemplate = true` and letting AppKit tint via `NSColor.controlAccentColor`, OR manually compositing through `lockFocus()`. For our use case (tinted SF Symbol composited onto a CGImage canvas), we need an explicit color application.

Strategy: provide `platformWithTintColor(_:)` that returns a `PlatformImage` with the tint baked in. iOS uses native API; macOS implementation does a manual color-blend pass.

- [ ] **Step 1: Write the failing test**

Append to `PlatformImageTests.swift`:

```swift
    func test_withTintColor_returnsNonNilImage() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let source: PlatformImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let tinted = source.platformWithTintColor(PlatformColor.red)
        XCTAssertNotNil(tinted)
    }
```

- [ ] **Step 2: Run, expect FAIL**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformImageTests/test_withTintColor_returnsNonNilImage \
  -quiet
```

Expected: compile error.

- [ ] **Step 3: Implement `platformWithTintColor`**

Append to `PeerDrop/Core/Platform/PlatformImage.swift`:

```swift
extension PlatformImage {
    /// Cross-platform tinted image. iOS forwards to `UIImage.withTintColor(_:renderingMode: .alwaysOriginal)`;
    /// macOS composites the tint via a destinationIn blend pass.
    func platformWithTintColor(_ color: PlatformColor) -> PlatformImage {
        #if canImport(UIKit)
        return self.withTintColor(color, renderingMode: .alwaysOriginal)
        #elseif canImport(AppKit)
        let tinted = NSImage(size: self.size)
        tinted.lockFocus()
        defer { tinted.unlockFocus() }
        let rect = NSRect(origin: .zero, size: self.size)
        self.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return tinted
        #else
        return self
        #endif
    }
}
```

- [ ] **Step 4: Re-run test, expect PASS**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformImageTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/Platform/PlatformImage.swift PeerDropTests/Core/Platform/PlatformImageTests.swift
git commit -m "$(cat <<'EOF'
refactor(core): PlatformImage gains platformWithTintColor helper (M1a)

iOS forwards to UIImage.withTintColor(_:renderingMode:); macOS uses
NSImage lockFocus + .sourceAtop blend. Needed by PetRendererV3 mood
overlay compositing (M1a Task 10).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `PlatformGraphicsRenderer` (cross-platform UIGraphicsImageRenderer wrapper)

**Files:**
- Create: `PeerDrop/Core/Platform/PlatformGraphicsRenderer.swift`
- Create: `PeerDrop/Core/Platform/iOS/UIKitGraphicsRenderer.swift`
- Test: `PeerDropTests/Core/Platform/PlatformGraphicsRendererTests.swift`

This is the biggest new abstraction in M1a. `UIGraphicsImageRenderer` lets you draw into a graphics context and get a `UIImage` out. We need the same semantic on macOS via `NSGraphicsContext`.

API design: pass the size + a drawing closure that receives a `CGContext`. Return a `PlatformImage`. This is a simpler API than `UIGraphicsImageRenderer` (no format object, no scale option) but matches everything PetRendererV3 needs.

- [ ] **Step 1: Write the failing test**

Create `PeerDropTests/Core/Platform/PlatformGraphicsRendererTests.swift`:

```swift
import XCTest
@testable import PeerDrop

final class PlatformGraphicsRendererTests: XCTestCase {
    func test_drawsIntoContext_andReturnsImageWithCGImage() {
        let renderer = PlatformGraphicsRenderer(size: CGSize(width: 10, height: 10))
        let image = renderer.image { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        XCTAssertNotNil(image)
        XCTAssertNotNil(image.cgImage, "PlatformImage should be CGImage-backed")
    }

    func test_producesDeterministicOutput() {
        let renderer1 = PlatformGraphicsRenderer(size: CGSize(width: 4, height: 4))
        let renderer2 = PlatformGraphicsRenderer(size: CGSize(width: 4, height: 4))
        let drawing: (CGContext) -> Void = { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let img1 = renderer1.image(drawing: drawing)
        let img2 = renderer2.image(drawing: drawing)
        XCTAssertEqual(img1.cgImage?.dataProvider?.data, img2.cgImage?.dataProvider?.data,
                       "PetRendererV3 caching contract requires deterministic output")
    }
}
```

(The second test pins the caching invariant the spec called out: "UIGraphicsImageRenderer produces byte-identical output for identical inputs — the M4.3 caching contract relies on this".)

Note on `PlatformImage.cgImage`: `UIImage.cgImage` exists; `NSImage.cgImage` does NOT exist directly — must call `NSImage.cgImage(forProposedRect:context:hints:)`. To keep call-site code clean, we add a `platformCGImage` getter in Task 4 OR we resolve via an extension here. Cleanest: add the getter as part of Task 3 since the test needs it.

So also add to `PlatformImage.swift` (still inside Task 3):

```swift
extension PlatformImage {
    /// Cross-platform CGImage accessor. iOS forwards to `UIImage.cgImage`;
    /// macOS forwards to `NSImage.cgImage(forProposedRect:context:hints:)`.
    var platformCGImage: CGImage? {
        #if canImport(UIKit)
        return self.cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: self.size)
        return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }
}
```

Update the test to use `platformCGImage` instead of `.cgImage`:

```swift
        XCTAssertNotNil(image.platformCGImage, "PlatformImage should be CGImage-backed")
```

And in `test_producesDeterministicOutput`:

```swift
        XCTAssertEqual(img1.platformCGImage?.dataProvider?.data,
                       img2.platformCGImage?.dataProvider?.data,
                       "PetRendererV3 caching contract requires deterministic output")
```

- [ ] **Step 2: Run, expect FAIL (PlatformGraphicsRenderer not found)**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformGraphicsRendererTests \
  -quiet 2>&1 | tail -10
```

Expected: compile error.

- [ ] **Step 3: Create `PlatformGraphicsRenderer.swift` (struct API; platform-specific impl lives in `iOS/` for iOS, inline `#if` for macOS)**

Create `PeerDrop/Core/Platform/PlatformGraphicsRenderer.swift`:

```swift
import Foundation
import CoreGraphics

/// Cross-platform image-context renderer. iOS wraps
/// `UIGraphicsImageRenderer` (scale = 1, opaque = false, deterministic
/// per Apple's docs); macOS uses an `NSGraphicsContext`-backed
/// `NSBitmapImageRep` with matching settings.
///
/// The output must be deterministic — the M4.3 caching contract in
/// PetRendererV3 (`docs/plans/2026-04-XX-pet-v4-impl.md`) depends on
/// byte-identical PNG bytes for identical drawing input.
public struct PlatformGraphicsRenderer {
    public let size: CGSize

    public init(size: CGSize) {
        self.size = size
    }

    public func image(drawing: (CGContext) -> Void) -> PlatformImage {
        #if canImport(UIKit)
        return UIKitGraphicsRenderer.render(size: size, drawing: drawing)
        #elseif canImport(AppKit)
        return AppKitGraphicsRenderer.render(size: size, drawing: drawing)
        #else
        // Compile-only branch
        return PlatformImage()
        #endif
    }
}

#if canImport(AppKit)
import AppKit

/// macOS implementation using NSBitmapImageRep. Matches UIGraphicsImageRenderer's
/// scale=1, opaque=false defaults.
enum AppKitGraphicsRenderer {
    static func render(size: CGSize, drawing: (CGContext) -> Void) -> PlatformImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawing(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
#endif
```

Then create the iOS adapter at `PeerDrop/Core/Platform/iOS/UIKitGraphicsRenderer.swift`:

```swift
#if canImport(UIKit)
import UIKit
import CoreGraphics

enum UIKitGraphicsRenderer {
    static func render(size: CGSize, drawing: (CGContext) -> Void) -> PlatformImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            drawing(ctx.cgContext)
        }
    }
}
#endif
```

- [ ] **Step 4: Re-run tests, expect PASS**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformGraphicsRendererTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/Platform/PlatformGraphicsRenderer.swift \
        PeerDrop/Core/Platform/iOS/UIKitGraphicsRenderer.swift \
        PeerDrop/Core/Platform/PlatformImage.swift \
        PeerDropTests/Core/Platform/PlatformGraphicsRendererTests.swift \
        PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): add PlatformGraphicsRenderer + platformCGImage (M1a)

Cross-platform wrapper around UIGraphicsImageRenderer / NSBitmapImageRep.
Deterministic output required by PetRendererV3 caching contract.

Plus PlatformImage.platformCGImage convenience getter (UIImage.cgImage
vs NSImage.cgImage(forProposedRect:context:hints:)).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Extend HapticFeedback with `evolutionTriggered()`

**Files:**
- Modify: `PeerDrop/Core/Platform/HapticFeedback.swift`
- Modify: `PeerDrop/Core/Platform/iOS/UIKitHapticFeedback.swift`
- Modify: `PeerDrop/Core/HapticManager.swift`
- Modify: `PeerDrop/Core/Platform/PlatformDependencies.swift` (NoOpHapticFeedback gains method)
- Modify: `PeerDropTests/Core/Platform/MockPlatformDependencies.swift` (MockHaptics gains method)

PetEngine calls `UIImpactFeedbackGenerator(style: .heavy).impactOccurred()` once at line 401 — when the pet evolves. Add a semantic method `evolutionTriggered()` to the protocol.

- [ ] **Step 1: Add `evolutionTriggered()` to the protocol**

Edit `PeerDrop/Core/Platform/HapticFeedback.swift`. Add `func evolutionTriggered()` at the end of the protocol body (alphabetical/semantic placement is fine; pick beside `callStarted`/`callEnded`):

```swift
public protocol HapticFeedback {
    func peerDiscovered()
    func connectionAccepted()
    func connectionRejected()
    func transferComplete()
    func transferFailed()
    func incomingRequest()
    func callStarted()
    func callEnded()
    func evolutionTriggered()    // ← NEW: heavy impact for pet evolution
    func tap()
}
```

- [ ] **Step 2: Implement in iOS adapter**

Edit `PeerDrop/Core/Platform/iOS/UIKitHapticFeedback.swift`. Add the new method:

```swift
final class UIKitHapticFeedback: HapticFeedback {
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    func peerDiscovered() { selection.selectionChanged() }
    func connectionAccepted() { notification.notificationOccurred(.success) }
    func connectionRejected() { notification.notificationOccurred(.error) }
    func transferComplete() { notification.notificationOccurred(.success) }
    func transferFailed() { notification.notificationOccurred(.warning) }
    func incomingRequest() { impact.impactOccurred() }
    func callStarted() { impact.impactOccurred() }
    func callEnded() { selection.selectionChanged() }
    func evolutionTriggered() { heavyImpact.impactOccurred() }
    func tap() { impact.impactOccurred(intensity: 0.5) }
}
```

(Cached generator instance, consistent with M0's f422921 perf fix.)

- [ ] **Step 3: Add to NoOpHapticFeedback in PlatformDependencies.swift**

Edit `PeerDrop/Core/Platform/PlatformDependencies.swift`. Find `private final class NoOpHapticFeedback: HapticFeedback` and add `func evolutionTriggered() {}` to it.

- [ ] **Step 4: Add to MockHaptics in tests**

Edit `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`. Find `final class MockHaptics: HapticFeedback` and add:

```swift
    func evolutionTriggered() { invocations.append("evolutionTriggered") }
```

- [ ] **Step 5: Add static facade in HapticManager**

Edit `PeerDrop/Core/HapticManager.swift`. Add the corresponding static method:

```swift
enum HapticManager {
    private static var feedback: HapticFeedback { PlatformDependencies.shared.haptics() }

    static func peerDiscovered() { feedback.peerDiscovered() }
    static func connectionAccepted() { feedback.connectionAccepted() }
    static func connectionRejected() { feedback.connectionRejected() }
    static func transferComplete() { feedback.transferComplete() }
    static func transferFailed() { feedback.transferFailed() }
    static func incomingRequest() { feedback.incomingRequest() }
    static func callStarted() { feedback.callStarted() }
    static func callEnded() { feedback.callEnded() }
    static func evolutionTriggered() { feedback.evolutionTriggered() }
    static func tap() { feedback.tap() }
}
```

- [ ] **Step 6: Add an injection test**

Edit `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`. Inside `HapticManagerInjectionTests`, add:

```swift
    func test_evolutionTriggeredForwardsToInjectedFeedback() {
        let originalDeps = PlatformDependencies.shared
        defer { PlatformDependencies.shared = originalDeps }

        let mock = MockHaptics()
        PlatformDependencies.shared = .mock(haptics: mock)

        HapticManager.evolutionTriggered()

        XCTAssertEqual(mock.invocations, ["evolutionTriggered"])
    }
```

- [ ] **Step 7: Build + test**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/HapticManagerInjectionTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **` (2 tests now: existing `test_tapForwardsToInjectedFeedback` + new one).

- [ ] **Step 8: Commit**

```bash
git add PeerDrop/Core/Platform PeerDrop/Core/HapticManager.swift PeerDropTests/Core/Platform
git commit -m "$(cat <<'EOF'
refactor(core): HapticFeedback gains evolutionTriggered (M1a)

PetEngine currently uses UIImpactFeedbackGenerator(style: .heavy)
directly for pet evolution. Adds semantic method to protocol so the
direct usage can be replaced (M1a Task 11).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Refactor SpriteSheetLoader (drop dead import)

**Files:**
- Modify: `PeerDrop/Pet/Renderer/SpriteSheetLoader.swift`

The file imports UIKit but actually uses only CoreGraphics. Trivial cleanup.

- [ ] **Step 1: Replace `import UIKit` with `import CoreGraphics`**

Edit line 1 of `PeerDrop/Pet/Renderer/SpriteSheetLoader.swift`:

```swift
// Before:
import UIKit

// After:
import CoreGraphics
```

(Verify no other UIKit type is used: `grep -n "UI[A-Z]" PeerDrop/Pet/Renderer/SpriteSheetLoader.swift` should be empty.)

- [ ] **Step 2: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add PeerDrop/Pet/Renderer/SpriteSheetLoader.swift
git commit -m "$(cat <<'EOF'
refactor(pet): SpriteSheetLoader drops dead UIKit import (M1a)

File never actually used any UIKit type — only CoreGraphics. Dead
import has been there since the file was created.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Refactor MoodOverlay (UIColor → PlatformColor)

**Files:**
- Modify: `PeerDrop/Pet/Renderer/MoodOverlay.swift`

- [ ] **Step 1: Replace UIKit import + return type**

Edit `PeerDrop/Pet/Renderer/MoodOverlay.swift`:

```swift
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Mood → SF Symbol icon + tint color mapping for the v4.0 mood overlay.
///
/// Replaces the per-mood PNG sprint that was originally planned for Q3 (c).
/// Validation 2026-04-29 showed PixelLab couldn't preserve character identity
/// across mood prompt variations (commit 23b3caf), so mood is now rendered as
/// an SF Symbol composited on top of the neutral PNG sprite by M4b.2.
///
/// Icon names locked per plan §M4b.1. Tint colors picked for visual distinct-
/// ness; happy uses warm yellow, sleepy cool blue, etc.
enum MoodOverlay {

    static func iconName(_ mood: PetMood) -> String {
        switch mood {
        case .happy:    return "face.smiling"
        case .curious:  return "questionmark.circle"
        case .sleepy:   return "moon.zzz"
        case .lonely:   return "cloud.rain"
        case .excited:  return "sparkles"
        case .startled: return "exclamationmark.triangle"
        }
    }

    static func tintColor(_ mood: PetMood) -> PlatformColor {
        switch mood {
        case .happy:    return .systemYellow
        case .curious:  return .systemTeal
        case .sleepy:   return .systemBlue
        case .lonely:   return .systemGray
        case .excited:  return .systemPink
        case .startled: return .systemRed
        }
    }
}
```

Why the explicit `#if canImport(UIKit) ... #elseif canImport(AppKit)` instead of just removing the import? Because `PlatformColor`'s static accessors like `.systemYellow` come from UIKit (`UIColor.systemYellow`) on iOS and AppKit (`NSColor.systemYellow`) on macOS. The file needs to import the framework that defines those static methods. The typealias `PlatformColor` itself routes through, but `.systemYellow` resolves via the imported framework.

- [ ] **Step 2: Verify no caller breaks**

```bash
grep -rn "MoodOverlay.tintColor" PeerDrop/ PeerDropTests/ 2>/dev/null
```

Each caller should accept the return type as `PlatformColor` (same as UIColor on iOS).

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`. (PetRendererV3 currently calls `MoodOverlay.tintColor(mood)` and passes the result to `withTintColor`. PetRendererV3 itself is updated in Task 10; for now the iOS typealias makes this still compile.)

- [ ] **Step 4: Commit**

```bash
git add PeerDrop/Pet/Renderer/MoodOverlay.swift
git commit -m "$(cat <<'EOF'
refactor(pet): MoodOverlay uses PlatformColor (M1a)

UIColor return type → PlatformColor. UIKit import gated to #if canImport(UIKit);
macOS branch imports AppKit so .systemYellow etc. resolve via NSColor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Refactor RarityOverlay (UIColor → PlatformColor)

**Files:**
- Modify: `PeerDrop/Pet/Renderer/RarityOverlay.swift`

Same intent as Task 6 (decouple UIColor return type) — full steps below.

- [ ] **Step 1: Read current file to inventory UIColor refs**

```bash
cat PeerDrop/Pet/Renderer/RarityOverlay.swift
grep -nE "UIColor|UIKit" PeerDrop/Pet/Renderer/RarityOverlay.swift
```

Based on inspection there are at least 2 sites: the `import UIKit` on line 2, and the `borderColor(for speciesID: SpeciesID) -> UIColor?` return type on line 21. There may also be `UIColor` literals inside the function body (e.g. `.systemSilver`, `.systemPurple` for rare/epic tiers); grep will show them.

- [ ] **Step 2: Apply the import gate + UIColor → PlatformColor substitution**

Edit `PeerDrop/Pet/Renderer/RarityOverlay.swift`:

```swift
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-variant collection-tier overlay (Phase V hook C — see
/// docs/plans/2026-05-17-variant-traits.md).
///
/// Pure code rendering — no PNG assets. Adds a colored border around the
/// sprite frame and (for epic+) an occasional sparkle particle. Reuses
/// `MoodOverlay`'s SF Symbol pattern where helpful.
enum RarityOverlay {

    static func borderColor(for speciesID: SpeciesID) -> PlatformColor? {
        // ... existing body — replace every UIColor reference with PlatformColor ...
        // The actual switch statement body depends on what the file currently
        // contains; copy it verbatim and substitute UIColor → PlatformColor.
    }

    // ... any other functions in the file, treated the same way ...
}
```

Concretely: after the import-gate change, use sed-like Edit operations to swap every `UIColor` with `PlatformColor`. `.systemSilver`, `.systemPurple`, `.systemRed` etc all exist on both UIColor and NSColor for macOS 11+. Preserve every other line as-is (function bodies, comments, doc comments, the enclosing `enum RarityOverlay { ... }`).

- [ ] **Step 3: Verify callers**

```bash
grep -rn "RarityOverlay.borderColor" PeerDrop/ PeerDropTests/ 2>/dev/null
```

Same caller story as MoodOverlay — typealias means no caller change needed.

- [ ] **Step 4: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Pet/Renderer/RarityOverlay.swift
git commit -m "$(cat <<'EOF'
refactor(pet): RarityOverlay uses PlatformColor (M1a)

Same treatment as MoodOverlay — UIColor → PlatformColor, UIKit import
gated to #if canImport(UIKit).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Refactor AccessoryOverlay (UIImage → PlatformImage)

**Files:**
- Modify: `PeerDrop/Pet/Renderer/AccessoryOverlay.swift`

- [ ] **Step 1: Apply the substitution**

Edit `PeerDrop/Pet/Renderer/AccessoryOverlay.swift`:

```swift
import Foundation
// PlatformImage typealias resolves to UIImage on iOS / NSImage on macOS.
// AppKit isn't imported here because AccessoryOverlay never uses NSImage-
// specific APIs beyond the typealiased PlatformImage; loading PNG bytes
// via Bundle is platform-neutral.
```

Replace the `import UIKit` line accordingly, then update the function signature:

```swift
    /// Loads an accessory PNG keyed by speciesID. Bundle path:
    /// `Accessories/<speciesID>.png`.
    static func image(for speciesID: SpeciesID, in bundle: Bundle = .main) -> PlatformImage? {
        // ... existing body but replace any UIImage(named:) or UIImage(data:)
        // with PlatformImage(named:) / PlatformImage(data:) ...
    }
```

Read the current body first to find any UIKit-specific code beyond the return type:

```bash
cat PeerDrop/Pet/Renderer/AccessoryOverlay.swift
```

If the body uses `UIImage(named:)` or `UIImage(data:)`, those substitutions work directly because `PlatformImage = UIImage` on iOS and `NSImage(named:)` / `NSImage(data:)` exist on macOS.

- [ ] **Step 2: Verify callers**

```bash
grep -rn "AccessoryOverlay.image" PeerDrop/ PeerDropTests/ 2>/dev/null
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add PeerDrop/Pet/Renderer/AccessoryOverlay.swift
git commit -m "$(cat <<'EOF'
refactor(pet): AccessoryOverlay uses PlatformImage (M1a)

UIImage? return type → PlatformImage?. Drops direct UIKit import;
PlatformImage typealias resolves automatically per platform.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Refactor PetRendererV3 (biggest change — uses 4 helpers from Tasks 1–3)

**Files:**
- Modify: `PeerDrop/Pet/Renderer/PetRendererV3.swift`

This is the most involved refactor. The `composite` method uses `UIGraphicsImageRendererFormat`, `UIGraphicsImageRenderer`, `UIImage(cgImage:).draw(in:)`, `UIImage(systemName:).withTintColor(...).draw(in:)`. All four get replaced by Tasks 1–3 helpers.

- [ ] **Step 1: Read the current `composite` method (lines ~175–230) to understand context**

```bash
sed -n '170,230p' PeerDrop/Pet/Renderer/PetRendererV3.swift
```

- [ ] **Step 2: Replace the `composite` method body**

Edit `PeerDrop/Pet/Renderer/PetRendererV3.swift`. Replace the function:

```swift
    private func composite(basePNG: CGImage, species: SpeciesID, mood: PetMood) -> CGImage {
        let size = CGSize(width: basePNG.width, height: basePNG.height)
        let renderer = PlatformGraphicsRenderer(size: size)

        let composited = renderer.image { cgCtx in
            // 1) Base sprite — draw the basePNG via CGContext directly.
            // CoreGraphics's coordinate system is bottom-left origin so we
            // flip the Y axis to match UIKit/AppKit top-left convention
            // before drawing, matching the prior UIImage(cgImage:).draw(in:)
            // behavior.
            cgCtx.saveGState()
            cgCtx.translateBy(x: 0, y: size.height)
            cgCtx.scaleBy(x: 1, y: -1)
            cgCtx.draw(basePNG, in: CGRect(origin: .zero, size: size))
            cgCtx.restoreGState()

            // 2) Rarity border draws BETWEEN the base sprite and the mood
            // overlay so it sits on the sprite edge but doesn't occlude
            // the mood icon at the top-right. Returns nil for .common
            // tier (no border).
            if let borderColor = RarityOverlay.borderColor(for: species) {
                let width = RarityOverlay.borderWidth(for: species)
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: width / 2, dy: width / 2)
                cgCtx.setStrokeColor(borderColor.cgColor)
                cgCtx.setLineWidth(width)
                cgCtx.stroke(rect)
            }

            // 3) Mood overlay — SF Symbol composited at top-right corner.
            let side = Self.overlaySidePixels(forBaseWidth: size.width)
            let iconRect = CGRect(
                x: size.width - side,
                y: 0,
                width: side,
                height: side
            )
            let iconName = MoodOverlay.iconName(mood)
            let tint = MoodOverlay.tintColor(mood)
            if let icon = PlatformImage(platformSystemName: iconName)?.platformWithTintColor(tint) {
                // Draw via PlatformImage's draw(in:) which respects the
                // current graphics context. UIImage.draw(in:) works on iOS;
                // NSImage.draw(in:) works on macOS — both honor the current
                // graphics context set by PlatformGraphicsRenderer.
                icon.draw(in: iconRect)
            }
        }

        if let cg = composited.platformCGImage {
            return cg
        }
        // PlatformGraphicsRenderer normally produces a CGImage-backed
        // PlatformImage. If it doesn't (some color-space edge cases), the
        // mood overlay vanishes silently — log so the issue is at least visible.
        rendererLogger.warning("PlatformGraphicsRenderer returned PlatformImage with nil cgImage; mood overlay dropped for mood=\(mood.rawValue, privacy: .public)")
        return basePNG
    }
```

- [ ] **Step 3: Drop `import UIKit` from line 3**

The file now has no UIKit usage. Change line 3:

```swift
// Before:
import UIKit

// After:
// (deleted — file is now cross-platform via Core/Platform/ helpers)
```

(Or, more conservatively, replace with `import Foundation` if not already imported. It is — line 1.)

Note: `PlatformImage.draw(in:)` — this method exists on both UIImage and NSImage natively (NSImage has `draw(in: NSRect)`, UIImage has `draw(in: CGRect)` — `CGRect == NSRect` typedef on Apple platforms). So `icon.draw(in: iconRect)` compiles on both platforms without a wrapper.

- [ ] **Step 4: Verify no UIKit reference remains**

```bash
grep -nE "UI[A-Z][a-zA-Z]+" PeerDrop/Pet/Renderer/PetRendererV3.swift
```

Expected: empty (or only matches in comments/docstrings).

- [ ] **Step 5: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run pet-related tests to verify the rendering is still correct**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PetRendererV3Tests \
  -only-testing:PeerDropTests/PetGenomeSpeciesTests \
  -quiet 2>&1 | tail -10
```

Expected: PetRendererV3Tests all PASS; PetGenomeSpeciesTests has a pre-existing failure (`test_resolvedSpeciesID_seed_picksDeterministically`) inherited from M0 baseline — confirm it's the same failure, not a new one. The renderer-specific tests should be green.

- [ ] **Step 7: Commit**

```bash
git add PeerDrop/Pet/Renderer/PetRendererV3.swift
git commit -m "$(cat <<'EOF'
refactor(pet): PetRendererV3 uses PlatformGraphicsRenderer (M1a)

composite() rewritten to use PlatformGraphicsRenderer with direct
CGContext drawing (CG bottom-left flip applied), PlatformImage(systemName:)
+ platformWithTintColor for SF Symbol mood overlay, and platformCGImage
accessor for extracting the final CGImage.

Drops direct UIKit import. PetRendererTests still pass — deterministic
output preserved (PlatformGraphicsRenderer documents this as a contract).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Refactor PetEngine (replace UIImpactFeedbackGenerator)

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`

- [ ] **Step 1: Find and replace line ~401**

Edit `PeerDrop/Pet/Engine/PetEngine.swift`. Find:

```swift
        showEvolutionFlash = true
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
```

Replace with:

```swift
        showEvolutionFlash = true
        HapticManager.evolutionTriggered()
```

- [ ] **Step 2: Check whether `import UIKit` can be dropped**

```bash
grep -nE "UI[A-Z][a-zA-Z]+" PeerDrop/Pet/Engine/PetEngine.swift
```

If the only remaining matches are inside comments or docstrings, drop the `import UIKit` (line 5) and replace with `import Foundation` if not already present.

If there are other UIKit uses, leave `import UIKit` but gate it with `#if os(iOS)` (matching M0's approach for ConnectionManager).

Read the surrounding context for each remaining match and decide.

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run PetEngine-related tests**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PetEngineTests \
  -only-testing:PeerDropTests/PetEngineSharedRenderedPetTests \
  -only-testing:PeerDropTests/PetEngineActionSelectionTests \
  -quiet 2>&1 | tail -10
```

Expected: PASS (any pre-existing failures from the M0 baseline unchanged).

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift
git commit -m "$(cat <<'EOF'
refactor(pet): PetEngine evolution uses HapticManager (M1a)

Direct UIImpactFeedbackGenerator(style: .heavy) replaced with
HapticManager.evolutionTriggered() (M1a Task 4 added the method).
UIKit import dropped if no other UIKit usage remained.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Verify Pet/ is UIKit-clean (verification + final commit)

**Files:**
- (verification only; possibly Modify: `.github/workflows/ci.yml` to scan Pet/ too)

- [ ] **Step 1: Scan for any remaining UIKit imports in Pet/ (excluding Pet/UI/)**

```bash
grep -rn "^import UIKit" PeerDrop/Pet/ | grep -v "/UI/"
```

Expected: empty output. If anything appears, it means a file was missed in Tasks 5–10. Fix that file and re-commit.

- [ ] **Step 2: Scan for unguarded UIKit type usage in Pet/ (excluding Pet/UI/)**

```bash
grep -rn "UIImage\|UIColor\|UIGraphicsImageRenderer\|UIImpactFeedback" PeerDrop/Pet/ | grep -v "/UI/" | grep -v "^//"
```

Expected: only the `PlatformImage`/`PlatformColor` typealiases (NOT raw `UIImage`/`UIColor`). If anything else appears, investigate.

- [ ] **Step 3: Extend `.github/workflows/ci.yml` to also scan `PeerDrop/Pet/` non-UI files**

Edit `.github/workflows/ci.yml`. The current `find` command is:

```yaml
done < <(find PeerDrop/Core -name "*.swift" -not -path "*/Platform/iOS/*")
```

Change to:

```yaml
done < <(find PeerDrop/Core PeerDrop/Pet -name "*.swift" -not -path "*/Platform/iOS/*" -not -path "*/Pet/UI/*")
```

The `-not -path "*/Pet/UI/*"` exempts the SwiftUI views in `Pet/UI/` which legitimately import UIKit + SwiftUI for view-layer code.

- [ ] **Step 4: Run the lint script locally to confirm "Clean."**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"

violations=""
while IFS= read -r file; do
  if grep -E "^import (UIKit|AppKit|WidgetKit)" "$file" > /dev/null 2>&1; then
    while IFS= read -r line_no; do
      prev_line=$((line_no - 1))
      prev=$(sed -n "${prev_line}p" "$file" | tr -d '[:space:]')
      if [ "$prev" != "#ifos(iOS)" ] && \
         [ "$prev" != "#ifcanImport(UIKit)" ] && \
         [ "$prev" != "#ifcanImport(AppKit)" ] && \
         [ "$prev" != "#ifcanImport(WidgetKit)" ] && \
         [ "$prev" != "#elseifcanImport(UIKit)" ] && \
         [ "$prev" != "#elseifcanImport(AppKit)" ] && \
         [ "$prev" != "#elseifcanImport(WidgetKit)" ] && \
         [ "$prev" != "#elseifos(iOS)" ]; then
        violations+="$file:$line_no\n"
      fi
    done < <(grep -n -E "^import (UIKit|AppKit|WidgetKit)" "$file" | cut -d: -f1)
  fi
done < <(find PeerDrop/Core PeerDrop/Pet -name "*.swift" -not -path "*/Platform/iOS/*" -not -path "*/Pet/UI/*")
if [ -n "$violations" ]; then
  printf "Violations:\n%b" "$violations"
else
  echo "Clean."
fi
```

Expected: `Clean.`

- [ ] **Step 5: Run full test suite to verify no regressions**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1a-final-tests.log | tail -10
```

Expected: same baseline as M0 — 12 pre-existing failures (verified to also fail on M0 HEAD `a3f6ba1`), 0 new failures.

- [ ] **Step 6: Commit the CI update (if any) + tag**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci: extend lint-imports to scan PeerDrop/Pet/ non-UI files (M1a)

After M1a's Pet UIKit decoupling, the same anti-UIKit rule applies
to Pet/Renderer + Pet/Engine + Pet/Model etc. Pet/UI/ remains
exempt (SwiftUI views legitimately import UIKit/SwiftUI).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"

git tag -a m1a-pet-uikit-decoupled -m "M1a done: Pet/ UIKit dependency removed (5 Renderer + 1 Engine files)"
```

- [ ] **Step 7: Push to feature branch + open PR**

```bash
git push -u origin feat/m1a-pet-uikit-decoupling
gh pr create --title "M1a: Pet UIKit decoupling (macOS port M1.1)" --body "$(cat <<'EOF'
## Summary

Second milestone of the macOS port (v6.0). Decouples Pet/Renderer (5 files) + Pet/Engine (1 file) from direct UIKit dependencies. Builds on M0's `PlatformImage`/`PlatformColor` typealiases by adding three new helpers and one new abstraction:

- `PlatformImage.init(platformCGImage:size:)`, `init(platformSystemName:)`, `platformWithTintColor(_:)`, `platformCGImage`
- `PlatformGraphicsRenderer` (cross-platform `UIGraphicsImageRenderer` / `NSBitmapImageRep` wrapper, deterministic output)
- `HapticFeedback.evolutionTriggered()` for PetEngine's pet-evolution heavy haptic

iOS behaviour byte-for-byte preserved. lint-imports CI job extended to scan `PeerDrop/Pet/` (excluding `Pet/UI/`).

## Plan & spec

- Spec: [`docs/superpowers/specs/2026-05-24-macos-port-design.md`](docs/superpowers/specs/2026-05-24-macos-port-design.md) §7 M1a
- Plan: [`docs/superpowers/plans/2026-05-25-m1a-pet-uikit-decoupling.md`](docs/superpowers/plans/2026-05-25-m1a-pet-uikit-decoupling.md)

## Test plan

- [x] xcodebuild build succeeds on iPhone 16 simulator
- [x] Full test suite: 0 new regressions; 12 pre-existing failures (M0 baseline) unchanged
- [x] `grep -rn "^import UIKit" PeerDrop/Pet/ | grep -v "/UI/"` → empty
- [x] `lint-imports` script (with M1a's extension to scan Pet/) reports `Clean.`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

(Or use plain `git push` and create the PR manually — your call.)

---

## Done

M1a complete. Pet/ has gone from 6 unguarded UIKit imports to 0 (plus the dead-import drop in SpriteSheetLoader). PetRendererV3 uses PlatformGraphicsRenderer with deterministic output guaranteed. PetEngine uses the HapticManager facade.

**Next:** M1b plan (Voice cleanup — extract CallKit-specific code from VoiceCallManager) by re-invoking `superpowers:writing-plans`.

## Open Items for M1b / M1c / M1d

Tracked but deferred:
1. **M1b** — Split Voice/ into CallKit-specific (stays in iOS app target) + cross-platform transport pieces (WebRTC, SDP, recorder, player)
2. **M1c** — Create `PeerDropKit/Package.swift` with 5 empty product modules + dependency graph
3. **M1d** — Migrate ~90 files into modules, update `project.yml`, move Pet/ resources into SPM bundle
