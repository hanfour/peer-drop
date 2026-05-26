# M1d-2 — Leaf Modules Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate 3 leaf modules (Protocol, Security, Pet) from `PeerDrop/` into `PeerDropKit/Sources/`. After M1d-2 ships:
- 11 + 28 + 61 = **100 source files** live in PeerDropKit modules
- 324 Pet resource zips live in PeerDropKit's SPM `.process` bundle
- ~89 test files live in PeerDropKit/Tests/
- Widget consumes PeerDropPet (via SPM package dep) instead of path-references to 7 specific .swift files
- App-level consumers gain `import PeerDropProtocol`/`PeerDropSecurity`/`PeerDropPet` as needed
- Types crossing module boundaries are `public` (or moved if mis-assigned)

**Architecture:** Each leaf migrates as one atomic commit. Build must pass after each commit. Order: **Protocol → Security → Pet**, smallest-to-largest. Cross-leaf references (e.g., `PeerDrop/Protocol/PeerMessage.swift` referencing Security types) are resolved per-commit by either moving the type OR adding `import` to the consumer file (within the same commit).

**Tech Stack:** Swift 5.9, iOS 16+, macOS 14+, XcodeGen 2.45.4. Builds: `xcodebuild` (iOS app) + `swift build`/`swift test` (PeerDropKit standalone).

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1d-2.

**Predecessors (all merged to main):**
- M0 (`a3f6ba1`), M1a (`32e1e3d`), M1b (`3e3946b`), triage (`84add66`), M1c (`cb40599`), M1d-1 (`ab079cc`)

