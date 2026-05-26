# M1d-3b — Pet Module Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the Pet module — 61 source files (preserving 8 subdirs) + 324 resource zips + 63 test files — from `PeerDrop/Pet/` (non-UI) + `PeerDrop/Resources/Pets/` into `PeerDropKit/Sources/PeerDropPet/`. Rewire Widget from 8 path-references to consume `PeerDropPet` via SPM. After M1d-3b ships, only PeerDropTransport + PeerDropCore migrations remain in the M1 train.

**Architecture:** PeerDropPet target gains `dependencies: ["PeerDropPlatform", "PeerDropProtocol"]` (PetRendererV3 uses PlatformImage/PlatformGraphicsRenderer; PetSocialEngine uses ProtocolVersion). Pet/Resources/ moves into SPM `.process("Resources")` bundle accessible via `Bundle.module`. Pet/UI/ stays in app target (SwiftUI views — exempted from lint-imports) and gains `import PeerDropPet`.

**Tech Stack:** Swift 5.9, iOS 16+, macOS 14+, XcodeGen 2.45.4. Builds: `xcodebuild` (iOS app) + `swift build`/`swift test` (PeerDropKit).

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1d-3b.

**Predecessors (all merged):** M0, M1a, M1b, triage, M1c, M1d-1, M1d-2, M1d-3a.

