// v0.16 / vitest v4 migration: `defineWorkersConfig` was removed in
// favor of the standard `defineConfig` from `vitest/config`. The
// previous `test.poolOptions.workers` block moves under the new
// `cloudflareTest()` Vite plugin (which the pool installs to wire up
// miniflare + the `cloudflare:test` virtual module).
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        // @cloudflare/vitest-pool-workers requires nodejs_compat for the
        // test runtime; enabling it here keeps production wrangler.toml
        // unchanged (the worker doesn't actually import any node:* APIs).
        compatibilityFlags: ["nodejs_compat"],
        // Override secrets for test runs (real secrets aren't available in CI).
        bindings: {
          API_KEY: "test-api-key-12345",
          ANALYTICS_KEY: "test-analytics-key-67890",
          TURN_KEY_ID: "",
          TURN_API_TOKEN: "",
          APNS_KEY_P8: "",
          APNS_KEY_ID: "",
          APNS_TEAM_ID: "",
          APNS_BUNDLE_ID: "",
        },
      },
    }),
  ],
});
