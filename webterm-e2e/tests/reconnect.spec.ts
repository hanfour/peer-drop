import { test, expect } from '@playwright/test';
import { loginAndReachPicker, connectShell, typeLine, termText } from './helpers';

// Session survival across a page reload. The tmux session outlives the WebSocket, so
// after reloading (the session cookie persists → still authenticated) reconnecting to
// the same preset must reattach a live terminal whose prior on-screen scrollback is
// redrawn by tmux.
test('shell session survives a page reload (tmux-backed reattach)', async ({ page }) => {
  await loginAndReachPicker(page);
  await connectShell(page);

  const marker = `PERSIST-${Date.now()}`;
  await typeLine(page, `echo ${marker}`);
  await expect.poll(() => termText(page), { timeout: 15_000 }).toContain(marker);

  // Reload — the browser keeps the webterm-session cookie, so we stay logged in.
  await page.reload();
  await expect(page.locator('#picker')).toBeVisible();

  // Reconnect to the still-running tmux session.
  await connectShell(page);

  // tmux redraws the current pane on reattach, so the earlier marker is still visible.
  await expect.poll(() => termText(page), { timeout: 15_000 }).toContain(marker);
});
