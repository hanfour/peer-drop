# M1c — SPM Scaffold + Empty Modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `PeerDropKit/Package.swift` with 5 empty product modules + the dependency graph from spec §1. Each module is a placeholder (compile-only) — actual file migration is M1d. Extend `lint-imports` CI to scan `PeerDropKit/Sources/` for future-proof UI-framework hygiene.

**Architecture:** Local Swift Package at `PeerDropKit/` exposing 5 library products (PeerDropCore, PeerDropTransport, PeerDropSecurity, PeerDropProtocol, PeerDropPet) with the dependency graph: `Core` consumes `{Transport, Security, Protocol, Pet}`; `Transport` consumes WebRTC; `Pet` consumes ZIPFoundation. Modules are empty in M1c (single placeholder `public enum X {}` per module to satisfy `swift build`). M1d will migrate files into them.

**Tech Stack:** Swift 5.9, iOS 16+, macOS 14+ (anticipating M2), Swift Package Manager, XcodeGen 2.45.4. Builds: `swift build` for package-level validation; `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet` for app-level.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §1 (module boundaries) + §7 M1c (scaffold-only scope).

**Predecessors:**
- M0 shipped (tag `m0-core-uikit-decoupled`, `a3f6ba1`)
- M1a shipped (tag `m1a-pet-uikit-decoupled`, `32e1e3d`)
- M1b shipped (tag `m1b-voice-cleanup`, `3e3946b`)
- Triage shipped (`84add66`) — main is now 1248 tests / 0 failures, clean baseline for M1c regression checks

**Investigation findings:**
- xcodegen 2.45.4 supports local SPM packages via `packages: PeerDropKit: { path: ./PeerDropKit }`
- External SPM deps (WebRTC, ZIPFoundation) currently consumed by the PeerDrop app target — `Package.swift` will need to re-declare them so the package compiles standalone
- Widget target currently path-references 7 specific Pet files (Pet/Shared dir + Pet/Renderer/PetPalettes.swift + 6 Pet/Model files) — this is the "poor man's shared module" pattern the spec calls out. **M1c does NOT change this** (Widget keeps path-refs); M1d migrates to depending on PeerDropPet instead
- Nothing depends on PeerDropKit modules in M1c — they're verified independently via `swift build`, not via the app target

---

## File Structure

**New files (7):**
- `PeerDropKit/Package.swift` — package manifest with 5 products + WebRTC + ZIPFoundation external deps + dependency graph
- `PeerDropKit/Sources/PeerDropCore/PeerDropCore.swift` — `public enum PeerDropCore {}` placeholder
- `PeerDropKit/Sources/PeerDropTransport/PeerDropTransport.swift` — placeholder
- `PeerDropKit/Sources/PeerDropSecurity/PeerDropSecurity.swift` — placeholder
- `PeerDropKit/Sources/PeerDropProtocol/PeerDropProtocol.swift` — placeholder
- `PeerDropKit/Sources/PeerDropPet/PeerDropPet.swift` — placeholder
- `PeerDropKit/README.md` — short doc explaining the package boundary + M1d migration plan

**Modified files (2):**
- `project.yml` — add `PeerDropKit: { path: ./PeerDropKit }` to `packages:` section (no target dependencies — modules empty in M1c)
- `.github/workflows/ci.yml` — extend `find` to also scan `PeerDropKit/Sources/` (locks UI-framework rule in for future PeerDropKit additions)

---

## Task 1: Create directory structure + placeholder source files

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/PeerDropCore.swift`
- Create: `PeerDropKit/Sources/PeerDropTransport/PeerDropTransport.swift`
- Create: `PeerDropKit/Sources/PeerDropSecurity/PeerDropSecurity.swift`
- Create: `PeerDropKit/Sources/PeerDropProtocol/PeerDropProtocol.swift`
- Create: `PeerDropKit/Sources/PeerDropPet/PeerDropPet.swift`

- [ ] **Step 1: Create the placeholder for each module**

Each placeholder is identical except for the type name. For PeerDropCore:

```swift
// PeerDropKit/Sources/PeerDropCore/PeerDropCore.swift

