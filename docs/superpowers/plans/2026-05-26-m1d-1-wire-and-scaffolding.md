# M1d-1 — Wire App Target to PeerDropKit + Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire PeerDropKit into the app target + test target dependency lists, add per-module `.testTarget(...)` scaffolding to `Package.swift` (5 empty test targets), and add `swift build` macOS gate to CI. **Zero source files migrate** — this is foundation work that enables M1d-2 onwards to start importing PeerDropKit modules. Net result: PeerDropKit modules become importable but stay empty; iOS behaviour unchanged; CI now also fails on macOS-incompatible code in PeerDropKit/Sources/.

**Architecture:** App target gains `- package: PeerDropKit` so files can `import PeerDropCore` etc. once M1d-2+ migrates them. Test target gains the same so test files can `@testable import PeerDropX`. Package.swift gains 5 `.testTarget(name: "<X>Tests")` declarations + 5 `Tests/<X>Tests/` placeholder directories. CI gets a `swift-build-macos` job alongside the existing iOS xcodebuild job.

**Tech Stack:** Swift 5.9, iOS 16+, macOS 14+, XCTest, XcodeGen 2.45.4. Builds: `xcodebuild` (iOS app), `swift build` (PeerDropKit standalone), GitHub Actions for CI.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1d-1 (split from M1d 2026-05-26).

