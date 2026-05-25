# M0 — Core UIKit Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove direct UIKit imports from 9 files in `PeerDrop/Core/` by introducing platform-abstraction protocols, typealiases, and `#if os(iOS)` gates — without changing any iOS-shipping behaviour. Sets the stage for M1's SPM package split.

**Architecture:** Introduce a new `PeerDrop/Core/Platform/` directory containing 5 protocols + 1 typealias. iOS implementations live in `PeerDrop/Core/Platform/iOS/`. Mock implementations live in `PeerDropTests/Core/Platform/`. Each consumer in Core/ takes its dependency via init injection with a default closure that returns the iOS adapter — keeping call sites unchanged while enabling test substitution.

**Tech Stack:** Swift 5.9, iOS 16+, XCTest. Builds: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`. Tests: same command with `test`.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §3.

**Reality check vs spec:** Spec listed 9 abstractions; actual code analysis shows only 5 protocols + 1 typealias are needed. Specifically:
- `PeerIdentity.swift` uses only `UIDevice.current.name`, not `identifierForVendor` — no `DeviceFingerprintProvider` needed
- `ArchiveManager.swift` uses only `UIDevice.current.name`, not `UIImage` — no `PlatformImage.jpegData` extension needed for it
- `AppLifecycleObserver` is unnecessary — `@Environment(\.scenePhase)` is already cross-platform SwiftUI

`DeviceFingerprintProvider` is deferred to M3 (only needed once Mac actually needs a device fingerprint for the Worker `platform` field).

---

## File Structure

**New files (12):**
- `PeerDrop/Core/Platform/PlatformImage.swift` — typealias + cross-platform helpers
- `PeerDrop/Core/Platform/PlatformPasteboard.swift` — protocol
- `PeerDrop/Core/Platform/HapticFeedback.swift` — protocol
- `PeerDrop/Core/Platform/DeviceNameProvider.swift` — protocol
- `PeerDrop/Core/Platform/SystemInfoProvider.swift` — protocol
- `PeerDrop/Core/Platform/RemoteNotificationRegistering.swift` — protocol
- `PeerDrop/Core/Platform/iOS/UIKitPasteboard.swift` — iOS impl
- `PeerDrop/Core/Platform/iOS/UIKitHapticFeedback.swift` — iOS impl
- `PeerDrop/Core/Platform/iOS/UIKitDeviceNameProvider.swift` — iOS impl
- `PeerDrop/Core/Platform/iOS/UIKitSystemInfoProvider.swift` — iOS impl
- `PeerDrop/Core/Platform/iOS/UIKitRemoteNotificationRegistering.swift` — iOS impl
- `PeerDropTests/Core/Platform/MockPlatformDependencies.swift` — mocks for all 5 protocols

**Modified files (10):**
- `PeerDrop/Core/ImageCache.swift`
- `PeerDrop/Core/ClipboardSyncManager.swift`
- `PeerDrop/Core/HapticManager.swift`
- `PeerDrop/Core/UserProfile.swift`
- `PeerDrop/Core/ArchiveManager.swift`
- `PeerDrop/Core/ErrorReporter.swift`
- `PeerDrop/Core/ConnectionManager.swift`
- `PeerDrop/Core/PeerIdentity.swift`
- `PeerDrop/Core/PushNotificationManager.swift`
- `PeerDrop/App/PeerDropApp.swift` — wire real implementations
- `.github/workflows/ci.yml` (or equivalent, create if missing) — `lint-imports` warn-only job

**Note on injection style:** All consumers in Core/ currently use top-level static singletons (`HapticManager.tap()`, `ImageCache.shared`, `enum ErrorReporter`). To minimise churn at call sites, we add a process-wide injection point: `PlatformDependencies.shared` (a struct with all 5 dependencies, defaulting to iOS implementations). Consumers read from `PlatformDependencies.shared.deviceName()` etc. Tests substitute via `PlatformDependencies.shared = .mock(...)` in `setUp`. This pattern matches the existing `ChatDataEncryptor.shared` style.

---

## Task 1: Create Platform/ directory + PlatformDependencies registry

**Files:**
- Create: `PeerDrop/Core/Platform/PlatformDependencies.swift`
- Test: `PeerDropTests/Core/Platform/PlatformDependenciesTests.swift`

- [ ] **Step 1: Create `PlatformDependencies.swift` with empty registry**

```swift
// PeerDrop/Core/Platform/PlatformDependencies.swift
import Foundation

/// Process-wide injection point for platform-specific dependencies. iOS
/// implementations are wired in `PeerDropApp` at launch; tests substitute mocks
/// in `setUp`. Each property is added incrementally as M0 introduces the
/// corresponding protocol (see docs/superpowers/plans/2026-05-25-m0-core-uikit-decoupling.md).
public struct PlatformDependencies {
    // Properties added in subsequent tasks. Empty for now so the file
    // compiles standalone.

    public init() {}

    /// Mutable singleton. App startup replaces this with iOS-wired
    /// implementations; tests replace with mocks.
    public static var shared = PlatformDependencies()
}
```

- [ ] **Step 2: Create test stub to verify shared is mutable**

```swift
// PeerDropTests/Core/Platform/PlatformDependenciesTests.swift
import XCTest
@testable import PeerDrop

final class PlatformDependenciesTests: XCTestCase {
    func test_sharedIsMutable() {
        let original = PlatformDependencies.shared
        defer { PlatformDependencies.shared = original }

        PlatformDependencies.shared = PlatformDependencies()
        XCTAssertNotNil(PlatformDependencies.shared)
    }
}
```

- [ ] **Step 3: Generate Xcode project to pick up new files**

```bash
xcodegen generate
```

Expected: `Generated project successfully` (no errors).

- [ ] **Step 4: Build and run test**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformDependenciesTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/Platform PeerDropTests/Core/Platform PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): introduce PlatformDependencies registry (M0)

Empty registry placeholder. Subsequent commits add one protocol per file
under Core/Platform/ and migrate each Core consumer to read its
platform-specific dependency from PlatformDependencies.shared.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: PlatformImage typealias

**Files:**
- Create: `PeerDrop/Core/Platform/PlatformImage.swift`
- Test: `PeerDropTests/Core/Platform/PlatformImageTests.swift`

`PlatformImage` is a typealias — no protocol, no PlatformDependencies entry needed. iOS = `UIImage`, macOS = `NSImage` (macOS branch added in M2 but the typealias compiles today on iOS already).

- [ ] **Step 1: Write failing test**

```swift
// PeerDropTests/Core/Platform/PlatformImageTests.swift
import XCTest
@testable import PeerDrop

final class PlatformImageTests: XCTestCase {
    func test_typealiasResolvesToUIImageOnIOS() {
        let image: PlatformImage = PlatformImage()
        XCTAssertTrue(type(of: image) == PlatformImage.self)
    }

    func test_jpegDataExtensionReturnsData() {
        // 1x1 pixel red image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image: PlatformImage = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let data = image.platformJPEGData(compressionQuality: 0.8)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }
}
```

- [ ] **Step 2: Run test, expect FAIL with "Cannot find type 'PlatformImage'"**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformImageTests -quiet
```

Expected: build failure (type not found).

- [ ] **Step 3: Create `PlatformImage.swift`**

```swift
// PeerDrop/Core/Platform/PlatformImage.swift
import Foundation
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif

extension PlatformImage {
    /// Cross-platform JPEG encoder. iOS forwards to `jpegData(compressionQuality:)`;
    /// macOS implementation lives in PeerDropApp-macOS (M2).
    func platformJPEGData(compressionQuality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return self.jpegData(compressionQuality: compressionQuality)
        #elseif canImport(AppKit)
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #endif
    }
}
```

- [ ] **Step 4: Re-run test**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformImageTests -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/Platform/PlatformImage.swift PeerDropTests/Core/Platform/PlatformImageTests.swift PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): add PlatformImage typealias (M0)

