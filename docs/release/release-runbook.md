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

---

## M3 Voice Calling Verification (Mac, v6.0)

Bidirectional iPhone ↔ Mac voice calling shipped via PR #(M3). The following matrix MUST be executed manually on real hardware (1 iPhone + 1 Mac, paired first via SAS) before promoting any Mac voice change to production.

### Worker prerequisites

```bash
cd cloudflare-worker
npx wrangler deploy            # ships /v2/call route + per-platform routing
```

The `APNS_BUNDLE_ID_MAC` env binding is optional — the Worker falls back to `com.hanfour.peerdrop.mac` in code if unset. Operators who prefer config-driven topic IDs should:

```bash
# Optional: explicit binding
npx wrangler secret put APNS_BUNDLE_ID_MAC   # paste com.hanfour.peerdrop.mac
```

### Manual test matrix

Per spec §6 lines 290-301. Each row must be ticked before M3 sign-off:

- [ ] iPhone → Mac (Mac foreground): panel appears top-right, Accept → both sides hear audio, mic + end buttons work.
- [ ] iPhone → Mac (Mac sleeping): APNs wakes app → panel appears → Accept → 10s grace window catches SDP → audio established. Log line `Cold-launch push: …` and `In-band SDP arrived…` should both appear in Console.app under subsystem `com.hanfour.peerdrop.mac`.
- [ ] iPhone → Mac (Mac in DND): panel still appears (visual confirm), ringtone silent (audio confirm), Accept → audio works.
- [ ] iPhone → Mac (no answer 30s): panel auto-dismisses, iPhone gets standard "no answer" via CallKit.
- [ ] Mac → iPhone call: iPhone shows CallKit incoming UI → Accept → audio established.
- [ ] Mac active-call window crosses Spaces: switch via Mission Control → call window stays visible (not bound to its origin Space).
- [ ] Mac quits app mid-call: clean teardown on both sides (no half-open SDP, no orphaned NSWindow).

### Known limitations (document in v6.0 reviewer notes)

- **Focus mode opacity**: macOS 14 does not expose Focus mode state to third-party apps. `DNDFilter` reads `UNUserNotificationCenter.notificationSettings()` only; per-Focus configurations (Sleep, custom Focus) are not directly readable.
- **Ringtone dev fallback**: if `Ringtone.caf` is missing from the bundle, `MacRingtonePlayer` falls back to looped `NSSound(named: "Glass")`. The fallback is dev-only — sandboxed shipped builds cannot reliably reference `/System/Library/Sounds/` and the Glass loop may not play. **Ringtone.caf MUST be commissioned + bundled before MAS submission.**
- **PushKit divergence**: iOS retains PushKit (CallKit requirement). macOS uses alert push only. Worker route `/v2/call/:deviceId` reads `device:{id}.platform` to choose APNs topic.

### iOS regression check

iOS unchanged in M3. Smoke test:
- [ ] iPhone ↔ iPhone voice call still works.
- [ ] iOS chat invite push still wakes the app via `/v2/invite/` (Worker route now per-platform; iOS default preserved).

---

## Mac App Store release (v6.0+)

This section covers the **Mac-specific** release flow. The shared parts of the runbook above (reviewer-notes loading, ASC API key setup, abort handling) apply to both platforms — only the lane names and one-time setup differ.

### One-time setup (first Mac ship only)

Before `fastlane release_mac` can succeed end-to-end, three external pieces must be in place. Each takes a few minutes; once done they're idempotent for future Mac releases.

#### 1. Apple Developer portal — Mac App ID capabilities

The Mac bundle `com.hanfour.peerdrop.mac` needs the same App ID capability set as iOS (where applicable) plus Mac-specific entries:

1. https://developer.apple.com/account → Identifiers → click `com.hanfour.peerdrop.mac` (create if absent: macOS App ID, description "PeerDrop for Mac")
2. Enable: App Sandbox, Push Notifications, Bluetooth, Microphone, Networking (multicast)
3. Save