**Investigation findings:**
- Protocol/: 11 source files, 2 test files. Mostly Codable payloads — `public` upgrade is mechanical.
- Security/: 28 source files (incl. 8 in Security/Protocol/ — X3DH, DoubleRatchet, etc.), ~22 test files plus the **CryptoTestKit** nested test-helper (4 sources + 7 tests + JSON vectors).
- Pet/: 61 source files across 8 subdirs (Behavior/Engine/Model/Persistence/Protocol/Renderer/Shared/Sprites — UI/ stays in app). ~64 test files. **324 zip resources** in `PeerDrop/Resources/Pets/`.
- **Bundle.main → Bundle.module:** 4 sites (Pet/Renderer/AccessoryOverlay, Pet/Renderer/SpriteSheetLoader, Pet/Sprites/SpriteService, Pet/Sprites/SpriteAssetResolver). All use `Bundle = .main` as default param — just change `.main` to `.module`.
- **External consumers** (need `import PeerDropX` added after migration):
  - Pet: 5 files (UI/ContentView, UI/Chat/ChatView, Core/ScreenshotModeProvider, Core/Platform/PlatformGraphicsRenderer, App/PeerDropApp)
  - Security: ~11 files (Core/*, Transport/OutboundRetryQueue, UI/Chat/*, UI/Connection/ConnectionQRView, Protocol/PeerMessage)
  - Protocol: ~15+ files (Transport/*, Core/*, Security/*, Extensions/NWConnection+Async, UI/*)
- **Inter-leaf cross-references**: `PeerDrop/Protocol/PeerMessage.swift` may use Security types. If yes, PeerMessage must add `import PeerDropSecurity` (since Protocol can't depend on Security per spec §1). Resolved during Protocol migration commit.

---

## File Structure

**Source migration (atomic commits per module):**
- M1d-2 Task 2 commit moves `PeerDrop/Protocol/*.swift` → `PeerDropKit/Sources/PeerDropProtocol/`
- M1d-2 Task 5 commit moves `PeerDrop/Security/*.swift` (incl. `Security/Protocol/`) → `PeerDropKit/Sources/PeerDropSecurity/`
- M1d-2 Task 8 commit moves `PeerDrop/Pet/{Behavior,Engine,Model,Persistence,Protocol,Renderer,Shared,Sprites}/*.swift` → `PeerDropKit/Sources/PeerDropPet/` (PRESERVE subdirectory structure)
- M1d-2 Task 9 commit moves `PeerDrop/Resources/Pets/` → `PeerDropKit/Sources/PeerDropPet/Resources/Pets/` + Package.swift declares `.process("Resources")`

**Test migration:**
- Task 3 moves Protocol tests
- Task 6 moves Security tests + CryptoTestKit
- Task 8 moves Pet tests

**Consumer updates per migration:**
- Each migration commit updates consumer files in the same commit (add `import PeerDropX`, optionally rename types if access changed)

**Placeholder file fate:** the 5 `PeerDropKit/Sources/<Module>/<Module>.swift` placeholder files from M1c will be DELETED as part of each migration commit — once the module has real content, the `public enum X {}` stub is unnecessary clutter.

**Test placeholder fate:** the 5 `PeerDropKit/Tests/<Module>Tests/<Module>Tests.swift` placeholders from M1d-1 will be DELETED as real tests migrate in. (PeerDropTransport's + PeerDropCore's placeholders stay until M1d-3/M1d-4.)

---

## Task 1: Pre-Protocol audit — identify cross-leaf references

**Files:** (analysis only; no edits)

This task gathers data BEFORE moving Protocol files. It identifies which Protocol types need to be `public` and which Protocol files have cross-leaf dependencies that need handling.

- [ ] **Step 1: Inventory all Protocol files**

```bash
ls PeerDrop/Protocol/
```

Expected: 11 files (ClipboardSyncPayload, FileResumePayload, MediaMessagePayload, MessageEditPayload, MessageReceiptPayload, MessageType, PeerMessage, ProtocolVersion, ReactionPayload, TextMessagePayload, TypingIndicatorPayload).

- [ ] **Step 2: Find all Protocol type names used externally**

For each Protocol file, find its top-level type declarations:

```bash
for f in PeerDrop/Protocol/*.swift; do
    echo "=== $(basename "$f") ==="
    grep -E "^(public |internal |private |fileprivate )?(struct|class|enum|protocol|typealias) " "$f"
done
```

Build a list of every type the module exports.

- [ ] **Step 3: Find external consumers**

```bash
grep -rln "MessageType\|PeerMessage\|ProtocolVersion\|ClipboardSyncPayload\|TextMessagePayload\|MediaMessagePayload\|TypingIndicatorPayload\|ReactionPayload\|MessageEditPayload\|MessageReceiptPayload\|FileResumePayload" PeerDrop/ --include="*.swift" | grep -v "/Protocol/" | sort -u
```

Each match needs `import PeerDropProtocol` added (or the file moves into PeerDropProtocol if it's logically part of the module).

- [ ] **Step 4: Check inter-leaf references**

Critical: does `PeerDrop/Protocol/PeerMessage.swift` (or any other Protocol file) reference Security types? If yes, PeerMessage needs `import PeerDropSecurity` after migration (Protocol depends on nothing per spec §1, but a CONSUMER file inside Protocol's module can still import Security — though it's cleaner if Protocol stays pure).

```bash
grep -n "PeerIdentity\|TrustedContact\|ChatDataEncryptor\|IdentityKeyManager\|TLSConfiguration\|SecurityPolicy\|KeyExchangeMessage" PeerDrop/Protocol/*.swift
```

If matches surface, decide per file:
- If the Security reference is **central** to the file's purpose → consider whether the file actually belongs in PeerDropSecurity instead of PeerDropProtocol
- If it's **incidental** → keep in PeerDropProtocol but plan to add `import PeerDropSecurity` (which means Protocol does need to import Security; spec §1 said Protocol is a leaf with no deps but reality may force adjustment)

Report findings as a brief inventory list.

- [ ] **Step 5: No commit. This is analysis-only.**

Output of this task informs Task 2's exact migration plan. Specifically:
- List of type names → `public` upgrade needed
- List of external consumer files → `import PeerDropProtocol` to add
- Decisions on any cross-leaf references

---

## Task 2: Migrate Protocol files into PeerDropProtocol module

**Files:**
- Move: 11 files from `PeerDrop/Protocol/` → `PeerDropKit/Sources/PeerDropProtocol/`
- Delete: `PeerDropKit/Sources/PeerDropProtocol/PeerDropProtocol.swift` (placeholder)
- Modify: external consumers (~15+ files) to add `import PeerDropProtocol`
- Modify: each moved file — change type/member access from default (`internal`) to `public` for types used externally
- Modify: `project.yml` — REMOVE `PeerDrop/Protocol/` from app target's sources excludes if listed (or leave alone if it's not — depends on existing config)

This is the FIRST real migration. The build must pass after this commit. Test count must remain 1248 / 0.

- [ ] **Step 1: Move source files**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"
# Use git mv to preserve file history
for f in PeerDrop/Protocol/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropProtocol/
done
rmdir PeerDrop/Protocol
```

Then delete the placeholder:

```bash
git rm PeerDropKit/Sources/PeerDropProtocol/PeerDropProtocol.swift
```

- [ ] **Step 2: Mark types public**

For each .swift file now in `PeerDropKit/Sources/PeerDropProtocol/`, edit to make top-level types and their members `public`.

Example: if `MessageType.swift` has:

```swift
enum MessageType: String, Codable {
    case text, image, file, ...
}
```

Change to:

```swift
public enum MessageType: String, Codable {
    case text, image, file, ...
}
```

For struct/class types with members that consumers access, also make those members `public`. For Codable types specifically, the Codable conformance auto-synthesizes its members — for consumers to access stored properties, those properties also need `public`.

Pattern for a typical payload:

```swift
// Before
struct TextMessagePayload: Codable {
    let id: UUID
    let text: String
    let timestamp: Date
}

// After
public struct TextMessagePayload: Codable {
    public let id: UUID
    public let text: String
    public let timestamp: Date

    public init(id: UUID, text: String, timestamp: Date) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}
```

Note the explicit `public init` — Swift's auto-synthesized memberwise init is internal by default, so if external consumers create instances, you need a public init.

- [ ] **Step 3: Add `import PeerDropProtocol` to external consumers**

Find consumers:

```bash
grep -rln "MessageType\|PeerMessage\|ProtocolVersion\|ClipboardSyncPayload\|TextMessagePayload\|MediaMessagePayload\|TypingIndicatorPayload\|ReactionPayload\|MessageEditPayload\|MessageReceiptPayload\|FileResumePayload" PeerDrop/ --include="*.swift" | grep -v "PeerDropKit/" | sort -u
```

For each consumer file, add `import PeerDropProtocol` after its existing imports. (Use Edit tool — single line addition per file.)

- [ ] **Step 4: Handle cross-leaf references (if any from Task 1)**

If `PeerMessage.swift` (or any other migrated Protocol file) imports Security types, decide:
- Add `import PeerDropSecurity` to that file (acceptable — leaf modules CAN have leaf-to-leaf deps if the spec graph permits; in this case it'd mean updating spec §1's "Protocol has no deps" to "Protocol depends on Security")
- OR move the file to PeerDropSecurity if it's actually a Security thing (e.g., KeyExchangeMessage already lives in Security; PeerMessage probably shouldn't)
- OR move just the Security-dependent type out of Protocol into Security

Apply the resolution. If Protocol ends up depending on Security:
- Update `PeerDropKit/Package.swift` — add `dependencies: ["PeerDropSecurity"]` to the PeerDropProtocol target

- [ ] **Step 5: xcodegen + build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`. Common failures + fixes:
- "No such module 'PeerDropProtocol'" in a file → that consumer needs `import PeerDropProtocol`
- "Type 'X' has no member 'Y'" → Y needs to be `public` in the new module
- "Initializer is inaccessible due to 'internal' protection" → add `public init`

Iterate until build passes.

- [ ] **Step 6: Full iOS test run**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1d2-task2-tests.log | tail -8
```

Expected: `** TEST SUCCEEDED **`, 1248 / 0.

- [ ] **Step 7: swift build + swift test from PeerDropKit/**

```bash
cd PeerDropKit && swift build && swift test 2>&1 | tail -10 && cd ..
```

Expected: PeerDropProtocol compiles standalone; the placeholder `test_moduleIsLinkable` for Protocol now fails to compile (because the placeholder file was deleted in Step 1 — the test file references `PeerDropProtocol.self` which no longer exists). Fix the placeholder test file OR delete it:

Edit `PeerDropKit/Tests/PeerDropProtocolTests/PeerDropProtocolTests.swift`. Either:
- (a) Update `XCTAssertNotNil(PeerDropProtocol.self)` to reference a real moved type, e.g., `XCTAssertNotNil(MessageType.self)`
- (b) Delete the file entirely (real tests come in Task 3)

Pick (a) for minimal noise — keeps a passing test until Task 3 adds real tests.

Re-run `swift test`; expected: 5 placeholder tests still pass (4 unchanged + 1 updated for Protocol).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-2): migrate Protocol module into PeerDropProtocol

11 source files moved from PeerDrop/Protocol/ to
PeerDropKit/Sources/PeerDropProtocol/ via git mv (preserves history).
Types marked `public` for cross-module access. ~N consumer files
gain `import PeerDropProtocol`. Placeholder enum deleted.

Tests migrated in M1d-2 Task 3. iOS test suite still 1248/0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(Replace `~N` with actual count of consumer files modified.)

---

## Task 3: Migrate Protocol tests into PeerDropProtocolTests

**Files:**
- Move: 2 Protocol test files from `PeerDropTests/` → `PeerDropKit/Tests/PeerDropProtocolTests/`
  - `PeerDropTests/RemoteMessageEnvelopeTests.swift` (NOTE: this is actually a SECURITY test — RemoteMessageEnvelope lives in Security/Protocol/; verify before moving)
  - `PeerDropTests/RemoteMessageEnvelopeProtocolVersionTests.swift` (same caveat)
- Delete: placeholder test `PeerDropKit/Tests/PeerDropProtocolTests/PeerDropProtocolTests.swift` (if updated in Task 2 Step 7)

Investigation from `grep "RemoteMessageEnvelope"`:
- `PeerDrop/Security/Protocol/RemoteMessageEnvelope.swift` exists — so RemoteMessageEnvelope IS a Security type, not a wire-Protocol type
- Therefore the 2 "Protocol" test files are misnamed — they actually test Security functionality
- They migrate with Security in Task 6, NOT with Protocol in Task 3

**Adjusted Task 3 scope:** there are NO direct Protocol-module test files. The placeholder from M1d-1 stays (just renamed to test a real Protocol type per Task 2 Step 7's (a) option).

- [ ] **Step 1: Verify the assumption**

```bash
grep -l "RemoteMessageEnvelope" PeerDrop/Protocol/*.swift 2>/dev/null
grep -l "RemoteMessageEnvelope" PeerDrop/Security/Protocol/*.swift 2>/dev/null
```

Expected: only Security/Protocol/ has RemoteMessageEnvelope.swift. Confirmed.

If for some reason Protocol/ does have RemoteMessageEnvelope (catalog drift), move the relevant test file to PeerDropProtocolTests; otherwise skip.

- [ ] **Step 2: Sanity check — does `swift test` for PeerDropProtocol still work?**

```bash
cd PeerDropKit && swift test --filter PeerDropProtocolTests 2>&1 | tail -10 && cd ..
```

Expected: 1 test (the placeholder, possibly updated to reference a real type). Passes.

- [ ] **Step 3: No commit — Task 2's commit already covers Protocol-related testing**

Task 3 is a no-op for Protocol. Real test migration happens in Tasks 6 (Security) and Tasks 8 (Pet).

---

## Task 4: Pre-Security audit

**Files:** (analysis only)

Same investigation pattern as Task 1, but for Security.

- [ ] **Step 1: Inventory Security files**

```bash
ls PeerDrop/Security/
ls PeerDrop/Security/Protocol/
```

Expected: 28 files total (20 in Security/, 8 in Security/Protocol/).

- [ ] **Step 2: Find Security type names + external consumers**

```bash
for f in PeerDrop/Security/*.swift PeerDrop/Security/Protocol/*.swift; do
    echo "=== $(basename "$f") ==="
    grep -E "^(public |internal |private |fileprivate )?(struct|class|enum|protocol|typealias) " "$f"
done

# External consumers
grep -rln "PeerIdentity\|ChatDataEncryptor\|TrustedContact\|IdentityKeyManager\|DoubleRatchet\|X3DH\|TLSConfiguration\|SecurityPolicy\|RelayAuthenticator\|RemoteMessageEnvelope\|PreKey\|SessionKey\|KeyExchange\|CertificateManager\|CanonicalJSON\|HashVerifier\|FileNameSanitizer\|TrustLevel\|SignedCryptoPolicy\|LocalSecureChannel\|ProofOfWork\|PairingPayload\|PeerVersion\|PeerPolicy\|SecurityPolicyStore\|SecurityPolicyBounds" PeerDrop/ --include="*.swift" | grep -v "/Security/" | grep -v "PeerDropKit/" | sort -u
```

Note that this grep is broad and may produce false positives (a comment mentioning "TrustLevel"); reading the actual usage in each match is needed.

- [ ] **Step 3: Check inter-leaf references**

```bash
# Does Security reference Protocol types?
grep -rln "MessageType\|PeerMessage\|ClipboardSyncPayload\|TextMessagePayload\|MediaMessagePayload\|TypingIndicatorPayload\|ReactionPayload\|MessageEditPayload\|MessageReceiptPayload\|FileResumePayload\|ProtocolVersion" PeerDrop/Security/ 2>/dev/null
```

If matches: PeerDropSecurity needs `dependencies: ["PeerDropProtocol"]` added to its Package.swift target declaration. Spec §1 has Security as a leaf with no deps; adjust if reality requires.

- [ ] **Step 4: Note CryptoTestKit handling decision**

CryptoTestKit (under `PeerDropTests/CryptoTestKit/`) is a nested test-helper Swift module structure (Sources + Tests + TestVectors). It tests Security cryptographic primitives. Options:

- **(a) Inline into PeerDropSecurityTests**: move all CryptoTestKit/Sources files into `PeerDropKit/Tests/PeerDropSecurityTests/Helpers/`, all CryptoTestKit/Tests files into `PeerDropKit/Tests/PeerDropSecurityTests/Vectors/` (or similar grouping), TestVectors/*.json into the test target's resources.
- **(b) Create a separate `.testTarget` in Package.swift** for CryptoTestKit so it lives as a sibling test target.

Recommended: (a). Simpler. CryptoTestKit doesn't need to be reusable beyond Security tests.

Apply decision in Task 6.

- [ ] **Step 5: No commit (analysis only)**

---

## Task 5: Migrate Security source files into PeerDropSecurity

**Files:**
- Move: 28 source files from `PeerDrop/Security/` → `PeerDropKit/Sources/PeerDropSecurity/` (PRESERVE the `Protocol/` subdirectory)
- Delete: `PeerDropKit/Sources/PeerDropSecurity/PeerDropSecurity.swift` (placeholder)
- Modify: each moved file — `public` upgrades
- Modify: external consumers (~11 files) — add `import PeerDropSecurity`
- Possibly modify: `PeerDropKit/Package.swift` — add `dependencies: ["PeerDropProtocol"]` to PeerDropSecurity target if cross-leaf ref found in Task 4

- [ ] **Step 1: Move source files preserving directory structure**

```bash
# Move top-level Security files
for f in PeerDrop/Security/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropSecurity/
done

# Move Security/Protocol/ subdir (the X3DH + Double Ratchet implementation)
mkdir -p PeerDropKit/Sources/PeerDropSecurity/Protocol
for f in PeerDrop/Security/Protocol/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropSecurity/Protocol/
done

rmdir PeerDrop/Security/Protocol
rmdir PeerDrop/Security

git rm PeerDropKit/Sources/PeerDropSecurity/PeerDropSecurity.swift
```

- [ ] **Step 2: Mark types public**

For each moved file, identify top-level types + members that external consumers access. Apply `public` upgrades.

Pay special attention to:
- `PeerIdentity` (referenced from Core extensively)
- `ChatDataEncryptor.shared` and its public methods (Codable encrypt/decrypt)
- `TrustedContactStore.shared` and its API surface
- `IdentityKeyManager.shared` and its public methods
- `DoubleRatchet` types (used by tests)
- `X3DH` types (used by tests after M1b's CryptoTestKit fix)
- `RemoteMessageEnvelope` (used by Transport for relay encoding)
- `SecurityPolicy`, `PeerVersion`, `PeerPolicy` (used widely after v5.4 hardening)

- [ ] **Step 3: Add `import PeerDropSecurity` to consumers**

```bash
grep -rln "PeerIdentity\|ChatDataEncryptor\|TrustedContact\|IdentityKeyManager\|DoubleRatchet\|X3DH\|TLSConfiguration\|SecurityPolicy\|RelayAuthenticator\|RemoteMessageEnvelope\|PreKey\|SessionKey\|KeyExchange\|CertificateManager\|TrustLevel\|SignedCryptoPolicy\|LocalSecureChannel" PeerDrop/ --include="*.swift" | grep -v "PeerDropKit/" | sort -u
```

Add `import PeerDropSecurity` to each file. (One line per file.)

If any of these files ALSO needs `import PeerDropProtocol` (because Security types reference Protocol types), add both.

- [ ] **Step 4: Update PeerDropProtocol's PeerMessage if it's now broken**

If Task 2 noted that PeerMessage referenced Security types via type names but didn't add `import PeerDropSecurity` (because PeerMessage was still in the same app-target compilation unit as Security):

Now that PeerMessage is in PeerDropProtocol (separate module) and Security types moved to PeerDropSecurity (also separate module), PeerMessage needs:

```swift
import Foundation
import PeerDropSecurity   // ← add this
```

If this is required, update `PeerDropKit/Package.swift` to add the dep:

```swift
.target(
    name: "PeerDropProtocol",
    dependencies: ["PeerDropSecurity"]  // ← add this
),
```

This breaks the spec §1 "Protocol is a pure leaf" assumption. Acceptable — spec needs a footnote.

- [ ] **Step 5: xcodegen + build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Iterate on `public` and import errors until clean.

- [ ] **Step 6: iOS test sweep**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tail -8
```

Expected: 1248 / 0.

- [ ] **Step 7: swift build + (placeholder) swift test from PeerDropKit/**

```bash
cd PeerDropKit && swift build && cd ..
```

Update `PeerDropKit/Tests/PeerDropSecurityTests/PeerDropSecurityTests.swift` placeholder to reference a real moved type (e.g., `XCTAssertNotNil(SecurityPolicy.self)`) so `swift test` still passes.

```bash
cd PeerDropKit && swift test 2>&1 | tail -10 && cd ..
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-2): migrate Security module into PeerDropSecurity

28 source files moved from PeerDrop/Security/ to
PeerDropKit/Sources/PeerDropSecurity/ (preserving Protocol/ subdir
for X3DH + Double Ratchet impl). Types marked `public` for
cross-module access. ~N consumer files gain `import PeerDropSecurity`.
Placeholder enum deleted.

Tests migrated in Task 6. iOS test suite still 1248/0.

# IMPLEMENTER: If Task 4 detected PeerDropProtocol → PeerDropSecurity dep,
# include this note; otherwise delete it:
#   "PeerDropProtocol now depends on PeerDropSecurity because PeerMessage
#   uses Security types — spec §1's leaf-only-deps assumption updated."

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate Security tests + CryptoTestKit into PeerDropSecurityTests

**Files:**
- Move: ~22 Security test files from `PeerDropTests/` → `PeerDropKit/Tests/PeerDropSecurityTests/`
- Move: CryptoTestKit/Sources/* → `PeerDropKit/Tests/PeerDropSecurityTests/Helpers/`
- Move: CryptoTestKit/Tests/* → `PeerDropKit/Tests/PeerDropSecurityTests/Vectors/` (and Properties/)
- Move: CryptoTestKit/TestVectors/*.json → `PeerDropKit/Tests/PeerDropSecurityTests/Resources/` (and declare in Package.swift)
- Modify: each moved test file — change `@testable import PeerDrop` to `@testable import PeerDropSecurity`
- Possibly modify: `PeerDropKit/Package.swift` — PeerDropSecurityTests target needs `resources: [.process("Resources")]` for test vectors

- [ ] **Step 1: List Security test files explicitly**

```bash
ls PeerDropTests/ | grep -E "Security|Identity|Crypto|Ratchet|Trust|X3DH|Pairing|SignedCrypto|RemoteMessageEnvelope|PreKey|KeyExchange|Certificate|LocalSecureChannel|ProofOfWork|HashVerifier|FileNameSanitizer|CanonicalJSON|RelayAuth"
```

Build the exact list of files. Common: ~22 files.

- [ ] **Step 2: Move them**

```bash
for f in IdentityKeyManagerTests SecurityPolicyStoreFetchTests CryptoHardeningMetricsTests X3DHSPKTimestampTests TrustedContactTests SecurityPolicyStoreTests DeviceIdentityTests TrustedContactStoreTests X3DHOPKFailClosedTests DoubleRatchetSkippedKeysTests TrustedContactKeyHistoryTests SecurityPolicyTests PeerIdentitySecurityTests CryptoHardeningBannerTests SignCryptoPolicyToolTests SignedCryptoPolicyTests DoubleRatchetTests X3DHTests DoubleRatchetPersistenceTests SecurityPolicyStoreParseTests TrustedContactPeerVersionTests RemoteMessageEnvelopeTests RemoteMessageEnvelopeProtocolVersionTests; do
    if [ -f "PeerDropTests/${f}.swift" ]; then
        git mv "PeerDropTests/${f}.swift" PeerDropKit/Tests/PeerDropSecurityTests/
    fi
done
```

Adjust list based on Step 1's actual output.

- [ ] **Step 3: Move CryptoTestKit**

```bash
mkdir -p PeerDropKit/Tests/PeerDropSecurityTests/{Helpers,Vectors,Properties,Resources}

# Sources → Helpers
for f in PeerDropTests/CryptoTestKit/Sources/*.swift; do
    git mv "$f" PeerDropKit/Tests/PeerDropSecurityTests/Helpers/
done

# Tests/* → Vectors/Properties (preserve subdir if present)
for f in PeerDropTests/CryptoTestKit/Tests/*.swift; do
    git mv "$f" PeerDropKit/Tests/PeerDropSecurityTests/
done
for f in PeerDropTests/CryptoTestKit/Tests/Vectors/*.swift; do
    git mv "$f" PeerDropKit/Tests/PeerDropSecurityTests/Vectors/
done
for f in PeerDropTests/CryptoTestKit/Tests/Properties/*.swift; do
    git mv "$f" PeerDropKit/Tests/PeerDropSecurityTests/Properties/
done

# TestVectors → Resources
for f in PeerDropTests/CryptoTestKit/TestVectors/*.json; do
    git mv "$f" PeerDropKit/Tests/PeerDropSecurityTests/Resources/
done

rm -rf PeerDropTests/CryptoTestKit
```

- [ ] **Step 4: Update each test file's `@testable import`**

```bash
# Bulk-update via sed (macOS bash 3.2 doesn't support globstar; use find)
for f in $(find PeerDropKit/Tests/PeerDropSecurityTests -name "*.swift"); do
    sed -i '' 's/@testable import PeerDrop$/@testable import PeerDropSecurity/g' "$f"
done
```

Some files might also need `@testable import PeerDropProtocol` (if they test something that uses Protocol types). Catch via build errors and fix per-file.

- [ ] **Step 5: Update Package.swift PeerDropSecurityTests target with resources**

Edit `PeerDropKit/Package.swift`. Update the PeerDropSecurityTests target:

```swift
.testTarget(
    name: "PeerDropSecurityTests",
    dependencies: ["PeerDropSecurity", "PeerDropProtocol"],  // add PeerDropProtocol if needed
    resources: [
        .process("Resources"),
    ]
),
```

- [ ] **Step 6: Run swift test**

```bash
cd PeerDropKit && swift test --filter PeerDropSecurityTests 2>&1 | tail -20 && cd ..
```

Expected: ~25+ tests run (22 file's worth of tests + CryptoTestKit's). All pass.

If "couldn't find test bundle resource" errors: the JSON test vectors need their relative path updated. The test code probably uses `Bundle.module.url(...)` or similar — verify.

- [ ] **Step 7: iOS test sweep (regression check)**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tail -8
```

Expected: ~1226 tests now (1248 - the ~22 that moved to PeerDropKit/Tests/). Run count + failure count to verify.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-2): migrate Security tests + CryptoTestKit into PeerDropSecurityTests

~22 Security test files + CryptoTestKit (4 source helpers + 7 test
files + JSON test vectors) moved into PeerDropKit/Tests/PeerDropSecurityTests/
with Helpers/, Vectors/, Properties/, Resources/ subdirectories.

@testable imports updated PeerDrop → PeerDropSecurity. Test vectors
now in SPM bundle via .process("Resources").

iOS test count: 1248 → ~1226 (the ~22 moved tests now run via
`swift test` instead of `xcodebuild test`).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Pre-Pet audit

Same pattern as Tasks 1 + 4, for Pet.

- [ ] **Step 1: Inventory Pet structure**

```bash
find PeerDrop/Pet -type f -name "*.swift" | head -30
find PeerDrop/Pet -type d
ls PeerDrop/Resources/Pets | head
find PeerDrop/Resources/Pets -name "*.zip" | wc -l
```

Expected: 61 source files across 8 subdirs (excluding UI/); 324 zips.

- [ ] **Step 2: Identify external consumers + Bundle.main sites**

```bash
# Pet type consumers outside Pet/
grep -rln "PetGenome\|SpeciesCatalog\|PetEngine\|PetRendererV3\|SpriteService\|PetState\|PetMood\|PetAction\|PetLevel\|SharedRenderedPet\|PetPersonality\|PetGreetingPayload\|BodyGene\|InteractionType\|SpriteRequest\|SpriteCache" PeerDrop/ --include="*.swift" | grep -v "/Pet/" | grep -v "PeerDropKit/" | sort -u

# Bundle.main usages (must become Bundle.module in PeerDropPet sources)
grep -rn "Bundle\.main\|Bundle = .main" PeerDrop/Pet/ | head
```

Expected: ~5 external consumer files + 4 Bundle.main sites.

- [ ] **Step 3: Note Widget path-references**

```bash
grep -A5 "PeerDropWidget" project.yml | head -20
```

Widget currently path-references 7 files from PeerDrop/Pet/. After Pet migration, these path-references become invalid. Plan to:
- Add `package: PeerDropKit / product: PeerDropPet` to Widget's dependencies
- Remove the 7 path-references

- [ ] **Step 4: Check inter-leaf references**

```bash
grep -rln "PeerIdentity\|ChatDataEncryptor\|TrustedContact\|MessageType\|PeerMessage" PeerDrop/Pet/ 2>/dev/null
```

If Pet references Security or Protocol types, PeerDropPet needs the corresponding dependencies in Package.swift.

- [ ] **Step 5: No commit (analysis)**

---

## Task 8: Migrate Pet source files + tests into PeerDropPet / PeerDropPetTests

**Files:**
- Move: 61 source files preserving 8 subdirectory structure
- Move: ~64 Pet test files
- Delete: PeerDropPet.swift placeholder
- Modify: each moved file — `public` upgrades
- Modify: 4 sites — `Bundle.main` → `Bundle.module`
- Modify: 5 external consumer files — add `import PeerDropPet`
- Update: Package.swift PeerDropPet target — add `dependencies` if needed (CoreGraphics, ZIPFoundation already there)

- [ ] **Step 1: Move source files preserving subdirs**

```bash
for subdir in Behavior Engine Model Persistence Protocol Renderer Shared Sprites; do
    if [ -d "PeerDrop/Pet/$subdir" ]; then
        mkdir -p "PeerDropKit/Sources/PeerDropPet/$subdir"
        for f in PeerDrop/Pet/$subdir/*.swift; do
            git mv "$f" "PeerDropKit/Sources/PeerDropPet/$subdir/"
        done
        rmdir "PeerDrop/Pet/$subdir"
    fi
done

git rm PeerDropKit/Sources/PeerDropPet/PeerDropPet.swift
```

- [ ] **Step 2: Move Pet test files**

Pet tests are in two places:
- `PeerDropTests/Pet*.swift` (top-level)
- `PeerDropTests/Pet/*.swift` (nested)

```bash
for f in PeerDropTests/Pet*.swift; do
    git mv "$f" PeerDropKit/Tests/PeerDropPetTests/
done

if [ -d PeerDropTests/Pet ]; then
    for f in PeerDropTests/Pet/*.swift; do
        git mv "$f" PeerDropKit/Tests/PeerDropPetTests/
    done
    rmdir PeerDropTests/Pet 2>/dev/null || true
fi
```

- [ ] **Step 3: Update `@testable import` in tests**

```bash
for f in PeerDropKit/Tests/PeerDropPetTests/*.swift; do
    sed -i '' 's/@testable import PeerDrop$/@testable import PeerDropPet/g' "$f"
done
```

Some Pet tests use Security types (e.g., `MainBundleAssetCoverageTests` reads pet zips which depend on the resource bundle); they may also need `@testable import PeerDropSecurity`. Catch via build errors.

- [ ] **Step 4: Mark Pet types public**

Apply `public` to all top-level types in `PeerDropKit/Sources/PeerDropPet/**/*.swift` that consumers access externally. Key ones:
- `PetGenome`, `BodyGene`, `SpeciesID`, `Rarity`, `VariantSpec`, `VariantTrait`
- `SpeciesCatalog` (its functions: `variantSpecs(for:)`, `traits(for:)`, `variants(for:)`)
- `PetEngine`, `PetState`, `PetMood`, `PetAction`, `PetLevel`
- `PetRendererV3`, `SpriteService`, `SpriteCache`, `SpriteRequest`
- `SharedRenderedPet`, `PetParticle`, `PoopState`
- `InteractionType`, `PetSurface`
- `PetGreetingPayload` (Pet/Protocol/PetPayload.swift)

- [ ] **Step 5: Update Bundle.main → Bundle.module (4 sites)**

```bash
# Edit each of the 4 files:
# - PeerDrop/Pet/Renderer/AccessoryOverlay.swift line 23: `Bundle = .main` → `Bundle = .module`
# - PeerDrop/Pet/Renderer/SpriteSheetLoader.swift line 59: `Bundle.main.url(...)` → `Bundle.module.url(...)`
# - PeerDrop/Pet/Sprites/SpriteService.swift line 34 + 59: same
# - PeerDrop/Pet/Sprites/SpriteAssetResolver.swift line 65: same
```

After migration, the files are at new paths under PeerDropKit/Sources/PeerDropPet/. Use the new paths when editing.

- [ ] **Step 6: Add `import PeerDropPet` to consumers**

```bash
grep -rln "PetGenome\|SpeciesCatalog\|PetEngine\|PetRendererV3\|SpriteService" PeerDrop/ --include="*.swift" | grep -v "PeerDropKit/" | sort -u
```

For each match (~5 files including ContentView.swift, ChatView.swift, ScreenshotModeProvider.swift, PlatformGraphicsRenderer.swift, PeerDropApp.swift), add `import PeerDropPet`.

- [ ] **Step 7: xcodegen + build (will fail because of Pet resources not yet moved + Widget path-refs broken)**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -20
```

Expected failures: Widget can't find path-referenced Pet files; Pet sources can't load resource bundle (because resources not moved yet). Tasks 9 + 10 fix these.

DON'T commit yet — wait until Tasks 9 + 10 are also done so the commit is atomic. Or commit now with a `BROKEN` marker:

Decision: COMMIT NOW with explicit "build broken until Task 9+10" note. This isolates the source migration concern from the resource + Widget concerns.

- [ ] **Step 8: Commit (build IS broken; Tasks 9+10 fix)**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-2): migrate Pet source + tests into PeerDropPet (BUILD BROKEN — Task 9+10 fix)

