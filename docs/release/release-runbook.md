# Release Runbook (operator)

Version-agnostic checklist for shipping a PeerDrop App Store release via `fastlane release`. Replaces the per-version runbook files (the v5.0 variant is preserved at `v5.0-submission-runbook.md` as a historical record of the v5.0.0 ship).

---

## Pre-flight checklist

Before running `fastlane release`, confirm in order:

- [ ] **`git checkout main && git pull --ff-only`** — release must always ship from `main` HEAD, never a feature branch or stale checkout.
- [ ] **`git status` is clean** — uncommitted changes will be silently baked into the IPA. The auto-generated `fastlane/README.md` churn can be discarded with `git checkout -- fastlane/README.md`.
- [ ] **`MARKETING_VERSION` in `project.yml` matches the version you intend to ship** — `grep MARKETING_VERSION project.yml`. Both app and widget target lines must agree.
- [ ] **`xcodegen generate` AFTER bumping `MARKETING_VERSION`.** This regenerates `PeerDrop.xcodeproj/project.pbxproj` from `project.yml`. Skipping this step is the #1 way to ship a version mismatch: project.yml says X.Y.Z, pbxproj retains X.Y.(Z-1), gym builds an IPA at X.Y.(Z-1), `upload_to_app_store` rejects with *"versionString has already been used"* because X.Y.(Z-1) is live. **Verify:** `grep MARKETING_VERSION PeerDrop.xcodeproj/project.pbxproj` shows the new version.
- [ ] **Reviewer notes exist** at `docs/release/v<MAJOR.MINOR.PATCH>-reviewer-notes.md` with `<!-- BEGIN_PASTE -->` / `<!-- END_PASTE -->` markers. The lane auto-discovers this file via the `MARKETING_VERSION` regex in `fastlane/Fastfile`.
- [ ] **5-lang release notes exist** at `fastlane/metadata/{en-US,zh-Hant,zh-Hans,ja,ko}/release_notes.txt`. Each file is committed plain text — fastlane uploads them as the version's localized notes.
- [ ] **App Store Connect API key** at `fastlane/api_key.json` (gitignored — confirm it's still on your machine via `ls fastlane/api_key.json`).
- [ ] **Code signing identity is current** — Xcode → Settings → Accounts → Apple ID still signed in, "PeerDrop" team selected, provisioning profile valid.
- [ ] **If this release adds a new App ID capability** (Push Notifications, In-App Purchase, Sign in with Apple, etc.) — see "Adding a new App ID capability" below. v5.3 hit this with `aps-environment`.
- [ ] **v5.4+ ONLY — Crypto-policy public key**: confirm `project.yml`'s `CryptoPolicyPublicKeys` entry is the **production** Ed25519 key, NOT the dev key committed at `cloudflare-worker/dev-signing-key.json`. See "Swapping crypto-policy keys to production" below. v5.4 is the first release that ships with this mechanism — getting this wrong means anyone with repo read access can sign policy blobs that production clients trust.
- [ ] **Optional**: pause iCloud Drive / Time Machine to avoid I/O contention during the build.

---

## Run the release

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"
fastlane release
```

This single command:

1. Reads `MARKETING_VERSION` from `project.yml` → uses for ASC version targeting.
2. Loads reviewer notes from `docs/release/v<version>-reviewer-notes.md` BEGIN_PASTE/END_PASTE block.
3. Builds Release config of `PeerDrop` scheme.
4. Uploads to TestFlight as build 1 (first build for this version).
5. Submits for App Store review with `auto_release: true`, `phased_release: false`. Reviewer notes auto-pasted into ASC's App Review Notes field.

**Expected wall time:** ~6 minutes on this machine for a v5.0.x-shaped patch (smaller diffs = faster build).

---

## Diagnosing failures

### *"versionString has been previously used"*
The IPA's `CFBundleShortVersionString` matches an existing ASC version. Almost always because pbxproj was not regenerated after the `project.yml` bump. Verify:
```bash
grep MARKETING_VERSION project.yml PeerDrop.xcodeproj/project.pbxproj
```
If they disagree: `xcodegen generate`, recommit pbxproj, push, retry.

### Build fails (signing)
Most likely cause: Apple Developer account session expired in Xcode.
```bash
open -a Xcode
# Settings > Accounts > re-sign in to Apple ID
# Confirm "PeerDrop" team is selected and provisioning is current
```

### Build fails: `Provisioning profile "..." doesn't include the X capability`

You added an entitlement (e.g. `aps-environment`) but the App Store provisioning profile on Apple's side hasn't been updated to grant the matching capability. v5.3's Push Notifications add hit this exactly.

See the "Adding a new App ID capability" section below for the full recovery flow. The short version:
```bash
# After enabling the capability on developer.apple.com:
fastlane run get_provisioning_profile \
  app_identifier:"com.hanfour.peerdrop" \
  provisioning_name:"com.hanfour.peerdrop AppStore" \
  force:true api_key_path:"./fastlane/api_key.json"
fastlane run get_provisioning_profile \
  app_identifier:"com.hanfour.peerdrop.widget" \
  provisioning_name:"com.hanfour.peerdrop.widget AppStore" \
  force:true api_key_path:"./fastlane/api_key.json"
# Then retry: fastlane release
```

### Build fails: `No Accounts: Add a new account in Accounts settings`

xcodebuild needs an authenticated Apple identity to refresh provisioning profiles when capabilities change. This used to require an interactive Xcode UI sign-in. As of commit `cbbadc7`, the `release` lane writes the ASC API key to a temp `.p8` and threads `-authenticationKey{ID,IssuerID,Path}` into xcodebuild via `xcargs`, so this should resolve itself — but if it surfaces again, verify `fastlane/api_key.json` is intact and parseable: `python3 -c 'import json; print(json.load(open("fastlane/api_key.json"))["key_id"])'`.

### Upload to TestFlight fails
Check `fastlane/api_key.json` exists and has correct issuer/key contents.
```bash
ls -la fastlane/api_key.json
# If missing, regenerate from App Store Connect → Users and Access → Keys
# Save as fastlane/api_key.json (gitignored).
```

### Reviewer notes not loaded
Check the BEGIN_PASTE/END_PASTE markers in `docs/release/v<version>-reviewer-notes.md` are intact. Lane prints the loaded char count to stdout — should be >100 chars.

### `fastlane diag_versions` says a version slot is taken but `check_status` doesn't show it
ASC sometimes filters draft/intermediate versions out of the standard query. The custom `diag_versions` lane (added 2026-05-11) lists every iOS version unfiltered. Use it when `check_status` looks clean but the upload still rejects.

### Need to abort an in-flight submission
```bash
fastlane check_status   # see current state
```
If WAITING_FOR_REVIEW: go to ASC → My Apps → PeerDrop → version → "Remove from review". If READY_FOR_REVIEW or before: ASC → Reject Binary.

---

## After successful submission

1. **Verify in ASC:** `fastlane check_status` should show the new version as `WAITING_FOR_REVIEW` in the In-Flight section.
2. **Update memory:** edit `MEMORY.md` App Store Status section with submission timestamp + build number.
3. **Update STATUS.md:** mark the new version in `docs/pet-design/ai-brief/STATUS.md` if pet-system relevant.
4. **Wait for review:** Apple typically reviews within 24-48 hours. First-major versions sometimes faster.
5. **On approval:** auto-release fires; new version becomes live within hours.
6. **(Optional smoke test):** install the TestFlight build on a real device before review approval. Step list in `docs/plans/v5.1+-deferred.md` item #10.

---

## Version-specific files

For any given version `X.Y.Z` the release expects:

```
docs/release/vX.Y.Z-reviewer-notes.md       (BEGIN_PASTE/END_PASTE markers)
fastlane/metadata/en-US/release_notes.txt   (rewritten per release)
fastlane/metadata/ja/release_notes.txt
fastlane/metadata/ko/release_notes.txt
fastlane/metadata/zh-Hans/release_notes.txt
fastlane/metadata/zh-Hant/release_notes.txt
```

The metadata files are NOT per-version named — fastlane uses whatever is checked into main at release time. Make sure to overwrite them before each release.

---

## Adding a new App ID capability

A release that introduces a new entitlement (`aps-environment`, `com.apple.developer.in-app-payments`, Sign in with Apple, etc.) requires manual Apple-side prep before `fastlane release` will archive successfully. Skipping this is what burned v5.3's first three release attempts.

### Step 1 — Enable the capability on developer.apple.com

1. Open https://developer.apple.com/account/resources/identifiers
2. Click into `com.hanfour.peerdrop`
3. **Capabilities** section → check the capability you're adding
4. **Save** at the top right → confirm in the modal
5. **Don't touch other capabilities** — disabling something already enabled (iCloud, App Groups, Keychain Sharing) breaks every shipped version that depended on it.
6. If the app uses a widget extension and the capability needs to apply there too, repeat for `com.hanfour.peerdrop.widget`.

### Step 2 — Regenerate the provisioning profile(s)

```bash
fastlane run get_provisioning_profile \
  app_identifier:"com.hanfour.peerdrop" \
  provisioning_name:"com.hanfour.peerdrop AppStore" \
  force:true \
  api_key_path:"./fastlane/api_key.json"

fastlane run get_provisioning_profile \
  app_identifier:"com.hanfour.peerdrop.widget" \
  provisioning_name:"com.hanfour.peerdrop.widget AppStore" \
  force:true \
  api_key_path:"./fastlane/api_key.json"
```

`force:true` is required — without it the action sees the existing local profile and skips. The new profile auto-installs into `~/Library/MobileDevice/Provisioning Profiles/`.

### Step 3 — Update the entitlements file

Add the new key to the right `properties:` block in `project.yml` (NOT directly to `PeerDrop.entitlements` — xcodegen rewrites that file from project.yml on every `xcodegen generate`). Example for `aps-environment`:

```yaml
entitlements:
  path: PeerDrop/App/PeerDrop.entitlements
  properties:
    aps-environment: development   # Apple maps to "production" at archive time
    # ... existing keys ...
```

Then `xcodegen generate` to roll the change into pbxproj + the actual `.entitlements` file.

### Step 4 — Run `fastlane release`

The release lane now (as of `cbbadc7`) threads the ASC API key into xcodebuild via `xcargs`, so `-allowProvisioningUpdates` can actually authenticate and refresh anything that still needs refreshing. No further manual intervention should be needed.

### What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Provisioning profile doesn't include the X capability` | Step 2 not run, or run before Step 1 saved | Re-run Step 2 |
| `No Accounts: Add a new account in Accounts settings` | xcodebuild can't talk to Apple to update provisioning | The release lane handles this since cbbadc7. If it surfaces, verify `fastlane/api_key.json` is intact |
| `Apple App Attestation Root CA` errors during App Attest | App ID `App Attest` capability auto-enabled by Apple for all dev accounts — no Step 1 needed. If `verifyAttestation` fails for other reasons, check team ID + bundle ID match between project.yml and worker's `APP_BUNDLE_ID` / `APP_TEAM_ID` env vars |

---

## Swapping crypto-policy keys to production (v5.4+ only)

The v5.4 crypto-policy mechanism ships with a development Ed25519 keypair at `cloudflare-worker/dev-signing-key.json`. The matching public key is in `project.yml`'s `CryptoPolicyPublicKeys` array and gets baked into `Info.plist`. **Both must be swapped before the v5.4.0 ship**, otherwise anyone with repo read access has signing authority over production policy blobs.

### One-time setup (perform once for the lifetime of the production key)

1. **Generate the production keypair offline** — never in this repo, never on a shared workstation:
   ```bash
   swift -e '
   import Foundation; import CryptoKit
   let k = Curve25519.Signing.PrivateKey()
   print("private: " + k.rawRepresentation.base64EncodedString())
   print("public:  " + k.publicKey.rawRepresentation.base64EncodedString())
   '
   ```
2. **Store the private key in 1Password (or equivalent secret manager)** — note: this is the only copy. Losing it means revoking the matching public key in a follow-up build and re-signing everything.
3. **Note the public key base64** — that's what goes in `project.yml`.

### Pre-ship steps (perform once per release that touches the public-key set)

1. **Edit `project.yml`** — replace the dev public key in `CryptoPolicyPublicKeys` with the production public key. During a key-rotation window, ship BOTH the old and new public keys in the array so the cached blob from before-the-rotation still verifies:
   ```yaml
   CryptoPolicyPublicKeys:
     - <production-public-key-base64>
     # Optional rotation window: keep the previous prod key for 30 days
     # - <previous-production-public-key-base64>
   ```
2. **Re-sign `cloudflare-worker/bundled-default-policy.signed.json`** with the production private key. Save the production private key to a temp file on your workstation (NEVER commit), run:
   ```bash
   # Write the production private key to a temp file (NEVER commit)
   cat > /tmp/prod-signing-key.json <<EOF
   { "private_key_base64": "<prod-private-key-base64>" }
   EOF
   chmod 600 /tmp/prod-signing-key.json

   # Sign
   swift tools/sign-crypto-policy.swift \
       cloudflare-worker/bundled-default-policy.json \
       /tmp/prod-signing-key.json \
     > cloudflare-worker/bundled-default-policy.signed.json

   # Wipe the temp file
   rm /tmp/prod-signing-key.json
   ```
3. **Regenerate the inlined TS constant** so the worker bundle picks up the new signed blob:
   ```bash
   cd cloudflare-worker && npm run prebuild && cd ..
   ```
4. **Run `xcodegen generate`** so `Info.plist` picks up the new public key from `project.yml`.
5. **Verify locally**:
   ```bash
   xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
     -only-testing:PeerDropTests/SignCryptoPolicyToolTests
   ```
   The `test_bundledDefaultSignedBlob_verifiesAgainstBundledPublicKey` test acts as a CI tripwire: it loads the signed blob, reads the bundled `Info.plist` public keys, and verifies — if you swapped the public key but forgot to re-sign (or vice versa), this fails.

### Post-ship — deploy the worker

Only after the IPA is uploaded and accepted by App Store Connect:

```bash
cd cloudflare-worker
npx wrangler deploy --env production
```

If the bundled-default blob is sufficient for v5.4.0 ship, no `CRYPTO_POLICY_JSON` secret is needed yet. Operator overrides can be applied later via `wrangler secret put CRYPTO_POLICY_JSON --env production` per `docs/security/crypto-policy-format.md`.

### Rolling back the public key

If the production private key is lost or compromised:
1. Generate a new keypair (Section "One-time setup" above).
2. Ship a build with the NEW public key in `project.yml` (drop the compromised one entirely — no rotation window since the threat model is "the old key is in attacker hands").
3. Re-sign the bundled-default blob and any worker-served override.
4. The next time clients fetch, the new blob is trusted. Clients still running the previous build only trust the compromised key — they keep working but with whatever policy was last verified. Force-quit / reinstall as needed for high-risk fleets.

---

## Reverting a bad ship

If you discover a regression after submission but before approval: see "Need to abort" above. If after approval but before users have updated en masse: ASC supports phased rollout pause, but the lane currently sets `phased_release: false` so the entire userbase gets the update at once. For a true revert you must ship a new version (X.Y.(Z+1)) with the regression fixed.