UIKit/AppKit typealias with platformJPEGData() helper. macOS branch
compiles today but is not exercised until M2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Refactor ImageCache to use PlatformImage

**Files:**
- Modify: `PeerDrop/Core/ImageCache.swift`

- [ ] **Step 1: Replace UIKit import + all UIImage references**

Open `PeerDrop/Core/ImageCache.swift` and replace the entire file:

```swift
// PeerDrop/Core/ImageCache.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ImageCache")

final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    func image(forKey key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: PlatformImage, forKey key: String) {
        let cost = image.platformJPEGData(compressionQuality: 1.0)?.count ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
        logger.debug("Image cache cleared")
    }
}
```

- [ ] **Step 2: Find all call sites passing UIImage to ImageCache and verify they still compile**

```bash
grep -rn "ImageCache.shared.setImage\|ImageCache.shared.image" PeerDrop/ | head
```

Expected output: list of call sites — since iOS `PlatformImage = UIImage`, all existing call sites compile unchanged.

- [ ] **Step 3: Full build to verify no regressions**

```bash
xcodebuild build \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run existing ImageCache-related tests if any**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests -quiet 2>&1 | grep -E "FAIL|PASS" | tail
```

Expected: any ImageCache-related tests still pass.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/ImageCache.swift
git commit -m "$(cat <<'EOF'
refactor(core): ImageCache uses PlatformImage (M0)

Drops direct UIKit import. iOS behaviour unchanged because
PlatformImage = UIImage on iOS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: PlatformPasteboard protocol + iOS impl + ClipboardSyncManager refactor

**Files:**
- Create: `PeerDrop/Core/Platform/PlatformPasteboard.swift`
- Create: `PeerDrop/Core/Platform/iOS/UIKitPasteboard.swift`
- Modify: `PeerDrop/Core/Platform/PlatformDependencies.swift`
- Modify: `PeerDrop/Core/ClipboardSyncManager.swift`
- Test: `PeerDropTests/Core/Platform/MockPlatformDependencies.swift` (create)

- [ ] **Step 1: Define protocol**

```swift
// PeerDrop/Core/Platform/PlatformPasteboard.swift
import Foundation

/// Cross-platform pasteboard abstraction.
///
/// iOS implementation wraps `UIPasteboard.general`; macOS implementation
/// (M2) wraps `NSPasteboard.general`. Both platforms expose change-count
/// semantics that ClipboardSyncManager polls every 2 seconds.
public protocol PlatformPasteboard: AnyObject {
    /// Monotonically increasing counter; bumped by the system whenever
    /// pasteboard contents change.
    var changeCount: Int { get }

    /// Current string content if any.
    var stringContent: String? { get set }

    /// Current image content if any.
    var imageContent: PlatformImage? { get set }

    /// Notification name posted when pasteboard changes (iOS: UIPasteboard.changedNotification;
    /// macOS: synthesised via the 2s poll).
    var changedNotificationName: Notification.Name { get }
}
```

- [ ] **Step 2: Implement iOS adapter**

```swift
// PeerDrop/Core/Platform/iOS/UIKitPasteboard.swift
#if canImport(UIKit)
import UIKit

final class UIKitPasteboard: PlatformPasteboard {
    private let pasteboard = UIPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    var stringContent: String? {
        get { pasteboard.string }
        set { pasteboard.string = newValue }
    }

    var imageContent: PlatformImage? {
        get { pasteboard.image }
        set { pasteboard.image = newValue }
    }

    var changedNotificationName: Notification.Name { UIPasteboard.changedNotification }
}
#endif
```

- [ ] **Step 3: Add to PlatformDependencies**

Edit `PeerDrop/Core/Platform/PlatformDependencies.swift`, replace contents:

```swift
import Foundation

public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard

    public init(
        pasteboard: @escaping () -> PlatformPasteboard = { Self.defaultPasteboard }
    ) {
        self.pasteboard = pasteboard
    }

    public static var shared = PlatformDependencies()

    // Default factories — iOS adapter on iOS, falls back to a no-op on
    // other platforms until M2 wires AppKit adapters.
    #if canImport(UIKit)
    private static let defaultPasteboard: PlatformPasteboard = UIKitPasteboard()
    #else
    private static let defaultPasteboard: PlatformPasteboard = NoOpPasteboard()
    #endif
}

#if !canImport(UIKit)
private final class NoOpPasteboard: PlatformPasteboard {
    var changeCount: Int { 0 }
    var stringContent: String? { get { nil } set { } }
    var imageContent: PlatformImage? { get { nil } set { } }
    var changedNotificationName: Notification.Name { Notification.Name("NoOpPasteboardChanged") }
}
#endif
```

- [ ] **Step 4: Create mock**

```swift
// PeerDropTests/Core/Platform/MockPlatformDependencies.swift
import Foundation
@testable import PeerDrop

final class MockPasteboard: PlatformPasteboard {
    var changeCount: Int = 0
    var stringContent: String?
    var imageContent: PlatformImage?
    let changedNotificationName: Notification.Name = Notification.Name("MockPasteboardChanged")

    func simulateChange(string: String? = nil, image: PlatformImage? = nil) {
        changeCount += 1
        if let string { stringContent = string }
        if let image { imageContent = image }
        NotificationCenter.default.post(name: changedNotificationName, object: nil)
    }
}

extension PlatformDependencies {
    /// Convenience factory for tests. Returns a registry with all-mock factories.
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard()
    ) -> PlatformDependencies {
        PlatformDependencies(pasteboard: { pasteboard })
    }
}
```

- [ ] **Step 5: Refactor ClipboardSyncManager**

Edit `PeerDrop/Core/ClipboardSyncManager.swift`. Replace the entire file (changes: drop `import UIKit`, accept pasteboard in init, read changeCount/notificationName from injected pasteboard, drop direct `UIPasteboard` references):

```swift
import Foundation
import Combine
import os.log

@MainActor
final class ClipboardSyncManager: ObservableObject {
    @Published private(set) var lastSyncedContent: String?
    @Published var pendingClipboardContent: ClipboardSyncPayload?

    private let pasteboard: PlatformPasteboard
    private var changeCount: Int
    private var pollTimer: Timer?
    private let maxImageSize: Int = 1_024_000 // 1MB
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ClipboardSync")

    var onClipboardChanged: ((ClipboardSyncPayload) -> Void)?

    init(pasteboard: PlatformPasteboard = PlatformDependencies.shared.pasteboard()) {
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount
    }

    func startMonitoring() {
        guard FeatureSettings.isClipboardSyncEnabled else { return }
        stopMonitoring()

        changeCount = pasteboard.changeCount

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardChanged),
            name: pasteboard.changedNotificationName,
            object: nil
        )

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboardChange()
            }
        }

        logger.info("Clipboard sync monitoring started")
    }

    func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: pasteboard.changedNotificationName, object: nil)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pasteboardChanged() {
        Task { @MainActor in
            checkPasteboardChange()
        }
    }

    private func checkPasteboardChange() {
        let currentCount = pasteboard.changeCount
        guard currentCount != changeCount else { return }
        changeCount = currentCount

        guard FeatureSettings.isClipboardSyncEnabled else { return }

        if let payload = buildPayload() {
            pendingClipboardContent = payload
            onClipboardChanged?(payload)
        }
    }

    private func buildPayload() -> ClipboardSyncPayload? {
        if let string = pasteboard.stringContent, !string.isEmpty {
            if let url = URL(string: string), url.scheme != nil {
                return ClipboardSyncPayload(contentType: .url, textContent: string)
            }
            return ClipboardSyncPayload(contentType: .text, textContent: string)
        }

        if let image = pasteboard.imageContent,
           let data = image.platformJPEGData(compressionQuality: 0.7) {
            if data.count <= maxImageSize {
                return ClipboardSyncPayload(contentType: .image, imageData: data)
            } else {
                if let compressed = image.platformJPEGData(compressionQuality: 0.3),
                   compressed.count <= maxImageSize {
                    return ClipboardSyncPayload(contentType: .image, imageData: compressed)
                }
                logger.warning("Clipboard image too large to sync (\(data.count) bytes)")
            }
        }

        return nil
    }

    func applyReceivedClipboard(_ payload: ClipboardSyncPayload) {
        switch payload.contentType {
        case .text, .url:
            if let text = payload.textContent {
                pasteboard.stringContent = text
                lastSyncedContent = text
                changeCount = pasteboard.changeCount
            }
        case .image:
            if let data = payload.imageData, let image = PlatformImage(data: data) {
                pasteboard.imageContent = image
                lastSyncedContent = "[\(NSLocalizedString("Image", comment: ""))]"
                changeCount = pasteboard.changeCount
            }
        }
    }

    func clearPending() {
        pendingClipboardContent = nil
    }

    deinit {
        pollTimer?.invalidate()
    }
}
```

