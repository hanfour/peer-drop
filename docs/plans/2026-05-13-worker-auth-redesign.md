# Worker auth redesign — Phase B of prod-readiness audit

Replaces the bundled `PeerDropWorkerAPIKey` (currently in `Info.plist`,
unzip-and-grep readable from the IPA) and the unauthenticated
`/debug/report` endpoint. Implements per-device tokens issued via Apple
App Attest, tighter CORS, and endpoint risk tiering.

Audit items addressed: 6, 7, 8.

---

## Current state (2026-05-13)

### Endpoint inventory

| Endpoint | Method | Current auth | Tier |
|---|---|---|---|
| `/room` | POST | `X-API-Key` (bundled) | Client-key |
| `/room/:code/ice` | POST | `X-API-Key` (bundled) | Client-key |
| `/room/:code` | WS | `?token=…` (returned by `/room`) | Anonymous-after-room-create |
| `/debug/report` | POST | **none** | **Open** |
| `/debug/metric` | POST | `X-API-Key` (bundled) | Client-key |
| `/config/metrics` | GET | none | Public config |
| `/debug/metrics/stats` | GET | `X-API-Key=ANALYTICS_KEY` | Admin |
| `/debug/reports` | GET | `X-API-Key=API_KEY` | Admin |
| `/v2/keys/register` | POST | self-issued mailbox token | OK (TOFU) |
| `/v2/keys/:mailboxId` | GET | none (consume OTP key) | Anonymous by design |
| `/v2/messages/:mailboxId` | POST | PoW (16-bit) | Anonymous + PoW |
| `/v2/messages` | GET | `X-Mailbox-Id` + `X-Mailbox-Token` | Mailbox-scoped |
| `/v2/mailbox/rotate` | POST | mailbox-scoped | OK |
| `/v2/keys` | DELETE | mailbox-scoped | OK |
| `/v2/inbox/:deviceId` | WS | `X-API-Key` (bundled) | Client-key |
| `/v2/device/register` | POST | `X-API-Key` (bundled) | Client-key |
| `/v2/invite/:deviceId` | POST | `X-API-Key` (bundled) | Client-key |

### CORS

`Access-Control-Allow-Origin: *` everywhere. No browser client exists in
production — purely accommodates ad-hoc admin tooling and was the
default at first commit.

### Bundled API key flow

`project.yml` injects `PEERDROP_WORKER_API_KEY` env var into
`Info.plist` under key `PeerDropWorkerAPIKey`. `WorkerSignaling.bundledAPIKey`
reads that key and ships it to the Worker on every authed call.
`UserDefaults.peerDropWorkerAPIKey` can override per device, but in
practice every shipping build carries the same secret.

### Threat model

The bundled key is a **client secret**, not a server secret. Any attacker
who unzips the IPA — including any user, anyone downloading via 3rd-party
IPA mirrors, or anyone with App Store Connect access — can extract it
and:

- Spam `/room` creating rooms (KV pressure, billing exposure)
- Spam `/debug/metric` filling METRICS KV
- Spam `/v2/device/register` poisoning APNs token mapping
- Spam `/v2/invite/:deviceId` to push-spam any registered device
- Connect inbox WS to any deviceId (passively listen for invites if no
  per-device check exists — needs audit)

`/debug/report` is even worse: no auth at all. Any attacker on the
internet can POST arbitrary JSON of any size, plus the worker writes
the requester's IP and User-Agent to the report — turning the endpoint
into an unauthenticated PII collector that grows KV at attacker speed.

---

## New auth model

### Layer 1 — Device attestation token

Replace the bundled key with a short-lived, per-device bearer token
issued only after Apple App Attest verification.

```
POST /v2/device/attest
  Body: { deviceId, attestation, keyId, clientDataHash }
  → Worker verifies attestation against Apple's attestation cert chain
  → Issues HMAC-signed token (15 min TTL, scope-limited)
  → Returns { token, expiresAt }

POST /v2/device/assert
  Body: { deviceId, assertion, clientData }
  → Worker verifies assertion via the cached App Attest pubkey
  → Issues fresh token
```

Token shape (HMAC-signed):

```
base64(JSON({ deviceId, scope, expires })).base64(HMAC(env.TOKEN_SECRET, body))
```

`scope` lets us issue scoped tokens later (e.g. `mailbox:abc123` for
mailbox-only operations).

**Why App Attest (not DeviceCheck):**

- App Attest binds the token to a Secure Enclave key generated at first
  launch and never exportable. Even rooting the device doesn't leak it.
