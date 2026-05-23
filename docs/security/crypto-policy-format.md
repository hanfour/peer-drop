# crypto-policy wire format

Spec: `docs/plans/2026-05-23-relay-crypto-hardening-design.md` §5.

## Signed-blob shape

(See `cloudflare-worker/bundled-default-policy.signed.json` for a worked example.)

```json
{
  "schemaVersion": 1,
  "issuedAt": <unix-seconds>,
  "expiresAt": <unix-seconds>,
  "policy": { ... },
  "signature": "<base64 Ed25519>"
}
```

The signature is computed over `CanonicalJSON.serialize({schemaVersion, issuedAt, expiresAt, policy})` — sorted keys at every depth, no whitespace, no slash escapes. The Swift implementation lives at `PeerDrop/Security/CanonicalJSON.swift`. The offline signer at `tools/sign-crypto-policy.swift` reproduces it inline.

## Operator workflow

### Update the production policy

1. Edit `cloudflare-worker/bundled-default-policy.json` (or a copy with a different name for a non-default override).
2. Sign:
   ```bash
   swift tools/sign-crypto-policy.swift \
       cloudflare-worker/<your-policy>.json \
       <path-to-production-signing-key.json> \
     > cloudflare-worker/<your-policy>.signed.json
   ```
3. Upload to the worker as the `CRYPTO_POLICY_JSON` secret:
   ```bash
   cat cloudflare-worker/<your-policy>.signed.json | \
     npx wrangler secret put CRYPTO_POLICY_JSON --env production
   ```
4. Verify rollout:
   ```bash
   curl https://peerdrop-signal.hanfourhuang.workers.dev/v2/config/crypto-policy | jq .
   ```

### Roll back

Clear the secret:
```bash
npx wrangler secret delete CRYPTO_POLICY_JSON --env production
```

The worker falls back to the bundled default (the .signed.json file from the most recently deployed worker build). Devices fetch the reverted policy within their 1-hour `max-age` cache window — worst case 1 hour to fully roll back across the install base.

## Signing-key custody

Production signing keys live OFFLINE — never commit them. The dev key at `cloudflare-worker/dev-signing-key.json` is for staging/CI only and is clearly labeled.

Per spec §5.3: bundle 2 public keys in `Info.plist`'s `CryptoPolicyPublicKeys` array during a rotation window (30 days overlap), then drop the old key in a follow-up build.

## Schema versioning

`schemaVersion: 1` is the v5.4 ship version. If a future incompatible change is needed, bump the schema version + ship a build that handles it BEFORE deploying any blob with the new version. The client policy fetcher records `policy.version_unsupported` and falls back to the bundled default when it sees a schema it doesn't know.

## Bundled default regeneration

When the bundled default policy is updated (i.e., `cloudflare-worker/bundled-default-policy.signed.json` is replaced), regenerate the inlined TypeScript constant before deploying:

```bash
cd cloudflare-worker
npm run prebuild
# Then deploy the worker (wrangler picks up the updated src/bundledDefaultPolicy.ts)
npx wrangler deploy
```

The `src/bundledDefaultPolicy.ts` file is auto-generated — do not edit it manually.

---

## Policy field reference

All fields live inside the `"policy"` object of the signed blob. Ground-truth source: `PeerDrop/Security/SecurityPolicy.swift` (struct definition) and `PeerDrop/Security/SecurityPolicyBounds.swift` (local hard ranges).