**Pre-M1d-3a investigation findings (Task 7 of M1d-2's plan):**

### Source files (61 across 8 subdirs)

```
Behavior:    11 files
Engine:       7 files
Model:       16 files
Persistence:  2 files
Protocol:     1 file  (PetPayload.swift)
Renderer:     8 files
Shared:       4 files
Sprites:     12 files
```

All currently internal — all need `public` upgrade for cross-module access.

### Resource files: 324 zip files in `PeerDrop/Resources/Pets/`

### Test files: 63 total (29 top-level + 34 nested)

```bash
ls PeerDropTests/Pet*.swift                # 29 files
find PeerDropTests/Pet -name "*.swift"     # 34 files (in nested Pet/ subdir)
```

### External consumers (4 files needing `import PeerDropPet`)

1. `PeerDrop/App/PeerDropApp.swift` — PetEngine, PetState, PetStore, BodyGene
2. `PeerDrop/Core/ScreenshotModeProvider.swift` — PetGenome, PetState, SocialEntry
3. `PeerDrop/UI/Chat/ChatView.swift` — PetEngine
4. `PeerDrop/UI/ContentView.swift` — PetEngine

Plus `PeerDrop/Pet/UI/*.swift` (~14 files) — SwiftUI views in app target that use Pet types. Each needs `import PeerDropPet` added.

### Bundle.main sites (4 — change to Bundle.module after migration)

1. `Pet/Renderer/AccessoryOverlay.swift:23` — `bundle: Bundle = .main` default param
2. `Pet/Renderer/SpriteSheetLoader.swift:59` — `Bundle.main.url(forResource:withExtension:)`
3. `Pet/Sprites/SpriteService.swift:34` — `bundle: Bundle = .main` init default
4. `Pet/Sprites/SpriteAssetResolver.swift:65` — `bundle: Bundle = .main` static func default

### Widget path-references (drop 8 in Task 9; replace with `package: PeerDropPet`)

Currently `project.yml` PeerDropWidget target lists:
1. `PeerDrop/Pet/Shared` (folder-ref — 4 files)
2. `PeerDrop/Pet/Renderer/PetPalettes.swift`
3. `PeerDrop/Pet/Model/PetGenome.swift`
4. `PeerDrop/Pet/Model/PetLevel.swift`
5. `PeerDrop/Pet/Model/PetAction.swift`
6. `PeerDrop/Pet/Model/PetMood.swift`
7. `PeerDrop/Pet/Model/PetSurface.swift`
8. `PeerDrop/Pet/Model/InteractionType.swift`

After M1d-3b: all 8 drop; Widget gains `- package: PeerDropKit / product: PeerDropPet` dep; Widget .swift files gain `import PeerDropPet`.

### Inter-leaf references

- Pet → PeerDropPlatform: PetRendererV3 + PetEngine + Pet/Renderer/MoodOverlay + RarityOverlay + AccessoryOverlay use Platform types. PeerDropPet target needs `dependencies: ["PeerDropPlatform"]`.
- Pet → PeerDropProtocol: PetSocialEngine uses ProtocolVersion. PeerDropPet target needs `dependencies: ["PeerDropPlatform", "PeerDropProtocol"]`.
- Pet → Security: None.
- Pet → app-target-only types: ZERO after M1d-3a (Platform extraction resolved the cycle).

---

## File Structure

**Source migration (atomic per task):**
- Task 2 commit moves 61 .swift files from `PeerDrop/Pet/{Behavior,Engine,Model,Persistence,Protocol,Renderer,Shared,Sprites}/` → `PeerDropKit/Sources/PeerDropPet/` (preserving 8 subdirs)

**Tests:**
- Task 6 moves 63 test files

**Resources:**
- Task 7 moves 324 zips into SPM bundle

**Consumer updates:**
- Task 5 adds imports to 4 main consumers + Pet/UI files
- Task 9 rewires Widget

---

## Task 1: Pre-migration audit + verify Pet/UI consumer count

**Files:** (analysis only)

The plan above estimates ~14 Pet/UI files. Confirm exact count + which Pet types each uses.

- [ ] **Step 1: Inventory Pet/UI files**

```bash
find PeerDrop/Pet/UI -name "*.swift" | sort
find PeerDrop/Pet/UI -name "*.swift" | wc -l
```

Note count.

- [ ] **Step 2: Per Pet/UI file, find which Pet types it uses**

```bash
for f in PeerDrop/Pet/UI/*.swift; do
    echo "=== $(basename "$f") ==="
    grep -oE "Pet[A-Z][a-zA-Z]+|SpeciesID|SpeciesCatalog|SpriteService|BodyGene|InteractionType|SharedRenderedPet|ColorPalette|PetPalettes|Rarity[A-Za-z]*" "$f" | sort -u | head
done
```

Each file needs `import PeerDropPet` after migration. Build list.

- [ ] **Step 3: Check for nested-Pet test fixtures**

```bash
ls PeerDropTests/Pet/Fixtures 2>/dev/null
```

If there are test fixtures (JSON, PNG, etc.), note them — they need handling like the Pets/ resources but in the test bundle.

- [ ] **Step 4: Check if MainBundleAssetCoverageTests references resource paths**

```bash
grep -n "Bundle.main\|Pets/" PeerDropTests/Pet/MainBundleAssetCoverageTests.swift 2>/dev/null
```

This test is critical — it validates Pet asset bundle integrity. If it loads via `Bundle.main`, after Pet migrates it needs to load via `Bundle.module` (or via PeerDropPet's bundle accessor). Note line numbers + how it currently accesses the bundle.

- [ ] **Step 5: No commit. Report findings.**

```
## Pet migration audit

### Pet/UI files (N total)
- <list>
- Pet types used: <per file>

### Test fixtures (if any)
- <list>

### MainBundleAssetCoverageTests bundle access pattern
- <quote relevant lines>
- Resolution strategy: update to Bundle.module post-migration

### Total consumer files needing `import PeerDropPet`
- 4 main (App + Core/ScreenshotModeProvider + UI/ChatView + UI/ContentView)
- N Pet/UI files
- Total: 4 + N
```

---

## Task 2: Migrate 61 Pet source files

**Files:**
- Move: 61 .swift files preserving 8 subdir structure
- Delete: `PeerDropKit/Sources/PeerDropPet/PeerDropPet.swift` (placeholder)

- [ ] **Step 1: Move source files preserving subdirs**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"

for subdir in Behavior Engine Model Persistence Protocol Renderer Shared Sprites; do
    mkdir -p "PeerDropKit/Sources/PeerDropPet/$subdir"
    for f in PeerDrop/Pet/$subdir/*.swift; do
        if [ -f "$f" ]; then
            git mv "$f" "PeerDropKit/Sources/PeerDropPet/$subdir/"
        fi
    done
    rmdir "PeerDrop/Pet/$subdir" 2>/dev/null
done

# Delete placeholder
git rm PeerDropKit/Sources/PeerDropPet/PeerDropPet.swift
```

Verify:
```bash
find PeerDropKit/Sources/PeerDropPet -name "*.swift" | wc -l   # 61
ls PeerDrop/Pet/Engine 2>&1                                    # should error
# Pet/UI/ should still exist (stays in app target):
ls PeerDrop/Pet/UI | head
```

- [ ] **Step 2: Don't build yet — Tasks 3+4+5 need to land for build to compile**

The state after Task 2 is intentionally broken. Tasks 3 (public upgrades + Package.swift deps), 4 (Bundle.main → .module), 5 (consumer imports) fix it.

---

## Task 3: Mark Pet types public + update Package.swift

**Files:**
- Modify: all 61 Pet source files (public upgrades)
- Modify: `PeerDropKit/Package.swift` — PeerDropPet target gains deps

- [ ] **Step 1: Add Package.swift deps**

Edit `PeerDropKit/Package.swift`. Find PeerDropPet target. Update:

```swift
.target(
    name: "PeerDropPet",
    dependencies: [
        "PeerDropPlatform",       // PetRendererV3 uses PlatformImage etc.
        "PeerDropProtocol",       // PetSocialEngine uses ProtocolVersion
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
    ]
),
```

- [ ] **Step 2: Mark Pet types public**

For each file in `PeerDropKit/Sources/PeerDropPet/{Behavior,Engine,Model,Persistence,Protocol,Renderer,Shared,Sprites}/*.swift`:

1. Top-level type declaration → `public`
2. Stored properties accessed by external consumers (UI, App, etc.) → `public`
3. Explicit `public init` for types instantiated by external consumers

Practical approach: do the obvious upgrades, then build, then fix any "inaccessible" errors.

Key types most consumed by external code (prioritize):
- `PetEngine` (Engine/PetEngine.swift) + its public API
- `PetGenome`, `BodyGene`, `EyeGene`, `LimbGene`, `PatternGene`, `SpeciesID`, `Rarity`, `VariantSpec`, `VariantTrait` (Model/PetGenome.swift, Sprites/SpeciesCatalog.swift, Sprites/SpeciesID.swift)
- `PetState`, `PetMood`, `PetAction`, `PetLevel`, `PetSurface`, `InteractionType` (Model/)
- `SocialEntry` (Model/SocialEntry.swift)
- `PetStore` (Persistence/)
- `SharedRenderedPet`, `IslandPose`, `PetActivityAttributes`, `SharedPetState`/`PetSnapshot` (Shared/)
- `ColorPalette`, `PetPalettes` (Renderer/)
- `SpeciesCatalog`, `SpriteService`, `SpriteCache`, `SpriteRequest`, `SpriteAssetResolver` (Sprites/)

- [ ] **Step 3: Don't build yet — Task 4 + 5 needed**

---

## Task 4: Bundle.main → Bundle.module (4 sites)

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropPet/Renderer/AccessoryOverlay.swift` — `Bundle = .main` → `Bundle = .module`
- Modify: `PeerDropKit/Sources/PeerDropPet/Renderer/SpriteSheetLoader.swift` — `Bundle.main.url(...)` → `Bundle.module.url(...)`
- Modify: `PeerDropKit/Sources/PeerDropPet/Sprites/SpriteService.swift` — `bundle: Bundle = .main` → `bundle: Bundle = .module`
- Modify: `PeerDropKit/Sources/PeerDropPet/Sprites/SpriteAssetResolver.swift` — `bundle: Bundle = .main` → `bundle: Bundle = .module`

For each file, use Edit to make the 1-token change `.main` → `.module`.

After this, Pet code loads resources from PeerDropPet's SPM bundle. Resources don't yet exist in the bundle — Task 7 moves them.

(NOTE: between Task 4 commit and Task 7 commit, runtime Pet sprite loading would fail because Bundle.module is empty. Build still works. Don't ship a half-state — Tasks 4+5+6+7 all need to land together. Or commit per-task with explicit "BROKEN" notes per M1d-2 Pet pattern.)

Actually: SIMPLER STRATEGY — do Tasks 2+3+4+5+6+7 as ONE big commit (or 2 commits: source migration + resource migration). This avoids intermediate broken states. The diff will be huge (~150 files) but each is a mechanical change.

**Decision for this plan**: combine Tasks 2-5 into a single commit (source migration + public + Bundle.module + consumer imports). Task 6 = test migration as separate commit. Task 7 = resource migration as separate commit. Task 8 = project.yml folder ref + excludes cleanup. Task 9 = Widget rewire. Task 10 = final.

Updated commit plan:
- Commit A (Tasks 2+3+4+5): source migration + public + Bundle.module + consumer imports
- Commit B (Task 6): test migration
- Commit C (Task 7): resource migration + Package.swift .process + project.yml folder-ref drop
- Commit D (Task 9): Widget rewire
- Commit E (Task 10 if needed): final verification fixes

---

## Task 5: Add `import PeerDropPet` to external consumers + Pet/UI

**Files:**
- Modify: 4 main consumers
- Modify: ~N Pet/UI files (per Task 1 audit)

- [ ] **Step 1: Main consumers**

Add `import PeerDropPet` to each:

```bash
# Each file: add line after existing imports
PeerDrop/App/PeerDropApp.swift
PeerDrop/Core/ScreenshotModeProvider.swift
PeerDrop/UI/Chat/ChatView.swift
PeerDrop/UI/ContentView.swift
```

- [ ] **Step 2: Pet/UI files**

For each file under `PeerDrop/Pet/UI/`, add `import PeerDropPet` after existing imports.

Use the Task 1 audit to identify exact files + their import needs.

### Step 3: xcodegen + iOS build (should now succeed after Tasks 2+3+4+5 commit)

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. Iterate on errors:
- "Cannot find type 'X'" → consumer missing `import PeerDropPet`
- "X is inaccessible" → type needs `public` (back to Task 3)
- "Bundle.module not found" → check Bundle.module usage is inside PeerDropPet target

NOTE: runtime resource loading will fail (Bundle.module is empty until Task 7) but BUILD is fine.

### Step 4: Commit (Tasks 2+3+4+5 combined)

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-3b): migrate Pet source into PeerDropPet (RUNTIME BROKEN — Task 7 moves resources)

61 source files moved from PeerDrop/Pet/{Behavior,Engine,Model,Persistence,
Protocol,Renderer,Shared,Sprites}/ to PeerDropKit/Sources/PeerDropPet/
(preserving subdir structure). Placeholder enum deleted.

Pet types marked public for cross-module access. Bundle.main → Bundle.module
in 4 sites (AccessoryOverlay, SpriteSheetLoader, SpriteService,
SpriteAssetResolver) — runtime resource loading will fail until Task 7
moves the 324 Pet zips into PeerDropPet's SPM bundle.

PeerDropPet target gains dependencies: ["PeerDropPlatform", "PeerDropProtocol"]
(PetRendererV3 needs Platform; PetSocialEngine needs ProtocolVersion).

External consumers gain `import PeerDropPet`:
- 4 main consumers (App, Core/ScreenshotModeProvider, UI/Chat/ChatView, UI/ContentView)
- N Pet/UI files (SwiftUI views in app target)

iOS build passes; tests in PeerDropTests/Pet*.swift will fail at runtime
until Task 7. Tests migrated in Task 6 + resources moved in Task 7
fully restore.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate Pet tests into PeerDropPetTests

**Files:**
- Move: 29 top-level test files + 34 nested test files → `PeerDropKit/Tests/PeerDropPetTests/`
- Modify: each test file's `@testable import PeerDrop` → `@testable import PeerDropPet`

- [ ] **Step 1: Move test files preserving structure where useful**

```bash
# Top-level Pet tests
for f in PeerDropTests/Pet*.swift; do
    git mv "$f" PeerDropKit/Tests/PeerDropPetTests/
done

# Nested Pet/ subdir tests
if [ -d PeerDropTests/Pet ]; then
    # Preserve any subdir structure inside PeerDropTests/Pet/
    for f in PeerDropTests/Pet/*.swift; do
        git mv "$f" PeerDropKit/Tests/PeerDropPetTests/
    done
    for sub in $(find PeerDropTests/Pet -mindepth 1 -type d); do
        subname=$(basename "$sub")
        mkdir -p "PeerDropKit/Tests/PeerDropPetTests/$subname"
        for f in "$sub"/*.swift; do
            if [ -f "$f" ]; then
                git mv "$f" "PeerDropKit/Tests/PeerDropPetTests/$subname/"
            fi
        done
    done
    rm -rf PeerDropTests/Pet
fi

# Delete placeholder
git rm PeerDropKit/Tests/PeerDropPetTests/PeerDropPetTests.swift
```

Verify:
```bash
find PeerDropKit/Tests/PeerDropPetTests -name "*.swift" | wc -l   # ~63
ls PeerDropTests/Pet 2>&1                                          # should error
ls PeerDropTests/PetEngineTests.swift 2>&1                         # should error
```

- [ ] **Step 2: Update `@testable import` in moved files**

```bash
for f in $(find PeerDropKit/Tests/PeerDropPetTests -name "*.swift"); do
    sed -i '' 's/@testable import PeerDrop$/@testable import PeerDropPet/g' "$f"
done
```

Some Pet tests also use Protocol/Security types — add additional `@testable import PeerDropProtocol` / `@testable import PeerDropSecurity` where build errors surface.

- [ ] **Step 3: Run swift test (resources not yet moved; some tests will fail at runtime)**

```bash
cd PeerDropKit && swift test --filter PeerDropPetTests 2>&1 | tail -20 && cd ..
```

Expected: most tests run. Tests that load Pet resources via Bundle.module will FAIL (resources not yet present — Task 7 moves them). Count failures; expect them to be resource-loading failures specifically.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-3b): migrate Pet tests into PeerDropPetTests

63 test files moved from PeerDropTests/Pet*.swift (29) +
PeerDropTests/Pet/ (34) to PeerDropKit/Tests/PeerDropPetTests/
(preserving any nested subdir structure).

@testable imports updated PeerDrop → PeerDropPet. Tests using
Protocol/Security types add additional @testable imports.

Tests that load Pet resources still fail at runtime until Task 7
moves the 324 zips into SPM bundle. iOS test count drops by 63.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Move Pet resources into SPM bundle

**Files:**
- Move: 324 zip files from `PeerDrop/Resources/Pets/` → `PeerDropKit/Sources/PeerDropPet/Resources/Pets/`
- Modify: `PeerDropKit/Package.swift` — PeerDropPet target gains `resources: [.process("Resources")]`
- Modify: `project.yml` — drop the Pet/Resources folder reference + excludes pattern from PeerDrop target

- [ ] **Step 1: Move 324 resources**

```bash
mkdir -p PeerDropKit/Sources/PeerDropPet/Resources/Pets
git mv PeerDrop/Resources/Pets PeerDropKit/Sources/PeerDropPet/Resources/Pets

# rmdir if Resources/ is now empty
rmdir PeerDrop/Resources 2>/dev/null
```

This is a HUGE git mv (324 files in one commit). Verify:
```bash
git status | grep -c "renamed:"   # ~324
find PeerDropKit/Sources/PeerDropPet/Resources/Pets -name "*.zip" | wc -l   # 324
```

Wait — `git mv` on a directory might fail or behave unexpectedly. If the above fails, do it file-by-file:

```bash
mkdir -p PeerDropKit/Sources/PeerDropPet/Resources/Pets
for f in PeerDrop/Resources/Pets/*.zip; do
    git mv "$f" PeerDropKit/Sources/PeerDropPet/Resources/Pets/
done

# Subdirs if any
for sub in $(find PeerDrop/Resources/Pets -mindepth 1 -type d); do
    subname=$(basename "$sub")
    mkdir -p "PeerDropKit/Sources/PeerDropPet/Resources/Pets/$subname"
    for f in "$sub"/*; do
        git mv "$f" "PeerDropKit/Sources/PeerDropPet/Resources/Pets/$subname/"
    done
done

rmdir PeerDrop/Resources/Pets 2>/dev/null
rmdir PeerDrop/Resources 2>/dev/null
```

- [ ] **Step 2: Update Package.swift**

Edit `PeerDropKit/Package.swift`. PeerDropPet target:

```swift
.target(
    name: "PeerDropPet",
    dependencies: [
        "PeerDropPlatform",
        "PeerDropProtocol",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
    ],
    resources: [
        .process("Resources"),
    ]
),
```

`.process` (vs `.copy`) lets SPM apply platform-specific transformations (no-op for zips but standard practice).

- [ ] **Step 3: Update project.yml**

Edit `project.yml`. Find PeerDrop target's `sources:` section:

```yaml
# Before (lines 26-39):
    sources:
      - path: PeerDrop
        # Pets/ is registered separately as a folder reference below — exclude
        # it from the default per-file scan so we don't get 324 PBXFileReference
        # entries cluttering the project file.
        excludes:
          - "Resources/Pets/**"
      - path: PeerDrop/Resources/Pets
        type: folder

# After:
    sources:
      - path: PeerDrop
```

(Drop the excludes block + the explicit Resources/Pets folder reference. Same edit applies to PeerDropTests target if it has the same pattern — check.)

- [ ] **Step 4: xcodegen + build + run Pet tests via swift test**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
cd PeerDropKit && swift test --filter PeerDropPetTests 2>&1 | tail -15 && cd ..
```

Expected: `** BUILD SUCCEEDED **`. Pet tests now find resources via Bundle.module — most should pass.

If `MainBundleAssetCoverageTests` fails: check if it was loading via Bundle.main (old app bundle path) and needs to update to Bundle.module. Per Task 1 audit's resolution strategy.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-3b): move 324 Pet resource zips into PeerDropPet SPM bundle

git mv PeerDrop/Resources/Pets/ → PeerDropKit/Sources/PeerDropPet/Resources/Pets/

PeerDropPet Package.swift target gains `resources: [.process("Resources")]`
— SPM ships the zips in Bundle.module.

project.yml drops the now-moot:
- excludes: ["Resources/Pets/**"] pattern
- explicit PeerDrop/Resources/Pets folder reference

Pet runtime resource loading via Bundle.module now works. Tests
that previously failed (post-Task-4 Bundle.module switch) now pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Update PeerDropTests project.yml (if it referenced PeerDrop/Resources/Pets)

**Files:**
- Modify: `project.yml` — PeerDropTests target

- [ ] **Step 1: Check if PeerDropTests had the folder reference**

```bash
sed -n '115,135p' project.yml
```

If PeerDropTests target lists `- path: PeerDrop/Resources/Pets type: folder` or `excludes: - "Resources/Pets/**"`, remove that.

If PeerDropTests has its own `path: PeerDropTests/Resources/Pets type: folder` for TEST fixtures (separate from production), LEAVE THAT. The production resource move only affects PeerDrop target.

- [ ] **Step 2: xcodegen + verify**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tail -8
```

- [ ] **Step 3: Commit if any change was needed**

If no edit was required, mark Task 8 complete via the closing report without a commit.

---

## Task 9: Widget rewire

**Files:**
- Modify: `project.yml` — PeerDropWidget target
- Modify: PeerDropWidget .swift files (add `import PeerDropPet`)

- [ ] **Step 1: Read current Widget config**

```bash
sed -n '146,200p' project.yml
```

Identify the 8 path-references (Pet/Shared folder + 7 individual Pet/Model + Pet/Renderer files).

- [ ] **Step 2: Update Widget target**

Edit `project.yml`. Replace the Widget target's sources + dependencies block:

```yaml
# Before:
  PeerDropWidget:
    type: app-extension
    platform: iOS
    sources:
      - PeerDropWidget
      - path: PeerDrop/Pet/Shared
      - path: PeerDrop/Pet/Renderer/PetPalettes.swift
      - path: PeerDrop/Pet/Model/PetGenome.swift
      - path: PeerDrop/Pet/Model/PetLevel.swift
      - path: PeerDrop/Pet/Model/PetAction.swift
      - path: PeerDrop/Pet/Model/PetMood.swift
      - path: PeerDrop/Pet/Model/PetSurface.swift
      - path: PeerDrop/Pet/Model/InteractionType.swift
    info: ...

# After:
  PeerDropWidget:
    type: app-extension
    platform: iOS
    sources:
      - PeerDropWidget
    dependencies:
      - package: PeerDropKit
        product: PeerDropPet
    info: ...
```

Preserve all other Widget config (info, settings, entitlements) unchanged.

- [ ] **Step 3: Add `import PeerDropPet` to PeerDropWidget .swift files**

Each Widget .swift file that uses Pet types needs the import:

```bash
grep -l "PetGenome\|SpeciesCatalog\|PetMood\|BodyGene\|InteractionType\|ColorPalette\|PetPalettes\|PetState\|PetLevel\|PetAction\|PetSurface\|SharedRenderedPet" PeerDropWidget/*.swift
```

For each match, add `import PeerDropPet` after existing imports.

- [ ] **Step 4: Build + test**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10
```

Iterate on Widget errors:
- "Cannot find type 'X'" → that Widget file needs `import PeerDropPet`
- "Cannot find package product 'PeerDropPet'" → project.yml dep wasn't added correctly

Full iOS test sweep:
```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tail -8
```

Expected: iOS test count down to ~1025 (1088 - 63 Pet tests now in swift test). 0 failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-3b): Widget consumes PeerDropPet (drops 8 path-references)

PeerDropWidget no longer path-references individual Pet/Shared + Pet/Renderer
+ Pet/Model files. Now consumes `package: PeerDropKit / product: PeerDropPet`
and imports PeerDropPet types via standard SPM mechanism.

Widget .swift files gain `import PeerDropPet`.

This was the "poor man's shared module" pattern flagged in M1c — Widget
is now wired the same way as the app target.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Final verification + tag

- [ ] **Step 1: Full sweeps**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1d3b-final-ios.log | tail -8

cd PeerDropKit && swift test 2>&1 | tee /tmp/m1d3b-final-swift.log | tail -10 && cd ..
```

Expected:
- iOS: ~1025 / 0 failures
- swift test: PeerDropPlatformTests (3) + PeerDropProtocolTests (1 placeholder) + PeerDropSecurityTests (162) + PeerDropPetTests (~63) + PeerDropCoreTests (1 placeholder) + PeerDropTransportTests (1 placeholder) = ~231

Total: ~1256

- [ ] **Step 2: Verify structure**

```bash
echo "=== Pet/ should only have UI/ left ==="
ls PeerDrop/Pet
echo "=== Resources/ should be gone or empty ==="
ls PeerDrop/Resources 2>&1
echo "=== PeerDropPet content ==="
find PeerDropKit/Sources/PeerDropPet -name "*.swift" | wc -l   # 61
find PeerDropKit/Sources/PeerDropPet/Resources -name "*.zip" | wc -l   # 324
echo "=== PeerDropPetTests ==="
find PeerDropKit/Tests/PeerDropPetTests -name "*.swift" | wc -l   # ~63
```

- [ ] **Step 3: Tag M1d-3b**

```bash
git tag -a m1d-3b-pet-migration -m "M1d-3b done: Pet migrated into PeerDropPet (61 source + 324 resources + 63 tests). Widget rewires. Only Transport + Core migrations remain in M1 train."

git log --oneline 0b8c25a..HEAD
git tag --list | grep -E "m0|m1"
```

Expected: ~5 M1d-3b commits, 8 tags total (m0, m1a, m1b, m1c, m1d-1, m1d-2, m1d-3a, m1d-3b).

## Done

M1d-3b complete. PeerDropPet has real content. Widget consumes PeerDropKit cleanly. Pet/UI/ stays in app target (SwiftUI views).

**Next:** M1d-4 plan (Transport migration: 28 files = 16 Transport + 6 Discovery + 6 Voice transport-side) by re-invoking `superpowers:writing-plans`.

## Open Items for M1d-4 / M1d-5

1. **M1d-4** (Transport): may need PeerDropPlatform + PeerDropProtocol + PeerDropSecurity deps (TBD via audit). CallKitManager stays in app target.
2. **M1d-5** (Core): now smaller (~28 files; Platform/ + HapticManager extracted in M1d-3a). PeerIdentity placement decision. Remove unused WebRTC/ZIPFoundation deps from app target.
3. Consider moving PlatformImageTests + PlatformGraphicsRendererTests from PeerDropTests to PeerDropPlatformTests if they can be rewritten to be macOS-compatible (M1d-3a deferral).