/// Placeholder for the PeerDropCore module.
///
/// In M1d, this module will own ConnectionManager, ChatManager,
/// DeviceRecordStore, UserProfile, InboxService, FeatureSettings,
/// ScreenshotModeProvider, ConnectionMetrics, plus the Platform/
/// registry from M0/M1a/M1b.
///
/// Until M1d migrates the source files, this empty enum exists only
/// so `swift build` has something to compile.
public enum PeerDropCore {}
```

Repeat the same pattern for the other 4 (replace `PeerDropCore` → `PeerDropTransport` / `PeerDropSecurity` / `PeerDropProtocol` / `PeerDropPet` in both the type name and the doc comment), and adjust the M1d-content sentence per module:

| Module | M1d content blurb |
|---|---|
| PeerDropCore | "ConnectionManager, ChatManager, DeviceRecordStore, UserProfile, InboxService, FeatureSettings, ScreenshotModeProvider, ConnectionMetrics, plus the Platform/ registry from M0/M1a/M1b." |
| PeerDropTransport | "Bonjour discovery, PeerConnection, WebRTC wrapper, RelaySession, NetworkFingerprint, TailnetPeerStore — plus the Voice/ transport-layer pieces from M1b (VoiceCallManager, WebRTCClient, SDPSignaling, VoicePlayer, VoiceRecorder, VoiceCallSession)." |
| PeerDropSecurity | "PeerIdentity, DeviceIdentity, ChatDataEncryptor, TrustedContact, Double Ratchet, SAS, relay crypto (v5.4 PR1–PR8)." |
| PeerDropProtocol | "Wire format, message envelope, version negotiation (incl. v5.4 PR7 peerProtocolVersion)." |
| PeerDropPet | "PetGenome, SpeciesCatalog, PetRendererV3, SpriteService, PaletteSwap, atlas decoding, plus the Pet/ resources moved to SPM bundle." |

- [ ] **Step 2: Verify directory layout**

```bash
find PeerDropKit -type f
```

Expected: 5 .swift files, one per module directory, all at `PeerDropKit/Sources/<ModuleName>/<ModuleName>.swift`.

- [ ] **Step 3: Commit**

```bash
git add PeerDropKit/Sources
git commit -m "$(cat <<'EOF'
chore(m1c): scaffold 5 empty module placeholders under PeerDropKit/Sources

PeerDropCore, PeerDropTransport, PeerDropSecurity, PeerDropProtocol,
PeerDropPet — each a one-line `public enum X {}` placeholder. Doc
comments describe what M1d will migrate into each module. Package
manifest lands in Task 2; xcodegen wire-up in Task 4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create `PeerDropKit/Package.swift` with the 5 products + dependency graph

**Files:**
- Create: `PeerDropKit/Package.swift`

- [ ] **Step 1: Write the manifest**

Create `PeerDropKit/Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PeerDropKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PeerDropCore", targets: ["PeerDropCore"]),
        .library(name: "PeerDropTransport", targets: ["PeerDropTransport"]),
        .library(name: "PeerDropSecurity", targets: ["PeerDropSecurity"]),
        .library(name: "PeerDropProtocol", targets: ["PeerDropProtocol"]),
        .library(name: "PeerDropPet", targets: ["PeerDropPet"]),
    ],
    dependencies: [
        // External SPM packages — re-declared here so PeerDropKit can be
        // built standalone via `swift build`. The PeerDrop app target also
        // depends on these (declared in project.yml `packages:` section),
        // but each declaration is independent — Xcode resolves to the same
        // pinned versions.
        .package(url: "https://github.com/stasel/WebRTC", exact: "125.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        // PeerDropCore is the keystone — depends on all 4 leaf modules.
        // Per spec §1: "Core consumes Transport/Security/Protocol/Pet";
        // strict single-direction (no cycles).
        .target(
            name: "PeerDropCore",
            dependencies: [
                "PeerDropTransport",
                "PeerDropSecurity",
                "PeerDropProtocol",
                "PeerDropPet",
            ]
        ),
        .target(
            name: "PeerDropTransport",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .target(name: "PeerDropSecurity"),
        .target(name: "PeerDropProtocol"),
        .target(
            name: "PeerDropPet",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
```