- [ ] **Step 6: Write integration test for the refactor**

Append to `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`:

```swift
// (additional tests at bottom of same file is fine; or create a new file)
import XCTest

@MainActor
final class ClipboardSyncManagerInjectionTests: XCTestCase {
    func test_buildPayload_readsFromInjectedPasteboard() {
        let mock = MockPasteboard()
        mock.stringContent = "https://example.com/test"
        let manager = ClipboardSyncManager(pasteboard: mock)

        var received: ClipboardSyncPayload?
        manager.onClipboardChanged = { received = $0 }
        manager.startMonitoring()
        defer { manager.stopMonitoring() }

        mock.simulateChange(string: "https://example.com/test")

        // Allow the @objc selector + Task @MainActor to run
        let exp = expectation(description: "payload arrives")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(received?.contentType, .url)
        XCTAssertEqual(received?.textContent, "https://example.com/test")
    }
}
```

- [ ] **Step 7: Generate project + run all new + existing clipboard tests**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/ClipboardSyncManagerInjectionTests -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add PeerDrop/Core/Platform PeerDrop/Core/ClipboardSyncManager.swift PeerDropTests/Core/Platform PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): ClipboardSyncManager uses PlatformPasteboard (M0)

- PlatformPasteboard protocol + UIKitPasteboard adapter
- PlatformDependencies registry gains pasteboard factory
- MockPasteboard for tests
- ClipboardSyncManager takes pasteboard via init injection

iOS behaviour unchanged. macOS branch deferred to M2 (NoOpPasteboard
fallback compiles cleanly).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: HapticFeedback protocol + iOS impl + HapticManager refactor

**Files:**
- Create: `PeerDrop/Core/Platform/HapticFeedback.swift`
- Create: `PeerDrop/Core/Platform/iOS/UIKitHapticFeedback.swift`
- Modify: `PeerDrop/Core/Platform/PlatformDependencies.swift`
- Modify: `PeerDrop/Core/HapticManager.swift`
- Modify: `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`

- [ ] **Step 1: Define protocol**

```swift
// PeerDrop/Core/Platform/HapticFeedback.swift
import Foundation

/// Cross-platform haptic feedback abstraction. Method names match the
/// 9 semantic call sites in HapticManager rather than UIKit's generator
/// types — keeps macOS no-op trivially simple and iOS impl mechanical.
public protocol HapticFeedback {
    func peerDiscovered()
    func connectionAccepted()
    func connectionRejected()
    func transferComplete()
    func transferFailed()
    func incomingRequest()
    func callStarted()
    func callEnded()
    func tap()
}
```

- [ ] **Step 2: iOS adapter**

```swift
// PeerDrop/Core/Platform/iOS/UIKitHapticFeedback.swift
#if canImport(UIKit)
import UIKit

final class UIKitHapticFeedback: HapticFeedback {
    private let impact = UIImpactFeedbackGenerator(style: .medium)
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
    func tap() { impact.impactOccurred(intensity: 0.5) }
}
#endif
```

- [ ] **Step 3: Add to PlatformDependencies**

Edit `PeerDrop/Core/Platform/PlatformDependencies.swift`. Add new `haptics` factory parameter parallel to `pasteboard`:

```swift
public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard
    public var haptics: () -> HapticFeedback

    public init(
        pasteboard: @escaping () -> PlatformPasteboard = { Self.defaultPasteboard },
        haptics: @escaping () -> HapticFeedback = { Self.defaultHaptics }
    ) {
        self.pasteboard = pasteboard
        self.haptics = haptics
    }

    public static var shared = PlatformDependencies()

    #if canImport(UIKit)
    private static let defaultPasteboard: PlatformPasteboard = UIKitPasteboard()
    private static let defaultHaptics: HapticFeedback = UIKitHapticFeedback()
    #else
    private static let defaultPasteboard: PlatformPasteboard = NoOpPasteboard()
    private static let defaultHaptics: HapticFeedback = NoOpHapticFeedback()
    #endif
}

#if !canImport(UIKit)
private final class NoOpPasteboard: PlatformPasteboard {
    var changeCount: Int { 0 }
    var stringContent: String? { get { nil } set { } }
    var imageContent: PlatformImage? { get { nil } set { } }
    var changedNotificationName: Notification.Name { Notification.Name("NoOpPasteboardChanged") }
}

private final class NoOpHapticFeedback: HapticFeedback {
    func peerDiscovered() {}
    func connectionAccepted() {}
    func connectionRejected() {}
    func transferComplete() {}
    func transferFailed() {}
    func incomingRequest() {}
    func callStarted() {}
    func callEnded() {}
    func tap() {}
}
#endif
```

- [ ] **Step 4: Refactor HapticManager**

Replace `PeerDrop/Core/HapticManager.swift`:

```swift
import Foundation

/// Centralized haptic feedback for key app events.
///
/// Static facade preserved for call-site compatibility; the actual
/// implementation comes from `PlatformDependencies.shared.haptics()`.
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
    static func tap() { feedback.tap() }
}
```

- [ ] **Step 5: Extend MockPlatformDependencies with MockHaptics**

Append to `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`:

```swift
final class MockHaptics: HapticFeedback {
    private(set) var invocations: [String] = []

    func peerDiscovered() { invocations.append("peerDiscovered") }
    func connectionAccepted() { invocations.append("connectionAccepted") }
    func connectionRejected() { invocations.append("connectionRejected") }
    func transferComplete() { invocations.append("transferComplete") }
    func transferFailed() { invocations.append("transferFailed") }
    func incomingRequest() { invocations.append("incomingRequest") }
    func callStarted() { invocations.append("callStarted") }
    func callEnded() { invocations.append("callEnded") }
    func tap() { invocations.append("tap") }
}
```

And update the `mock(...)` helper signature:

```swift
extension PlatformDependencies {
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard(),
        haptics: MockHaptics = MockHaptics()
    ) -> PlatformDependencies {
        PlatformDependencies(
            pasteboard: { pasteboard },
            haptics: { haptics }
        )
    }
}
```

- [ ] **Step 6: Add HapticManager injection test**

Append to the same file (or create a new file):

```swift
@MainActor
final class HapticManagerInjectionTests: XCTestCase {
    func test_tapForwardsToInjectedFeedback() {
        let originalDeps = PlatformDependencies.shared
        defer { PlatformDependencies.shared = originalDeps }

        let mock = MockHaptics()
        PlatformDependencies.shared = .mock(haptics: mock)

        HapticManager.tap()
        HapticManager.transferComplete()

        XCTAssertEqual(mock.invocations, ["tap", "transferComplete"])
    }
}
```

- [ ] **Step 7: Build + test**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/HapticManagerInjectionTests -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add PeerDrop/Core/Platform PeerDrop/Core/HapticManager.swift PeerDropTests/Core/Platform PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): HapticManager uses HapticFeedback protocol (M0)

