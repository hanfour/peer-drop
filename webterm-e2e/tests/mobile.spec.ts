import { test, expect } from '@playwright/test';
import { loginAndReachPicker, connectShell } from './helpers';

// Runs only under the `mobile-chrome` (Pixel 5) project — hasTouch + isMobile makes
// `(pointer: coarse)` match, which reveals the on-screen key bar.
test('mobile viewport reveals the on-screen key bar with terminal shortcuts', async ({ page }) => {
  await loginAndReachPicker(page);
  await connectShell(page);

  const keybar = page.locator('#keybar');
  await expect(keybar).toBeVisible();

  // Core mobile shortcut keys are present and tappable.
  await expect(page.locator('#keybar [data-seq="esc"]')).toBeVisible();
  await expect(page.locator('#keybar [data-seq="up"]')).toBeVisible();
  await expect(page.locator('#keybar #ctrlkey')).toBeVisible();

  // Tapping a shortcut must not throw / detach the terminal.
  await page.locator('#keybar [data-seq="up"]').click();
  await expect(page.locator('.xterm-rows')).toBeVisible();
});
