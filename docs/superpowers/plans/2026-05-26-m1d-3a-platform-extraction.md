# M1d-3a — PeerDropPlatform Module Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `PeerDrop/Core/Platform/` (17 files) + `PeerDrop/Core/HapticManager.swift` (1 file) into a NEW `PeerDropPlatform` module — a 6th product in PeerDropKit, MORE foundational than the 4 existing leaves (Protocol, Security, Pet, Transport, Core). After M1d-3a: PeerDropPlatform is independently buildable, all 10+ consumers across Pet/Transport/UI/Core gain `import PeerDropPlatform`, and the cycle that was blocking Pet migration is resolved. NO Pet or Core source migration happens here — that's M1d-3b and M1d-5.

**Architecture:** PeerDropKit gains a 6th product. New dependency graph (updates spec §1):
```
                ┌────────────────┐
PeerDropPlatform ← consumed by:  │
                ↑                ↓
                PeerDropPet ────┐
                PeerDropSecurity ─┐
                PeerDropProtocol ─┼─→ PeerDropCore ─→ (app targets)
                PeerDropTransport ┘
```
PeerDropPlatform is a leaf with only Foundation/CoreGraphics/UIKit/AVFoundation deps. Pet, Transport, Core all depend on it.

**Tech Stack:** Swift 5.9, iOS 16+, macOS 14+, XcodeGen 2.45.4. Builds: `xcodebuild` (iOS app) + `swift build`/`swift test` (PeerDropKit).

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1d-3a.

**Predecessors (all merged):** M0, M1a, M1b, triage, M1c, M1d-1, M1d-2.

**Investigation findings:**
- **Source to move:** 18 files
  - 10 top-level in `PeerDrop/Core/Platform/`: PlatformDependencies, PlatformImage, PlatformGraphicsRenderer, PlatformPasteboard, HapticFeedback, DeviceNameProvider, SystemInfoProvider, RemoteNotificationRegistering, CallProvider, AudioSessionConfiguring
  - 7 in `PeerDrop/Core/Platform/iOS/`: UIKitPasteboard, UIKitHapticFeedback, UIKitDeviceNameProvider, UIKitSystemInfoProvider, UIKitRemoteNotificationRegistering, UIKitAudioSession, UIKitGraphicsRenderer
  - 1 in `PeerDrop/Core/`: HapticManager.swift (static facade, depends on PlatformDependencies + HapticFeedback)
