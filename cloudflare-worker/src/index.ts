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
  API_KEY: string; // Shared secret for authenticating iOS clients
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  ANALYTICS_KEY: string;
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
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-API-Key, X-Mailbox-Id, X-Mailbox-Token",
};

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

    // API key authentication (required for room creation, ICE credentials, device registration, and invites)
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
      const providedKey = request.headers.get("X-API-Key") || url.searchParams.get("apiKey");
      if (providedKey !== env.API_KEY) {
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

        // Cloudflare API returns iceServers as an object; normalize to array for iOS client
        const iceServers = Array.isArray(turnData.iceServers)
          ? turnData.iceServers
          : [turnData.iceServers];

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

    // POST /debug/report — receive error report from app
    if (path === "/debug/report" && request.method === "POST") {
      try {
        const body = await request.json() as Record<string, unknown>;
        const reportId = `report:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
        const report = {
          ...body,
          ip: clientIP,
          timestamp: new Date().toISOString(),
          userAgent: request.headers.get("User-Agent") || "unknown",
        };
        await env.ROOMS.put(reportId, JSON.stringify(report), { expirationTtl: 86400 * 7 }); // 7 days
        return new Response(JSON.stringify({ ok: true, id: reportId }), {
          status: 201,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      } catch {
        return new Response(JSON.stringify({ error: "Invalid report" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    // POST /debug/metric — ingest connection telemetry (API_KEY required)
    if (path === "/debug/metric" && request.method === "POST") {
      if (!env.API_KEY || request.headers.get("X-API-Key") !== env.API_KEY) {
        return jsonResponse({ error: "Unauthorized" }, 401);
      }
      // Payload size limit: 4 KB
      const body = await request.text();
      if (body.length > 4 * 1024) {
        return jsonResponse({ error: "Payload too large", size: body.length }, 413);
      }
      let parsed: Record<string, unknown>;
      try { parsed = JSON.parse(body); } catch { return jsonResponse({ error: "Invalid JSON" }, 400); }
      const dateKey = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
      const metricId = `metric:${dateKey}:${crypto.randomUUID()}`;
      await env.METRICS.put(metricId, JSON.stringify({
        ...parsed,
        ingestedAt: new Date().toISOString(),
        ip: clientIP,
      }), { expirationTtl: 14 * 86400 });
      return jsonResponse({ ok: true, id: metricId }, 201);
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

// Helper: JSON response with CORS
function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
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
    const remaining = this.state.getWebSockets();
    const activeSockets = remaining.filter(ws => ws.readyState === 0 || ws.readyState === 1);

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