| Field | Wire key | Type | Default | Allowed range | Description |
|---|---|---|---|---|---|
| SPK max age | `spkMaxAgeDays` | `Int` | `21` | `7…90` | Maximum age in calendar days of a peer's Signed Pre-Key bundle before an initiator considers it expired. Controls C1 enforcement. |
| SPK expiry behavior | `spkExpirationBehavior` | `"warn"` \| `"reject"` | `"warn"` | — | What an initiator does when it encounters an expired SPK. `"warn"` logs a diagnostic and proceeds; `"reject"` refuses to initiate X3DH. Strictness ordering: `reject > warn`. |
| OPK exhaustion behavior (legacy peers) | `opkExhaustionBehavior.legacy` | `"proceedWithoutDH4"` \| `"failClosed"` | `"proceedWithoutDH4"` | — | Behavior when a responder has no OPKs and the session is with a pre-v5.4 peer. `"proceedWithoutDH4"` preserves backward compatibility. |
| OPK exhaustion behavior (v5.4+ peers) | `opkExhaustionBehavior.strict` | `"proceedWithoutDH4"` \| `"failClosed"` | `"failClosed"` | — | Behavior when a responder has no OPKs and the session is with a v5.4+ peer. `"failClosed"` refuses the initiation and queues a retry. Strictness ordering: `failClosed > proceedWithoutDH4`. |
| OPK retry max attempts | `opkRetryMaxAttempts` | `Int` | `5` | `1…20` | Maximum number of times the C2 retry queue will retry a failed OPK-exhausted initiation before giving up and surfacing a permanent error to the UI. |
| OPK retry interval | `opkRetryIntervalSeconds` | `Int` | `60` | `30…600` | Base interval between retry attempts in the C2 queue. This is a pure UX field — the stronger-of-two merge always takes the **local** value; the remote policy cannot change the retry cadence. |
| Skipped-key TTL | `skippedKeyTTLDays` | `Int` | `30` | `1…365` | Maximum age in calendar days of an entry in the Double Ratchet skipped-key cache (C3). Entries older than this are evicted regardless of whether the corresponding message has arrived. Shorter = stricter. |
| Skipped-key max count | `skippedKeyMaxCount` | `Int` | `200` | `50…2000` | Maximum number of entries in the Double Ratchet skipped-key cache (C3). When the limit is reached, the oldest entries are evicted LRU. Smaller = stricter. |
| Consumed-OPK prune window | `consumedOPKPruneWindowDays` | `Int` | `90` | `30…365` | How many days an OPK ID stays in the `consumedOneTimePreKeyIds` set before being pruned (C4). **Cross-field invariant:** must be ≥ `spkMaxAgeDays × 4`; a policy that violates this is rejected and falls back to bundled defaults. Longer = stricter. |

**Wire encoding note.** `opkExhaustionBehavior` is encoded as a nested JSON object with two string fields (`legacy` and `strict`). All other fields are top-level scalars. See the Codable implementation in `SecurityPolicy.swift` (lines ~116–168) for the exact encoding/decoding logic.

**Merge semantics.** When the remote policy is merged with the bundled default via `SecurityPolicy.merged(local:remote:)`, each field uses a strictness-based merge:
- `min()` for fields where smaller is stricter (`spkMaxAgeDays`, `skippedKeyTTLDays`, `skippedKeyMaxCount`)
- `max()` for fields where larger is stricter (`consumedOPKPruneWindowDays`, `opkRetryMaxAttempts`, enum fields)
- Local wins for `opkRetryIntervalSeconds` (pure UX — the remote policy cannot change retry cadence)

The merge ensures the remote policy can only strengthen the bundled default, never weaken it.

---

## Canonical JSON rules

The signed payload is the canonical-JSON serialization of the envelope minus the `"signature"` field. Both the offline signer (`tools/sign-crypto-policy.swift`) and the in-app verifier (`PeerDrop/Security/CanonicalJSON.swift`) must produce byte-identical output for signature verification to succeed.

