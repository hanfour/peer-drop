# Mac App Store IAP Attach

Playwright automation for attaching the three tip-jar IAPs to the inflight Mac App Store version. Used in M4 Task 10.

## Why this exists

App Store Connect has no public API for attaching In-App Purchases to a specific version slot. Spaceship's `submission_information` and deliver's options don't expose an `in_app_purchases` field. The only path is the ASC web UI — and ASC's "App 內購買項目和訂閱項目" / "In-App Purchases and Subscriptions" attach section is fiddly to find consistently. Automating this with Playwright is the same approach v5.3.2 used for the first iOS IAP attach.

## Prerequisites

- macOS or Linux host with Node.js 20+
- The Mac v6.0.0 binary already uploaded via `fastlane release_mac submit:false` (i.e. sitting in `PREPARE_FOR_SUBMISSION`)
- The three tip-jar IAPs already created in ASC at app level (these were created for the iOS Tip Jar in v5.3.1+ and are reused for the Mac platform — same product IDs, same pricing tiers)
- A Web browser the script can launch (`chromium` is downloaded by `npx playwright install`)

## Usage

```bash
cd Scripts/mac-iap-attach
npm install
npx playwright install chromium    # one-time
npx tsx iap-attach-mac.ts
```

The script opens a headed Chromium window pointed at ASC's login page. You sign in interactively (the script never sees or stores your password / 2FA code). After login the script waits for the post-login dashboard to load, then navigates to the v6.0.0 macOS inflight version and ticks the three IAP checkboxes.

## What the script does

1. Opens `https://appstoreconnect.apple.com/login` in a visible browser
2. Pauses for interactive 2FA (you handle this)
3. Detects post-login by watching for the `My Apps` / `我的 App` link
4. Navigates to `https://appstoreconnect.apple.com/apps/6759594513/distribution/macos/version/inflight`
5. Finds the IAP attach section (`App 內購買項目和訂閱項目`)
6. Clicks the selector
7. Ticks: `tip.small`, `tip.medium`, `tip.large`
8. Clicks 完成 / Done
9. Verifies the attach took by reading the IAP rows back

After the script exits, run `fastlane submit_mac_only version:6.0.0 build:1`.

## Failure modes

- **Login times out (5 min default)**: the script waits 5 minutes for the post-login dashboard. If 2FA takes longer than that, restart.
- **Inflight URL 404s**: the macOS version isn't in `PREPARE_FOR_SUBMISSION`. Either `release_mac` failed (check `fastlane check_status_mac`) or you already submitted.
- **IAP attach section not found**: the version was already submitted; the section only shows in `PREPARE_FOR_SUBMISSION`. Or ASC re-themed and the selector changed.
- **One IAP doesn't tick**: a product ID changed. Update `IAP_PRODUCT_IDS` in the script.

## Locale dependency

The script anchors on `text=/我的 App|My Apps/i` for login detection and similar bilingual selectors for the IAP section. If your ASC account is set to ja/ko, add those localised strings to the regex.

## Maintenance

ASC's web UI changes ~once per quarter. When the script breaks:
1. Run with `headless: false` (default) and watch what happens
2. Find the new selectors via Chromium DevTools
3. Update the selector strings in `iap-attach-mac.ts`

The high-level flow (login → inflight URL → IAP section → tick → done) is stable; the selectors drift.