Static facade preserved at call sites (HapticManager.tap()); real
implementation injected via PlatformDependencies.shared.haptics().

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: DeviceNameProvider protocol + iOS impl + 4 consumers

**Files:**
- Create: `PeerDrop/Core/Platform/DeviceNameProvider.swift`
- Create: `PeerDrop/Core/Platform/iOS/UIKitDeviceNameProvider.swift`
- Modify: `PeerDrop/Core/Platform/PlatformDependencies.swift`
- Modify: `PeerDrop/Core/UserProfile.swift`
- Modify: `PeerDrop/Core/PeerIdentity.swift` line 65
- Modify: `PeerDrop/Core/ArchiveManager.swift` line 28
- Modify: `PeerDrop/Core/ConnectionManager.swift` line 2422
- Modify: `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`

This task touches 4 consumers in one commit because they all share the same trivial substitution (`UIDevice.current.name` → `PlatformDependencies.shared.deviceName().currentName`).

- [ ] **Step 1: Define protocol (@MainActor required because iOS UIDevice.current is MainActor-isolated)**

```swift
// PeerDrop/Core/Platform/DeviceNameProvider.swift
import Foundation

/// Returns the user-visible device name (iOS: "Hanfour's iPhone"; macOS:
/// "Hanfour's Mac mini" via Host.current().localizedName).
///
/// MainActor-isolated because the iOS adapter reads UIDevice.current which
/// is MainActor-bound in Swift 6. Call sites that are nonisolated/async
/// must wrap reads in `MainActor.run { ... }` (ConnectionManager line 2422
/// already does this).
public protocol DeviceNameProvider {
    @MainActor
    var currentName: String { get }
}
```

- [ ] **Step 2: iOS adapter**

```swift
// PeerDrop/Core/Platform/iOS/UIKitDeviceNameProvider.swift
#if canImport(UIKit)
import UIKit

final class UIKitDeviceNameProvider: DeviceNameProvider {
    @MainActor
    var currentName: String { UIDevice.current.name }
}
#endif
```

Note on entitlements: iOS 16+ requires `com.apple.developer.device-information.user-assigned-device-name` for `UIDevice.current.name` to return the actual user-set name; without it the system returns a generic "iPhone". The existing code already runs without that entitlement so behaviour is preserved.

- [ ] **Step 3: Add to PlatformDependencies**

Edit `PeerDrop/Core/Platform/PlatformDependencies.swift`, add `deviceName` factory:

```swift
public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard
    public var haptics: () -> HapticFeedback
    public var deviceName: () -> DeviceNameProvider

    public init(
        pasteboard: @escaping () -> PlatformPasteboard = { Self.defaultPasteboard },
        haptics: @escaping () -> HapticFeedback = { Self.defaultHaptics },
        deviceName: @escaping () -> DeviceNameProvider = { Self.defaultDeviceName }
    ) {
        self.pasteboard = pasteboard
        self.haptics = haptics
        self.deviceName = deviceName
    }

    public static var shared = PlatformDependencies()

    #if canImport(UIKit)
    private static let defaultPasteboard: PlatformPasteboard = UIKitPasteboard()
    private static let defaultHaptics: HapticFeedback = UIKitHapticFeedback()
    private static let defaultDeviceName: DeviceNameProvider = UIKitDeviceNameProvider()
    #else
    private static let defaultPasteboard: PlatformPasteboard = NoOpPasteboard()
    private static let defaultHaptics: HapticFeedback = NoOpHapticFeedback()
    private static let defaultDeviceName: DeviceNameProvider = HostnameDeviceNameProvider()
    #endif
}

#if !canImport(UIKit)
private final class NoOpPasteboard: PlatformPasteboard { /* …as before… */ }
private final class NoOpHapticFeedback: HapticFeedback { /* …as before… */ }

private final class HostnameDeviceNameProvider: DeviceNameProvider {
    @MainActor
    var currentName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}
#endif
```

- [ ] **Step 4: Refactor UserProfile**

Edit `PeerDrop/Core/UserProfile.swift`:

```swift
import Foundation

struct UserProfile: Codable {
    var displayName: String
    var avatarData: Data?

    @MainActor
    static var current: UserProfile {
        let name = UserDefaults.standard.string(forKey: "peerDropDisplayName")
            ?? PlatformDependencies.shared.deviceName().currentName
        let avatar = UserDefaults.standard.data(forKey: "peerDropAvatarData")
        return UserProfile(displayName: name, avatarData: avatar)
    }

    func save() {
        UserDefaults.standard.set(displayName, forKey: "peerDropDisplayName")
        if let avatarData {
            UserDefaults.standard.set(avatarData, forKey: "peerDropAvatarData")
        } else {
            UserDefaults.standard.removeObject(forKey: "peerDropAvatarData")
        }
    }
}
```

Note: marking `current` as `@MainActor` is required because `DeviceNameProvider.currentName` is MainActor-isolated. Verify call sites of `UserProfile.current` — they're already on MainActor (the property is read from SwiftUI views and `@MainActor` ConnectionManager).

- [ ] **Step 5: Verify UserProfile.current call sites are MainActor-safe**

```bash
grep -rn "UserProfile.current" PeerDrop/ | head
```

Expected: all call sites are either inside `@MainActor` classes (ConnectionManager, ChatManager) or SwiftUI views (which are MainActor by default). If you find a non-MainActor call site, wrap it in `MainActor.run { UserProfile.current }`.

- [ ] **Step 6: Refactor PeerIdentity.swift line 65**

Open `PeerDrop/Core/PeerIdentity.swift`, find line 65 region (the `let name = ... UIDevice.current.name` assignment). Read the surrounding context first:

```bash
sed -n '60,72p' PeerDrop/Core/PeerIdentity.swift
```

Replace `UIDevice.current.name` with `PlatformDependencies.shared.deviceName().currentName`:

```swift
// before:
let name = UserDefaults.standard.string(forKey: "peerDropDisplayName") ?? UIDevice.current.name
// after:
let name = UserDefaults.standard.string(forKey: "peerDropDisplayName")
    ?? PlatformDependencies.shared.deviceName().currentName
```

Also remove `import UIKit` at line 2; replace with `import Foundation` if not already present. Verify the enclosing function is `@MainActor` or wrap in `MainActor.assumeIsolated { ... }` if necessary.

- [ ] **Step 7: Refactor ArchiveManager.swift line 28**

In `PeerDrop/Core/ArchiveManager.swift`:

```swift
// before:
let manifest = Manifest(version: 1, exportDate: Date(), deviceName: UIDevice.current.name)
// after:
let manifest = Manifest(version: 1, exportDate: Date(), deviceName: PlatformDependencies.shared.deviceName().currentName)
```

Also drop `import UIKit` (line 2), replace with nothing — `Foundation` is already imported on line 1.

`exportArchive` is already `@MainActor`, so the call is safe.

- [ ] **Step 8: Refactor ConnectionManager.swift line 2422**

In `PeerDrop/Core/ConnectionManager.swift`:

```swift
// before:
let senderName = await MainActor.run { UIDevice.current.name }
// after:
let senderName = await MainActor.run { PlatformDependencies.shared.deviceName().currentName }
```

(The MainActor.run is retained because the surrounding function is `nonisolated`/async; the protocol method is MainActor-isolated so it must run on MainActor.)

Do NOT remove `import UIKit` at line 6 yet — `UIApplication` and `UIBackgroundTaskIdentifier` are still used. Removal happens in Task 11.

- [ ] **Step 9: Add MockDeviceName + extend mock() helper**

Append to `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`:

