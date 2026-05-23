# v5.4 Relay Crypto Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v5.4 with four mid-tier relay-crypto risk mitigations (C1–C4), a signed remote-policy "crypto agility" layer, a reusable `CryptoTestKit` (property tests + frozen vectors + fuzz), and a published threat-model document — all wire-compatible with v5.0–v5.3.6.

**Architecture:** Add a pure `SecurityPolicy` value type + `SecurityPolicyStore` that synchronously reads cache/bundled defaults at boot and asynchronously fetches a signed JSON blob from the Cloudflare Worker. Crypto modules (`PreKeyStore`, `X3DH`, `DoubleRatchet`) read the policy at every entry point. Worker can only strengthen, never weaken, via stronger-of-two merge plus hard local bounds. Eight sequential PRs ship under one release with a feature-flag-via-policy activation strategy (PRs ship with bundled-default policy = legacy behavior; worker blob upgrade enables strict mode post-soak).

**Tech Stack:** Swift 5.9, XcodeGen, SwiftUI, CryptoKit (Curve25519, AES.GCM, HKDF, Ed25519), Cloudflare Workers TypeScript, XCTest with custom property-test harness.

**Spec reference:** `docs/plans/2026-05-23-relay-crypto-hardening-design.md`

---

## File Structure

### New files (Swift, app)

| Path | Responsibility |
|---|---|
| `PeerDrop/Security/SecurityPolicy.swift` | Immutable value type holding all tunable thresholds + bundled defaults + `merged(local:remote:)` stronger-of-two |
| `PeerDrop/Security/SecurityPolicyBounds.swift` | Hard local ranges; clamps any incoming value |
| `PeerDrop/Security/SecurityPolicyStore.swift` | `@MainActor` `ObservableObject`; loads cache → bundled → fetches remote; publishes `current` |
| `PeerDrop/Security/PeerPolicy.swift` | Resolves effective per-peer policy from `peerProtocolVersion` |
| `PeerDrop/Security/ProtocolVersion.swift` | Enum `.v5_4_plus / .legacy / .unknown` |
| `PeerDrop/Telemetry/CryptoHardeningMetrics.swift` | 22 named counters + flush integration |
| `PeerDrop/Transport/OutboundRetryQueue.swift` | Persistent queue for C2 retry-on-OPK-exhaustion |
| `PeerDrop/UI/Security/CryptoHardeningBanner.swift` | C1/C2 banner views (reuses `decryptFailureBanner` visuals) |

### New files (Swift, tests)

| Path | Responsibility |
|---|---|
| `PeerDropTests/CryptoTestKit/Sources/PropertyTest.swift` | Lightweight `forAll(n, seed:)` harness |
| `PeerDropTests/CryptoTestKit/Sources/TestVectorLoader.swift` | JSON fixture loader |
| `PeerDropTests/CryptoTestKit/Sources/DeterministicCrypto.swift` | Seeded key factories |
| `PeerDropTests/CryptoTestKit/Sources/FuzzHarness.swift` | Mutation operators + iteration runner |
| `PeerDropTests/CryptoTestKit/Tests/Properties/SecurityPolicyProperties.swift` | Stronger-of-two + bounds invariants |
| `PeerDropTests/CryptoTestKit/Tests/Properties/X3DHProperties.swift` | C1/C2 invariants |
| `PeerDropTests/CryptoTestKit/Tests/Properties/RatchetProperties.swift` | C3 invariants |
| `PeerDropTests/CryptoTestKit/Tests/Properties/PreKeyStoreProperties.swift` | C4 invariants |
| `PeerDropTests/CryptoTestKit/Tests/Vectors/FrozenVectorTests.swift` | Runs all JSON fixtures |
| `PeerDropTests/CryptoTestKit/Tests/Fuzz/X3DHFuzzTests.swift` | 10K parse iterations |
| `PeerDropTests/CryptoTestKit/Tests/Fuzz/RatchetFuzzTests.swift` | 10K parse iterations |
| `PeerDropTests/CryptoTestKit/Tests/Fuzz/PolicyFuzzTests.swift` | 10K parse iterations |
| `PeerDropTests/CryptoTestKit/TestVectors/x3dh/*.json` | 20 frozen X3DH input/output pairs |
| `PeerDropTests/CryptoTestKit/TestVectors/ratchet/*.json` | 30 frozen ratchet sequences |
| `PeerDropTests/CryptoTestKit/TestVectors/skipped-keys/*.json` | 10 out-of-order sequences |
| `PeerDropTests/CryptoTestKit/TestVectors/policy/*.json` | 5 signed-policy fixtures |
| `PeerDropTests/SecurityPolicyStoreTests.swift` | Integration tests (fetch, cache, signature verify) |
| `PeerDropTests/OutboundRetryQueueTests.swift` | C2 retry persistence/retry-tick |
| `PeerDropTests/PerPeerPolicyTests.swift` | PeerPolicy resolution |

### New files (Worker)

| Path | Responsibility |
|---|---|
| `cloudflare-worker/src/cryptoPolicy.ts` | Schema types, signed-blob serve, version handling |
| `cloudflare-worker/src/__tests__/cryptoPolicy.test.ts` | Endpoint tests |

### New files (tooling)

| Path | Responsibility |
|---|---|
| `tools/sign-crypto-policy.swift` | Offline Ed25519 signer (operator CLI) |
| `tools/generate-test-vectors.swift` | Deterministic vector generator |

### New files (docs)

| Path | Responsibility |
|---|---|
| `docs/security/threat-model-relay.md` | Attack trees + mitigations + residual risk |
| `docs/security/crypto-policy-format.md` | JSON schema + signing spec |

### Modified files

| Path | Change |
|---|---|
| `PeerDrop/Security/Protocol/PreKeyStore.swift` | C1 timestamp write; C4 prune; data structure change `Set<UInt32>` → `[UInt32: Date]` |
| `PeerDrop/Security/Protocol/X3DH.swift` | C1 timestamp verify; C2 fail-closed branch |
| `PeerDrop/Security/Protocol/DoubleRatchet.swift` | C3 TTL+LRU; skipped key value type wrap |
| `PeerDrop/Security/Protocol/PreKeyBundle.swift` | Add `signedPreKeyTimestamp: UInt64?` + `signedPreKeyTimestampSignature: Data?` |
| `PeerDrop/Security/Protocol/RemoteMessageEnvelope.swift` | Add `protocolVersion: UInt8?` |
| `PeerDrop/Core/TrustedContactStore.swift` | Add `peerProtocolVersion: ProtocolVersion?` to `TrustedContact` |
| `PeerDrop/Core/ConnectionManager.swift` | Wire `peerProtocolVersion` set on first envelope/first contact; instantiate `SecurityPolicyStore` |
| `PeerDrop/App/PeerDropApp.swift` | Inject `SecurityPolicyStore` into the env |
| `PeerDrop/App/Info.plist` | Add `CryptoPolicyPublicKeys` (base64 array) |
| `PeerDrop/App/Localizable.xcstrings` | 4 new keys × 5 languages |
| `cloudflare-worker/src/index.ts` | Add `/v2/config/crypto-policy` route |
| `cloudflare-worker/wrangler.toml` | Document `CRYPTO_POLICY_JSON` env var |
| `project.yml` | Bump `MARKETING_VERSION` to 5.4.0; add new files to sources |
| `fastlane/Fastfile` | (no change expected; release lane already handles version bump) |

---

## Conventions

- Every code task includes a TDD cycle: failing test → verify fail → minimal impl → verify pass → commit
- All file paths are absolute from repo root
- Build verification command (run after Swift source changes):
  ```
  xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
  ```
- Test verification command (run per task):
  ```
  xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/<TestClass>/<testMethod>
  ```
- After adding any new `.swift` file to the project: run `xcodegen generate` before next build
- Commit message style: `type: scope short description` per repo convention; add `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` line
- Each PR is one feature branch off `main`; tasks within a PR can share a branch

---

# PR1 — Foundation

**Branch:** `feat/v5.4-security-policy-foundation`

**Goal:** Land `SecurityPolicy` + `SecurityPolicyStore` + `CryptoHardeningMetrics` with bundled defaults, no consumers yet, zero behavior change.

---

### Task 1.1 — `SecurityPolicy.OPKExhaustionBehavior` enum

**Files:**
- Create: `PeerDrop/Security/SecurityPolicy.swift`
- Test: `PeerDropTests/SecurityPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PeerDropTests/SecurityPolicyTests.swift`:

```swift
import XCTest
@testable import PeerDrop

final class SecurityPolicyTests: XCTestCase {
    func test_OPKExhaustionBehavior_strictness_ordering() {
        XCTAssertGreaterThan(
            SecurityPolicy.OPKExhaustionBehavior.failClosed,
            SecurityPolicy.OPKExhaustionBehavior.proceedWithoutDH4,
            "failClosed is strictly stronger than proceedWithoutDH4"
        )
    }
}
```

- [ ] **Step 2: Run test, verify failure**

```
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SecurityPolicyTests/test_OPKExhaustionBehavior_strictness_ordering
```

Expected: fails with "Cannot find type 'SecurityPolicy'".

- [ ] **Step 3: Create the file**

`PeerDrop/Security/SecurityPolicy.swift`:

```swift
import Foundation

/// Immutable value type holding all tunable crypto-hardening thresholds.
/// Read at every relevant call site; never mutated in-place. Merging is
/// always stronger-of-two — see `merged(local:remote:)`.
public struct SecurityPolicy: Equatable, Codable {

    public enum OPKExhaustionBehavior: String, Codable, Comparable {
        /// Current pre-v5.4 behavior: skip DH4 and proceed with weakened
        /// forward secrecy.
        case proceedWithoutDH4

        /// v5.4+ behavior: refuse to initiate X3DH, schedule retry.
        case failClosed

        /// Strictness ordering: failClosed > proceedWithoutDH4.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.proceedWithoutDH4, .failClosed): return true
            default: return false
            }
        }
    }
}
```

- [ ] **Step 4: Run xcodegen + build + test**

```
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SecurityPolicyTests/test_OPKExhaustionBehavior_strictness_ordering
```

Expected: test PASS.

- [ ] **Step 5: Commit**

```bash
git checkout -b feat/v5.4-security-policy-foundation
git add PeerDrop/Security/SecurityPolicy.swift PeerDropTests/SecurityPolicyTests.swift project.yml
git commit -m "feat(security): add SecurityPolicy.OPKExhaustionBehavior enum

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.2 — `SecurityPolicy.SPKExpirationBehavior` enum

**Files:**
- Modify: `PeerDrop/Security/SecurityPolicy.swift`
- Modify: `PeerDropTests/SecurityPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `PeerDropTests/SecurityPolicyTests.swift`:

```swift
func test_SPKExpirationBehavior_strictness_ordering() {
    XCTAssertGreaterThan(
        SecurityPolicy.SPKExpirationBehavior.reject,
        SecurityPolicy.SPKExpirationBehavior.warn,
        "reject is strictly stronger than warn"
    )
}
```

- [ ] **Step 2: Run test, verify failure**

Same command, scoped to this test. Fails with "no member 'SPKExpirationBehavior'".

- [ ] **Step 3: Extend the type**

Inside `SecurityPolicy`:

```swift
public enum SPKExpirationBehavior: String, Codable, Comparable {
    case warn
    case reject

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.warn, .reject): return true
        default: return false
        }
    }
}
```

- [ ] **Step 4: Test PASS, no commit yet**

Run test. Continue to next task before committing.

---

### Task 1.3 — `SecurityPolicy` core struct + bundled defaults

**Files:**
- Modify: `PeerDrop/Security/SecurityPolicy.swift`
- Modify: `PeerDropTests/SecurityPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func test_bundledDefault_matchesSpec() {
    let p = SecurityPolicy.bundledDefault
    XCTAssertEqual(p.spkMaxAgeDays, 21)
    XCTAssertEqual(p.spkExpirationBehavior, .warn)
    XCTAssertEqual(p.opkExhaustionBehavior(.legacy), .proceedWithoutDH4)
    XCTAssertEqual(p.opkExhaustionBehavior(.v5_4_plus), .failClosed)
    XCTAssertEqual(p.opkRetryMaxAttempts, 5)
    XCTAssertEqual(p.opkRetryIntervalSeconds, 60)
    XCTAssertEqual(p.skippedKeyTTLDays, 30)
    XCTAssertEqual(p.skippedKeyMaxCount, 200)
    XCTAssertEqual(p.consumedOPKPruneWindowDays, 90)
}
```

- [ ] **Step 2: Run, verify failure**

