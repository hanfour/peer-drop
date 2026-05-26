# M1d-4 — PeerDropTransport Module Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate 29 source files (Transport 17 + Discovery 6 + Voice transport-side 6) from `PeerDrop/{Transport,Discovery,Voice}/` into `PeerDropKit/Sources/PeerDropTransport/`. CallKitManager.swift (iOS-only CallKit adapter) stays in app target — moves from `PeerDrop/Voice/` to `PeerDrop/App/` next to AppDelegate. After M1d-4, only PeerDropCore migration (M1d-5) remains.

**Architecture:** PeerDropTransport target gains `dependencies: ["PeerDropPlatform", "PeerDropProtocol", "PeerDropSecurity", WebRTC]`. Transport uses Security (PeerIdentity?, RemoteSessionManager, ChatDataEncryptor, TrustedContact, RelayAuthenticator) + Protocol (PeerMessage, MessageType) + Platform (AudioSession, CallProvider, HapticManager). The `MailboxClient+SecurityProtocol.swift` bridge from M1d-2 moves with MailboxClient into PeerDropTransport.

**Tech Stack:** Swift 5.9, iOS 16+, macOS 14+, XcodeGen 2.45.4. Builds: `xcodebuild` (iOS app) + `swift build`/`swift test` (PeerDropKit).

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1d-4.

**Predecessors (all merged):** M0, M1a, M1b, triage, M1c, M1d-1, M1d-2, M1d-3a, M1d-3b.

**Investigation findings:**

### Source files (29 total)

**Transport/ (17):**
- DataChannelClient, DataChannelTransport, DeviceTokenManager, FileTransfer, FileTransferSession, ICEConfigurationProvider, MailboxClient, MailboxClient+SecurityProtocol (bridge from M1d-2), MailboxManager, MessageFramer, OutboundRetryQueue, TCPTransport, TransferMetadata, TransferRecord, TransportProtocol, WorkerAuthHelper, WorkerSignaling

**Discovery/ (6):**
- BLEDiscovery, BLESignaling, BonjourDiscovery, DiscoveryService, NearbyInteractionManager, TailscalePeer

**Voice/ transport-side (6 — CallKitManager stays):**
- SDPSignaling, VoiceCallManager, VoiceCallSession, VoicePlayer, VoiceRecorder, WebRTCClient

### CallKitManager.swift — STAYS in app target, MOVES from PeerDrop/Voice/ to PeerDrop/App/CallKitManager.swift

Rationale: it's the iOS-only adapter for the CallProvider protocol (in PeerDropPlatform). AppDelegate creates the instance. Next to AppDelegate is the natural home. After M1d-4, `PeerDrop/Voice/` directory is removed entirely.

This also simplifies the lint-imports CI exclusion — `*/Voice/CallKitManager.swift` exclusion is no longer needed because PeerDrop/App/ isn't scanned by lint-imports at all.

### Test files to migrate (13 — verify exact count during execution)

```
PeerDropTests/DataChannelTransportReassemblyTests.swift
PeerDropTests/FileTransferChunkLimitsTests.swift
PeerDropTests/BLEDiscoveryTests.swift
PeerDropTests/FileTransferTests.swift
PeerDropTests/DataChannelTransportTests.swift
PeerDropTests/RelayAuthenticatorTests.swift  (Security test, but RelayAuthenticator USED by Transport — verify ownership)
PeerDropTests/RelayTrustGateIntegrationTests.swift  (similar — verify)
PeerDropTests/RelaySessionTests.swift
PeerDropTests/PeerTransportTests.swift
PeerDropTests/DiscoveryServiceTests.swift
PeerDropTests/FileTransferIntegrationTests.swift
PeerDropTests/Mocks/MockTransport.swift
PeerDropTests/Mocks/MockDiscovery.swift
```

Voice test files? Check during audit — likely some VoiceRecorder/VoicePlayer tests exist.

### Inter-module references

- **Transport → PeerDropSecurity**: OutboundRetryQueue uses ChatDataEncryptor + TrustedContact + RemoteSessionManager. MailboxClient+SecurityProtocol provides bridge conformance. PeerDropTransport target needs `dependencies: ["PeerDropSecurity"]`.
- **Transport → PeerDropProtocol**: 8 files use PeerMessage / MessageType / ProtocolVersion. PeerDropTransport needs `["PeerDropProtocol"]`.
- **Transport → PeerDropPlatform**: 6 files use Platform types (CallProvider, AudioSessionConfiguring, HapticManager). PeerDropTransport needs `["PeerDropPlatform"]`.
- **Transport → PeerDropPet**: NONE (verified).
- **Transport → Core types** (PeerIdentity, DeviceRecord etc.): need to handle case-by-case. PeerIdentity is in PeerDrop/Core/. If Transport files reference PeerIdentity, that's a problem — Transport can't depend on Core (cycle). Resolution options: (a) extract PeerIdentity to Security (was originally specced there); (b) protocol-inversion bridge in app target.

