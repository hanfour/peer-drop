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

## Reverting a bad ship

If you discover a regression after submission but before approval: see "Need to abort" above. If after approval but before users have updated en masse: ASC supports phased rollout pause, but the lane currently sets `phased_release: false` so the entire userbase gets the update at once. For a true revert you must ship a new version (X.Y.(Z+1)) with the regression fixed.