Rules (conformance: subset of [RFC 8785 / JCS](https://www.rfc-editor.org/rfc/rfc8785)):

1. **Object keys are sorted lexicographically** at every depth, by raw UTF-8 byte value. (The policy schema uses ASCII-only keys, so UTF-8 byte order equals Unicode code-point order.)
2. **No whitespace** anywhere outside string values — no spaces, no newlines, no indentation.
3. **No slash escaping** — forward slashes in string values are left as-is (`/` not `\/`). `JSONSerialization` is called with `.withoutEscapingSlashes`.
4. **UTF-8 encoding** — the canonical bytes are UTF-8. No BOM.
5. **Integers** are encoded without a decimal point (`21`, not `21.0`). The policy schema has no float fields. Floats are rejected by design — `CanonicalJSON.serialize` throws `unsupportedType` for `Double`/`Float` values; the caller must pre-format any float as a string if one is ever added to the schema.
6. **Booleans** are `true`/`false` (lowercase, no quotes).
7. **Arrays** preserve insertion order (not re-sorted).
8. **`null`** is encoded as the JSON literal `null`.

**Worked example.** Given the following input dict (simplified policy envelope):

```json
{
  "policy": { "spkMaxAgeDays": 21, "spkExpirationBehavior": "warn" },
  "schemaVersion": 1,
  "issuedAt": 1716422400,
  "expiresAt": 1748044800
}
```

The canonical output (the bytes fed to Ed25519 sign/verify) is:

```
{"expiresAt":1748044800,"issuedAt":1716422400,"policy":{"spkExpirationBehavior":"warn","spkMaxAgeDays":21},"schemaVersion":1}
```

Note: top-level keys `expiresAt`, `issuedAt`, `policy`, `schemaVersion` are in lexicographic order; within `policy`, `spkExpirationBehavior` sorts before `spkMaxAgeDays`. No spaces, no newlines.

---

## Public-key rotation procedure

The Ed25519 public key(s) bundled in `Info.plist`'s `CryptoPolicyPublicKeys` array are the sole trust roots for policy verification. If the corresponding offline private key needs to be rotated (scheduled renewal, or suspected compromise), follow this procedure. Minimum elapsed time from start to completion: **approximately 6 weeks**, dominated by the App Store review cadence and post-ship soak window.

### Step 1 — Generate the new keypair (offline)

On an air-gapped machine or secure offline environment:

```bash
swift tools/sign-crypto-policy.swift --generate-keypair \
    --out new-signing-key.json
```

This produces a JSON file with `privateKey` (base64) and `publicKey` (base64). Store `new-signing-key.json` according to your offline key custody procedure. **Never commit it to source control.**

Extract the public key:

```bash
jq -r .publicKey new-signing-key.json
# → <base64-encoded 32-byte Ed25519 public key>
```

### Step 2 — Add the new public key to the app binary (overlap window)

Open `PeerDrop/App/Info.plist` and add the new public key to the `CryptoPolicyPublicKeys` array. **Do not remove the old key yet.** The array should now contain both the old and new public keys:

```xml
<key>CryptoPolicyPublicKeys</key>
<array>
    <string><!-- old public key (base64) --></string>
    <string><!-- new public key (base64) --></string>
</array>
```

`SecurityPolicyStore.parseSignedPolicy` accepts a blob signed by **any** key in the array. During the overlap window, both the old and new keys are valid, so policies signed by either key will be accepted.

### Step 3 — Ship the multi-key build via App Store

Submit the updated binary for App Store review in the normal way (`fastlane release`). Review typically takes 1–3 days; allow up to 10 days to be safe. The soak window (95%+ of active users upgrading to the new binary) is approximately 2–4 weeks post-release based on PeerDrop's historical upgrade rate.

**Do not sign any new policy blobs with the new key until the soak window has passed.** Devices still running the old binary trust only the old key; if you switch signing keys before the soak window, those devices will reject every new policy blob and fall back to the bundled default for an extended period.

### Step 4 — Sign future policy updates with the new key only

Once the soak window has passed (approximately 3–4 weeks post-release of the multi-key build):

```bash
swift tools/sign-crypto-policy.swift \
    cloudflare-worker/your-new-policy.json \
    new-signing-key.json \
  > cloudflare-worker/your-new-policy.signed.json
```

Deploy the new signed blob to the worker per the "Operator workflow" section above. Devices running the old binary will reject this blob (signed with the new key only) and fall back to bundled defaults, but by this point fewer than 5% of the install base should still be on the old binary, and they will still receive the previous cached policy (signed with the old key) until it expires.

### Step 5 — Drop the old public key in a follow-up build

After the new-key policy has been live for at least one cache expiry cycle (typically 24–48 hours per device refresh interval), submit a follow-up App Store binary that removes the old public key from `CryptoPolicyPublicKeys`. This closes the overlap window.

**Total rotation timeline:** Generate new keypair (day 0) → Ship multi-key binary (day 1) → App Store approval (day 1–10) → Soak window (day 10–38 approx.) → Switch signing to new key (day 38) → Ship single-key cleanup binary (day 39) → App Store approval (day 39–49).

---

## Bundled default policy

`cloudflare-worker/bundled-default-policy.signed.json` is the reference worked example of a validly-signed policy blob. It is also the policy that ships compiled into the Cloudflare Worker itself (as the inline TypeScript constant in `src/bundledDefaultPolicy.ts`, auto-generated by `npm run prebuild`).

**First-ship activation strategy (spec §8.3).** The bundled default policy at the v5.4 launch is intentionally set to **legacy behavior**: `spkExpirationBehavior: "warn"` (not `"reject"`), `opkExhaustionBehavior.strict: "failClosed"` (C2 is active for v5.4↔v5.4 sessions), and conservative skipped-key and consumed-OPK bounds. This means that v5.4's first ship is a **no-op for existing users** — the observable behavior is identical to v5.3.x until the operator deploys a strict policy via the worker.

Post-launch activation sequence:

1. Monitor 7-day soak metrics per spec §8.6 (policy fetch success rate, policySignatureInvalid rate, OPK exhaustion events).
2. If metrics are healthy, sign and deploy a "strict" policy blob that sets `spkExpirationBehavior: "reject"` and tightens any thresholds that field data suggests should be tighter.
3. The strict policy propagates to devices within 24 hours (the policy refresh interval on success).

This activation strategy means C1's `reject` mode and any future threshold tightening can be enabled or rolled back without a new App Store submission.
