# M1d-5 — PeerDropCore Module Migration + Final Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate 28 source files from `PeerDrop/Core/` into `PeerDropKit/Sources/PeerDropCore/` (the final SPM module). Move `PeerIdentity` + `PeerMessage+Hello` into `PeerDropSecurity` (PeerIdentity was originally specced there). Wrap iOS-only `UIApplication.beginBackgroundTask` in a Platform abstraction so PeerDropCore compiles for macOS. Drop now-unused direct `WebRTC` + `ZIPFoundation` deps from the iOS app target — they reach the app target transitively via `PeerDropKit`. Run final `lint-imports` validation. After M1d-5, the M1 train is done and the iOS app target is essentially a thin shell over `PeerDropKit`.

**Architecture:** PeerDropCore target gains `dependencies: ["PeerDropPlatform", "PeerDropProtocol", "PeerDropSecurity", "PeerDropPet", "PeerDropTransport"]` (already declared in `Package.swift`). PeerDropCore is the keystone — depends on all 5 other modules. UIApplication background-task usage in `ConnectionManager` gets a `BackgroundTaskHandling` Platform protocol (iOS adapter wraps `UIApplication.beginBackgroundTask`; macOS adapter is a no-op since macOS doesn't background-suspend the same way). `PeerIdentity` moves to `PeerDropSecurity` (carries `IdentityKeyManager` reference) — the 3 UI consumers + 1 Security-internal comment update accordingly.

**Tech Stack:** Swift 5.9, iOS 16+, macOS 14+, XcodeGen 2.45.4. Builds: `xcodebuild` (iOS app) + `swift build`/`swift test` (PeerDropKit).

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1d-5 line 319.

**Predecessors (all merged or in flight):** M0, M1a, M1b, triage, M1c, M1d-1, M1d-2, M1d-3a, M1d-3b, M1d-4 (PR #54).

**Investigation findings (2026-05-27):**

### Source files (30 in PeerDrop/Core/, splitting 28 + 2)

**28 → PeerDropCore:**
```
ArchiveManager.swift                          ChatManager.swift
ChatMessage.swift                             ClipboardSyncManager.swift
ConnectionContext.swift                       ConnectionManager.swift
ConnectionManager+TransportHost.swift         ConnectionMetric.swift
ConnectionMetrics.swift                       ConnectionState.swift
DeviceGroup.swift                             DeviceGroupStore.swift
DeviceRecord.swift                            DeviceRecordStore.swift
DeviceRecordStore+RelayAuth.swift             ErrorReporter.swift
ImageCache.swift                              InboxService.swift
NetworkFingerprint.swift                      NotificationManager.swift
PeerConnection.swift                          PeerConnectionState.swift
PushNotificationManager.swift                 RelaySession.swift
ScreenshotModeProvider.swift                  TailnetPeerEntry.swift
TailnetPeerStore.swift                        UserProfile.swift
```

**2 → PeerDropSecurity:**
```
PeerIdentity.swift                            (struct used by Security types)
PeerMessage+Hello.swift                       (hello + secureHandshake factories
                                               use PeerIdentity + LocalSecureChannel)
```

### iOS-only API in Core

- **`ConnectionManager.swift:1588-1610`** — `UIApplication.shared.beginBackgroundTask` + `endBackgroundTask` + `backgroundTimeRemaining`. macOS doesn't have these. Three uses (start, end, observe remaining time). Solution: protocol-inversion via a new `BackgroundTaskHandling` protocol in PeerDropPlatform, iOS adapter wraps UIApplication, macOS no-op adapter returns invalid token + `.infinity` for remaining.

- **`DeviceGroupStore.swift:1`, `DeviceRecordStore.swift:1`** — `import SwiftUI` is unused (these are `@Published` types which live in `Combine`, not SwiftUI). Replace with `import Combine` — cross-platform safe.

### Cross-module dependency outlook

After M1d-4, Core/ imports:
```
Combine, CryptoKit, Foundation, Network, os, os.log,
PeerDropPet, PeerDropPlatform, PeerDropProtocol,
PeerDropSecurity, PeerDropTransport,
SwiftUI (only DeviceGroupStore + DeviceRecordStore + ConnectionManager — drop where unused),
UIKit (ConnectionManager only — replaced by BackgroundTaskHandling),
UserNotifications
```

After M1d-5, PeerDropCore should import: `Combine, CryptoKit, Foundation, Network, os, os.log, UserNotifications` + the 5 SPM modules. **No UIKit, no SwiftUI** — passes the existing `lint-imports` rule.

### WebRTC direct usage in app target

- **`PeerDrop/Core/RelaySession.swift:3`** uses `@preconcurrency import WebRTC` (and `RTCConfiguration`, `RTCSessionDescription`, `RTCIceCandidate`).
- After RelaySession moves into PeerDropCore, the iOS app target no longer has any source file importing WebRTC directly.
- `project.yml` `dependencies:` block currently declares `- package: WebRTC` for the app target; this becomes redundant (WebRTC reaches the app target transitively via `PeerDropKit` → `PeerDropTransport`).

### ZIPFoundation direct usage

- Already zero direct imports in app target sources (verified via `grep -rln "^import ZIPFoundation" PeerDrop/`).
- Used only by PeerDropPet's `Sprites/{SpriteAtlas,SpriteService,SpriteDecoder,SpriteMetadata}.swift`.
- `project.yml` `- package: ZIPFoundation` for the app target is also redundant.

### External consumers needing `import PeerDropCore`

42 files across `PeerDrop/App/` + `PeerDrop/UI/` (verified via grep). 27 test files already touch Core types via `@testable import PeerDrop`; after M1d-5 most can switch to `@testable import PeerDropCore` (some still need both for app-target integration tests).

### PeerIdentity move impact

- `PeerIdentity.swift` already imports `PeerDropSecurity` + `PeerDropPlatform`. Zero Core deps.
- 3 UI consumers: `GroupChatView.swift`, `GroupReadReceiptView.swift`, `RemoteInviteView.swift` need `import PeerDropSecurity`.
- 1 Security comment in `TrustedContact.swift` (no code change).
- Other Core/ files reference PeerIdentity but those are inside the migrated PeerDropCore (which already depends on PeerDropSecurity — no new dep).
- ConnectionManager.swift's `extension ConnectionManager: TransportHost` exposes `var localPeerID: String { localIdentity.id }` — unchanged after PeerIdentity moves (Security is already in PeerDropCore's deps).

### Widget impact

`PeerDropWidget` only imports `PeerDropPet` + framework UI. Zero Core touches. No widget changes needed.

---

## File Structure

**Move (30 source files):**
- 28 → `PeerDropKit/Sources/PeerDropCore/`
- 2 (`PeerIdentity` + `PeerMessage+Hello`) → `PeerDropKit/Sources/PeerDropSecurity/`

**Create:**
- `PeerDropKit/Sources/PeerDropPlatform/BackgroundTaskHandling.swift` (cross-platform protocol)
- `PeerDropKit/Sources/PeerDropPlatform/iOS/UIKitBackgroundTaskHandler.swift` (iOS adapter)
- `PeerDropKit/Sources/PeerDropPlatform/NoOpBackgroundTaskHandler.swift` (macOS / default adapter)

**Delete:**
- `PeerDropKit/Sources/PeerDropCore/PeerDropCore.swift` (M1d-1 placeholder enum)

**Modify:**
- `PeerDropKit/Package.swift` — PeerDropCore target gains `PeerDropPlatform` dep (already implicit but make explicit)
- `PeerDropKit/Sources/PeerDropPlatform/PlatformDependencies.swift` — register `BackgroundTaskHandling`
- `PeerDropKit/Sources/PeerDropPlatform/iOS/PlatformDependencies+iOS.swift` — wire iOS adapter
- `project.yml` — drop `- package: WebRTC` and `- package: ZIPFoundation` from main app target deps; keep them in `PeerDropKit/Package.swift`
- ~42 consumer files in PeerDrop/{App,UI}/ — add `import PeerDropCore` (and `import PeerDropSecurity` for the 3 PeerIdentity files)
- ~27 test files in PeerDropTests/ — switch to `@testable import PeerDropCore` where Core internals are needed
- `docs/superpowers/specs/2026-05-24-macos-port-design.md` §1 — update dependency graph diagram + final paragraph noting M1 train complete

---

## Task 1: Pre-Core audit

**Files:** (analysis only)

Same pattern as M1d-4 audit. Goal: full picture of consumers + verify no surprise cycles.

- [ ] **Step 1: Inventory + type lists**

```bash
ls PeerDrop/Core/ | wc -l   # expect 30
for f in PeerDrop/Core/*.swift; do
    echo "=== $(basename $f) ==="
    grep -E "^(public |internal |fileprivate |private |open |final |@MainActor )?(struct|class|enum|protocol|typealias|actor) " "$f" | head -5
done
```

- [ ] **Step 2: External consumer scan**

```bash
grep -rln "ConnectionManager\|ChatManager\|DeviceRecordStore\|DeviceGroupStore\|UserProfile\|InboxService\|ScreenshotModeProvider\|ConnectionMetrics\|ConnectionMetric\|ArchiveManager\|ChatMessage\|ClipboardSyncManager\|ConnectionContext\|ConnectionState\|DeviceGroup\b\|DeviceRecord\b\|ErrorReporter\|ImageCache\|NetworkFingerprint\|NotificationManager\|PeerConnection\b\|PeerIdentity\|PushNotificationManager\|RelaySession\|TailnetPeerEntry\|TailnetPeerStore\|PeerConnectionState" PeerDrop/App PeerDrop/UI --include="*.swift" 2>/dev/null | sort -u
```

Verify ~42 files (count may shift ±5 depending on what counts as a true reference vs. a doc comment).

- [ ] **Step 3: Test file consumer scan**

```bash
grep -rln "ConnectionManager\|ChatManager\|DeviceRecordStore\|DeviceGroupStore\|UserProfile\|InboxService\|ScreenshotModeProvider\|ConnectionMetrics\|ConnectionMetric\|ArchiveManager\|ChatMessage\|ClipboardSyncManager\|ConnectionContext\|ConnectionState\|DeviceGroup\b\|DeviceRecord\b\|ErrorReporter\|ImageCache\|NetworkFingerprint\|NotificationManager\|PeerConnection\b\|PeerIdentity\|PushNotificationManager\|RelaySession\|TailnetPeerEntry\|TailnetPeerStore\|PeerConnectionState" PeerDropTests --include="*.swift" 2>/dev/null | sort -u
```

Each test file may need `@testable import PeerDropCore` added (some will also keep `@testable import PeerDrop` for app-target wiring).

- [ ] **Step 4: Verify zero remaining WebRTC/ZIPFoundation direct imports in app target after Core moves**

```bash
# Pre-move (should currently only show RelaySession.swift)
grep -rln "^import WebRTC\|^@preconcurrency import WebRTC" PeerDrop --include="*.swift"
grep -rln "^import ZIPFoundation" PeerDrop --include="*.swift"
```

After RelaySession moves, both greps should return empty for `PeerDrop/` (the iOS app target dir). Confirms it's safe to drop direct deps in Task 8.

- [ ] **Step 5: UIApplication usage scan**

```bash
grep -n "UIApplication\|UIView\|UIImage\|UIColor\|UIDevice" PeerDrop/Core/*.swift
```

Expected: only ConnectionManager.swift lines 1588, 1599, 1610 (the background-task uses). If more surface, the BackgroundTaskHandling abstraction may need to widen.

- [ ] **Step 6: SwiftUI usage scan in stores**

```bash
grep -n "^import SwiftUI" PeerDrop/Core/*.swift
grep -n "@AppStorage\|Color\b\|View\b\|@StateObject\|@ObservedObject\|@EnvironmentObject" PeerDrop/Core/DeviceGroupStore.swift PeerDrop/Core/DeviceRecordStore.swift
```

Expected: no real SwiftUI types used in DeviceGroupStore + DeviceRecordStore (only `@Published`, which is Combine). If ConnectionManager has real SwiftUI usage, decide between `#if canImport(SwiftUI)` guards or a Combine-only refactor.

- [ ] **Step 7: No commit. Report findings.**

Output:
```
## Core migration audit

### Source inventory
- 30 in PeerDrop/Core/. Split: 28 → PeerDropCore, 2 → PeerDropSecurity.

### External consumer files
- App+UI: N files (expected ~42)
- Tests: M files (expected ~27)

### iOS-only API surface
- UIApplication background task: ConnectionManager only (3 sites)
- SwiftUI: <real use? none expected outside DeviceGroupStore/DeviceRecordStore unused imports>

### WebRTC + ZIPFoundation
- Direct imports in app target after RelaySession move: 0 confirmed
- Safe to drop both from project.yml

### Recommended Task ordering
1. Pre-move refactor: BackgroundTaskHandling Platform abstraction
2. Pre-move refactor: PeerIdentity + PeerMessage+Hello → PeerDropSecurity
3. Pre-move refactor: SwiftUI import → Combine in 2 store files
4. Move 28 Core sources + delete placeholder
5. Mark types public + Package.swift dep tweak
6. Add `import PeerDropCore` to ~42 consumers
7. Build + iterate
8. Commit
9. Drop unused direct deps (WebRTC + ZIPFoundation) from project.yml
10. Lint validation + spec §1 update
11. Final verification + tag
```

---

## Task 2: Pre-move refactor — BackgroundTaskHandling Platform abstraction

**Files:**
- Create: `PeerDropKit/Sources/PeerDropPlatform/BackgroundTaskHandling.swift`
- Create: `PeerDropKit/Sources/PeerDropPlatform/iOS/UIKitBackgroundTaskHandler.swift`
- Create: `PeerDropKit/Sources/PeerDropPlatform/NoOpBackgroundTaskHandler.swift`
- Modify: `PeerDropKit/Sources/PeerDropPlatform/PlatformDependencies.swift` (add `backgroundTaskHandler()` resolver)
- Modify: `PeerDropKit/Sources/PeerDropPlatform/iOS/PlatformDependencies+iOS.swift` (register iOS adapter)
- Modify: `PeerDrop/Core/ConnectionManager.swift:1583-1615` (replace UIApplication direct calls)

- [ ] **Step 1: Define BackgroundTaskHandling protocol**

Create `PeerDropKit/Sources/PeerDropPlatform/BackgroundTaskHandling.swift`:

```swift
import Foundation

/// Opaque background-task handle. iOS wraps `UIBackgroundTaskIdentifier`;
/// other platforms map to a sentinel `.invalid`.
public struct BackgroundTaskToken: Hashable {
    /// Sentinel for an invalid / never-started task.
    public static let invalid = BackgroundTaskToken(rawValue: 0)

    /// Platform-specific raw value (iOS: UIBackgroundTaskIdentifier.rawValue).
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Cross-platform background-task lifecycle. iOS implementation wraps
/// `UIApplication.beginBackgroundTask`. macOS implementation is a no-op
/// (the OS doesn't suspend foreground apps the same way; long-running
/// work runs without the special API).
@MainActor
public protocol BackgroundTaskHandling: AnyObject {
    /// Request additional time to finish work when the app is about to
    /// suspend. `expirationHandler` runs when the OS is about to forcibly
    /// end the task — the caller MUST call `end(_:)` from within it.
    func begin(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken

    /// Release the background-task token. No-op for `.invalid`.
    func end(_ token: BackgroundTaskToken)

    /// Remaining time before the OS forcibly ends the current task.
    /// macOS returns `.infinity`.
    var backgroundTimeRemaining: TimeInterval { get }
}
```

- [ ] **Step 2: Create no-op (macOS) adapter**

Create `PeerDropKit/Sources/PeerDropPlatform/NoOpBackgroundTaskHandler.swift`:

```swift
import Foundation

/// No-op `BackgroundTaskHandling` adapter for platforms where the OS
/// doesn't suspend foreground apps via the iOS background-task API
/// (currently macOS). All operations succeed trivially; remaining time
/// is `.infinity` so callers that compare against thresholds short-
/// circuit to "still have time."
@MainActor
public final class NoOpBackgroundTaskHandler: BackgroundTaskHandling {
    public init() {}

    public func begin(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
        BackgroundTaskToken(rawValue: 1) // any non-invalid value
    }

    public func end(_ token: BackgroundTaskToken) {
        // No-op.
    }

    public var backgroundTimeRemaining: TimeInterval { .infinity }
}
```

- [ ] **Step 3: Create iOS adapter**

Create `PeerDropKit/Sources/PeerDropPlatform/iOS/UIKitBackgroundTaskHandler.swift`:

```swift
#if os(iOS)
import Foundation
import UIKit

@MainActor
public final class UIKitBackgroundTaskHandler: BackgroundTaskHandling {
    public init() {}

    public func begin(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
        let id = UIApplication.shared.beginBackgroundTask(withName: "PeerDrop") {
            expirationHandler()
        }
        return BackgroundTaskToken(rawValue: id.rawValue)
    }

    public func end(_ token: BackgroundTaskToken) {
        guard token != .invalid else { return }
        let id = UIBackgroundTaskIdentifier(rawValue: token.rawValue)
        UIApplication.shared.endBackgroundTask(id)
    }

    public var backgroundTimeRemaining: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
}
#endif
```

- [ ] **Step 4: Register in PlatformDependencies**

Edit `PeerDropKit/Sources/PeerDropPlatform/PlatformDependencies.swift` — add a `backgroundTaskHandler()` factory method to the resolver protocol, mirroring how `audioSession()` is wired. Keep the default to `NoOpBackgroundTaskHandler`.

- [ ] **Step 5: Wire iOS adapter**

Edit `PeerDropKit/Sources/PeerDropPlatform/iOS/PlatformDependencies+iOS.swift` — return `UIKitBackgroundTaskHandler()` inside `#if os(iOS)`.

- [ ] **Step 6: Refactor ConnectionManager to use the protocol**

In `PeerDrop/Core/ConnectionManager.swift`:
- Add `private lazy var backgroundTaskHandler: BackgroundTaskHandling = PlatformDependencies.shared.backgroundTaskHandler()` near the other lazy properties.
- Replace `backgroundTaskID = UIApplication.shared.beginBackgroundTask { ... }` with `backgroundTaskToken = backgroundTaskHandler.begin(expirationHandler: { ... })`.
- Replace `UIApplication.shared.endBackgroundTask(backgroundTaskID)` with `backgroundTaskHandler.end(backgroundTaskToken)`.
- Replace `UIApplication.shared.backgroundTimeRemaining` with `backgroundTaskHandler.backgroundTimeRemaining`.
- Rename stored property `backgroundTaskID: UIBackgroundTaskIdentifier?` → `backgroundTaskToken: BackgroundTaskToken = .invalid`.
- Drop `import UIKit` from ConnectionManager.swift.

- [ ] **Step 7: Build verify (in current location)**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`. ConnectionManager no longer references UIApplication directly.

- [ ] **Step 8: Test verify**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

Expected: ~635 tests pass (same count as M1d-4 baseline).

- [ ] **Step 9: Commit**

```bash
git add PeerDropKit/Sources/PeerDropPlatform/ PeerDrop/Core/ConnectionManager.swift
git commit -m "$(cat <<'EOF'
refactor(m1d-5): introduce BackgroundTaskHandling Platform abstraction

ConnectionManager's three iOS-only UIApplication background-task
calls (begin / end / backgroundTimeRemaining) now go through a
BackgroundTaskHandling protocol in PeerDropPlatform. iOS gets the
UIKitBackgroundTaskHandler wrapper; macOS / default gets a no-op
handler (.infinity remaining time, trivial begin/end).

Last UIKit dependency in PeerDrop/Core/ is gone — Core is ready to
migrate into PeerDropKit/Sources/PeerDropCore/ in M1d-5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Pre-move refactor — Move PeerIdentity + PeerMessage+Hello into PeerDropSecurity

**Files:**
- Move: `PeerDrop/Core/PeerIdentity.swift` → `PeerDropKit/Sources/PeerDropSecurity/PeerIdentity.swift`
- Move: `PeerDrop/Core/PeerMessage+Hello.swift` → `PeerDropKit/Sources/PeerDropSecurity/PeerMessage+Hello.swift`
- Modify: 3 UI consumers (add `import PeerDropSecurity`)
- Modify: ~25 test files (most already `@testable import PeerDrop`; PeerIdentity now visible after `@testable import PeerDropSecurity`)

- [ ] **Step 1: Move both files**

```bash
git mv PeerDrop/Core/PeerIdentity.swift PeerDropKit/Sources/PeerDropSecurity/PeerIdentity.swift
git mv PeerDrop/Core/PeerMessage+Hello.swift PeerDropKit/Sources/PeerDropSecurity/PeerMessage+Hello.swift
```

- [ ] **Step 2: Mark `PeerIdentity` public**

Edit `PeerDropKit/Sources/PeerDropSecurity/PeerIdentity.swift`:
- Change `struct PeerIdentity:` → `public struct PeerIdentity:`
- Mark all stored properties `public`
- Mark both `init`s `public`
- Mark `static var current`, `static func local(_:)`, `private static let localIDKey` accessors as appropriate.

Note: `PeerIdentity` already imports `PeerDropPlatform` (for `PlatformDependencies.shared.deviceName()`). Keep that.

- [ ] **Step 3: Mark factories on `PeerMessage+Hello` public**

Edit `PeerDropKit/Sources/PeerDropSecurity/PeerMessage+Hello.swift`:
- Change `static func hello(identity:)` → `public static func hello(identity:)`
- Change `static func secureHandshake(bundle:senderID:)` → `public static func secureHandshake(bundle:senderID:)`

The extension's `PeerMessage` host is in `PeerDropProtocol`. Adding `public` to factory methods inside an `extension PeerMessage` declared in PeerDropSecurity is allowed — Swift permits extension methods of any access level on a public type.

- [ ] **Step 4: Add `import PeerDropSecurity` to 3 UI consumers**

```bash
for f in PeerDrop/UI/Chat/GroupChatView.swift \
         PeerDrop/UI/Chat/GroupReadReceiptView.swift \
         PeerDrop/UI/Security/RemoteInviteView.swift; do
    if ! grep -q "^import PeerDropSecurity" "$f"; then
        awk 'BEGIN{added=0} /^import / && !added { print; print "import PeerDropSecurity"; added=1; next } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
done
```

- [ ] **Step 5: Update the TrustedContact comment**

In `PeerDropKit/Sources/PeerDropSecurity/TrustedContact.swift:6`, the existing comment `// Stable peer device ID (PeerIdentity.id)` is now accurate without the "currently in Core" caveat — no edit required, but verify the comment still reads correctly.

- [ ] **Step 6: Build verify**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep -E "error:" | head -10
cd PeerDropKit && swift build 2>&1 | grep -E "error:" | head -10 && cd ..
```

Iterate on errors (typically: more files need `import PeerDropSecurity`, or some symbol's access level needs raising).

- [ ] **Step 7: Test verify**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
cd PeerDropKit && swift test 2>&1 | grep "Executed " | tail -2 && cd ..
```

Expected: iOS ~635, SPM 614 — same counts.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-5): move PeerIdentity + PeerMessage+Hello into PeerDropSecurity