61 source files moved from PeerDrop/Pet/{Behavior,Engine,Model,Persistence,
Protocol,Renderer,Shared,Sprites}/ to PeerDropKit/Sources/PeerDropPet/
(preserving subdir structure). ~64 Pet test files moved to
PeerDropKit/Tests/PeerDropPetTests/. @testable imports updated.

Types marked `public`. Bundle.main → Bundle.module (4 sites).
External consumers (~5 files) gain `import PeerDropPet`.

INTENTIONAL BROKEN STATE:
- Pet resources at PeerDrop/Resources/Pets/ not yet moved to SPM bundle (Task 9)
- Widget still path-references 7 Pet files (Task 10)

Both fixes land before this PR ships.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Move Pet resources into SPM bundle

**Files:**
- Move: 324 .zip files from `PeerDrop/Resources/Pets/` → `PeerDropKit/Sources/PeerDropPet/Resources/Pets/`
- Modify: `PeerDropKit/Package.swift` — add `resources: [.process("Resources")]` to PeerDropPet target
- Modify: `project.yml` — REMOVE the `PeerDrop/Resources/Pets` folder reference from PeerDrop target's sources (also remove the `excludes: - "Resources/Pets/**"` since that exclusion is now moot)
- Modify: `project.yml` — Same for PeerDropTests target if it references PeerDrop/Resources/Pets