- DeviceCheck is two-bit per-device flags; not appropriate for auth.
- Alternatives considered:
  - **Static per-install token sealed in Keychain** — works but lacks
    server-side proof the install is genuine; an attacker who reverses
    the iOS code can still mint legitimate-looking tokens.
  - **OAuth-style refresh tokens** — overkill for first-party app; same
    bootstrap problem.

### Layer 2 — Endpoint risk tiering

| Tier | Auth | Endpoints |
|---|---|---|
| **Anonymous** | none | `GET /v2/keys/:id`, `POST /v2/messages/:id` (PoW), `GET /config/metrics`, `WS /room/:code` (room token gate) |
| **Device token** | `Authorization: Bearer <token>` | `POST /room`, `POST /room/:code/ice`, `POST /v2/device/register`, `POST /v2/invite/:id`, `WS /v2/inbox/:id`, `POST /debug/metric`, `POST /debug/report` |
| **Mailbox token** | `X-Mailbox-Id` + `X-Mailbox-Token` | `GET /v2/messages`, `POST /v2/mailbox/rotate`, `DELETE /v2/keys` |
| **Admin** | `X-Admin-Key` | `GET /debug/metrics/stats`, `GET /debug/reports` |

### Layer 3 — CORS

Default `Access-Control-Allow-Origin` to `null` (omit). Allow OPTIONS
only on routes that legitimately need browser callers (none today).
If an admin web dashboard ships later, allowlist its origin explicitly.

### Layer 4 — `/debug/report` hardening

Independent of Layer 1 — can ship today without device tokens:

- Schema allowlist: only `type`, `error`, `context`, `appVersion`,
  `osVersion`, `stackHash` are kept; everything else is dropped.
- Body cap: 8 KB. Larger bodies → 413.
- PII redaction: never store the requester's IP or User-Agent. Replace
  with literal `"redacted"`.
- Retention: 7-day TTL (already in place).

After Layer 1 ships, add device-token auth on top.

### Layer 5 — Migration

The Worker accepts BOTH old `X-API-Key` and new `Authorization: Bearer`
for a transition window. Once a v5.3 ships that uses tokens by default
and the install base has rolled over (say, 30 days), drop the
`X-API-Key` fallback.

Already-shipped v5.0–v5.2 clients carry the bundled key and continue to
work during the window. New installs on v5.3+ use App Attest.

---

## Sub-task breakdown

| # | Subtask | Independent? | Estimate |
|---|---|---|---|
| **B3a** | `/debug/report` schema + cap + PII redaction | yes | 30 min |
| **B2** | CORS tightening | yes (low risk, mostly subtractive) | 30 min |
| **B1a** | Worker `/v2/device/attest` + `/v2/device/assert` + HMAC token | yes | 1 day |
| **B1b** | iOS App Attest integration in `DeviceIdentity` / `WorkerSignaling` | needs B1a | 1 day |
| **B2b** | Worker accepts Bearer token on Layer 2 endpoints (with API_KEY fallback) | needs B1a | half day |
| **B3b** | Add Bearer auth on `/debug/report` | needs B1a + B1b | 15 min |
| **B4** | Tests: token happy path, refresh, anonymous endpoints, debug/report rejects unauthed | needs everything | half day |
| **B5** | Deploy worker + queue iOS v5.3 release | needs B4 | 30 min |

---

## Risks + open decisions

1. **App Attest works only on App Store builds** — TestFlight + production
   yes, dev builds need fallback. Plan: dev builds use a debug-only
   `X-Dev-Token` header bound to a `DEV_TOKEN` env secret on the worker.

2. **Apple attestation verification on Cloudflare Workers** — requires
   X.509 cert chain validation. Web Crypto on workers can do ECDSA
   verification; the App Attest cert chain may need a JS shim (e.g.
   `pkijs`) or we extract the public key during attestation and only
   verify it matches Apple's well-known root.

3. **Token revocation** — HMAC tokens can't be revoked individually.
   Acceptable because of the short TTL (15 min). For "device lost"
   scenarios the existing `DELETE /v2/keys` flow tears down the
   mailbox; we can pair that with `DELETE /v2/device/attest` that
   forgets the cached pubkey.

4. **Backward-compat window length** — proposed 30 days. The audit's
   intent is "no static client secret"; the 30-day window violates
   that briefly. Acceptable trade-off for not stranding v5.0–v5.2 users
   on day 1 of v5.3.

---

## Going first

Ship **B3a + B2** immediately (independent, low-risk, half day total).
This nets:

- `/debug/report` no longer accepts arbitrary bodies / stores PII
- CORS no longer wildcards

Surface that progress, then align on the App Attest specifics before
spending the day on B1a.
