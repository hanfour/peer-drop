# Strict crypto-policy activation plan (2026-07-05)

Closes the last open item of the v5.4 relay-crypto-hardening rollout:
flipping C1 to `spkExpirationBehavior: reject` in production. This doc is
the operator runbook + the sequencing rationale.

## TL;DR

Activation is gated on three things that did **not** exist when the
original "7-day soak then flip" plan was written:

1. **A trustworthy trust root.** The shipped apps (v5.4.0–v5.5.2) bundle
   the *committed dev* public key as `CryptoPolicyPublicKeys`. Signing a
   strict blob with that key is meaningless — the private key is in this
   public repo. The trust root must be swapped to an offline production
   key first.
2. **Real soak data.** The soak "looked clean" only because the telemetry
   pipeline didn't exist (`CryptoHardeningMetrics.snapshot()` had no
   consumer; `/debug/metric` was blackholing; the worker wasn't even
   auto-deploying). All fixed 2026-07-05 (PRs #123, #127, #128), but the
   uploader ships **in the app**, so real data only starts flowing after
   the next iOS release propagates.
3. **The v5.4.1 fuzz + coverage BLOCK items** — satisfied by #125
   (DoubleRatchet 77→98%, X3DH 92→99%, scheduled 100K fuzz CI, soft
   coverage gate).

The key swap and the metrics soak share the **same** next iOS build, so
this is one release, not two.

## Sequence

```
[A] Swap trust root to production key   ── repo prep DONE (this PR);
    │                                       offline keygen + Info.plist
    │                                       swap = operator, at release cut
    ▼
[B] Cut the next iOS release            ── carries: production public key,
    │                                       #127 metrics uploader (already
    │                                       in main), plus batched fixes
    ▼
[C] Soak 2–4 weeks                      ── build propagates + real crypto
    │                                       metrics accumulate in KV
    ▼
[D] Gate on real data                  ── tools/activate-strict-policy.sh
    │                                       (min-snapshots + 3 soak-gate
    │                                       counters ≈0)
    ▼
[E] Sign strict blob + deploy          ── prod key → CRYPTO_POLICY_JSON.
                                            NO new App Store release.
```

## [A] Swap trust root to production (per-release, operator)

Full procedure: `docs/release/release-runbook.md` §"Swapping crypto-policy
keys to production". Summary:

1. **Offline keygen** (air-gapped / not this repo):
   ```bash
   swift -e 'import Foundation; import CryptoKit
   let k = Curve25519.Signing.PrivateKey()
   print("private: " + k.rawRepresentation.base64EncodedString())
   print("public:  " + k.publicKey.rawRepresentation.base64EncodedString())'
   ```
2. Store the **private** key in 1Password (only copy). Note the **public**
   key base64.
3. Set `CryptoPolicyPublicKeys` to a **dual-key overlap** — production key
   FIRST, dev key SECOND (`[prod, dev]`), in `project.yml` and
   `PeerDropMac/App/Info.plist`. This is NOT optional and NOT a naive
   swap-to-prod-only:
   - The worker keeps serving the **dev-signed** bundled default during the
     soak (`CRYPTO_POLICY_JSON` is unset until activation).
   - A prod-**only** build would reject that dev-signed default →
     `policy.signature_invalid` spikes across the fleet during the soak →
     poisons the very gate we need (`signature_invalid == 0`).
   - With `[prod, dev]`, the new build accepts the dev-signed default (dev
     trusted) so the soak stays clean, AND it can accept the prod-signed
     STRICT blob at activation (prod trusted). No re-sign of the bundled
     default is needed now.
4. **Do NOT re-sign the bundled default now** — it stays dev-signed so both
   the new (`[prod,dev]`) and old (`[dev]`) builds accept it through the
   soak. The first prod-signed blob is the STRICT policy, produced by
   `activate-strict-policy.sh` at activation time.
5. `xcodegen generate`, then
   `xcodebuild test -only-testing:PeerDropTests/SignCryptoPolicyToolTests`.

**Closing the dev-key trust root** is a follow-up release (N+1) that drops
the dev key from `CryptoPolicyPublicKeys` once strict is live — by then the
prod-signed policy is what the fleet uses and the overlap window can close.
Until then the dev-key residual risk stays bounded (force-strict DoS only,
via MITM/worker-compromise; `merged()` is stronger-of-two).

## [D]/[E] Activate (post-soak, operator)

`tools/activate-strict-policy.sh` automates the gate + sign + deploy:

```bash
tools/activate-strict-policy.sh \
    --prod-key /path/to/prod-signing-key.json \
    --analytics-key <ANALYTICS_KEY> \
    --min-snapshots 500 \
    --range 7d
    # add --deploy to actually push CRYPTO_POLICY_JSON
```

It **aborts** unless the soak is both healthy and populated:

- `snapshots >= --min-snapshots` — the guard against the empty-bucket
  trap. A near-empty soak is "not enough data", never "clean".
- `policy.signature_invalid == 0` — any non-zero = a client rejected a
  signature (tampering/bug); investigate before touching anything.
- `spkInvalidSignature == 0` and `opkFailedInitiation == 0` — real C1/C2
  failures in production; do **not** flip to reject over them.

The script also refuses to sign with the committed dev key or any key whose
public half isn't in `project.yml`'s `CryptoPolicyPublicKeys` (so a wrong or
un-swapped key can't silently no-op or "activate" with a forgeable root),
and aborts if the stats aggregation was `truncated` (a partial sum could
hide failures in unscanned older buckets).

**Two residual gate limitations (know before you trust the number):**
- The populate gate counts snapshot *rows*, not distinct *devices*, and has
  no soak-*duration* floor — `--min-snapshots` is a proxy for "the uploading
  build has soaked long enough". Confirm the metrics-uploading iOS build has
  actually been live ≥2 weeks before trusting a passing gate. A future worker
  enhancement could return the earliest-snapshot age + a device-cardinality
  estimate to harden this.
- The strict policy (`cloudflare-worker/strict-policy.json`) differs from
the bundled default only in `spkExpirationBehavior: reject`. Everything
else stays at the conservative defaults (C2 `failClosed` is already active
for v5.4↔v5.4). The cross-field invariant `consumedOPKPruneWindowDays (90)
≥ spkMaxAgeDays (21) × 4 = 84` holds. The script regenerates fresh
`issuedAt`/`expiresAt` at sign time (the timestamps committed in the JSON
are placeholders).

## Rollback

`npx wrangler secret delete CRYPTO_POLICY_JSON` — the worker falls back to
the bundled default (legacy/warn). Devices revert within their 1-hour
policy cache window.

## Why not just activate now

Signing with the dev key = security theater (anyone can forge the same).
Activating over an empty/near-empty soak = repeating the exact mistake the
2026-07-03 audit found. Both gates are load-bearing.
