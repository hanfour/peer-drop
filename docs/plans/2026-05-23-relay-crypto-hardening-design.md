# Relay Crypto Hardening — v5.4 Design Spec

**Status:** Brainstorming complete, awaiting user review before plan stage
**Created:** 2026-05-23
**Target release:** v5.4.0
**Time budget:** 6–8 weeks (quality-optimized; lays groundwork for audit-#15)
**Author:** brainstorming session with user 2026-05-23

---

## 1. Problem statement

The v5.3.6 connection-layer audit surfaced four medium-risk gaps in PeerDrop's relay encryption path. None are acute, but together they erode the forward-secrecy and resource-hardening guarantees the Signal-style protocol is supposed to deliver:

- **C1 — Prekey bundle replay**: `X3DH` does not bind the responder's signed prekey (SPK) to a timestamp. An attacker who captures a bundle can replay it up to 21 days later (the "previous 3 SPKs" retention window in `PreKeyStore.swift:150`) and trick an initiator into completing X3DH against a stale key, degrading forward secrecy.
- **C2 — Silent OPK exhaustion**: when the responder's one-time-prekey list is empty, `X3DH.swift:32-34` silently skips DH4. The session still succeeds but with weaker forward secrecy. The sender never learns this happened.
- **C3 — Unbounded skipped-key growth**: `DoubleRatchet.swift` caps `skippedKeys` at 200 entries but has no time-based eviction. A peer with poor connectivity that keeps a session alive for months can accumulate stale keys on disk.
- **C4 — Unbounded consumed-OPK set**: `PreKeyStore.swift:27` tracks consumed OPK IDs in a `Set<UInt32>` that grows forever. Over the app's lifetime this is O(n) memory + disk growth with no prune policy.

This spec packages all four into a single v5.4 "hardening" release, plus the test infrastructure and threat-model documentation needed to ship the changes safely and to provide a baseline for audit-#15 (identity key rotation, scheduled to follow this release).

## 2. Scope

**In scope:**
- C1 SPK timestamp binding (additive wire change)
- C2 OPK exhaustion fail-closed (sender-side, policy-controlled)
- C3 skipped-keys LRU + TTL (local-only)
- C4 consumed-OPK prune (local-only)
- New `SecurityPolicy` + remote `crypto-policy` endpoint (crypto agility layer)
- `CryptoTestKit` test infrastructure (property tests, frozen vectors, fuzz harness)
- Threat model document (`docs/security/threat-model-relay.md`)

**Out of scope:**
- Identity key rotation → tracked separately as audit-#15
- X-API-Key deprecation → separate sub-project, time-gated to ~2026-06-13
- Any changes to local Wi-Fi (`LocalSecureChannel`) protocol

**Hard constraints:**
- **Wire compatibility with v5.0–v5.3.6**: all protocol changes must be additive (new optional fields); old peers ignore new fields and continue to work
- **One release**: all four items plus infrastructure ship together as v5.4.0
- **Remote policy is signed**: worker can never inject unsigned policy values
- **Stronger-of-two**: remote policy can only strengthen local defaults, never weaken
- **Local bounds**: each policy field has hard min/max; remote values outside the range are clamped

## 3. Architecture

### 3.1 Module boundaries

**New files:**

```
PeerDrop/Security/
├─ SecurityPolicy.swift                 # Policy struct + defaults + stronger-of-two merge
├─ SecurityPolicyStore.swift            # Boot-time fetch, signature verification, cache, fallback
└─ Telemetry/
   ├─ CryptoHardeningMetrics.swift      # C1–C4 counters
   └─ CryptoHardeningBanner.swift       # C1/C2 UI components

cloudflare-worker/src/
└─ cryptoPolicy.ts                      # Policy schema, signing, version handling

tools/
└─ sign-crypto-policy.swift             # Offline Ed25519 signer (operator workflow)

PeerDropTests/CryptoTestKit/             # New test infrastructure module
├─ Sources/{PropertyTest,TestVectorLoader,DeterministicCrypto,FuzzHarness}.swift
├─ TestVectors/{x3dh,ratchet,skipped-keys,policy}/*.json
└─ Tests/{Properties,Vectors,Fuzz}/

docs/security/
├─ threat-model-relay.md                # Attack trees + mitigations
└─ crypto-policy-format.md              # Policy JSON schema + signing spec
```

**Modified files:**

```
PeerDrop/Security/Protocol/PreKeyStore.swift     # C1 timestamp write, C4 prune
PeerDrop/Security/Protocol/X3DH.swift            # C1 timestamp verify, C2 fail-closed
PeerDrop/Security/Protocol/DoubleRatchet.swift   # C3 TTL + LRU
PeerDrop/Core/TrustedContactStore.swift          # Add peerProtocolVersion
cloudflare-worker/src/index.ts                   # Add /v2/config/crypto-policy route
PeerDrop/App/Info.plist                          # Bundle CryptoPolicyPublicKeys (array)
PeerDrop/App/Localizable.xcstrings               # 4 new keys × 5 languages
```

### 3.2 Policy data flow

```
Worker (signed source of truth)
      │  GET /v2/config/crypto-policy
      ▼
SecurityPolicyStore (client)
      │  Sync at boot: cache → bundled defaults
      │  Async: fetch → verify signature → merge stronger-of-two → publish
      ▼
SecurityPolicy.current  (immutable @Published, @MainActor)
      │  Read at every operation
      ▼
PreKeyStore / X3DH / DoubleRatchet / TrustedContactStore
```

**Three core invariants:**

1. **Stronger-of-two**: `merged(local, remote)` is never weaker than either input on any field.
2. **Signed-only**: remote policy without valid Ed25519 signature → ignored; fall back to cache or bundled.
3. **Cache-first**: app launch never blocks on network; cached or bundled policy is always usable synchronously.

### 3.3 Per-peer policy

`TrustedContactStore` gains a new field `peerProtocolVersion: PeerVersion?`, populated from the relay path only (C1/C2 enforcement is relay-specific; C3/C4 are local-only and don't need peer version).

> **Naming note (post-PR1):** the type was originally specified as `ProtocolVersion` but renamed to `PeerVersion` during implementation because `PeerDrop/Protocol/ProtocolVersion.swift` already declares a `UInt8`-backed enum for wire envelope format versioning — a distinct concept. The field name `peerProtocolVersion` is kept for readability; only the type name changed.

- **Relay**: new optional `protocolVersion: UInt8?` field on `RemoteMessageEnvelope` (additive, old peers ignore). When the responder receives the first envelope from a new peer, it stores `peerProtocolVersion` on the `TrustedContact` created at first-contact approval. The initiator independently infers the responder's version from the prekey bundle: if `signedPreKeyTimestamp` is present, the responder is `.v5_4_plus`; otherwise `.legacy`.
- **Local Wi-Fi**: `peerProtocolVersion` stays `nil` for `LocalSecureChannel` peers. This is fine because C1/C2 do not apply to local Wi-Fi (no X3DH, no SPK), and C3/C4 are purely local with no per-peer dependency.

`PeerPolicy.policy(for:base:)` resolves the effective policy:

| Peer version | C1/C2 behavior | C3/C4 behavior |
|---|---|---|
| `.v5_4_plus` | strict | strict |
| `.legacy` | no timestamp check, no fail-closed | strict (purely local, always applies) |
| `.unknown` / `nil` | same as `.v5_4_plus` | strict |

### 3.4 Why this split

- `SecurityPolicy` is a pure value type: easy to test, serialize, and compose.
- `SecurityPolicyStore` isolates all side effects (network, disk, signature verification) so the rest of the codebase reads policy synchronously.
- Existing crypto files (`PreKeyStore`, `X3DH`, `DoubleRatchet`) gain only thin checks at well-defined points; business logic is untouched, keeping diffs small and review-friendly.
- `CryptoTestKit` is in its own directory so it can be extracted into a SwiftPM module when audit-#15 starts.

## 4. Per-item designs

### 4.1 — C1: SPK timestamp binding

**Wire change (strictly additive):** `PreKeyBundle` gains **two** new optional fields. The existing SPK signature is **unchanged** — this is what preserves wire compatibility for old initiators verifying new responders' bundles.

```
PreKeyBundle (v5.4+ adds two optional fields):
  identityKey:                     pubkey                              (unchanged)
  signedPreKey:                    pubkey + legacy_spk_signature       (unchanged: signed by IK over SPK_pubkey)
  oneTimePreKey:                   pubkey                              (unchanged, optional)
  signedPreKeyTimestamp:           UInt64?                             (NEW, Unix seconds since epoch)
  signedPreKeyTimestampSignature:  Data?                               (NEW, Ed25519 over SPK_pubkey || timestamp_BE_8B, signed by IK)
```

The legacy SPK signature is preserved verbatim; new fields are tacked on. Old clients ignore unknown JSON keys and verify only the legacy SPK signature — wire compat holds in **both directions** (old↔new, new↔old).

**Verification flow (initiator-side, in `X3DH.initiate`):**

1. Verify legacy SPK signature over `SPK_pubkey` using peer's IK (same as today).
2. If exactly one of `signedPreKeyTimestamp` / `signedPreKeyTimestampSignature` is present (not both, not neither) → **hard reject** (looks like tampering); telemetry `c1.spk_timestamp_malformed`.
3. If both are absent → peer is legacy; proceed without freshness check; record `peerProtocolVersion = PeerVersion.legacy`; telemetry `c1.spk_timestamp_missing`.
4. If both are present:
   - Verify `signedPreKeyTimestampSignature` over `SPK_pubkey || timestamp_BE_8B` using peer's IK.
   - If invalid → **hard reject**; telemetry `c1.spk_timestamp_invalid_signature`.
   - If valid, check `now - timestamp > policy.spkMaxAgeDays`:
     - In `.warn` mode → proceed; show C1 UI banner; telemetry `c1.spk_timestamp_too_old`.
     - In `.reject` mode → **hard reject**; telemetry `c1.spk_timestamp_too_old` (with `extra.action = "reject"`).
   - If fresh → normal X3DH; telemetry `c1.spk_timestamp_valid`.

**Default threshold:** `spkMaxAgeDays = 21` (matches existing SPK rotation: 7-day interval × 3 retained). Remote policy may tighten to 14.

**UI:** when `c1.spk_timestamp_too_old` fires in `.reject` mode, show banner using the existing `decryptFailureBanner` visual pattern:
- Copy (zh-Hant): 「對方的加密金鑰已過期，請對方重新開啟 app」
- Action: 「重新嘗試」
- Auto-dismiss: no

### 4.2 — C2: OPK exhaustion fail-closed

**Position:** sender-side (initiator) only. Responder cannot control its own OPK depletion.

**Behavior matrix (controlled by `SecurityPolicy.opkExhaustionBehavior`):**

| Peer version | OPK in bundle | Behavior |
|---|---|---|
| `.legacy` (v5.0–v5.3) | nil | `.proceedWithoutDH4` (current behavior, telemetry only) |
| `.v5_4_plus` | nil | **`.failClosed`** + enqueue retry (every 60s, max 5 attempts) |
| `.unknown` | nil | Same as `.v5_4_plus` |
| Any | present | Normal X3DH |

**Retry mechanism:** new `OutboundRetryQueue` (sibling to existing `MailboxManager`) holds pending sends. The queue is persisted to disk (`~/Documents/Security/outbound-retry-queue.enc`, encrypted via `ChatDataEncryptor`) so retries survive app restart. On every retry tick:
1. Re-fetch the recipient's prekey bundle.
2. If OPK is now present, proceed with X3DH and drain the queued envelope.
3. If still missing after 5 attempts → permanent failure; surface "OPK exhausted" banner.

**UI states:**
- Retrying: 「對方暫時無法接收訊息，重試中…（N/5）」 + 「取消發送」 button
- Exhausted: 「對方加密金鑰存量不足，請對方開啟 app 補充」 + 「現在重試」 button

**Telemetry:** `c2.opk_missing`, `c2.opk_failed_initiation`, `c2.opk_retry_succeeded`, `c2.opk_retry_exhausted`.

### 4.3 — C3: Skipped keys LRU + TTL

**Local-only**; no wire impact.

**Data-structure change** in `DoubleRatchet`:

```swift
// Before
skippedKeys: [SkippedKeyIndex: SymmetricKey]

// After
struct SkippedKeyEntry {
    let key: SymmetricKey
    let createdAt: Date
}
skippedKeys: [SkippedKeyIndex: SkippedKeyEntry]
```

**Eviction (runs at every `decrypt` entry):**
1. **TTL pass**: remove entries where `now - createdAt > policy.skippedKeyTTLDays` (default 30)
2. **LRU pass**: if count still exceeds `policy.skippedKeyMaxCount` (default 200), remove oldest by `createdAt` until count ≤ max

**Persistence backward compatibility:** old session files have no `createdAt`. On load, missing timestamps are filled with `Date()` (giving a fresh TTL window — safe because those entries were already bounded by the existing 200 cap).

**Telemetry:** `c3.skipped_key_evicted_ttl`, `c3.skipped_key_evicted_lru`, `c3.skipped_key_hit`, `c3.skipped_key_miss`.

**No UI** (purely operational hardening).

### 4.4 — C4: Consumed-OPK set prune

**Local-only**; no wire impact.

**Data-structure change** in `PreKeyStore`:

```swift
// Before
consumedOneTimePreKeyIds: Set<UInt32>

// After
consumedOneTimePreKeyIds: [UInt32: Date]   // id → consumedAt
```

**Prune (runs at every `saveSync` entry):** remove entries where `now - consumedAt > policy.consumedOPKPruneWindowDays` (default 90).

**Critical invariant (enforced at SecurityPolicy construction and verified in property tests):**

```
policy.consumedOPKPruneWindowDays >= policy.spkMaxAgeDays * 4
```

Reasoning: a pruned consumed-OPK ID is only exploitable if the attacker can replay the original prekey bundle that referenced it. C1's SPK timestamp check rejects any bundle older than `spkMaxAgeDays`. The 4× safety margin guarantees the consumed entry outlives any usable replay window.

**Persistence backward compatibility:** old `Set<UInt32>` deserializes into `[UInt32: Date(now)]`. Each existing entry gets a fresh prune window so no entry is immediately purged on first save after upgrade.

**Telemetry:** `c4.consumed_opk_pruned`, `c4.consumed_opk_size` (sampled on every save).

**No UI.**

## 5. Crypto agility layer

### 5.1 Policy JSON schema

```json
{
  "schemaVersion": 1,
  "issuedAt": 1748000000,
  "expiresAt": 1750592000,
  "policy": {
    "spkMaxAgeDays": 21,
    "spkExpirationBehavior": "warn",
    "opkExhaustionBehavior": {
      "legacy": "proceedWithoutDH4",
      "strict": "failClosed"
    },
    "opkRetryMaxAttempts": 5,
    "opkRetryIntervalSeconds": 60,
    "skippedKeyTTLDays": 30,
    "skippedKeyMaxCount": 200,
    "consumedOPKPruneWindowDays": 90
  },
  "signature": "<base64 Ed25519 over canonical JSON(schemaVersion + issuedAt + expiresAt + policy)>"
}
```

- **Canonical JSON**: RFC 8785 (JCS), deterministic for signing
- **`schemaVersion`**: when client encounters newer version it doesn't understand → fall back to bundled defaults + telemetry
- **`expiresAt`**: advisory; client uses expired cache only as last resort, marks for refresh

### 5.2 Worker endpoint

`GET /v2/config/crypto-policy` — no auth required; the response is signed.

- Response body: the JSON above
- Headers: `Cache-Control: public, max-age=3600, s-maxage=86400`
- Worker env var `CRYPTO_POLICY_JSON` holds the pre-signed blob; worker has **no signing capability**
- If env var unset → return the bundled default (also signed offline and committed to the repo)

### 5.3 Signing key custody

- **Ed25519** keypair; private key lives offline on operator workstation, never on worker
- Workflow: operator edits policy JSON → runs `tools/sign-crypto-policy.swift` → pastes signed blob into Cloudflare worker env vars
- Public keys bundled in `Info.plist` under `CryptoPolicyPublicKeys` (base64 array, supports rotation)
- Rotation procedure: ship a new build with both old and new public keys → 30 days later, drop old public key from a subsequent build

### 5.4 Client fetch flow

```
App launch
 │
 ├─ Synchronous load from ~/Documents/Security/crypto-policy.json
 │   ├─ Signature valid + not expired → use cached
 │   ├─ Signature valid + expired      → use cached + mark for refresh
 │   └─ Missing or invalid             → use bundled defaults
 │
 ├─ Async fetch GET /v2/config/crypto-policy (non-blocking)
 │   ├─ Signature valid + schemaVersion supported → update cache + publish to SecurityPolicy.current
 │   ├─ Signature invalid             → keep current; telemetry policy.signature_invalid
 │   ├─ schemaVersion unsupported     → keep current; telemetry policy.version_unsupported
 │   └─ Network failure               → exponential backoff (1m, 5m, 15m, 1h cap)
 │
 └─ Periodic refresh every 24h
```

`SecurityPolicy.current` is a `@Published` value on `SecurityPolicyStore` (`@MainActor`). All consumers re-read on every operation, so policy updates take effect immediately without restart.

### 5.5 Stronger-of-two merge

```swift
extension SecurityPolicy {
    static func merged(local: SecurityPolicy, remote: SecurityPolicy) -> SecurityPolicy {
        SecurityPolicy(
            spkMaxAgeDays: min(local.spkMaxAgeDays, remote.spkMaxAgeDays),
            spkExpirationBehavior: stricter(local.spkExpirationBehavior, remote.spkExpirationBehavior), // .reject > .warn
            opkExhaustionBehavior: { peer in
                stricter(local.opkExhaustionBehavior(peer), remote.opkExhaustionBehavior(peer))         // .failClosed > .proceedWithoutDH4
            },
            opkRetryMaxAttempts: max(local.opkRetryMaxAttempts, remote.opkRetryMaxAttempts),           // more retries = better UX, equal security
            opkRetryIntervalSeconds: local.opkRetryIntervalSeconds,                                     // UX only; local wins
            skippedKeyTTLDays: min(local.skippedKeyTTLDays, remote.skippedKeyTTLDays),
            skippedKeyMaxCount: min(local.skippedKeyMaxCount, remote.skippedKeyMaxCount),
            consumedOPKPruneWindowDays: max(local.consumedOPKPruneWindowDays, remote.consumedOPKPruneWindowDays)  // longer = stricter
        )
    }
}
```

**Core invariant (property-tested):** `merged(A, B) ⊒ A ∧ merged(A, B) ⊒ B` where `⊒` means "at least as strict on every field". The worker can only ever strengthen, never weaken.

### 5.6 Local bounds (defense against malicious remote policy)

```swift
struct SecurityPolicyBounds {
    static let spkMaxAgeDaysRange = 7...90
    static let opkRetryMaxAttemptsRange = 1...20
    static let opkRetryIntervalSecondsRange = 30...600
    static let skippedKeyTTLDaysRange = 1...365
    static let skippedKeyMaxCountRange = 50...2000
    static let consumedOPKPruneWindowDaysRange = 30...365
}
```

Any remote value outside its range is clamped to the bound; telemetry records `policy.value_out_of_bounds` with the field name.

### 5.7 Attack surface

**Worker or signing-key compromise allows the attacker to:**
- DoS by setting `spkMaxAgeDays = 0` (every bundle rejected). Mitigated by local lower bound of 7.
- DoS by setting `opkExhaustionBehavior.legacy = "failClosed"`. No data exfil, no key exposure, just availability damage.

**Compromise does NOT allow the attacker to:**
- Weaken C3/C4 below local defaults (stronger-of-two + bounds)
- Violate `consumedOPKPruneWindowDays >= spkMaxAgeDays * 4` (client rejects violating policy → falls back to cache/bundled)
- Inject code (policy is data, parsed by a hardened parser that is also fuzzed)

**Defense in depth:**
- Public-key rotation (30-day overlap)
- Local bounds (clamp outside ranges)
- Stronger-of-two (never weaken)
- Reasonable bundled defaults (cache failure → safe state)

### 5.8 Telemetry (policy layer)

`policy.fetch_success`, `policy.fetch_failure`, `policy.signature_invalid`, `policy.version_unsupported`, `policy.value_out_of_bounds`, `policy.cache_hit`, `policy.expired_in_use`.

## 6. Test infrastructure (CryptoTestKit)

### 6.1 Property tests (non-negotiable invariants)

**C1:**
- `∀ bundle. legacySpkSigValid(bundle) ∧ noTimestamp(bundle) ⇒ initiate(bundle).ok` (peer is legacy)
- `∀ bundle. legacySpkSigValid(bundle) ∧ timestampSigValid(bundle) ∧ fresh(bundle) ⇒ initiate(bundle).ok`
- `∀ bundle. ¬legacySpkSigValid(bundle) ⇒ initiate(bundle).fails` (unchanged from today)
- `∀ bundle. hasTimestamp(bundle) ∧ ¬hasTimestampSig(bundle) ⇒ initiate(bundle).fails` (malformed)
- `∀ bundle. ¬hasTimestamp(bundle) ∧ hasTimestampSig(bundle) ⇒ initiate(bundle).fails` (malformed)
- `∀ bundle. hasTimestamp(bundle) ∧ ¬timestampSigValid(bundle) ⇒ initiate(bundle).fails`
- `∀ bundle. expired(bundle) ∧ policy.expirationBehavior == .reject ⇒ initiate(bundle).fails`

**C2:**
- `peerVersion == .legacy ⇒ initiateWithoutOPK.proceedsWithoutDH4`
- `peerVersion ∈ {.strict, .unknown} ⇒ initiateWithoutOPK.failsClosed`

**C3:**
- `∀ skipped. age > policy.ttl ⇒ ¬contains(skipped)`
- `count(skippedKeys) ≤ policy.maxCount`

**C4:**
- `∀ consumed. age > policy.pruneWindow ⇒ pruned`
- `policy.pruneWindow ≥ policy.spkMaxAge * 4` (asserted on policy construction; also property-tested)

**SecurityPolicy:**
- `∀ local remote. merged(local, remote) ⊒ local ∧ merged(local, remote) ⊒ remote`
- `∀ policy. validateBounds(policy).fields ⊂ allowed_ranges`

**Harness:** 100 randomized trials per property per test run, fixed seed for reproducible failures, runs in `xcodebuild test` like any other XCTest.

### 6.2 Frozen test vectors

Generated once via a deterministic Swift utility using seeded keys; checked into the repo. CI runs every commit; any change that breaks a vector requires an explicit decision (update vector or roll back the change).

Vector format:

```json
{
  "name": "x3dh_initiator_with_opk",
  "inputs": {
    "alice_ik_seed": "0x01...",
    "bob_ik_seed": "0x02...",
    "bob_spk_seed": "0x03...",
    "bob_opk_seed": "0x04...",
    "alice_ek_seed": "0x05..."
  },
  "expected": {
    "root_key": "base64...",
    "chain_key": "base64..."
  }
}
```

**Initial set:** 20 X3DH vectors, 30 ratchet vectors, 10 skipped-key sequences, 5 signed-policy fixtures.

### 6.3 Fuzz harness

**Targets:**
- `X3DH.parsePreKeyBundle(Data)`
- `DoubleRatchet.parseEnvelope(Data)`
- `SecurityPolicyStore.parseSignedPolicy(Data)`

**Strategy:** in-process, no libFuzzer (avoids toolchain complexity); seeded random + simple mutation operators (bit flip, byte insert/delete, length truncation); 10K iterations per target per CI run; any uncaught throw or hang > 1s = test failure.

Reference: Signal's `libsignal` Swift test style.

### 6.4 Coverage target

- `PeerDrop/Security/Protocol/*`: **95% line coverage** per file (currently ~70%)
- `SecurityPolicy.swift` and `SecurityPolicyStore.swift`: **100%**
- Enforced by CI parsing `xccov` JSON reports; below threshold → CI fails

Net uplift: +25 percentage points on the crypto-layer files.

## 7. Threat model document

`docs/security/threat-model-relay.md`, deliverable alongside the code.

**Required sections:**

1. **Scope** — relay X3DH / DoubleRatchet / PreKeyStore / SecurityPolicy. Out of scope: local Wi-Fi, transport, identity-key rotation (audit-#15).
2. **Trust model** — worker is honest-but-curious; signing-key custodian is trusted; users trust the bundled public keys.
3. **Attack trees** — one per item:
   - Bundle replay (mitigated by C1)
   - OPK exhaustion downgrade (mitigated by C2)
   - Skipped-key cache poisoning / DoS (mitigated by C3)
   - Long-term consumed-OPK forgetfulness (mitigated by C4)
   - Policy downgrade via worker compromise (mitigated by stronger-of-two + local bounds)
4. **Out of scope** — explicitly call out audit-#15 as the home for identity-key rotation work.
5. **Residual risk** — honest acknowledgment of gaps that remain after this release (e.g., no protection against full device compromise; identity key still long-lived).

## 8. Telemetry, UI, and rollout

### 8.1 Telemetry pipeline

New file `Telemetry/CryptoHardeningMetrics.swift` exposes 22 counters (C1: 5, C2: 4, C3: 4, C4: 2, policy: 7). All events flow through the existing `ConnectionMetrics` → `/debug/metric` pipeline, flushed every 5 minutes or on app background.

**Privacy:** events carry only `kind: String` and optional `peerVersion: String?` (`PeerVersion.rawValue` — e.g., `"legacy"`, `"v5_4_plus"`). **No peer IDs, no message IDs, no payload data.** Aligns with the existing Privacy Manifest.

**Schema:**

```swift
struct CryptoHardeningEvent: Codable {
    let timestamp: Date
    let kind: String                  // e.g. "c1.spk_timestamp_too_old"
    let peerVersion: String?  // PeerVersion.rawValue: "legacy" | "v5_4_plus" | "unknown"
    let extra: [String: String]?
}
```

### 8.2 UI surfaces

Two new banner types, both reusing the existing `decryptFailureBanner` visual pattern:

| Banner | Trigger | Copy (zh-Hant) | Action |
|---|---|---|---|
| C1: SPK expired | `c1.spk_timestamp_too_old` in `.reject` mode | 「對方的加密金鑰已過期，請對方重新開啟 app」 | 「重新嘗試」 |
| C2: OPK retry | retry queue advances | 「對方暫時無法接收訊息，重試中…（N/5）」 | 「取消發送」 |
| C2: OPK exhausted | 5 retries failed | 「對方加密金鑰存量不足，請對方開啟 app 補充」 | 「現在重試」 |

**i18n:** 4 new keys × 5 languages (en, zh-Hant, zh-Hans, ja, ko) = 20 entries in `Localizable.xcstrings`.

**Optional Settings → 進階 → 加密狀態 panel:** displays current policy version, last fetch time, local counter summary. Read-only, no actions.

### 8.3 Rollout — 8 sequential PRs, single v5.4 release

| PR | Content | Enables behavior? |
|---|---|---|
| 1 — Foundation | `SecurityPolicy` + `SecurityPolicyStore` + bundled public keys + metrics scaffold | No (no consumers yet) |
| 2 — CryptoTestKit | Module skeleton + first batch of property tests + vectors + coverage target | No |
| 3 — C3 + C4 | Local-only hardening (skipped keys + consumed OPK) | **Yes** (local only, no wire impact) |
| 4 — Worker endpoint | `/v2/config/crypto-policy` + `tools/sign-crypto-policy.swift` + client fetch flow | Fetch begins; policy contents still legacy defaults |
| 5 — C2 | OPK fail-closed + retry queue + UI banners + i18n | No (policy-controlled; bundled default = legacy) |
| 6 — C1 | SPK timestamp signing + bundle field + verification + UI banner | No (policy-controlled) |
| 7 — Per-peer override | `peerProtocolVersion` + `PeerPolicy` resolver | No |
| 8 — Threat model + release notes | `docs/security/threat-model-relay.md` + crypto CHANGELOG | — |

**Activation strategy (feature flag via remote policy):**
- PRs 1–8 ship with bundled default policy = legacy behavior → **zero behavior change on first install of v5.4**
- After App Store approval and 7-day soak, push a new worker policy blob → all devices fetch within 5 minutes → C1/C2 enforcement engages progressively
- Any production issue → revert worker policy blob → behavior returns to legacy within 5 minutes (**no App Store re-review required**)

### 8.4 Backward compatibility verification

UITests gain a 4-cell compatibility matrix:
- v5.4 ↔ v5.4 (baseline)
- v5.4 ↔ mocked v5.3.6 (new ↔ legacy)
- mocked v5.3.6 ↔ v5.4 (legacy ↔ new)
- v5.4 with `SecurityPolicy` falling back to bundled defaults (policy-fetch failure path)

Each cell verifies X3DH completes, send and receive both work.

### 8.5 Release readiness checklist

Ship gate — all must pass:

- [ ] All property tests pass (100%)
- [ ] All frozen test vectors pass
- [ ] Fuzz CI runs 100K iterations per target with no new crashes
- [ ] Crypto-layer coverage ≥ 95% (per file, enforced in CI)
- [ ] All 4 backward-compatibility UITest cells pass
- [ ] `docs/security/threat-model-relay.md` reviewed
- [ ] Worker policy blob signed in staging, fetched and applied successfully
- [ ] Bundled policy = legacy (no immediate enforcement at first install)
- [ ] 5-language i18n strings complete
- [ ] CHANGELOG and release notes drafted

### 8.6 Post-ship monitoring (7-day observation window)

Daily review of:

| Metric | Expected | Action if not |
|---|---|---|
| `c1.spk_timestamp_invalid_signature` | ≈ 0 | Non-zero = real attack or bug; investigate |
| `c1.spk_timestamp_too_old` | Baseline = "peers offline ≥ 21 days" users | If unexpectedly high, may need to relax threshold |
| `c2.opk_failed_initiation` | ≈ 0 | High = OPK replenishment broken; investigate |
| `policy.signature_invalid` | 0 | Non-zero = signing key mismatch or bundled public key wrong |

After 7 stable days → upgrade worker policy blob to enable `strict` enforcement.

## 9. Open questions and future work

**Open for follow-up (not blocking this spec):**
- Should the policy fetch endpoint reuse the App Attest Bearer token, or stay anonymous? **Decision in this spec:** anonymous because the response is signed; auth would add complexity without raising security.
- Should the C1 timestamp also be bound into HKDF info (defense in depth)? **Decision in this spec:** no, the signature already binds it; HKDF binding is redundant and would break wire compatibility (HKDF info change is not additive).

**Future work (separate sub-projects):**
- **audit-#15: Identity key rotation** — uses the `CryptoTestKit` infrastructure built here as its baseline; expected 2026-07 onward.
- **X-API-Key deprecation** — earliest 2026-06-13; separate sub-project tracked in `docs/plans/2026-05-13-worker-auth-redesign.md` §Layer 5.
- **Optional: SPK timestamp also included in HKDF info** — if a future audit recommends defense in depth.

## 10. References

- `docs/plans/2026-05-13-worker-auth-redesign.md` — preceding worker auth redesign (App Attest)
- `PeerDrop/Security/Protocol/X3DH.swift` — current X3DH implementation
- `PeerDrop/Security/Protocol/DoubleRatchet.swift` — current Double Ratchet implementation
- `PeerDrop/Security/Protocol/PreKeyStore.swift` — current prekey management
- Signal's [`libsignal`](https://github.com/signalapp/libsignal) — reference for Swift crypto test style
- RFC 8785 — JSON Canonicalization Scheme (for policy signing)
