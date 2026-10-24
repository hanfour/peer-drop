// Worker-side front for the anonymous rendezvous room (Project E).
//
//   GET  /rv      WebSocket; first text frame = {"v":1,"t":<token>,"pow":{h,n}}
//   POST /rv/ice  body = {"t":<token>,"pow":{h,n}} -> STUN/TURN config
//
// PRIVACY CONTRACT (do not weaken):
//   - never console.* anything, never write KV, never write `wslog:`;
//   - nothing derived from the request (IP, headers, token) is persisted;
//     the only state is a short-lived in-memory rate-limit table keyed by
//     salted hashes (random per-isolate salt, never stored);
//   - EVERY failure (bad frame/token/PoW, rate limit, full room, timeout,
//     idle) looks identical: same close code+reason / same HTTP status+body.
//
// The Worker has to read the first frame to learn the token (it is not in the
// URL), so it accepts the client socket, validates, then bridges it to the
// token-named DO. The DO does the hibernating, blind relay.

import {
  RV_MAX_FRAME_BYTES,
  verifyRendezvousClaim,
} from "./rendezvousPow";
import { RV_CLOSE_CODE, RV_CLOSE_REASON, RV_IDLE_MS } from "./rendezvousRoom";
import { buildIceServers } from "./turnIce";

interface RvEnv {
  RENDEZVOUS_ROOM: DurableObjectNamespace;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
}

export const RV_RATE_LIMIT_MAX = 12;
export const RV_RATE_WINDOW_MS = 60_000;
export const RV_FIRST_FRAME_TIMEOUT_MS = 5_000;
const MAX_TABLE_ENTRIES = 20_000;
const MAX_PENDING_FRAMES = 8;

// ---------------------------------------------------------------------------
// In-memory rate limiter (NO KV). Per-isolate salt: nothing stable is stored.
// ---------------------------------------------------------------------------
const salt = crypto.getRandomValues(new Uint8Array(16));
const attempts = new Map<string, { windowStart: number; count: number }>();
let lastSweep = 0;

async function saltedHash(label: string, value: string): Promise<string> {
  const v = new TextEncoder().encode(label + "\0" + value);
  const buf = new Uint8Array(salt.length + v.length);
  buf.set(salt, 0);
  buf.set(v, salt.length);
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
  let hex = "";
  for (let i = 0; i < 8; i++) hex += d[i].toString(16).padStart(2, "0");
  return hex;
}

function sweep(now: number): void {
  if (now - lastSweep < RV_RATE_WINDOW_MS && attempts.size < MAX_TABLE_ENTRIES) return;
  lastSweep = now;
  for (const [k, v] of attempts) {
    if (now - v.windowStart >= RV_RATE_WINDOW_MS) attempts.delete(k);
  }
  if (attempts.size >= MAX_TABLE_ENTRIES) attempts.clear(); // memory guard
}

/** Returns true if this attempt is allowed (and counts it). */
async function allowAttempt(kind: "ws" | "ice", ip: string, token: string, now: number): Promise<boolean> {
  sweep(now);
  const key = `${kind}:${await saltedHash("ip", ip)}:${await saltedHash("t", token)}`;
  const e = attempts.get(key);
  if (!e || now - e.windowStart >= RV_RATE_WINDOW_MS) {
    attempts.set(key, { windowStart: now, count: 1 });
    return true;
  }
  if (e.count >= RV_RATE_LIMIT_MAX) return false;
  e.count++;
  return true;
}

/** Parse + size-check + rate-limit + PoW. Returns the token or null (all failures alike). */
async function admit(kind: "ws" | "ice", raw: string, ip: string): Promise<string | null> {
  if (new TextEncoder().encode(raw).length > RV_MAX_FRAME_BYTES) return null;
  let claim: unknown;
  try { claim = JSON.parse(raw); } catch { return null; }
  // /rv/ice bodies are {"t","pow"} (no version field); the socket hello has v:1.
  if (kind === "ice" && typeof claim === "object" && claim !== null && !("v" in claim)) {
    (claim as { v?: number }).v = 1;
  }
  const now = Date.now();
  // Rate-limit on the claimed token string before spending CPU on PoW.
  const claimedToken = (claim as { t?: unknown } | null)?.t;
  if (typeof claimedToken !== "string" || claimedToken.length > 64) return null;
  if (!(await allowAttempt(kind, ip, claimedToken, now))) return null;
  return verifyRendezvousClaim(claim, now);
}

