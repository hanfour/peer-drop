# PeerDrop Signaling Worker

Cloudflare Worker that hosts WebRTC signaling, encrypted invite delivery, telemetry ingest, and pre-key storage for PeerDrop.

## Local development

```bash
cd cloudflare-worker
npm install
npx wrangler dev          # local dev server
npx vitest run            # run tests (or ./scripts/run-tests.sh on paths with spaces)
```

## Tests

Tests live in `src/__tests__/` and use [`@cloudflare/vitest-pool-workers`](https://developers.cloudflare.com/workers/testing/vitest-integration/) with miniflare. The harness loads `src/index.ts`, the wrangler config, and overrides the auth secrets to test-only values.

Coverage:

| File | What it locks down |
|------|--------------------|
| `signaling-room.spec.ts` | Capacity (409), token validation (403/404), clientId dedup (v3.2.2 regression), zombie eviction (v3.3.1 regression) |
| `auth.spec.ts` | API-key auth on POST /room, /room/:code/ice, /v2/device/register, /v2/invite, WS /v2/inbox |
| `rate-limit.spec.ts` | 30 req/min per IP cap; per-IP isolation |
| `metric-ingest.spec.ts` | POST /debug/metric — auth, 4 KB cap, JSON validation, required fields, end-to-end aggregation via /debug/metrics/stats |
| `metrics-config.spec.ts` | GET /config/metrics — public access, default values, KV-driven config, fail-open on malformed JSON |

## CI/CD

Deployment is automated via [`.github/workflows/worker-deploy.yml`](../.github/workflows/worker-deploy.yml). On every push to `main` that touches `cloudflare-worker/**`:

1. `test` job runs `npx vitest run` (miniflare-backed DO tests)
2. If green AND the push is to `main`, `deploy` job runs `npx wrangler deploy`

PRs that touch `cloudflare-worker/**` run only the test job — no deploy.

### Required repo secrets

| Secret | Scope | Purpose |
|--------|-------|---------|
| `CLOUDFLARE_API_TOKEN` | Workers + Durable Objects + KV write | Authenticates `wrangler deploy` |
| `CLOUDFLARE_ACCOUNT_ID` | account ID | Tells wrangler which account |

Set both via `gh secret set NAME` or in repo Settings → Secrets and variables → Actions.

## Manual deploy

If CI is unavailable:

```bash
cd cloudflare-worker
npx wrangler deploy
```

Requires `wrangler login` first (interactive).
