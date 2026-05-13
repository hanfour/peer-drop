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

export interface Env {
  // KV
  ROOMS: KVNamespace;
  V2_STORE: KVNamespace;
  METRICS: KVNamespace;
  // Durable Objects
  SIGNALING_ROOM: DurableObjectNamespace;
  PREKEY_STORE: DurableObjectNamespace;
  DEVICE_INBOX: DurableObjectNamespace;
  // Secrets
  TURN_KEY_ID: string;
  TURN_API_TOKEN: string;
  API_KEY: string; // Shared secret for authenticating iOS clients (legacy — see TOKEN_SECRET)
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  ANALYTICS_KEY: string;
  // Phase B device-token auth. HMAC secret for issuing per-device bearer
  // tokens after App Attest verification. Set via
  // `wrangler secret put TOKEN_SECRET` once the App Attest verifier
  // lands; until then the device-token routes return 501 and clients
  // stay on the legacy X-API-Key path.
  TOKEN_SECRET: string;
  // App identifier inputs for App Attest rpIdHash verification.
  APP_BUNDLE_ID?: string;       // "com.hanfour.peerdrop"
  APP_TEAM_ID?: string;         // "UK48R5KWLV"
  // Set to "true" to also accept App Attest attestations issued by the
  // development environment (AAGUID = "appattestdevelop"). Production
  // worker should leave this unset / "false" so dev-build attestations
  // never produce real tokens.
  APP_ATTEST_ALLOW_DEV?: string;
}

// Room code: 6 chars, alphanumeric excluding ambiguous chars (0/O/1/I/l)
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const ROOM_CODE_LENGTH = 6;
const ROOM_TTL_SECONDS = 600; // 10 minutes
const TURN_TTL_SECONDS = 900; // 15 minutes

// Rate limiting: max requests per IP within the window
const RATE_LIMIT_WINDOW_MS = 60_000; // 1 minute
const RATE_LIMIT_MAX_REQUESTS = 30;

function generateRoomCode(): string {
  const randomBytes = new Uint8Array(ROOM_CODE_LENGTH);
  crypto.getRandomValues(randomBytes);
  const chars: string[] = [];
  for (let i = 0; i < ROOM_CODE_LENGTH; i++) {
    chars.push(ALPHABET[randomBytes[i] % ALPHABET.length]);
  }
  return chars.join("");
}

// Simple in-memory rate limiter (per worker instance)
const rateLimitMap = new Map<string, { count: number; windowStart: number }>();

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = rateLimitMap.get(ip);

  if (!entry || now - entry.windowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitMap.set(ip, { count: 1, windowStart: now });
    return false;
  }

  entry.count++;
  if (entry.count > RATE_LIMIT_MAX_REQUESTS) {
    return true;
  }
  return false;
}

