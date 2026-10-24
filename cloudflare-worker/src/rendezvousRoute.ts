// Worker-side front for the anonymous rendezvous room (Project E).
//
//   GET  /rv      WebSocket; first text frame = {"v":1,"t":<token>,"pow":{h,n}}
//   POST /rv/ice  body = {"t":<token>,"pow":{h,n}} -> STUN/TURN config
//
// CLIENT LIVENESS CONTRACT (binding for the Swift side):
//   Clients MUST send the TEXT frame exactly "ping" at least every 30 s.
//   Only text frames reach this bridge's listener; WebSocket-protocol pings
//   (URLSessionWebSocketTask.sendPing) are handled by the runtime, never reach
//   it, and do NOT count: such a client would be cut after 90 s of "silence".
//   The 2 h hard cap cuts even active sessions: reconnect with the SAME `s`.
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
  parseSessionId,
  verifyRendezvousClaim,
} from "./rendezvousPow";
import { RV_CLOSE_CODE, RV_CLOSE_REASON, RV_IDLE_MS, RV_SESSION_HEADER } from "./rendezvousRoom";
import { buildIceServers } from "./turnIce";

interface RvEnv {
  RENDEZVOUS_ROOM: DurableObjectNamespace;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
}

export const RV_RATE_LIMIT_MAX = 12;
export const RV_RATE_WINDOW_MS = 60_000;
export const RV_FIRST_FRAME_TIMEOUT_MS = 5_000;
/** Test hook: shrink the table cap. Production value stays 20_000. */
export const rvTestHooks = { maxEntries: 20_000 };
export function rvTableSizes() {
  return { attempts: attempts.size, ipHandshakes: ipHandshakes.size, ipUnauthOpen: ipUnauthOpen.size };
}

/** Key IPv6 by its /64 prefix (one subscriber = one /64); IPv4 unchanged. */
export function ipBucket(ip: string): string {
  if (!ip.includes(":")) return ip;
  let a = ip.toLowerCase();
  const zone = a.indexOf("%");
  if (zone >= 0) a = a.slice(0, zone);
  const [headRaw, tailRaw] = a.split("::");
  const head = headRaw ? headRaw.split(":") : [];
  const tail = tailRaw !== undefined && tailRaw ? tailRaw.split(":") : [];
  const fill = a.includes("::") ? Array(Math.max(0, 8 - head.length - tail.length)).fill("0") : [];
  const groups = [...head, ...fill, ...tail].map((g) => (g || "0").replace(/^0+(?=.)/, ""));
  return "v6:" + groups.slice(0, 4).join(":");
}
const MAX_PENDING_FRAMES = 8;
const MAX_PENDING_BYTES = 64 * 1024;
/** Client pings every 30 s; 90 s of total silence closes the bridge (one-sided liveness). */
export const RV_LIVENESS_MS = 90_000;
// Looser per-IP-hash caps, independent of the token (memory only, per isolate).
const IP_HANDSHAKES_PER_MIN = 60;
const IP_MAX_UNAUTH_SOCKETS = 8;

export interface RvDeps {
  setTimeout: (fn: () => void, ms: number) => any;
  clearTimeout: (id: any) => void;
  livenessMs: number;
  firstFrameMs: number;
  hardCapMs: number;
}
const realDeps: RvDeps = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (id) => clearTimeout(id),
  livenessMs: RV_LIVENESS_MS,
  firstFrameMs: RV_FIRST_FRAME_TIMEOUT_MS,
  hardCapMs: RV_IDLE_MS,
};

// ---------------------------------------------------------------------------
// In-memory rate limiter (NO KV). Per-isolate salt: nothing stable is stored.
// ---------------------------------------------------------------------------
const salt = crypto.getRandomValues(new Uint8Array(16));
const attempts = new Map<string, { windowStart: number; count: number }>();
const ipHandshakes = new Map<string, { windowStart: number; count: number }>();
const ipUnauthOpen = new Map<string, number>();
let lastSweep = 0;

