/**
 * PeerDrop Signaling Worker
 *
 * Lightweight HTTP + WebSocket relay for WebRTC signaling.
 * Uses Durable Objects to ensure both peers in a room share the same isolate.
 *
 * Endpoints:
 *   POST /room           → Create a new room, returns { roomCode }
 *   GET  /room/:code     → Upgrade to WebSocket for signaling (via Durable Object)
 *   POST /room/:code/ice → Generate Cloudflare TURN credentials
 */

import { sendAPNs } from "./apns";
import {
  freshTokenPayload,
  issueToken,
  verifyAppAttestation,
  verifyAppAttestAssertion,
} from "./deviceToken";
import type { TokenPayload } from "./deviceToken";
import { scopeForDevice, accountIdFromScope, generateAccountId, validateNickname, verifyRegistrationSignature, classifyRegisterError, findAccountByHandle } from "./account";

export interface Env {
  // KV
  ROOMS: KVNamespace;
  V2_STORE: KVNamespace;
  METRICS: KVNamespace;
  // Durable Objects
  SIGNALING_ROOM: DurableObjectNamespace;
  PREKEY_STORE: DurableObjectNamespace;
  DEVICE_INBOX: DurableObjectNamespace;
  // D1
  ACCOUNTS_DB: D1Database;
  // Secrets
  TURN_KEY_ID: string;
  TURN_API_TOKEN: string;
  API_KEY: string; // Operator credential (CLI/Debug/Simulator). Rotated 2026-07; no longer ships in store binaries.
  // Client credential for shipped surfaces that cannot do App Attest —
  // today only the native macOS app (DCAppAttestService.isSupported ==
  // false there; verified 2026-09-15 on an M4 / macOS 15.7 dev build).
  // Deliberately SEPARATE from API_KEY so a key extracted from a shipped
  // Mac binary is not the operator credential: it reaches the same /v2
  // relay surfaces the Mac needs, but on /v3 it is restricted to the
  // read/registration routes (see isKeyLane + handleV3). Rotating it
  // requires a Mac release; rotating API_KEY does not.
  // When unset (local dev, vitest) the lane falls back to API_KEY so no
  // extra binding is needed to exercise it.
  MAC_CLIENT_KEY?: string;
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  APNS_BUNDLE_ID_MAC?: string;
  ANALYTICS_KEY: string;
  // Phase B device-token auth. HMAC secret for issuing per-device bearer
  // tokens after App Attest verification (live since 2026-05; see
  // ./appAttest.ts). Set via `wrangler secret put TOKEN_SECRET`.
  TOKEN_SECRET: string;
  // App identifier inputs for App Attest rpIdHash verification.
  APP_BUNDLE_ID?: string;       // "com.hanfour.peerdrop" (legacy single-value input; merged into the list below)
  APP_BUNDLE_IDS?: string;      // comma-separated; default "com.hanfour.peerdrop,com.hanfour.peerdrop.mac"
  APP_TEAM_ID?: string;         // "UK48R5KWLV"
  // Set to "true" to also accept App Attest attestations issued by the
  // development environment (AAGUID = "appattestdevelop"). Production
  // worker should leave this unset / "false" so dev-build attestations
  // never produce real tokens.
  APP_ATTEST_ALLOW_DEV?: string;
  // Operator override for the signed crypto-policy blob served at
  // GET /v2/config/crypto-policy. When set, this value is returned
  // verbatim (e.g. a stricter post-soak policy). When unset, the
  // bundled default (inlined at build time) is served.
  // Set via: cat <policy>.signed.json | wrangler secret put CRYPTO_POLICY_JSON
  CRYPTO_POLICY_JSON?: string;
}

// Room code: 6 chars, alphanumeric excluding ambiguous chars (0/O/1/I/l)
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const ROOM_CODE_LENGTH = 6;
const ROOM_TTL_SECONDS = 600; // 10 minutes
const TURN_TTL_SECONDS = 900; // 15 minutes

// Rate limiting: max requests per (IP, route class) within the window.
//
// NOT exported (2026-09-15): `wrangler dev` builds a local service registry
// from every non-default export of the entry module and requires each entry
// to be a function, a class, or an ExportedHandler — a plain numeric export
// crashes the whole local runtime before it binds a port
// ("Incorrect type for map entry 'RATE_LIMIT_MAX_REQUESTS'"), which blocked
// every local E2E run. Nothing imports these from here (rate-limit.spec.ts
// declares its own copy of the limit it asserts against).
const RATE_LIMIT_WINDOW_MS = 60_000; // 1 minute
const RATE_LIMIT_MAX_REQUESTS = 30;
// KV min TTL is 60s; give the counter key a little slack past the window so it
// survives to the window edge, then self-expires (no cleanup job needed).
const RATE_LIMIT_TTL_SECONDS = 120;

function generateRoomCode(): string {
  const randomBytes = new Uint8Array(ROOM_CODE_LENGTH);
  crypto.getRandomValues(randomBytes);
  const chars: string[] = [];
  for (let i = 0; i < ROOM_CODE_LENGTH; i++) {
    chars.push(ALPHABET[randomBytes[i] % ALPHABET.length]);
  }
  return chars.join("");
}

// Coarse route class for rate-limit bucketing. Keeping separate budgets per
// class (rather than one global counter as the old Map did) means a burst on
// one surface — e.g. message delivery — can't starve unrelated surfaces like
// room creation for the same IP.
export function rateLimitClass(path: string, _method: string): string {
  if (path.startsWith("/v3/")) return "v3";
  if (path.startsWith("/v2/keys")) return "keys";
  if (path.startsWith("/v2/messages")) return "messages";
  if (path.startsWith("/v2/device")) return "device";
  if (path.startsWith("/v2/inbox")) return "inbox";
  if (path.startsWith("/v2/")) return "v2";
  if (path.startsWith("/room")) return "room";
  if (path.startsWith("/debug")) return "debug";
  return "default";
}

// KV key for a rate-limit counter. The IP is already keyed-hashed (never the
// raw IP, mirroring the wslog redaction). Fixed minute-window buckets keep the
// per-key write volume bounded and let KV TTL expire them automatically.
export function rateLimitKey(ipHash: string, routeClass: string, atMs: number): string {
  const windowIndex = Math.floor(atMs / RATE_LIMIT_WINDOW_MS);
  return `rl:${routeClass}:${ipHash}:${windowIndex}`;
}

/**
 * KV-backed, cross-isolate rate limiter. Returns true if the request should be
 * rejected. Counters live in KV (shared across every isolate/colo) instead of
 * a per-isolate in-memory Map, which previously multiplied the effective limit
 * by the isolate count (i.e. effectively unlimited).
 *
 * Notes / trade-offs:
 *   - The header-absent "unknown" IP is NOT limited: it only occurs off-edge
 *     or in tests (Cloudflare always sets CF-Connecting-IP), and a shared
 *     "unknown" bucket would merge unrelated callers.
 *   - KV read-modify-write is not atomic, so under a same-key burst the count
 *     can undercount slightly (last-writer-wins). This is acceptable for a
 *     coarse ~30/min limit and is still a vast improvement over the previous
 *     per-isolate Map. A DO could make it exactly atomic at the cost of a hop
 *     on every request.
 *   - Fail-open on unexpected KV errors: a limiter outage must not take the
 *     whole relay down.
 */
async function isRateLimited(env: Env, ip: string, routeClass: string): Promise<boolean> {
  if (!ip || ip === "unknown") return false;
  try {
    const ipHash = await hashClientIp(ip, env.TOKEN_SECRET);
    const key = rateLimitKey(ipHash, routeClass, Date.now());
    const current = parseInt((await env.ROOMS.get(key)) ?? "0", 10) || 0;
    if (current >= RATE_LIMIT_MAX_REQUESTS) return true;
    await env.ROOMS.put(key, String(current + 1), { expirationTtl: RATE_LIMIT_TTL_SECONDS });
    return false;
  } catch {
    return false; // fail-open on limiter infrastructure errors
  }
}