- **Tests to move:** 5 files in `PeerDropTests/Core/Platform/`
- **Consumers across the codebase:**
  - HapticManager called from: Transport/FileTransfer, Transport/FileTransferSession, UI/Discovery/DiscoveryView, UI/Discovery/NearbyTab, UI/Transfer/ClipboardShareView, Pet/Engine/PetEngine (already deferred to M1d-3b), Core/ClipboardSyncManager, Core/PushNotificationManager, etc.
  - PlatformImage / PlatformColor (typealiases): used by Core/ImageCache + Pet/Renderer/* (deferred to M1d-3b) + UI/* (e.g., chat image rendering)
  - PlatformGraphicsRenderer / platformCGImage: used by Pet/Renderer/PetRendererV3 (deferred to M1d-3b)
  - PlatformDependencies.shared: used by ClipboardSyncManager (via init), PushNotificationManager, ErrorReporter, UserProfile, PeerIdentity, ArchiveManager, ConnectionManager (all Core), PeerDropApp (App)
  - HapticFeedback / CallProvider / etc. protocols themselves: directly referenced by Core code + AppDelegate
- **External consumers count:** ~15+ files across Core/Transport/UI/App will need `import PeerDropPlatform`. Pet consumers (PetEngine + Pet/Renderer/*) ALSO need it, but those files stay in app target for M1d-3a — they'll get the import naturally since they're in the app target which consumes PeerDropPlatform.

**Critical design decisions for this plan:**

1. **HapticManager.swift moves with the Platform/ files** — it's a facade over the HapticFeedback protocol, conceptually a platform concern.
2. **MockPlatformDependencies.swift** is a test fixture defining mocks for all 7 protocols + injection-test classes. It moves into PeerDropPlatformTests as part of test migration. After move, app-target tests (`PeerDropTests`) that use these mocks need to `@testable import PeerDropPlatform`.
3. **Existing iOS test count drops** as 5 Platform tests move out of `xcodebuild test` and into `swift test`. Net total preserved.
4. **PeerDropPlatform's Package.swift declaration** needs careful platform handling: it imports UIKit on iOS, AppKit on macOS — but Package.swift platforms declaration is `[.iOS(.v16), .macOS(.v14)]` so SPM handles per-platform compilation. The `#if canImport(UIKit)` gates from M0/M1a/M1b/M1d-1 (already in the Platform files) make this work.

---

## File Structure

**New files (1):**
- (None — placeholder PeerDropPlatform.swift not needed since real files arrive immediately. But we DO add a Package.swift product entry.)

**Move (18 source + 5 test):**
- 17 files: `PeerDrop/Core/Platform/*.swift` → `PeerDropKit/Sources/PeerDropPlatform/` (preserving `iOS/` subdir)
- 1 file: `PeerDrop/Core/HapticManager.swift` → `PeerDropKit/Sources/PeerDropPlatform/HapticManager.swift`
- 5 files: `PeerDropTests/Core/Platform/*.swift` → `PeerDropKit/Tests/PeerDropPlatformTests/`

**Modify:**
- `PeerDropKit/Package.swift` — add `.library(name: "PeerDropPlatform", ...)` product, `.target(name: "PeerDropPlatform")`, `.testTarget(name: "PeerDropPlatformTests")`. Pet/Transport/Core/Protocol/Security targets may need PeerDropPlatform added to dependencies once they consume it (Pet in M1d-3b, others later).
- `project.yml` — PeerDrop + PeerDropTests targets gain `package: PeerDropKit / product: PeerDropPlatform`.
- ~15 consumer files across PeerDrop/ — add `import PeerDropPlatform`.
- Possibly `PeerDropKit/Tests/PeerDropCoreTests/PeerDropCoreTests.swift` — placeholder may reference `PlatformDependencies.self` from M1d-1; that ref now belongs in PeerDropPlatformTests.

---

## Task 1: Pre-extraction audit

**Files:** (analysis only)

Goal: list every file that calls into Platform/ types so Task 4 knows where to add imports.

- [ ] **Step 1: Inventory Platform/ types**

```bash
ls PeerDrop/Core/Platform/
ls PeerDrop/Core/Platform/iOS/
```

Confirm 17 files (10 top-level + 7 iOS adapters).

- [ ] **Step 2: Find all consumers of HapticManager**

```bash
grep -rln "HapticManager\." PeerDrop/ --include="*.swift" | grep -v "/Pet/" | sort -u
```

Each match is a file that will need `import PeerDropPlatform` after Task 4. List them.

- [ ] **Step 3: Find all consumers of PlatformDependencies, PlatformImage/Color, PlatformGraphicsRenderer, and the 7 protocols**

```bash
grep -rln "PlatformDependencies\|PlatformImage\|PlatformColor\|PlatformGraphicsRenderer\|HapticFeedback\b\|PlatformPasteboard\|DeviceNameProvider\|SystemInfoProvider\|RemoteNotificationRegistering\|CallProvider\|AudioSessionConfiguring\|AudioSessionCategory\|CallEndReason" PeerDrop/ --include="*.swift" | grep -v "/Core/Platform/" | grep -v "/Pet/" | grep -v "PeerDropKit/" | sort -u
```

Note that Pet/ matches are deferred (M1d-3b). For M1d-3a, focus on non-Pet consumers.

For each match, note WHICH Platform type it uses (informs whether the import is needed in that file).

- [ ] **Step 4: Inventory tests**

```bash
ls PeerDropTests/Core/Platform/
```

Expected: 5 files (PlatformDependenciesTests, PlatformImageTests, PlatformGraphicsRendererTests, MockPlatformDependencies, CallProviderTests).

- [ ] **Step 5: Identify which test files outside Core/Platform/ use the mocks**

```bash
grep -rln "MockPlatformDependencies\|MockHaptics\|MockPasteboard\|MockDeviceNameProvider\|MockSystemInfoProvider\|MockRemoteNotificationRegistering\|MockCallProvider\|MockAudioSession\|PlatformDependencies\.mock" PeerDropTests/ | grep -v "/Core/Platform/" | sort -u
```

These tests will need `@testable import PeerDropPlatform` after Task 6.

- [ ] **Step 6: No commit. Report findings.**

Output:
```
## Platform extraction audit

### Source files
- 17 files in PeerDrop/Core/Platform/ (10 top-level + 7 iOS adapters)
- 1 file at PeerDrop/Core/HapticManager.swift
- Total: 18 source files

### Test files
- 5 files in PeerDropTests/Core/Platform/

### HapticManager consumers (non-Pet)
- N files: <list>

### Other Platform/ type consumers (non-Pet)
- M files: <list with which type used>

### Test files using mocks (outside Core/Platform/)
- K files: <list>

### Estimated total consumer files needing `import PeerDropPlatform`
- Production: M + ~5 (HapticManager callers) = ~N
- Test: K
```

---

## Task 2: Create PeerDropPlatform package + placeholder

**Files:**
- Create: `PeerDropKit/Sources/PeerDropPlatform/` directory (empty until Task 3)
- Modify: `PeerDropKit/Package.swift` — add product + target + testTarget entries

- [ ] **Step 1: Add to Package.swift**

Edit `PeerDropKit/Package.swift`. In the `products:` array, add:

```swift
.library(name: "PeerDropPlatform", targets: ["PeerDropPlatform"]),
```

(Place near the top — PeerDropPlatform is more foundational than the others.)

In the `targets:` array, add a new `.target(...)`:

```swift
.target(
    name: "PeerDropPlatform",
    dependencies: []  // truly leaf: only Foundation/UIKit/AppKit/AVFoundation/CoreGraphics — no PeerDropKit deps
),
```

And a `.testTarget(...)`:

```swift
.testTarget(name: "PeerDropPlatformTests", dependencies: ["PeerDropPlatform"]),
```

- [ ] **Step 2: Create directory + temporary placeholder**

Since Task 3 will move the real files in, the placeholder is only needed if `swift build` runs between Task 2 and Task 3. Create a minimal one:

```bash
mkdir -p PeerDropKit/Sources/PeerDropPlatform
cat > PeerDropKit/Sources/PeerDropPlatform/PeerDropPlatform.swift <<'EOF'
/// Temporary placeholder. Real Platform/ source files migrate in Task 3.
public enum PeerDropPlatform {}
EOF

mkdir -p PeerDropKit/Tests/PeerDropPlatformTests
cat > PeerDropKit/Tests/PeerDropPlatformTests/PeerDropPlatformTests.swift <<'EOF'
import XCTest
@testable import PeerDropPlatform

final class PeerDropPlatformTests: XCTestCase {
    func test_moduleIsLinkable() {
        XCTAssertNotNil(PeerDropPlatform.self)
    }
}
EOF
```

- [ ] **Step 3: Build standalone to verify Package.swift is valid**

```bash
cd PeerDropKit && swift build && swift test --filter PeerDropPlatformTests 2>&1 | tail -10 && cd ..
```

Expected: `Build complete!` + 1 test passes.

- [ ] **Step 4: Commit**

```bash
git add PeerDropKit/Package.swift PeerDropKit/Sources/PeerDropPlatform PeerDropKit/Tests/PeerDropPlatformTests
git commit -m "$(cat <<'EOF'
chore(m1d-3a): scaffold PeerDropPlatform module (placeholder)

6th product in PeerDropKit. Real source files migrate in Task 3.
Temporary `public enum PeerDropPlatform {}` placeholder + 1
test_moduleIsLinkable so swift build + swift test succeed.

Platform graph spec (§1 5-leaf-graph update):
- PeerDropPlatform is the most foundational module
- Pet, Transport, Core all depend on it
- Spec §1 will be updated when M1d-3a's whole-branch review confirms

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Move source files into PeerDropPlatform

**Files:**
- Move: 17 files from `PeerDrop/Core/Platform/` → `PeerDropKit/Sources/PeerDropPlatform/` (preserving iOS/ subdir)
- Move: 1 file `PeerDrop/Core/HapticManager.swift` → `PeerDropKit/Sources/PeerDropPlatform/HapticManager.swift`
- Delete: `PeerDropKit/Sources/PeerDropPlatform/PeerDropPlatform.swift` (placeholder)

- [ ] **Step 1: Move with git mv (preserves history)**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"

# Move 10 top-level Platform files
for f in PeerDrop/Core/Platform/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropPlatform/
done

# Move iOS subdir (preserve structure)
mkdir -p PeerDropKit/Sources/PeerDropPlatform/iOS
for f in PeerDrop/Core/Platform/iOS/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropPlatform/iOS/
done

# Clean up empty dirs
rmdir PeerDrop/Core/Platform/iOS
rmdir PeerDrop/Core/Platform

# Move HapticManager (the facade)
git mv PeerDrop/Core/HapticManager.swift PeerDropKit/Sources/PeerDropPlatform/HapticManager.swift

# Delete placeholder
git rm PeerDropKit/Sources/PeerDropPlatform/PeerDropPlatform.swift
```

Verify:
```bash
ls PeerDrop/Core/Platform 2>&1                                  # should error
ls PeerDrop/Core/HapticManager.swift 2>&1                       # should error
find PeerDropKit/Sources/PeerDropPlatform -name "*.swift" | wc -l   # 18
```

- [ ] **Step 2: Mark types public**

These types are already partially `public` from M0/M1a/M1b/M1d-1 work (they were designed for SPM split). Quick audit:

```bash
for f in PeerDropKit/Sources/PeerDropPlatform/*.swift; do
    echo "=== $(basename "$f") ==="
    grep -E "^(public |internal |private |fileprivate )?(struct|class|enum|protocol|typealias) " "$f" | head -5
done
```

The 7 protocols + `PlatformDependencies` + `PlatformImage`/`PlatformColor` typealiases should already be `public`. `HapticManager` (the static facade enum) is currently `enum HapticManager` (internal) — needs `public`.

Audit + apply `public` to anything that isn't already, including:
- `HapticManager` (the enum itself + all its static methods)
- Any internal helpers within the iOS adapter files (`UIKitGraphicsRenderer.render(...)` — currently internal; check)
- Any enum cases / nested types that consumers access

Iterate via build errors.

- [ ] **Step 3: xcodegen + iOS build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -20
```

EXPECTED to fail with many "Cannot find type 'PlatformImage'" / "Cannot find 'HapticManager'" errors — that's because consumer files don't yet have `import PeerDropPlatform`. Task 4 fixes.

Don't commit yet — wait for Task 4 to add imports so build is clean.

---

## Task 4: Add `import PeerDropPlatform` to all consumers

**Files:**
- Modify: ~15 consumer files across PeerDrop/ (from Task 1 audit)

- [ ] **Step 1: For each consumer file from Task 1's audit, add `import PeerDropPlatform`**

Typical pattern:
```swift
// Before:
import Foundation
import Combine

// After:
import Foundation
import Combine
import PeerDropPlatform
```

Use Edit tool — one line addition per file.

Common consumer files (from Task 1's audit):
- HapticManager callers: Transport/FileTransfer, Transport/FileTransferSession, UI/Discovery/DiscoveryView, UI/Discovery/NearbyTab, UI/Transfer/ClipboardShareView, Pet/Engine/PetEngine (still in app target for M1d-3a), Core/ClipboardSyncManager, Core/PushNotificationManager
- PlatformDependencies / ImageCache / etc.: Core/ImageCache, Core/ErrorReporter, Core/UserProfile, Core/PeerIdentity, Core/ArchiveManager, Core/ConnectionManager, App/PeerDropApp, App/AppDelegate
- Pet/Renderer/* (PetRendererV3, etc.) currently use PlatformImage/PlatformColor/PlatformGraphicsRenderer — they're in app target for M1d-3a, get the import
- UI/Settings/SettingsView, UI/Chat/ChatBubbleView, etc. — anything using PlatformImage or HapticManager

The Task 1 audit lists exact files.

- [ ] **Step 2: xcodegen + iOS build (should now succeed)**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -20
```

Iterate on remaining errors:
- "Cannot find type 'X'" → that file needs `import PeerDropPlatform` (Task 1 audit may have missed it; add now)
- "X is inaccessible due to 'internal' protection" → type needs `public` (back to Task 3 Step 2)

### Step 3: Run full iOS test sweep

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1d3a-task4-tests.log | tail -8
```

Expected: `** TEST SUCCEEDED **`, 1091 tests / 0 failures (matches post-M1d-2 baseline). The 5 Platform tests still run in xcodebuild (they migrate in Task 6).

### Step 4: Commit

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-3a): migrate Platform/ + HapticManager into PeerDropPlatform

17 files from PeerDrop/Core/Platform/ (preserving iOS/ subdir) +
HapticManager.swift moved to PeerDropKit/Sources/PeerDropPlatform/
via git mv. Placeholder enum deleted.

Internal types marked `public` where consumers cross the module
boundary (HapticManager enum + its static methods; previously-public
protocols and typealiases unchanged).

~N consumer files across Core/Transport/UI/Pet/App gain
`import PeerDropPlatform`.

iOS test suite still 1091/0. swift test for PeerDropPlatformTests
not yet migrated (still 1 placeholder — Task 6).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Update Package.swift consumer-leaves to optionally depend on PeerDropPlatform

**Files:**
- Modify: `PeerDropKit/Package.swift` (potentially)
- Modify: `project.yml` — PeerDrop + PeerDropTests gain `package: PeerDropKit / product: PeerDropPlatform`

- [ ] **Step 1: Determine if PeerDropProtocol / PeerDropSecurity need PeerDropPlatform**

```bash
grep -l "PlatformImage\|PlatformColor\|PlatformGraphicsRenderer\|PlatformDependencies\|HapticManager\|HapticFeedback" PeerDropKit/Sources/PeerDropProtocol/ PeerDropKit/Sources/PeerDropSecurity/ 2>/dev/null
```

If no matches: PeerDropProtocol + PeerDropSecurity don't need PeerDropPlatform. Skip their Package.swift updates.

If there are matches: add `dependencies: ["PeerDropPlatform"]` to those targets in `PeerDropKit/Package.swift`.

- [ ] **Step 2: Update project.yml to consume PeerDropPlatform**

Edit `project.yml`. PeerDrop target's `dependencies:` list currently has 5 PeerDropKit products. Add a 6th:

```yaml
- package: PeerDropKit
  product: PeerDropPlatform
```

Same for PeerDropTests target.

(Per M1d-1 reviewer note: any new PeerDropKit product must be added to both target dep lists. PeerDropPlatform is the first such addition.)

- [ ] **Step 3: xcodegen + verify build still passes**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **` (no change from Task 4 — the import paths already work because all PeerDropKit products are linked).

- [ ] **Step 4: Commit**

```bash
git add project.yml PeerDrop.xcodeproj PeerDropKit/Package.swift
git commit -m "$(cat <<'EOF'
chore(m1d-3a): wire PeerDropPlatform into project.yml + Package.swift

PeerDrop + PeerDropTests targets gain 6th PeerDropKit product
(PeerDropPlatform). Existing 5 products unchanged.

Package.swift updates (if any): PeerDropProtocol/Security/Pet/Transport
targets get `dependencies: ["PeerDropPlatform"]` only if their source
files reference Platform types. For M1d-3a most modules are still
empty placeholders so deps may not be needed yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate Platform tests into PeerDropPlatformTests

**Files:**
- Move: 5 test files `PeerDropTests/Core/Platform/*.swift` → `PeerDropKit/Tests/PeerDropPlatformTests/`
- Delete: `PeerDropKit/Tests/PeerDropPlatformTests/PeerDropPlatformTests.swift` (placeholder from Task 2)
- Modify: each moved file — `@testable import PeerDrop` → `@testable import PeerDropPlatform`
- Modify: other test files in PeerDropTests/ that use mocks (from Task 1 Step 5 audit) — add `@testable import PeerDropPlatform`

- [ ] **Step 1: Move test files**

```bash
for f in PeerDropTests/Core/Platform/*.swift; do
    git mv "$f" PeerDropKit/Tests/PeerDropPlatformTests/
done
rmdir PeerDropTests/Core/Platform 2>/dev/null

git rm PeerDropKit/Tests/PeerDropPlatformTests/PeerDropPlatformTests.swift
```

- [ ] **Step 2: Update `@testable import` in moved files**

```bash
for f in $(find PeerDropKit/Tests/PeerDropPlatformTests -name "*.swift"); do
    sed -i '' 's/@testable import PeerDrop$/@testable import PeerDropPlatform/g' "$f"
done
```

Some tests may also `@testable import PeerDropProtocol` or `PeerDropSecurity` — leave those untouched.

- [ ] **Step 3: Update OTHER test files that use Platform mocks**

For each file in Task 1 Step 5's audit (test files outside Core/Platform/ that use MockPlatformDependencies, MockHaptics, etc.), add `@testable import PeerDropPlatform` to their imports.

- [ ] **Step 4: Run swift test from PeerDropKit/**

```bash
cd PeerDropKit && swift test --filter PeerDropPlatformTests 2>&1 | tail -15 && cd ..
```

Expected: 5+ tests run (PlatformDependenciesTests, PlatformImageTests x 2, PlatformGraphicsRendererTests x 2, CallProviderTests, + the 5 injection tests inside MockPlatformDependencies). All pass.

If tests fail:
- "Cannot find type 'X'" → missing `@testable import PeerDropPlatform`
- "Member 'X' is internal" → mark X public in source

Iterate.

- [ ] **Step 5: Run full iOS test sweep (count check)**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1d3a-task6-tests.log | tail -8
```

Expected: iOS test count drops by 5 (Platform tests now run via swift test). 1091 → ~1086 iOS tests / 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-3a): migrate Platform tests into PeerDropPlatformTests

5 test files moved from PeerDropTests/Core/Platform/ to
PeerDropKit/Tests/PeerDropPlatformTests/. Placeholder
test_moduleIsLinkable deleted.

@testable imports updated PeerDrop → PeerDropPlatform. Other test
files using Platform mocks (~N files outside Core/Platform/) gain
the same import.

iOS test count: 1091 → 1086 (5 Platform tests now run via swift
test). PeerDropPlatformTests: 5+ tests pass via swift test.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Final verification + tag

**Files:** (verification only)

- [ ] **Step 1: Full iOS test + swift test sweeps**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tail -8

cd PeerDropKit && swift test 2>&1 | tail -10 && cd ..
```

Expected:
- iOS: ~1086 tests / 0 failures
- swift test: 162 (Security) + 5+ (Platform) + 4 placeholders (Protocol+Pet+Core+Transport) = ~171+ / 0 failures

Total: ~1257+ (was 1253 — net +4 from full Platform test inclusion).

- [ ] **Step 2: Verify directory structure**

```bash
ls PeerDrop/Core/Platform 2>&1   # should error
ls PeerDrop/Core/HapticManager.swift 2>&1   # should error
find PeerDropKit/Sources/PeerDropPlatform -name "*.swift" | sort
find PeerDropKit/Tests/PeerDropPlatformTests -name "*.swift" | sort
```

Expected:
- 2 errors (PeerDrop/Core/Platform and HapticManager.swift no longer exist)
- 18 source files in PeerDropPlatform/
- 5 test files in PeerDropPlatformTests/

- [ ] **Step 3: lint-imports clean**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"

# Run lint script (same as M1c)
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
done < <(find PeerDrop/Core PeerDrop/Pet PeerDrop/Voice PeerDropKit/Sources -name "*.swift" \
  -not -path "*/Platform/iOS/*" \
  -not -path "*/Pet/UI/*" \
  -not -path "*/Voice/CallKitManager.swift")