```swift
final class MockDeviceNameProvider: DeviceNameProvider {
    var name: String = "Mock Device"

    @MainActor
    var currentName: String { name }
}

extension PlatformDependencies {
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard(),
        haptics: MockHaptics = MockHaptics(),
        deviceName: MockDeviceNameProvider = MockDeviceNameProvider()
    ) -> PlatformDependencies {
        PlatformDependencies(
            pasteboard: { pasteboard },
            haptics: { haptics },
            deviceName: { deviceName }
        )
    }
}
```

- [ ] **Step 10: Add injection test**

Append:

```swift
@MainActor
final class DeviceNameInjectionTests: XCTestCase {
    func test_userProfileCurrentReadsFromInjectedDeviceName() {
        let originalDeps = PlatformDependencies.shared
        defer { PlatformDependencies.shared = originalDeps }

        // Clear any saved display name so the fallback is exercised
        UserDefaults.standard.removeObject(forKey: "peerDropDisplayName")
        defer { UserDefaults.standard.removeObject(forKey: "peerDropDisplayName") }

        let mock = MockDeviceNameProvider()
        mock.name = "Test Mac"
        PlatformDependencies.shared = .mock(deviceName: mock)

        XCTAssertEqual(UserProfile.current.displayName, "Test Mac")
    }
}
```

- [ ] **Step 11: Full build + test sweep**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/DeviceNameInjectionTests -quiet
```

Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 12: Verify no UIDevice.current.name references remain in Core/**

```bash
grep -rn "UIDevice.current.name" PeerDrop/Core/
```

Expected: empty output (no matches).

- [ ] **Step 13: Commit**

```bash
git add PeerDrop/Core/Platform PeerDrop/Core/UserProfile.swift PeerDrop/Core/PeerIdentity.swift PeerDrop/Core/ArchiveManager.swift PeerDrop/Core/ConnectionManager.swift PeerDropTests/Core/Platform PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): DeviceNameProvider replaces UIDevice.current.name (M0)

4 consumers migrated: UserProfile, PeerIdentity, ArchiveManager,
ConnectionManager. UIKit import dropped from 3 of them; ConnectionManager
still imports UIKit for background-task APIs (handled in Task 11).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: SystemInfoProvider protocol + iOS impl + ErrorReporter refactor

**Files:**
- Create: `PeerDrop/Core/Platform/SystemInfoProvider.swift`
- Create: `PeerDrop/Core/Platform/iOS/UIKitSystemInfoProvider.swift`
- Modify: `PeerDrop/Core/Platform/PlatformDependencies.swift`
- Modify: `PeerDrop/Core/ErrorReporter.swift`
- Modify: `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`

- [ ] **Step 1: Define protocol**

```swift
// PeerDrop/Core/Platform/SystemInfoProvider.swift
import Foundation

/// System telemetry for error reports. Both fields ship to the Cloudflare
/// Worker `/debug/report` endpoint as plain strings.
public protocol SystemInfoProvider {
    @MainActor
    var deviceModel: String { get }

    @MainActor
    var osVersion: String { get }
}
```

- [ ] **Step 2: iOS adapter**

```swift
// PeerDrop/Core/Platform/iOS/UIKitSystemInfoProvider.swift
#if canImport(UIKit)
import UIKit

final class UIKitSystemInfoProvider: SystemInfoProvider {
    @MainActor
    var deviceModel: String { UIDevice.current.model }

    @MainActor
    var osVersion: String { UIDevice.current.systemVersion }
}
#endif
```

- [ ] **Step 3: Add to PlatformDependencies**

Replace the entire `PeerDrop/Core/Platform/PlatformDependencies.swift` contents (extending the previous version with `systemInfo`):

```swift
import Foundation

public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard
    public var haptics: () -> HapticFeedback
    public var deviceName: () -> DeviceNameProvider
    public var systemInfo: () -> SystemInfoProvider

    public init(
        pasteboard: @escaping () -> PlatformPasteboard = { Self.defaultPasteboard },
        haptics: @escaping () -> HapticFeedback = { Self.defaultHaptics },
        deviceName: @escaping () -> DeviceNameProvider = { Self.defaultDeviceName },
        systemInfo: @escaping () -> SystemInfoProvider = { Self.defaultSystemInfo }
    ) {
        self.pasteboard = pasteboard
        self.haptics = haptics
        self.deviceName = deviceName
        self.systemInfo = systemInfo
    }

    public static var shared = PlatformDependencies()

    #if canImport(UIKit)
    private static let defaultPasteboard: PlatformPasteboard = UIKitPasteboard()
    private static let defaultHaptics: HapticFeedback = UIKitHapticFeedback()
    private static let defaultDeviceName: DeviceNameProvider = UIKitDeviceNameProvider()
    private static let defaultSystemInfo: SystemInfoProvider = UIKitSystemInfoProvider()
    #else
    private static let defaultPasteboard: PlatformPasteboard = NoOpPasteboard()
    private static let defaultHaptics: HapticFeedback = NoOpHapticFeedback()
    private static let defaultDeviceName: DeviceNameProvider = HostnameDeviceNameProvider()
    private static let defaultSystemInfo: SystemInfoProvider = SysctlSystemInfoProvider()
    #endif
}

#if !canImport(UIKit)
private final class NoOpPasteboard: PlatformPasteboard {
    var changeCount: Int { 0 }
    var stringContent: String? { get { nil } set { } }
    var imageContent: PlatformImage? { get { nil } set { } }
    var changedNotificationName: Notification.Name { Notification.Name("NoOpPasteboardChanged") }
}

private final class NoOpHapticFeedback: HapticFeedback {
    func peerDiscovered() {}
    func connectionAccepted() {}
    func connectionRejected() {}
    func transferComplete() {}
    func transferFailed() {}
    func incomingRequest() {}
    func callStarted() {}
    func callEnded() {}
    func tap() {}
}

private final class HostnameDeviceNameProvider: DeviceNameProvider {
    @MainActor
    var currentName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}

private final class SysctlSystemInfoProvider: SystemInfoProvider {
    @MainActor
    var deviceModel: String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    @MainActor
    var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
#endif
```

- [ ] **Step 4: Refactor ErrorReporter**

Replace `PeerDrop/Core/ErrorReporter.swift`:

```swift
import Foundation
import os.log

/// Sends error reports to the Cloudflare Worker for remote debugging.
/// Reports are stored for 7 days and can be fetched with:
///   curl -H "X-API-Key: $KEY" https://peerdrop-signal.hanfourhuang.workers.dev/debug/reports
enum ErrorReporter {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ErrorReporter")

    /// Send an error report. Fire-and-forget — never blocks UI.
    static func report(
        error: String,
        context: String,
        extras: [String: String] = [:]
    ) {
        Task.detached(priority: .utility) {
            await send(error: error, context: context, extras: extras)
        }
    }

    private static func send(
        error: String,
        context: String,
        extras: [String: String]
    ) async {
        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard let url = URL(string: "\(baseURL)/debug/report") else { return }

        let info = PlatformDependencies.shared.systemInfo()
        let deviceModel = await MainActor.run { info.deviceModel }
        let systemVersion = await MainActor.run { info.osVersion }
        var body: [String: Any] = [
            "error": error,
            "context": context,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "device": deviceModel,
            "systemVersion": systemVersion,
        ]
        for (k, v) in extras { body[k] = v }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 201 {
                logger.info("Error report sent successfully")
            }
        } catch {
            logger.debug("Failed to send error report: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 5: Add MockSystemInfo + extend `mock(...)`**

Append to `MockPlatformDependencies.swift`:

```swift
final class MockSystemInfoProvider: SystemInfoProvider {
    var model: String = "MockDevice"
    var os: String = "MockOS 1.0"

    @MainActor
    var deviceModel: String { model }

    @MainActor
    var osVersion: String { os }
}

