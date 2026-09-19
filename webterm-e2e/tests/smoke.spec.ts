import { test, expect } from '@playwright/test';
import { loginAndReachPicker, connectShell, typeLine, termText } from './helpers';

test('login with default password → open shell → echo round-trips through xterm', async ({ page }) => {
  await loginAndReachPicker(page);
  await connectShell(page);

  // On desktop (fine pointer) the on-screen key bar must stay hidden.
  await expect(page.locator('#keybar')).toBeHidden();

  const marker = `hello-e2e-${Date.now()}`;
  await typeLine(page, `echo ${marker}`);

  // The command output ("hello-e2e-<ts>") must appear in the live xterm buffer.
  await expect.poll(() => termText(page), { timeout: 15_000 }).toContain(marker);
});
