# Threat Model — Relay Crypto Hardening (v5.4)

**Status:** Published  
**Date:** 2026-05-23  
**Spec:** [docs/plans/2026-05-23-relay-crypto-hardening-design.md](../plans/2026-05-23-relay-crypto-hardening-design.md)  
**Covers:** PRs [#37](https://github.com/hanfour/peer-drop/pull/37)–[#43](https://github.com/hanfour/peer-drop/pull/43)

---

## 1. Scope

This document covers the threat model for PeerDrop's **cloud relay transport path** as hardened in the v5.4 release. The relay path is the cross-country, non-proximity mode introduced in v5.0, where peers exchange messages through the Cloudflare Worker signaling relay at `peerdrop-signal.hanfourhuang.workers.dev` rather than via a direct local Wi-Fi connection.

Components in scope:

- **X3DH key agreement** over relay: the initiator fetches a pre-key bundle from the worker and uses it to establish a shared secret with the responder.
- **Double Ratchet session**: the symmetric-key ratchet that provides forward secrecy and break-in recovery for ongoing messaging after X3DH.
- **PreKeyStore**: the server-side store (inside the Cloudflare Worker) that holds signed pre-keys (SPKs) and one-time pre-keys (OPKs).
- **SecurityPolicy** and the crypto agility layer: the signed JSON blob fetched from the worker at `/v2/config/crypto-policy` that governs tunable thresholds for the hardening measures above.

**Explicitly out of scope (deferred to audit-#15):**

- Local Wi-Fi transport (the SAS pairing sheet path). The local path has its own MITM defense and is not materially changed in v5.4.
- Identity-key rotation. Ed25519 identity keys are long-lived and not yet subject to automated rotation.
- Post-compromise recovery beyond what the Double Ratchet already provides.
- Long-term secret shredding on device loss.

---

## 2. Trust Model

### 2.1 The Cloudflare Worker

The worker is treated as **honest-but-curious**: it faithfully executes its code, stores and serves pre-key bundles and ciphertext envelopes, and forwards relay traffic, but it is assumed to read everything it can access. Under this model:

- The worker **cannot** read plaintext chat messages or file contents — all application data is Double Ratchet-encrypted end-to-end between devices.
- The worker **can** read pre-key bundles (public keys), ciphertext envelopes (opaque blobs), metadata (sender mailbox IDs, recipient mailbox IDs, message timestamps, and sizes).
- The worker **can** serve a tampered or replayed pre-key bundle to a connecting initiator. The v5.4 hardening package (C1–C4 + policy layer) constrains how much damage this can do.

The honest-but-curious model is appropriate for a Cloudflare-hosted worker under normal conditions. A **full compromise of the worker** (malicious code replaced, for example by a supply-chain attack on the wrangler deployment pipeline) is treated as out of scope for this document and is mitigated primarily by the signing layer on the crypto policy blob (see Section 3.5 below).

### 2.2 The Offline Signing-Key Custodian

The Ed25519 private key used to sign the crypto policy blob is kept offline, never committed to source control. The custodian is trusted to:

- Keep the key material offline and protected.
- Sign only policy blobs that have been reviewed and are consistent with the spec.
- Follow the public-key rotation procedure in `docs/security/crypto-policy-format.md` if the key is ever suspected of compromise.

### 2.3 App Users (Trust-on-First-Use)

Users trust the Ed25519 public keys bundled in the app at build time. The model is TOFU (trust on first use of the app): users who install from the App Store receive a binary with a fixed public key baked into `Info.plist`'s `CryptoPolicyPublicKeys` array. That key is the sole root of trust for policy enforcement.

Users trust each other's identity keys via the SAS pairing sheet (local Wi-Fi) or via the receiver-side `pendingFirstContact` prompt (relay). Neither mechanism is changed in v5.4.

---

## 3. Attack Trees

### A1 — Bundle Replay

*An attacker fetches an old signed-pre-key bundle and presents it to an initiator as the responder's current bundle.*

**Attacker capability.** Anyone who can make HTTPS requests to the Cloudflare Worker's `/v2/prekey-bundle/<peerID>` endpoint can fetch a pre-key bundle. Because bundles contain public keys and are not themselves encrypted, a passive network observer or an attacker who has compromised the worker can also store any bundle they observe.

**Attack steps:**

1. Attacker records a valid pre-key bundle for victim Bob at time T₀. The bundle contains Bob's SPK (Signed Pre-Key) and one or more OPKs (One-Time Pre-Keys), all signed by Bob's identity key.
2. At time T₁ (much later, e.g. T₀ + 60 days), when Bob has rotated his SPK, the attacker re-uploads the stale T₀ bundle to the worker, replacing the current bundle.
3. A new initiator Alice fetches what she believes is Bob's current bundle and runs X3DH against it.
4. Alice derives a session secret from a stale SPK. If any of the stale OPKs were already consumed in prior sessions, Bob has no corresponding OPK private key and the X3DH-derived secret is irrecoverable on his side. Depending on which OPK Alice chose, Bob may be completely unable to decrypt Alice's initial envelope.

**What fails without the mitigation.** Before v5.4, SPK bundles carried no timestamp. An initiator had no way to distinguish a current bundle from one recorded 90 days ago. The attack allows the worker (or any man-in-the-middle with write access to the pre-key store) to force initiators into sessions built on stale key material, potentially causing session establishment failures or, in pathological cases, cryptographic confusion if a stale OPK private key has been deleted from Bob's device.

**What the mitigation does.** C1 ([spec §4.1](../plans/2026-05-23-relay-crypto-hardening-design.md), [PR #42](https://github.com/hanfour/peer-drop/pull/42)) adds a separately-signed Unix-seconds timestamp to each SPK bundle at upload time. The timestamp is signed by the owner's identity key, so neither the worker nor a network observer can backdate or advance it without invalidating the signature. Initiators check the timestamp against `policy.spkMaxAgeDays` (default: 21 days) and refuse to proceed with an expired bundle. The refusal behavior is controlled by `policy.spkExpirationBehavior` (default: `warn`; can be hardened to `reject` via a policy update without a new App Store release).

**Residual risk.** An attacker who replays a bundle that is less than `spkMaxAgeDays` old can still present it. The window narrows as `spkMaxAgeDays` is tightened. SPK rotation cadence on the responder side determines how often fresh bundles are uploaded; if a device is offline for longer than `spkMaxAgeDays`, legitimate initiators will also be refused until the device reconnects and uploads a new SPK.

---

### A2 — OPK Exhaustion Downgrade

*An attacker drains the responder's one-time pre-key pool, then tricks an initiator into running X3DH without a one-time pre-key, silently losing the DH4 forward-secrecy leg.*

**Attacker capability.** Each time a legitimate-appearing X3DH initiation is processed, the worker removes one OPK from the responder's pool and returns it to the initiator. An attacker who can make repeated initiation-like requests to the worker can drain the OPK pool without any per-request authentication.

**Attack steps:**

1. Attacker sends a flood of forged X3DH initiation envelopes addressed to victim Bob, each consuming one OPK from Bob's pool.
2. Bob's pool is exhausted. The worker's pre-key bundle endpoint now returns a bundle with no OPK.
3. A legitimate initiator Alice fetches Bob's bundle, sees `opks: []`, and — under the pre-v5.4 behavior — proceeds with X3DH using only the SPK (no DH4). This is the "X3DH without ephemeral OPK" variant, which provides weaker forward secrecy: if Bob's SPK private key is later compromised, all sessions that skipped DH4 can be retroactively decrypted.
4. Alice sends her initial envelope. Bob receives it, establishes the session, and neither party notices that DH4 was absent.

**What fails without the mitigation.** The silent downgrade is the core problem: pre-v5.4 code logs nothing observable to the user, so a sustained OPK exhaustion attack silently degrades all new relay sessions to weaker forward secrecy without either party's knowledge or consent. An attacker who can record relay ciphertext and who later compromises Bob's SPK can decrypt all those sessions retroactively.

**What the mitigation does.** C2 ([spec §4.2](../plans/2026-05-23-relay-crypto-hardening-design.md), [PR #41](https://github.com/hanfour/peer-drop/pull/41)) changes the initiator's behavior when a no-OPK bundle is received. Under the `failClosed` behavior (default for v5.4+ initiators talking to v5.4+ responders), the initiator refuses to proceed and instead enqueues the initiation to a persistent retry queue with exponential backoff. A banner is surfaced to the user indicating that the session could not be established. The `opkExhaustionBehavior` field in the policy blob has two sub-fields — `legacy` and `strict` — so that v5.4 initiators continue to apply the old `proceedWithoutDH4` behavior when talking to pre-v5.4 responders (which cannot replenish OPKs on demand), while applying `failClosed` to v5.4+ sessions. The behavior switch is keyed on `PeerVersion`, which is tagged on every relay envelope in v5.4 (see [PR #43](https://github.com/hanfour/peer-drop/pull/43)).

**Residual risk.** An attacker can still cause a denial of service by exhausting the OPK pool: legitimate initiations will queue and retry but not complete until Bob's device comes online and replenishes. The retry queue with configurable `opkRetryMaxAttempts` (default: 5) and `opkRetryIntervalSeconds` (default: 60s) bounds how long the initiator retries. This is an availability concern, not a confidentiality concern — with `failClosed`, the attacker cannot degrade forward secrecy; they can only delay session establishment.

---

### A3 — Skipped-Key Cache Poisoning / Denial of Service

*An attacker floods the Double Ratchet's out-of-order key cache, causing unbounded memory growth or poisoning valid skipped-key entries.*

**Attacker capability.** A peer who is already in an established Double Ratchet session can send messages out of order or with artificially advanced ratchet counters. The recipient's implementation stores the "skipped" message keys in a local map so that genuinely delayed out-of-order messages can still be decrypted later. An attacker peer who generates a large number of messages with advancing chain counter values, never sending the corresponding ciphertext, forces the recipient to store O(N) skipped keys with no natural eviction mechanism.

**Attack steps:**

1. Attacker Alice is in a valid Double Ratchet session with victim Bob.
2. Alice sends Bob a stream of messages that force large ratchet steps — each message has a `prevMessageCount` or chain-counter value far ahead of the last seen counter.
3. Bob's implementation stores all intermediate skipped keys in its in-memory (and possibly on-disk) map, one entry per skipped index.
4. Over time the map grows to hundreds of megabytes. On a constrained iOS device, memory pressure kills the PeerDrop process; on disk, the persisted skipped-key store grows without bound.
5. Alternatively, Alice crafts a specific key that collides with or evicts a genuine skipped key that Bob was waiting to use, causing a legitimate out-of-order message from a different (honest) sender to become permanently undecryptable.

**What fails without the mitigation.** The pre-v5.4 Double Ratchet skipped-key cache had no eviction policy: entries were added on each skipped key encountered and only removed when the corresponding message was successfully decrypted. An attacker peer could trigger unbounded growth, and genuinely delayed messages from the past might eventually be evicted in an ad-hoc manner but without any defined behavior.

**What the mitigation does.** C3 ([spec §4.3](../plans/2026-05-23-relay-crypto-hardening-design.md), [PR #39](https://github.com/hanfour/peer-drop/pull/39)) introduces a two-dimensional eviction policy on the skipped-key map. Each entry carries a creation timestamp, and the map is bounded by both age (`policy.skippedKeyTTLDays`, default: 30 days) and count (`policy.skippedKeyMaxCount`, default: 200 entries). When a new entry would exceed either bound, the oldest entries are evicted first (LRU). This bounds the memory footprint of the skipped-key map to a predictable constant regardless of attacker behavior. Both bounds are operator-tunable via the signed policy blob without an App Store release — if the bounds prove too tight in practice (legitimate high-volume peers with lossy relay connections), the operator can widen them; if a new attack surface is discovered, they can tighten.

**Residual risk.** With bounds enforced, a legitimate out-of-order message whose skipped key has been evicted by the TTL becomes permanently undecryptable. The default 30-day TTL is generous for most real out-of-order scenarios (relay delivery delays are typically seconds to minutes, not weeks), but a device that was offline for longer than the TTL will experience message loss for genuinely delayed envelopes. This is a deliberate availability trade-off in favor of bounded memory.

---

### A4 — Long-Term Consumed-OPK Forgetfulness

*The `consumedOneTimePreKeyIds` set grows unbounded on disk, and an OPK ID that was pruned from the set becomes replayable.*

**Attacker capability.** An attacker who can observe or record a pre-key bundle that includes a specific OPK (either by fetching it from the worker before it was consumed, or by observing it in a prior session's X3DH handshake) can, at a later time, attempt to replay a synthetic X3DH initiation that reuses the same OPK ID. The responder's defense is to check whether that OPK ID is in the `consumedOneTimePreKeyIds` set. If the ID has been pruned from the set, the responder cannot detect the replay and will accept the initiation as if it used a fresh OPK.

**Attack steps:**

1. At time T₀, attacker records an X3DH initiation envelope from Alice to Bob that uses OPK ID 42.
2. Bob accepts the initiation, adds OPK ID 42 to `consumedOneTimePreKeyIds`, and deletes the OPK private key.
3. The pre-v5.4 `consumedOneTimePreKeyIds` set grows forever. After a long time, Bob's device performs a prune (or the set is cleared after a reinstall), and OPK ID 42 is removed.
4. Attacker re-sends the recorded X3DH initiation envelope from step 1. Bob no longer has OPK ID 42 in the consumed set, accepts the replayed initiation, and attempts to derive the session secret. Since Bob deleted the OPK private key in step 2, he cannot actually derive the same secret as Alice used — the session is broken — but the attacker has forced a spurious session establishment attempt.
5. In a more targeted variant: attacker generates a fresh OPK keypair and arranges for OPK ID 42 to collide with the (now-pruned) consumed ID. Depending on implementation details, the responder might accept the new OPK as fresh.

**What fails without the mitigation.** The pre-v5.4 code had no prune policy on the consumed-OPK set. In practice the set would grow until a device reinstall or app data clear. An unbounded set is both a storage issue and a DoS vector (in memory, checking membership in an ever-growing set degrades to O(N) or requires an index that itself consumes space).

**What the mitigation does.** C4 ([spec §4.4](../plans/2026-05-23-relay-crypto-hardening-design.md), [PR #39](https://github.com/hanfour/peer-drop/pull/39)) introduces a sliding prune window of `policy.consumedOPKPruneWindowDays` (default: 90 days). Entries older than the prune window are eligible for eviction. This bounds the on-disk set size. The relationship between this value and `spkMaxAgeDays` is governed by a cross-field invariant enforced in `SecurityPolicy.validateInvariants`: `consumedOPKPruneWindowDays` must be at least `spkMaxAgeDays × 4`. This ensures that by the time an OPK ID ages out of the consumed set, the corresponding SPK bundle is already well past its `spkMaxAgeDays` expiry and will be rejected by C1 before a replay can proceed.

**Residual risk.** The invariant `consumedOPKPruneWindowDays ≥ spkMaxAgeDays × 4` is validated at policy-parse time; any signed blob that violates it causes the client to fall back to bundled defaults rather than applying the offending policy. As long as an attacker cannot push a validly-signed policy that relaxes both values simultaneously below the invariant threshold, the relay-replay window is bounded. The offline signing key is the ultimate trust root for this guarantee.

---

### A5 — Policy Downgrade via Worker Compromise

*An attacker who controls the worker pushes a weakened crypto-policy blob, bypassing the C1–C4 hardening measures.*

**Attacker capability.** The worker serves the signed policy blob at `/v2/config/crypto-policy`. An attacker with write access to the worker's `CRYPTO_POLICY_JSON` KV secret (for example via a compromised wrangler deploy pipeline or a compromised Cloudflare account) can replace the signed blob with any content they choose.

**Attack steps:**

1. Attacker replaces the `CRYPTO_POLICY_JSON` secret with a blob that sets `spkMaxAgeDays: 3650`, `spkExpirationBehavior: "warn"`, `opkExhaustionBehavior.strict: "proceedWithoutDH4"`, `skippedKeyMaxCount: 999999`, and `consumedOPKPruneWindowDays: 1`.
2. Clients fetch the blob. The blob does not carry a valid signature from the offline signing key.
3. `SecurityPolicyStore.parseSignedPolicy` verifies the signature and finds it invalid. The client discards the blob and falls back to the bundled default policy.
4. Alternatively: attacker generates their own Ed25519 keypair, signs a weakened blob with the new key, and replaces both the KV secret and the in-app `CryptoPolicyPublicKeys` array. But changing `CryptoPolicyPublicKeys` requires shipping a new App Store binary — impossible without App Store review.

**What fails without the mitigation.** If policy were served without signatures — as unsigned JSON fetched over HTTPS — a compromised worker or a TLS-terminating attacker could serve arbitrarily weak policy values. Even with HTTPS, Cloudflare itself can read and modify traffic it terminates.

**What the mitigation does.** The signing layer ([spec §5.5](../plans/2026-05-23-relay-crypto-hardening-design.md), [spec §5.6](../plans/2026-05-23-relay-crypto-hardening-design.md), [PR #40](https://github.com/hanfour/peer-drop/pull/40)) ensures every policy blob is signed offline with an Ed25519 key that never touches the worker or source control. The client verifies the signature against public keys baked into the App Store binary before trusting any value in the blob. Additionally, `SecurityPolicyBounds.clamp` enforces hard local ranges on every numeric field regardless of what the blob claims, and the stronger-of-two merge (`SecurityPolicy.merged`) ensures the remote policy can only tighten the bundled default, never loosen it. A compromised worker that serves a weakened blob is doubly defended: the signature check rejects it outright, and even if the signature were somehow valid, the merge would discard any weakening and keep the bundled default value.

**Residual risk.** If the offline signing key itself is compromised, an attacker can produce validly-signed blobs. In this case `SecurityPolicyBounds.clamp` and the stronger-of-two merge with the bundled default are the final defense — they prevent the policy from going below the hard-coded floor values even with a valid signature. The floor values are set conservatively enough that the remaining attack surface (e.g. relaxing `spkMaxAgeDays` from its default of 21 to the maximum allowed value of 90 days) is a significant weakening but not a complete removal of C1 protection. Compromising the offline signing key is treated as a high-severity incident requiring the key rotation procedure documented in `docs/security/crypto-policy-format.md`.

---

## 4. Out of Scope — Deferred to Audit-#15

The following threats are acknowledged but not addressed in v5.4. They are explicitly tracked for audit-#15:

- **Identity-key rotation.** Ed25519 identity keys are generated once at app install and never automatically rotated. A device compromise exposes the identity key for the lifetime of the installation. Audit-#15 will design an opt-in or scheduled rotation mechanism.
- **Post-compromise recovery beyond Double Ratchet.** The Double Ratchet provides "break-in recovery" — a future message from an uncompromised device will re-establish fresh symmetric keys. However, a persistent attacker who maintains continuous access to the device's key material recovers every new ratchet state as it is computed. Long-term device compromise is out of scope.
- **Long-term secret shredding on device loss.** If a device is lost or stolen, all locally-stored key material (session state, identity keys, consumed-OPK set) is accessible to anyone who can unlock the device. Encrypted-at-rest session keys mitigate this partially, but the root iOS device unlock is the ultimate gate. Formal key shredding on device loss (e.g. via remote wipe) is out of scope.

---

## 5. Residual Risk

After the v5.4 hardening package, the following residual risks remain and are accepted for this release:

**Full device compromise yields all keys.** A root-level attacker on the device (jailbreak, physical access with device unlocked, or a zero-click iOS exploit) can read any key material PeerDrop has in memory or in its Keychain group. No application-layer mitigation addresses this; it is an OS-level concern.

**Identity key is long-lived.** There is no automatic rotation of the Ed25519 identity key. A peer who has trusted Alice's identity key continues to trust it indefinitely unless they manually re-pair. If Alice's identity key is compromised, all past sessions whose session-level keys were derived from it are potentially exposed to an attacker who recorded the ciphertext (depending on whether those sessions had DH4 / OPK coverage).

**Worker can observe metadata.** The Cloudflare Worker can see sender and recipient mailbox IDs, message timestamps, and message sizes. It cannot read plaintext, but traffic analysis on the metadata is possible. No traffic analysis resistance is provided in v5.4.

**Bundled public key is a single point of trust.** The `CryptoPolicyPublicKeys` array in `Info.plist` contains the Ed25519 public key(s) that validate policy blobs. Compromise of the corresponding offline private key allows an attacker to sign arbitrary policy blobs. The `SecurityPolicyBounds` hard floor (see Section 3.5) limits how weak a validly-signed policy can be, but does not eliminate the risk entirely. Mitigated by the offline key custody discipline described in Section 2.2 and the rotation procedure in `docs/security/crypto-policy-format.md`.

**Retry-queue persistence.** The C2 retry queue for failed OPK-exhausted initiations is persisted to disk. A sophisticated attacker with read access to the app's container could observe which peer IDs Alice has been trying to contact. This is a metadata leak, not a plaintext leak.