PeerIdentity has always belonged in PeerDropSecurity per the original
spec — it carries the device's `IdentityKeyManager.shared.publicKey`
and is the canonical identity stamp on every PeerMessage. M1d-2 left
it in PeerDrop/Core/ to avoid expanding scope; M1d-5 is the natural
place to finish the move.

PeerMessage+Hello.swift travels with PeerIdentity because both
remaining factories (`hello(identity:)`, `secureHandshake(bundle:
senderID:)`) reference Security types. The fileOffer + batchStart
factories already moved to PeerMessage+FileTransfer.swift in
PeerDropTransport in M1d-4.

3 UI consumers gain `import PeerDropSecurity`. No semantic changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Pre-move refactor — Replace gratuitous `import SwiftUI` in stores

**Files:**
- Modify: `PeerDrop/Core/DeviceGroupStore.swift:1`
- Modify: `PeerDrop/Core/DeviceRecordStore.swift:1`

- [ ] **Step 1: Replace import**

For each file, change `import SwiftUI` → `import Combine` if SwiftUI is unused (per Task 1 Step 6 audit confirming no SwiftUI types remain). If audit found real SwiftUI usage, add a `#if canImport(SwiftUI)` guard instead.

- [ ] **Step 2: Build verify**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add PeerDrop/Core/DeviceGroupStore.swift PeerDrop/Core/DeviceRecordStore.swift
git commit -m "$(cat <<'EOF'
refactor(m1d-5): replace gratuitous import SwiftUI with import Combine