// Periodically clean up stale rate limit entries
function cleanupRateLimits() {
  const now = Date.now();
  for (const [ip, entry] of rateLimitMap) {
    if (now - entry.windowStart > RATE_LIMIT_WINDOW_MS * 2) {
      rateLimitMap.delete(ip);
    }
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

    // Rate limiting
    const clientIP = request.headers.get("CF-Connecting-IP") || "unknown";
    if (isRateLimited(clientIP)) {
      return new Response(
        JSON.stringify({ error: "Too many requests" }),
        { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json", "Retry-After": "60" } }
      );
    }

    // Periodic cleanup
    if (Math.random() < 0.01) cleanupRateLimits();

    // Authentication for tier-2 endpoints (room creation, ICE creds,
    // device registration, invite delivery, inbox WebSocket).
    //
    // During the v5.3 transition window, accept BOTH:
    //   - `Authorization: Bearer <token>` issued by /v2/device/attest
    //     (preferred — per-device, replay-resistant, 15-min TTL)
    //   - legacy `X-API-Key: <bundled-key>` for v5.0–v5.2 clients
    //     that still ship the bundled secret in Info.plist
    //
    // After the transition window we drop the X-API-Key fallback and
    // this block becomes a single Bearer check.
    const requiresAuth = (path === "/room" && request.method === "POST") ||
                          (path.match(/^\/room\/[A-Z0-9]{6}\/ice$/) && request.method === "POST") ||
                          (path === "/v2/device/register" && request.method === "POST") ||
                          (path.match(/^\/v2\/invite\/[a-zA-Z0-9-]{8,64}$/) && request.method === "POST") ||
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
        // Diagnostic: log WS upgrade failures (7-day TTL)
        const logKey = `wslog:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
        await env.ROOMS.put(logKey, JSON.stringify({
          reason: "room_not_found",
          code,
          ip: clientIP,
          ua: request.headers.get("User-Agent") || "",
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
          ip: clientIP,
          ua: request.headers.get("User-Agent") || "",
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
          ip: clientIP,
          ua: request.headers.get("User-Agent") || "",
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

    // POST /debug/metric — ingest connection telemetry (API_KEY required)
    if (path === "/debug/metric" && request.method === "POST") {
      const unauth = requireKey(request, env, "API_KEY");
      if (unauth) return unauth;
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
    // Returns a short-lived bearer token + caches the device's public
    // key for subsequent /v2/device/assert calls. Stub mode until pkijs
    // attestation chain validation lands (see ./deviceToken.ts TODO);
    // returns 501 so the iOS client can detect partial deployment and
    // stay on the X-API-Key fallback.
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
          bundleIdentifier: env.APP_BUNDLE_ID ?? "com.hanfour.peerdrop",
          teamIdentifier: env.APP_TEAM_ID ?? "UK48R5KWLV",
          allowDevelopmentEnvironment: env.APP_ATTEST_ALLOW_DEV === "true",
        });
        // Cache device-pubkey + counter for later assert calls.
        await env.V2_STORE.put(
          `attest:${body.deviceId}`,
          JSON.stringify({
            keyId: body.keyId,
            publicKeyDer: arrayBufferToBase64(result.publicKeyDer),
            receipt: arrayBufferToBase64(result.receipt),
            counter: 0,
            attestedAt: Date.now(),
          }),
          { expirationTtl: 90 * 86400 },
        );
        const token = await issueToken(freshTokenPayload(body.deviceId), env.TOKEN_SECRET);
        return jsonResponse({ token, expiresInSeconds: 15 * 60 }, 201);
      } catch (err) {
        return jsonResponse({ error: String((err as Error).message) }, 400);
      }
    }

    // POST /v2/device/assert — refresh the bearer token by proving the
    // device still controls the Secure Enclave keypair registered at
    // /v2/device/attest time. Stub like /attest above.
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
      };
      try {
        const result = await verifyAppAttestAssertion({
          assertion: base64Decode(body.assertion),
          clientData: base64Decode(body.clientData),
          publicKeyDer: base64Decode(meta.publicKeyDer),
          previousCounter: meta.counter,
          bundleIdentifier: env.APP_BUNDLE_ID ?? "com.hanfour.peerdrop",
          teamIdentifier: env.APP_TEAM_ID ?? "UK48R5KWLV",
        });
        await env.V2_STORE.put(
          `attest:${body.deviceId}`,
          JSON.stringify({ ...JSON.parse(cached), counter: result.newCounter }),
          { expirationTtl: 90 * 86400 },
        );
        const token = await issueToken(freshTokenPayload(body.deviceId), env.TOKEN_SECRET);
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

      // Rate limit registration using in-memory limiter (no IP persisted to KV)
      if (isRateLimited(clientIP)) {
        return jsonResponse({ error: "Too many requests" }, 429);
      }

      // Generate mailbox token if first registration
      const existingMeta = await env.V2_STORE.get(`meta:${body.mailboxId}`);
      let token: string;
      if (existingMeta) {
        const meta = JSON.parse(existingMeta) as { token: string };
        // Verify token if re-registering
        if (body.token && body.token !== meta.token) {
          return jsonResponse({ error: "Invalid token" }, 403);
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

      // Delegate to PreKeyStore Durable Object for atomic OTP key consumption
      const doId = env.PREKEY_STORE.idFromName(mailboxId);
      const stub = env.PREKEY_STORE.get(doId);
      return stub.fetch(new Request(`https://internal/consume?mailboxId=${mailboxId}`, {
        headers: request.headers,
      }));
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
        if (info.platform !== "ios" || !env.APNS_KEY_P8) {
          return jsonResponse({ ok: true, delivered: "queued", apns: "not_configured" });
        }
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
          });
          return jsonResponse({ ok: true, delivered: "apns", apnsStatus: result.status });
        } catch (e) {
          return jsonResponse({ ok: true, delivered: "queued", apns: "send_failed", error: String(e) });
        }
      }

      return jsonResponse({ ok: true, delivered: doResult.delivered });
    }

    return new Response("Not Found", { status: 404, headers: corsHeaders });
  },
};

/**
 * Combined auth check for the tier-2 endpoint set. Returns true if the
 * request carries either a valid Bearer token signed with `TOKEN_SECRET`
 * or the legacy `X-API-Key`. Bearer is checked first so the cheap path
 * shrinks every release as more clients migrate.
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
      // Fall through to X-API-Key — a malformed/expired Bearer should
      // still allow a transition-era client to retry with its bundled
      // key during the deprecation window.
    }
  }
  const providedKey = request.headers.get("X-API-Key") || url.searchParams.get("apiKey");
  return providedKey === env.API_KEY;
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