extension PlatformDependencies {
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard(),
        haptics: MockHaptics = MockHaptics(),
        deviceName: MockDeviceNameProvider = MockDeviceNameProvider(),
        systemInfo: MockSystemInfoProvider = MockSystemInfoProvider()
    ) -> PlatformDependencies {
        PlatformDependencies(
            pasteboard: { pasteboard },
            haptics: { haptics },
            deviceName: { deviceName },
            systemInfo: { systemInfo }
        )
    }
}
```

- [ ] **Step 6: Build + verify ErrorReporter call sites compile**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add PeerDrop/Core/Platform PeerDrop/Core/ErrorReporter.swift PeerDropTests/Core/Platform PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): ErrorReporter uses SystemInfoProvider (M0)

UIDevice.current.model / systemVersion abstracted behind protocol.
ErrorReporter drops direct UIKit import.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: RemoteNotificationRegistering protocol + iOS impl + PushNotificationManager refactor

**Files:**
- Create: `PeerDrop/Core/Platform/RemoteNotificationRegistering.swift`
- Create: `PeerDrop/Core/Platform/iOS/UIKitRemoteNotificationRegistering.swift`
- Modify: `PeerDrop/Core/Platform/PlatformDependencies.swift`
- Modify: `PeerDrop/Core/PushNotificationManager.swift`
- Modify: `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`

- [ ] **Step 1: Define protocol**

```swift
// PeerDrop/Core/Platform/RemoteNotificationRegistering.swift
import Foundation

/// Abstracts the platform-specific APNs token registration call.
/// iOS: UIApplication.shared.registerForRemoteNotifications()
/// macOS (M2): NSApplication.shared.registerForRemoteNotifications()
public protocol RemoteNotificationRegistering {
    @MainActor
    func registerForRemoteNotifications()
}
```

- [ ] **Step 2: iOS adapter**

```swift
// PeerDrop/Core/Platform/iOS/UIKitRemoteNotificationRegistering.swift
#if canImport(UIKit)
import UIKit

final class UIKitRemoteNotificationRegistering: RemoteNotificationRegistering {
    @MainActor
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
#endif
```

- [ ] **Step 3: Add to PlatformDependencies**

Replace the entire `PeerDrop/Core/Platform/PlatformDependencies.swift` contents (extending the Task 7 version with `remoteNotifications`):

```swift
import Foundation

public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard
    public var haptics: () -> HapticFeedback
    public var deviceName: () -> DeviceNameProvider
    public var systemInfo: () -> SystemInfoProvider
    public var remoteNotifications: () -> RemoteNotificationRegistering

    public init(
        pasteboard: @escaping () -> PlatformPasteboard = { Self.defaultPasteboard },
        haptics: @escaping () -> HapticFeedback = { Self.defaultHaptics },
        deviceName: @escaping () -> DeviceNameProvider = { Self.defaultDeviceName },
        systemInfo: @escaping () -> SystemInfoProvider = { Self.defaultSystemInfo },
        remoteNotifications: @escaping () -> RemoteNotificationRegistering = { Self.defaultRemoteNotifications }
    ) {
        self.pasteboard = pasteboard
        self.haptics = haptics
        self.deviceName = deviceName
        self.systemInfo = systemInfo
        self.remoteNotifications = remoteNotifications
    }

    public static var shared = PlatformDependencies()

    #if canImport(UIKit)
    private static let defaultPasteboard: PlatformPasteboard = UIKitPasteboard()
    private static let defaultHaptics: HapticFeedback = UIKitHapticFeedback()
    private static let defaultDeviceName: DeviceNameProvider = UIKitDeviceNameProvider()
    private static let defaultSystemInfo: SystemInfoProvider = UIKitSystemInfoProvider()
    private static let defaultRemoteNotifications: RemoteNotificationRegistering = UIKitRemoteNotificationRegistering()
    #else
    private static let defaultPasteboard: PlatformPasteboard = NoOpPasteboard()
    private static let defaultHaptics: HapticFeedback = NoOpHapticFeedback()
    private static let defaultDeviceName: DeviceNameProvider = HostnameDeviceNameProvider()
    private static let defaultSystemInfo: SystemInfoProvider = SysctlSystemInfoProvider()
    private static let defaultRemoteNotifications: RemoteNotificationRegistering = NoOpRemoteNotificationRegistering()
    #endif
}

#if !canImport(UIKit)
private final class NoOpPasteboard: PlatformPasteboard {
    var changeCount: Int { 0 }
    var stringContent: String? { get { nil } set { } }
    var imageContent: PlatformImage? { get { nil } set { } }
    var changedNotificationName: Notification.Name { Notification.Name("NoOpPasteboardChanged") }
}

private final class NoOpHapticFeedback: HapticFeedback {
    func peerDiscovered() {}
    func connectionAccepted() {}
    func connectionRejected() {}
    func transferComplete() {}
    func transferFailed() {}
    func incomingRequest() {}
    func callStarted() {}
    func callEnded() {}
    func tap() {}
}

private final class HostnameDeviceNameProvider: DeviceNameProvider {
    @MainActor
    var currentName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}

private final class SysctlSystemInfoProvider: SystemInfoProvider {
    @MainActor
    var deviceModel: String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    @MainActor
    var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

private final class NoOpRemoteNotificationRegistering: RemoteNotificationRegistering {
    @MainActor
    func registerForRemoteNotifications() {
        // M2 replaces with NSApplication.shared.registerForRemoteNotifications()
    }
}
#endif
```

- [ ] **Step 4: Refactor PushNotificationManager line 65**

In `PeerDrop/Core/PushNotificationManager.swift`:

```swift
// before:
await MainActor.run {
    UIApplication.shared.registerForRemoteNotifications()
}
// after:
await MainActor.run {
    PlatformDependencies.shared.remoteNotifications().registerForRemoteNotifications()
}
```

Also drop `import UIKit` at line 2 if no other UIKit reference remains in the file:

```bash
grep -n "UIApplication\|UIDevice\|UIImage\|UIKit" PeerDrop/Core/PushNotificationManager.swift
```

If the only remaining hit is `import UIKit`, replace it with `import Foundation`.

- [ ] **Step 5: Add MockRemoteNotificationRegistering + extend mock(...)**

Append to `MockPlatformDependencies.swift`:

```swift
final class MockRemoteNotificationRegistering: RemoteNotificationRegistering {
    private(set) var registerCalled = false

    @MainActor
    func registerForRemoteNotifications() {
        registerCalled = true
    }
}

extension PlatformDependencies {
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard(),
        haptics: MockHaptics = MockHaptics(),
        deviceName: MockDeviceNameProvider = MockDeviceNameProvider(),
        systemInfo: MockSystemInfoProvider = MockSystemInfoProvider(),
        remoteNotifications: MockRemoteNotificationRegistering = MockRemoteNotificationRegistering()
    ) -> PlatformDependencies {
        PlatformDependencies(
            pasteboard: { pasteboard },
            haptics: { haptics },
            deviceName: { deviceName },
            systemInfo: { systemInfo },
            remoteNotifications: { remoteNotifications }
        )
    }
}
```

- [ ] **Step 6: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add PeerDrop/Core/Platform PeerDrop/Core/PushNotificationManager.swift PeerDropTests/Core/Platform PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): PushNotificationManager uses RemoteNotificationRegistering (M0)

UIApplication.shared.registerForRemoteNotifications() abstracted.
PushNotificationManager drops direct UIKit import.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Wrap ConnectionManager background-task code in `#if os(iOS)`

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift`

This task does NOT introduce an abstraction. iOS-only `UIBackgroundTaskIdentifier`, `beginBackgroundTask`, `endBackgroundTask`, `backgroundTimeRemaining` get bare `#if os(iOS)` gates. On macOS the surrounding ScenePhase handler simply skips these calls (Mac apps don't suspend, so the entire concept is N/A).

- [ ] **Step 1: Read the current background-task region**

```bash
sed -n '250,260p;1560,1610p' PeerDrop/Core/ConnectionManager.swift
```

Note line 256 (`private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid`) and lines 1566–1610 (the 4 helper functions).

