// Shared test credentials. The values must match the miniflare bindings
// declared in vitest.config.mts (which can't import from here — the
// config is evaluated outside the worker test context, so it keeps its
// own literal; a mismatch fails the auth specs immediately and loudly).
export const TEST_TOKEN_SECRET = "test-token-secret-deterministic";
export const TEST_API_KEY = "test-api-key-12345";
export const TEST_ANALYTICS_KEY = "test-analytics-key-67890";
export const TEST_BUNDLE_IDS = ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"];