Then regenerate the provisioning profile via fastlane:

```bash
fastlane run get_provisioning_profile \
  app_identifier:com.hanfour.peerdrop.mac \
  platform:macos \
  app_store:true \
  force:true
```

This creates **`com.hanfour.peerdrop.mac AppStore`** in your Apple Developer account and downloads it to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. The name string is what `release_mac` references in its `export_options.provisioningProfiles` dict.

#### 2. App Store Connect — enable macOS platform

ASC needs to know the existing PeerDrop app record (App ID `6759594513`, iOS bundle `com.hanfour.peerdrop`) also serves Mac:

1. https://appstoreconnect.apple.com/apps/6759594513 → general info → **+ Add macOS** → pick bundle `com.hanfour.peerdrop.mac`
2. Fill in Mac-specific app info (category defaults to iOS values; subtitle / promo per `fastlane/metadata/macos/<lang>/`); ASC will auto-populate from the metadata upload on first `release_mac` run
3. Min macOS version: 14.0 (matches `project.yml: MACOSX_DEPLOYMENT_TARGET`)

After this, `fastlane check_status_mac` returns the Mac app metadata instead of `app not found`.

#### 3. Commission `Ringtone.caf`

`MacRingtonePlayer` falls back to looped `NSSound("Glass")` if `Ringtone.caf` is missing from the bundle. The fallback is **dev-only** — sandboxed shipped builds can't reliably reference `/System/Library/Sounds/`. Before MAS ship:

```bash
# Source: CC0 from Freesound, branded recording, or licensed asset
afconvert -d aac -f caff Source.aiff PeerDropMac/Resources/Ringtone.caf
afinfo PeerDropMac/Resources/Ringtone.caf  # verify: AAC, mono 44.1 kHz, ≤6s
```

Commit + push. The next `release_mac` picks it up.

### Per-release flow

Both platforms ship the same version per spec §M4 (M0–M3 was iOS-only at 5.x; v6.0+ is bi-platform). The order matters:

#### Step 1 — Verify both versions bumped

```bash
grep "MARKETING_VERSION" project.yml
# Expect: 6.0.0 for both PeerDrop target and PeerDropMac target
```

If iOS PeerDrop is still on 5.4.x, bump to 6.0.0:

```yaml
# project.yml
PeerDrop:
  settings:
    base:
      MARKETING_VERSION: "6.0.0"   # was "5.4.0"
```

then `xcodegen generate` and commit.

#### Step 2 — Sign + write the v6.0.0 reviewer notes

```bash
# Already at docs/release/v6.0.0-reviewer-notes.md (M4 Task 8).
# Verify the BEGIN_PASTE block is ≤ 4000 chars:
python3 -c "import re; t=open('docs/release/v6.0.0-reviewer-notes.md').read(); m=re.search(r'<!-- BEGIN_PASTE.*?-->(.*?)<!-- END_PASTE -->', t, re.DOTALL); print(len(m.group(1).strip()))"
```

Both `release` and `release_mac` lanes auto-load from this same file.

#### Step 3 — Capture Mac screenshots

```bash
fastlane screenshots_mac
```

Output lands in `fastlane/screenshots_mac/<lang>/`. The `MacSnapshotTests` + `MacSnapshotTestsDark` suites produce 5 captures × 2 appearances × 5 languages = 50 PNGs total.

**Smoke check on a real Mac before submit**: macOS UI tests need the dev provisioning profile installed; if `fastlane screenshots_mac` errors with `No profiles for 'com.hanfour.peerdrop.mac'`, you skipped one-time setup #1.

#### Step 4 — Ship iOS first (`release`)

```bash
fastlane release
```

Standard iOS flow. ~6 min wall-time. Lands in `WAITING_FOR_REVIEW`.

#### Step 5 — Cut Mac binary (no submit yet)

```bash
fastlane release_mac submit:false
```