**Predecessors:**
- M0 (tag `m0-core-uikit-decoupled`)
- M1a (tag `m1a-pet-uikit-decoupled`)
- M1b (tag `m1b-voice-cleanup`)
- Triage (no tag; PR #48 merged)
- M1c (tag `m1c-spm-scaffold`) — current baseline. PeerDropKit exists with 5 empty modules, package registered in `project.yml` but no target consumes

**M1c reviewer follow-ups addressed by M1d-1:**
- ✅ Add `swift build` as macOS compile gate to CI (Task 5 below)
- ✅ Create per-module `Tests/` targets in `Package.swift` (Task 3 below)
- Deferred to M1d-3: CallKitManager path placement decision

---

## File Structure

**Modified files (4):**
- `project.yml` — add `- package: PeerDropKit` to PeerDrop + PeerDropTests target `dependencies:` lists
- `PeerDropKit/Package.swift` — add 5 `.testTarget(...)` entries (one per module)
- `.github/workflows/ci.yml` — new `swift-build-macos` job runs `swift build` from PeerDropKit/

**New files (5):**
- `PeerDropKit/Tests/PeerDropCoreTests/PeerDropCoreTests.swift` — single placeholder test per module
- `PeerDropKit/Tests/PeerDropTransportTests/PeerDropTransportTests.swift`
- `PeerDropKit/Tests/PeerDropSecurityTests/PeerDropSecurityTests.swift`
- `PeerDropKit/Tests/PeerDropProtocolTests/PeerDropProtocolTests.swift`
- `PeerDropKit/Tests/PeerDropPetTests/PeerDropPetTests.swift`

Each placeholder test is identical (one trivial assertion that proves the test infrastructure works). Real tests migrate in M1d-2+ alongside their production code.

---

## Task 1: Add 5 placeholder test files

**Files:**
- Create `PeerDropKit/Tests/PeerDropCoreTests/PeerDropCoreTests.swift`
- Create `PeerDropKit/Tests/PeerDropTransportTests/PeerDropTransportTests.swift`
- Create `PeerDropKit/Tests/PeerDropSecurityTests/PeerDropSecurityTests.swift`
- Create `PeerDropKit/Tests/PeerDropProtocolTests/PeerDropProtocolTests.swift`
- Create `PeerDropKit/Tests/PeerDropPetTests/PeerDropPetTests.swift`

Each file is the same shape with the module name swapped.

- [ ] **Step 1: Create the 5 placeholder test files**

For `PeerDropCoreTests`:

```swift
// PeerDropKit/Tests/PeerDropCoreTests/PeerDropCoreTests.swift
import XCTest
@testable import PeerDropCore

final class PeerDropCoreTests: XCTestCase {
    /// Placeholder. Real tests for PeerDropCore consumers (ConnectionManager,
    /// ChatManager, etc.) migrate here in M1d-4 alongside the source files.
    /// This single trivial test ensures `swift test` can find + run a test target.
    func test_moduleIsLinkable() {
        // PeerDropCore is currently `public enum PeerDropCore {}` — verify
        // the test target can reference it.
        XCTAssertNotNil(PeerDropCore.self)
    }
}
```

Repeat for the other 4 modules — change `PeerDropCore` → `PeerDropTransport` / `PeerDropSecurity` / `PeerDropProtocol` / `PeerDropPet` in:
- The file path
- The `@testable import` line
- The class name
- The doc comment ("PeerDropCore consumers" → "PeerDropTransport consumers (Bonjour, PeerConnection, RelaySession, WebRTC, voice transport pieces)" etc.; refer to README.md for module purposes)
- The assertion target (`PeerDropCore.self` → `PeerDropTransport.self` etc.)

Per-module doc comment text (mirror README):

| Module | Consumer text |
|---|---|
| PeerDropCore | "consumers (ConnectionManager, ChatManager, etc.)" |
| PeerDropTransport | "consumers (Bonjour, PeerConnection, RelaySession, WebRTC, voice transport pieces)" |
| PeerDropSecurity | "consumers (PeerIdentity, ChatDataEncryptor, Double Ratchet, SAS)" |
| PeerDropProtocol | "consumers (wire format, message envelope, version negotiation)" |
| PeerDropPet | "consumers (PetGenome, SpeciesCatalog, PetRendererV3, sprite atlas)" |

The migration milestone per module:
- PeerDropProtocol/Security/Pet — M1d-2
- PeerDropTransport — M1d-3
- PeerDropCore — M1d-4

Update the doc comment's "migrate here in M1d-X" accordingly.

- [ ] **Step 2: Verify directory layout**

```bash
find PeerDropKit/Tests -type f | sort
```

Expected:
```
PeerDropKit/Tests/PeerDropCoreTests/PeerDropCoreTests.swift
PeerDropKit/Tests/PeerDropPetTests/PeerDropPetTests.swift
PeerDropKit/Tests/PeerDropProtocolTests/PeerDropProtocolTests.swift
PeerDropKit/Tests/PeerDropSecurityTests/PeerDropSecurityTests.swift
PeerDropKit/Tests/PeerDropTransportTests/PeerDropTransportTests.swift
```

- [ ] **Step 3: Commit (will fail `swift test` until Task 2 adds .testTarget entries; that's OK for the intermediate state)**

```bash
git add PeerDropKit/Tests
git commit -m "$(cat <<'EOF'
chore(m1d-1): 5 placeholder test files under PeerDropKit/Tests/

One trivial `test_moduleIsLinkable` per module. `.testTarget(...)`
entries in Package.swift are added in Task 2; real tests migrate
in M1d-2 onwards alongside source files.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Extend `Package.swift` with 5 `.testTarget(...)` entries

**Files:**
- Modify: `PeerDropKit/Package.swift`

- [ ] **Step 1: Read current Package.swift**

```bash
cat PeerDropKit/Package.swift
```

Identify the current `targets:` array (5 `.target(...)` entries).

- [ ] **Step 2: Append 5 `.testTarget(...)` entries**

Edit `PeerDropKit/Package.swift`. Inside the `targets:` array, after the existing 5 `.target(...)` entries, add:

```swift
        // Test targets — one per product module. Each tests its corresponding
        // module via `@testable import`. Empty in M1d-1; real tests migrate
        // here in M1d-2 onwards alongside production source files.
        .testTarget(name: "PeerDropCoreTests", dependencies: ["PeerDropCore"]),
        .testTarget(name: "PeerDropTransportTests", dependencies: ["PeerDropTransport"]),
        .testTarget(name: "PeerDropSecurityTests", dependencies: ["PeerDropSecurity"]),
        .testTarget(name: "PeerDropProtocolTests", dependencies: ["PeerDropProtocol"]),
        .testTarget(name: "PeerDropPetTests", dependencies: ["PeerDropPet"]),
```

Each test target depends ONLY on its own production target — no cross-module test deps (keeps the dependency graph clean).

- [ ] **Step 3: Verify `swift test` now finds + runs the 5 tests**

```bash
cd PeerDropKit && swift test 2>&1 | tail -15 && cd ..
```

Expected: 5 tests executed, all pass:
```
Test Suite 'PeerDropCoreTests' passed at ...
...
Test Suite 'All tests' passed at ...
     Executed 5 tests, with 0 failures
```

If the build fails because `@testable import PeerDropCore` can't find the module, that means Task 1's placeholder test file uses the wrong import. Re-check.

- [ ] **Step 4: Commit**

```bash
git add PeerDropKit/Package.swift
git commit -m "$(cat <<'EOF'
chore(m1d-1): Package.swift gains 5 .testTarget entries

Addresses M1c reviewer follow-up #3: per-module Tests/ targets must
exist before M1d-2 starts migrating tests. Each test target depends
only on its own production target — no cross-module test
dependencies.

`swift test` from PeerDropKit/ now executes 5 placeholder tests
(test_moduleIsLinkable per module).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire app target + test target to consume PeerDropKit

**Files:**
- Modify: `project.yml`
- Regenerate: `PeerDrop.xcodeproj/project.pbxproj`

This is the most critical task in M1d-1. After this, the app target's source files CAN `import PeerDropCore` etc. — they don't yet (modules are empty), but the wiring is in place for M1d-2+.

- [ ] **Step 1: Read current `dependencies:` lists**

```bash
grep -A5 "    dependencies:" project.yml | head -30
```

Note the current state for both PeerDrop and PeerDropTests targets.

- [ ] **Step 2: Add `- package: PeerDropKit` to PeerDrop target dependencies**

Edit `project.yml`. Find the PeerDrop target's `dependencies:` list (around lines 38-41):

```yaml
# Before:
    dependencies:
      - package: WebRTC
      - package: ZIPFoundation
      - target: PeerDropWidget

# After:
    dependencies:
      - package: WebRTC
      - package: ZIPFoundation
      - package: PeerDropKit
      - target: PeerDropWidget
```

DO NOT remove the existing WebRTC + ZIPFoundation entries yet. They're transitively available via PeerDropKit, but the app target's source files currently import them directly. M1d-4 removes them after all source migrates and no app-level file imports them directly.

- [ ] **Step 3: Add `- package: PeerDropKit` to PeerDropTests target dependencies**

Find the PeerDropTests target's `dependencies:` list (around lines 128-130):

```yaml
# Before:
    dependencies:
      - target: PeerDrop
      - package: ZIPFoundation

# After:
    dependencies:
      - target: PeerDrop
      - package: ZIPFoundation
      - package: PeerDropKit
```

- [ ] **Step 4: Regenerate Xcode project**

```bash
xcodegen generate 2>&1 | tail -5
```

Expected: `Generated project successfully` with no errors.

- [ ] **Step 5: Build the app**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`. Nothing in the app actually `import PeerDropX`s yet, so behaviour is identical to pre-M1d-1.

- [ ] **Step 6: Run full test suite**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1d1-task3-tests.log | tail -8
```

Expected: `** TEST SUCCEEDED **`, 1248 tests / 0 failures (matches post-M1c baseline).

- [ ] **Step 7: Commit**

```bash
git add project.yml PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
chore(m1d-1): app + test targets consume PeerDropKit

Added `- package: PeerDropKit` to PeerDrop and PeerDropTests
dependencies. App-level + test-level files can now `import PeerDropX`
once M1d-2 onwards starts migrating source.

Existing WebRTC + ZIPFoundation direct deps retained (M1d-4 removes
them after all source migration is done and no app file imports them
directly).

App build unchanged; 1248 tests still pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Verify a sample `import PeerDropCore` works (smoke test for the wiring)

**Files:**
- Verification only (no commit unless something is broken)

This step verifies that an arbitrary app-target source file can successfully `import PeerDropCore` after Task 3. We don't actually commit any import — just temporarily add one, build, then revert. This catches wiring problems before M1d-2 starts the real migration.

- [ ] **Step 1: Pick a low-risk app-target file to test with**

`PeerDrop/App/PeerDropApp.swift` is a good candidate — it's the SwiftUI entry point and already imports several modules. Adding a temporary `import PeerDropCore` won't affect runtime behaviour.

- [ ] **Step 2: Temporarily add the import**

Use Edit to add `import PeerDropCore` after the existing imports at the top of `PeerDrop/App/PeerDropApp.swift`. (DO NOT use any `PeerDropCore.X` types yet — the module only contains an empty enum.)

- [ ] **Step 3: Build to verify the import resolves**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`. If build fails with "No such module 'PeerDropCore'", the Task 3 wiring is broken — investigate.

- [ ] **Step 4: REVERT the temporary import**

Use Edit to remove the temporary `import PeerDropCore` line. The file should be EXACTLY as it was at Task 3's end.

Verify:
```bash
git diff PeerDrop/App/PeerDropApp.swift
```

Expected: no output (file unchanged from HEAD).

- [ ] **Step 5: No commit. This is a verification-only step.**

The fact that the build succeeded in Step 3 proves the wiring is correct. The revert leaves no trace.

---

## Task 5: Add `swift-build-macos` CI job (reviewer follow-up #2)

**Files:**
- Modify: `.github/workflows/ci.yml`

M1c reviewer recommended adding `swift build` as a macOS compile gate alongside xcodebuild. This catches accidental iOS-only API usage in PeerDropKit/Sources/ early — without it, an iOS-only API would only fail when M2 actually builds the macOS target (potentially weeks later).

- [ ] **Step 1: Read current workflow**

```bash
cat .github/workflows/ci.yml
```

Identify where to add the new job (top-level under `jobs:`).

- [ ] **Step 2: Add the new job**

Edit `.github/workflows/ci.yml`. Add a new job at the top-level `jobs:` section (after `lint-imports`):

```yaml
  swift-build-macos:
    name: Swift build (macOS host) — PeerDropKit compile gate
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: swift build from PeerDropKit/
        working-directory: PeerDropKit
        run: |
          swift build 2>&1
          # Exit code propagates: any compile failure (including
          # accidental iOS-only API usage in PeerDropKit/Sources/)
          # fails the job and blocks the PR.
```

This job runs `swift build` on macOS native (no iOS simulator) — so anything in PeerDropKit/Sources/ that doesn't compile for macOS 14+ (per the platforms declaration in Package.swift) fails the build.

Today PeerDropKit modules are empty `public enum X {}` placeholders that trivially compile on macOS. The real test of this gate comes in M1d-2+ when files migrate.

- [ ] **Step 3: Verify the workflow is valid YAML**

```bash
# Quick YAML sanity check
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" 2>&1
```

Expected: no output (valid YAML).

- [ ] **Step 4: Run `swift build` locally to confirm it succeeds (matches what CI will do)**

```bash
cd PeerDropKit && swift build 2>&1 | tail -5 && cd ..
```

Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci: add swift-build-macos job — PeerDropKit compile gate (m1d-1)

Addresses M1c reviewer follow-up #2: catch iOS-only API usage in
PeerDropKit/Sources/ at PR time rather than weeks later when M2
builds the macOS target.

Runs `swift build` from PeerDropKit/ on macos-15. Today the 5 empty
module placeholders trivially compile; the real test of this gate
comes in M1d-2 onwards when files migrate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final verification + tag M1d-1

**Files:**
- Verification only

- [ ] **Step 1: Run the full iOS test suite**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1d1-final-tests.log | tail -8
```

Expected: `** TEST SUCCEEDED **` with 1248 tests / 0 failures.

- [ ] **Step 2: Run `swift test` from PeerDropKit/ to verify the 5 placeholder tests pass**

```bash
cd PeerDropKit && swift test 2>&1 | tail -10 && cd ..
```

Expected: 5 tests executed, all pass.

- [ ] **Step 3: Verify package structure**

```bash
echo "=== PeerDropKit Tests ==="
find PeerDropKit/Tests -type f | sort

echo "=== Package.swift target count ==="
cd PeerDropKit && swift package describe 2>&1 | grep -E "^Target:" | head -20 && cd ..

echo "=== project.yml dependencies ==="
grep -A5 "    dependencies:" project.yml | head -20
```

Expected:
- 5 test files under Tests/
- 10 targets in Package.swift (5 product + 5 test)
- PeerDrop dependencies list includes `package: PeerDropKit`
- PeerDropTests dependencies list includes `package: PeerDropKit`

- [ ] **Step 4: Tag M1d-1**

```bash
git tag -a m1d-1-wire-and-scaffolding -m "M1d-1 done: PeerDropKit wired into app + test target; 5 testTargets scaffolded; CI macOS gate added. No source migrated yet (M1d-2+ does that)."
git log --oneline cb40599..HEAD
git tag --list | grep -E "m0|m1"
```

Expected: ~5 M1d-1 commits, 5 tags (m0, m1a, m1b, m1c, m1d-1).

## Done

M1d-1 complete. The plumbing is in place for M1d-2 to start migrating leaf modules (Protocol, Security, Pet). App + test targets can now `import PeerDropX`. CI has both an iOS (xcodebuild) and macOS (`swift build`) gate.

**Next:** M1d-2 plan (leaf modules migration: 11 + 28 + 61 source files + 324 Pet resource zips moving from `PeerDrop/Protocol/`, `PeerDrop/Security/`, `PeerDrop/Pet/` into PeerDropKit modules) by re-invoking `superpowers:writing-plans`.

## Open Items for M1d-2 / M1d-3 / M1d-4

1. **M1d-2:** migrate Protocol (11) + Security (28) + Pet (61 source + 324 resources). Each module is an atomic commit. Mark moved types `public`. Update all consumers' imports. Pet resources move to SPM `.process` bundle.
2. **M1d-3:** migrate Transport (16 + 6 Discovery + 6 Voice transport-side = 28 files). CallKitManager stays in app target (consistent with `CallProvider` from M1b — reviewer follow-up #1). Update PeerDropTransport's `.target` declaration if it needs additional sub-dependencies.
3. **M1d-4:** migrate Core (47 files). Widget rewires from path-references (7 specific .swift files) to `- package: PeerDropPet`. Remove now-unused direct WebRTC/ZIPFoundation deps from app target (only if app-level files no longer import them). Final lint-imports validation across all modules.
