import { test, expect } from '@playwright/test';

test('wrong password is rejected (401) and never reaches the terminal', async ({ page }) => {
  await page.goto('/login');
  await page.fill('input[name="password"]', 'definitely-not-the-password');

  const [resp] = await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/login') && r.request().method() === 'POST'),
    page.click('button[type="submit"]'),
  ]);

  // Server returns 401 Unauthorized for a bad password.
  expect(resp.status()).toBe(401);

  // No session cookie was issued.
  const cookies = await page.context().cookies();
  expect(cookies.find((c) => c.name === 'webterm-session')).toBeUndefined();

  // The terminal picker is never rendered.
  await expect(page.locator('#picker')).toHaveCount(0);
});

// Regression: POST /logout used to be undone by AuthMiddleware's password-mode
// cookie "slide" re-issuing a valid webterm-session cookie on the same response,
// overriding the handler's Max-Age=0 clear — so Logout did nothing. Fixed by
// skipping the slide on POST /logout; this pins that the cookie is actually cleared.
test('logging out clears the session and returns to the login form', async ({ page }) => {
  // Log in first.
  await page.goto('/login');
  await page.fill('input[name="password"]', 'changeme');
  await page.click('button[type="submit"]');
  await expect(page.locator('#picker')).toBeVisible();
  expect((await page.context().cookies()).find((c) => c.name === 'webterm-session')).toBeDefined();

  // Click the Logout button → app.js POSTs /logout then navigates to /login.
  await page.click('#logout-btn');
  await expect(page.locator('input[name="password"]')).toBeVisible();
  expect(new URL(page.url()).pathname).toBe('/login');

  // Desired behaviour: the session cookie is cleared so the tab is no longer authenticated.
  expect((await page.context().cookies()).find((c) => c.name === 'webterm-session')?.value ?? '').toBe('');
});
