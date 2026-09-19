import { type Page, expect } from '@playwright/test';

export const DEFAULT_PASSWORD = 'changeme';

/**
 * Submit the login form. The browser carries the httpOnly `webterm-csrf` cookie that
 * GET /login set, and the form's hidden `csrf` field mirrors it — the server's
 * double-submit CSRF check passes automatically with no extra wiring on our side.
 */
export async function submitLogin(page: Page, password = DEFAULT_PASSWORD): Promise<void> {
  await page.goto('/login');
  await expect(page.locator('input[name="password"]')).toBeVisible();
  await page.fill('input[name="password"]', password);
  await page.click('button[type="submit"]');
}

/** Log in and wait until the session picker with the built-in "Shell" preset is shown. */
export async function loginAndReachPicker(page: Page, password = DEFAULT_PASSWORD): Promise<void> {
  await submitLogin(page, password);
  // Successful login → 303 to "/" → index.html picker.
  await expect(page.locator('#picker')).toBeVisible();
  await expect(page.locator('.preset', { hasText: 'Shell' })).toBeVisible();
}

/** Normalised text content of the xterm terminal rows (DOM renderer). */
export async function termText(page: Page): Promise<string> {
  const raw = await page.locator('.xterm-rows').innerText();
  return raw.replace(/ /g, ' '); // xterm pads cells with non-breaking spaces
}

/**
 * Click the "Shell" preset, wait for xterm to mount and the WebSocket to deliver the
 * first shell prompt. Waiting for non-empty output before typing avoids losing keystrokes
 * during shell/tmux startup.
 */
export async function connectShell(page: Page): Promise<void> {
  await page.locator('.preset', { hasText: 'Shell' }).click();
  await expect(page.locator('#term')).toBeVisible();
  await expect(page.locator('.xterm-rows')).toBeVisible();
  await expect
    .poll(async () => (await termText(page)).trim().length, { timeout: 15_000 })
    .toBeGreaterThan(0);
}

/** Focus the terminal, type a line and press Enter. */
export async function typeLine(page: Page, line: string): Promise<void> {
  await page.locator('.xterm-screen').click(); // focus xterm's hidden textarea
  await page.keyboard.type(line);
  await page.keyboard.press('Enter');
}