DeviceGroupStore + DeviceRecordStore use `@Published` (Combine) — no
SwiftUI types. The `import SwiftUI` was unnecessary and would force
the PeerDropCore SPM module to pull in SwiftUI on macOS for no
purpose.

ConnectionManager.swift still imports SwiftUI because it owns several
`@Published` properties consumed by SwiftUI Views via @StateObject —
that one stays.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Move 28 Core source files into PeerDropCore

**Files:**
- Move: 28 .swift files from `PeerDrop/Core/` → `PeerDropKit/Sources/PeerDropCore/`
- Delete: `PeerDropKit/Sources/PeerDropCore/PeerDropCore.swift` (M1d-1 placeholder)
- Verify: `PeerDrop/Core/` directory is empty after the move and can be removed

- [ ] **Step 1: Move all 28 files**

```bash
for f in PeerDrop/Core/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropCore/
done
rmdir PeerDrop/Core 2>/dev/null
ls PeerDropKit/Sources/PeerDropCore/ | wc -l  # expect 29 (28 moved + placeholder)
```

- [ ] **Step 2: Delete placeholder**

```bash
git rm PeerDropKit/Sources/PeerDropCore/PeerDropCore.swift
ls PeerDropKit/Sources/PeerDropCore/ | wc -l  # expect 28
```

