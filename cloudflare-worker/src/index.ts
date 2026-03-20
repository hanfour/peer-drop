/**
 * PeerDrop Signaling Worker
 *
 * Lightweight HTTP + WebSocket relay for WebRTC signaling.
 *
 * Endpoints:
 *   POST /room           → Create a new room, returns { roomCode }
 *   GET  /room/:code     → Upgrade to WebSocket for signaling
 *   POST /room/:code/ice → Generate Cloudflare TURN credentials
 */

export interface Env {
  ROOMS: KVNamespace;
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
  const chars: string[] = [];
  for (let i = 0; i < ROOM_CODE_LENGTH; i++) {
    chars.push(ALPHABET[Math.floor(Math.random() * ALPHABET.length)]);
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

// Per-room WebSocket state (in-memory, per worker instance)
const roomSockets = new Map<string, Set<WebSocket>>();

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS headers
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, X-API-Key",
    };

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

      await env.ROOMS.put(roomCode, JSON.stringify({ created: Date.now(), peers: 0 }), {
        expirationTtl: ROOM_TTL_SECONDS,
      });

      return new Response(JSON.stringify({ roomCode }), {
        status: 201,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // WebSocket /room/:code — signaling relay
    const wsMatch = path.match(/^\/room\/([A-Z0-9]{6})$/);
    if (wsMatch && request.headers.get("Upgrade") === "websocket") {
      const code = wsMatch[1];
      const room = await env.ROOMS.get(code);
      if (!room) {
        return new Response(JSON.stringify({ error: "Room not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);

      // Track this socket in the room
      if (!roomSockets.has(code)) {
        roomSockets.set(code, new Set());
      }
      const sockets = roomSockets.get(code)!;

      if (sockets.size >= 2) {
        return new Response(JSON.stringify({ error: "Room is full" }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      sockets.add(server);

      server.accept();

      // Notify existing peer that someone joined
      for (const peer of sockets) {
        if (peer !== server && peer.readyState === WebSocket.READY_STATE_OPEN) {
          peer.send(JSON.stringify({ type: "peer-joined" }));
        }
      }

      server.addEventListener("message", (event) => {
        // Relay to all other peers in the room
        for (const peer of sockets) {
          if (peer !== server && peer.readyState === WebSocket.READY_STATE_OPEN) {
            peer.send(event.data as string);
          }
        }
      });

      server.addEventListener("close", () => {
        sockets.delete(server);
        if (sockets.size === 0) {
          roomSockets.delete(code);
        }
      });

      server.addEventListener("error", () => {
        sockets.delete(server);
        if (sockets.size === 0) {
          roomSockets.delete(code);
        }
      });

      return new Response(null, {
        status: 101,
        webSocket: client,
      });
    }

    // POST /room/:code/ice — generate TURN credentials
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

      // Request TURN credentials from Cloudflare API
      if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) {
        // Return STUN-only fallback if TURN is not configured
        return new Response(
          JSON.stringify({
            iceServers: [
              { urls: ["stun:stun.cloudflare.com:3478"] },
              { urls: ["stun:stun.l.google.com:19302"] },
            ],
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
          iceServers: { urls: string[]; username: string; credential: string }[];
        };

        return new Response(JSON.stringify(turnData), {
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