async function sha256Hex(v: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v)));
  let hex = "";
  for (const b of d) hex += b.toString(16).padStart(2, "0");
  return hex;
}

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
  const max = rvTestHooks.maxEntries;
  if (now - lastSweep < RV_RATE_WINDOW_MS && attempts.size < max && ipHandshakes.size < max && ipUnauthOpen.size < max) return;
  lastSweep = now;
  for (const [k, v] of attempts) {
    if (now - v.windowStart >= RV_RATE_WINDOW_MS) attempts.delete(k);
  }
  for (const [k, v] of ipHandshakes) {
    if (now - v.windowStart >= RV_RATE_WINDOW_MS) ipHandshakes.delete(k);
  }
  if (attempts.size >= rvTestHooks.maxEntries) attempts.clear(); // memory guard
  if (ipHandshakes.size >= rvTestHooks.maxEntries) ipHandshakes.clear();
  if (ipUnauthOpen.size >= rvTestHooks.maxEntries) ipUnauthOpen.clear();
}

/** Returns true if this attempt is allowed (and counts it). */
async function allowAttempt(kind: "ws" | "ice", ip: string, token: string, now: number): Promise<boolean> {
  sweep(now);
  const key = `${kind}:${await saltedHash("ip", ipBucket(ip))}:${await saltedHash("t", token)}`;
  const e = attempts.get(key);
  if (!e || now - e.windowStart >= RV_RATE_WINDOW_MS) {
    attempts.set(key, { windowStart: now, count: 1 });
    return true;
  }
  if (e.count >= RV_RATE_LIMIT_MAX) return false;
  e.count++;
  return true;
}

interface Admitted { token: string; sid: string }

/** Parse + size-check + rate-limit + PoW. Returns the canonical token (+ session id) or null (all failures alike). */
async function admit(kind: "ws" | "ice", raw: string, ip: string): Promise<Admitted | null> {
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
  const token = await verifyRendezvousClaim(claim, now);
  if (token === null) return null;
  const sid = kind === "ws" ? parseSessionId(claim) : "";
  if (sid === null) return null;
  return { token, sid };
}

/** Per-IP-hash gate: returns {deny} or a key to release the unauth slot with. */
async function ipGate(ip: string): Promise<{ deny: boolean; key: string | null }> {
  if (!ip || ip === "unknown") return { deny: false, key: null };
  const now = Date.now();
  sweep(now);
  const key = await saltedHash("ipcap", ipBucket(ip));
  const e = ipHandshakes.get(key);
  if (!e || now - e.windowStart >= RV_RATE_WINDOW_MS) ipHandshakes.set(key, { windowStart: now, count: 1 });
  else if (e.count >= IP_HANDSHAKES_PER_MIN) return { deny: true, key: null };
  else e.count++;
  const open = ipUnauthOpen.get(key) ?? 0;
  if (open >= IP_MAX_UNAUTH_SOCKETS) return { deny: true, key: null };
  ipUnauthOpen.set(key, open + 1);
  return { deny: false, key };
}
function ipRelease(key: string | null): void {
  if (!key) return;
  const n = (ipUnauthOpen.get(key) ?? 1) - 1;
  if (n <= 0) ipUnauthOpen.delete(key); else ipUnauthOpen.set(key, n);
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

/** Read at most `limit` bytes; null if the body is larger. */
async function readCapped(request: Request, limit: number): Promise<string | null> {
  const cl = request.headers.get("Content-Length");
  if (cl !== null && !(Number(cl) <= limit)) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) { try { await reader.cancel(); } catch { /* ignore */ } return null; }
    chunks.push(value);
  }
  const buf = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { buf.set(c, off); off += c.byteLength; }
  return new TextDecoder().decode(buf);
}