- [ ] **Step 3: Verify Core directory is gone**

```bash
ls PeerDrop/Core 2>&1  # should error: No such file or directory
find PeerDropKit/Sources/PeerDropCore -name "*.swift" | wc -l  # 28
```

- [ ] **Step 4: Don't build yet — Tasks 6 + 7 need to land for build**

---

## Task 6: Update Package.swift deps + mark types public

**Files:**
- Modify: `PeerDropKit/Package.swift` — PeerDropCore target adds `PeerDropPlatform`
- Modify: 28 PeerDropCore source files (public upgrades, iterating on build errors)

- [ ] **Step 1: Add PeerDropPlatform to PeerDropCore deps**

Edit `PeerDropKit/Package.swift`. PeerDropCore target:

```swift
.target(
    name: "PeerDropCore",
    dependencies: [
        "PeerDropPlatform",
        "PeerDropTransport",
        "PeerDropSecurity",
        "PeerDropProtocol",
        "PeerDropPet",
    ]
),
```

- [ ] **Step 2: First SPM build pass**

```bash
cd PeerDropKit && swift build --target PeerDropCore 2>&1 | grep "error:" | head -20 && cd ..
```

Expected errors (categorize by type, similar to M1d-4 iteration):
- "method must be declared public because it matches a requirement in public protocol X" — protocol conformance methods (e.g. CallProvider's expiry handler, ObservableObject delegate methods on stores)
- "type cannot be declared public because its parameter uses an internal type" — need to make nested types public
- "property cannot be declared public because its type uses an internal type" — same fix
- "initializer 'init(from:)' must be declared public because it matches a requirement in public protocol 'Decodable'" — public init needed on Codable structs

- [ ] **Step 3: Iterative public-marking pass**

Use the same sed pattern as M1d-4 Task 3 (proven). Generate the error-location list once, apply once, then iterate:

```bash
cd PeerDropKit && swift build --target PeerDropCore 2>&1 | grep -oE "/Volumes/[^:]+\.swift:[0-9]+" | sort -u > /tmp/core_error_locs.txt && cd ..
wc -l /tmp/core_error_locs.txt

while IFS=: read -r path lineno; do
    /usr/bin/sed -E -i '' "${lineno}s/^([[:space:]]*)((static |@MainActor |nonisolated |@Published |@objc )?)(var |let |func |init|class |convenience init|override init|required init)/\1public \2\4/" "$path"
done < /tmp/core_error_locs.txt
```

Rebuild and repeat for 2–4 iterations. Each round shrinks the error list. M1d-4 took 3 iterations from 577 → 33 → 4 → 0.

- [ ] **Step 4: Add explicit public inits to public Codable structs**

For structs that synthesize `init(from:)` for Codable but need a memberwise public init for cross-module construction (typically `Chat
Message`, `ConnectionMetric`, `DeviceGroup`, `DeviceRecord`, `TailnetPeerEntry`, `UserProfile`, `ConnectionContext`), add explicit memberwise initializers (same pattern as M1d-4's `ProofOfWorkToken` / `MailboxMessage` fix).

- [ ] **Step 5: Mark Codable enums public**

`ConnectionState`, `PeerConnectionState`, and other small enums need `public enum X: Codable` (the existing `enum X` keeps Swift from synthesizing public conformance).

- [ ] **Step 6: Verify full SPM build**

```bash
cd PeerDropKit && swift build 2>&1 | tail -3 && cd ..
```

Expected: `Build complete!`

---

## Task 7: Add `import PeerDropCore` to consumers

**Files:**
- Modify: ~42 consumer files in `PeerDrop/App/` + `PeerDrop/UI/`
- Modify: ~27 test files in `PeerDropTests/` (switch from `@testable import PeerDrop` to also include `@testable import PeerDropCore` where needed)

- [ ] **Step 1: Generate consumer list**

```bash
grep -rln "ConnectionManager\|ChatManager\|DeviceRecordStore\|DeviceGroupStore\|UserProfile\|InboxService\|ScreenshotModeProvider\|ConnectionMetrics\|ConnectionMetric\|ArchiveManager\|ChatMessage\|ClipboardSyncManager\|ConnectionContext\|ConnectionState\|DeviceGroup\b\|DeviceRecord\b\|ErrorReporter\|ImageCache\|NetworkFingerprint\|NotificationManager\|PeerConnection\b\|PushNotificationManager\|RelaySession\|TailnetPeerEntry\|TailnetPeerStore\|PeerConnectionState" PeerDrop/App PeerDrop/UI --include="*.swift" 2>/dev/null | sort -u > /tmp/core_consumers.txt
wc -l /tmp/core_consumers.txt   # expect ~42
```

- [ ] **Step 2: Bulk-insert `import PeerDropCore`**

```bash
while IFS= read -r f; do
    if ! grep -q "^import PeerDropCore" "$f"; then
        awk 'BEGIN{added=0} /^import / && !added { print; print "import PeerDropCore"; added=1; next } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
done < /tmp/core_consumers.txt
```

- [ ] **Step 3: Test-file imports**

For each test file that already has `@testable import PeerDrop`, decide whether it still needs the app-target testable import (e.g. tests of UI integration that exercise internal app-only types) or can switch to `@testable import PeerDropCore`. Conservative default: add `@testable import PeerDropCore` *alongside* `@testable import PeerDrop` and let the compiler resolve.

```bash
grep -rln "ConnectionManager\|ChatManager\|DeviceRecordStore\|DeviceGroupStore\|UserProfile\|InboxService" PeerDropTests --include="*.swift" | while read -r f; do
    if grep -q "^@testable import PeerDrop$" "$f" && ! grep -q "import PeerDropCore" "$f"; then
        awk 'BEGIN{added=0} /^@testable import PeerDrop$/ && !added { print "@testable import PeerDropCore"; print; added=1; next } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
done
```

---

## Task 8: Build + iterate

- [ ] **Step 1: xcodegen + iOS build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep -E "error:" | sort -u | head -20
```

Common remaining issues:
- A consumer file references a Core symbol that's still internal (raise to `public`)
- A `private(set)` `@Published` property exposed via SwiftUI binding requires `public private(set)` (set scope must match getter scope or be tighter)
- Missing `import PeerDropCore` on a file the audit didn't catch (e.g. test helper that uses a Core type via a transient param)

- [ ] **Step 2: Iterate**

Same iteration pattern as M1d-4 Tasks 3+5: surface error → identify access-level fix → apply → rebuild. Budget 30 minutes of iteration.

- [ ] **Step 3: Test verify (both sides)**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
cd PeerDropKit && swift test 2>&1 | grep "Executed " | tail -2 && cd ..
```

Expected:
- iOS: ~635 (same as M1d-4 baseline)
- SPM: 614+ (placeholder PeerDropCoreTests will start running real coverage as test target gains content; up to migrator's discretion whether to backfill core tests in this PR)

---

## Task 9: Commit (Tasks 5-8 combined)

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-5): migrate Core into PeerDropCore SPM module (28 files)

28 source files moved out of PeerDrop/Core/ into
PeerDropKit/Sources/PeerDropCore/. The M1d-1 placeholder enum is
deleted. PeerDrop/Core/ directory removed.

PeerDropCore target gains explicit PeerDropPlatform dep (already
transitively needed via PeerIdentity in M1d-3a; now mandatory for
ConnectionManager's BackgroundTaskHandling consumption).

~N types/methods marked public for cross-module access. Highlights:
  - Public ObservableObject classes: ConnectionManager (the keystone),
    ChatManager, DeviceRecordStore, DeviceGroupStore, InboxService,
    ScreenshotModeProvider, NotificationManager, PushNotificationManager,
    PeerConnection, RelaySession, ArchiveManager, ConnectionMetrics
  - Public value types: ChatMessage, ConnectionState, ConnectionContext,
    ConnectionMetric, DeviceRecord, DeviceGroup, PeerConnectionState,
    TailnetPeerEntry, UserProfile, NetworkFingerprint
  - Public Codable structs gained explicit memberwise public inits
    (same pattern as M1d-4's MailboxMessage / ProofOfWorkToken fix)

~42 consumer files in PeerDrop/{App,UI}/ gained `import PeerDropCore`.
~27 test files updated to also `@testable import PeerDropCore`.

iOS app builds. iOS test suite: ~635 tests pass. SPM swift test:
614+ pass. After M1d-5, only thin shell remains in PeerDrop/ —
App/, UI/, Pet renderer UI, plus AppDelegate / SceneDelegate /
PeerDropApp / CallKitManager / a few extension files.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Drop unused direct deps from project.yml

**Files:**
- Modify: `project.yml` (remove `- package: WebRTC` and `- package: ZIPFoundation` from main app target deps; remove the `WebRTC:` and `ZIPFoundation:` entries from top-level `packages:` block)

- [ ] **Step 1: Verify zero direct imports after migration**

```bash
grep -rln "^import WebRTC\|^@preconcurrency import WebRTC" PeerDrop --include="*.swift" 2>/dev/null
grep -rln "^import ZIPFoundation" PeerDrop --include="*.swift" 2>/dev/null
```

Both should return empty (`PeerDrop/Core/RelaySession.swift` is now under `PeerDropKit/Sources/PeerDropCore/` — outside the scan path).

- [ ] **Step 2: Edit project.yml**

Remove these lines from the main `PeerDrop` target dependencies:
```yaml
- package: WebRTC
- package: ZIPFoundation
```

Remove these entries from top-level `packages:`:
```yaml
WebRTC:
  url: https://github.com/stasel/WebRTC
ZIPFoundation:
  url: https://github.com/weichsel/ZIPFoundation
```

Keep them only in `PeerDropKit/Package.swift` where they remain pinned for the SPM targets.

If the widget target separately depends on `package: ZIPFoundation`, leave that one in place (verify via `grep "package: ZIPFoundation" project.yml`).

- [ ] **Step 3: Regenerate + verify build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`. The transitive deps from PeerDropKit (which has them in its `Package.swift`) keep WebRTC + ZIPFoundation available to the app via the PeerDropTransport + PeerDropPet linkage.

- [ ] **Step 4: Test verify**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

Expected: ~635 tests pass.

- [ ] **Step 5: Commit**

```bash
git add project.yml PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
chore(m1d-5): drop now-unused WebRTC + ZIPFoundation direct deps

After Core migration into PeerDropCore (and Transport into
PeerDropTransport in M1d-4), the iOS app target has zero direct
`import WebRTC` / `import ZIPFoundation` calls. Both packages
reach the app target transitively via `package: PeerDropKit`
(WebRTC via PeerDropTransport, ZIPFoundation via PeerDropPet).

Drops 2 direct deps + 2 top-level package entries from project.yml.
Pinned versions remain in PeerDropKit/Package.swift where the SPM
targets consume them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Final lint validation + spec §1 update

**Files:**
- Modify: `.github/workflows/ci.yml` — verify lint scope is correct (M1d-4 already broadened to PeerDropKit/Sources)
- Modify: `docs/superpowers/specs/2026-05-24-macos-port-design.md` §1 — update final dependency graph + "M1 train done" note

- [ ] **Step 1: Run lint-imports locally**

```bash
violations=""
while IFS= read -r file; do
    while IFS= read -r line_no; do
        prev=$(sed -n "$((line_no - 1))p" "$file" 2>/dev/null | tr -d '[:space:]')
        if [ "$prev" != "#ifos(iOS)" ] && \
           [ "$prev" != "#ifcanImport(UIKit)" ] && \
           [ "$prev" != "#ifcanImport(AppKit)" ] && \
           [ "$prev" != "#ifcanImport(WidgetKit)" ] && \
           [ "$prev" != "#elseifcanImport(UIKit)" ] && \
           [ "$prev" != "#elseifcanImport(AppKit)" ] && \
           [ "$prev" != "#elseifcanImport(WidgetKit)" ] && \
           [ "$prev" != "#elseifos(iOS)" ]; then
          violations+="$file:$line_no: $(sed -n "${line_no}p" "$file")"$'\n'
        fi
    done < <(grep -n -E "^import (UIKit|AppKit|WidgetKit)" "$file" | cut -d: -f1)
done < <(find PeerDrop/Core PeerDrop/Pet PeerDropKit/Sources -name "*.swift" -not -path "*/Platform/iOS/*" -not -path "*/Pet/UI/*")
if [ -n "$violations" ]; then echo "VIOLATIONS:"; echo "$violations"; else echo "Clean"; fi
```

Expected: `Clean`. (After Task 2, ConnectionManager no longer imports UIKit; after Task 5, the few remaining Core-side UIKit references — should be zero — are gone too.)

- [ ] **Step 2: Update spec §1 dependency graph**

Edit `docs/superpowers/specs/2026-05-24-macos-port-design.md` §1 (find the dependency graph paragraph / diagram). Update to reflect the final state:

```
PeerDropPlatform (leaf — Foundation only + iOS adapters)
├── PeerDropProtocol (leaf)
├── PeerDropSecurity (deps: PeerDropProtocol)
├── PeerDropPet (deps: PeerDropPlatform, PeerDropProtocol, ZIPFoundation)
├── PeerDropTransport (deps: PeerDropPlatform, PeerDropProtocol, PeerDropSecurity, WebRTC)
└── PeerDropCore (deps: all 5 modules above — the keystone)

PeerDrop app target (iOS) deps: PeerDropKit (all 6 products via .package(path:))
PeerDropWidget target (iOS) deps: PeerDropPet only
PeerDrop-macOS app target (M2): PeerDropKit (all 6 products)
```

Note that `M1 train complete` on the schedule, and remove the "Open Items for M1d-5" section now that they're done.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml docs/superpowers/specs/2026-05-24-macos-port-design.md
git commit -m "$(cat <<'EOF'
docs(m1d-5): final M1 wrap-up — spec dependency graph + lint validation

Updates the §1 dependency graph diagram to reflect the final M1
shape (6 SPM modules, app target reduces to UI shell + AppDelegate
+ a handful of iOS-specific files). Removes the "Open Items for
M1d-5" section since all are now done.

lint-imports local run is clean across PeerDrop/Core/, PeerDrop/Pet/
(non-UI), and PeerDropKit/Sources/. The PeerDrop/Core/ scan path is
preserved in CI even though the directory is now empty — keeps the
guard active if Core stuff ever re-emerges in the iOS-only layer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Final verification + tag

- [ ] **Step 1: Full test sweep**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
cd PeerDropKit && swift test 2>&1 | grep "Executed " | tail -2 && cd ..
```

Expected: iOS ~635 / 0 failures; SPM 614+ / 0 failures.

- [ ] **Step 2: Verify directory shape**

```bash
ls PeerDrop/   # expect: App, Pet, UI, project structure files; NO Core, Transport, Discovery, Voice, Extensions
ls PeerDrop/Core 2>&1   # expect: directory does not exist
ls PeerDrop/Extensions 2>&1   # expect: directory does not exist
find PeerDropKit/Sources -maxdepth 2 -type d | sort
# expect: PeerDropCore, PeerDropPet, PeerDropPlatform, PeerDropProtocol, PeerDropSecurity, PeerDropTransport
```

- [ ] **Step 3: Tag**

```bash
git tag -a m1d-5-core-migration -m "M1d-5 done: PeerDropCore migrated (28 files). PeerIdentity + PeerMessage+Hello relocated to PeerDropSecurity. BackgroundTaskHandling abstraction for iOS UIApplication. WebRTC + ZIPFoundation direct deps dropped from app target. M1 train complete — iOS app target is a thin shell over PeerDropKit."
```

- [ ] **Step 4: Push and open PR**

Follow the same flow as M1d-4 (push to `feat/m1d-5-core-migration`, open PR via `gh pr create`). Summary should call out:
- 28 files migrated
- PeerIdentity finally home in Security
- BackgroundTaskHandling protocol (covers macOS port readiness)
- 2 direct app-target deps dropped
- Lint validation clean
- M1 train done — M2 (macOS UI shell) is now unblocked

---

## Done

After M1d-5: every SPM module has real content. PeerDrop/ contains only App/ (AppDelegate, PeerDropApp, CallKitManager, Info.plist, entitlements, Assets), UI/ (SwiftUI views), and Pet/ (Pet UI/widget bridging). The iOS app target is essentially a thin presentation layer over PeerDropKit — the macOS port (M2) can now stand up a parallel app target consuming the same PeerDropKit products with no source-code duplication.

## Lessons from M1d-4 that apply here

1. **Plan estimates undercount cross-leaf refs.** M1d-4 plan only flagged PeerIdentity; actual audit found 5 Core types referenced by Transport. Don't trust the plan's count — re-audit with `grep` before estimating effort.
2. **Bulk public-marking via sed is the proven pattern.** M1d-4 went 577 → 33 → 4 → 0 errors in 3 iterations. PeerDropCore will likely take 4-5 because it's larger and has more public-protocol conformances (ObservableObject, Identifiable, Codable, Equatable, Hashable).
3. **`Codable` structs need explicit memberwise public inits.** Swift synthesizes `init(from:)` but not the memberwise init for cross-module use. M1d-4's `MailboxMessage` / `ProofOfWorkToken` fix repeats here for ~10 Core types.
4. **`@Published private(set) var` becomes `@Published public private(set) var`** — set-scope must match get-scope or be tighter.
5. **Test files: prefer `@testable import` alongside, not instead.** Some tests genuinely need both app-target internal access (for AppDelegate / UI integration) and Core internal access. Don't force a choice.

## Open Items After M1d-5

None — M1 train is done. Next milestone is M2 (macOS UI shell).