// CORS headers shared across all responses
// CORS: locked down in B2 of the worker-auth redesign. The iOS app
// (the only production caller) is not a browser and ignores CORS
// entirely. With no admin web dashboard shipping today, an open
// `Access-Control-Allow-Origin: *` purely amplified the attack
// surface: any web page could replay calls bound to the bundled
// API_KEY. Empty headers cause browsers to reject preflight, but
// don't affect server-to-server or native callers.
//
// To re-enable a specific browser origin later (e.g. a future admin
// dashboard), restore the keys here with a single origin instead of
// "*", and gate them behind an `Origin` header check.
const corsHeaders: Record<string, string> = {};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    // Rate limiting (KV-backed, shared across isolates/colos)
    const clientIP = request.headers.get("CF-Connecting-IP") || "unknown";
    if (await isRateLimited(env, clientIP, rateLimitClass(path, request.method))) {
      return new Response(
        JSON.stringify({ error: "Too many requests" }),
        { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json", "Retry-After": "60" } }
      );
    }

    // Authentication for tier-2 endpoints (room creation, ICE creds,
    // device registration, invite delivery, inbox WebSocket).
    //
    // Two permanent lanes (worker-auth redesign §Layer 5, REVISED
    // 2026-07-05 — do NOT remove the key lane):
    //   - `Authorization: Bearer <token>` issued by /v2/device/attest
    //     (store clients — per-device, replay-resistant, 15-min TTL)
    //   - `X-API-Key: <operator key>` for surfaces without App Attest:
    //     peerdrop-cli relay mode, local Debug builds, Simulator runs.
    //     Since the 2026-07 rotation the key no longer ships inside
    //     store binaries; it is an operator credential.
    const requiresAuth = (path === "/room" && request.method === "POST") ||
                          (path.match(/^\/room\/[A-Z0-9]{6}\/ice$/) && request.method === "POST") ||
                          (path === "/v2/device/register" && request.method === "POST") ||
                          (path.match(/^\/v2\/invite\/[a-zA-Z0-9-]{8,64}$/) && request.method === "POST") ||
                          (path.match(/^\/v2\/call\/[a-zA-Z0-9-]{8,64}$/) && request.method === "POST") ||
                          (path.match(/^\/v2\/inbox\/[a-zA-Z0-9-]{8,64}$/) && request.headers.get("Upgrade") === "websocket");
    if (requiresAuth) {
      if (!env.API_KEY) {
        return new Response(
          JSON.stringify({ error: "Server misconfigured: API_KEY not set" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      const authorized = await isRequestAuthorized(request, url, env);
      if (!authorized) {
        return new Response(
          JSON.stringify({ error: "Unauthorized" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    // /v2/inbox/:deviceId ownership binding — a device's Bearer token may
    // only open ITS OWN inbox. Runs only after the requiresAuth gate above
    // has already accepted some credential (Bearer or a key), so a
    // missing/invalid credential still surfaces as 401 there. The
    // `X-API-Key` lane (operator CLI/Debug/Simulator, and the Mac client
    // key) is intentionally exempt — it keeps opening any inbox, matching
    // existing behaviour.
    //
    // NOTE: unlike the /v3 key lane, this exemption does NOT require an
    // `X-Device-Id`, and cannot: this is a WebSocket upgrade, and
    // URLSession's `webSocketTask(with:)` drops custom headers on the
    // upgrade request — the credential itself only reaches us via
    // `?apiKey=`. The inbox path segment is the device id anyway, so a
    // header would be redundant with what the key lane already asserts.
    const inboxOwnershipMatch = path.match(/^\/v2\/inbox\/([a-zA-Z0-9-]{8,64})$/);
    if (inboxOwnershipMatch && request.headers.get("Upgrade") === "websocket") {
      const providedKey = request.headers.get("X-API-Key") || url.searchParams.get("apiKey");
      if (isKeyLane(providedKey, env) === null) {
        const candidate = (request.headers.get("Authorization")?.startsWith("Bearer ")
          ? request.headers.get("Authorization")!.slice(7).trim() : null) ?? url.searchParams.get("token");
        try {
          const { verifyToken } = await import("./deviceToken");
          const payload = await verifyToken(candidate ?? "", env.TOKEN_SECRET);
          if (payload.deviceId !== inboxOwnershipMatch[1]) return jsonResponse({ error: "forbidden" }, 403);
        } catch {
          // Defense-in-depth: unreachable via the public route today, since
          // the requiresAuth gate above already rejected any request with
          // neither a valid Bearer/`?token=` nor a valid X-API-Key with 401.
          return jsonResponse({ error: "Unauthorized" }, 401);
        }
      }
    }

    // POST /room — create a new room
    if (path === "/room" && request.method === "POST") {
      let roomCode: string;
      let attempts = 0;
      do {
        roomCode = generateRoomCode();
        const existing = await env.ROOMS.get(roomCode);
        if (!existing) break;
        attempts++;
      } while (attempts < 10);

      if (attempts >= 10) {
        return new Response(
          JSON.stringify({ error: "Unable to generate unique room code" }),
          { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Generate a room token for WebSocket authentication
      const tokenBytes = new Uint8Array(16);
      crypto.getRandomValues(tokenBytes);
      const roomToken = Array.from(tokenBytes).map(b => b.toString(16).padStart(2, "0")).join("");

      await env.ROOMS.put(roomCode, JSON.stringify({ created: Date.now(), peers: 0, token: roomToken }), {
        expirationTtl: ROOM_TTL_SECONDS,
      });

      return new Response(JSON.stringify({ roomCode, roomToken }), {
        status: 201,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // WebSocket /room/:code?token=xxx — signaling relay (delegated to Durable Object)
    const wsMatch = path.match(/^\/room\/([A-Z0-9]{6})$/);
    if (wsMatch && request.headers.get("Upgrade") === "websocket") {
      const code = wsMatch[1];
      const roomData = await env.ROOMS.get(code);
      if (!roomData) {
        // Diagnostic: log WS upgrade failures (7-day TTL). PII redacted —
        // keyed IP hash only, never the raw IP or User-Agent (#10).
        const logKey = `wslog:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
        await env.ROOMS.put(logKey, JSON.stringify({
          reason: "room_not_found",
          code,
          ipHash: await hashClientIp(clientIP, env.TOKEN_SECRET),
          timestamp: new Date().toISOString(),
        }), { expirationTtl: 7 * 86400 });
        return new Response(JSON.stringify({ error: "Room not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Validate room token
      const roomInfo = JSON.parse(roomData) as { token?: string };
      const providedToken = url.searchParams.get("token");
      if (!providedToken || providedToken !== roomInfo.token) {
        const logKey = `wslog:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
        await env.ROOMS.put(logKey, JSON.stringify({
          reason: "invalid_token",
          code,
          providedToken: providedToken ? `${providedToken.slice(0, 4)}...${providedToken.slice(-4)}` : null,
          expectedTokenHash: roomInfo.token ? `${roomInfo.token.slice(0, 4)}...${roomInfo.token.slice(-4)}` : null,
          ipHash: await hashClientIp(clientIP, env.TOKEN_SECRET),
          timestamp: new Date().toISOString(),
        }), { expirationTtl: 7 * 86400 });
        return new Response(JSON.stringify({ error: "Invalid room token" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Forward to Durable Object — same room code always routes to same instance
      const id = env.SIGNALING_ROOM.idFromName(code);
      const stub = env.SIGNALING_ROOM.get(id);
      const doResponse = await stub.fetch(request);
      // If the DO rejected the upgrade (e.g. 409 room full), log it with body detail.
      if (doResponse.status !== 101) {
        // Clone so we can still return the original to the caller.
        const cloned = doResponse.clone();
        let bodyText = "";
        try { bodyText = await cloned.text(); } catch { /* best effort */ }
        const logKey = `wslog:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
        await env.ROOMS.put(logKey, JSON.stringify({
          reason: "do_rejected_upgrade",
          code,
          doStatus: doResponse.status,
          doBody: bodyText.slice(0, 500),
          clientId: url.searchParams.get("clientId")?.slice(0, 8) || null,
          ipHash: await hashClientIp(clientIP, env.TOKEN_SECRET),
          timestamp: new Date().toISOString(),
        }), { expirationTtl: 7 * 86400 });
      }
      return doResponse;
    }

    // POST /room/:code/ice — generate TURN credentials + return room token
    const iceMatch = path.match(/^\/room\/([A-Z0-9]{6})\/ice$/);
    if (iceMatch && request.method === "POST") {
      const code = iceMatch[1];
      const room = await env.ROOMS.get(code);
      if (!room) {
        return new Response(JSON.stringify({ error: "Room not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const roomInfo = JSON.parse(room) as { token?: string };
      const roomToken = roomInfo.token;

      // Request TURN credentials from Cloudflare API
      if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) {
        // Return STUN-only fallback if TURN is not configured
        return new Response(
          JSON.stringify({
            iceServers: [
              { urls: ["stun:stun.cloudflare.com:3478"] },
              { urls: ["stun:stun.l.google.com:19302"] },
            ],
            roomToken,
          }),
          {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }

      try {
        const turnResponse = await fetch(
          `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${env.TURN_API_TOKEN}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
          }
        );

        if (!turnResponse.ok) {
          throw new Error(`TURN API returned ${turnResponse.status}`);
        }

        const turnData = (await turnResponse.json()) as {
          iceServers: { urls: string[]; username: string; credential: string } | { urls: string[]; username: string; credential: string }[];
        };

        // Cloudflare API returns iceServers as an object; normalize to array
        const rawServers = Array.isArray(turnData.iceServers)
          ? turnData.iceServers
          : [turnData.iceServers];

        // Extract credentials from the first TURN entry (all variants share the same creds)
        const creds = rawServers[0];

        // Reconstruct iceServers with STUN (no auth) + TURN over UDP, TCP, and TLS
        const iceServers = [
          { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] },
          {
            urls: [
              "turn:turn.cloudflare.com:3478?transport=udp",
              "turn:turn.cloudflare.com:3478?transport=tcp",
              "turns:turn.cloudflare.com:5349?transport=tcp",
            ],
            username: creds.username,
            credential: creds.credential,
          },
        ];

        return new Response(JSON.stringify({ iceServers, roomToken }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      } catch (error) {
        // Fallback to STUN only
        return new Response(
          JSON.stringify({
            iceServers: [
              { urls: ["stun:stun.cloudflare.com:3478"] },
              { urls: ["stun:stun.l.google.com:19302"] },
            ],
            roomToken,
          }),
          {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }
    }

    // POST /debug/report — receive error report from app.
    // Hardened in B3a of the worker-auth redesign (docs/plans/
    // 2026-05-13-worker-auth-redesign.md):
    //   - 8 KB body cap (was unbounded; attackers could fill KV with any
    //     size payload)
    //   - Schema allowlist — only the fields we actually display in the
    //     admin reports view survive into KV. Everything else is dropped.
    //   - PII redaction — neither the requester's IP nor User-Agent are
    //     persisted. The "received from a real client" signal was never
    //     used in practice; the trade-off in exposure was bad.
    //   - 7-day retention TTL retained.
    // Bearer-token auth comes in B3b once the App Attest flow lands.
    if (path === "/debug/report" && request.method === "POST") {
      const raw = await request.text();
      if (raw.length > 8 * 1024) {
        return jsonResponse({ error: "Payload too large" }, 413);
      }
      let parsed: Record<string, unknown>;
      try {
        const obj = JSON.parse(raw) as unknown;
        if (!obj || typeof obj !== "object" || Array.isArray(obj)) {
          return jsonResponse({ error: "Expected JSON object" }, 400);
        }
        parsed = obj as Record<string, unknown>;
      } catch {
        return jsonResponse({ error: "Invalid JSON" }, 400);
      }

      // Schema allowlist. Each field is bounded so a single report can't
      // soak the 8 KB envelope all on one string. `stackHash` is expected
      // to arrive already-hashed by the client — we never want raw stack
      // traces in KV.
      const report = {
        type: typeof parsed.type === "string" ? String(parsed.type).slice(0, 32) : "error",
        error: typeof parsed.error === "string" ? String(parsed.error).slice(0, 500) : "",
        context: typeof parsed.context === "string" ? String(parsed.context).slice(0, 200) : undefined,
        appVersion: typeof parsed.appVersion === "string" ? String(parsed.appVersion).slice(0, 32) : "unknown",
        osVersion: typeof parsed.osVersion === "string" ? String(parsed.osVersion).slice(0, 32) : undefined,
        stackHash: typeof parsed.stackHash === "string" ? String(parsed.stackHash).slice(0, 64) : undefined,
        timestamp: new Date().toISOString(),
        // PII intentionally redacted — see comment above.
        ip: "redacted",
        userAgent: "redacted",
      };

      const reportId = `report:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
      await env.ROOMS.put(reportId, JSON.stringify(report), { expirationTtl: 86400 * 7 });
      return jsonResponse({ ok: true, id: reportId }, 201);
    }

    // POST /debug/metric — ingest connection telemetry. Accepts the
    // same credentials as the data-plane routes (App-Attest Bearer OR
    // X-API-Key) but HEADER-ONLY: unlike isRequestAuthorized there is
    // deliberately no `?apiKey=`/`?token=` query lane here — this is a
    // plain POST (no WebSocket-upgrade excuse), and credentials in
    // URLs end up in request logs where they can be replayed.
    //
    // History: this was `requireKey` (X-API-Key ONLY) until 2026-07-05,
    // which 401'd every v5.3+ device whose App Attest succeeded —
    // WorkerAuthHelper prefers Bearer, the client-side "silently drop"
    // policy ate the failures, and production telemetry ingest was a
    // blackhole for ~7 weeks.
    if (path === "/debug/metric" && request.method === "POST") {
      if (!(await isHeaderAuthorized(request, env))) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }
      // Payload size limit: 4 KB
      const body = await request.text();
      if (body.length > 4 * 1024) {
        return jsonResponse({ error: "Payload too large" }, 413);
      }
      let parsed: Record<string, unknown>;
      try {
        const raw = JSON.parse(body) as unknown;
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
          return jsonResponse({ error: "Expected JSON object" }, 400);
        }
        parsed = raw as Record<string, unknown>;
      } catch {
        return jsonResponse({ error: "Invalid JSON" }, 400);
      }
      // Require expected metric fields so leaked API_KEY can't flood KV with arbitrary blobs.
      if (typeof parsed["connectionType"] !== "string" ||
          typeof parsed["role"] !== "string" ||
          typeof parsed["outcome"] !== "object" && typeof parsed["outcome"] !== "string") {
        return jsonResponse({ error: "Missing required metric fields" }, 400);
      }
      const dateKey = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
      const metricId = `metric:${dateKey}:${crypto.randomUUID()}`;
      // Store aggregation-friendly summary in KV metadata so stats endpoint
      // can aggregate from list() results without individual get() calls.
      const summary = {
        ct: String(parsed["connectionType"] ?? "unknown"),
        o: String((parsed["outcome"] as any)?.type ?? parsed["outcome"] ?? "unknown"),
        d: typeof parsed["durationMs"] === "number" ? parsed["durationMs"] : null,
        cu: (parsed["iceStats"] as any)?.candidatesUsed ?? null,
        fr: (parsed["outcome"] as any)?.reason ?? null,
      };
      await env.METRICS.put(metricId, JSON.stringify({
        ...parsed,
        ingestedAt: new Date().toISOString(),
      }), { expirationTtl: 14 * 86400, metadata: summary });
      return jsonResponse({ ok: true, id: metricId }, 201);
    }

    // POST /debug/crypto-metric — ingest a CryptoHardeningMetrics snapshot
    // for the v5.4 crypto-hardening soak (spec §8.6). Header-only auth
    // (same rationale as /debug/metric: no `?apiKey=` lane on a plain POST).
    // The soak-gate counters are copied into KV metadata so the stats
    // endpoint aggregates from list() without per-key gets.
    if (path === "/debug/crypto-metric" && request.method === "POST") {
      if (!(await isHeaderAuthorized(request, env))) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }
      const body = await request.text();
      // 8 KB cap: the payload's keyedCounters is bounded (≤23 kinds ×
      // small PeerVersion enum ≈ 70 entries ≈ 5 KB worst case), so 8 KB
      // never rejects a legitimate snapshot. The prior 2 KB cap 413'd the
      // busiest multi-peer devices — exactly the ones most likely to hold a
      // non-zero error counter — and the client's retry-on-non-2xx turned
      // that into a permanent loop, silently dropping their error signals
      // from the soak (the dangerous undercount direction).
      if (body.length > 8 * 1024) {
        return jsonResponse({ error: "Payload too large" }, 413);
      }
      let parsed: Record<string, unknown>;
      try {
        const raw = JSON.parse(body) as unknown;
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
          return jsonResponse({ error: "Expected JSON object" }, 400);
        }
        parsed = raw as Record<string, unknown>;
      } catch {
        return jsonResponse({ error: "Invalid JSON" }, 400);
      }
      // Require a `counters` object so a leaked key can't flood KV with junk.
      const counters = parsed["counters"];
      if (!counters || typeof counters !== "object" || Array.isArray(counters)) {
        return jsonResponse({ error: "Missing required `counters` object" }, 400);
      }
      const c = counters as Record<string, unknown>;
      // Clamp to a non-negative integer. Counters are monotonic tallies —
      // a negative or fractional value can only come from a hostile or
      // buggy client, and an unclamped negative in a soak-gate counter
      // would let ONE authenticated device drive the fleet-wide error sum
      // down and mask real failures (premature strict-policy activation).
      const num = (k: string): number => {
        const v = c[k];
        return typeof v === "number" && Number.isFinite(v) ? Math.max(0, Math.floor(v)) : 0;
      };
      // Soak-gate summary (spec §8.6): the three counters that must stay ≈0
      // before strict C1/C2 policy activation. Kept small for KV metadata.
      const soakSummary = {
        isig: num("c1.spk_timestamp_invalid_signature"),
        ofail: num("c2.opk_failed_initiation"),
        psig: num("policy.signature_invalid"),
      };
      const dateKey = new Date().toISOString().slice(0, 10);
      const id = `cryptometric:${dateKey}:${crypto.randomUUID()}`;
      // 31-day TTL so the stats endpoint's range=30d window is fully backed
      // by data (14 days used to expire days 15–30 into a silent undercount).
      await env.METRICS.put(id, JSON.stringify({ ...parsed, ingestedAt: new Date().toISOString() }),
        { expirationTtl: 31 * 86400, metadata: soakSummary });
      return jsonResponse({ ok: true, id }, 201);
    }

    // GET /debug/crypto-metrics/stats?range=24h|7d|30d — soak aggregation
    // (ANALYTICS_KEY). Sums the three soak-gate counters + snapshot count
    // across the window, so strict-policy activation can be gated on real
    // production numbers instead of the empty bucket the soak read before.
    if (path === "/debug/crypto-metrics/stats" && request.method === "GET") {
      const unauth = requireKey(request, env, "ANALYTICS_KEY");
      if (unauth) return unauth;

      const VALID_RANGES = new Set(["24h", "7d", "30d"]);
      const range = url.searchParams.get("range") ?? "24h";
      if (!VALID_RANGES.has(range)) {
        return jsonResponse({ error: "range must be one of 24h|7d|30d" }, 400);
      }
      // Keys are bucketed by UTC calendar day, but the window is a rolling
      // duration. Scan ONE EXTRA day-bucket so the trailing edge (e.g. a
      // 24h query at 01:00Z that must still see yesterday-evening events) is
      // fully covered. This over-scans by up to 24h — the SAFE direction:
      // it can only over-count error signals (delaying strict activation),
      // never undercount them (which could green-light a fail-closed policy
      // while production failures exist).
      const windowDays = range === "7d" ? 7 : range === "30d" ? 30 : 1;
      const daysBack = windowDays + 1;
      const SNAPSHOT_CAP = 20000;

      type Soak = { isig: number; ofail: number; psig: number };
      let snapshots = 0;
      let spkInvalidSignature = 0, opkFailedInitiation = 0, policySignatureInvalid = 0;
      let truncated = false;

      try {
        outer: for (let i = 0; i < daysBack; i++) {
          const d = new Date(Date.now() - i * 86400_000);
          const prefix = `cryptometric:${d.toISOString().slice(0, 10)}:`;
          let cursor: string | undefined;
          do {
            const list = await env.METRICS.list({ prefix, limit: 1000, cursor });
            for (const key of list.keys) {
              if (!key.name.startsWith(prefix)) continue;
              if (snapshots >= SNAPSHOT_CAP) { truncated = true; break outer; }
              // Every crypto-metric key is written WITH metadata at ingest
              // (unlike legacy /debug/metric entries), so `meta` is present
              // by construction — no per-key value fetch needed and the sum
              // can't undercount from missing metadata.
              const meta = key.metadata as Soak | null | undefined;
              if (meta) {
                spkInvalidSignature += meta.isig ?? 0;
                opkFailedInitiation += meta.ofail ?? 0;
                policySignatureInvalid += meta.psig ?? 0;
              }
              snapshots++;
            }
            cursor = list.list_complete ? undefined : list.cursor;
          } while (cursor);
        }
      } catch (e) {
        return jsonResponse({ error: "aggregation_failed", detail: String(e).slice(0, 200) }, 500);
      }

      return jsonResponse({
        range,
        snapshots,
        truncated,
        soak: { spkInvalidSignature, opkFailedInitiation, policySignatureInvalid },
      });
    }

    // GET /config/metrics — remote circuit breaker (public, no auth).
    // Fail-open: malformed KV JSON falls through to the default so clients
    // keep polling a usable shape even if an operator botches `wrangler kv put`.
    if (path === "/config/metrics" && request.method === "GET") {
      const raw = await env.METRICS.get("config:metrics");
      let parsed: { sampleRate: number; enabled: boolean } = { sampleRate: 1.0, enabled: true };
      if (raw) {
        try { parsed = JSON.parse(raw); }
        catch (e) { console.error("Bad config:metrics JSON, serving default:", e); }
      }
      return jsonResponse(parsed);
    }

    // GET /debug/metrics/stats?range=24h|7d|30d — aggregate metrics (ANALYTICS_KEY required)
    if (path === "/debug/metrics/stats" && request.method === "GET") {
      const unauth = requireKey(request, env, "ANALYTICS_KEY");
      if (unauth) return unauth;

      const VALID_RANGES = new Set(["24h", "7d", "30d"]);
      const range = url.searchParams.get("range") ?? "24h";
      if (!VALID_RANGES.has(range)) {
        return jsonResponse({ error: "range must be one of 24h|7d|30d" }, 400);
      }
      const daysBack = range === "7d" ? 7 : range === "30d" ? 30 : 1;
      const METRIC_CAP = 5000;

      const prefixes: string[] = [];
      for (let i = 0; i < daysBack; i++) {
        const d = new Date(Date.now() - i * 86400_000);
        prefixes.push(`metric:${d.toISOString().slice(0, 10)}:`);
      }

      // Collect metrics from list metadata — no individual gets needed.
      // Legacy entries without metadata are fetched individually (fallback).
      type MetaSummary = { ct: string; o: string; d: number | null; cu: string | null; fr: string | null };
      const entries: MetaSummary[] = [];
      let keysScanned = 0;
      let truncated = false;
      let legacyFetches = 0;

      try {
        outer: for (const prefix of prefixes) {
          let cursor: string | undefined;
          do {
            const list = await env.METRICS.list({ prefix, limit: 1000, cursor });
            for (const key of list.keys) {
              if (!key.name.startsWith(prefix)) continue; // defence-in-depth
              keysScanned++;
              if (entries.length >= METRIC_CAP) { truncated = true; break outer; }
              const meta = key.metadata as MetaSummary | null | undefined;
              if (meta && typeof meta.ct === "string") {
                entries.push(meta);
              } else {
                // Fallback: legacy entry written before metadata was added
                legacyFetches++;
                const raw = await env.METRICS.get(key.name);
                if (!raw) continue;
                try {
                  const m = JSON.parse(raw) as Record<string, unknown>;
                  const outcomeField = m["outcome"];
                  entries.push({
                    ct: String(m["connectionType"] ?? "unknown"),
                    o: String(typeof outcomeField === "object" && outcomeField !== null
                      ? (outcomeField as any)["type"] ?? "unknown"
                      : outcomeField ?? "unknown"),
                    d: typeof m["durationMs"] === "number" ? m["durationMs"] as number : null,
                    cu: (typeof m["iceStats"] === "object" && m["iceStats"] !== null
                      ? (m["iceStats"] as any)["candidatesUsed"] : null) ?? null,
                    fr: (typeof outcomeField === "object" && outcomeField !== null
                      ? (outcomeField as any)["reason"] : null) ?? null,
                  });
                } catch { /* skip corrupt entry */ }
              }
            }
            cursor = list.list_complete ? undefined : list.cursor;
            if (entries.length >= METRIC_CAP) { truncated = true; break outer; }
          } while (cursor);
        }
      } catch (e) {
        return jsonResponse({
          error: "aggregation_failed",
          detail: String(e).slice(0, 200),
          partial: entries.length,
        }, 503);
      }

      // Aggregate from metadata summaries.
      // Response contract: stats.byType[connectionType] = { success, failure, abandoned, p50, p95 }
      // Keep keys stable — consumed by ops dashboard.
      const byType: Record<string, { success: number; failure: number; abandoned: number; durations: number[] }> = {};
      const candidateUse: Record<string, number> = {};
      const failureReasons: Record<string, number> = {};
      for (const m of entries) {
        const t = m.ct || "unknown";
        byType[t] ??= { success: 0, failure: 0, abandoned: 0, durations: [] };
        if (m.o === "success") byType[t].success++;
        else if (m.o === "abandoned") byType[t].abandoned++;
        else byType[t].failure++;
        if (typeof m.d === "number") byType[t].durations.push(m.d);
        if (m.cu) candidateUse[m.cu] = (candidateUse[m.cu] ?? 0) + 1;
        if (m.fr) failureReasons[m.fr] = (failureReasons[m.fr] ?? 0) + 1;
      }

      const stats = {
        range,
        total: entries.length,
        keysScanned,
        truncated,
        legacyFetches,
        byType: Object.fromEntries(Object.entries(byType).map(([k, v]) => {
          const d = v.durations.slice().sort((a, b) => a - b);
          return [k, {
            success: v.success,
            failure: v.failure,
            abandoned: v.abandoned,
            p50: d.length ? d[Math.floor(d.length * 0.5)] : null,
            p95: d.length ? d[Math.floor(d.length * 0.95)] : null,
          }];
        })),
        candidateUse,
        failureReasons,
      };
      return jsonResponse(stats);
    }

    // GET /debug/reports — fetch recent error reports (requires API key)
    if (path === "/debug/reports" && request.method === "GET") {
      if (!env.API_KEY || request.headers.get("X-API-Key") !== env.API_KEY) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const list = await env.ROOMS.list({ prefix: "report:" });
      const reports = [];
      for (const key of list.keys) {
        const data = await env.ROOMS.get(key.name);
        if (data) reports.push({ id: key.name, ...JSON.parse(data) });
      }
      reports.sort((a: any, b: any) => b.timestamp?.localeCompare(a.timestamp || "") || 0);
      return new Response(JSON.stringify(reports, null, 2), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ===================================================================
    // v2 API: Pre-Key Server & Anonymous Mailbox
    // Zero-knowledge relay — no logging of content, IPs, or relationships
    // ===================================================================

    // POST /v2/device/challenge — issue a server-side challenge nonce
    // for the App Attest flow. iOS calls this immediately before
    // /v2/device/attest so the attestation is tied to a value the
    // server controls (replay defense). 32 random bytes, 5-minute TTL,
    // single-use — the /attest handler pulls + deletes the entry.
    if (path === "/v2/device/challenge" && request.method === "POST") {
      const body = await request.json().catch(() => null) as { deviceId?: string } | null;
      if (!body?.deviceId) return jsonResponse({ error: "Missing deviceId" }, 400);
      if (!/^[a-zA-Z0-9-]{8,64}$/.test(body.deviceId)) {
        return jsonResponse({ error: "Invalid deviceId format" }, 400);
      }
      const challengeBytes = new Uint8Array(32);
      crypto.getRandomValues(challengeBytes);
      const challengeB64 = arrayBufferToBase64(challengeBytes);
      await env.V2_STORE.put(
        `challenge:${body.deviceId}`,
        challengeB64,
        { expirationTtl: 5 * 60 },
      );
      return jsonResponse({ challenge: challengeB64 }, 201);
    }

    // POST /v2/device/attest — register a new device via Apple App Attest.
    // Runs the full pkijs attestation-chain verification (./appAttest.ts):
    // returns a short-lived bearer token + caches the device's public
    // key for subsequent /v2/device/assert calls. Invalid attestations
    // get 400 with the verifier's reason.
    if (path === "/v2/device/attest" && request.method === "POST") {
      if (!env.TOKEN_SECRET) {
        return jsonResponse({ error: "Server misconfigured: TOKEN_SECRET not set" }, 500);
      }
      const body = await request.json().catch(() => null) as {
        deviceId?: string;
        attestation?: string;       // base64
        keyId?: string;
        challenge?: string;          // base64
      } | null;
      if (!body || !body.deviceId || !body.attestation || !body.keyId || !body.challenge) {
        return jsonResponse({ error: "Missing fields" }, 400);
      }
      if (!/^[a-zA-Z0-9-]{8,64}$/.test(body.deviceId)) {
        return jsonResponse({ error: "Invalid deviceId format" }, 400);
      }

      // Replay defense: the supplied challenge must match the server-
      // issued nonce we stored at /v2/device/challenge time. Pull-and-
      // delete so the same nonce can't satisfy two attestations.
      const storedChallenge = await env.V2_STORE.get(`challenge:${body.deviceId}`);
      if (!storedChallenge || storedChallenge !== body.challenge) {
        return jsonResponse({ error: "Challenge expired or not issued" }, 400);
      }
      await env.V2_STORE.delete(`challenge:${body.deviceId}`);

      // App Attest's clientDataHash is SHA-256(serverChallenge). The
      // verifier expects that hash as its `challenge` input — recompute
      // here from the raw bytes we just confirmed match.
      const challengeBytes = base64Decode(body.challenge);
      const clientDataHash = new Uint8Array(
        await crypto.subtle.digest("SHA-256", challengeBytes.buffer.slice(challengeBytes.byteOffset, challengeBytes.byteOffset + challengeBytes.byteLength) as ArrayBuffer),
      );

      try {
        const result = await verifyAppAttestation({
          attestation: base64Decode(body.attestation),
          challenge: clientDataHash,
          keyId: base64Decode(body.keyId),
          bundleIdentifiers: configuredBundleIds(env),
          teamIdentifier: env.APP_TEAM_ID ?? "UK48R5KWLV",
          allowDevelopmentEnvironment: env.APP_ATTEST_ALLOW_DEV === "true",
        });
        // Cache device-pubkey + counter for later assert calls. Pin the
        // bundle id that matched so a later /assert verifies against the
        // same app (rather than re-widening to the whole configured set).
        await env.V2_STORE.put(
          `attest:${body.deviceId}`,
          JSON.stringify({
            keyId: body.keyId,
            publicKeyDer: arrayBufferToBase64(result.publicKeyDer),
            receipt: arrayBufferToBase64(result.receipt),
            counter: 0,
            attestedAt: Date.now(),
            bundleId: result.bundleIdentifier,
          }),
          { expirationTtl: 90 * 86400 },
        );
        const token = await issueToken(freshTokenPayload(body.deviceId, await scopeForDevice(env.ACCOUNTS_DB, body.deviceId)), env.TOKEN_SECRET);
        return jsonResponse({ token, expiresInSeconds: 15 * 60 }, 201);
      } catch (err) {
        return jsonResponse({ error: String((err as Error).message) }, 400);
      }
    }

    // POST /v2/device/assert — refresh the bearer token by proving the
    // device still controls the Secure Enclave keypair registered at
    // /v2/device/attest time. Verifies the ECDSA assertion signature +
    // strictly-increasing counter against the cached public key.
    if (path === "/v2/device/assert" && request.method === "POST") {
      if (!env.TOKEN_SECRET) {
        return jsonResponse({ error: "Server misconfigured: TOKEN_SECRET not set" }, 500);
      }
      const body = await request.json().catch(() => null) as {
        deviceId?: string;
        assertion?: string;     // base64
        clientData?: string;    // base64
      } | null;
      if (!body || !body.deviceId || !body.assertion || !body.clientData) {
        return jsonResponse({ error: "Missing fields" }, 400);
      }
      const cached = await env.V2_STORE.get(`attest:${body.deviceId}`);
      if (!cached) {
        return jsonResponse({ error: "Device not attested" }, 404);
      }
      const meta = JSON.parse(cached) as {
        publicKeyDer: string;
        counter: number;
        bundleId?: string;
      };
      try {
        const result = await verifyAppAttestAssertion({
          assertion: base64Decode(body.assertion),
          clientData: base64Decode(body.clientData),
          publicKeyDer: base64Decode(meta.publicKeyDer),
          previousCounter: meta.counter,
          // Pre-existing records (attested before this field was added)
          // have no `bundleId` — fall back to the full configured set so
          // those devices aren't locked out.
          bundleIdentifiers: meta.bundleId ? [meta.bundleId] : configuredBundleIds(env),
          teamIdentifier: env.APP_TEAM_ID ?? "UK48R5KWLV",
        });
        await env.V2_STORE.put(
          `attest:${body.deviceId}`,
          JSON.stringify({ ...JSON.parse(cached), counter: result.newCounter }),
          { expirationTtl: 90 * 86400 },
        );
        const token = await issueToken(freshTokenPayload(body.deviceId, await scopeForDevice(env.ACCOUNTS_DB, body.deviceId)), env.TOKEN_SECRET);
        return jsonResponse({ token, expiresInSeconds: 15 * 60 }, 200);
      } catch (err) {
        return jsonResponse({ error: String((err as Error).message) }, 400);
      }
    }

    // POST /v2/keys/register — Upload device's public key bundle
    if (path === "/v2/keys/register" && request.method === "POST") {
      const body = await request.json() as { mailboxId?: string; preKeyBundle?: unknown; token?: string };
      if (!body.mailboxId || !body.preKeyBundle) {
        return jsonResponse({ error: "Missing mailboxId or preKeyBundle" }, 400);
      }

      // Rate limiting is handled globally at the top of fetch() (route class
      // "keys"), which is KV-backed and shared across isolates — no separate
      // per-handler limiter needed here.

      // Generate mailbox token if first registration.
      //
      // Re-registration REQUIRES the mailbox token (2026-09-15): the check
      // used to be `if (body.token && body.token !== meta.token)`, so a
      // caller that simply OMITTED `token` sailed past it and could
      // overwrite any known mailbox's pre-key bundle — an unauthenticated
      // key-substitution attack on every future sender to that mailbox.
      // Missing and wrong are now both 403. Shipped clients are unaffected:
      // `MailboxManager.uploadPreKeysIfNeeded()` always passes the stored
      // token, and `registerIfNeeded()` only ever writes a brand-new,
      // randomly-generated mailbox id (the first-writer path below).
      const existingMeta = await env.V2_STORE.get(`meta:${body.mailboxId}`);
      let token: string;
      if (existingMeta) {
        const meta = JSON.parse(existingMeta) as { token: string };
        if (!body.token || body.token !== meta.token) {
          return jsonResponse({ error: "forbidden" }, 403);
        }
        token = meta.token;
      } else {
        const tokenBytes = new Uint8Array(32);
        crypto.getRandomValues(tokenBytes);
        token = Array.from(tokenBytes).map(b => b.toString(16).padStart(2, "0")).join("");
      }

      await env.V2_STORE.put(`keys:${body.mailboxId}`, JSON.stringify(body.preKeyBundle), {
        expirationTtl: 30 * 86400, // 30 days
      });
      await env.V2_STORE.put(`meta:${body.mailboxId}`, JSON.stringify({ token, created: Date.now() }), {
        expirationTtl: 30 * 86400,
      });

      return jsonResponse({ ok: true, token }, 201);
    }

    // GET /v2/keys/:mailboxId — Retrieve target's pre-key bundle (consumes one OTP key atomically via DO)
    const keysMatch = path.match(/^\/v2\/keys\/([a-z0-9]+)$/);
    if (keysMatch && request.method === "GET") {
      const mailboxId = keysMatch[1];
      return await fetchAndConsumePreKeyBundle(env, mailboxId);
    }

    // POST /v2/messages/:mailboxId — Deliver encrypted message to target
    const msgDeliverMatch = path.match(/^\/v2\/messages\/([a-z0-9]+)$/);
    if (msgDeliverMatch && request.method === "POST") {
      const mailboxId = msgDeliverMatch[1];
      const body = await request.json() as {
        ciphertext?: string;
        pow?: { challenge: string; proof: number };
      };

      if (!body.ciphertext || !body.pow) {
        return jsonResponse({ error: "Missing ciphertext or pow" }, 400);
      }

      // Verify PoW
      if (!(await verifyPoW(body.pow.challenge, body.pow.proof, 16))) {
        return jsonResponse({ error: "Invalid proof of work" }, 403);
      }

      // Rate limit: 200 messages/day per mailbox
      const dailyKey = `msg-count:${mailboxId}:${new Date().toISOString().slice(0, 10)}`;
      const dailyCount = parseInt(await env.V2_STORE.get(dailyKey) || "0");
      if (dailyCount >= 200) {
        return jsonResponse({ error: "Daily message limit reached" }, 429);
      }
      await env.V2_STORE.put(dailyKey, String(dailyCount + 1), { expirationTtl: 86400 });

      // Store message
      const msgId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
      await env.V2_STORE.put(`msg:${mailboxId}:${msgId}`, JSON.stringify({
        id: msgId,
        ciphertext: body.ciphertext,
        timestamp: new Date().toISOString(),
      }), { expirationTtl: 7 * 86400 }); // 7 days TTL

      return jsonResponse({ ok: true, id: msgId }, 201);
    }

    // GET /v2/messages — Pull pending messages for own mailbox
    if (path === "/v2/messages" && request.method === "GET") {
      const mailboxId = request.headers.get("X-Mailbox-Id");
      const token = request.headers.get("X-Mailbox-Token");
      if (!mailboxId || !token) {
        return jsonResponse({ error: "Missing mailbox credentials" }, 401);
      }

      // Verify token
      const meta = await env.V2_STORE.get(`meta:${mailboxId}`);
      if (!meta) {
        return jsonResponse({ error: "Mailbox not found" }, 404);
      }
      const metaObj = JSON.parse(meta) as { token: string };
      if (metaObj.token !== token) {
        return jsonResponse({ error: "Invalid token" }, 403);
      }

      // List and return all pending messages
      const list = await env.V2_STORE.list({ prefix: `msg:${mailboxId}:` });
      const messages = [];
      for (const key of list.keys) {
        const data = await env.V2_STORE.get(key.name);
        if (data) messages.push(JSON.parse(data));
      }

      // Delete after successful retrieval
      for (const key of list.keys) {
        await env.V2_STORE.delete(key.name);
      }

      return jsonResponse(messages);
    }

    // POST /v2/mailbox/rotate — Rotate mailbox ID
    if (path === "/v2/mailbox/rotate" && request.method === "POST") {
      const oldMailboxId = request.headers.get("X-Mailbox-Id");
      const oldToken = request.headers.get("X-Mailbox-Token");
      if (!oldMailboxId || !oldToken) {
        return jsonResponse({ error: "Missing mailbox credentials" }, 401);
      }

      const meta = await env.V2_STORE.get(`meta:${oldMailboxId}`);
      if (!meta) {
        return jsonResponse({ error: "Mailbox not found" }, 404);
      }
      const metaObj = JSON.parse(meta) as { token: string };
      if (metaObj.token !== oldToken) {
        return jsonResponse({ error: "Invalid token" }, 403);
      }

      // Generate new mailbox ID and token
      const newIdBytes = new Uint8Array(12);
      crypto.getRandomValues(newIdBytes);
      const newMailboxId = Array.from(newIdBytes).map(b => b.toString(16).padStart(2, "0")).join("");
      const newTokenBytes = new Uint8Array(32);
      crypto.getRandomValues(newTokenBytes);
      const newToken = Array.from(newTokenBytes).map(b => b.toString(16).padStart(2, "0")).join("");

      // Migrate keys
      const keys = await env.V2_STORE.get(`keys:${oldMailboxId}`);
      if (keys) {
        await env.V2_STORE.put(`keys:${newMailboxId}`, keys, { expirationTtl: 30 * 86400 });
      }
      await env.V2_STORE.put(`meta:${newMailboxId}`, JSON.stringify({ token: newToken, created: Date.now() }), {
        expirationTtl: 30 * 86400,
      });

      // Migrate pending messages
      const msgList = await env.V2_STORE.list({ prefix: `msg:${oldMailboxId}:` });
      for (const key of msgList.keys) {
        const data = await env.V2_STORE.get(key.name);
        if (data) {
          const newKey = key.name.replace(`msg:${oldMailboxId}:`, `msg:${newMailboxId}:`);
          await env.V2_STORE.put(newKey, data, { expirationTtl: 7 * 86400 });
        }
        await env.V2_STORE.delete(key.name);
      }

      // Clean up old mailbox
      await env.V2_STORE.delete(`keys:${oldMailboxId}`);
      await env.V2_STORE.delete(`meta:${oldMailboxId}`);

      // If the caller also holds an account-scoped Bearer token, keep
      // accounts.mailbox_id in sync so /v3/directory and /v3/account/me
      // reflect the rotated mailbox. Best-effort and behind a try/catch:
      // pre-account (or account-less) clients never touch D1 here at all
      // (authorizeV3 returns null for a missing/default-scope Bearer), and
      // an accounts-DB hiccup must never fail the rotate itself — the V2
      // mailbox rotation above has already fully succeeded by this point.
      try {
        const acct = await authorizeV3(request, env);
        if (acct) {
          // Only overwrite the account's mailbox when it still points at
          // the mailbox being rotated. Without the `mailbox_id = ?4`
          // guard, rotating a STALE mailbox (an old id whose meta is still
          // in KV — e.g. a second device, or a retry after the account
          // already moved on) would clobber the account's current, live
          // mailbox with the rotation of an abandoned one.
          await env.ACCOUNTS_DB.prepare("UPDATE accounts SET mailbox_id = ?1, updated_at = ?2 WHERE account_id = ?3 AND mailbox_id = ?4")
            .bind(newMailboxId, Date.now(), acct.accountId, oldMailboxId).run();
        }
      } catch (err) {
        console.error("mailbox/rotate: failed to sync accounts.mailbox_id", String(err));
      }

      return jsonResponse({ newMailboxId, newToken });
    }

    // DELETE /v2/keys — Revoke all keys (device lost)
    if (path === "/v2/keys" && request.method === "DELETE") {
      const mailboxId = request.headers.get("X-Mailbox-Id");
      const token = request.headers.get("X-Mailbox-Token");
      if (!mailboxId || !token) {
        return jsonResponse({ error: "Missing mailbox credentials" }, 401);
      }

      const meta = await env.V2_STORE.get(`meta:${mailboxId}`);
      if (!meta) {
        return jsonResponse({ error: "Mailbox not found" }, 404);
      }
      const metaObj = JSON.parse(meta) as { token: string };
      if (metaObj.token !== token) {
        return jsonResponse({ error: "Invalid token" }, 403);
      }

      // Delete everything
      await env.V2_STORE.delete(`keys:${mailboxId}`);
      await env.V2_STORE.delete(`meta:${mailboxId}`);
      const msgList = await env.V2_STORE.list({ prefix: `msg:${mailboxId}:` });
      for (const key of msgList.keys) {
        await env.V2_STORE.delete(key.name);
      }

      return jsonResponse({ ok: true });
    }

    // GET /v2/inbox/:deviceId — WebSocket upgrade for real-time invite inbox
    const inboxMatch = path.match(/^\/v2\/inbox\/([a-zA-Z0-9-]{8,64})$/);
    if (inboxMatch && request.headers.get("Upgrade") === "websocket") {
      const deviceId = inboxMatch[1];
      const id = env.DEVICE_INBOX.idFromName(deviceId);
      const stub = env.DEVICE_INBOX.get(id);
      const doURL = new URL(request.url);
      doURL.pathname = "/ws";
      return stub.fetch(new Request(doURL.toString(), request));
    }

    // POST /v2/device/register — register APNs device token
    if (path === "/v2/device/register" && request.method === "POST") {
      const body = await request.json() as { deviceId?: string; pushToken?: string; platform?: string };
      if (!body.deviceId || !body.pushToken) {
        return jsonResponse({ error: "Missing deviceId or pushToken" }, 400);
      }
      if (!/^[a-zA-Z0-9-]{8,64}$/.test(body.deviceId)) {
        return jsonResponse({ error: "Invalid deviceId format" }, 400);
      }
      await env.V2_STORE.put(`device:${body.deviceId}`, JSON.stringify({
        pushToken: body.pushToken,
        platform: body.platform || "ios",
        updated: Date.now(),
      }), { expirationTtl: 30 * 86400 });
      return jsonResponse({ ok: true });
    }

    // POST /v2/invite/:deviceId — deliver relay invite
    const inviteMatch = path.match(/^\/v2\/invite\/([a-zA-Z0-9-]{8,64})$/);
    if (inviteMatch && request.method === "POST") {
      const deviceId = inviteMatch[1];
      const body = await request.json() as {
        roomCode?: string;
        roomToken?: string;
        senderName?: string;
        senderId?: string;
      };
      if (!body.roomCode || !body.roomToken || !body.senderName) {
        return jsonResponse({ error: "Missing invite fields" }, 400);
      }
      if (!/^[A-Z0-9]{6}$/.test(body.roomCode)) {
        return jsonResponse({ error: "Invalid roomCode format" }, 400);
      }

      const safeSenderName = (body.senderName || "").slice(0, 100);

      const invitePayload = JSON.stringify({
        type: "relay-invite",
        roomCode: body.roomCode,
        roomToken: body.roomToken,
        senderName: safeSenderName,
        senderId: body.senderId || "",
        timestamp: Date.now(),
      });

      // Push via DeviceInbox DO
      const id = env.DEVICE_INBOX.idFromName(deviceId);
      const stub = env.DEVICE_INBOX.get(id);
      const pushURL = new URL(request.url);
      pushURL.pathname = "/push";
      const doResp = await stub.fetch(new Request(pushURL.toString(), {
        method: "POST",
        body: invitePayload,
      }));
      const doResult = await doResp.json() as { delivered: string };

      // If queued, try APNs
      if (doResult.delivered === "queued") {
        // Look up APNs token for this device
        const deviceInfo = await env.V2_STORE.get(`device:${deviceId}`);
        if (!deviceInfo) {
          return jsonResponse({ ok: true, delivered: "queued", apns: "no_token" });
        }
        const info = JSON.parse(deviceInfo) as { pushToken: string; platform: string };
        if (!env.APNS_KEY_P8) {
          return jsonResponse({ ok: true, delivered: "queued", apns: "not_configured" });
        }
        const inviteTopic = selectApnsTopic(info.platform, env);
        try {
          const result = await sendAPNs(info.pushToken, {
            alert: { title: "PeerDrop", body: `${safeSenderName} wants to connect` },
            sound: "default",
            contentAvailable: true,
            customData: {
              // roomToken is NOT included in push — it stays in the DO queue.
              // The app fetches it via the authenticated inbox WebSocket on wake.
              roomCode: body.roomCode,
              senderId: body.senderId || "",
              senderName: safeSenderName,
            },
          }, {
            keyId: env.APNS_KEY_ID,
            teamId: env.APNS_TEAM_ID,
            p8Key: env.APNS_KEY_P8,
            bundleId: env.APNS_BUNDLE_ID || "com.hanfour.peerdrop",
          }, {
            topicOverride: inviteTopic,
          });
          return jsonResponse({ ok: true, delivered: "apns", apnsStatus: result.status });
        } catch (e) {
          return jsonResponse({ ok: true, delivered: "queued", apns: "send_failed", error: String(e) });
        }
      }

      return jsonResponse({ ok: true, delivered: doResult.delivered });
    }

    // POST /v2/call/:deviceId — deliver voice-call wake push (M3 Mac voice)
    const callMatch = path.match(/^\/v2\/call\/([a-zA-Z0-9-]{8,64})$/);
    if (callMatch && request.method === "POST") {
      const deviceId = callMatch[1];
      const body = await request.json() as { callerId?: string; callerName?: string };
      if (!body.callerId || !body.callerName) {
        return jsonResponse({ error: "Missing callerId or callerName" }, 400);
      }
      const safeCallerName = (body.callerName || "").slice(0, 100);
      const safeCallerId = body.callerId.slice(0, 100);
      const deviceInfo = await env.V2_STORE.get(`device:${deviceId}`);
      if (!deviceInfo) {
        return jsonResponse({ ok: false, error: "not_registered" }, 404);
      }
      const info = JSON.parse(deviceInfo) as { pushToken: string; platform: string };
      if (!env.APNS_KEY_P8) {
        return jsonResponse({ ok: false, apns: "not_configured" });
      }
      const callTopic = selectApnsTopic(info.platform, env);
      try {
        const result = await sendAPNs(info.pushToken, {
          alert: { title: "Incoming call", body: safeCallerName },
          sound: "default",
          customData: {
            type: "callRequest",
            callerId: safeCallerId,
            callerName: safeCallerName,
          },
        }, {
          keyId: env.APNS_KEY_ID,
          teamId: env.APNS_TEAM_ID,
          p8Key: env.APNS_KEY_P8,
          bundleId: env.APNS_BUNDLE_ID || "com.hanfour.peerdrop",
        }, {
          topicOverride: callTopic,
          priority: 10,
          expiration: Math.floor(Date.now() / 1000) + 30,
          interruptionLevel: "time-sensitive",
        });
        return jsonResponse({ ok: true, apnsStatus: result.status });
      } catch (e) {
        return jsonResponse({ ok: false, apns: "send_failed", error: String(e) }, 500);
      }
    }

    // GET /v2/config/crypto-policy — serve the signed crypto-policy blob.
    // No auth required — the response is already signed with the operator's
    // Ed25519 key; any tampering is caught client-side. Auth would add
    // complexity without improving security here.
    if (path === "/v2/config/crypto-policy" && request.method === "GET") {
      const { handleCryptoPolicy } = await import("./cryptoPolicy");
      return handleCryptoPolicy(env);
    }

    // POST /v3/account/challenge — issue a single-use nonce for the account
    // registration signature. Needs only a device token of ANY scope (not
    // yet account-scoped — that's exactly what /register is about to
    // create), so this runs before the account-token gate below.
    if (path === "/v3/account/challenge" && request.method === "POST") {
      const payload = await authorizeDevice(request, env);
      if (!payload) return jsonResponse({ error: "Unauthorized" }, 401);
      const challengeRaw = await request.text();
      if (challengeRaw.length > 4096) return jsonResponse({ error: "too_large" }, 413);
      let body: { deviceId?: string } | null;
      try { body = JSON.parse(challengeRaw || "null"); } catch { body = null; }
      if (!body?.deviceId || !/^[a-zA-Z0-9-]{8,64}$/.test(body.deviceId)) return jsonResponse({ error: "invalid_device_id" }, 400);
      if (body.deviceId !== payload.deviceId) return jsonResponse({ error: "forbidden" }, 403);
      const nonce = new Uint8Array(32); crypto.getRandomValues(nonce);
      const nonceB64 = arrayBufferToBase64(nonce);
      await env.V2_STORE.put(`acct-challenge:${body.deviceId}`, nonceB64, { expirationTtl: 300 });
      return jsonResponse({ nonce: nonceB64 }, 201);
    }

    // POST /v3/account/register — create (or bind a device to) an account.
    // Same "device token of any scope" gate as /challenge above — an
    // unbound device must be able to call this to become account-scoped
    // in the first place.
    if (path === "/v3/account/register" && request.method === "POST") {
      const payload = await authorizeDevice(request, env);
      if (!payload) return jsonResponse({ error: "Unauthorized" }, 401);
      const raw = await request.text();
      if (raw.length > 4096) return jsonResponse({ error: "too_large" }, 413);
      // A malformed body must be a 400, not an uncaught SyntaxError that
      // escapes as a 500 (the /challenge route above already guards its
      // own parse the same way).
      let body: { deviceId?: string; platform?: string; identityKey?: string; signingKey?: string; mailboxId?: string; mailboxToken?: string; nonce?: string; signature?: string } | null;
      try { body = JSON.parse(raw || "null"); } catch { return jsonResponse({ error: "invalid_json" }, 400); }
      if (!body?.deviceId || !body.platform || !body.identityKey || !body.signingKey || !body.mailboxId || !body.mailboxToken || !body.nonce || !body.signature) return jsonResponse({ error: "missing_fields" }, 400);
      if (body.deviceId !== payload.deviceId) return jsonResponse({ error: "forbidden" }, 403);
      if (!["ios", "macos"].includes(body.platform)) return jsonResponse({ error: "invalid_platform" }, 400);
      if (!/^[a-z0-9]{1,64}$/.test(body.mailboxId)) return jsonResponse({ error: "invalid_mailbox" }, 400);
      const stored = await env.V2_STORE.get(`acct-challenge:${body.deviceId}`);
      if (!stored || stored !== body.nonce) return jsonResponse({ error: "nonce_invalid" }, 400);
      await env.V2_STORE.delete(`acct-challenge:${body.deviceId}`);
      // `atob` throws InvalidCharacterError on a non-base64 string — same
      // reasoning as the JSON guard above: a client typo is a 400, never a
      // 500. (The nonce is decoded here too even though it already matched
      // the stored value byte-for-byte above, so all four decodes share one
      // guard rather than relying on that invariant holding forever.)
      let signingKey: Uint8Array, identityKey: Uint8Array, nonceBytes: Uint8Array, signatureBytes: Uint8Array;
      try {
        signingKey = base64Decode(body.signingKey);
        identityKey = base64Decode(body.identityKey);
        nonceBytes = base64Decode(body.nonce);
        signatureBytes = base64Decode(body.signature);
      } catch { return jsonResponse({ error: "invalid_encoding" }, 400); }
      if (identityKey.length !== 32) return jsonResponse({ error: "invalid_identity_key" }, 400);
      // The signature covers the identity key and the mailbox id (v2
      // message — see verifyRegistrationSignature), so neither can be
      // swapped for another device's by an attacker holding only a
      // replayed nonce + signature.
      const ok = await verifyRegistrationSignature(signingKey, nonceBytes, body.deviceId, identityKey, body.mailboxId, signatureBytes);
      if (!ok) return jsonResponse({ error: "bad_signature" }, 400);
      // Prove the caller actually owns the mailbox it is binding to the
      // account: without this, any device could point its account row at
      // someone else's mailbox id and make the directory hand that
      // mailbox's pre-key bundle out under the attacker's account/nickname.
      // The mailbox token is the same secret `/v2/keys/register` minted.
      const mailboxMeta = await env.V2_STORE.get(`meta:${body.mailboxId}`);
      if (!mailboxMeta) return jsonResponse({ error: "mailbox_not_owned" }, 403);
      let mailboxMetaToken: string | undefined;
      try { mailboxMetaToken = (JSON.parse(mailboxMeta) as { token?: string }).token; } catch { mailboxMetaToken = undefined; }
      if (!mailboxMetaToken || mailboxMetaToken !== body.mailboxToken) return jsonResponse({ error: "mailbox_not_owned" }, 403);
      const now = Date.now();
      const bound = await env.ACCOUNTS_DB.prepare("SELECT account_id FROM account_devices WHERE device_id = ?1").bind(body.deviceId).first<{ account_id: string }>();
      let existing = await env.ACCOUNTS_DB.prepare("SELECT account_id, nickname FROM accounts WHERE signing_key = ?1").bind(signingKey).first<{ account_id: string; nickname: string | null }>();
      if (bound && (!existing || bound.account_id !== existing.account_id)) return jsonResponse({ error: "device_bound" }, 409);

      // Registration is written as a single D1 batch (one transaction — a
      // failure rolls everything back) so a new account and its first
      // device binding, or an existing account's mailbox update and a new
      // device binding, never land half-written. Failures are classified
      // by which UNIQUE constraint they tripped (classifyRegisterError):
      // an account_id collision just needs a fresh id (retried up to 3
      // times total); an identity_key collision is a real conflict (409);
      // a signing_key collision means a concurrent registration for the
      // same signing key won the race between our SELECT above and this
      // batch — re-read once and fall into the existing-account path; a
      // device_devices collision means a concurrent registration for the
      // same device won that race — 409 device_bound, matching the
      // pre-check above.
      const MAX_ACCOUNT_ID_ATTEMPTS = 3;
      let accountIdAttempts = 0;
      let signingKeyRetried = false;
      let accountId = "";
      let nickname: string | null = null;
      for (;;) {
        const statements: D1PreparedStatement[] = [];
        if (existing) {
          accountId = existing.account_id;
          nickname = existing.nickname;
          // The identity key is refreshed too, not just the mailbox: a
          // reinstall regenerates IdentityKeyManager's X25519 keypair while
          // the (Keychain-persisted) Ed25519 signing key survives, so an
          // update that only touched mailbox_id left the directory serving
          // a dead identity key forever — every sender would encrypt to a
          // key the owner no longer holds. A UNIQUE violation here means
          // the new identity key already belongs to a DIFFERENT account →
          // 409 identity_bound via classifyRegisterError.
          statements.push(
            env.ACCOUNTS_DB.prepare("UPDATE accounts SET identity_key = ?1, mailbox_id = ?2, updated_at = ?3 WHERE account_id = ?4")
              .bind(identityKey, body.mailboxId, now, accountId),
          );
          if (!bound) {
            statements.push(
              env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, ?3, ?4)")
                .bind(accountId, body.deviceId, body.platform, now),
            );
          }
        } else {
          accountIdAttempts++;
          accountId = generateAccountId();
          nickname = null;
          statements.push(
            env.ACCOUNTS_DB.prepare("INSERT INTO accounts (account_id, signing_key, identity_key, nickname, mailbox_id, created_at, updated_at) VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?5)")
              .bind(accountId, signingKey, identityKey, body.mailboxId, now),
          );
          statements.push(
            env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, ?3, ?4)")
              .bind(accountId, body.deviceId, body.platform, now),
          );
        }

        try {
          await env.ACCOUNTS_DB.batch(statements);
          break;
        } catch (e) {
          const kind = classifyRegisterError(e);
          if (kind === "account_id" && !existing && accountIdAttempts < MAX_ACCOUNT_ID_ATTEMPTS) continue;
          if (kind === "identity_bound") return jsonResponse({ error: "identity_bound" }, 409);
          if (kind === "signing_key" && !signingKeyRetried) {
            signingKeyRetried = true;
            existing = await env.ACCOUNTS_DB.prepare("SELECT account_id, nickname FROM accounts WHERE signing_key = ?1")
              .bind(signingKey).first<{ account_id: string; nickname: string | null }>();
            if (existing) continue;
          }
          if (kind === "device_bound") return jsonResponse({ error: "device_bound" }, 409);
          throw e;
        }
      }
      const token = await issueToken(freshTokenPayload(body.deviceId, `account:${accountId}`), env.TOKEN_SECRET);
      return jsonResponse({ accountId, nickname, token, expiresInSeconds: 900 }, 201);
    }

    // /v3/* — account-scoped routes. Bearer device token, or the key lane
    // (`X-API-Key` + `X-Device-Id`) for surfaces without App Attest; never
    // `?token=` or `?apiKey=`. The key lane reaches only the read/
    // registration routes — handleV3 refuses it on the mutating ones.
    if (path.startsWith("/v3/")) {
      const auth = await authorizeV3(request, env);
      if (!auth) return jsonResponse({ error: "Unauthorized" }, 401);
      return await handleV3(request, url, path, env, auth);
    }

    return new Response("Not Found", { status: 404, headers: corsHeaders });
  },
};

export interface V3Auth { deviceId: string; accountId: string; lane: AuthLane }

/** Which credential got the caller in — see `isKeyLane`. */
export type AuthLane = "bearer" | "key";

/**
 * Constant-time comparison of two credential strings. Length is compared
 * first (and leaks, as it does in every practical implementation), but the
 * bytes themselves are compared without an early exit so a remote caller
 * can't binary-search a key one character at a time off response timing.
 */
function constantTimeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ea = enc.encode(a), eb = enc.encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

/**
 * Classify an `X-API-Key` value.
 *
 *   "operator" — `API_KEY`: the operator/dev credential (peerdrop-cli,
 *                Debug builds, Simulator, `/debug/*`). Full reach.
 *   "client"   — `MAC_CLIENT_KEY`: the credential embedded in the shipped
 *                native macOS app, which has no App Attest. Same /v2 relay
 *                reach (the Mac needs it), but a restricted /v3 lane.
 *   null       — not a recognized key.
 *
 * `MAC_CLIENT_KEY` unset (local dev / vitest) falls back to `API_KEY`, so
 * the operator branch simply wins there and the lane stays exercisable
 * without a second binding.
 */
export function isKeyLane(key: string | null, env: Env): "operator" | "client" | null {
  if (!key) return null;
  if (env.API_KEY && constantTimeEqual(key, env.API_KEY)) return "operator";
  const clientKey = env.MAC_CLIENT_KEY || env.API_KEY;
  if (clientKey && constantTimeEqual(key, clientKey)) return "client";
  return null;
}

/**
 * Device authentication for the account routes.
 *
 * Preferred lane: an App-Attest-issued Bearer device token (any scope),
 * header only — never `?token=`.
 *
 * Fallback lane ("key lane"): `X-API-Key` (operator OR Mac client key)
 * PLUS an `X-Device-Id` header. This is the operator/client credential for
 * surfaces without App Attest — peerdrop-cli and, since the 2026-09-15
 * spike, the native macOS app (`DCAppAttestService.isSupported == false`
 * on macOS). **The device id is self-asserted**: the key proves "a holder
 * of this credential", not "this device". That is why the key lane is
 * confined in `handleV3` to challenge/register/me/directory, and why
 * anything that MUTATES an account (nickname, delete) demands a Bearer —
 * those the device has to have earned by registering. Header only: a key
 * in `?apiKey=` would leak into request logs.
 *
 * Returns a synthetic payload with `expires: 0` — nothing downstream reads
 * `expires` (the token's own verification already enforced it on the
 * Bearer lane), and 0 makes a key-lane payload obviously not a real token
 * if it ever gets logged.
 */
async function authorizeDeviceWithLane(request: Request, env: Env): Promise<{ payload: TokenPayload; lane: AuthLane } | null> {
  const header = request.headers.get("Authorization");
  if (header?.startsWith("Bearer ") && env.TOKEN_SECRET) {
    try {
      const { verifyToken } = await import("./deviceToken");
      return { payload: await verifyToken(header.slice(7).trim(), env.TOKEN_SECRET), lane: "bearer" };
    } catch {
      // Fall through to the key lane — a stale Bearer must not lock out a
      // caller that also holds a key (mirrors isRequestAuthorized).
    }
  }
  const key = request.headers.get("X-API-Key");
  const deviceId = request.headers.get("X-Device-Id");
  if (isKeyLane(key, env) && deviceId && /^[a-zA-Z0-9-]{8,64}$/.test(deviceId)) {
    return { payload: { deviceId, scope: await scopeForDevice(env.ACCOUNTS_DB, deviceId), expires: 0 }, lane: "key" };
  }
  return null;
}

/** Bearer device token (any scope), or the key lane + `X-Device-Id`. */
export async function authorizeDevice(request: Request, env: Env): Promise<TokenPayload | null> {
  return (await authorizeDeviceWithLane(request, env))?.payload ?? null;
}

/**
 * Account-scoped authentication. The scope comes from the verified token on
 * the Bearer lane and from `scopeForDevice` on the key lane, so a device
 * that has never registered gets the "default" scope and is rejected here
 * either way. Never reads `?token=`.
 */
export async function authorizeV3(request: Request, env: Env): Promise<V3Auth | null> {
  const authed = await authorizeDeviceWithLane(request, env);
  if (!authed) return null;
  const accountId = accountIdFromScope(authed.payload.scope);
  return accountId ? { deviceId: authed.payload.deviceId, accountId, lane: authed.lane } : null;
}

/**
 * Fetch a mailbox's pre-key bundle from the PreKeyStore Durable Object,
 * consuming one one-time pre-key atomically as a side effect (see
 * `class PreKeyStore` below for the exact KV shape under `keys:<mailboxId>`
 * and the consumed-bundle response shape). Returns the DO's raw Response
 * unmodified — the caller decides how to surface a non-OK status (the /v2
 * route passes it straight through, byte-for-byte identical to before
 * this was extracted; the /v3 directory lookup treats any non-OK status
 * as "no bundle" and omits the `preKeyBundle` field). Extracted from the
 * original `GET /v2/keys/:mailboxId` handler so /v3/directory?bundle=1
 * can reuse the exact same atomic-consume behavior.
 */
async function fetchAndConsumePreKeyBundle(env: Env, mailboxId: string): Promise<Response> {
  const doId = env.PREKEY_STORE.idFromName(mailboxId);
  const stub = env.PREKEY_STORE.get(doId);
  return stub.fetch(new Request(`https://internal/consume?mailboxId=${mailboxId}`));
}

// /v3 route table for account-token-scoped routes (challenge/register run
// before authorizeV3 above — they only need a device token of any scope).
async function handleV3(request: Request, url: URL, path: string, env: Env, auth: V3Auth): Promise<Response> {
  const db = env.ACCOUNTS_DB;
  if (path === "/v3/account/me" && request.method === "GET") {
    const acct = await db.prepare("SELECT account_id, nickname, mailbox_id FROM accounts WHERE account_id = ?1").bind(auth.accountId).first<{ account_id: string; nickname: string | null; mailbox_id: string }>();
    if (!acct) return jsonResponse({ error: "not_found" }, 404);
    const devices = (await db.prepare("SELECT device_id, platform, bound_at FROM account_devices WHERE account_id = ?1 ORDER BY bound_at").bind(auth.accountId).all<{ device_id: string; platform: string; bound_at: number }>()).results
      .map((d) => ({ deviceId: d.device_id, platform: d.platform, boundAt: d.bound_at }));
    return jsonResponse({ accountId: acct.account_id, nickname: acct.nickname, mailboxId: acct.mailbox_id, devices });
  }
  if (path === "/v3/account/nickname" && request.method === "PUT") {
    // Bearer-only. The key lane's device id is self-asserted, so allowing
    // it here would let any holder of the key rename (or, below, delete)
    // an account it merely knows a device id for. A registered Mac always
    // has a Bearer: /v3/account/register hands one back and the client
    // adopts it (AccountManager.ensureFreshTokenIfNeeded re-runs the flow
    // when it has expired).
    if (auth.lane === "key") return jsonResponse({ error: "bearer_required" }, 401);
    const nicknameRaw = await request.text();
    if (nicknameRaw.length > 4096) return jsonResponse({ error: "too_large" }, 413);
    let body: { nickname?: string | null } | null;
    try { body = JSON.parse(nicknameRaw || "null"); } catch { body = null; }
    if (!body || !("nickname" in body)) return jsonResponse({ error: "missing_fields" }, 400);
    const day = new Date().toISOString().slice(0, 10);
    const quotaKey = `nick-quota:${auth.accountId}:${day}`;
    const used = parseInt((await env.V2_STORE.get(quotaKey)) ?? "0", 10) || 0;
    if (used >= 5) return jsonResponse({ error: "rate_limited" }, 429);
    let value: string | null = null;
    if (body.nickname !== null) {
      const check = validateNickname(String(body.nickname));
      if (!check.ok) return jsonResponse({ error: check.code }, 400);
      value = check.value;
    }
    try {
      await db.prepare("UPDATE accounts SET nickname = ?1, updated_at = ?2 WHERE account_id = ?3").bind(value, Date.now(), auth.accountId).run();
    } catch (e) {
      if (String((e as Error).message).includes("UNIQUE")) return jsonResponse({ error: "nickname_taken" }, 409);
      throw e;
    }
    await env.V2_STORE.put(quotaKey, String(used + 1), { expirationTtl: 86400 });
    return jsonResponse({ nickname: value });
  }
  if (path === "/v3/account" && request.method === "DELETE") {
    // Bearer-only — same reasoning as PUT /v3/account/nickname above, with
    // a destructive, irreversible outcome.
    if (auth.lane === "key") return jsonResponse({ error: "bearer_required" }, 401);
    // D1 doesn't guarantee foreign_keys=ON (so ON DELETE CASCADE in the
    // schema isn't reliable) — delete devices explicitly first, as one
    // batch (one transaction) so the two deletes can't land half-done.
    await db.batch([
      db.prepare("DELETE FROM account_devices WHERE account_id = ?1").bind(auth.accountId),
      db.prepare("DELETE FROM accounts WHERE account_id = ?1").bind(auth.accountId),
    ]);
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  // GET /v3/directory/:handle[?bundle=1] — resolve a normalized account id
  // or nickname to its public directory entry. Rate limited per calling
  // account (not per target) at 30 lookups/min via KV
  // `dir-quota:<accountId>:<minuteWindow>`, incremented before the lookup
  // so even 404s count against the caller's quota.
  const dirMatch = path.match(/^\/v3\/directory\/([^/]{1,64})$/);
  if (dirMatch && request.method === "GET") {
    const minute = Math.floor(Date.now() / 60_000);
    const quotaKey = `dir-quota:${auth.accountId}:${minute}`;
    const used = parseInt((await env.V2_STORE.get(quotaKey)) ?? "0", 10) || 0;
    if (used >= 30) return jsonResponse({ error: "rate_limited" }, 429);
    await env.V2_STORE.put(quotaKey, String(used + 1), { expirationTtl: 120 });
    // decodeURIComponent throws URIError on a malformed escape (e.g. "%zz")
    // — treat that the same as "no such handle" rather than letting it
    // escape as an uncaught 500. The quota increment above already ran,
    // matching the "count even 404s" rule.
    let handle: string;
    try {
      handle = decodeURIComponent(dirMatch[1]);
    } catch {
      return jsonResponse({ error: "not_found" }, 404);
    }
    const row = await findAccountByHandle(db, handle);
    if (!row) return jsonResponse({ error: "not_found" }, 404);
    const out: Record<string, unknown> = {
      accountId: row.account_id, nickname: row.nickname,
      identityKey: arrayBufferToBase64(new Uint8Array(row.identity_key)),
      signingKey: arrayBufferToBase64(new Uint8Array(row.signing_key)),
      mailboxId: row.mailbox_id,
    };
    if (url.searchParams.get("bundle") === "1") {
      const bundleResp = await fetchAndConsumePreKeyBundle(env, row.mailbox_id);
      if (bundleResp.ok) out.preKeyBundle = await bundleResp.json();
    }
    return jsonResponse(out);
  }
  return jsonResponse({ error: "not_found" }, 404);
}

/**
 * Combined auth check for the tier-2 endpoint set. Returns true if the
 * request carries either a valid Bearer token signed with `TOKEN_SECRET`
 * or a recognized `X-API-Key` (operator or Mac client — see isKeyLane).
 * Both lanes are permanent (§Layer 5 REVISED 2026-07-05): Bearer serves
 * store clients via App Attest; the keys serve surfaces that can't attest
 * (peerdrop-cli, Debug builds, Simulator, native macOS).
 */
async function isRequestAuthorized(request: Request, url: URL, env: Env): Promise<boolean> {
  // Bearer first — header for normal requests, `?token=` query string
  // for WebSocket upgrades (URLSession's `webSocketTask(with:)` can't
  // attach custom headers to the upgrade request, so the InboxService
  // WS path is the only legitimate query-param token consumer).
  const headerBearer = request.headers.get("Authorization");
  const headerToken = headerBearer?.startsWith("Bearer ")
    ? headerBearer.slice("Bearer ".length).trim()
    : null;
  const queryToken = url.searchParams.get("token");
  const candidateToken = headerToken ?? queryToken;
  if (candidateToken && env.TOKEN_SECRET) {
    try {
      const { verifyToken } = await import("./deviceToken");
      await verifyToken(candidateToken, env.TOKEN_SECRET);
      return true;
    } catch {
      // Fall through to the operator X-API-Key lane — a malformed or
      // expired Bearer must not lock out a caller that also holds the
      // operator key (e.g. a Debug build with a stale token cache).
    }
  }
  // Both the operator key and the Mac client key are accepted here: the
  // shipped macOS app has no App Attest, so the /v2 relay surfaces it uses
  // (rooms, ICE, device register, invites, calls, inbox) must stay reachable
  // with its own credential.
  const providedKey = request.headers.get("X-API-Key") || url.searchParams.get("apiKey");
  return isKeyLane(providedKey, env) !== null;
}

/**
 * Header-only variant of isRequestAuthorized for plain HTTP routes
 * (currently /debug/metric). Same credentials — Bearer or a recognized
 * X-API-Key — but never reads the query string: only the WebSocket
 * upgrade has a legitimate need for `?token=`, and credentials in URLs
 * leak into request logs where they can be captured and replayed.
 */
async function isHeaderAuthorized(request: Request, env: Env): Promise<boolean> {
  const headerBearer = request.headers.get("Authorization");
  const headerToken = headerBearer?.startsWith("Bearer ")
    ? headerBearer.slice("Bearer ".length).trim()
    : null;
  if (headerToken && env.TOKEN_SECRET) {
    try {
      const { verifyToken } = await import("./deviceToken");
      await verifyToken(headerToken, env.TOKEN_SECRET);
      return true;
    } catch {
      // Fall through to the operator X-API-Key header.
    }
  }
  return isKeyLane(request.headers.get("X-API-Key"), env) !== null;
}

/**
 * Resolve the correct `apns-topic` bundle ID for a device's registered
 * platform. Missing/unknown `platform` values default to iOS (legacy
 * compatibility — pre-v6 clients never sent the field). Exported so it
 * can be unit-tested in isolation without involving APNs HTTP/2.
 */
export function selectApnsTopic(
  platform: string | undefined,
  env: Pick<Env, "APNS_BUNDLE_ID" | "APNS_BUNDLE_ID_MAC">
): string {
  if (platform === "macos") {
    return env.APNS_BUNDLE_ID_MAC || "com.hanfour.peerdrop.mac";
  }
  return env.APNS_BUNDLE_ID || "com.hanfour.peerdrop";
}

/**
 * Bundle ids the worker accepts for App Attest rpIdHash verification —
 * iOS and Mac by default, overridable via `APP_BUNDLE_IDS` (comma-
 * separated). The legacy single-value `APP_BUNDLE_ID` is merged in too
 * (if not already present) so existing deployments that only set that
 * var keep working unchanged.
 */
export function configuredBundleIds(env: Pick<Env, "APP_BUNDLE_ID" | "APP_BUNDLE_IDS">): string[] {
  // `||` (not `??`) so an empty or whitespace-only APP_BUNDLE_IDS ("" from
  // an unset wrangler var, or a stray "  ") falls back to the default
  // rather than resolving to an empty bundle-id list.
  const raw = (env.APP_BUNDLE_IDS && env.APP_BUNDLE_IDS.trim()) || "com.hanfour.peerdrop,com.hanfour.peerdrop.mac";
  const list = raw.split(",").map((s) => s.trim()).filter((s) => s.length > 0);
  if (env.APP_BUNDLE_ID && !list.includes(env.APP_BUNDLE_ID)) list.push(env.APP_BUNDLE_ID);
  return Array.from(new Set(list));
}

// Helper: JSON response with CORS
function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// base64 ⇄ bytes for the device-token endpoints. Standard (not URL-safe)
// alphabet because the iOS App Attest API emits standard base64.
function base64Decode(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function arrayBufferToBase64(buf: Uint8Array): string {
  let s = "";
  for (const b of buf) s += String.fromCharCode(b);
  return btoa(s);
}

/**
 * Keyed, non-reversible hash of a client IP for diagnostics/rate-limit keys.
 *
 * Raw IPs must never land in KV (see /debug/report redaction + the v2
 * "no logging of IPs" contract). A *plain* SHA-256 of an IP is pointless —
 * the IPv4 space is only ~4 billion values, trivially brute-forced back to
 * the original. So we HMAC with a server-only secret (TOKEN_SECRET): the
 * output is stable (same source ⇒ same hash, preserving correlation value)
 * but cannot be reversed or rainbow-tabled without the secret.
 *
 * Returns "unknown" for the header-absent case (only happens off-edge / in
 * tests — Cloudflare always populates CF-Connecting-IP) and "unkeyed" if the
 * secret is somehow unset, so a raw IP is never emitted on any path.
 */
async function hashClientIp(ip: string, secret: string | undefined): Promise<string> {
  if (!ip || ip === "unknown") return "unknown";
  if (!secret) return "unkeyed";
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(ip)));
  let hex = "";
  for (let i = 0; i < 8; i++) hex += sig[i].toString(16).padStart(2, "0"); // 64-bit tag
  return hex;
}

/**
 * Check `X-API-Key` header against the named secret in env.
 * Returns null if authorized, or a 401 Response to return immediately.
 */
function requireKey(request: Request, env: Env, keyName: "API_KEY" | "ANALYTICS_KEY"): Response | null {
  const expected = env[keyName];
  if (!expected || request.headers.get("X-API-Key") !== expected) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }
  return null;
}

// Proof-of-Work verification (matches client-side SHA256 hashcash)
async function verifyPoW(challenge: string, proof: number, difficulty: number): Promise<boolean> {
  const data = new TextEncoder().encode(challenge);
  const proofBytes = new ArrayBuffer(8);
  new DataView(proofBytes).setBigUint64(0, BigInt(proof), false); // big-endian
  const combined = new Uint8Array(data.length + 8);
  combined.set(data, 0);
  combined.set(new Uint8Array(proofBytes), data.length);
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", combined));
  let zeroBits = 0;
  for (const byte of hash) {
    if (byte === 0) {
      zeroBits += 8;
    } else {
      zeroBits += Math.clz32(byte) - 24; // clz32 counts 32-bit leading zeros
      break;
    }
    if (zeroBits >= difficulty) return true;
  }
  return zeroBits >= difficulty;
}

// ---------------------------------------------------------------------------
// Durable Object: SignalingRoom
//
// Each room code maps to exactly one DO instance, guaranteeing that both
// WebSocket peers land in the same isolate. Uses the Hibernation API so
// the DO can sleep between messages without burning wall-clock billing.
// ---------------------------------------------------------------------------

const MAX_PEERS_PER_ROOM = 2;

export class SignalingRoom {
  private state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 400 });
    }

    // Client provides a stable clientId per WorkerSignaling instance so we can
    // deduplicate reconnects from the same client without waiting for the old
    // socket's close frame to propagate (which causes races that surface as
    // -1011 on iOS).
    const url = new URL(request.url);
    const clientId = url.searchParams.get("clientId") || "";

    const allSockets = this.state.getWebSockets();

    // Evict any prior socket from the same client (stale reconnect).
    let evicted = 0;
    if (clientId) {
      for (const ws of allSockets) {
        const att = ws.deserializeAttachment() as { clientId?: string } | null;
        if (att?.clientId === clientId) {
          try { ws.close(1000, "superseded by newer connection"); } catch { /* already closed */ }
          evicted++;
        }
      }
    }

    // Re-read after eviction to get the authoritative count.
    let remaining = this.state.getWebSockets();
    let activeSockets = remaining.filter(ws => ws.readyState === 0 || ws.readyState === 1);

    // If room appears full, evict any zombie sockets before giving up.
    // Legitimate peers disconnect their signaling WS within ~30s (on .ready
    // success or on any failure path, post iOS fix for zombie leak). Any
    // socket still here after STALE_THRESHOLD_MS is almost certainly a
    // leaked socket from a prior session whose close frame never propagated
    // — evicting it frees the room for the new joiner.
    //
    // Also probe recent sockets with a ping; if send() throws, the underlying
    // connection is dead and the socket is evictable regardless of age.
    if (activeSockets.length >= MAX_PEERS_PER_ROOM) {
      const now = Date.now();
      const STALE_THRESHOLD_MS = 60 * 1000;
      for (const ws of activeSockets) {
        const att = ws.deserializeAttachment() as { clientId?: string; createdAt?: number } | null;
        const age = att?.createdAt ? now - att.createdAt : Infinity;
        let isStale = age > STALE_THRESHOLD_MS;
        if (!isStale) {
          try {
            ws.send(JSON.stringify({ type: "ping" }));
          } catch {
            isStale = true;
          }
        }
        if (isStale) {
          try { ws.close(1001, "stale socket evicted on capacity overflow"); } catch { /* already closed */ }
          evicted++;
        }
      }
      // Re-read authoritative count after stale eviction.
      remaining = this.state.getWebSockets();
      activeSockets = remaining.filter(ws => ws.readyState === 0 || ws.readyState === 1);
    }

    if (activeSockets.length >= MAX_PEERS_PER_ROOM) {
      return new Response(JSON.stringify({
        error: "Room is full",
        activeSocketCount: activeSockets.length,
        totalSocketCount: remaining.length,
        evicted,
        clientId: clientId ? clientId.slice(0, 8) : null,
      }), {
        status: 409,
        headers: { "Content-Type": "application/json" },
      });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    // Accept with Hibernation API — lets the DO hibernate between messages
    this.state.acceptWebSocket(server);
    if (clientId) {
      server.serializeAttachment({ clientId, createdAt: Date.now() });
    }

    // Notify existing peer(s) that someone joined
    for (const peer of activeSockets) {
      try {
        peer.send(JSON.stringify({ type: "peer-joined" }));
      } catch {
        // Stale socket — will be cleaned up on next event
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  // Hibernation API callbacks ------------------------------------------------

  webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    const allSockets = this.state.getWebSockets();
    const data = typeof message === "string" ? message : new TextDecoder().decode(message);
    for (const peer of allSockets) {
      if (peer !== ws) {
        try {
          peer.send(data);
        } catch {
          // Peer gone — will be cleaned up via webSocketClose/webSocketError
        }
      }
    }
  }

  webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean) {
    try { ws.close(code, reason); } catch { /* already closed */ }
    this.notifyPeerLeft(ws);
  }

  webSocketError(ws: WebSocket, error: unknown) {
    try { ws.close(1011, "WebSocket error"); } catch { /* already closed */ }
    this.notifyPeerLeft(ws);
  }

  private notifyPeerLeft(closedWs: WebSocket) {
    const remaining = this.state.getWebSockets();
    for (const peer of remaining) {
      if (peer !== closedWs) {
        try {
          peer.send(JSON.stringify({ type: "peer-left" }));
        } catch { /* ignore */ }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Durable Object: PreKeyStore
//
// Provides atomic OTP key consumption. Each mailbox ID maps to one DO instance,
// ensuring only one request at a time can consume an OTP key.
// ---------------------------------------------------------------------------

export class PreKeyStore {
  private state: DurableObjectState;
  private env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const mailboxId = url.searchParams.get("mailboxId");
    if (!mailboxId) {
      return jsonResponse({ error: "Missing mailboxId" }, 400);
    }

    // Read bundle from KV
    const raw = await this.env.V2_STORE.get(`keys:${mailboxId}`);
    if (!raw) {
      return jsonResponse({ error: "Key bundle not found" }, 404);
    }

    const bundle = JSON.parse(raw) as {
      identityKey: string; signingKey: string;
      signedPreKey: unknown; oneTimePreKeys?: unknown[];
    };

    // Atomically consume one OTP key (DO guarantees single-threaded execution)
    let consumedOTPK: unknown | undefined;
    if (bundle.oneTimePreKeys && bundle.oneTimePreKeys.length > 0) {
      consumedOTPK = bundle.oneTimePreKeys.shift();
      await this.env.V2_STORE.put(`keys:${mailboxId}`, JSON.stringify(bundle), {
        expirationTtl: 30 * 86400,
      });
    }

    return jsonResponse({
      identityKey: bundle.identityKey,
      signingKey: bundle.signingKey,
      signedPreKey: bundle.signedPreKey,
      oneTimePreKey: consumedOTPK ?? null,
    });
  }
}

// ---------------------------------------------------------------------------
// Durable Object: DeviceInbox
// Each device maps to one DO. Holds the foreground WebSocket for real-time
// invite delivery. Falls back to APNs + KV queue when WS is absent.
// ---------------------------------------------------------------------------

export class DeviceInbox {
  private state: DurableObjectState;
  private env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // GET /ws — upgrade to WebSocket
    if (url.pathname === "/ws" && request.headers.get("Upgrade") === "websocket") {
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.state.acceptWebSocket(server);

      // Flush any queued invites
      const queue = await this.state.storage.list<string>({ prefix: "queue:" });
      for (const [key, value] of queue) {
        try {
          server.send(value);
        } catch { /* socket already bad, abort */ break; }
        await this.state.storage.delete(key);
      }

      return new Response(null, { status: 101, webSocket: client });
    }

    // POST /push — deliver invite (from /v2/invite/:deviceId handler)
    if (url.pathname === "/push" && request.method === "POST") {
      const payload = await request.text();
      const sockets = this.state.getWebSockets();
      if (sockets.length > 0) {
        let delivered = false;
        for (const ws of sockets) {
          try { ws.send(payload); delivered = true; } catch { /* skip */ }
        }
        if (delivered) return jsonResponse({ delivered: "websocket" });
      }

      // No live socket → queue + caller will send APNs
      const queueKey = `queue:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
      await this.state.storage.put(queueKey, payload);
      // Auto-clean old queue entries (keep last 20)
      const all = await this.state.storage.list<string>({ prefix: "queue:" });
      const keys = Array.from(all.keys()).sort();
      while (keys.length > 20) {
        const oldest = keys.shift();
        if (oldest) await this.state.storage.delete(oldest);
      }
      return jsonResponse({ delivered: "queued" });
    }

    return new Response("Not Found", { status: 404 });
  }

  // Hibernation API
  webSocketClose(ws: WebSocket) {
    try { ws.close(); } catch { /* already closed */ }
  }
  webSocketError(ws: WebSocket) {
    try { ws.close(1011, "error"); } catch { /* already closed */ }
  }
}