`submit:false` is required because the Mac IAP tip jar must be re-attached via Playwright (ASC has no API for IAP attachment; this is the v5.3.2 lesson applied to the first Mac ship). After upload, v6.0.0 macOS sits in `PREPARE_FOR_SUBMISSION`.

Verify via `fastlane check_status_mac`.

#### Step 6 — Attach Mac IAPs (Playwright)

```bash
cd Scripts/mac-iap-attach
npm install
npx playwright install chromium    # one-time per host
npx tsx iap-attach-mac.ts
```

The script opens ASC in a visible browser, waits for you to complete 2FA interactively, then navigates to the v6.0.0 macOS inflight version and ticks the three tip-jar IAPs (`tip.small` / `tip.medium` / `tip.large`). See `Scripts/mac-iap-attach/README.md` for failure modes and selector-drift fixes.

ASC web UI fallback if the script breaks: app inflight → `App 內購買項目和訂閱項目` → 選取項目 → check tip.small / tip.medium / tip.large → 完成.

#### Step 7 — Submit Mac

```bash
fastlane submit_mac_only version:6.0.0 build:1
```

Verifies IAP attach didn't get rolled back, builds the review-submission, and flips macOS v6.0.0 from `PREPARE_FOR_SUBMISSION` to `WAITING_FOR_REVIEW`.

Both iOS + Mac now in Apple's review queue.

#### Step 8 — Apple review window

1–2 weeks. Monitor:

```bash
fastlane check_status        # iOS
fastlane check_status_mac    # Mac
```

Status transitions: `WAITING_FOR_REVIEW` → `IN_REVIEW` → either `APPROVED` / `PENDING_DEVELOPER_RELEASE` (automatic_release:false) or `REJECTED`.

#### Step 9 — Release to App Store

**iOS:** the `release` lane defaults to `submit:true`, which sets both `submit_for_review: true` AND `automatic_release: true`. Apple ships iOS automatically on approval — **no `release_now` needed** unless you explicitly ran `fastlane release submit:false` (which you would only do to attach IAPs the v5.3.2 way; v6.0.0 didn't need that on iOS).

**Mac:** `submit_mac_only` intentionally defaults `automatic_release: false` (first Mac ship caution per spec §M4 risk register). v6.0.0 macOS lands in `PENDING_DEVELOPER_RELEASE` and you flip it manually:

```bash
fastlane release_now_mac        # wraps Spaceship's create_app_store_version_release_request with platform: MAC_OS
# Or via web UI: ASC → app inflight → 「發佈此版本」
```

**First Mac ship strategy**: NO phased rollout for v6.0.0. The lane is configured with `phased_release: false` per the spec §M4 risk register — sandbox surprises only surface in shipped builds; we want immediate rollback control rather than a partial-userbase exposure window. v6.1+ can default to phased.

#### Step 10 — MAS-install smoke check

After both platforms are `READY_FOR_SALE`, wait ~30 min for App Store propagation, then install **from the App Store** (not TestFlight) on a clean Mac:

- [ ] iPhone ↔ Mac voice call works (full 7-row matrix from "M3 Voice Calling Verification" above)
- [ ] BLE peer discovery works (sandboxed shipped binaries can hit `NSBluetoothAlwaysUsageDescription` requirements that dev/TF builds miss)
- [ ] Bonjour discovery works on local Wi-Fi
- [ ] APNs push wakes the app from terminated state. **Do not modify the entitlement file** — it ships as `aps-environment = development`. Apple's App Store distribution signing normalises this: the production APNs route is selected by receipt/build provenance, not by the string in the embedded entitlement. Verifying the smoke is "does push wake the app from terminated state, after install from App Store", NOT inspecting the entitlement string. (If a future setup requires the literal `production` string, it'd come from a Release-config xcconfig override — but that override doesn't exist today and isn't needed for MAS distribution.)
- [ ] Microphone permission prompt appears on first call attempt