### External consumers needing `import PeerDropTransport`

After Transport migrates, files outside Transport using its types need the import. Identify in audit. Likely includes:
- Core/ConnectionManager (uses many Transport types — heavy user)
- Core/PeerConnection (uses transport protocols)
- UI/Transfer/* (file transfer UI)
- App/PeerDropApp / AppDelegate (audio session setup, CallKit wiring)

---

## File Structure

**New files:**
- (Possibly) `PeerDrop/App/CallKitManager.swift` (moved from PeerDrop/Voice/CallKitManager.swift)

**Move (29 source + ~13 test):**
- 17 Transport files → `PeerDropKit/Sources/PeerDropTransport/`
- 6 Discovery files → `PeerDropKit/Sources/PeerDropTransport/Discovery/` (preserve as subdir)
- 6 Voice transport-side files → `PeerDropKit/Sources/PeerDropTransport/Voice/` (preserve as subdir)
- 1 CallKitManager.swift → `PeerDrop/App/CallKitManager.swift`
- 13 test files → `PeerDropKit/Tests/PeerDropTransportTests/`

**Delete (placeholder):**
- `PeerDropKit/Sources/PeerDropTransport/PeerDropTransport.swift`

**Modify:**
- `PeerDropKit/Package.swift` — PeerDropTransport target gains deps
- `project.yml` — possibly add PeerDropTransport to app target sources path adjustments
- `.github/workflows/ci.yml` — remove the `*/Voice/CallKitManager.swift` exclusion (Voice/ dir is gone)
- ~N consumer files — add `import PeerDropTransport`

---

## Task 1: Pre-Transport audit

**Files:** (analysis only)

Same pattern as M1d-2/3 audits. Goal: full picture of types to make public, consumers to add imports to, inter-leaf references.

- [ ] **Step 1: Inventory + type lists**

```bash
# Confirm 29 source files
ls PeerDrop/Transport/ | wc -l   # 17
ls PeerDrop/Discovery/ | wc -l   # 6
ls PeerDrop/Voice/ | wc -l       # 7 (6 + CallKitManager)

