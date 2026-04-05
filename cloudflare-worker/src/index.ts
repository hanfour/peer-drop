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

export interface Env {
  ROOMS: KVNamespace;
  SIGNALING_ROOM: DurableObjectNamespace;
  TURN_KEY_ID: string;
  TURN_API_TOKEN: string;
  API_KEY: string; // Shared secret for authenticating iOS clients
}

// Room code: 6 chars, alphanumeric excluding ambiguous chars (0/O/1/I/l)
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const ROOM_CODE_LENGTH = 6;
const ROOM_TTL_SECONDS = 300; // 5 minutes
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
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-API-Key",
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

    // API key authentication (required for room creation and ICE credentials)
    const requiresAuth = (path === "/room" && request.method === "POST") ||
                          (path.match(/^\/room\/[A-Z0-9]{6}\/ice$/) && request.method === "POST");
    if (requiresAuth && env.API_KEY) {
      const providedKey = request.headers.get("X-API-Key");
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
        return new Response(JSON.stringify({ error: "Room not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Validate room token
      const roomInfo = JSON.parse(roomData) as { token?: string };
      const providedToken = url.searchParams.get("token");
      if (roomInfo.token && providedToken !== roomInfo.token) {
        return new Response(JSON.stringify({ error: "Invalid room token" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Forward to Durable Object — same room code always routes to same instance
      const id = env.SIGNALING_ROOM.idFromName(code);
      const stub = env.SIGNALING_ROOM.get(id);
      return stub.fetch(request);
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

    return new Response("Not Found", { status: 404, headers: corsHeaders });
  },
};

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

    const activeSockets = this.state.getWebSockets();
    if (activeSockets.length >= MAX_PEERS_PER_ROOM) {
      return new Response(JSON.stringify({ error: "Room is full" }), {
        status: 409,
        headers: { "Content-Type": "application/json" },
      });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    // Accept with Hibernation API — lets the DO hibernate between messages
    this.state.acceptWebSocket(server);

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