If failures surface: file a v6.0.1 hotfix at `docs/release/v6.0.1-reviewer-notes.md`, bump `MARKETING_VERSION`, re-run `release_mac` + `submit_mac_only`. The MAS-install smoke exists specifically to catch sandbox surprises BEFORE end users.

### Diagnosing Mac-specific failures

#### `fastlane release_mac` fails with `app not found`

The macOS platform was never enabled on the ASC app record. Do one-time setup #2 above.

#### `fastlane release_mac` fails with `No profiles for 'com.hanfour.peerdrop.mac'`

Mac App Store provisioning profile missing. Re-run one-time setup #1.

#### `fastlane release_mac` fails with `Could not find category 'MZGenre.SocialNetworking'`

(Should not happen — fastlane deliver's `map_category_from_itc` strips the `MZGenre.` prefix and looks up the bare name in a flat map that covers iOS + macOS. If it does happen, the fastlane version may have changed the API; verify against `spaceship/lib/spaceship/connect_api/models/app_category.rb`.)

#### `release_mac` upload succeeds but ASC shows no IAPs attached

The macOS app's IAP attachment must be done via Playwright or the ASC web UI **after** `release_mac submit:false` completes. Spaceship has no IAP-attach API. If you ran `release_mac` with the default `submit:true`, the version is locked at `WAITING_FOR_REVIEW` without IAPs and Apple may reject as Guideline 2.1. Re-run with `submit:false`, attach IAPs, then `submit_mac_only`.

#### Snapshot capture fails with `XCUIKeyboardKeySecondaryFn` error

You're on an older fastlane SnapshotHelper. The current PeerDropMacUITests/SnapshotHelper.swift uses `XCUIKeyboardKey.secondaryFn.rawValue`. If you regenerated the helper from the fastlane template, re-apply the M4 Task 6 fix.

#### `release_mac` succeeds but ASC reports `Notarization rejected`

Mac App Store distribution requires the uploaded `.pkg` to pass Apple's notarization service before it can be added to a version. Notarization typically rejects for:

- **Missing Privacy Manifest entries** — `PrivacyInfo.xcprivacy` doesn't declare a required reason for a privacy-relevant API. Mac-side common offender: `NSPrivacyAccessedAPICategoryFileTimestamp` if you read file mtimes anywhere.
- **Deprecated APIs that Apple no longer accepts** — even if Xcode compiles, the notary may reject (rare).
- **Hardened-runtime + sandbox conflict** — entitlement asks for something the sandbox denies, or vice versa.
- **Broken or expired signing chain** — distribution cert revoked, or a nested binary not signed.

Diagnosis:

```bash
# Find your submission ID
xcrun notarytool history --key fastlane/AuthKey_<keyid>.p8 --key-id <keyid> --issuer <issuer>

# Pull the full log for a specific submission
xcrun notarytool log <submission-uuid> --key fastlane/AuthKey_<keyid>.p8 --key-id <keyid> --issuer <issuer>

# Or check the ASC web UI: app inflight → 「處理中問題」(processing issues)
```

Common fixes:
- Add the missing Privacy Manifest entry; bump build number; re-run `fastlane release_mac submit:false`.
- For hardened-runtime conflicts, audit `PeerDropMac/App/PeerDrop-Mac.entitlements` against the actually-requested capabilities.

### Mac-only files reference

- Project: `PeerDropMac/`, `PeerDropMacUITests/`, `PeerDropMac/App/PeerDrop-Mac.entitlements`, `PeerDropMac/Resources/Ringtone.caf`
- Fastlane: `fastlane/SnapfileMac`, `fastlane/metadata/macos/`, `fastlane/screenshots_mac/`
- Lanes: `release_mac`, `check_status_mac`, `submit_mac_only`, `screenshots_mac`
- Reviewer notes: `docs/release/v6.0.0-reviewer-notes.md` (shared with iOS — both platforms ship same version)