async function handleIce(request: Request, env: RvEnv): Promise<Response> {
  if (request.method !== "POST") return denied();
  let raw: string | null;
  try { raw = await readCapped(request, RV_MAX_FRAME_BYTES); } catch { return denied(); }
  if (raw === null) return denied();
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

async function handleSocket(request: Request, env: RvEnv, deps: RvDeps): Promise<Response> {
  if (request.headers.get("Upgrade") !== "websocket") return denied();
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const gate = await ipGate(ip);
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);
  server.accept();
  if (gate.deny) {
    closeGeneric(server);
    return new Response(null, { status: 101, webSocket: client });
  }
  let slotKey = gate.key;
  const releaseSlot = () => { ipRelease(slotKey); slotKey = null; };

  let upstream: WebSocket | null = null;
  let done = false;
  let gotFirst = false;
  const pending: (string | ArrayBuffer)[] = [];
  let pendingBytes = 0;
  let livenessTimer: any;
  let hardCapTimer: any;
  let firstFrameTimer: any;

  const finish = () => {
    if (done) return;
    done = true;
    releaseSlot();
    deps.clearTimeout(firstFrameTimer);
    deps.clearTimeout(livenessTimer);
    deps.clearTimeout(hardCapTimer);
    closeGeneric(server);
    if (upstream) { try { upstream.close(1000, ""); } catch { /* closed */ } }
  };
  // Liveness is one-sided and identity-free: ANY client frame (a ping counts)
  // re-arms it. It proves only that this socket was heard from.
  const armLiveness = () => {
    deps.clearTimeout(livenessTimer);
    livenessTimer = deps.setTimeout(finish, deps.livenessMs);
  };
  firstFrameTimer = deps.setTimeout(finish, deps.firstFrameMs);

  const connectUpstream = async (raw: string) => {
    const adm = await admit("ws", raw, ip);
    if (adm === null || done) { finish(); return; }
    const stub = env.RENDEZVOUS_ROOM.get(env.RENDEZVOUS_ROOM.idFromName(adm.token));
    const headers: Record<string, string> = { Upgrade: "websocket" };
    // Pass only SHA-256(token || s) (hex): the DO needs equality, never s itself.
    if (adm.sid) headers[RV_SESSION_HEADER] = await sha256Hex(adm.token + adm.sid);
    let resp: Response;
    try {
      resp = await stub.fetch("https://rv.internal/connect", { headers });
    } catch { finish(); return; }
    const up = resp.webSocket;
    if (resp.status !== 101 || !up) { finish(); return; }
    up.accept();
    if (done) { try { up.close(1000, ""); } catch { /* closed */ } return; }
    upstream = up;
    deps.clearTimeout(firstFrameTimer);
    up.addEventListener("message", (e) => {
      if (done) return;
      try { server.send(e.data as string | ArrayBuffer); } catch { finish(); }
    });
    up.addEventListener("close", finish);
    up.addEventListener("error", finish);
    for (const m of pending.splice(0)) { try { up.send(m); } catch { finish(); return; } }
    pendingBytes = 0;
  };

  server.addEventListener("message", (e) => {
    if (done) return;
    const data = e.data as string | ArrayBuffer;
    if (!gotFirst) {
      gotFirst = true;
      releaseSlot(); // first frame arrived: no longer an unauthenticated socket
      if (typeof data !== "string") { finish(); return; }
      armLiveness();
      deps.clearTimeout(hardCapTimer);
      hardCapTimer = deps.setTimeout(finish, deps.hardCapMs);
      void connectUpstream(data).catch(finish);
      return;
    }
    armLiveness();
    if (upstream) {
      try { upstream.send(data); } catch { finish(); }
      return;
    }
    const size = typeof data === "string" ? data.length * 3 : data.byteLength; // upper bound
    if (pending.length >= MAX_PENDING_FRAMES || pendingBytes + size > MAX_PENDING_BYTES) {
      finish();
      return;
    }
    pending.push(data);
    pendingBytes += size;
  });
  server.addEventListener("close", finish);
  server.addEventListener("error", finish);

  return new Response(null, { status: 101, webSocket: client });
}

/** Entry point. Called from index.ts BEFORE auth and the KV rate limiter. */
export async function handleRendezvous(request: Request, env: RvEnv, path: string, deps: RvDeps = realDeps): Promise<Response> {
  if (path === "/rv/ice") return handleIce(request, env);
  return handleSocket(request, env, deps);
}