- [ ] **Step 2: Wrap the property declaration**

Find line 256 (approximate). Replace:

```swift
private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
```

with:

```swift
#if os(iOS)
private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
#endif
```

- [ ] **Step 3: Wrap the 4 helper functions**

Find `beginBackgroundTask`, `endBackgroundTask`, `startBackgroundTimeMonitor`, `stopBackgroundTimeMonitor`, `handleBackgroundTimeWarning` (lines ~1566–1610). Wrap the entire block (from `private func beginBackgroundTask()` through the closing brace of `handleBackgroundTimeWarning`):

```swift
#if os(iOS)
private func beginBackgroundTask() {
    // ... existing body ...
}

private func endBackgroundTask() {
    // ... existing body ...
}

private func startBackgroundTimeMonitor() {
    // ... existing body ...
}

private func stopBackgroundTimeMonitor() {
    // ... existing body ...
}

private func handleBackgroundTimeWarning(remaining: TimeInterval) {
    // ... existing body ...
}
#endif
```

- [ ] **Step 4: Wrap the call sites in handleScenePhaseChange**

Find lines 1531 and 1536 (`beginBackgroundTask()` calls inside `handleScenePhaseChange`). Wrap each in `#if os(iOS)`:

```swift
case .connected, .transferring, .voiceCall:
    #if os(iOS)
    beginBackgroundTask()
    #endif
    stopDiscoveryOnly()
case .requesting, .connecting, .incomingRequest:
    #if os(iOS)
    beginBackgroundTask()
    #endif
    stopDiscoveryOnly()
```

Also wrap any `endBackgroundTask()` calls and `backgroundTaskID` reads/writes outside the helper functions:

```bash
grep -n "backgroundTaskID\|endBackgroundTask\|stopBackgroundTimeMonitor\|backgroundTimeMonitorTask" PeerDrop/Core/ConnectionManager.swift
```

Wrap each match in `#if os(iOS)` ... `#endif`.

Also wrap the property `backgroundTimeMonitorTask` and `backgroundWarningThreshold` if iOS-only:

```bash
grep -n "private var backgroundTimeMonitorTask\|private let backgroundWarningThreshold" PeerDrop/Core/ConnectionManager.swift
```

If found, wrap them in `#if os(iOS)`.

- [ ] **Step 5: Remove `import UIKit` from ConnectionManager**

Verify nothing else in ConnectionManager imports UIKit:

```bash
grep -n "UIDevice\|UIApplication\|UIImage\|UIPasteboard\|UIScreen\|UIColor\|UIView" PeerDrop/Core/ConnectionManager.swift
```

Expected: only matches inside `#if os(iOS)` blocks (from Task 6 you've already handled `UIDevice.current.name` on line 2422; from this task you've wrapped `UIApplication.shared.beginBackgroundTask`).

If clean, wrap the `import UIKit` line itself:

```swift
#if os(iOS)
import UIKit
#endif
```

- [ ] **Step 6: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`. If errors mention `UIBackgroundTaskIdentifier` or any UI type, find that reference and add `#if os(iOS)` around it.

- [ ] **Step 7: Run full test suite (sanity check — 913 tests should still pass)**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -quiet 2>&1 | tail -20
```

Expected: `Test Suite 'All tests' passed`. If anything fails, it's likely an `import UIKit` you missed inside a closure or a missing `#if`. Read the failure line and add the gate.

- [ ] **Step 8: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift
git commit -m "$(cat <<'EOF'
refactor(core): gate ConnectionManager iOS background-task code (M0)

UIBackgroundTaskIdentifier, beginBackgroundTask, endBackgroundTask,
backgroundTimeRemaining, and the background-time monitor wrapped in
#if os(iOS). macOS apps don't suspend so the concept is N/A.

ConnectionManager's `import UIKit` itself is now #if os(iOS) too —
all other UIKit references in this file were removed in Task 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Verify Core/ is UIKit-free except inside `#if os(iOS)`

**Files:**
- (verification only; no changes unless a stray import is found)

- [ ] **Step 1: Scan for unguarded UIKit imports**

```bash
grep -rn "^import UIKit" PeerDrop/Core/
```

Expected: only `PeerDrop/Core/ConnectionManager.swift` shows a match, and the line above it is `#if os(iOS)`. If any other file matches, find the cause and fix:
- If the file legitimately needs UIKit (rare), wrap the import in `#if os(iOS)` and gate the using code too
- Otherwise convert the remaining UIKit usage to use a `PlatformDependencies` member

- [ ] **Step 2: Scan for unguarded UIKit type usage**

```bash
grep -rn "UIDevice\|UIApplication\|UIImage\|UIPasteboard\|UIScreen\|UIFont\|UIColor\|UIImpactFeedback\|UINotificationFeedback\|UISelectionFeedback" PeerDrop/Core/
```

Expected: matches only inside `#if os(iOS)` blocks. Visually scan each hit. Note: `PlatformImage` (typealias) is fine.

- [ ] **Step 3: Full build (no test, just compilation sanity)**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: No commit (verification only). Proceed to Task 11.**

---

## Task 11: Wire iOS implementations explicitly in PeerDropApp (no-op for now)

**Files:**
- Modify: `PeerDrop/App/PeerDropApp.swift`

The defaults in `PlatformDependencies.init` already point to iOS adapters via `Self.defaultPasteboard` etc. — so this step is largely a no-op that **documents** the wiring point for M2 (when macOS adapters need explicit registration). We add a single line in `PeerDropApp.init` to make the wiring explicit and discoverable.

- [ ] **Step 1: Find PeerDropApp.init or .onAppear bootstrap region**

```bash
sed -n '1,80p' PeerDrop/App/PeerDropApp.swift
```

Locate the existing `init()` of `PeerDropApp` (if absent, find the SwiftUI App struct declaration).

- [ ] **Step 2: Add explicit dependency wiring**

Add or extend `PeerDropApp.init()`:

```swift
init() {
    // Explicit wiring of platform dependencies. The struct defaults already
    // resolve to iOS adapters on iOS, but binding the registry here makes
    // M2 (macOS) wiring trivially symmetric: replace with .init(
    //   pasteboard: { AppKitPasteboard() }, ...) and the rest of the app
    // is untouched.
    PlatformDependencies.shared = PlatformDependencies()
}
```

If `init()` already exists, prepend this line to its body.

- [ ] **Step 3: Build + test**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/PlatformDependenciesTests \
  -only-testing:PeerDropTests/PlatformImageTests \
  -only-testing:PeerDropTests/ClipboardSyncManagerInjectionTests \
  -only-testing:PeerDropTests/HapticManagerInjectionTests \
  -only-testing:PeerDropTests/DeviceNameInjectionTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add PeerDrop/App/PeerDropApp.swift
git commit -m "$(cat <<'EOF'
refactor(app): explicit PlatformDependencies wiring in PeerDropApp.init (M0)

No-op on iOS (defaults already resolve to iOS adapters). Documents the
single point where M2 will swap in AppKit adapters for macOS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Add `lint-imports` CI job in warn-only mode

**Files:**
- Create or Modify: `.github/workflows/ci.yml`

Check what CI exists today:

```bash
ls -la .github/workflows/ 2>/dev/null
```

If no workflows exist, create `.github/workflows/ci.yml`. If a workflow exists for tests, append a new job to it.

- [ ] **Step 1: Add the job**

Append to `.github/workflows/ci.yml` (or create the file with this content if no workflow exists):