- [ ] **Step 1: Move the resources**

```bash
mkdir -p PeerDropKit/Sources/PeerDropPet/Resources
git mv PeerDrop/Resources/Pets PeerDropKit/Sources/PeerDropPet/Resources/Pets
# PeerDrop/Resources/ may now be empty
rmdir PeerDrop/Resources 2>/dev/null || true
```

This is a HUGE git mv (324 files). Verify count:

```bash
git status | grep "renamed:" | wc -l
```

Expected: 324.

- [ ] **Step 2: Update Package.swift**

Edit `PeerDropKit/Package.swift`. Find the PeerDropPet target:

```swift
.target(
    name: "PeerDropPet",
    dependencies: [
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
    ]
),
```

Change to:

```swift
.target(
    name: "PeerDropPet",
    dependencies: [
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
    ],
    resources: [
        .process("Resources"),
    ]
),
```

The `.process` declaration tells SPM to copy the Resources/ subdir into the module's bundle, accessible via `Bundle.module`.

- [ ] **Step 3: Update project.yml**

Edit `project.yml`. Find PeerDrop target's `sources:` block. The current setup has:

```yaml
    sources:
      - path: PeerDrop
        excludes:
          - "Resources/Pets/**"
      - path: PeerDrop/Resources/Pets
        type: folder
```

