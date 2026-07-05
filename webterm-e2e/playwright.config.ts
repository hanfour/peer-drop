import { defineConfig, devices } from '@playwright/test';

// Fixed localhost port so the Origin/host check (WEBTERM_HOST=localhost) always matches
// what the browser navigates to. Overridable for parallel local runs.
const PORT = Number(process.env.WEBTERM_E2E_PORT ?? 8899);
const BASE_URL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: './tests',
  // The webterm server is a single shared, tmux-backed process — run serially so tests
  // never race over the same `webterm-shell` session.
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: process.env.CI
    ? [['github'], ['html', { open: 'never' }]]
    : [['list']],
  globalSetup: './global-setup.ts',
  globalTeardown: './global-teardown.ts',
  use: {
    baseURL: BASE_URL,
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
      // Desktop project skips the touch-only mobile spec.
      testIgnore: /mobile\.spec\.ts/,
    },
    {
      name: 'mobile-chrome',
      use: { ...devices['Pixel 5'] }, // hasTouch + isMobile → (pointer: coarse) → key bar shows
      testMatch: /mobile\.spec\.ts/,
    },
  ],
  webServer: {
    // Build (fast no-op if already built) then `exec` so Playwright's tree-kill lands on
    // the webterm process directly rather than a lingering `swift run` wrapper.
    command: 'swift build --product webterm && exec .build/debug/webterm',
    cwd: '../PeerDropKit',
    // GET /login is a clean 200 (index "/" 303-redirects to it when logged out).
    url: `${BASE_URL}/login`,
    reuseExistingServer: !process.env.CI,
    timeout: 240_000, // first-time swift build can be slow
    stdout: 'pipe',
    stderr: 'pipe',
    env: {
      WEBTERM_PORT: String(PORT),
      WEBTERM_HOST: 'localhost',
      // No WEBTERM_PASSWORD_HASH → server falls back to the default password "changeme"
      // (prints a WARNING, which is expected).
    },
  },
});