```yaml
  lint-imports:
    name: Lint — no UIKit in Core/Platform
    runs-on: macos-15
    continue-on-error: true  # warn-only at M0; flipped to false in M1
    steps:
      - uses: actions/checkout@v4
      - name: Scan for unguarded UIKit/AppKit/WidgetKit imports in Core/
        run: |
          set -e
          violations=$(grep -rn "^import UIKit\|^import AppKit\|^import WidgetKit" PeerDrop/Core/ | \
            grep -v "PeerDrop/Core/Platform/iOS/" | \
            grep -B1 "^import UIKit\|^import AppKit\|^import WidgetKit" || true)
          if [ -n "$violations" ]; then
            echo "::warning::Direct UI-framework imports found in Core/:"
            echo "$violations"
          else
            echo "Clean: Core/ has no direct UI-framework imports outside Platform/iOS/."
          fi
```

Note: `continue-on-error: true` makes it a warning. In M1 (when SPM split lands), this becomes `continue-on-error: false` and the job becomes a hard gate.

The grep allowlist excludes `PeerDrop/Core/Platform/iOS/` (where UIKit imports are legitimate, gated to iOS). ConnectionManager's `#if os(iOS)\nimport UIKit\n#endif` is detected by `^import UIKit` but the surrounding `#if` doesn't appear on the same line; the `grep -v` allowlist needs to handle it. Simpler approach: just scan for files where `import UIKit` appears NOT after `#if os(iOS)`:

Replace the run step with a more robust check:

```yaml
      - name: Scan for unguarded UIKit/AppKit/WidgetKit imports in Core/
        run: |
          set -e
          violations=""
          while IFS= read -r file; do
            if grep -E "^import (UIKit|AppKit|WidgetKit)" "$file" > /dev/null 2>&1; then
              # Check whether each import is gated by #if os(iOS) immediately above
              while IFS= read -r line_no; do
                prev_line=$((line_no - 1))
                prev=$(sed -n "${prev_line}p" "$file" | tr -d '[:space:]')
                if [ "$prev" != "#ifos(iOS)" ]; then
                  violations+="$file:$line_no: $(sed -n "${line_no}p" "$file")\n"
                fi
              done < <(grep -n -E "^import (UIKit|AppKit|WidgetKit)" "$file" | cut -d: -f1)
            fi
          done < <(find PeerDrop/Core -name "*.swift" -not -path "*/Platform/iOS/*")
          if [ -n "$violations" ]; then
            echo "::warning::Unguarded UI-framework imports in Core/:"
            printf "$violations"
          else
            echo "Clean."
          fi
```

- [ ] **Step 2: Run the script locally to verify it passes**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"
violations=""
while IFS= read -r file; do
  if grep -E "^import (UIKit|AppKit|WidgetKit)" "$file" > /dev/null 2>&1; then
    while IFS= read -r line_no; do
      prev_line=$((line_no - 1))
      prev=$(sed -n "${prev_line}p" "$file" | tr -d '[:space:]')
      if [ "$prev" != "#ifos(iOS)" ]; then
        violations+="$file:$line_no\n"
      fi
    done < <(grep -n -E "^import (UIKit|AppKit|WidgetKit)" "$file" | cut -d: -f1)
  fi
done < <(find PeerDrop/Core -name "*.swift" -not -path "*/Platform/iOS/*")
if [ -n "$violations" ]; then
  printf "Violations:\n%b" "$violations"
else
  echo "Clean."
fi
```

Expected: `Clean.` (since ConnectionManager's import is gated by `#if os(iOS)`).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci: lint-imports job (warn-only) for Core/ UI-framework hygiene (M0)

Detects unguarded `import UIKit/AppKit/WidgetKit` outside Platform/iOS/.
Warn-only at M0; flips to error in M1 once SPM split lands and the
PeerDropKit module boundary makes the rule physically enforced.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Full regression sweep + close M0

**Files:**
- Modify: `CLAUDE.md` (add M0 ship note to PeerDrop project memory)

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m0-test-output.log | tail -30
```

Expected: `Test Suite 'All tests' passed at ...`. If any test fails:
1. Read the failure in `/tmp/m0-test-output.log`
2. The most likely cause is a missing `#if os(iOS)` gate, an injection that didn't pick up the iOS default, or a test that hard-coded `UIDevice.current.name` and now reads the mock. Fix and re-run.

- [ ] **Step 2: Count tests for sanity**

```bash
grep -c "Test Case.*started" /tmp/m0-test-output.log
```

Expected: ≥ 913 (the existing baseline) + 5 new injection tests = ~918. Any decrease means a test bundle wasn't picked up by xcodegen — verify with `xcodegen generate` then re-run.

- [ ] **Step 3: Verify Core/ UIKit dependency count dropped from 9 to 1**

```bash
grep -rln "^import UIKit" PeerDrop/Core/ | wc -l
```

Expected: `1` (only `ConnectionManager.swift`, and that's wrapped in `#if os(iOS)`).

- [ ] **Step 4: Update CLAUDE.md memory**

The memory file is at `/Users/hanfourmini/.claude/projects/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/memory/MEMORY.md`. Append a new line under the **Detailed Notes** section pointing to a new memory file `project-macos-port.md`:

Create `/Users/hanfourmini/.claude/projects/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/memory/project-macos-port.md` with:

```markdown
---
name: project-macos-port
description: macOS port (v6.0) progress tracker — milestones, blockers, design + plan locations
metadata:
  type: project
---

# PeerDrop macOS Port — v6.0

**Spec:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` (approved 2026-05-24)
**Plans:** `docs/superpowers/plans/2026-05-25-m0-*.md` (M1–M4 written as each prior milestone ships)

## Milestone status

- **M0 Core UIKit decoupling:** ✅ shipped <DATE>. 5 protocols + 1 typealias under `PeerDrop/Core/Platform/`. iOS behaviour unchanged; ConnectionManager's `import UIKit` is the only remaining UI-framework import in Core/ and it's `#if os(iOS)`-gated. lint-imports CI job in warn-only mode.
- **M1 SPM package split:** pending. Plan to write after M0 ships.
- **M2 macOS UI shell:** pending
- **M3 Mac voice calling:** pending
- **M4 MAS submission prep:** pending

## Key reality-checks vs spec

- `DeviceFingerprintProvider` deferred to M3 (PeerIdentity uses only `UIDevice.current.name`, not `identifierForVendor` — the spec was wrong)
- `AppLifecycleObserver` not needed — `@Environment(\.scenePhase)` is already cross-platform SwiftUI
- ArchiveManager doesn't use `UIImage` — only `UIDevice.current.name`
```

Append a one-liner to `MEMORY.md`:

```markdown
- [macOS Port (v6.0) Tracker](project-macos-port.md) — milestones, blockers, design + plan locations
```

- [ ] **Step 5: Commit + tag**

```bash
git add CLAUDE.md  # if updated
git add /Users/hanfourmini/.claude/projects/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/memory/MEMORY.md \
        /Users/hanfourmini/.claude/projects/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/memory/project-macos-port.md
# (Memory files aren't in the repo — adjust this step to your memory-tracking workflow if needed)

# Final M0 closing commit (if any docs needed):
# Otherwise this task is just verification.

# Tag the M0 ship point for easy reference from M1:
git tag -a m0-core-uikit-decoupled -m "M0 done: Core/ UIKit dependency removed via PlatformDependencies"
```

- [ ] **Step 6: Confirm M0 ready to ship as iOS v5.5 internal refactor (optional release)**

This is a pure-refactor PR; no ASC submission required. If you want to release it to TestFlight for dogfooding:

```bash
# Bump MARKETING_VERSION to 5.5.0 in project.yml
xcodegen generate
fastlane release  # or fastlane release submit:false if you want to attach IAPs
```

Or, skip release and roll M0+M1 together as part of v6.0.0.

---

## Done

M0 complete. Core/ has gone from 9 unguarded UIKit imports to 1 gated import. All iOS behaviour preserved (913+ tests passing). PlatformDependencies registry ready to receive AppKit adapters in M2 with zero changes to call sites.

Next: write the M1 plan (`docs/superpowers/plans/2026-06-XX-m1-spm-package-split.md`) by re-invoking `superpowers:writing-plans` once M0 is merged.