Change to:

```yaml
    sources:
      - path: PeerDrop
```

(Drop the excludes and the explicit folder reference, since Pets is no longer under PeerDrop/.)

Same edit for PeerDropTests target if it has the same pattern.

- [ ] **Step 4: xcodegen + build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10
```

Build should now succeed for the Pet sources (resources are accessible via Bundle.module). Widget may still fail — that's Task 10.

If "Bundle.module" not found errors appear in PeerDropPet sources: check that `import Foundation` is present and that Package.swift correctly declares `resources:` on the right target.

- [ ] **Step 5: swift test from PeerDropKit/ (PeerDropPet tests must pass with resource loading)**

```bash
cd PeerDropKit && swift test --filter PeerDropPetTests 2>&1 | tail -15 && cd ..
```

Expected: ~64 Pet tests run, mostly pass. If `MainBundleAssetCoverageTests` fails, the resource bundle config is wrong — debug.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-2): Pet resources (324 zips) move into PeerDropPet SPM bundle

PeerDrop/Resources/Pets/ → PeerDropKit/Sources/PeerDropPet/Resources/Pets/
via git mv (324 .zip files; preserves history).

Package.swift PeerDropPet target gains `resources: [.process("Resources")]`
— SPM ships the zips in module's Bundle.module.

project.yml drops the now-moot PeerDrop/Resources/Pets folder reference
and the corresponding excludes pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Update Widget target to consume PeerDropPet

**Files:**
- Modify: `project.yml` — PeerDropWidget target

PeerDropWidget currently path-references 7 specific files from `PeerDrop/Pet/`. After Task 8 those files moved into PeerDropKit. Widget needs to either:
- (a) Add `package: PeerDropKit / product: PeerDropPet` to its dependencies — cleanest
- (b) Update path references to the new locations under PeerDropKit/Sources/PeerDropPet/

Pick (a). It's the whole point of M1d.

- [ ] **Step 1: Read current Widget target config**

```bash
sed -n '146,200p' project.yml
```

Note the 7 path-reference lines (Pet/Shared dir + PetPalettes.swift + 6 Pet/Model files).

- [ ] **Step 2: Remove path-references + add PeerDropPet dependency**

Edit `project.yml`. Replace the PeerDropWidget target config's sources/dependencies pattern:

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

(Preserve the rest of the Widget config — info, settings, entitlements unchanged.)

- [ ] **Step 3: xcodegen + build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

If Widget files fail with "No such module 'PeerDropPet'" — the dependency wasn't added correctly. Re-check.

If Widget files fail with "Cannot find type 'X' in scope" — they need to `import PeerDropPet`. Add the import to each Widget .swift file:

```bash
grep -l "PetGenome\|SpeciesCatalog\|PetMood" PeerDropWidget/*.swift
```

For each match, add `import PeerDropPet` after existing imports.

- [ ] **Step 4: Full iOS test sweep**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tail -8
```

Expected: ~1226 - 64 = ~1162 tests in xcodebuild (the 64 Pet tests now run via `swift test`). 0 failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-2): Widget consumes PeerDropPet (drops 7 path-references)

PeerDropWidget no longer path-references individual Pet files. Now
consumes `package: PeerDropKit / product: PeerDropPet` and imports
PeerDropPet types via the standard SPM mechanism.

Widget .swift files add `import PeerDropPet`.

This closes the "M1c reviewer follow-up to plan Widget path resolution
in M1d" — Widget is now wired the same way as the app target.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Final verification + lint-imports update + tag M1d-2

**Files:**
- Possibly modify: `.github/workflows/ci.yml` (extend find paths or exclusions if the migration changed where things live)
- Verification

- [ ] **Step 1: Verify all 3 leaves moved correctly**

```bash
# Source migration sanity
ls PeerDrop/Protocol 2>/dev/null && echo "MISTAKE: Protocol/ still in PeerDrop"
ls PeerDrop/Security 2>/dev/null && echo "MISTAKE: Security/ still in PeerDrop"
ls PeerDrop/Pet 2>/dev/null | grep -v "UI" | head -5 && echo "CHECK: Pet/ subdirs other than UI should be empty/gone"
find PeerDrop/Resources 2>/dev/null && echo "CHECK: Resources/ should be gone or empty"

# PeerDropKit content
find PeerDropKit/Sources/PeerDropProtocol -name "*.swift" | wc -l  # expect 11
find PeerDropKit/Sources/PeerDropSecurity -name "*.swift" | wc -l  # expect 28
find PeerDropKit/Sources/PeerDropPet -name "*.swift" | wc -l       # expect 61
find PeerDropKit/Sources/PeerDropPet/Resources -name "*.zip" | wc -l  # expect 324
```

- [ ] **Step 2: Full iOS test + swift test sweeps**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1d2-final-ios.log | tail -8

cd PeerDropKit && swift test 2>&1 | tee /tmp/m1d2-final-swift.log | tail -10 && cd ..
```

Expected:
- iOS test count: ~1162 (down from 1248 because ~22 Security + ~64 Pet tests now run via swift test). 0 failures.
- swift test count: ~22 + ~64 + 1 placeholder Transport + 1 placeholder Core = ~88 tests. 0 failures (or only pre-existing failures that originated in the source tests).

Verify total tests = ~1162 + ~88 = ~1250 (matches the pre-M1d-2 1248 baseline within tolerance — the +/- accounts for placeholders being added/removed).

- [ ] **Step 3: Extend lint-imports if needed**

The CI `lint-imports` job scans `PeerDrop/Core PeerDrop/Pet PeerDrop/Voice PeerDropKit/Sources`. After Pet migrated, `PeerDrop/Pet/` only contains the UI/ subdir (which is exempted via `-not -path "*/Pet/UI/*"`). So the existing scan paths still work.

If `PeerDrop/Protocol/` or `PeerDrop/Security/` is now empty/missing, the find command still works (just scans 0 files in those paths).

No change needed. Verify by running locally:

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"
# Run the lint-imports script as in M1d-1 Task 5
# ... (copy the script body from .github/workflows/ci.yml)
```

Expected: `Clean.`

- [ ] **Step 4: Tag M1d-2**

```bash
git tag -a m1d-2-leaf-modules-migration -m "M1d-2 done: 3 leaf modules (Protocol/Security/Pet) migrated into PeerDropKit. 100 source files + 324 Pet resources + ~89 test files. Widget rewires to consume PeerDropPet."

git log --oneline ab079cc..HEAD
git tag --list | grep -E "m0|m1"
```

Expected: ~6+ commits (Task 2 + Task 5 + Task 8 + Task 9 + Task 10 + maybe lint fix), 6 tags (m0, m1a, m1b, m1c, m1d-1, m1d-2).

## Done

M1d-2 complete. PeerDropKit now contains 3 of 5 modules with real content. Tests + builds work end-to-end through the SPM boundary.

**Next:** M1d-3 plan (Transport migration: 28 files = 16 Transport + 6 Discovery + 6 Voice transport-side) by re-invoking `superpowers:writing-plans`.

## Open Items for M1d-3 / M1d-4

1. **M1d-3:** Transport migration. CallKitManager stays in app target. Watch for cross-leaf refs (Transport probably uses Security types — PeerDropTransport target adds `dependencies: ["PeerDropSecurity"]` if needed; this matches spec §1 since Transport is a leaf with its own external WebRTC dep).
2. **M1d-4:** Core migration (47 files). Widget already rewired in M1d-2 Task 10 — only the app target left to clean. Remove now-unused direct WebRTC/ZIPFoundation deps from PeerDrop target (only if app-level files no longer import them directly).
