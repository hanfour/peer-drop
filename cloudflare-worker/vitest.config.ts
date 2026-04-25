import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          // @cloudflare/vitest-pool-workers requires nodejs_compat for the
          // test runtime; enabling it here keeps production wrangler.toml
          // unchanged (the worker doesn't actually import any node:* APIs).
          compatibilityFlags: ["nodejs_compat"],
          // Override secrets for test runs (real secrets aren't available in CI)
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
      },
    },
  },
});