Notes:
- `platforms:` includes macOS 14+ in anticipation of M2 (macOS native target). Even though no macOS consumer exists today, declaring it now means the package can't accidentally adopt iOS-only API in M1d
- Both WebRTC and ZIPFoundation use the same version constraints as the current project.yml (exact 125.0.0 for WebRTC, `from: 0.9.19` for ZIPFoundation) — same dependency-resolution outcome
- `PeerDropTransport` and `PeerDropPet` re-declare their external dep so each module advertises its own dependency surface (good for the spec's "what does each module depend on?" check)

- [ ] **Step 2: Verify the package builds standalone**

```bash
cd PeerDropKit && swift build 2>&1 | tail -20 && cd ..
```

Expected: `Build complete!` with no errors. The placeholder files compile trivially; the build mainly verifies the dependency graph + Package.swift syntax. The first build will resolve WebRTC + ZIPFoundation (slow first-time, fast cached).

If the build fails with a dependency-resolution error, troubleshoot:
- Network access to GitHub for WebRTC + ZIPFoundation
- Version constraint conflicts (unlikely since we mirror project.yml exactly)
- Module name typo (e.g., the WebRTC product is named "WebRTC" inside the package — verify with `swift package resolve` then inspect the resolved manifest)

- [ ] **Step 3: Commit**

```bash
git add PeerDropKit/Package.swift PeerDropKit/Package.resolved
git commit -m "$(cat <<'EOF'
chore(m1c): PeerDropKit Package.swift — 5 products + dependency graph

Implements spec §1 module boundaries:
- PeerDropCore depends on Transport/Security/Protocol/Pet (single direction, no cycles)
- PeerDropTransport depends on WebRTC SPM
- PeerDropPet depends on ZIPFoundation SPM
- PeerDropSecurity + PeerDropProtocol are leaf modules (Foundation only)

Platform support declares iOS 16+ AND macOS 14+ now so M1d can't
accidentally adopt iOS-only API. Package builds standalone via
`swift build` from PeerDropKit/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(Include `Package.resolved` if `swift build` created it — it pins the exact transitive dep versions.)

---

## Task 3: Write `PeerDropKit/README.md`

**Files:**
- Create: `PeerDropKit/README.md`

- [ ] **Step 1: Write the README**

```markdown
# PeerDropKit

Local Swift Package containing the cross-platform core of the PeerDrop app.
Consumed by both the iOS app target (`PeerDropApp-iOS`, eventual `PeerDropApp-macOS`)
and the `PeerDropWidget` extension.

## Modules

| Module | Purpose | External dependencies |
|---|---|---|
| `PeerDropCore` | App-level orchestration: ConnectionManager, ChatManager, UserProfile, InboxService, Platform/ registry | none |
| `PeerDropTransport` | Network/transport layer: Bonjour, PeerConnection, RelaySession, WebRTC, voice transport pieces | WebRTC |
| `PeerDropSecurity` | Cryptography: PeerIdentity, ChatDataEncryptor, Double Ratchet, SAS, relay crypto | CryptoKit (Apple) |
| `PeerDropProtocol` | Wire format + envelope + version negotiation | none |
| `PeerDropPet` | Pet system: PetGenome, SpeciesCatalog, PetRendererV3, sprite atlas decoding | ZIPFoundation |

## Dependency graph

```
PeerDropPet ────┐
PeerDropSecurity ─┐
PeerDropProtocol ─┼──> PeerDropCore ──> (app targets)
PeerDropTransport ┘
```

Strict single-direction. Enforced via `swift build` (cycles would not compile)
and via the macOS-platform target declaration (UI-framework imports would
fail on macOS even if iOS happens to accept them).

## Status

| Milestone | Status | Description |
|---|---|---|
| M1c | ✅ shipped | Package scaffold + empty placeholder modules |
| M1d | pending | Migrate ~90 source files from `PeerDrop/` into modules |
| M2 | pending | macOS app target consumes PeerDropKit alongside iOS |

## Local development

```bash
# Build the package standalone
cd PeerDropKit && swift build

# Run package tests (none in M1c — tests come in M1d when files migrate)
cd PeerDropKit && swift test
```

The PeerDrop app builds + tests still flow through xcodebuild on the
`PeerDrop` scheme; xcodegen wires the local SPM package into the Xcode
project via project.yml.
```

- [ ] **Step 2: Commit**

```bash
git add PeerDropKit/README.md
git commit -m "$(cat <<'EOF'
docs(m1c): PeerDropKit README — modules + dependency graph + status

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire PeerDropKit into project.yml (declare-only, no target consumes yet)

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Read current `packages:` section**

```bash
sed -n '1,25p' project.yml
```

Note the existing 2 SPM packages (WebRTC, ZIPFoundation).

- [ ] **Step 2: Add PeerDropKit as a local package**

Edit `project.yml`. In the `packages:` section, add:

```yaml
packages:
  WebRTC:
    url: https://github.com/stasel/WebRTC
    exactVersion: 125.0.0
  ZIPFoundation:
    url: https://github.com/weichsel/ZIPFoundation
    from: 0.9.19
  PeerDropKit:
    path: PeerDropKit
```

xcodegen recognises the `path:` key as a local package reference.

DO NOT add any target dependency on PeerDropKit yet. Modules are empty in M1c — nothing should consume them. M1d will add `- package: PeerDropKit` to the relevant targets' `dependencies:` lists.

- [ ] **Step 3: Generate Xcode project**

```bash
xcodegen generate 2>&1 | tail -10
```

Expected: `Generated project successfully` with no errors. xcodegen should pick up the local package and resolve it.

- [ ] **Step 4: Build the app (should be unchanged from main)**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`. The app build doesn't consume PeerDropKit yet, so behaviour is identical to pre-M1c.

- [ ] **Step 5: Run full test suite to verify zero regressions**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1c-task4-tests.log | tail -8
```

Expected: `** TEST SUCCEEDED **` (1248 tests, 0 failures — same as the triage baseline). If any test fails, investigate before committing.

- [ ] **Step 6: Commit**

```bash
git add project.yml PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
chore(m1c): wire PeerDropKit into project.yml as local SPM package

Declared in packages: section with `path: PeerDropKit`. NO target
dependency added — modules are empty in M1c, nothing consumes them.
M1d will add `- package: PeerDropKit` to PeerDrop / PeerDropTests /
PeerDropWidget dependencies as files migrate.

App build unchanged; 1248 tests still pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Extend `lint-imports` CI to scan `PeerDropKit/Sources/`

**Files:**
- Modify: `.github/workflows/ci.yml`

The lint job currently scans `PeerDrop/Core PeerDrop/Pet PeerDrop/Voice`. Add `PeerDropKit/Sources` so any future file migrated into PeerDropKit can't sneak in a UIKit/AppKit/WidgetKit import.

- [ ] **Step 1: Read current `find` command**

```bash
sed -n '1,50p' .github/workflows/ci.yml
```

Find the line containing `find PeerDrop/Core PeerDrop/Pet PeerDrop/Voice -name "*.swift" ...`.

- [ ] **Step 2: Extend the find path**

Edit the find command:

```yaml
done < <(find PeerDrop/Core PeerDrop/Pet PeerDrop/Voice PeerDropKit/Sources -name "*.swift" \
  -not -path "*/Platform/iOS/*" \
  -not -path "*/Pet/UI/*" \
  -not -path "*/Voice/CallKitManager.swift")
```

The existing exclusion patterns (`*/Platform/iOS/*`) will continue to apply if M1d moves Platform/iOS/ adapters under PeerDropKit/Sources/PeerDropCore/Platform/iOS/. No new exclusion needed for M1c since PeerDropKit/Sources/ is just 5 placeholder enums with no UIKit anywhere.

- [ ] **Step 3: Run lint locally to confirm "Clean."**

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

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci: lint-imports also scans PeerDropKit/Sources/ (m1c)

Locks the no-UIKit rule into PeerDropKit early. The 5 placeholder
modules trivially satisfy it today; the real test comes in M1d when
files migrate in.

Same exclusion patterns (Platform/iOS/, Pet/UI/, Voice/CallKitManager.swift)
continue to apply if file paths move under PeerDropKit/Sources/ during M1d.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Verify swift test runs on the empty package (sanity check + future-proof)

**Files:**
- (verification only, no commit unless issues surface)

- [ ] **Step 1: Run swift test from PeerDropKit/**

```bash
cd PeerDropKit && swift test 2>&1 | tail -10 && cd ..
```

Expected: `Test Suite 'All tests' passed at ...` with 0 tests run. The package has no tests yet (M1d adds them). The point is to verify the test infrastructure works — if `swift test` errors out on the empty package, M1d will hit it later anyway.

If you see `error: no tests to run`, that's actually fine for SwiftPM — but on Swift 5.9 it usually returns 0 success silently. If it errors, investigate.

- [ ] **Step 2: No commit needed**

This is a one-off sanity check; pass/fail informs M1d's testability assumptions.

---

## Task 7: Final verification + tag M1c

**Files:**
- (verification only; no code commits expected)

- [ ] **Step 1: Run the full test suite once more for clean baseline**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1c-final-tests.log | tail -8
```

Expected: `** TEST SUCCEEDED **` with 1248 tests, 0 failures (same as triage baseline post-merge).

Extract:

```bash
grep -cE "^Test Case .* started" /tmp/m1c-final-tests.log
grep -cE "Test Case '-\[.*\]' failed" /tmp/m1c-final-tests.log
```

Expected: 1248 / 0.

- [ ] **Step 2: Verify directory + package shape**

```bash
echo "=== PeerDropKit structure ==="
find PeerDropKit -type f | sort

echo "=== Package.swift validity ==="
cd PeerDropKit && swift package describe 2>&1 | head -20 && cd ..

echo "=== project.yml packages section ==="
sed -n '1,20p' project.yml
```

Expected: 7 files in PeerDropKit (5 placeholders + Package.swift + README.md), Package.swift parses correctly, project.yml declares PeerDropKit.

- [ ] **Step 3: Tag M1c**

```bash
git tag -a m1c-spm-scaffold -m "M1c done: PeerDropKit scaffold (5 empty product modules + dependency graph)"
git log --oneline 84add66..HEAD
git tag --list | grep -E "m0|m1"
```

Expected: ~5-6 M1c commits, all 4 tags listed.

## Done

M1c complete. `PeerDropKit/` exists with 5 empty product modules following the spec §1 dependency graph. App build + tests unchanged. M1d can now start migrating files into modules.

**Next:** M1d plan (file migration — ~90 files moving into the 5 modules, project.yml dependency wiring, Widget target switches from path-refs to `- package: PeerDropKit`, Pet/ resources move to SPM resource bundle) by re-invoking `superpowers:writing-plans`.

## Open Items for M1d / M2+

1. **M1d:** migrate ~90 files into modules; update `project.yml` targets to depend on PeerDropKit; rewrite PeerDropWidget to use `import PeerDropPet` instead of path-references; move Pet/ resources into SPM resource bundle via `.process` or `.copy`
2. **M2:** add `PeerDropApp-macOS` target that also depends on PeerDropKit
3. **macOS deployment target verification**: `Package.swift` declares macOS 14+, but until M2 we don't actually build for macOS. M2's first action should be `swift build --triple arm64-apple-macos14.0` to verify the package compiles on macOS