# Top-level types per file
for f in PeerDrop/Transport/*.swift PeerDrop/Discovery/*.swift PeerDrop/Voice/*.swift; do
    echo "=== $(basename $f) ==="
    grep -E "^(public |)?(struct|class|enum|protocol|typealias|actor) " "$f" | head -5
done
```

- [ ] **Step 2: External consumer scan**

```bash
grep -rln "PeerConnection\|FileTransfer\|MailboxClient\|MailboxManager\|BonjourDiscovery\|BLEDiscovery\|DiscoveryService\|TCPTransport\|DataChannelTransport\|WebRTCClient\|VoiceCallManager\|VoiceCallSession\|VoiceRecorder\|VoicePlayer\|SDPSignaling\|DeviceTokenManager\|WorkerSignaling\|WorkerAuthHelper\|ICEConfigurationProvider\|MessageFramer\|TransferMetadata\|TransferRecord\|OutboundRetryQueue\|NearbyInteractionManager\|TailscalePeer\|BLESignaling" PeerDrop/ --include="*.swift" | grep -v "/Transport/" | grep -v "/Discovery/" | grep -v "/Voice/" | grep -v "PeerDropKit/" | sort -u
```

For each match, note which Transport type(s) it uses. Build the consumer list.

- [ ] **Step 3: Check Voice test files**

```bash
find PeerDropTests -iname "*Voice*" -name "*.swift" 2>/dev/null
find PeerDropTests -iname "*WebRTC*" -name "*.swift" 2>/dev/null
find PeerDropTests -iname "*SDP*" -name "*.swift" 2>/dev/null
```

Add any matches to the test migration list. Note: CallKitManager-specific tests stay with CallKitManager in PeerDropTests/ (app target tests).

- [ ] **Step 4: PeerIdentity reference check (CRITICAL)**

```bash
grep -rln "PeerIdentity" PeerDrop/Transport/ PeerDrop/Discovery/ PeerDrop/Voice/ 2>/dev/null | head
```

PeerIdentity lives in `PeerDrop/Core/PeerIdentity.swift`. If Transport/Discovery/Voice files reference it, that's a problem:
- Transport → Core would cycle (Core depends on Transport per spec §1)
- Options:
  - (a) Move PeerIdentity to PeerDropSecurity (was originally specced there)
  - (b) Protocol-inversion bridge in app target

Per file, quote the line + decide resolution. Report.

- [ ] **Step 5: CallKitManager move target decision**

The plan says move CallKitManager to PeerDrop/App/. Verify there's no other file in PeerDrop/App/ that would conflict. Check current contents:

```bash
ls PeerDrop/App/
```

Expected: PeerDropApp.swift, AppDelegate.swift, Info.plist. Plus possibly PeerMessage+Hello.swift (from M1d-2). Adding CallKitManager.swift here is fine.

- [ ] **Step 6: No commit. Report findings.**

Output:
```
## Transport migration audit

### Source inventory
- 17 Transport + 6 Discovery + 6 Voice transport-side = 29 to move
- 1 CallKitManager stays (relocates to PeerDrop/App/CallKitManager.swift)

### Test inventory
- 13 (per plan estimate) + N Voice tests if any = total

### External consumer files
| File | Transport types used |
|------|---------------------|
| ... | ... |

Total: N files need `import PeerDropTransport`.

### Inter-module deps
- Transport → Protocol: required (PeerMessage et al)
- Transport → Security: required (ChatDataEncryptor, TrustedContact, RemoteSessionManager via MailboxClient bridge)
- Transport → Platform: required (CallProvider, AudioSessionConfiguring, HapticManager)
- Transport → Pet: NONE

### PeerIdentity issue
- N files reference PeerIdentity (in Core)
- Resolution: <chosen approach>

### Recommended Task ordering
1. Move 29 sources + handle PeerIdentity
2. Move CallKitManager to PeerDrop/App/
3. Mark types public + Package.swift deps
4. Add `import PeerDropTransport` to N consumers
5. Move 13+ test files
6. Update lint-imports CI (drop Voice/ exclusion)
7. Final verification + tag
```

---

## Task 2: Move source files (29 + CallKitManager relocation)

**Files:**
- Move: 17 Transport, 6 Discovery, 6 Voice transport-side
- Move: 1 CallKitManager (Voice → App)
- Delete: placeholder

- [ ] **Step 1: Move Transport flat files (17)**

```bash
for f in PeerDrop/Transport/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropTransport/
done
rmdir PeerDrop/Transport 2>/dev/null
```

- [ ] **Step 2: Move Discovery into subdir**

```bash
mkdir -p PeerDropKit/Sources/PeerDropTransport/Discovery
for f in PeerDrop/Discovery/*.swift; do
    git mv "$f" PeerDropKit/Sources/PeerDropTransport/Discovery/
done
rmdir PeerDrop/Discovery 2>/dev/null
```

- [ ] **Step 3: Move Voice transport-side into subdir**

```bash
mkdir -p PeerDropKit/Sources/PeerDropTransport/Voice

# All Voice files EXCEPT CallKitManager
for f in PeerDrop/Voice/*.swift; do
    base=$(basename "$f")
    if [ "$base" != "CallKitManager.swift" ]; then
        git mv "$f" "PeerDropKit/Sources/PeerDropTransport/Voice/"
    fi
done
```

- [ ] **Step 4: Relocate CallKitManager to app target**

```bash
git mv PeerDrop/Voice/CallKitManager.swift PeerDrop/App/CallKitManager.swift

# Voice/ should now be empty
rmdir PeerDrop/Voice 2>/dev/null
```

- [ ] **Step 5: Delete placeholder**

```bash
git rm PeerDropKit/Sources/PeerDropTransport/PeerDropTransport.swift
```

Verify:
```bash
ls PeerDrop/Transport PeerDrop/Discovery PeerDrop/Voice 2>&1   # all should error
ls PeerDrop/App/CallKitManager.swift   # exists
find PeerDropKit/Sources/PeerDropTransport -name "*.swift" | wc -l   # 29
```

- [ ] **Step 6: Don't build yet — Tasks 3 + 4 need to land for build**

---

## Task 3: Update Package.swift deps + mark types public

**Files:**
- Modify: `PeerDropKit/Package.swift`
- Modify: 29 PeerDropTransport source files (public upgrades)

- [ ] **Step 1: Add Package.swift deps**

Edit `PeerDropKit/Package.swift`. PeerDropTransport target:

```swift
.target(
    name: "PeerDropTransport",
    dependencies: [
        "PeerDropPlatform",
        "PeerDropProtocol",
        "PeerDropSecurity",
        .product(name: "WebRTC", package: "WebRTC"),
    ]
),
```

- [ ] **Step 2: Mark types public**

For each .swift file in PeerDropKit/Sources/PeerDropTransport/, upgrade:
- Top-level types → `public`
- Stored properties used externally → `public`
- Explicit `public init` for types instantiated externally
- Nested types accessed externally → `public`

Iterate via build errors.

Key types to prioritize:
- PeerConnection (heavy user from Core)
- FileTransfer + FileTransferSession + TransferMetadata + TransferRecord
- MailboxClient + MailboxManager
- BonjourDiscovery + BLEDiscovery + DiscoveryService
- TCPTransport + DataChannelTransport + TransportProtocol
- WebRTCClient + VoiceCallManager + VoiceCallSession
- RelayAuthenticator (used by app code)
- OutboundRetryQueue

---

## Task 4: Handle PeerIdentity cross-leaf reference (per Task 1 audit decision)

The audit identified PeerIdentity references in Transport/Discovery/Voice files. Apply the chosen resolution:

- (a) If moving PeerIdentity to PeerDropSecurity: git mv `PeerDrop/Core/PeerIdentity.swift` → `PeerDropKit/Sources/PeerDropSecurity/PeerIdentity.swift`. Update Security module's public surface. Add `import PeerDropSecurity` to consumers.
- (b) If protocol-inversion: define a `TransportIdentityProvider` protocol in PeerDropTransport that exposes only the PeerIdentity fields Transport needs. Conformance bridge in app target.

Pick based on the audit. (a) is cleaner if PeerIdentity has no Core-specific deps; (b) is the right call if PeerIdentity uses Core types extensively.

---

## Task 5: Add `import PeerDropTransport` to consumers

For each external consumer file from Task 1 audit, add the import.

Combined with Task 6 (build verify) — see commit strategy.

---

## Task 6: Build + iterate

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -20
```

Iterate on errors. Once clean:

```bash
cd PeerDropKit && swift build 2>&1 | tail -5 && cd ..
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -8
```

---

## Task 7: Commit (Tasks 2-6 combined)

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(m1d-4): migrate Transport into PeerDropTransport (29 files)

17 Transport + 6 Discovery + 6 Voice transport-side files moved
from PeerDrop/{Transport,Discovery,Voice}/ to
PeerDropKit/Sources/PeerDropTransport/ (preserving Discovery/ + Voice/
subdirs). Placeholder enum deleted.

CallKitManager.swift relocated to PeerDrop/App/ (next to AppDelegate)
— stays iOS-only per CallProvider abstraction from M1b. PeerDrop/Voice/
directory removed.

Types marked public for cross-module access. ~N consumer files gain
`import PeerDropTransport`.

PeerDropTransport target gains deps: PeerDropPlatform + PeerDropProtocol
+ PeerDropSecurity + WebRTC.

PeerIdentity handled via <chosen resolution>.

iOS build passes; iOS test count down by ~13 (Transport tests now via
swift test in Task 8).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Migrate Transport tests

Same pattern as M1d-3b Task 6. Move 13+ test files, update `@testable import`, add to PeerDropTransportTests target deps in Package.swift if needed.

Tests likely need:
- `@testable import PeerDropTransport`
- `@testable import PeerDropPlatform` (mocks)
- `@testable import PeerDropProtocol` (PeerMessage)
- `@testable import PeerDropSecurity` (some integration tests)

Or `import PeerDrop` for tests that exercise app-target wiring.

---

## Task 9: Update lint-imports CI

`-not -path "*/Voice/CallKitManager.swift"` exclusion is no longer needed (Voice/ dir gone; CallKitManager at PeerDrop/App/ which isn't scanned).

Edit `.github/workflows/ci.yml`. Remove the exclusion line.

Verify lint still passes locally.

---

## Task 10: Final verification + tag

```bash
xcodebuild test ... 2>&1 | tail -8
cd PeerDropKit && swift test 2>&1 | tail -8 && cd ..

git tag -a m1d-4-transport-migration -m "M1d-4 done: Transport migrated (29 files). CallKitManager relocated to App/. Only Core migration remains."
```

## Done

After M1d-4: PeerDropTransport has real content. Only PeerDropCore (M1d-5) remains in M1 train. CallKit-specific code isolated to app target as planned.

## Open Items for M1d-5

1. Core migration (~28 files: ConnectionManager, ChatManager, DeviceRecordStore, UserProfile, InboxService, FeatureSettings, ScreenshotModeProvider, etc.)
2. PeerIdentity placement (if not moved in M1d-4)
3. Remove unused WebRTC + ZIPFoundation direct deps from app target (now transitively via PeerDropKit)
4. PeerMessage+Hello.swift cleanup (if PeerIdentity moves, the factory may need re-extraction location update)
5. Final spec §1 dependency graph diagram update