if [ -n "$violations" ]; then
  printf "Violations:\n%b" "$violations"
else
  echo "Clean."
fi
```

Expected: `Clean.`

Note: the existing `-not -path "*/Platform/iOS/*"` exclusion in the lint script will still match the new path `PeerDropKit/Sources/PeerDropPlatform/iOS/*.swift` because the pattern matches any `/Platform/iOS/` in the path.

- [ ] **Step 4: Tag M1d-3a**

```bash
git tag -a m1d-3a-platform-extraction -m "M1d-3a done: PeerDropPlatform module extracted from Core/Platform/ + HapticManager. 6th product in PeerDropKit. Pet migration unblocked for M1d-3b."

git log --oneline f4535b3..HEAD
git tag --list | grep -E "m0|m1"
```

Expected: ~5-6 M1d-3a commits, 7 tags.

## Done

M1d-3a complete. PeerDropPlatform module exists and is consumed by app + test targets. The Pet → Core → Pet cycle that was blocking M1d-2's Pet migration is now resolvable: Pet just depends on PeerDropPlatform (which doesn't depend on anyone).

**Next:** M1d-3b plan (Pet migration — 61 source + 64 tests + 324 resources + Widget rewire) by re-invoking `superpowers:writing-plans`.

## Open Items for M1d-3b

1. Add `dependencies: ["PeerDropPlatform"]` to PeerDropPet target in Package.swift (Pet uses PlatformImage / PlatformGraphicsRenderer / HapticManager).
2. Migrate 61 Pet source files preserving 8 subdirs.
3. Move 324 Pet resource zips into PeerDropKit/Sources/PeerDropPet/Resources/Pets/ with `.process("Resources")` declaration.
4. 4 Bundle.main → Bundle.module substitutions.
5. Widget rewire: drop 8 path-references, add `package: PeerDropPet` dependency.
6. Move 63 Pet test files.