Fails on `bundledDefault`, `spkMaxAgeDays`, `.legacy`, `.v5_4_plus` (the last two need `ProtocolVersion` from a future task — but we'll forward-declare).

- [ ] **Step 3: First create `ProtocolVersion.swift`**

`PeerDrop/Security/ProtocolVersion.swift`:

```swift
import Foundation

/// Identifies the wire-protocol generation of a peer for per-peer policy
/// decisions. v5.0–v5.3.x are `.legacy`; v5.4+ are `.v5_4_plus`;
/// `.unknown` is used before first contact or when the peer hasn't sent
/// any envelope yet.
public enum ProtocolVersion: String, Codable {
    case legacy
    case v5_4_plus
    case unknown
}
```

- [ ] **Step 4: Add core struct + `bundledDefault`**

Extend `SecurityPolicy.swift`:

```swift
public struct SecurityPolicy: Equatable, Codable {
    // (enums omitted for brevity — keep what's there)

    public let spkMaxAgeDays: Int
    public let spkExpirationBehavior: SPKExpirationBehavior
    private let opkExhaustionLegacy: OPKExhaustionBehavior
    private let opkExhaustionStrict: OPKExhaustionBehavior
    public let opkRetryMaxAttempts: Int
    public let opkRetryIntervalSeconds: Int
    public let skippedKeyTTLDays: Int
    public let skippedKeyMaxCount: Int
    public let consumedOPKPruneWindowDays: Int

    public func opkExhaustionBehavior(_ version: ProtocolVersion) -> OPKExhaustionBehavior {
        switch version {
        case .legacy: return opkExhaustionLegacy
        case .v5_4_plus, .unknown: return opkExhaustionStrict
        }
    }

    public init(
        spkMaxAgeDays: Int,
        spkExpirationBehavior: SPKExpirationBehavior,
        opkExhaustionLegacy: OPKExhaustionBehavior,
        opkExhaustionStrict: OPKExhaustionBehavior,
        opkRetryMaxAttempts: Int,
        opkRetryIntervalSeconds: Int,
        skippedKeyTTLDays: Int,
        skippedKeyMaxCount: Int,
        consumedOPKPruneWindowDays: Int
    ) {
        self.spkMaxAgeDays = spkMaxAgeDays
        self.spkExpirationBehavior = spkExpirationBehavior
        self.opkExhaustionLegacy = opkExhaustionLegacy
        self.opkExhaustionStrict = opkExhaustionStrict
        self.opkRetryMaxAttempts = opkRetryMaxAttempts
        self.opkRetryIntervalSeconds = opkRetryIntervalSeconds
        self.skippedKeyTTLDays = skippedKeyTTLDays
        self.skippedKeyMaxCount = skippedKeyMaxCount
        self.consumedOPKPruneWindowDays = consumedOPKPruneWindowDays
    }

    public static let bundledDefault = SecurityPolicy(
        spkMaxAgeDays: 21,
        spkExpirationBehavior: .warn,
        opkExhaustionLegacy: .proceedWithoutDH4,
        opkExhaustionStrict: .failClosed,
        opkRetryMaxAttempts: 5,
        opkRetryIntervalSeconds: 60,
        skippedKeyTTLDays: 30,
        skippedKeyMaxCount: 200,
        consumedOPKPruneWindowDays: 90
    )
}
```

- [ ] **Step 5: xcodegen + build + test**

All three SecurityPolicyTests should pass.

- [ ] **Step 6: Commit**

```bash
git add PeerDrop/Security/ProtocolVersion.swift PeerDrop/Security/SecurityPolicy.swift PeerDropTests/SecurityPolicyTests.swift project.yml
git commit -m "feat(security): SecurityPolicy struct + bundled defaults

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.4 — `SecurityPolicyBounds` clamping

**Files:**
- Create: `PeerDrop/Security/SecurityPolicyBounds.swift`
- Modify: `PeerDropTests/SecurityPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func test_bounds_clamp_outOfRangeValues() {
    let raw = SecurityPolicy(
        spkMaxAgeDays: 0,        // below min (7)
        spkExpirationBehavior: .warn,
        opkExhaustionLegacy: .proceedWithoutDH4,
        opkExhaustionStrict: .failClosed,
        opkRetryMaxAttempts: 999, // above max (20)
        opkRetryIntervalSeconds: 5, // below min (30)
        skippedKeyTTLDays: 30,
        skippedKeyMaxCount: 200,
        consumedOPKPruneWindowDays: 90
    )
    let clamped = SecurityPolicyBounds.clamp(raw)
    XCTAssertEqual(clamped.spkMaxAgeDays, 7)
    XCTAssertEqual(clamped.opkRetryMaxAttempts, 20)
    XCTAssertEqual(clamped.opkRetryIntervalSeconds, 30)
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create the file**

`PeerDrop/Security/SecurityPolicyBounds.swift`:

```swift
import Foundation

/// Hard local ranges for each policy field. Any value outside the range
/// (whether from local cache or remote fetch) is clamped to the nearest
/// bound. The bundled defaults are always within these ranges.
public enum SecurityPolicyBounds {

    public static let spkMaxAgeDaysRange = 7...90
    public static let opkRetryMaxAttemptsRange = 1...20
    public static let opkRetryIntervalSecondsRange = 30...600
    public static let skippedKeyTTLDaysRange = 1...365
    public static let skippedKeyMaxCountRange = 50...2000
    public static let consumedOPKPruneWindowDaysRange = 30...365

    public static func clamp(_ p: SecurityPolicy) -> SecurityPolicy {
        return SecurityPolicy(
            spkMaxAgeDays: p.spkMaxAgeDays.clamped(to: spkMaxAgeDaysRange),
            spkExpirationBehavior: p.spkExpirationBehavior,
            opkExhaustionLegacy: p.opkExhaustionBehavior(.legacy),
            opkExhaustionStrict: p.opkExhaustionBehavior(.v5_4_plus),
            opkRetryMaxAttempts: p.opkRetryMaxAttempts.clamped(to: opkRetryMaxAttemptsRange),
            opkRetryIntervalSeconds: p.opkRetryIntervalSeconds.clamped(to: opkRetryIntervalSecondsRange),
            skippedKeyTTLDays: p.skippedKeyTTLDays.clamped(to: skippedKeyTTLDaysRange),
            skippedKeyMaxCount: p.skippedKeyMaxCount.clamped(to: skippedKeyMaxCountRange),
            consumedOPKPruneWindowDays: p.consumedOPKPruneWindowDays.clamped(to: consumedOPKPruneWindowDaysRange)
        )
    }

    /// Returns the names of fields that were out of range (for telemetry).
    public static func violations(_ p: SecurityPolicy) -> [String] {
        var out: [String] = []
        if !spkMaxAgeDaysRange.contains(p.spkMaxAgeDays) { out.append("spkMaxAgeDays") }
        if !opkRetryMaxAttemptsRange.contains(p.opkRetryMaxAttempts) { out.append("opkRetryMaxAttempts") }
        if !opkRetryIntervalSecondsRange.contains(p.opkRetryIntervalSeconds) { out.append("opkRetryIntervalSeconds") }
        if !skippedKeyTTLDaysRange.contains(p.skippedKeyTTLDays) { out.append("skippedKeyTTLDays") }
        if !skippedKeyMaxCountRange.contains(p.skippedKeyMaxCount) { out.append("skippedKeyMaxCount") }
        if !consumedOPKPruneWindowDaysRange.contains(p.consumedOPKPruneWindowDays) { out.append("consumedOPKPruneWindowDays") }
        return out
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Security/SecurityPolicyBounds.swift PeerDropTests/SecurityPolicyTests.swift project.yml
git commit -m "feat(security): SecurityPolicyBounds clamping

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.5 — `SecurityPolicy.merged()` stronger-of-two

**Files:**
- Modify: `PeerDrop/Security/SecurityPolicy.swift`
- Modify: `PeerDropTests/SecurityPolicyTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func test_merge_strongerOfTwo_spkMaxAge() {
    let local = SecurityPolicy.bundledDefault  // spkMaxAge = 21
    let remote = SecurityPolicy(
        spkMaxAgeDays: 14,  // stricter
        spkExpirationBehavior: .warn,
        opkExhaustionLegacy: .proceedWithoutDH4,
        opkExhaustionStrict: .failClosed,
        opkRetryMaxAttempts: 5,
        opkRetryIntervalSeconds: 60,
        skippedKeyTTLDays: 30,
        skippedKeyMaxCount: 200,
        consumedOPKPruneWindowDays: 90
    )
    let merged = SecurityPolicy.merged(local: local, remote: remote)
    XCTAssertEqual(merged.spkMaxAgeDays, 14, "merge picks the shorter (stricter)")
}

func test_merge_strongerOfTwo_neverWeakerThanInput() {
    let a = SecurityPolicy.bundledDefault
    let b = SecurityPolicy(
        spkMaxAgeDays: 60,
        spkExpirationBehavior: .reject,  // stricter on this field
        opkExhaustionLegacy: .proceedWithoutDH4,
        opkExhaustionStrict: .failClosed,
        opkRetryMaxAttempts: 10,
        opkRetryIntervalSeconds: 60,
        skippedKeyTTLDays: 60,
        skippedKeyMaxCount: 100,  // stricter (smaller)
        consumedOPKPruneWindowDays: 180  // stricter (larger)
    )
    let m = SecurityPolicy.merged(local: a, remote: b)
    XCTAssertLessThanOrEqual(m.spkMaxAgeDays, min(a.spkMaxAgeDays, b.spkMaxAgeDays))
    XCTAssertGreaterThanOrEqual(m.spkExpirationBehavior, max(a.spkExpirationBehavior, b.spkExpirationBehavior))
    XCTAssertLessThanOrEqual(m.skippedKeyMaxCount, min(a.skippedKeyMaxCount, b.skippedKeyMaxCount))
    XCTAssertGreaterThanOrEqual(m.consumedOPKPruneWindowDays, max(a.consumedOPKPruneWindowDays, b.consumedOPKPruneWindowDays))
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Add the merge function**

Extend `SecurityPolicy.swift`:

```swift
extension SecurityPolicy {
    public static func merged(local: SecurityPolicy, remote: SecurityPolicy) -> SecurityPolicy {
        return SecurityPolicy(
            spkMaxAgeDays: min(local.spkMaxAgeDays, remote.spkMaxAgeDays),
            spkExpirationBehavior: max(local.spkExpirationBehavior, remote.spkExpirationBehavior),
            opkExhaustionLegacy: max(local.opkExhaustionBehavior(.legacy), remote.opkExhaustionBehavior(.legacy)),
            opkExhaustionStrict: max(local.opkExhaustionBehavior(.v5_4_plus), remote.opkExhaustionBehavior(.v5_4_plus)),
            opkRetryMaxAttempts: max(local.opkRetryMaxAttempts, remote.opkRetryMaxAttempts),
            opkRetryIntervalSeconds: local.opkRetryIntervalSeconds, // UX-only; local wins
            skippedKeyTTLDays: min(local.skippedKeyTTLDays, remote.skippedKeyTTLDays),
            skippedKeyMaxCount: min(local.skippedKeyMaxCount, remote.skippedKeyMaxCount),
            consumedOPKPruneWindowDays: max(local.consumedOPKPruneWindowDays, remote.consumedOPKPruneWindowDays)
        )
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Security/SecurityPolicy.swift PeerDropTests/SecurityPolicyTests.swift
git commit -m "feat(security): SecurityPolicy.merged stronger-of-two

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.6 — Invariant assertion: `consumedOPKPruneWindow ≥ spkMaxAge × 4`

**Files:**
- Modify: `PeerDrop/Security/SecurityPolicy.swift`
- Modify: `PeerDropTests/SecurityPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func test_invariant_pruneWindow_geq_spkMaxAge_times_4() {
    XCTAssertNoThrow(try SecurityPolicy.bundledDefault.validateInvariants())

    let bad = SecurityPolicy(
        spkMaxAgeDays: 30,
        spkExpirationBehavior: .warn,
        opkExhaustionLegacy: .proceedWithoutDH4,
        opkExhaustionStrict: .failClosed,
        opkRetryMaxAttempts: 5,
        opkRetryIntervalSeconds: 60,
        skippedKeyTTLDays: 30,
        skippedKeyMaxCount: 200,
        consumedOPKPruneWindowDays: 90  // 90 < 30*4=120 → violation
    )
    XCTAssertThrowsError(try bad.validateInvariants()) { error in
        guard case SecurityPolicy.InvariantError.pruneWindowTooShort = error else {
            return XCTFail("expected pruneWindowTooShort, got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Add validation**

```swift
extension SecurityPolicy {
    public enum InvariantError: Error, Equatable {
        case pruneWindowTooShort(prune: Int, required: Int)
    }

    public func validateInvariants() throws {
        let required = spkMaxAgeDays * 4
        if consumedOPKPruneWindowDays < required {
            throw InvariantError.pruneWindowTooShort(
                prune: consumedOPKPruneWindowDays,
                required: required
            )
        }
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Security/SecurityPolicy.swift PeerDropTests/SecurityPolicyTests.swift
git commit -m "feat(security): enforce pruneWindow >= spkMaxAge*4 invariant

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.7 — `CryptoHardeningMetrics` scaffolding

**Files:**
- Create: `PeerDrop/Telemetry/CryptoHardeningMetrics.swift`
- Test: `PeerDropTests/CryptoHardeningMetricsTests.swift`

- [ ] **Step 1: Write the failing test**

`PeerDropTests/CryptoHardeningMetricsTests.swift`:

```swift
import XCTest
@testable import PeerDrop

final class CryptoHardeningMetricsTests: XCTestCase {
    func test_recordIncrementsCounter() {
        let m = CryptoHardeningMetrics()
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.c1SpkTimestampTooOld, peerVersion: .legacy)
        let snapshot = m.snapshot()
        XCTAssertEqual(snapshot.counters["c1.spk_timestamp_valid"], 2)
        XCTAssertEqual(snapshot.counters["c1.spk_timestamp_too_old"], 1)
    }

    func test_eventKindCount_is_22() {
        XCTAssertEqual(CryptoHardeningMetrics.EventKind.allCases.count, 22,
                       "Spec §8.1 requires exactly 22 events")
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create the file**

`PeerDrop/Telemetry/CryptoHardeningMetrics.swift`:

```swift
import Foundation

/// Per-process counter store for the 22 crypto-hardening events listed
/// in spec §8.1. Counters are keyed by `(kind, peerVersion)` so the
/// flushed snapshot retains the per-peer-version dimension the spec
/// requires. Thread-safe via NSLock. Snapshots flush through the
/// existing ConnectionMetrics pipeline (wired in Task 1.10).
public final class CryptoHardeningMetrics {

    public enum EventKind: String, CaseIterable {
        // C1 (5)
        case c1SpkTimestampMissing            = "c1.spk_timestamp_missing"
        case c1SpkTimestampMalformed          = "c1.spk_timestamp_malformed"
        case c1SpkTimestampInvalidSignature   = "c1.spk_timestamp_invalid_signature"
        case c1SpkTimestampTooOld             = "c1.spk_timestamp_too_old"
        case c1SpkTimestampValid              = "c1.spk_timestamp_valid"

        // C2 (4)
        case c2OpkMissing                     = "c2.opk_missing"
        case c2OpkFailedInitiation            = "c2.opk_failed_initiation"
        case c2OpkRetrySucceeded              = "c2.opk_retry_succeeded"
        case c2OpkRetryExhausted              = "c2.opk_retry_exhausted"

        // C3 (4)
        case c3SkippedKeyEvictedTTL           = "c3.skipped_key_evicted_ttl"
        case c3SkippedKeyEvictedLRU           = "c3.skipped_key_evicted_lru"
        case c3SkippedKeyHit                  = "c3.skipped_key_hit"
        case c3SkippedKeyMiss                 = "c3.skipped_key_miss"

        // C4 (2)
        case c4ConsumedOpkPruned              = "c4.consumed_opk_pruned"
        case c4ConsumedOpkSize                = "c4.consumed_opk_size"

        // policy (7)
        case policyFetchSuccess               = "policy.fetch_success"
        case policyFetchFailure               = "policy.fetch_failure"
        case policySignatureInvalid           = "policy.signature_invalid"
        case policyVersionUnsupported         = "policy.version_unsupported"
        case policyValueOutOfBounds           = "policy.value_out_of_bounds"
        case policyCacheHit                   = "policy.cache_hit"
        case policyExpiredInUse               = "policy.expired_in_use"
    }

    public struct Key: Hashable {
        public let kind: String
        public let peerVersion: String?   // ProtocolVersion.rawValue or nil
    }

    public struct Snapshot {
        /// Flat counters by "kind" only — easy aggregate view used by tests
        /// and the simplest dashboard.
        public let counters: [String: Int]
        /// Counters keyed by both kind and peer version (when known).
        /// Sent to the worker as the canonical telemetry payload.
        public let keyedCounters: [Key: Int]
    }

    private let lock = NSLock()
    private var keyedCounters: [Key: Int] = [:]

    public init() {}

    public func record(_ kind: EventKind, peerVersion: ProtocolVersion? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(kind: kind.rawValue, peerVersion: peerVersion?.rawValue)
        keyedCounters[key, default: 0] += 1
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var flat: [String: Int] = [:]
        for (key, count) in keyedCounters {
            flat[key.kind, default: 0] += count
        }
        return Snapshot(counters: flat, keyedCounters: keyedCounters)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        keyedCounters.removeAll()
    }
}
```

Update the test in Step 1 to also exercise the per-peer-version dimension:

```swift
func test_recordIncrements_perPeerVersion() {
    let m = CryptoHardeningMetrics()
    m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
    m.record(.c1SpkTimestampValid, peerVersion: .legacy)
    let snap = m.snapshot()
    XCTAssertEqual(snap.counters["c1.spk_timestamp_valid"], 2)
    XCTAssertEqual(
        snap.keyedCounters[.init(kind: "c1.spk_timestamp_valid", peerVersion: "v5_4_plus")],
        1
    )
    XCTAssertEqual(
        snap.keyedCounters[.init(kind: "c1.spk_timestamp_valid", peerVersion: "legacy")],
        1
    )
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Telemetry/CryptoHardeningMetrics.swift PeerDropTests/CryptoHardeningMetricsTests.swift project.yml
git commit -m "feat(telemetry): CryptoHardeningMetrics scaffolding (22 events)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.8 — `PeerPolicy.policy(for:base:)` resolver

**Files:**
- Create: `PeerDrop/Security/PeerPolicy.swift`
- Test: `PeerDropTests/PerPeerPolicyTests.swift`

- [ ] **Step 1: Write the failing tests**

`PeerDropTests/PerPeerPolicyTests.swift`:

```swift
import XCTest
@testable import PeerDrop

final class PerPeerPolicyTests: XCTestCase {
    func test_legacy_peer_skips_C1_C2_strict_behaviors() {
        let base = SecurityPolicy.bundledDefault
        let p = PeerPolicy.policy(for: .legacy, base: base)
        // legacy peer's OPK exhaustion stays proceedWithoutDH4
        XCTAssertEqual(p.opkExhaustionBehavior(.legacy), .proceedWithoutDH4)
    }

    func test_v5_4_peer_uses_strict_behaviors() {
        let base = SecurityPolicy.bundledDefault
        let p = PeerPolicy.policy(for: .v5_4_plus, base: base)
        XCTAssertEqual(p.opkExhaustionBehavior(.v5_4_plus), .failClosed)
    }

    func test_unknown_peer_defaults_to_strict() {
        let base = SecurityPolicy.bundledDefault
        let p = PeerPolicy.policy(for: .unknown, base: base)
        XCTAssertEqual(p.opkExhaustionBehavior(.unknown), .failClosed)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create `PeerPolicy.swift`**

```swift
import Foundation

/// Resolves the effective `SecurityPolicy` for a given peer based on its
/// detected protocol version. The base policy is the merged
/// local-stronger-of-two-remote; this function applies per-peer
/// adjustments without weakening it.
public enum PeerPolicy {
    public static func policy(for version: ProtocolVersion, base: SecurityPolicy) -> SecurityPolicy {
        // Currently a no-op pass-through: per-peer logic is consumed
        // inside the call sites via `base.opkExhaustionBehavior(version)`.
        // This wrapper exists so future per-peer adjustments (e.g.,
        // version-specific timeouts) have a single entry point.
        return base
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Security/PeerPolicy.swift PeerDropTests/PerPeerPolicyTests.swift project.yml
git commit -m "feat(security): PeerPolicy resolver entry point

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.9 — `SecurityPolicyStore` skeleton (cache + bundled-default fallback only; no network yet)

**Files:**
- Create: `PeerDrop/Security/SecurityPolicyStore.swift`
- Test: `PeerDropTests/SecurityPolicyStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import PeerDrop

final class SecurityPolicyStoreTests: XCTestCase {
    func test_init_with_no_cache_uses_bundled_default() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = SecurityPolicyStore(storageDirectory: tmpDir, publicKeys: [])
        XCTAssertEqual(store.current, .bundledDefault)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create the file (skeleton)**

```swift
import Foundation
import Combine

/// Boot-time policy loader. Reads cache → bundled default synchronously;
/// (network fetch will be added in PR4). Exposes `current` as a published
/// property for SwiftUI consumers.
@MainActor
public final class SecurityPolicyStore: ObservableObject {

    @Published public private(set) var current: SecurityPolicy

    private let storageDirectory: URL
    private let publicKeys: [Data]  // Ed25519 public keys for signature verification (PR4)
    private let metrics: CryptoHardeningMetrics?

    public init(
        storageDirectory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics? = nil
    ) {
        self.storageDirectory = storageDirectory
        self.publicKeys = publicKeys
        self.metrics = metrics
        // Synchronous boot load.
        self.current = Self.loadFromCacheOrBundled(
            directory: storageDirectory,
            publicKeys: publicKeys,
            metrics: metrics
        )
    }

    private static func loadFromCacheOrBundled(
        directory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics?
    ) -> SecurityPolicy {
        // PR4 will read and verify a cached signed blob here. For PR1,
        // always return the bundled default so the consumer surface
        // is testable end-to-end.
        metrics?.record(.policyCacheHit)
        return .bundledDefault
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Security/SecurityPolicyStore.swift PeerDropTests/SecurityPolicyStoreTests.swift project.yml
git commit -m "feat(security): SecurityPolicyStore skeleton (bundled-only)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.10 — Wire `SecurityPolicyStore` + `CryptoHardeningMetrics` into the App env

**Files:**
- Modify: `PeerDrop/App/PeerDropApp.swift`
- Modify: `PeerDrop/Core/ConnectionManager.swift`

- [ ] **Step 1: Identify the current root injection point**

```
grep -n "ConnectionManager()" PeerDrop/App/PeerDropApp.swift
grep -n "@StateObject\|@EnvironmentObject" PeerDrop/App/PeerDropApp.swift
```

- [ ] **Step 2: Add SecurityPolicyStore + metrics to PeerDropApp**

In `PeerDrop/App/PeerDropApp.swift`, inside the `App` struct:

```swift
@StateObject private var policyStore: SecurityPolicyStore = {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Security")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bundledKeys: [Data] = (Bundle.main.object(forInfoDictionaryKey: "CryptoPolicyPublicKeys") as? [String])?
        .compactMap { Data(base64Encoded: $0) } ?? []
    return SecurityPolicyStore(storageDirectory: dir, publicKeys: bundledKeys, metrics: cryptoMetrics)
}()

@StateObject private var cryptoMetrics = CryptoHardeningMetrics()
```

Apply `.environmentObject(policyStore).environmentObject(cryptoMetrics)` to the root view.

- [ ] **Step 3: Inject into ConnectionManager init (no consumers yet — just hold the reference)**

In `PeerDrop/Core/ConnectionManager.swift`, add stored properties:

```swift
let policyStore: SecurityPolicyStore?
let cryptoMetrics: CryptoHardeningMetrics?
```

Add to the designated init (parameter with default `nil` to avoid breaking existing callers):

```swift
init(
    /* existing params, */
    policyStore: SecurityPolicyStore? = nil,
    cryptoMetrics: CryptoHardeningMetrics? = nil
) {
    /* existing */
    self.policyStore = policyStore
    self.cryptoMetrics = cryptoMetrics
}
```

- [ ] **Step 4: Build + smoke test**

```
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SecurityPolicyStoreTests
```

Expected: build succeeds, existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/App/PeerDropApp.swift PeerDrop/Core/ConnectionManager.swift
git commit -m "feat(security): inject SecurityPolicyStore + CryptoHardeningMetrics

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.11 — Bundled public keys placeholder

**Files:**
- Modify: `PeerDrop/App/Info.plist`

- [ ] **Step 1: Add the Info.plist key**

Open `PeerDrop/App/Info.plist`, add:

```xml
<key>CryptoPolicyPublicKeys</key>
<array>
    <!-- Placeholder — replaced in PR4 with real Ed25519 public keys -->
    <string>PLACEHOLDER_REPLACED_IN_PR4</string>
</array>
```

- [ ] **Step 2: Verify the placeholder reads correctly (still ignored by SecurityPolicyStore in PR1)**

Run existing `SecurityPolicyStoreTests` — should still pass.

- [ ] **Step 3: Commit**

```bash
git add PeerDrop/App/Info.plist
git commit -m "chore(security): add CryptoPolicyPublicKeys Info.plist placeholder

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.12 — PR1 wrap-up: bump xcodegen, run full test suite, open PR

- [ ] **Step 1: Regenerate project, full test run**

```
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

Expected: all existing tests pass + all new tests pass.

- [ ] **Step 2: Push branch + open PR**

```
git push -u origin feat/v5.4-security-policy-foundation
gh pr create --base main --title "feat(security): v5.4 PR1 — SecurityPolicy foundation" --body "$(cat <<'EOF'
## Summary
- Adds `SecurityPolicy` (immutable value type) + `SecurityPolicyBounds` + `merged()` stronger-of-two
- Adds `SecurityPolicyStore` skeleton (loads bundled defaults; remote fetch lands in PR4)
- Adds `CryptoHardeningMetrics` with all 22 spec'd event kinds
- Adds `PeerPolicy` resolver entry point + `ProtocolVersion` enum
- Wires both into `PeerDropApp` and `ConnectionManager`
- No behavior change — no consumers yet.

## Test plan
- [ ] `SecurityPolicyTests` — bundled defaults, bounds clamping, merge invariants, pruneWindow×4 assertion
- [ ] `SecurityPolicyStoreTests` — boot-time cache fallback to bundled
- [ ] `CryptoHardeningMetricsTests` — 22 events present, counter increments
- [ ] `PerPeerPolicyTests` — resolver returns expected per-version policy
- [ ] Full simulator build passes

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

# PR2 — CryptoTestKit

**Branch:** `feat/v5.4-crypto-testkit`

**Goal:** Build the property-test harness, the test-vector loader, and the fuzz harness. Generate the first set of frozen test vectors and bring crypto-layer coverage to 95%+.

---

### Task 2.1 — `PropertyTest` harness

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Sources/PropertyTest.swift`
- Test: `PeerDropTests/CryptoTestKit/Tests/PropertyTestHarnessTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import PeerDrop

final class PropertyTestHarnessTests: XCTestCase {
    func test_forAll_runsNTrials() {
        var calls = 0
        PropertyTest.forAll(trials: 50, seed: 42) { rng in
            calls += 1
            return true
        }
        XCTAssertEqual(calls, 50)
    }

    func test_forAll_fails_when_property_returns_false() {
        let result = PropertyTest.runCapturingFailure(trials: 100, seed: 42) { rng in
            return rng.next() % 10 != 7  // will fail on some seed
        }
        XCTAssertNotNil(result.firstFailingSeed)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create the harness**

`PeerDropTests/CryptoTestKit/Sources/PropertyTest.swift`:

```swift
import Foundation
import XCTest

/// Lightweight property-testing harness. Each trial gets a seeded RNG so
/// failures are reproducible. Built in-house to avoid a SwiftCheck
/// dependency and keep the CI surface minimal.
public enum PropertyTest {

    public struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        public init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
        public mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    public struct FailureReport {
        public let firstFailingSeed: UInt64?
        public let trialsRun: Int
    }

    /// Asserts a property holds for `trials` random inputs. Uses XCTFail
    /// on first failure (with the seed printed for reproducibility).
    public static func forAll(
        trials: Int,
        seed: UInt64,
        file: StaticString = #file,
        line: UInt = #line,
        _ property: (inout SeededRNG) -> Bool
    ) {
        for trial in 0..<trials {
            let trialSeed = seed &+ UInt64(trial)
            var rng = SeededRNG(seed: trialSeed)
            if !property(&rng) {
                XCTFail("Property failed on trial \(trial), seed \(trialSeed). Reproduce with .forAll(trials: 1, seed: \(trialSeed)).",
                        file: file, line: line)
                return
            }
        }
    }

    /// Variant that returns a structured report instead of using XCTFail —
    /// for self-testing the harness.
    public static func runCapturingFailure(
        trials: Int,
        seed: UInt64,
        _ property: (inout SeededRNG) -> Bool
    ) -> FailureReport {
        for trial in 0..<trials {
            let trialSeed = seed &+ UInt64(trial)
            var rng = SeededRNG(seed: trialSeed)
            if !property(&rng) {
                return FailureReport(firstFailingSeed: trialSeed, trialsRun: trial + 1)
            }
        }
        return FailureReport(firstFailingSeed: nil, trialsRun: trials)
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git checkout -b feat/v5.4-crypto-testkit
git add PeerDropTests/CryptoTestKit/Sources/PropertyTest.swift PeerDropTests/CryptoTestKit/Tests/PropertyTestHarnessTests.swift project.yml
git commit -m "test(cryptotestkit): PropertyTest harness with seeded RNG

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.2 — `DeterministicCrypto` seeded key factory

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Sources/DeterministicCrypto.swift`
- Test: `PeerDropTests/CryptoTestKit/Tests/DeterministicCryptoTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class DeterministicCryptoTests: XCTestCase {
    func test_sameSeed_producesSameKey() {
        let seed = Data(repeating: 0xAB, count: 32)
        let k1 = DeterministicCrypto.curve25519AgreementKey(seed: seed)
        let k2 = DeterministicCrypto.curve25519AgreementKey(seed: seed)
        XCTAssertEqual(k1.rawRepresentation, k2.rawRepresentation)
    }

    func test_differentSeed_differentKey() {
        let k1 = DeterministicCrypto.curve25519AgreementKey(seed: Data(repeating: 0x01, count: 32))
        let k2 = DeterministicCrypto.curve25519AgreementKey(seed: Data(repeating: 0x02, count: 32))
        XCTAssertNotEqual(k1.rawRepresentation, k2.rawRepresentation)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create the file**

```swift
import Foundation
import CryptoKit

/// Deterministic key factories for test vectors. Never use these for any
/// production code — seeds are predictable.
public enum DeterministicCrypto {
    public static func curve25519AgreementKey(seed: Data) -> Curve25519.KeyAgreement.PrivateKey {
        // CryptoKit's PrivateKey init throws on invalid seed bytes (e.g.,
        // small subgroup) — extremely unlikely with arbitrary 32-byte seed,
        // but we retry with a derived seed if it happens.
        var attempt = seed
        for _ in 0..<8 {
            if let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: attempt) {
                return key
            }
            attempt = Data(SHA256.hash(data: attempt))
        }
        preconditionFailure("Could not derive Curve25519 key from seed")
    }

    public static func curve25519SigningKey(seed: Data) -> Curve25519.Signing.PrivateKey {
        var attempt = seed
        for _ in 0..<8 {
            if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: attempt) {
                return key
            }
            attempt = Data(SHA256.hash(data: attempt))
        }
        preconditionFailure("Could not derive Curve25519 signing key from seed")
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDropTests/CryptoTestKit/Sources/DeterministicCrypto.swift PeerDropTests/CryptoTestKit/Tests/DeterministicCryptoTests.swift project.yml
git commit -m "test(cryptotestkit): DeterministicCrypto seeded key factories

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.3 — `TestVectorLoader`

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Sources/TestVectorLoader.swift`
- Create: `PeerDropTests/CryptoTestKit/TestVectors/example-loader-test.json`
- Test: `PeerDropTests/CryptoTestKit/Tests/TestVectorLoaderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import PeerDrop

final class TestVectorLoaderTests: XCTestCase {
    struct Sample: Codable, Equatable {
        let name: String
        let value: Int
    }

    func test_loadsAndParsesJSON() throws {
        let url = Bundle(for: type(of: self)).url(
            forResource: "example-loader-test",
            withExtension: "json"
        )!
        let v: Sample = try TestVectorLoader.load(from: url)
        XCTAssertEqual(v, Sample(name: "test", value: 42))
    }
}
```

`example-loader-test.json`:

```json
{ "name": "test", "value": 42 }
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create the loader**

```swift
import Foundation

public enum TestVectorLoader {
    public enum LoadError: Error { case fileNotFound(URL); case decodeFailed(Error) }

    public static func load<T: Decodable>(from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LoadError.decodeFailed(error)
        }
    }

    public static func loadAll<T: Decodable>(matching pattern: String, in bundle: Bundle) throws -> [T] {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: pattern) ?? []
        return try urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .map { try load(from: $0) as T }
    }
}
```

- [ ] **Step 4: Add JSON to test bundle**

In `project.yml`, ensure `PeerDropTests/CryptoTestKit/TestVectors/` is added as a resource group for the test target. Run `xcodegen generate`.

- [ ] **Step 5: Test PASS**

- [ ] **Step 6: Commit**

```bash
git add PeerDropTests/CryptoTestKit/Sources/TestVectorLoader.swift \
        PeerDropTests/CryptoTestKit/TestVectors/example-loader-test.json \
        PeerDropTests/CryptoTestKit/Tests/TestVectorLoaderTests.swift \
        project.yml
git commit -m "test(cryptotestkit): TestVectorLoader JSON harness

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.4 — Vector generator tool (`tools/generate-test-vectors.swift`)

**Files:**
- Create: `tools/generate-test-vectors.swift`

- [ ] **Step 1: Create the tool**

```swift
#!/usr/bin/env swift
// Run: swift tools/generate-test-vectors.swift PeerDropTests/CryptoTestKit/TestVectors/
//
// Deterministic vector generator for the CryptoTestKit fixtures.
// Re-run after intentional crypto changes; never run to "make a failing
// test pass" — vectors are the source of truth.

import Foundation
import CryptoKit

guard CommandLine.arguments.count >= 2 else {
    print("usage: generate-test-vectors.swift <output-dir>")
    exit(1)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])

// ... emit JSON for 20 X3DH + 30 ratchet + 10 skipped-key + 5 policy
// vectors. (Implementation: copy the deterministic Swift helpers from
// PeerDropTests/CryptoTestKit/Sources/ — this script doesn't link the
// app target.)
```

This task is intentionally a placeholder: the full vector generator is large. Mark this task as "design only — implementation in Task 2.5"; the tool will be filled in below.

- [ ] **Step 2: Create the X3DH vector emitter (Task 2.5 below covers the actual generation)**

---

### Task 2.5 — Generate 20 X3DH vectors + frozen vector tests

**Files:**
- Modify: `tools/generate-test-vectors.swift`
- Create: `PeerDropTests/CryptoTestKit/TestVectors/x3dh/vec-001.json` through `vec-020.json`
- Create: `PeerDropTests/CryptoTestKit/Tests/Vectors/X3DHVectorTests.swift`

- [ ] **Step 1: Define the JSON shape**

Example `vec-001.json`:

```json
{
  "name": "x3dh_initiator_with_opk_seed_01",
  "inputs": {
    "alice_ik_seed": "0101010101010101010101010101010101010101010101010101010101010101",
    "bob_ik_seed":   "0202020202020202020202020202020202020202020202020202020202020202",
    "bob_spk_seed":  "0303030303030303030303030303030303030303030303030303030303030303",
    "bob_opk_seed":  "0404040404040404040404040404040404040404040404040404040404040404",
    "alice_ek_seed": "0505050505050505050505050505050505050505050505050505050505050505"
  },
  "expected": {
    "root_key":  "<base64 — computed by initial generator run>",
    "chain_key": "<base64 — computed by initial generator run>"
  }
}
```

- [ ] **Step 2: Fill in `generate-test-vectors.swift` for X3DH**

In the tool, generate vectors by:
1. Producing 20 unique seed quintuples (deterministic — e.g., index ⊕ field-magic byte)
2. For each, derive keys via `DeterministicCrypto`
3. Run `X3DH.initiate` against the deterministic responder bundle
4. Capture `(rootKey, chainKey)` and emit JSON

- [ ] **Step 3: Run the tool to populate vec-001.json … vec-020.json**

```
swift tools/generate-test-vectors.swift PeerDropTests/CryptoTestKit/TestVectors/x3dh/
```

- [ ] **Step 4: Write the vector test**

`PeerDropTests/CryptoTestKit/Tests/Vectors/X3DHVectorTests.swift`:

```swift
import XCTest
@testable import PeerDrop

final class X3DHVectorTests: XCTestCase {
    struct X3DHVector: Codable {
        let name: String
        let inputs: Inputs
        let expected: Expected

        struct Inputs: Codable {
            let alice_ik_seed: String
            let bob_ik_seed: String
            let bob_spk_seed: String
            let bob_opk_seed: String
            let alice_ek_seed: String
        }
        struct Expected: Codable {
            let root_key: String
            let chain_key: String
        }
    }

    func test_all_x3dh_vectors() throws {
        let urls = Bundle(for: type(of: self))
            .urls(forResourcesWithExtension: "json", subdirectory: "x3dh") ?? []
        XCTAssertGreaterThanOrEqual(urls.count, 20, "expected ≥ 20 X3DH vectors")
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let v: X3DHVector = try TestVectorLoader.load(from: url)
            let result = try runVector(v)
            XCTAssertEqual(result.rootKey.base64EncodedString(), v.expected.root_key, "rootKey mismatch in \(v.name)")
            XCTAssertEqual(result.chainKey.base64EncodedString(), v.expected.chain_key, "chainKey mismatch in \(v.name)")
        }
    }

    private func runVector(_ v: X3DHVector) throws -> (rootKey: Data, chainKey: Data) {
        let aliceIK = DeterministicCrypto.curve25519AgreementKey(seed: Data(hex: v.inputs.alice_ik_seed))
        let bobIK = DeterministicCrypto.curve25519AgreementKey(seed: Data(hex: v.inputs.bob_ik_seed))
        let bobSPK = DeterministicCrypto.curve25519AgreementKey(seed: Data(hex: v.inputs.bob_spk_seed))
        let bobOPK = DeterministicCrypto.curve25519AgreementKey(seed: Data(hex: v.inputs.bob_opk_seed))
        let aliceEK = DeterministicCrypto.curve25519AgreementKey(seed: Data(hex: v.inputs.alice_ek_seed))
        let result = try X3DH.initiate(
            myIdentityKey: aliceIK,
            myEphemeralKey: aliceEK,
            theirIdentityKey: bobIK.publicKey,
            theirSignedPreKey: bobSPK.publicKey,
            theirOneTimePreKey: bobOPK.publicKey
        )
        return (
            rootKey: result.rootKey.withUnsafeBytes { Data($0) },
            chainKey: result.chainKey.withUnsafeBytes { Data($0) }
        )
    }
}

private extension Data {
    init(hex: String) {
        var data = Data(); data.reserveCapacity(hex.count/2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self = data
    }
}
```

- [ ] **Step 5: Run + commit**

```
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/X3DHVectorTests
git add tools/generate-test-vectors.swift \
        PeerDropTests/CryptoTestKit/TestVectors/x3dh/ \
        PeerDropTests/CryptoTestKit/Tests/Vectors/X3DHVectorTests.swift \
        project.yml
git commit -m "test(cryptotestkit): 20 frozen X3DH vectors

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.6 — Generate 30 ratchet vectors + tests

**Files:**
- Modify: `tools/generate-test-vectors.swift` (add ratchet emitter)
- Create: `PeerDropTests/CryptoTestKit/TestVectors/ratchet/vec-001.json` … `vec-030.json`
- Create: `PeerDropTests/CryptoTestKit/Tests/Vectors/RatchetVectorTests.swift`

Mirror Task 2.5's pattern. Each ratchet vector encodes:
- Initial root key + DH key seeds
- A sequence of `[send/recv, plaintext_hex]` operations
- Expected per-message ciphertexts

Tests iterate the sequence and verify byte-for-byte equality.

Commit message: `test(cryptotestkit): 30 frozen ratchet vectors`

---

### Task 2.7 — Generate 10 skipped-key sequence vectors + tests

**Files:**
- Modify: `tools/generate-test-vectors.swift`
- Create: `PeerDropTests/CryptoTestKit/TestVectors/skipped-keys/vec-001.json` … `vec-010.json`
- Create: `PeerDropTests/CryptoTestKit/Tests/Vectors/SkippedKeyVectorTests.swift`

Vector schema includes:
- Send-then-receive-out-of-order operations
- Expected `skippedKeys` cache contents after each step
- Final post-recovery plaintext

Commit message: `test(cryptotestkit): 10 frozen skipped-key sequence vectors`

---

### Task 2.8 — Generate 5 signed-policy fixtures + tests

**Files:**
- Modify: `tools/generate-test-vectors.swift` (add policy signer with a test-only key)
- Create: `PeerDropTests/CryptoTestKit/TestVectors/policy/{valid,expired,tampered-sig,malformed-json,unsupported-version}.json`
- Create: `PeerDropTests/CryptoTestKit/Tests/Vectors/PolicyVectorTests.swift`

The test-only signing key is committed to `PeerDropTests/CryptoTestKit/TestVectors/policy/test-signing-key.json` and used only by tests. Production builds use the `Info.plist` public keys.

Tests assert that each fixture parses (or fails to parse) as expected by `SecurityPolicyStore.parseSignedPolicy()` (which lands in PR4 — for PR2, only the JSON loader part is exercised).

Commit message: `test(cryptotestkit): 5 signed-policy fixtures`

---

### Task 2.9 — `FuzzHarness` with mutation operators

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Sources/FuzzHarness.swift`
- Test: `PeerDropTests/CryptoTestKit/Tests/FuzzHarnessTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
final class FuzzHarnessTests: XCTestCase {
    func test_mutate_bitFlip_changesOneByte() {
        let original = Data(repeating: 0xAA, count: 32)
        var rng = PropertyTest.SeededRNG(seed: 42)
        let mutated = FuzzHarness.mutate(original, operator: .bitFlip, rng: &rng)
        XCTAssertEqual(mutated.count, original.count)
        XCTAssertNotEqual(mutated, original)
        // exactly one byte should differ
        let differingBytes = zip(mutated, original).filter { $0 != $1 }.count
        XCTAssertEqual(differingBytes, 1)
    }

    func test_run_iteratesNTimes() {
        var seen = 0
        FuzzHarness.run(
            target: Data(repeating: 0, count: 16),
            iterations: 100,
            seed: 42,
            operators: [.bitFlip, .byteInsert, .byteDelete, .truncate]
        ) { _ in
            seen += 1
        }
        XCTAssertEqual(seen, 100)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Create the harness**

```swift
import Foundation

public enum FuzzHarness {

    public enum Mutator: CaseIterable {
        case bitFlip
        case byteInsert
        case byteDelete
        case truncate
    }

    public static func mutate(
        _ input: Data,
        operator op: Mutator,
        rng: inout PropertyTest.SeededRNG
    ) -> Data {
        switch op {
        case .bitFlip:
            guard !input.isEmpty else { return input }
            var out = input
            let idx = Int(rng.next() % UInt64(input.count))
            let bit: UInt8 = 1 << UInt8(rng.next() % 8)
            out[idx] ^= bit
            return out
        case .byteInsert:
            var out = input
            let idx = Int(rng.next() % UInt64(input.count + 1))
            out.insert(UInt8(rng.next() & 0xFF), at: idx)
            return out
        case .byteDelete:
            guard input.count > 1 else { return input }
            var out = input
            out.remove(at: Int(rng.next() % UInt64(out.count)))
            return out
        case .truncate:
            guard input.count > 1 else { return input }
            let cut = Int(rng.next() % UInt64(input.count))
            return input.prefix(cut)
        }
    }

    public static func run(
        target: Data,
        iterations: Int,
        seed: UInt64,
        operators: [Mutator],
        body: (Data) -> Void
    ) {
        var rng = PropertyTest.SeededRNG(seed: seed)
        for _ in 0..<iterations {
            let op = operators[Int(rng.next() % UInt64(operators.count))]
            let mutated = mutate(target, operator: op, rng: &rng)
            body(mutated)
        }
    }
}
```

- [ ] **Step 4: Test PASS, commit**

```bash
git add PeerDropTests/CryptoTestKit/Sources/FuzzHarness.swift \
        PeerDropTests/CryptoTestKit/Tests/FuzzHarnessTests.swift \
        project.yml
git commit -m "test(cryptotestkit): FuzzHarness mutation operators

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.10 — `SecurityPolicy` property tests (stronger-of-two invariants)

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Tests/Properties/SecurityPolicyProperties.swift`

- [ ] **Step 1: Write the property tests**

```swift
import XCTest
@testable import PeerDrop

final class SecurityPolicyProperties: XCTestCase {

    func test_property_merge_neverWeakerThanInputs() {
        PropertyTest.forAll(trials: 200, seed: 1) { rng in
            let a = randomBoundedPolicy(rng: &rng)
            let b = randomBoundedPolicy(rng: &rng)
            let m = SecurityPolicy.merged(local: a, remote: b)
            return policyStrictness(m) >= max(policyStrictness(a), policyStrictness(b))
        }
    }

    func test_property_clamp_alwaysInBounds() {
        PropertyTest.forAll(trials: 200, seed: 2) { rng in
            let raw = randomUnboundedPolicy(rng: &rng)
            let clamped = SecurityPolicyBounds.clamp(raw)
            return SecurityPolicyBounds.spkMaxAgeDaysRange.contains(clamped.spkMaxAgeDays)
                && SecurityPolicyBounds.skippedKeyTTLDaysRange.contains(clamped.skippedKeyTTLDays)
                && SecurityPolicyBounds.skippedKeyMaxCountRange.contains(clamped.skippedKeyMaxCount)
                && SecurityPolicyBounds.consumedOPKPruneWindowDaysRange.contains(clamped.consumedOPKPruneWindowDays)
        }
    }

    // Helpers
    private func randomBoundedPolicy(rng: inout PropertyTest.SeededRNG) -> SecurityPolicy {
        SecurityPolicy(
            spkMaxAgeDays: Int(rng.next() % 84) + 7,
            spkExpirationBehavior: rng.next() % 2 == 0 ? .warn : .reject,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: Int(rng.next() % 20) + 1,
            opkRetryIntervalSeconds: Int(rng.next() % 571) + 30,
            skippedKeyTTLDays: Int(rng.next() % 365) + 1,
            skippedKeyMaxCount: Int(rng.next() % 1951) + 50,
            consumedOPKPruneWindowDays: Int(rng.next() % 336) + 30
        )
    }

    private func randomUnboundedPolicy(rng: inout PropertyTest.SeededRNG) -> SecurityPolicy {
        SecurityPolicy(
            spkMaxAgeDays: Int(rng.next() % 1000) - 500,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: Int(rng.next() % 1000),
            opkRetryIntervalSeconds: Int(rng.next() % 10000),
            skippedKeyTTLDays: Int(rng.next() % 1000),
            skippedKeyMaxCount: Int(rng.next() % 10000),
            consumedOPKPruneWindowDays: Int(rng.next() % 1000)
        )
    }

    private func policyStrictness(_ p: SecurityPolicy) -> Int {
        // Composite scalar where larger = stricter. Pure for property-test ordering only.
        return (90 - p.spkMaxAgeDays)             // shorter = stricter
             + (p.spkExpirationBehavior == .reject ? 100 : 0)
             + (200 - p.skippedKeyMaxCount)       // smaller cap = stricter
             + (p.consumedOPKPruneWindowDays - 30) // longer = stricter
    }
}
```

- [ ] **Step 2: Run, verify PASS**

- [ ] **Step 3: Commit**

```bash
git add PeerDropTests/CryptoTestKit/Tests/Properties/SecurityPolicyProperties.swift project.yml
git commit -m "test(cryptotestkit): SecurityPolicy property tests (merge + clamp)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.11 — Coverage CI script

**Files:**
- Create: `tools/check-coverage.sh`
- Modify: `.github/workflows/ci.yml` (if exists) or document the manual gate in `docs/security/threat-model-relay.md` (when written in PR8)

- [ ] **Step 1: Add the coverage check tool**

```bash
#!/usr/bin/env bash
# tools/check-coverage.sh
# Parses xccov JSON and fails if any crypto-layer file is below threshold.

set -euo pipefail

REPORT=$1
THRESHOLD=95

# Files to enforce at 95%:
TARGETS=(
  "PreKeyStore.swift"
  "X3DH.swift"
  "DoubleRatchet.swift"
)

# Files to enforce at 100%:
TARGETS_100=(
  "SecurityPolicy.swift"
  "SecurityPolicyStore.swift"
)

fail=0
for f in "${TARGETS[@]}"; do
  pct=$(jq -r ".targets[].files[] | select(.path | endswith(\"$f\")) | .lineCoverage" "$REPORT" | head -n1)
  pct_int=$(python3 -c "print(int(float('$pct')*100))")
  echo "$f: ${pct_int}%"
  if [ "$pct_int" -lt $THRESHOLD ]; then
    echo "❌ $f below ${THRESHOLD}%"; fail=1
  fi
done
for f in "${TARGETS_100[@]}"; do
  pct=$(jq -r ".targets[].files[] | select(.path | endswith(\"$f\")) | .lineCoverage" "$REPORT" | head -n1)
  pct_int=$(python3 -c "print(int(float('$pct')*100))")
  echo "$f: ${pct_int}%"
  if [ "$pct_int" -lt 100 ]; then
    echo "❌ $f below 100%"; fail=1
  fi
done

exit $fail
```

- [ ] **Step 2: chmod + smoke test**

```
chmod +x tools/check-coverage.sh
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -enableCodeCoverage YES -resultBundlePath /tmp/peerdrop.xcresult
xcrun xccov view --report --json /tmp/peerdrop.xcresult > /tmp/cov.json
tools/check-coverage.sh /tmp/cov.json
```

Expected: some files may currently fail (PreKeyStore/X3DH/DoubleRatchet) — that's the baseline. Document the current % in the commit message; PR3–PR7 will raise them.

- [ ] **Step 3: Commit**

```bash
git add tools/check-coverage.sh
git commit -m "test(coverage): add 95/100 coverage gate script

Baseline before PR3+: PreKeyStore N%, X3DH N%, DoubleRatchet N%.
Target after PR7: all ≥ 95%, SecurityPolicy files = 100%.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.12 — PR2 wrap-up: open PR

- [ ] **Step 1: Push + open PR**

```
git push -u origin feat/v5.4-crypto-testkit
gh pr create --base main --title "feat(test): v5.4 PR2 — CryptoTestKit" --body "$(cat <<'EOF'
## Summary
- Adds CryptoTestKit module (PropertyTest harness, DeterministicCrypto, TestVectorLoader, FuzzHarness)
- 65 frozen test vectors (20 X3DH, 30 ratchet, 10 skipped-key, 5 policy)
- SecurityPolicy property tests (merge + clamp invariants)
- Coverage gate script

## Test plan
- [ ] All vector tests pass
- [ ] PropertyTest harness self-tests pass
- [ ] FuzzHarness mutation tests pass
- [ ] Coverage gate runs (may report current files below threshold — baseline)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

# PR3 — C3 + C4 (Local hardening)

**Branch:** `feat/v5.4-c3-c4-local-hardening`

**Goal:** Add TTL + LRU to `skippedKeys` (C3) and prune to `consumedOneTimePreKeyIds` (C4) — both purely local, no wire impact. Backward-compatible deserialization of old session/keystore files.

---

### Task 3.1 — `SkippedKeyEntry` value type

**Files:**
- Modify: `PeerDrop/Security/Protocol/DoubleRatchet.swift`
- Test: `PeerDropTests/DoubleRatchetSkippedKeysTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class DoubleRatchetSkippedKeysTests: XCTestCase {
    func test_skippedKeyEntry_serializes_with_timestamp() throws {
        let entry = DoubleRatchetSession.SkippedKeyEntry(
            key: SymmetricKey(size: .bits256),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DoubleRatchetSession.SkippedKeyEntry.self, from: data)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Add `SkippedKeyEntry` to DoubleRatchet**

In `DoubleRatchet.swift`:

```swift
public struct SkippedKeyEntry: Codable {
    public let key: SymmetricKey
    public let createdAt: Date

    public init(key: SymmetricKey, createdAt: Date) {
        self.key = key
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let keyData = try c.decode(Data.self, forKey: .key)
        self.key = SymmetricKey(data: keyData)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // ^ Backward compat: old session files have no createdAt → use now.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key.withUnsafeBytes { Data($0) }, forKey: .key)
        try c.encode(createdAt, forKey: .createdAt)
    }

    enum CodingKeys: String, CodingKey { case key, createdAt }
}
```

- [ ] **Step 4: Test PASS, commit**

```bash
git checkout -b feat/v5.4-c3-c4-local-hardening
git add PeerDrop/Security/Protocol/DoubleRatchet.swift PeerDropTests/DoubleRatchetSkippedKeysTests.swift project.yml
git commit -m "feat(c3): SkippedKeyEntry value type with timestamp

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.2 — Migrate `skippedKeys` dictionary value type

**Files:**
- Modify: `PeerDrop/Security/Protocol/DoubleRatchet.swift`
- Modify: `PeerDropTests/DoubleRatchetSkippedKeysTests.swift`

- [ ] **Step 1: Write a deserialize-old-format test**

```swift
func test_legacy_session_deserialize_fills_createdAt() throws {
    // Old format: skippedKeys is [String: SymmetricKey] (key Data base64)
    let legacyJSON = """
    {
      "myRatchetKey": "...",
      ...
      "skippedKeys": {
        "AAAA": "ABCDEFG..."
      }
    }
    """
    // (Use a real legacy fixture committed under TestVectors/legacy-sessions/)
    let session = try JSONDecoder().decode(DoubleRatchetSession.self, from: legacyJSON.data(using: .utf8)!)
    // The single skipped key should be retained, with createdAt set near now.
    XCTAssertEqual(session.skippedKeys.count, 1)
    if let entry = session.skippedKeys.first?.value {
        XCTAssertLessThan(abs(entry.createdAt.timeIntervalSinceNow), 5.0)
    }
}
```

(Create a real legacy fixture by dumping the current `DoubleRatchetSession` encoding before this PR; commit it under `PeerDropTests/CryptoTestKit/TestVectors/legacy-sessions/session-pre-v5.4.json`.)

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Change the type + custom decoder**

In `DoubleRatchetSession`:

```swift
public var skippedKeys: [SkippedKeyIndex: SkippedKeyEntry] = [:]

// In init(from decoder:) for DoubleRatchetSession, handle both old + new shapes:
//   Try decode skippedKeys as [SkippedKeyIndex: SkippedKeyEntry]
//   Fallback: decode as [SkippedKeyIndex: Data] (legacy) and wrap each
//             into SkippedKeyEntry(key:, createdAt: Date())
```

- [ ] **Step 4: Update all callers**

```
grep -rn "skippedKeys\[" PeerDrop/Security/Protocol/DoubleRatchet.swift
```

Each access of `skippedKeys[idx]` now gives `SkippedKeyEntry?` instead of `SymmetricKey?`. Update callers to use `.key`.

- [ ] **Step 5: Test PASS, commit**

```bash
git add PeerDrop/Security/Protocol/DoubleRatchet.swift PeerDropTests/DoubleRatchetSkippedKeysTests.swift PeerDropTests/CryptoTestKit/TestVectors/legacy-sessions/session-pre-v5.4.json
git commit -m "feat(c3): migrate skippedKeys to SkippedKeyEntry with backward-compat decode

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.3 — TTL eviction pass in `DoubleRatchetSession.decrypt`

**Files:**
- Modify: `PeerDrop/Security/Protocol/DoubleRatchet.swift`
- Modify: `PeerDropTests/DoubleRatchetSkippedKeysTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func test_TTLEviction_removesExpiredEntries() {
    var session = makeTestSession()
    let oldKey = SymmetricKey(size: .bits256)
    let oldIdx = DoubleRatchetSession.SkippedKeyIndex(ratchetKey: Data([0x01]), counter: 0)
    session.skippedKeys[oldIdx] = .init(key: oldKey, createdAt: Date(timeIntervalSinceNow: -86400 * 31))
    let policy = SecurityPolicy.bundledDefault  // skippedKeyTTLDays = 30

    session.evictExpiredSkippedKeys(now: Date(), policy: policy)
    XCTAssertNil(session.skippedKeys[oldIdx])
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Add the eviction method**

```swift
extension DoubleRatchetSession {
    public mutating func evictExpiredSkippedKeys(now: Date, policy: SecurityPolicy) {
        let cutoff = now.addingTimeInterval(-Double(policy.skippedKeyTTLDays) * 86400)
        let beforeCount = skippedKeys.count
        skippedKeys = skippedKeys.filter { $0.value.createdAt >= cutoff }
        let evicted = beforeCount - skippedKeys.count
        if evicted > 0 {
            // metric will be wired in Task 3.5 via the caller
        }
    }
}
```

- [ ] **Step 4: Test PASS**

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Security/Protocol/DoubleRatchet.swift PeerDropTests/DoubleRatchetSkippedKeysTests.swift
git commit -m "feat(c3): TTL eviction for skipped keys

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.4 — LRU eviction pass

**Files:**
- Modify: `PeerDrop/Security/Protocol/DoubleRatchet.swift`
- Modify: `PeerDropTests/DoubleRatchetSkippedKeysTests.swift`

- [ ] **Step 1: Test**

```swift
func test_LRUEviction_keepsNewestNCap() {
    var session = makeTestSession()
    let now = Date()
    for i in 0..<250 {
        let idx = DoubleRatchetSession.SkippedKeyIndex(ratchetKey: Data([UInt8(i & 0xFF)]), counter: UInt32(i))
        session.skippedKeys[idx] = .init(
            key: SymmetricKey(size: .bits256),
            createdAt: now.addingTimeInterval(-Double(i))
        )
    }
    let policy = SecurityPolicy.bundledDefault  // skippedKeyMaxCount = 200
    session.evictLRUSkippedKeys(policy: policy)
    XCTAssertEqual(session.skippedKeys.count, 200)
}
```

- [ ] **Step 2: Verify failure**

- [ ] **Step 3: Implement**

```swift
extension DoubleRatchetSession {
    public mutating func evictLRUSkippedKeys(policy: SecurityPolicy) {
        guard skippedKeys.count > policy.skippedKeyMaxCount else { return }
        let sorted = skippedKeys.sorted { $0.value.createdAt > $1.value.createdAt }
        let kept = sorted.prefix(policy.skippedKeyMaxCount)
        skippedKeys = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
```

- [ ] **Step 4: Test PASS, commit**

```bash
git commit -am "feat(c3): LRU eviction for skipped keys" --signoff
```

---

### Task 3.5 — Wire C3 eviction into the decrypt path + metrics

**Files:**
- Modify: `PeerDrop/Security/Protocol/DoubleRatchet.swift`
- Modify: `PeerDrop/Security/Protocol/RemoteSessionManager.swift`

- [ ] **Step 1: Read current `decrypt()` flow**

```
grep -n "func decrypt" PeerDrop/Security/Protocol/DoubleRatchet.swift
```

- [ ] **Step 2: Add eviction call at the top of decrypt**

```swift
public mutating func decrypt(
    _ ratchetMessage: RatchetMessage,
    policy: SecurityPolicy,
    metrics: CryptoHardeningMetrics? = nil
) throws -> Data {
    // 1. Run eviction passes first (cheap; bounded by skippedKeyMaxCount).
    let before = skippedKeys.count
    evictExpiredSkippedKeys(now: Date(), policy: policy)
    let afterTTL = skippedKeys.count
    if before > afterTTL { metrics?.record(.c3SkippedKeyEvictedTTL) }
    evictLRUSkippedKeys(policy: policy)
    if afterTTL > skippedKeys.count { metrics?.record(.c3SkippedKeyEvictedLRU) }

    // 2. Existing decrypt logic (unchanged below this comment).
    ...
}
```

Update the signature of all callers in `RemoteSessionManager.swift` to pass `policy` and `metrics`.

- [ ] **Step 3: Add hit/miss metrics**

Inside the existing skipped-key lookup branch:

```swift
if let entry = skippedKeys[idx] {
    metrics?.record(.c3SkippedKeyHit)
    skippedKeys.removeValue(forKey: idx)
    return try decryptWithMessageKey(entry.key, ciphertext: ratchetMessage.ciphertext)
} else {
    metrics?.record(.c3SkippedKeyMiss)
    // ... continue to symmetric/DH ratchet
}
```

- [ ] **Step 4: Build + run all DoubleRatchet tests**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(c3): wire skipped-key eviction + metrics into decrypt path"
```

---

### Task 3.6 — C3 property test

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Tests/Properties/RatchetProperties.swift`

```swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class RatchetProperties: XCTestCase {
    func test_property_skippedKeys_neverExceedMaxCount() {
        PropertyTest.forAll(trials: 100, seed: 31) { rng in
            var session = self.freshSession(seed: rng.next())
            let policy = SecurityPolicy.bundledDefault
            for i in 0..<500 {
                let idx = DoubleRatchetSession.SkippedKeyIndex(
                    ratchetKey: Data([UInt8(rng.next() & 0xFF)]), counter: UInt32(i)
                )
                session.skippedKeys[idx] = .init(
                    key: SymmetricKey(size: .bits256),
                    createdAt: Date()
                )
                session.evictLRUSkippedKeys(policy: policy)
            }
            return session.skippedKeys.count <= policy.skippedKeyMaxCount
        }
    }

    func test_property_expiredSkippedKeys_alwaysEvicted() {
        PropertyTest.forAll(trials: 50, seed: 32) { rng in
            var session = self.freshSession(seed: rng.next())
            let policy = SecurityPolicy.bundledDefault
            let stale = Date(timeIntervalSinceNow: -Double(policy.skippedKeyTTLDays + 1) * 86400)
            let idx = DoubleRatchetSession.SkippedKeyIndex(ratchetKey: Data([0x42]), counter: 0)
            session.skippedKeys[idx] = .init(key: SymmetricKey(size: .bits256), createdAt: stale)
            session.evictExpiredSkippedKeys(now: Date(), policy: policy)
            return session.skippedKeys[idx] == nil
        }
    }

    private func freshSession(seed: UInt64) -> DoubleRatchetSession {
        let ikSeed = Data((0..<32).map { _ in UInt8(seed & 0xFF) })
        // (Construct via DeterministicCrypto / existing test helpers)
        // ... abridged: build a minimal DoubleRatchetSession for the test
        return DoubleRatchetSession.makeTestSession()  // helper added in Task 3.1
    }
}
```

- [ ] **Step 1-5: TDD as before — test, fail, impl helper, pass, commit**

Commit: `test(c3): property tests for skipped-key eviction invariants`

---

### Task 3.7 — `PreKeyStore` consumedOPK type migration

**Files:**
- Modify: `PeerDrop/Security/Protocol/PreKeyStore.swift`
- Test: `PeerDropTests/PreKeyStoreConsumedOPKTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import PeerDrop

final class PreKeyStoreConsumedOPKTests: XCTestCase {

    func test_consumedOPK_stores_with_timestamp() async throws {
        let store = try PreKeyStore(storageKey: "test-\(UUID())")
        _ = try await store.consumeOneTimePreKey(id: 42)
        let snapshot = store.snapshotForTesting()
        XCTAssertNotNil(snapshot.consumedOneTimePreKeyIds[42])
        XCTAssertLessThan(abs(snapshot.consumedOneTimePreKeyIds[42]!.timeIntervalSinceNow), 5.0)
    }

    func test_legacy_consumed_set_deserializes() throws {
        // legacy = "consumedOneTimePreKeyIds": [1, 2, 3]
        let legacyJSON = """
        { "currentSignedPreKey": {...}, "consumedOneTimePreKeyIds": [1, 2, 3], "oneTimePreKeys": {} }
        """
        let state = try JSONDecoder().decode(PreKeyStore.PersistedState.self,
                                              from: legacyJSON.data(using: .utf8)!)
        XCTAssertEqual(state.consumedOneTimePreKeyIds.count, 3)
        // All three should have createdAt near now (backward-compat injection)
        for (_, date) in state.consumedOneTimePreKeyIds {
            XCTAssertLessThan(abs(date.timeIntervalSinceNow), 5.0)
        }
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Migrate the type**

In `PreKeyStore.swift`, change `PersistedState.consumedOneTimePreKeyIds: Set<UInt32>` to `[UInt32: Date]`. Add a custom decoder fallback:

```swift
extension PreKeyStore.PersistedState {
    enum CodingKeys: String, CodingKey {
        case currentSignedPreKey, previousSignedPreKeys, oneTimePreKeys
        case consumedOneTimePreKeyIds, nextOneTimePreKeyId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.currentSignedPreKey = try c.decode(SignedPreKey.self, forKey: .currentSignedPreKey)
        self.previousSignedPreKeys = try c.decodeIfPresent([SignedPreKey].self, forKey: .previousSignedPreKeys) ?? []
        self.oneTimePreKeys = try c.decode([UInt32: OneTimePreKey].self, forKey: .oneTimePreKeys)
        self.nextOneTimePreKeyId = try c.decode(UInt32.self, forKey: .nextOneTimePreKeyId)

        // Backward compat: old format was Set<UInt32>; new is [UInt32: Date].
        if let asDict = try? c.decode([UInt32: Date].self, forKey: .consumedOneTimePreKeyIds) {
            self.consumedOneTimePreKeyIds = asDict
        } else if let asSet = try? c.decode(Set<UInt32>.self, forKey: .consumedOneTimePreKeyIds) {
            let now = Date()
            self.consumedOneTimePreKeyIds = Dictionary(uniqueKeysWithValues: asSet.map { ($0, now) })
        } else {
            self.consumedOneTimePreKeyIds = [:]
        }
    }
}
```

Update all access points:
- `consumedOneTimePreKeyIds.insert(id)` → `consumedOneTimePreKeyIds[id] = Date()`
- `consumedOneTimePreKeyIds.contains(id)` → `consumedOneTimePreKeyIds[id] != nil`
- Any iteration over `consumedOneTimePreKeyIds` → iterate `.keys`

- [ ] **Step 4: Test PASS, commit**

```bash
git add PeerDrop/Security/Protocol/PreKeyStore.swift PeerDropTests/PreKeyStoreConsumedOPKTests.swift
git commit -m "feat(c4): migrate consumedOneTimePreKeyIds to [UInt32: Date]"
```

---

### Task 3.8 — C4 prune logic + metrics

**Files:**
- Modify: `PeerDrop/Security/Protocol/PreKeyStore.swift`
- Modify: `PeerDropTests/PreKeyStoreConsumedOPKTests.swift`

- [ ] **Step 1: Test**

```swift
func test_prune_removes_expired_entries() {
    var state = PreKeyStore.PersistedState.empty()
    let now = Date()
    state.consumedOneTimePreKeyIds[1] = now.addingTimeInterval(-86400 * 100) // 100d old
    state.consumedOneTimePreKeyIds[2] = now.addingTimeInterval(-86400 * 30)  // 30d
    state.consumedOneTimePreKeyIds[3] = now                                   // fresh

    let policy = SecurityPolicy.bundledDefault  // pruneWindow = 90

    let pruned = PreKeyStore.pruneConsumedOPK(in: &state, now: now, policy: policy)
    XCTAssertEqual(pruned, 1)
    XCTAssertNil(state.consumedOneTimePreKeyIds[1])
    XCTAssertNotNil(state.consumedOneTimePreKeyIds[2])
    XCTAssertNotNil(state.consumedOneTimePreKeyIds[3])
}
```

- [ ] **Step 2: Verify failure**

- [ ] **Step 3: Implement**

```swift
extension PreKeyStore {
    @discardableResult
    public static func pruneConsumedOPK(
        in state: inout PersistedState,
        now: Date,
        policy: SecurityPolicy
    ) -> Int {
        let cutoff = now.addingTimeInterval(-Double(policy.consumedOPKPruneWindowDays) * 86400)
        let before = state.consumedOneTimePreKeyIds.count
        state.consumedOneTimePreKeyIds = state.consumedOneTimePreKeyIds.filter { $0.value >= cutoff }
        return before - state.consumedOneTimePreKeyIds.count
    }
}
```

- [ ] **Step 4: Call from `saveSync`**

In `PreKeyStore.saveSync()`:

```swift
let pruned = Self.pruneConsumedOPK(in: &state, now: Date(), policy: policy ?? .bundledDefault)
if pruned > 0 { metrics?.record(.c4ConsumedOpkPruned) }
metrics?.record(.c4ConsumedOpkSize)
```

Add `policy` and `metrics` properties to `PreKeyStore` (init parameters with default values for back-compat).

- [ ] **Step 5: Test PASS, commit**

---

### Task 3.9 — C4 property test (prune invariant + safety margin)

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Tests/Properties/PreKeyStoreProperties.swift`

```swift
final class PreKeyStoreProperties: XCTestCase {
    func test_property_pruned_entries_are_always_expired() {
        PropertyTest.forAll(trials: 100, seed: 41) { rng in
            var state = PreKeyStore.PersistedState.empty()
            let now = Date()
            let policy = SecurityPolicy.bundledDefault
            // Seed with random consumedOPK ages
            for i in 0..<200 {
                let ageDays = Int(rng.next() % 200)
                state.consumedOneTimePreKeyIds[UInt32(i)] = now.addingTimeInterval(-Double(ageDays) * 86400)
            }
            _ = PreKeyStore.pruneConsumedOPK(in: &state, now: now, policy: policy)
            let cutoff = now.addingTimeInterval(-Double(policy.consumedOPKPruneWindowDays) * 86400)
            return state.consumedOneTimePreKeyIds.allSatisfy { $0.value >= cutoff }
        }
    }

    func test_property_pruneWindow_always_geq_spkMaxAge_x4() {
        PropertyTest.forAll(trials: 1, seed: 42) { _ in
            do {
                try SecurityPolicy.bundledDefault.validateInvariants()
                return true
            } catch {
                return false
            }
        }
    }
}
```

Commit: `test(c4): property tests for prune invariants`

---

### Task 3.10 — PR3 wrap-up

- [ ] Full test run + coverage check:

```
xcodebuild test -scheme PeerDrop ... -enableCodeCoverage YES
xcrun xccov view --report --json /tmp/peerdrop.xcresult > /tmp/cov.json
tools/check-coverage.sh /tmp/cov.json
```

Expected: `DoubleRatchet.swift` and `PreKeyStore.swift` now at ≥ 90%, on track for the 95% target.

- [ ] Push + open PR:

```
git push -u origin feat/v5.4-c3-c4-local-hardening
gh pr create --base main --title "feat(security): v5.4 PR3 — C3 + C4 local hardening" --body "..."
```

---

# PR4 — Worker policy endpoint + client fetch

**Branch:** `feat/v5.4-worker-policy-endpoint`

**Goal:** Add `/v2/config/crypto-policy` worker route serving a pre-signed JSON blob, the `tools/sign-crypto-policy.swift` offline signer, and the client-side fetch + signature verification path. After this PR, the policy plumbing is end-to-end functional, even though no consumer yet enforces C1/C2.

---

### Task 4.1 — Define `SignedCryptoPolicy` types (client + worker)

**Files (Swift):**
- Create: `PeerDrop/Security/SignedCryptoPolicy.swift`
- Test: `PeerDropTests/SignedCryptoPolicyTests.swift`

**Files (TypeScript):**
- Create: `cloudflare-worker/src/cryptoPolicy.ts`

- [ ] **Step 1: Swift struct**

```swift
import Foundation

public struct SignedCryptoPolicy: Codable {
    public let schemaVersion: Int
    public let issuedAt: UInt64
    public let expiresAt: UInt64
    public let policy: SecurityPolicy
    public let signature: String   // base64 Ed25519 over canonical JSON of (schemaVersion+issuedAt+expiresAt+policy)
}
```

- [ ] **Step 2: TypeScript schema (mirror)**

```typescript
export interface SignedCryptoPolicy {
  schemaVersion: number;
  issuedAt: number;
  expiresAt: number;
  policy: SecurityPolicyShape;
  signature: string;
}

export interface SecurityPolicyShape {
  spkMaxAgeDays: number;
  spkExpirationBehavior: "warn" | "reject";
  opkExhaustionBehavior: { legacy: "proceedWithoutDH4" | "failClosed"; strict: "proceedWithoutDH4" | "failClosed" };
  opkRetryMaxAttempts: number;
  opkRetryIntervalSeconds: number;
  skippedKeyTTLDays: number;
  skippedKeyMaxCount: number;
  consumedOPKPruneWindowDays: number;
}
```

- [ ] **Step 3: Codable round-trip test**

```swift
func test_signedPolicy_roundTrips() throws {
    let blob = SignedCryptoPolicy(
        schemaVersion: 1,
        issuedAt: 1748000000,
        expiresAt: 1750592000,
        policy: .bundledDefault,
        signature: "AAA="
    )
    let encoded = try JSONEncoder().encode(blob)
    let decoded = try JSONDecoder().decode(SignedCryptoPolicy.self, from: encoded)
    XCTAssertEqual(decoded.policy, .bundledDefault)
}
```

- [ ] **Step 4: Test PASS, commit**

---

### Task 4.2 — Canonical JSON serializer (RFC 8785 subset)

**Files:**
- Create: `PeerDrop/Security/CanonicalJSON.swift`
- Test: `PeerDropTests/CanonicalJSONTests.swift`

- [ ] **Step 1: Failing test**

```swift
func test_canonicalize_sortsKeys() throws {
    let json = ["b": 2, "a": 1, "c": 3]
    let canonical = try CanonicalJSON.serialize(json)
    XCTAssertEqual(String(data: canonical, encoding: .utf8), "{\"a\":1,\"b\":2,\"c\":3}")
}
```

- [ ] **Step 2: Implement**

```swift
public enum CanonicalJSON {
    public enum Error: Swift.Error { case unsupportedType }

    public static func serialize(_ value: Any) throws -> Data {
        // RFC 8785-ish: sort keys recursively, no whitespace.
        // Worker side uses an npm canonical-json library; this is the
        // Swift mirror. Both sides MUST agree byte-for-byte on the same input.
        let normalized = try canonicalize(value)
        return try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
    }

    private static func canonicalize(_ v: Any) throws -> Any {
        switch v {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, sub) in dict { out[k] = try canonicalize(sub) }
            return out
        case let arr as [Any]:
            return try arr.map { try canonicalize($0) }
        case is Int, is Double, is String, is Bool: return v
        case is NSNull: return v
        default: throw Error.unsupportedType
        }
    }
}
```

- [ ] **Step 3: Test PASS, commit**

(For worker side, install `json-canonicalize` npm package or implement a small TS equivalent; document in `docs/security/crypto-policy-format.md`.)

---

### Task 4.3 — Signature verification

**Files:**
- Modify: `PeerDrop/Security/SecurityPolicyStore.swift`
- Test: `PeerDropTests/SecurityPolicyStoreTests.swift`

- [ ] **Step 1: Failing test using a known-good fixture**

```swift
func test_parseSignedPolicy_acceptsValidSignature() throws {
    // valid.json was generated by tools/sign-crypto-policy.swift using
    // the test-only signing key, also committed under TestVectors/policy/
    let url = Bundle(for: type(of: self)).url(forResource: "valid", withExtension: "json", subdirectory: "policy")!
    let blob = try Data(contentsOf: url)
    let testPubKey = Data(base64Encoded: "<test-pubkey>")!
    let result = try SecurityPolicyStore.parseSignedPolicy(blob, publicKeys: [testPubKey])
    XCTAssertEqual(result.policy.spkMaxAgeDays, 21)
}

func test_parseSignedPolicy_rejectsBadSignature() throws {
    let url = Bundle(for: type(of: self)).url(forResource: "tampered-sig", withExtension: "json", subdirectory: "policy")!
    let blob = try Data(contentsOf: url)
    let testPubKey = Data(base64Encoded: "<test-pubkey>")!
    XCTAssertThrowsError(try SecurityPolicyStore.parseSignedPolicy(blob, publicKeys: [testPubKey]))
}
```

- [ ] **Step 2: Implement**

```swift
extension SecurityPolicyStore {
    public enum ParseError: Error, Equatable {
        case malformedJSON
        case invalidSignature
        case unsupportedSchemaVersion(Int)
        case invariantViolation
    }

    public static func parseSignedPolicy(_ data: Data, publicKeys: [Data]) throws -> SignedCryptoPolicy {
        let decoded: SignedCryptoPolicy
        do { decoded = try JSONDecoder().decode(SignedCryptoPolicy.self, from: data) }
        catch { throw ParseError.malformedJSON }

        if decoded.schemaVersion != 1 {
            throw ParseError.unsupportedSchemaVersion(decoded.schemaVersion)
        }

        let canonical = try CanonicalJSON.serialize([
            "schemaVersion": decoded.schemaVersion,
            "issuedAt": decoded.issuedAt,
            "expiresAt": decoded.expiresAt,
            "policy": try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded.policy))
        ])
        guard let sigBytes = Data(base64Encoded: decoded.signature) else {
            throw ParseError.invalidSignature
        }
        var matched = false
        for pkBytes in publicKeys {
            if let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkBytes),
               pk.isValidSignature(sigBytes, for: canonical) {
                matched = true; break
            }
        }
        guard matched else { throw ParseError.invalidSignature }

        try decoded.policy.validateInvariants()
        return decoded
    }
}
```

- [ ] **Step 3: Test PASS, commit**

---

### Task 4.4 — `tools/sign-crypto-policy.swift` offline signer

**Files:**
- Create: `tools/sign-crypto-policy.swift`

- [ ] **Step 1: Implement**

```swift
#!/usr/bin/env swift
// Usage:
//   swift tools/sign-crypto-policy.swift <policy.json> <signing-key.json>
// Outputs the signed JSON to stdout.

import Foundation
import CryptoKit

guard CommandLine.arguments.count == 3 else {
    print("usage: sign-crypto-policy.swift <policy.json> <signing-key.json>")
    exit(1)
}
let policyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])

struct SigningKey: Codable { let privateKeyBase64: String }
let keyBlob = try JSONDecoder().decode(SigningKey.self, from: Data(contentsOf: keyURL))
let pk = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: keyBlob.privateKeyBase64)!)

let inputRaw = try Data(contentsOf: policyURL)
let policyOnly = try JSONSerialization.jsonObject(with: inputRaw) as! [String: Any]

// Canonical-JSON of {schemaVersion, issuedAt, expiresAt, policy}
let payload = try JSONSerialization.data(
    withJSONObject: [
        "schemaVersion": policyOnly["schemaVersion"]!,
        "issuedAt": policyOnly["issuedAt"]!,
        "expiresAt": policyOnly["expiresAt"]!,
        "policy": policyOnly["policy"]!
    ],
    options: [.sortedKeys]
)
let signature = try pk.signature(for: payload).base64EncodedString()

var output = policyOnly
output["signature"] = signature
let outputData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(outputData)
print()
```

- [ ] **Step 2: Generate the production keypair** (offline, store securely)

```
swift -e '
import Foundation; import CryptoKit
let k = Curve25519.Signing.PrivateKey()
print("private: " + k.rawRepresentation.base64EncodedString())
print("public:  " + k.publicKey.rawRepresentation.base64EncodedString())
'
```

Store the private key in 1Password or similar. Update `PeerDrop/App/Info.plist` `CryptoPolicyPublicKeys` with the public key.

- [ ] **Step 3: Sign the bundled default and commit**

Create `cloudflare-worker/bundled-default-policy.json` (unsigned source), sign it:

```
swift tools/sign-crypto-policy.swift \
    cloudflare-worker/bundled-default-policy.json \
    <local-signing-key.json> \
  > cloudflare-worker/bundled-default-policy.signed.json
```

Commit only `bundled-default-policy.signed.json` (the unsigned source can also be committed, but the signed one is authoritative).

- [ ] **Step 4: Commit**

```bash
git add tools/sign-crypto-policy.swift cloudflare-worker/bundled-default-policy.* PeerDrop/App/Info.plist
git commit -m "feat(security): policy signing tool + production public keys"
```

---

### Task 4.5 — Worker `/v2/config/crypto-policy` route

**Files:**
- Modify: `cloudflare-worker/src/index.ts`
- Modify: `cloudflare-worker/src/cryptoPolicy.ts`
- Create: `cloudflare-worker/src/__tests__/cryptoPolicy.test.ts`

- [ ] **Step 1: Add the route handler**

In `cryptoPolicy.ts`:

```typescript
export async function handleCryptoPolicy(env: Env): Promise<Response> {
  const body = env.CRYPTO_POLICY_JSON ?? BUNDLED_DEFAULT_POLICY_JSON;
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=3600, s-maxage=86400",
      "Access-Control-Allow-Origin": "*"
    }
  });
}
```

(`BUNDLED_DEFAULT_POLICY_JSON` is imported from the committed `bundled-default-policy.signed.json` — bundle into the worker via a build-time inline.)

In `index.ts`, add:

```typescript
if (url.pathname === "/v2/config/crypto-policy" && request.method === "GET") {
  const { handleCryptoPolicy } = await import("./cryptoPolicy");
  return handleCryptoPolicy(env);
}
```

- [ ] **Step 2: Worker test**

```typescript
import { describe, it, expect } from "vitest";
import worker from "../index";

describe("/v2/config/crypto-policy", () => {
  it("returns 200 with bundled default when env var unset", async () => {
    const res = await worker.fetch(
      new Request("https://example.com/v2/config/crypto-policy"),
      { CRYPTO_POLICY_JSON: undefined } as any,
      {} as any
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.schemaVersion).toBe(1);
    expect(body.signature).toBeDefined();
  });
});
```

- [ ] **Step 3: Deploy to staging**

```
cd cloudflare-worker
npm test
npx wrangler deploy --env staging
curl https://peerdrop-signal-staging.hanfourhuang.workers.dev/v2/config/crypto-policy | jq .
```

- [ ] **Step 4: Commit**

```bash
git add cloudflare-worker/src/cryptoPolicy.ts cloudflare-worker/src/index.ts cloudflare-worker/src/__tests__/cryptoPolicy.test.ts
git commit -m "feat(worker): /v2/config/crypto-policy endpoint"
```

---

### Task 4.6 — `SecurityPolicyStore` async fetch + cache

**Files:**
- Modify: `PeerDrop/Security/SecurityPolicyStore.swift`
- Modify: `PeerDropTests/SecurityPolicyStoreTests.swift`

- [ ] **Step 1: Add async fetch test using URLProtocol mock**

```swift
func test_fetch_updatesCurrent_onValidResponse() async throws {
    URLProtocol.registerClass(MockURLProtocol.self)
    defer { URLProtocol.unregisterClass(MockURLProtocol.self) }
    MockURLProtocol.responseData = try Data(contentsOf: validFixtureURL)

    let store = SecurityPolicyStore(
        storageDirectory: tmpDir,
        publicKeys: [testPubKey],
        baseURL: URL(string: "https://example.com")!
    )
    await store.fetchAndUpdate()
    XCTAssertEqual(store.current.spkMaxAgeDays, 14, "fixture has spkMaxAgeDays=14")
}
```

(Define `MockURLProtocol` as a thin shim in `PeerDropTests/Helpers/`.)

- [ ] **Step 2: Implement fetch flow**

```swift
public extension SecurityPolicyStore {
    func fetchAndUpdate() async {
        guard let url = baseURL?.appendingPathComponent("v2/config/crypto-policy") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                metrics?.record(.policyFetchFailure)
                return
            }
            let parsed = try Self.parseSignedPolicy(data, publicKeys: publicKeys)
            let clamped = SecurityPolicyBounds.clamp(parsed.policy)
            if !SecurityPolicyBounds.violations(parsed.policy).isEmpty {
                metrics?.record(.policyValueOutOfBounds)
            }
            let merged = SecurityPolicy.merged(local: .bundledDefault, remote: clamped)
            try await saveToCache(parsed)
            await MainActor.run { self.current = merged }
            metrics?.record(.policyFetchSuccess)
        } catch SecurityPolicyStore.ParseError.invalidSignature {
            metrics?.record(.policySignatureInvalid)
        } catch SecurityPolicyStore.ParseError.unsupportedSchemaVersion {
            metrics?.record(.policyVersionUnsupported)
        } catch {
            metrics?.record(.policyFetchFailure)
        }
    }

    private func saveToCache(_ blob: SignedCryptoPolicy) async throws {
        let cacheURL = storageDirectory.appendingPathComponent("crypto-policy.json")
        let data = try JSONEncoder().encode(blob)
        try data.write(to: cacheURL, options: .atomic)
    }
}
```

- [ ] **Step 3: Add boot-time cache read (replace PR1 placeholder)**

In `loadFromCacheOrBundled`:

```swift
let cacheURL = directory.appendingPathComponent("crypto-policy.json")
if let cached = try? Data(contentsOf: cacheURL),
   let parsed = try? parseSignedPolicy(cached, publicKeys: publicKeys) {
    let clamped = SecurityPolicyBounds.clamp(parsed.policy)
    metrics?.record(.policyCacheHit)
    if parsed.expiresAt < UInt64(Date().timeIntervalSince1970) {
        metrics?.record(.policyExpiredInUse)
    }
    return SecurityPolicy.merged(local: .bundledDefault, remote: clamped)
}
return .bundledDefault
```

- [ ] **Step 4: Schedule periodic refresh** (24h)

In `SecurityPolicyStore.init`, after the sync load, spawn a Task that calls `fetchAndUpdate()` immediately and then every 24h.

- [ ] **Step 5: Test PASS, commit**

```bash
git add PeerDrop/Security/SecurityPolicyStore.swift \
        PeerDropTests/SecurityPolicyStoreTests.swift \
        PeerDropTests/Helpers/MockURLProtocol.swift
git commit -m "feat(security): SecurityPolicyStore async fetch + cache"
```

---

### Task 4.7 — Policy fuzz harness

**Files:**
- Create: `PeerDropTests/CryptoTestKit/Tests/Fuzz/PolicyFuzzTests.swift`

```swift
import XCTest
@testable import PeerDrop

final class PolicyFuzzTests: XCTestCase {
    func test_fuzz_parseSignedPolicy_neverCrashes() {
        let validFixture = try! Data(contentsOf: validFixtureURL)
        FuzzHarness.run(
            target: validFixture,
            iterations: 10_000,
            seed: 0xDEADBEEF,
            operators: [.bitFlip, .byteInsert, .byteDelete, .truncate]
        ) { mutated in
            // Must never crash or throw an unexpected error.
            do {
                _ = try SecurityPolicyStore.parseSignedPolicy(mutated, publicKeys: [testPubKey])
            } catch SecurityPolicyStore.ParseError.malformedJSON,
                    SecurityPolicyStore.ParseError.invalidSignature,
                    SecurityPolicyStore.ParseError.unsupportedSchemaVersion,
                    SecurityPolicyStore.ParseError.invariantViolation {
                // expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
```

Commit: `test(cryptotestkit): policy parse fuzz harness (10K iterations)`

---

### Task 4.8 — PR4 wrap-up

Open PR. Run staging-side smoke test: install build with policy fetch enabled, observe `policy.fetch_success` metric ticking up.

---

# PR5 — C2 (OPK exhaustion fail-closed)

**Branch:** `feat/v5.4-c2-opk-fail-closed`

**Goal:** Make X3DH initiation refuse to proceed when responder has no OPK and peer is `.v5_4_plus` or `.unknown`; queue the send for retry; surface UI banner.

---

### Task 5.1 — `OutboundRetryQueue` skeleton

**Files:**
- Create: `PeerDrop/Transport/OutboundRetryQueue.swift`
- Test: `PeerDropTests/OutboundRetryQueueTests.swift`

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import PeerDrop

final class OutboundRetryQueueTests: XCTestCase {
    func test_enqueue_storesEntry() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let entry = OutboundRetryQueue.Entry(
            id: UUID(),
            recipientMailboxId: "mailbox-123",
            envelopeData: Data("hello".utf8),
            attemptCount: 0,
            firstAttemptAt: Date()
        )
        try await queue.enqueue(entry)
        let all = await queue.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.recipientMailboxId, "mailbox-123")
    }

    func test_enqueue_persistsAcrossReload() async throws {
        let url = tmpURL
        do {
            let queue = try await OutboundRetryQueue(storageURL: url)
            try await queue.enqueue(.testEntry())
        }
        let reloaded = try await OutboundRetryQueue(storageURL: url)
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 1)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public actor OutboundRetryQueue {
    public struct Entry: Codable, Identifiable {
        public let id: UUID
        public let recipientMailboxId: String
        public let envelopeData: Data
        public var attemptCount: Int
        public var firstAttemptAt: Date
    }

    private let storageURL: URL
    private let encryptor: ChatDataEncryptor   // reuse existing
    private var entries: [Entry] = []

    public init(storageURL: URL, encryptor: ChatDataEncryptor = .shared) async throws {
        self.storageURL = storageURL
        self.encryptor = encryptor
        try await load()
    }

    public func enqueue(_ entry: Entry) async throws {
        entries.append(entry)
        try await save()
    }

    public func remove(id: UUID) async throws {
        entries.removeAll { $0.id == id }
        try await save()
    }

    public func all() async -> [Entry] { entries }

    public func update(_ entry: Entry) async throws {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
            try await save()
        }
    }

    private func load() async throws {
        guard let blob = try? Data(contentsOf: storageURL) else {
            entries = []; return
        }
        let plaintext = try encryptor.decrypt(blob)
        entries = try JSONDecoder().decode([Entry].self, from: plaintext)
    }

    private func save() async throws {
        let plaintext = try JSONEncoder().encode(entries)
        let blob = try encryptor.encrypt(plaintext)
        try blob.write(to: storageURL, options: .atomic)
    }
}
```

- [ ] **Step 3: Test PASS, commit**

```bash
git checkout -b feat/v5.4-c2-opk-fail-closed
git add PeerDrop/Transport/OutboundRetryQueue.swift PeerDropTests/OutboundRetryQueueTests.swift project.yml
git commit -m "feat(c2): OutboundRetryQueue persistent storage"
```

---

### Task 5.2 — Hook into X3DH initiate failure path

**Files:**
- Modify: `PeerDrop/Security/Protocol/X3DH.swift`
- Modify: `PeerDrop/Core/ConnectionManager.swift`

- [ ] **Step 1: Add `OPKExhaustedError` to X3DH**

```swift
extension X3DH {
    public enum InitiationError: Error, Equatable {
        case opkExhausted   // bundle had no OPK and policy says failClosed
    }
}
```

- [ ] **Step 2: Modify initiate to consult policy**

```swift
public static func initiate(
    /* existing params */,
    theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?,
    peerProtocolVersion: ProtocolVersion,
    policy: SecurityPolicy,
    metrics: CryptoHardeningMetrics?
) throws -> KeyAgreementResult {
    if theirOneTimePreKey == nil {
        metrics?.record(.c2OpkMissing, peerVersion: peerProtocolVersion)
        let behavior = policy.opkExhaustionBehavior(peerProtocolVersion)
        if behavior == .failClosed {
            metrics?.record(.c2OpkFailedInitiation, peerVersion: peerProtocolVersion)
            throw InitiationError.opkExhausted
        }
    }
    // existing DH computation...
}
```

- [ ] **Step 3: ConnectionManager catches and enqueues**

In `ConnectionManager.sendRemoteMessage`:

```swift
do {
    try x3dhInitiate(...)
    // proceed to encrypt + send
} catch X3DH.InitiationError.opkExhausted {
    let entry = OutboundRetryQueue.Entry(
        id: UUID(),
        recipientMailboxId: peerMailboxId,
        envelopeData: pendingEnvelope,
        attemptCount: 0,
        firstAttemptAt: Date()
    )
    try await retryQueue.enqueue(entry)
    surfaceC2RetryBanner(attempts: 1, max: policy.opkRetryMaxAttempts)
}
```

- [ ] **Step 4: Tests** (mock `theirOneTimePreKey = nil`, assert enqueue happens)

- [ ] **Step 5: Commit**

---

### Task 5.3 — Retry tick (60s, max 5 attempts)

**Files:**
- Modify: `PeerDrop/Transport/OutboundRetryQueue.swift`
- Modify: `PeerDrop/Core/ConnectionManager.swift`

- [ ] **Step 1: Test**

```swift
func test_retryTick_invokesCallback_perEntry() async throws {
    let q = try await OutboundRetryQueue(storageURL: tmpURL)
    try await q.enqueue(.testEntry())
    try await q.enqueue(.testEntry())
    var attempted = 0
    await q.runRetryTick { _ in
        attempted += 1
        return .success
    }
    XCTAssertEqual(attempted, 2)
    let remaining = await q.all()
    XCTAssertEqual(remaining.count, 0)
}

func test_retryTick_handlesFailure_incrementsAttemptCount() async throws {
    let q = try await OutboundRetryQueue(storageURL: tmpURL)
    try await q.enqueue(.testEntry(attempts: 0))
    await q.runRetryTick { _ in .failure }
    let entry = await q.all().first
    XCTAssertEqual(entry?.attemptCount, 1)
}
```

- [ ] **Step 2: Implement**

```swift
public extension OutboundRetryQueue {
    enum RetryResult { case success, failure }

    func runRetryTick(handler: (Entry) async -> RetryResult) async {
        for entry in entries {
            let result = await handler(entry)
            switch result {
            case .success:
                try? await remove(id: entry.id)
            case .failure:
                var updated = entry
                updated.attemptCount += 1
                try? await update(updated)
            }
        }
    }
}
```

- [ ] **Step 3: Wire periodic tick in ConnectionManager**

```swift
private var retryTickTimer: Task<Void, Never>?

private func startRetryTickLoop(policy: SecurityPolicy) {
    retryTickTimer?.cancel()
    retryTickTimer = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(policy.opkRetryIntervalSeconds) * 1_000_000_000)
            await retryQueue.runRetryTick { entry in
                await self.attemptRetry(entry, policy: policy)
            }
        }
    }
}

private func attemptRetry(_ entry: OutboundRetryQueue.Entry, policy: SecurityPolicy) async -> OutboundRetryQueue.RetryResult {
    // Re-fetch peer bundle, try X3DH again.
    do {
        try await retrySendEnvelope(entry.envelopeData, mailboxId: entry.recipientMailboxId)
        cryptoMetrics?.record(.c2OpkRetrySucceeded)
        return .success
    } catch {
        if entry.attemptCount + 1 >= policy.opkRetryMaxAttempts {
            cryptoMetrics?.record(.c2OpkRetryExhausted)
            surfaceC2ExhaustedBanner(for: entry)
            try? await retryQueue.remove(id: entry.id)
            return .success  // remove from queue
        }
        return .failure
    }
}
```

- [ ] **Step 4: Tests + commit**

---

### Task 5.4 — `CryptoHardeningBanner` views (C2 retry + exhausted)

**Files:**
- Create: `PeerDrop/UI/Security/CryptoHardeningBanner.swift`
- Modify: `PeerDrop/App/Localizable.xcstrings`

- [ ] **Step 1: Add the 4 new i18n keys**

In `Localizable.xcstrings`:
- `c2.opk.retry.title` → zh-Hant: `對方暫時無法接收訊息`
- `c2.opk.retry.body` → zh-Hant: `重試中… (%@/%@)`
- `c2.opk.exhausted.title` → zh-Hant: `對方加密金鑰存量不足`
- `c2.opk.exhausted.body` → zh-Hant: `請對方開啟 app 補充`

Translate to en, zh-Hans, ja, ko (5 languages × 4 keys = 20 entries).

- [ ] **Step 2: Build the banner SwiftUI view**

```swift
import SwiftUI

public struct CryptoHardeningBanner: View {
    public enum Kind {
        case c2OPKRetry(attempts: Int, max: Int, onCancel: () -> Void)
        case c2OPKExhausted(onRetry: () -> Void)
        case c1SPKExpired(onRetry: () -> Void)
    }

    public let kind: Kind
    public var body: some View {
        // Reuses existing decryptFailureBanner styling (search for that
        // style helper in PeerDrop/UI/ and apply same modifiers).
        // ...
    }
}
```

- [ ] **Step 3: Unit-test the binding logic (no snapshot tests)**

```swift
final class CryptoHardeningBannerTests: XCTestCase {
    func test_c2Retry_titleAndBody_useLocalizedStrings() {
        let view = CryptoHardeningBanner(kind: .c2OPKRetry(attempts: 3, max: 5, onCancel: {}))
        let mirror = Mirror(reflecting: view.body)
        // Inspect for the LocalizedStringKey identifiers; verify both
        // `c2.opk.retry.title` and `c2.opk.retry.body` keys are referenced.
        // ...
    }
    func test_c2Cancel_button_callsHandler() {
        var cancelled = false
        let view = CryptoHardeningBanner(kind: .c2OPKRetry(attempts: 1, max: 5, onCancel: { cancelled = true }))
        view.invokeCancelForTesting()
        XCTAssertTrue(cancelled)
    }
}
```

Expose a `#if DEBUG`-gated `invokeCancelForTesting()` on the banner that calls the `onCancel` closure directly (avoids needing UI test infrastructure to verify the binding).

- [ ] **Step 4: Commit**

---

### Task 5.5 — C2 property tests

**Files:**
- Create or modify: `PeerDropTests/CryptoTestKit/Tests/Properties/X3DHProperties.swift`

```swift
final class X3DHProperties: XCTestCase {
    func test_property_legacyPeer_OPKNil_proceeds() {
        PropertyTest.forAll(trials: 50, seed: 51) { rng in
            // Random valid bundle missing OPK, peer = legacy.
            // Expect: initiate succeeds (DH4 skipped).
            // ...
            return true /* check no throw */
        }
    }
    func test_property_v5_4Peer_OPKNil_failsClosed() {
        PropertyTest.forAll(trials: 50, seed: 52) { rng in
            // Same setup, peer = v5_4_plus.
            // Expect: initiate throws .opkExhausted.
            return true /* check throws */
        }
    }
}
```

Commit: `test(c2): X3DH property tests for OPK exhaustion behavior`

---

### Task 5.6 — PR5 wrap-up + Open PR

---

# PR6 — C1 (SPK timestamp binding)

**Branch:** `feat/v5.4-c1-spk-timestamp`

**Goal:** Add `signedPreKeyTimestamp` + `signedPreKeyTimestampSignature` to `PreKeyBundle`; sign on responder side; verify on initiator side; reject malformed / invalid / too-old per policy.

---

### Task 6.1 — Extend `PreKeyBundle` with optional timestamp fields

**Files:**
- Modify: `PeerDrop/Security/Protocol/PreKeyBundle.swift`
- Test: `PeerDropTests/PreKeyBundleTimestampTests.swift`

- [ ] **Step 1: Failing test**

```swift
func test_legacy_bundle_decodes_without_timestamp() throws {
    let legacyJSON = #"{"identityKey":"AAA=","signedPreKey":{...},"oneTimePreKey":"BBB="}"#.data(using: .utf8)!
    let bundle = try JSONDecoder().decode(PreKeyBundle.self, from: legacyJSON)
    XCTAssertNil(bundle.signedPreKeyTimestamp)
    XCTAssertNil(bundle.signedPreKeyTimestampSignature)
}

func test_v5_4_bundle_decodes_with_timestamp() throws {
    let newJSON = #"{...,"signedPreKeyTimestamp":1748000000,"signedPreKeyTimestampSignature":"CCC="}"#.data(using: .utf8)!
    let bundle = try JSONDecoder().decode(PreKeyBundle.self, from: newJSON)
    XCTAssertEqual(bundle.signedPreKeyTimestamp, 1748000000)
    XCTAssertNotNil(bundle.signedPreKeyTimestampSignature)
}
```

- [ ] **Step 2: Implement**

In `PreKeyBundle.swift`:

```swift
public struct PreKeyBundle: Codable {
    /* existing fields */
    public let signedPreKeyTimestamp: UInt64?
    public let signedPreKeyTimestampSignature: Data?
}
```

- [ ] **Step 3: Test PASS, commit**

---

### Task 6.2 — Responder-side: sign the timestamp when emitting bundle

**Files:**
- Modify: `PeerDrop/Security/Protocol/PreKeyStore.swift`
- Modify: `PeerDropTests/PreKeyStoreTests.swift`

- [ ] **Step 1: Test**

```swift
func test_emittedBundle_hasValidTimestampSignature() async throws {
    let store = try PreKeyStore(...)
    let bundle = await store.currentPreKeyBundle()
    XCTAssertNotNil(bundle.signedPreKeyTimestamp)
    XCTAssertNotNil(bundle.signedPreKeyTimestampSignature)
    // Verify signature locally:
    let ik = await IdentityKeyManager.shared.publicSigningKey()
    let payload = bundle.signedPreKey.publicKey.rawRepresentation
                + uint64BE(bundle.signedPreKeyTimestamp!)
    XCTAssertTrue(ik.isValidSignature(bundle.signedPreKeyTimestampSignature!, for: payload))
}
```

- [ ] **Step 2: Implement**

In `PreKeyStore.currentPreKeyBundle()`:

```swift
let now = UInt64(Date().timeIntervalSince1970)
let timestampPayload = signedPreKey.publicKey.rawRepresentation + uint64BigEndian(now)
let timestampSig = try IdentityKeyManager.shared.sign(timestampPayload)
return PreKeyBundle(
    /* existing */,
    signedPreKeyTimestamp: now,
    signedPreKeyTimestampSignature: timestampSig
)
```

Helper:
```swift
func uint64BigEndian(_ value: UInt64) -> Data {
    var be = value.bigEndian
    return Data(bytes: &be, count: 8)
}
```

- [ ] **Step 3: Test PASS, commit**

---

### Task 6.3 — Initiator-side: verify timestamp signature + freshness

**Files:**
- Modify: `PeerDrop/Security/Protocol/X3DH.swift`
- Test: `PeerDropTests/X3DHTimestampTests.swift`

- [ ] **Step 1: Test all 5 cases from spec §4.1**

```swift
func test_legacy_bundle_proceeds() { /* both fields nil → ok, peerVersion=legacy */ }
func test_malformed_only_timestamp_present_rejects() { /* timestamp without sig → reject */ }
func test_malformed_only_sig_present_rejects() { /* sig without timestamp → reject */ }
func test_invalid_signature_rejects() { /* bad sig → reject */ }
func test_too_old_in_warn_mode_proceeds_with_metric() { /* old timestamp, .warn → proceed, metric */ }
func test_too_old_in_reject_mode_rejects() { /* old timestamp, .reject → throw */ }
func test_fresh_valid_proceeds() { /* fresh + valid sig → ok */ }
```

- [ ] **Step 2: Implement**

```swift
extension X3DH {
    public static func verifyBundleFreshness(
        bundle: PreKeyBundle,
        peerIdentityKey: Curve25519.Signing.PublicKey,
        now: Date,
        policy: SecurityPolicy,
        metrics: CryptoHardeningMetrics?
    ) throws -> ProtocolVersion {

        let hasTS = bundle.signedPreKeyTimestamp != nil
        let hasSig = bundle.signedPreKeyTimestampSignature != nil

        if !hasTS && !hasSig {
            metrics?.record(.c1SpkTimestampMissing)
            return .legacy
        }
        if hasTS != hasSig {
            metrics?.record(.c1SpkTimestampMalformed)
            throw InitiationError.timestampMalformed
        }
        // Both present
        let ts = bundle.signedPreKeyTimestamp!
        let sig = bundle.signedPreKeyTimestampSignature!
        let payload = bundle.signedPreKey.publicKey.rawRepresentation + uint64BigEndian(ts)
        guard peerIdentityKey.isValidSignature(sig, for: payload) else {
            metrics?.record(.c1SpkTimestampInvalidSignature)
            throw InitiationError.timestampSignatureInvalid
        }
        let ageDays = Int(now.timeIntervalSince1970 - Double(ts)) / 86400
        if ageDays > policy.spkMaxAgeDays {
            metrics?.record(.c1SpkTimestampTooOld)
            if policy.spkExpirationBehavior == .reject {
                throw InitiationError.timestampTooOld
            }
            // .warn: continue but mark for UI
        } else {
            metrics?.record(.c1SpkTimestampValid)
        }
        return .v5_4_plus
    }

    public enum InitiationError: Error, Equatable {
        case opkExhausted
        case timestampMalformed
        case timestampSignatureInvalid
        case timestampTooOld
    }
}
```

- [ ] **Step 3: Wire into `X3DH.initiate`** — call `verifyBundleFreshness` before the DH computation; capture the returned `ProtocolVersion` and propagate to `OPK exhaustion` check.

- [ ] **Step 4: Test PASS, commit**

---

### Task 6.4 — C1 UI banner

**Files:**
- Modify: `PeerDrop/UI/Security/CryptoHardeningBanner.swift`
- Modify: `PeerDrop/App/Localizable.xcstrings`

Add:
- `c1.spk.expired.title` → zh-Hant: `對方的加密金鑰已過期`
- `c1.spk.expired.body` → zh-Hant: `請對方重新開啟 app`
- Action: `c1.spk.expired.retry` → zh-Hant: `重新嘗試`

Surface it from `ConnectionManager` when `verifyBundleFreshness` throws `.timestampTooOld` (in `.reject` mode) OR records `c1.spk_timestamp_too_old` (in `.warn` mode).

Commit: `feat(c1): SPK expired UI banner`

---

### Task 6.5 — C1 property tests

**Files:**
- Modify: `PeerDropTests/CryptoTestKit/Tests/Properties/X3DHProperties.swift`

Add the 7 properties from spec §6.1:

```swift
func test_property_validSig_fresh_succeeds() { ... }
func test_property_invalidSig_rejects() { ... }
func test_property_malformed_onlyTimestamp_rejects() { ... }
func test_property_malformed_onlySig_rejects() { ... }
func test_property_invalidTimestampSig_rejects() { ... }
func test_property_expiredInReject_rejects() { ... }
func test_property_expiredInWarn_succeeds() { ... }
```

Commit: `test(c1): X3DH timestamp property tests`

---

### Task 6.6 — PR6 wrap-up + open PR

---

# PR7 — Per-peer override (peerProtocolVersion plumbing)

**Branch:** `feat/v5.4-per-peer-policy`

**Goal:** Plumb `peerProtocolVersion` through `RemoteMessageEnvelope` + `TrustedContact`; use `PeerPolicy.policy(for:base:)` at C1/C2 enforcement sites.

---

### Task 7.1 — Add `protocolVersion` field to `RemoteMessageEnvelope`

**Files:**
- Modify: `PeerDrop/Security/Protocol/RemoteMessageEnvelope.swift`
- Test: `PeerDropTests/RemoteMessageEnvelopeTests.swift`

- [ ] **Step 1: Failing test**

```swift
func test_envelope_with_protocolVersion_decodes() throws {
    let json = #"{"senderIdentityKey":"AAA=","ratchetMessage":{...},"protocolVersion":1}"#.data(using: .utf8)!
    let env = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: json)
    XCTAssertEqual(env.protocolVersion, 1)
}

func test_envelope_without_protocolVersion_decodes_to_nil() throws {
    let json = #"{"senderIdentityKey":"AAA=","ratchetMessage":{...}}"#.data(using: .utf8)!
    let env = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: json)
    XCTAssertNil(env.protocolVersion)
}
```

- [ ] **Step 2: Implement**

```swift
public struct RemoteMessageEnvelope: Codable {
    /* existing */
    public let protocolVersion: UInt8?
}
```

For send side, set `protocolVersion = 1` (= v5.4+).

- [ ] **Step 3: Test PASS, commit**

```bash
git checkout -b feat/v5.4-per-peer-policy
git add ...
git commit -m "feat(envelope): add optional protocolVersion field"
```

---

### Task 7.2 — Add `peerProtocolVersion` to `TrustedContact`

**Files:**
- Modify: `PeerDrop/Core/TrustedContactStore.swift`
- Test: `PeerDropTests/TrustedContactStoreTests.swift`

- [ ] **Step 1: Failing test**

```swift
func test_trustedContact_decodes_legacy_without_peerProtocolVersion() throws {
    // Old persisted JSON without the field → defaults to nil
}

func test_trustedContact_storesAndReturns_peerProtocolVersion() async throws {
    let store = try TrustedContactStore(...)
    var contact = TrustedContact(identityKey: ..., trustLevel: .linked)
    contact.peerProtocolVersion = .v5_4_plus
    try await store.upsert(contact)
    let retrieved = await store.contact(byKey: ...)
    XCTAssertEqual(retrieved?.peerProtocolVersion, .v5_4_plus)
}
```

- [ ] **Step 2: Add field**

```swift
public struct TrustedContact: Codable {
    /* existing */
    public var peerProtocolVersion: ProtocolVersion?
}
```

- [ ] **Step 3: Test PASS, commit**

---

### Task 7.3 — Wire `peerProtocolVersion` set on first envelope

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift`

In `handleRemoteMessage`:

```swift
let detected: ProtocolVersion = {
    if envelope.protocolVersion == 1 { return .v5_4_plus }
    if envelope.protocolVersion == nil { return .legacy }
    return .unknown
}()
// On first-contact approve, persist `peerProtocolVersion = detected` to TrustedContact.
```

In `approveFirstContact`:

```swift
var contact = newTrustedContactFromEnvelope(...)
contact.peerProtocolVersion = pendingDetectedVersion
try await trustedContactStore.upsert(contact)
```

- [ ] **Test + commit**

---

### Task 7.4 — Initiator infers responder version from bundle

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift`

After `X3DH.verifyBundleFreshness` returns a `ProtocolVersion`, propagate it to the `TrustedContact` (created when handshake completes) and use it for the C2 fail-closed check inside `X3DH.initiate`.

- [ ] **Test + commit**

---

### Task 7.5 — PR7 wrap-up

---

# PR8 — Threat model + release notes

**Branch:** `docs/v5.4-threat-model`

**Goal:** Publish `docs/security/threat-model-relay.md`, `docs/security/crypto-policy-format.md`, and v5.4 CHANGELOG entries.

---

### Task 8.1 — Threat model document

**Files:**
- Create: `docs/security/threat-model-relay.md`

Use the section structure from spec §7:
1. Scope
2. Trust model
3. Attack trees (one per item)
4. Out of scope (→ audit-#15)
5. Residual risk

Word count target: 2000–3500 words.

Commit: `docs(security): publish relay threat model`

---

### Task 8.2 — Crypto policy format spec

**Files:**
- Create: `docs/security/crypto-policy-format.md`

Document:
- JSON schema (all fields + types)
- Canonical-JSON rules
- Signing workflow (`tools/sign-crypto-policy.swift`)
- Public-key rotation procedure
- Bundled-default policy committed at `cloudflare-worker/bundled-default-policy.signed.json`

Commit: `docs(security): crypto policy format spec`

---

### Task 8.3 — CHANGELOG + release notes

**Files:**
- Modify: `CHANGELOG.md` (if exists; otherwise create)
- Create: `docs/release/v5.4.0-reviewer-notes.md`

Reviewer notes (the BEGIN_PASTE section) MUST stay under 4000 characters per the `feedback-asc-iap-quirks` lesson.

Commit: `docs(release): v5.4.0 reviewer notes + CHANGELOG`

---

### Task 8.4 — Backward-compatibility UITest matrix (spec §8.4)

**Files:**
- Create: `PeerDropUITests/V5_4_BackwardCompatTests.swift`
- Create: `PeerDropUITests/Helpers/MockLegacyPeer.swift`

The 4 cells from spec §8.4:
1. v5.4 ↔ v5.4 (baseline)
2. v5.4 ↔ mocked v5.3.6 (new initiator ↔ legacy responder)
3. mocked v5.3.6 ↔ v5.4 (legacy initiator ↔ new responder)
4. v5.4 with `SecurityPolicy` falling back to bundled defaults (policy-fetch-failure path)

- [ ] **Step 1: Mock legacy peer helper**

```swift
// PeerDropUITests/Helpers/MockLegacyPeer.swift
import Foundation
@testable import PeerDrop

/// Constructs `PreKeyBundle` / `RemoteMessageEnvelope` instances shaped
/// like the pre-v5.4 wire format (no timestamp fields, no protocolVersion)
/// so the v5.4 code path can be exercised against legacy peer behavior
/// in-process — no second simulator required.
public enum MockLegacyPeer {
    public static func legacyBundle(identityKey: Curve25519.Signing.PrivateKey,
                                     signedPreKey: Curve25519.KeyAgreement.PrivateKey,
                                     oneTimePreKey: Curve25519.KeyAgreement.PrivateKey?) -> PreKeyBundle {
        let spkSig = try! identityKey.signature(for: signedPreKey.publicKey.rawRepresentation)
        return PreKeyBundle(
            identityKey: identityKey.publicKey.rawRepresentation,
            signedPreKey: .init(publicKey: signedPreKey.publicKey, signature: spkSig, id: 1),
            oneTimePreKey: oneTimePreKey.map { .init(publicKey: $0.publicKey, id: 1) },
            signedPreKeyTimestamp: nil,
            signedPreKeyTimestampSignature: nil
        )
    }

    public static func legacyEnvelope(senderIK: Data, ratchetMessage: RatchetMessage) -> RemoteMessageEnvelope {
        RemoteMessageEnvelope(
            senderIdentityKey: senderIK,
            ratchetMessage: ratchetMessage,
            protocolVersion: nil   // legacy
        )
    }
}
```

- [ ] **Step 2: Cell 1 — v5.4 ↔ v5.4 baseline**

```swift
func test_cell1_v5_4_to_v5_4_X3DH_completes() async throws {
    let alice = makeFreshV54Peer(label: "alice")
    let bob = makeFreshV54Peer(label: "bob")
    let bundle = await bob.preKeyStore.currentPreKeyBundle()
    let session = try X3DH.initiate(
        myIdentityKey: alice.identityKey,
        myEphemeralKey: alice.freshEphemeral(),
        bundle: bundle,
        peerProtocolVersion: .v5_4_plus,
        policy: .bundledDefault,
        metrics: nil
    )
    XCTAssertFalse(session.rootKey.withUnsafeBytes { Data($0) }.isEmpty)
}
```

- [ ] **Step 3: Cell 2 — v5.4 initiator ↔ legacy responder**

```swift
func test_cell2_v5_4_initiator_with_legacy_responder() throws {
    let alice = makeFreshV54Peer(label: "alice")
    let bobLegacy = makeFreshLegacyKeyMaterial()  // no SPK timestamp
    let legacyBundle = MockLegacyPeer.legacyBundle(
        identityKey: bobLegacy.ik, signedPreKey: bobLegacy.spk, oneTimePreKey: bobLegacy.opk
    )
    // X3DH should succeed; peerProtocolVersion captured as .legacy
    let result = try X3DH.verifyBundleFreshness(
        bundle: legacyBundle,
        peerIdentityKey: bobLegacy.ik.publicKey,
        now: Date(),
        policy: .bundledDefault,
        metrics: nil
    )
    XCTAssertEqual(result, .legacy)
}
```

- [ ] **Step 4: Cell 3 — legacy initiator ↔ v5.4 responder**

```swift
func test_cell3_legacy_initiator_with_v5_4_responder_bundle() throws {
    // Simulate a v5.3.6 initiator that doesn't know to look at the
    // new bundle fields. It uses the legacy SPK signature only.
    let bob = makeFreshV54Peer(label: "bob")
    let bobBundle = await bob.preKeyStore.currentPreKeyBundle()
    // Legacy verifier only checks the legacy SPK signature.
    let spkSigValid = bob.identityKey.publicKey.isValidSignature(
        bobBundle.signedPreKey.signature,
        for: bobBundle.signedPreKey.publicKey.rawRepresentation
    )
    XCTAssertTrue(spkSigValid, "legacy SPK signature must still be valid for old clients")
}
```

- [ ] **Step 5: Cell 4 — v5.4 with policy fetch failure → bundled defaults**

```swift
func test_cell4_policyFetchFailure_fallsBackToBundledDefault() async throws {
    URLProtocol.registerClass(MockURLProtocol.self)
    MockURLProtocol.responseError = NSError(domain: "test", code: -1, userInfo: nil)

    let store = SecurityPolicyStore(storageDirectory: tmpDir, publicKeys: [testPubKey])
    await store.fetchAndUpdate()  // network failure path
    XCTAssertEqual(store.current, .bundledDefault, "fallback to bundled defaults on fetch error")
}
```

- [ ] **Step 6: Run all 4 cells + commit**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropUITests/V5_4_BackwardCompatTests
git add PeerDropUITests/V5_4_BackwardCompatTests.swift PeerDropUITests/Helpers/MockLegacyPeer.swift project.yml
git commit -m "test(uitests): v5.4 backward-compat 4-cell matrix"
```

---

### Task 8.5 — Release readiness checklist run

Run the checklist from spec §8.5. For each line:

- [ ] All property tests pass
- [ ] All frozen test vectors pass
- [ ] Fuzz CI runs 100K iterations per target with no new crashes
- [ ] Crypto-layer coverage ≥ 95% (per file)
- [ ] All 4 backward-compatibility UITest cells pass (Task 8.4)
- [ ] `docs/security/threat-model-relay.md` reviewed
- [ ] Worker policy blob signed in staging, fetched and applied successfully
- [ ] Bundled policy = legacy (no immediate enforcement at first install)
- [ ] 5-language i18n strings complete
- [ ] CHANGELOG and release notes drafted

When all pass: `fastlane release submit:false`, then proceed with standard ASC submission flow (see `docs/release/release-runbook.md`).

---

# Post-ship: 7-day soak + remote policy upgrade

After App Store approval and 7-day soak window:

1. Edit `cloudflare-worker/bundled-default-policy.json` (or a new `strict-policy.json`) with desired strict thresholds.
2. Sign:
   ```
   swift tools/sign-crypto-policy.swift \
       cloudflare-worker/strict-policy.json \
       <signing-key.json> \
     > cloudflare-worker/strict-policy.signed.json
   ```
3. Upload to worker env:
   ```
   cat cloudflare-worker/strict-policy.signed.json | npx wrangler secret put CRYPTO_POLICY_JSON --env production
   ```
4. Verify rollout in metrics:
   - `policy.fetch_success` rises
   - `c1.spk_timestamp_too_old` may rise (peers offline ≥ 21 days)
   - `c2.opk_failed_initiation` should stay ≈ 0

Rollback (if needed): clear the env var or upload the previous signed blob. Devices revert within 5 minutes.
