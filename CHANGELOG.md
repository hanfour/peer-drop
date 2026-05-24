# Changelog

All notable changes to PeerDrop will be documented in this file. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [5.4.0] — 2026-05-23

### Added — Relay crypto hardening (8-PR series, #37–#44)

- **C1 — SPK timestamp binding** ([#42](https://github.com/hanfour/peer-drop/pull/42)): peer signed-pre-keys now carry a separately-signed Unix-seconds timestamp. Initiators reject expired bundles per `policy.spkMaxAgeDays`.
- **C2 — OPK exhaustion fail-closed** ([#41](https://github.com/hanfour/peer-drop/pull/41)): when a responder is out of one-time pre-keys, v5.4+ initiators now refuse to proceed (instead of silently dropping DH4 forward-secrecy). Failed initiations enqueue to a persistent retry queue with exponential backoff + UI banners.
- **C3 — Skipped-keys LRU + TTL** ([#39](https://github.com/hanfour/peer-drop/pull/39)): Double Ratchet's out-of-order tolerance window now bounded by both count and age. Prevents unbounded memory growth + cache poisoning.
- **C4 — Consumed-OPK set prune** ([#39](https://github.com/hanfour/peer-drop/pull/39)): on-disk `consumedOneTimePreKeyIds` set now pruned to a sliding window. Prevents replay-defense set from growing unbounded. Cross-field invariant: prune window must be ≥ `spkMaxAgeDays × 4`.
- **Crypto agility layer** ([#37](https://github.com/hanfour/peer-drop/pull/37), [#40](https://github.com/hanfour/peer-drop/pull/40)): policy thresholds now fetched from a signed JSON blob served by the worker at `/v2/config/crypto-policy`. Allows tuning without an App Store release. Bundled default = legacy behavior, so first ship of v5.4 is a no-op until the worker policy is upgraded post-launch.
- **`PeerVersion` + per-peer policy plumbing** ([#43](https://github.com/hanfour/peer-drop/pull/43)): every relay envelope tags its protocol generation. Receivers persist the detected version on `TrustedContact`. Legacy peers continue to interop; new C1/C2 enforcement only applies to v5.4↔v5.4 sessions.

### Added — Testing infrastructure

- **CryptoTestKit module** ([#38](https://github.com/hanfour/peer-drop/pull/38)): deterministic property-test harness (SplitMix64 RNG), 65 frozen test vectors (20 X3DH, 30 ratchet, 10 skipped-key, 5 policy), fuzz harness, coverage gate script.

### Documentation

- `docs/security/threat-model-relay.md` — 5 attack trees (bundle replay, OPK exhaustion, skipped-key poisoning, consumed-OPK forgetfulness, policy downgrade) + mitigations + residual risk.
- `docs/security/crypto-policy-format.md` — extended with field reference table, canonical-JSON rules + worked example, 6-week public-key rotation procedure.

### Wire compatibility

v5.4 ↔ v5.0–v5.3.x continues to work unchanged. Two new fields added to relay envelopes (`protocolVersion`) and pre-key bundles (`signedPreKeyTimestamp`, `signedPreKeyTimestampSignature`); all three are optional — synthesized Codable handles absent keys as `nil`, so pre-v5.4 senders and responders continue to interop with v5.4 peers without modification.
