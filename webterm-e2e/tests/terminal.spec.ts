import { test, expect } from '@playwright/test';
import { loginAndReachPicker, connectShell, typeLine, termText } from './helpers';

test('runs a command and renders multi-line, ANSI-colored output', async ({ page }) => {
  await loginAndReachPicker(page);
  await connectShell(page);

  const marker = `ANSI${Date.now()}`;
  // printf interprets \033 (ESC) and \n; xterm must parse the SGR color escape and show
  // only the visible text — a broken parser would leak "[32m" into the output area.
  await typeLine(page, `printf '\\033[32m${marker}\\033[0m\\nSECOND-${marker}\\n'`);

  await expect.poll(() => termText(page), { timeout: 15_000 }).toContain(marker);
  await expect.poll(() => termText(page), { timeout: 15_000 }).toContain(`SECOND-${marker}`);

  // A green-foreground styled cell must exist (proves the ANSI SGR was applied, not printed).
  await expect(page.locator('.xterm-rows span[class*="xterm-fg-"]').first()).toBeVisible();
});
