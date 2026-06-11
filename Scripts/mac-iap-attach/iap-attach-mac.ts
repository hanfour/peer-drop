/**
 * Mac App Store IAP attach via Playwright.
 *
 * ASC has no API for IAP attachment to a version slot — the only path
 * is the web UI. This script automates the click-through:
 *   1. Operator launches; Playwright opens https://appstoreconnect.apple.com/login
 *   2. Operator enters Apple ID + password + 2FA code (interactive — the
 *      script does NOT store credentials)
 *   3. Script navigates to the v6.0.0 macOS inflight version
 *   4. Script ticks the three tip jar IAPs and clicks 完成 (Done)
 *   5. Script exits; operator runs `fastlane submit_mac_only` next
 *
 * Used in M4 Task 10. Predecessor:
 * `fastlane release_mac submit:false` (so v6.0.0 macOS is sitting in
 * PREPARE_FOR_SUBMISSION with the IAP attach section exposed).
 *
 * Usage:
 *   cd scripts/mac-iap-attach
 *   npm install
 *   npx playwright install chromium   # one-time
 *   npx tsx iap-attach-mac.ts
 *
 * The script runs headed (visible browser) so the operator can complete
 * the interactive login. After login the rest is automated.
 */

import { chromium, Page } from "playwright";

const APP_ID = "6759594513";
const VERSION = "6.0.0";
const PLATFORM = "macos";

const IAP_PRODUCT_IDS = [
  "com.hanfour.peerdrop.tip.small",
  "com.hanfour.peerdrop.tip.medium",
  "com.hanfour.peerdrop.tip.large",
];

// ASC's inflight URL pattern for a specific platform.
const INFLIGHT_URL = `https://appstoreconnect.apple.com/apps/${APP_ID}/distribution/${PLATFORM}/version/inflight`;

async function waitForInteractive(page: Page, prompt: string): Promise<void> {
  // The page-based interactive wait: instead of stdin, watch for a
  // selector that only appears post-login.
  console.log(`\n→ ${prompt}\n`);
}

async function main(): Promise<void> {
  const browser = await chromium.launch({ headless: false, slowMo: 100 });
  const context = await browser.newContext({
    locale: "zh-Hant",
    viewport: { width: 1280, height: 800 },
  });
  const page = await context.newPage();

  // Step 1: login (interactive 2FA)
  await page.goto("https://appstoreconnect.apple.com/login");
  await waitForInteractive(
    page,
    "Sign in with your Apple ID + complete 2FA. The script will continue " +
      "automatically once it detects the post-login page."
  );

  // Wait for ASC's main dashboard to appear (post-login marker).
  // ASC's main shell exposes a "My Apps" / "我的 App" link in the header.
  await page.waitForSelector('text=/我的 App|My Apps/i', { timeout: 300_000 });
  console.log("✓ Login detected; navigating to v6.0.0 macOS inflight version");

  // Step 2: navigate to the macOS inflight version
  await page.goto(INFLIGHT_URL);
  await page.waitForLoadState("networkidle");

  // Step 3: find the IAP attach section + open the selector
  // The section heading is "App 內購買項目和訂閱項目" (zh-Hant) or
  // "In-App Purchases and Subscriptions" (en). We anchor by either.
  const iapSection = page.locator(
    'text=/App 內購買項目和訂閱項目|In-App Purchases and Subscriptions/i'
  );
  await iapSection.first().waitFor({ timeout: 60_000 });
  console.log("✓ Found IAP attach section");

  // Click the "選取項目" (Select Items) or equivalent button near the section.
  const selectButton = page.locator(
    'button:has-text("選取項目"), button:has-text("Select")'
  );
  await selectButton.first().click();
  await page.waitForLoadState("networkidle");

  // Step 4: tick each tip jar IAP
  for (const productId of IAP_PRODUCT_IDS) {
    console.log(`  Ticking ${productId}…`);
    const row = page.locator(`tr:has-text("${productId}")`);
    const checkbox = row.locator('input[type="checkbox"]');
    if (!(await checkbox.isChecked().catch(() => false))) {
      await checkbox.click();
    }
  }

  // Step 5: confirm
  const doneButton = page.locator(
    'button:has-text("完成"), button:has-text("Done")'
  );
  await doneButton.first().click();
  console.log("✓ Confirmed selection");

  // Wait for the IAP rows to appear under the version's attach section.
  await page.waitForSelector(
    `text="${IAP_PRODUCT_IDS[0]}"`,
    { timeout: 30_000 }
  );
  console.log(`✓ All ${IAP_PRODUCT_IDS.length} IAPs attached to v${VERSION} (${PLATFORM})`);

  console.log(
    "\nNext step: `fastlane submit_mac_only version:6.0.0 build:1`\n"
  );

  await browser.close();
}

main().catch((err) => {
  console.error("✗ IAP attach failed:", err);
  process.exit(1);
});
