// Types the `env` export from "cloudflare:test" for use in specs.
//
// The task brief for this change specified a `ProvidedEnv` module
// augmentation (the API used by older `@cloudflare/vitest-pool-workers`
// releases):
//
//   declare module "cloudflare:test" {
//     interface ProvidedEnv extends Env {}
//   }
//
// The version installed here (^0.16.4, resolved 0.11.x-series API) does not
// use `ProvidedEnv` — see
// node_modules/@cloudflare/vitest-pool-workers/types/cloudflare-test.d.ts,
// which types `env` directly as `Cloudflare.Env`. That same `Cloudflare.Env`
// ambient namespace is already the file worker-configuration.d.ts (generated
// by `wrangler types`) extends with every existing binding (ROOMS, METRICS,
// SIGNALING_ROOM, ...). Declaring `ProvidedEnv` here would be inert (nothing
// reads it) and would sit alongside that existing mechanism as an unused
// second declaration, so instead we extend the same `Cloudflare.Env`
// declaration `worker-configuration.d.ts` already populates.
declare namespace Cloudflare {
  interface Env {
    ACCOUNTS_DB: D1Database;
  }
}
