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
export const rvTestHooks = { maxEntries: 20_000, now: () => Date.now() };
export function rvTableSizes() {
  return { attempts: attempts.size, ipHandshakes: ipHandshakes.size, ipUnauthOpen: ipUnauthOpen.size };
}

/**
 * Bucket key for per-IP caps. IPv4 unchanged. IPv6 is keyed by its /64 prefix
 * (one subscriber = one /64), EXCEPT addresses that embed an IPv4 client,
 * which are keyed as that IPv4 so distinct clients do not collapse into one
 * bucket: IPv4-mapped (::ffff:a.b.c.d, dotted or hex), NAT64 64:ff9b::/96 and
 * the deprecated IPv4-compatible ::a.b.c.d form.
 */
export function ipBucket(ip: string): string {
  if (!ip.includes(":")) return ip;
  let a = ip.toLowerCase();
  const zone = a.indexOf("%");
  if (zone >= 0) a = a.slice(0, zone);
  // Dotted-quad tail -> two hex groups.
  const dotted = a.match(/^(.*:)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (dotted) {
    const [o1, o2, o3, o4] = dotted.slice(2).map(Number);
    if ([o1, o2, o3, o4].some((o) => o > 255)) return "v6:invalid";
    a = dotted[1] + ((o1 << 8) | o2).toString(16) + ":" + ((o3 << 8) | o4).toString(16);
  }
  const parts = a.split("::");
  if (parts.length > 2) return "v6:invalid";
  const head = parts[0] ? parts[0].split(":") : [];
  const tail = parts.length === 2 && parts[1] ? parts[1].split(":") : [];
  const fillCount = parts.length === 2 ? Math.max(0, 8 - head.length - tail.length) : 0;
  const raw = [...head, ...Array(fillCount).fill("0"), ...tail];
  if (raw.length !== 8) return "v6:invalid";
  const g = raw.map((x) => parseInt(x || "0", 16));
  if (g.some((x) => Number.isNaN(x) || x > 0xffff)) return "v6:invalid";
  const v4 = `${g[6] >> 8}.${g[6] & 255}.${g[7] >> 8}.${g[7] & 255}`;
  const zeros = (from: number, to: number) => g.slice(from, to).every((x) => x === 0);
  if (zeros(0, 5) && g[5] === 0xffff) return v4; // ::ffff:a.b.c.d
  if (g[0] === 0x64 && g[1] === 0xff9b && zeros(2, 6)) return v4; // 64:ff9b::/96
  if (zeros(0, 6) && (g[6] !== 0 || g[7] > 1)) return v4; // ::a.b.c.d (deprecated)
  return "v6:" + g.slice(0, 4).map((x) => x.toString(16)).join(":");
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
// Created lazily on first use: workerd forbids generating random values in the
// global scope ("Disallowed operation called within global scope"), so a
// module-level getRandomValues makes the Worker fail to start (wrangler dev)
// and fail upload validation on deploy. vitest-pool-workers did not catch it.
let salt: Uint8Array | null = null;
function isolateSalt(): Uint8Array {
  if (!salt) salt = crypto.getRandomValues(new Uint8Array(16));
  return salt;
}
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
  const s = isolateSalt();
  const buf = new Uint8Array(s.length + v.length);
  buf.set(s, 0);
  buf.set(v, s.length);
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
  let hex = "";
  for (let i = 0; i < 8; i++) hex += d[i].toString(16).padStart(2, "0");
  return hex;
}

/** Drop entries from expired windows, then, only if still over the cap, the OLDEST (insertion order). */
function evict(map: Map<string, any>, now: number, max: number, timed: boolean): void {
  if (timed) {
    for (const [k, v] of map) if (now - v.windowStart >= RV_RATE_WINDOW_MS) map.delete(k);
  }
  for (const k of map.keys()) {
    if (map.size < max) break;
    map.delete(k);
  }
}

function sweep(now: number): void {
  const max = rvTestHooks.maxEntries;
  if (now - lastSweep < RV_RATE_WINDOW_MS && attempts.size < max && ipHandshakes.size < max && ipUnauthOpen.size < max) return;
  lastSweep = now;
  evict(attempts, now, max, true);
  evict(ipHandshakes, now, max, true);
  evict(ipUnauthOpen, now, max, false);
}

/** Set with fresh insertion position so Map order == window-start order. */
function setFresh<V>(map: Map<string, V>, k: string, v: V): void {
  map.delete(k);
  map.set(k, v);
}

async function allowAttempt(kind: "ws" | "ice", ip: string, token: string, now: number): Promise<boolean> {
  sweep(now);
  const key = `${kind}:${await saltedHash("ip", ipBucket(ip))}:${await saltedHash("t", token)}`;
  const e = attempts.get(key);
  if (!e || now - e.windowStart >= RV_RATE_WINDOW_MS) {
    setFresh(attempts, key, { windowStart: now, count: 1 });
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
  const now = rvTestHooks.now();
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
  const now = rvTestHooks.now();
  sweep(now);
  const key = await saltedHash("ipcap", ipBucket(ip));
  const e = ipHandshakes.get(key);
  if (!e || now - e.windowStart >= RV_RATE_WINDOW_MS) setFresh(ipHandshakes, key, { windowStart: now, count: 1 });
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