// ---------------------------------------------------------------------------
// POST /rv/ice
// ---------------------------------------------------------------------------
function denied(): Response {
  return new Response('{"error":"denied"}', {
    status: 403,
    headers: { "Content-Type": "application/json" },
  });
}

async function handleIce(request: Request, env: RvEnv): Promise<Response> {
  if (request.method !== "POST") return denied();
  let raw: string;
  try {
    const buf = await request.arrayBuffer();
    if (buf.byteLength > RV_MAX_FRAME_BYTES) return denied();
    raw = new TextDecoder("utf-8", { fatal: true }).decode(buf);
  } catch {
    return denied();
  }
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  if ((await admit("ice", raw, ip)) === null) return denied();
  const iceServers = await buildIceServers(env);
  return new Response(JSON.stringify({ iceServers }), {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

// ---------------------------------------------------------------------------
// GET /rv (WebSocket)
// ---------------------------------------------------------------------------
function closeGeneric(ws: WebSocket): void {
  try { ws.close(RV_CLOSE_CODE, RV_CLOSE_REASON); } catch { /* already closed */ }
}

function handleSocket(request: Request, env: RvEnv): Response {
  if (request.headers.get("Upgrade") !== "websocket") return denied();
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);
  server.accept();

  let upstream: WebSocket | null = null;
  let done = false;
  let gotFirst = false;
  const pending: (string | ArrayBuffer)[] = [];
  let idleTimer: ReturnType<typeof setTimeout> | undefined;

  const finish = () => {
    if (done) return;
    done = true;
    clearTimeout(firstFrameTimer);
    clearTimeout(idleTimer);
    closeGeneric(server);
    if (upstream) { try { upstream.close(1000, ""); } catch { /* closed */ } }
  };
  const armIdle = () => {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(finish, RV_IDLE_MS);
  };
  const firstFrameTimer = setTimeout(finish, RV_FIRST_FRAME_TIMEOUT_MS);

  const connectUpstream = async (raw: string) => {
    const token = await admit("ws", raw, ip);
    if (token === null || done) { finish(); return; }
    const stub = env.RENDEZVOUS_ROOM.get(env.RENDEZVOUS_ROOM.idFromName(token));
    let resp: Response;
    try {
      resp = await stub.fetch("https://rv.internal/connect", { headers: { Upgrade: "websocket" } });
    } catch { finish(); return; }
    const up = resp.webSocket;
    if (resp.status !== 101 || !up) { finish(); return; }
    up.accept();
    if (done) { try { up.close(1000, ""); } catch { /* closed */ } return; }
    upstream = up;
    clearTimeout(firstFrameTimer);
    armIdle();
    up.addEventListener("message", (e) => {
      if (done) return;
      try { server.send(e.data as string | ArrayBuffer); } catch { finish(); }
    });
    up.addEventListener("close", finish);
    up.addEventListener("error", finish);
    for (const m of pending.splice(0)) { try { up.send(m); } catch { finish(); return; } }
  };

  server.addEventListener("message", (e) => {
    if (done) return;
    const data = e.data as string | ArrayBuffer;
    if (!gotFirst) {
      gotFirst = true;
      if (typeof data !== "string") { finish(); return; }
      void connectUpstream(data).catch(finish);
      return;
    }
    armIdle();
    if (upstream) {
      try { upstream.send(data); } catch { finish(); }
    } else if (pending.length < MAX_PENDING_FRAMES) {
      pending.push(data);
    } else {
      finish();
    }
  });
  server.addEventListener("close", finish);
  server.addEventListener("error", finish);

  return new Response(null, { status: 101, webSocket: client });
}

/** Entry point. Called from index.ts BEFORE auth and the KV rate limiter. */
export async function handleRendezvous(request: Request, env: RvEnv, path: string): Promise<Response> {
  if (path === "/rv/ice") return handleIce(request, env);
  return handleSocket(request, env);
}
