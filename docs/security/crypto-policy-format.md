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
