/**
 * Anonymous rendezvous room (/rv) and ICE route (/rv/ice) — Project E, Task 2.
 * PRIVACY is the point: these tests assert that nothing about the request
 * (IP, token, headers) is logged or written to KV.
 */
import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect, vi, afterEach } from "vitest";
import vectors from "../../test-vectors/rendezvous-pow.json";
import { verifyRendezvousClaim } from "../rendezvousPow";
import { handleRendezvous, rvTestHooks, rvTableSizes, ipBucket } from "../rendezvousRoute";

// runInDurableObject's generics trip TS2589; erase them.
const runDO: (stub: any, fn: (inst: any, state: any) => any) => Promise<any> = runInDurableObject as any;
const GENERIC_CLOSE_CODE = 1008;
const GENERIC_CLOSE_REASON = "denied";

function b64u(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function randomToken(): string {
  return b64u(crypto.getRandomValues(new Uint8Array(32)));
}
function fromB64u(s: string): Uint8Array {
  const p = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  return Uint8Array.from(atob(p), (c) => c.charCodeAt(0));
}
function hourNow(): number {
  return Math.floor(Date.now() / 3_600_000);
}
async function leadingZeroBits(token: string, hour: number, nonce: string): Promise<number> {
  const t = fromB64u(token);
  const n = new TextEncoder().encode(nonce);
  const buf = new Uint8Array(t.length + 8 + n.length);
  buf.set(t, 0);
  new DataView(buf.buffer).setBigUint64(t.length, BigInt(hour), false);
  buf.set(n, t.length + 8);
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
  let z = 0;
  for (const b of h) {
    if (b === 0) { z += 8; continue; }
    z += Math.clz32(b) - 24;
    break;
  }
  return z;
}
async function mine(token: string, hour: number): Promise<string> {
  for (let i = 0; ; i++) {
    const n = "n" + i.toString(36);
    if ((await leadingZeroBits(token, hour, n)) >= 16) return n;
  }
}
async function hello(token: string, opts: { hour?: number; nonce?: string; s?: string } = {}): Promise<string> {
  const h = opts.hour ?? hourNow();
  const n = opts.nonce ?? (await mine(token, h));
  const o: any = { v: 1, t: token, pow: { h, n } };
  if (opts.s !== undefined) o.s = opts.s;
  return JSON.stringify(o);
}

let ipCounter = 0;
function freshIp(): string {
  ipCounter++;
  return `203.0.113.${(ipCounter % 250) + 1}`;
}

class TestSocket {
  messages: (string | ArrayBuffer)[] = [];
  closed: { code: number; reason: string } | null = null;
  private waiters: (() => void)[] = [];
  constructor(public ws: WebSocket) {
    ws.accept();
    ws.addEventListener("message", (e) => { this.messages.push(e.data as string | ArrayBuffer); this.wake(); });
    ws.addEventListener("close", (e) => { this.closed = { code: e.code, reason: e.reason }; this.wake(); });
  }
  private wake() { const w = this.waiters; this.waiters = []; w.forEach((f) => f()); }
  async waitFor(pred: () => boolean, ms = 4000): Promise<void> {
    const end = Date.now() + ms;
    while (!pred()) {
      const left = end - Date.now();
      if (left <= 0) throw new Error("timeout waiting; messages=" + JSON.stringify(this.messages) + " closed=" + JSON.stringify(this.closed));
      await new Promise<void>((res) => { this.waiters.push(res); setTimeout(res, Math.min(left, 50)); });
    }
  }
  async nextMessage(): Promise<string | ArrayBuffer> {
    await this.waitFor(() => this.messages.length > 0);
    return this.messages.shift()!;
  }
  send(d: string | ArrayBuffer) { this.ws.send(d); }
}

async function connect(ip = freshIp()): Promise<TestSocket> {
  const resp = await SELF.fetch("https://example.com/rv", {
    headers: { Upgrade: "websocket", "CF-Connecting-IP": ip },
  });
  expect(resp.status).toBe(101);
  return new TestSocket(resp.webSocket!);
}
async function join(token: string, ip = freshIp(), sid?: string): Promise<TestSocket> {
  const s = await connect(ip);
  s.send(await hello(token, { s: sid }));
  return s;
}
async function pair(token = randomToken()): Promise<{ a: TestSocket; b: TestSocket; token: string }> {
  const a = await join(token);
  const b = await join(token);
  await a.waitFor(() => a.messages.length > 0);
  await b.waitFor(() => b.messages.length > 0);
  expect(JSON.parse(a.messages.shift() as string)).toEqual({ t: "joined" });
  expect(JSON.parse(b.messages.shift() as string)).toEqual({ t: "joined" });
  return { a, b, token };
}
function roomStub(token: string): any {
  const ns = (env as any).RENDEZVOUS_ROOM;
  return ns.get(ns.idFromName(token));
}
async function expectDoEmpty(token: string) {
  await runDO(roomStub(token), async (_i: any, state: any) => {
    expect((await state.storage.list()).size).toBe(0);
    expect(await state.storage.getAlarm()).toBeNull();
  });
}
function sid(): string { return b64u(crypto.getRandomValues(new Uint8Array(16))); }
function expectGenericClose(s: TestSocket) {
  expect(s.closed).toEqual({ code: GENERIC_CLOSE_CODE, reason: GENERIC_CLOSE_REASON });
}

afterEach(() => { vi.restoreAllMocks(); });

describe("PoW rule + shared vectors", () => {
  for (const v of (vectors as any).vectors) {
    it(`vector: ${v.name}`, async () => {
      const ok = await verifyRendezvousClaim(
        { v: 1, t: v.token, pow: { h: v.h, n: v.n } },
        v.nowSeconds * 1000,
      );
      expect(ok !== null).toBe(v.valid);
    });
  }
  it("has at least 5 vectors", () => {
    expect((vectors as any).vectors.length).toBeGreaterThanOrEqual(5);
  });
});

describe("/rv pairing and relay", () => {
  it("pairs two sockets, sends joined to both, blind-relays text and binary", async () => {
    const { a, b } = await pair();
    a.send("hello from a");
    expect(await b.nextMessage()).toBe("hello from a");
    b.send("not json {{{ at all");
    expect(await a.nextMessage()).toBe("not json {{{ at all");
    const bin = new Uint8Array([0, 1, 2, 250, 251]).buffer;
    a.send(bin);
    const got = (await b.nextMessage()) as ArrayBuffer;
    expect(Array.from(new Uint8Array(got))).toEqual([0, 1, 2, 250, 251]);
    a.ws.close(1000, "bye"); b.ws.close(1000, "bye");
  });

  it("sends left to the remaining socket when one closes", async () => {
    const { a, b } = await pair();
    a.ws.close(1000, "done");
    expect(JSON.parse((await b.nextMessage()) as string)).toEqual({ t: "left" });
    b.ws.close(1000, "done");
  });

  it("rooms are isolated per token", async () => {
    const p1 = await pair();
    const p2 = await pair();
    p1.a.send("only p1");
    expect(await p1.b.nextMessage()).toBe("only p1");
    await new Promise((r) => setTimeout(r, 100));
    expect(p2.a.messages.length + p2.b.messages.length).toBe(0);
    for (const s of [p1.a, p1.b, p2.a, p2.b]) s.ws.close(1000, "x");
  });

  it("answers ping with pong", async () => {
    const { a, b } = await pair();
    a.send("ping");
    expect(await a.nextMessage()).toBe("pong");
    expect(b.messages.length).toBe(0);
    a.ws.close(1000, "x"); b.ws.close(1000, "x");
  });

  it("third socket is rejected with the generic close and does not evict anyone", async () => {
    const { a, b, token } = await pair();
    // Make both existing sockets "old" is irrelevant: DO must never evict.
    const c = await join(token);
    await c.waitFor(() => c.closed !== null);
    expectGenericClose(c);
    a.send("still alive");
    expect(await b.nextMessage()).toBe("still alive");
    expect(a.closed).toBeNull();
    expect(b.closed).toBeNull();
    a.ws.close(1000, "x"); b.ws.close(1000, "x");
  });
});

describe("/rv failures are indistinguishable", () => {
  async function failureOf(frame: string | ArrayBuffer | null, ip = freshIp()): Promise<TestSocket> {
    const s = await connect(ip);
    if (frame !== null) s.send(frame);
    await s.waitFor(() => s.closed !== null, 8000);
    return s;
  }

  it("bad JSON, bad version, bad token, bad hour, bad PoW, oversize, binary first frame", async () => {
    const tok = randomToken();
    const goodNonce = await mine(tok, hourNow());
    const cases: (string | ArrayBuffer)[] = [
      "not json",
      JSON.stringify({ v: 2, t: tok, pow: { h: hourNow(), n: goodNonce } }),
      JSON.stringify({ v: 1, t: "short", pow: { h: hourNow(), n: "x" } }),
      JSON.stringify({ v: 1, t: b64u(new Uint8Array(31)), pow: { h: hourNow(), n: "x" } }),
      JSON.stringify({ v: 1, t: tok + "=", pow: { h: hourNow(), n: goodNonce } }),
      JSON.stringify({ v: 1, t: tok, pow: { h: hourNow() - 2, n: await mine(tok, hourNow() - 2) } }),
      JSON.stringify({ v: 1, t: tok, pow: { h: hourNow() + 1, n: await mine(tok, hourNow() + 1) } }),
      JSON.stringify({ v: 1, t: tok, pow: { h: hourNow(), n: "0" } }),
      JSON.stringify({ v: 1, t: tok, pow: { h: String(hourNow()), n: goodNonce } }),
      JSON.stringify({ v: 1, t: tok, pow: { h: hourNow(), n: goodNonce }, pad: "x".repeat(600) }),
      new Uint8Array([1, 2, 3]).buffer,
    ];
    const seen = new Set<string>();
    for (const c of cases) {
      const s = await failureOf(c);
      expectGenericClose(s);
      seen.add(`${s.closed!.code}|${s.closed!.reason}`);
    }
    expect(seen.size).toBe(1);
  });

  it("accepts a previous-hour PoW", async () => {
    const tok = randomToken();
    const s = await connect();
    s.send(await hello(tok, { hour: hourNow() - 1 }));
    const t = await join(tok);
    await s.waitFor(() => s.messages.length > 0);
    expect(JSON.parse(s.messages[0] as string)).toEqual({ t: "joined" });
    s.ws.close(1000, "x"); t.ws.close(1000, "x");
  });

  it("closes with the generic close when no first frame arrives within 5 s", async () => {
    const s = await failureOf(null);
    expectGenericClose(s);
  }, 15000);

  it("rate limit: 13th attempt for the same (ip, token) is closed generically", async () => {
    const ip = freshIp();
    const tok = randomToken();
    const nonce = await mine(tok, hourNow());
    const frame = JSON.stringify({ v: 1, t: tok, pow: { h: hourNow(), n: nonce } });
    // 12 attempts: some pair, some hit "room full" - all consume the budget.
    for (let i = 0; i < 12; i++) {
      const s = await connect(ip);
      s.send(frame);
      await new Promise((r) => setTimeout(r, 30));
      s.ws.close(1000, "x");
    }
    await new Promise((r) => setTimeout(r, 200)); // let the room empty
    // Control: a different IP with the same token is admitted and stays open.
    const control = await connect(freshIp());
    control.send(frame);
    await new Promise((r) => setTimeout(r, 300));
    expect(control.closed).toBeNull();
    control.ws.close(1000, "x");
    await new Promise((r) => setTimeout(r, 200));
    // The 13th attempt from the original IP would be admitted (room is empty)
    // were it not rate limited, so a generic close proves the limiter fired.
    const last = await connect(ip);
    last.send(frame);
    await last.waitFor(() => last.closed !== null);
    expectGenericClose(last);
  });

  it("rate limit does not leak through the shared 'room' KV bucket and uses no KV", async () => {
    const before = await env.ROOMS.list({ prefix: "rl:" });
    const ip = freshIp();
    for (let i = 0; i < 3; i++) {
      const s = await connect(ip);
      s.send("garbage");
      await s.waitFor(() => s.closed !== null);
    }
    const after = await env.ROOMS.list({ prefix: "rl:" });
    expect(after.keys.length).toBe(before.keys.length);
  });
});

describe("/rv idle cap (injected clock)", () => {
  it("closes all sockets after 2 h without frames, and not before", async () => {
    const { a, b, token } = await pair();
    const stub = roomStub(token);
    await runDO(stub, async (inst: any) => {
      const base = Date.now();
      inst.now = () => base + 119 * 60_000;
      inst.checkIdle();
      expect(inst.ctx.getWebSockets().length).toBe(2);
      inst.now = () => base + 2 * 3600_000 + 1000;
      inst.checkIdle();
    });
    await a.waitFor(() => a.closed !== null);
    await b.waitFor(() => b.closed !== null);
    expectGenericClose(a);
    expectGenericClose(b);
  });

  it("a frame resets the idle timer", async () => {
    const { a, b, token } = await pair();
    const stub = roomStub(token);
    await runDO(stub, async (inst: any) => {
      const base = Date.now();
      inst.now = () => base + 100 * 60_000;
      inst.touch(inst.ctx.getWebSockets()[0]);
      inst.now = () => base + 200 * 60_000; // 100 min after the touch
      inst.checkIdle();
      expect(inst.ctx.getWebSockets().length).toBe(2);
    });
    a.ws.close(1000, "x"); b.ws.close(1000, "x");
  });
});

describe("POST /rv/ice", () => {
  async function postIce(body: unknown, headers: Record<string, string> = {}): Promise<Response> {
    return SELF.fetch("https://example.com/rv/ice", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": freshIp(), ...headers },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
  }

  it("returns ICE config without Authorization and without any room token", async () => {
    const t = randomToken();
    const r = await postIce({ t, pow: { h: hourNow(), n: await mine(t, hourNow()) } });
    expect(r.status).toBe(200);
    const j = (await r.json()) as any;
    expect(Array.isArray(j.iceServers)).toBe(true);
    expect(j.iceServers.length).toBeGreaterThan(0);
    expect(Object.keys(j)).toEqual(["iceServers"]);
    expect(JSON.stringify(j)).not.toContain(t);
    expect(r.headers.get("Set-Cookie")).toBeNull();
  });

  it("all failures return the identical status and body", async () => {
    const t = randomToken();
    const good = await mine(t, hourNow());
    const bodies: unknown[] = [
      "not json",
      { t, pow: { h: hourNow(), n: "0" } },
      { t: "short", pow: { h: hourNow(), n: good } },
      { t, pow: { h: hourNow() - 2, n: await mine(t, hourNow() - 2) } },
      { t, pow: { h: hourNow(), n: good }, pad: "x".repeat(600) },
      {},
    ];
    const seen = new Set<string>();
    for (const b of bodies) {
      const r = await postIce(b);
      seen.add(`${r.status}|${await r.text()}`);
    }
    expect(seen.size).toBe(1);
    expect([...seen][0].startsWith("403|")).toBe(true);
  });

  it("rate limited after 12 attempts per (ip, token), with the same generic failure", async () => {
    const ip = freshIp();
    const t = randomToken();
    const body = { t, pow: { h: hourNow(), n: await mine(t, hourNow()) } };
    for (let i = 0; i < 12; i++) {
      const r = await postIce(body, { "CF-Connecting-IP": ip });
      expect(r.status).toBe(200);
    }
    const r = await postIce(body, { "CF-Connecting-IP": ip });
    const bad = await postIce("nope", { "CF-Connecting-IP": ip });
    expect(r.status).toBe(403);
    expect(await r.text()).toBe(await bad.text());
  });
});

describe("existing routes unchanged", () => {
  it("POST /room still requires auth", async () => {
    const r = await SELF.fetch("https://example.com/room", { method: "POST" });
    expect(r.status).toBe(401);
  });
  it("POST /room/:code/ice still requires auth", async () => {
    const r = await SELF.fetch("https://example.com/room/ABCDEF/ice", { method: "POST" });
    expect(r.status).toBe(401);
  });
  it("/room is still rate limited via KV and /rv traffic does not consume that bucket", async () => {
    const ip = "198.51.100.77";
    for (let i = 0; i < 40; i++) {
      const s = await SELF.fetch("https://example.com/rv", { headers: { Upgrade: "websocket", "CF-Connecting-IP": ip } });
      const ts = new TestSocket(s.webSocket!);
      ts.ws.close(1000, "x");
    }
    const r = await SELF.fetch("https://example.com/room", { method: "POST", headers: { "X-API-Key": "test-api-key-12345", "CF-Connecting-IP": ip } });
    expect(r.status).toBe(201);
  });
});

describe("PRIVACY: no logging, no KV writes", () => {
  it("a full /rv session and /rv/ice call touch no console and no KV", async () => {
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((m) => vi.spyOn(console, m));
    const kvSpies = ([env.ROOMS, env.V2_STORE, env.METRICS] as any[]).flatMap((kv) =>
      (["put", "delete"] as const).map((m) => vi.spyOn(kv, m)));
    const dbSpy = vi.spyOn(env.ACCOUNTS_DB as any, "prepare");
    const snap = async () => ({
      rooms: (await env.ROOMS.list()).keys.map((k) => k.name).sort(),
      v2: (await env.V2_STORE.list()).keys.map((k) => k.name).sort(),
      metrics: (await env.METRICS.list()).keys.map((k) => k.name).sort(),
    });
    const before = await snap();

    const { a, b, token } = await pair();
    a.send("x"); await b.nextMessage();
    const c = await join(token); await c.waitFor(() => c.closed !== null);
    const bad = await connect(); bad.send("garbage"); await bad.waitFor(() => bad.closed !== null);
    a.ws.close(1000, "x");
    await b.nextMessage();
    b.ws.close(1000, "x");
    const t = randomToken();
    await SELF.fetch("https://example.com/rv/ice", {
      method: "POST",
      body: JSON.stringify({ t, pow: { h: hourNow(), n: await mine(t, hourNow()) } }),
    });
    await SELF.fetch("https://example.com/rv/ice", { method: "POST", body: "junk" });

    const after = await snap();
    expect(after).toEqual(before);
    expect([...after.rooms, ...after.v2, ...after.metrics].some((k) => k.startsWith("wslog:"))).toBe(false);
    for (const s of spies) expect(s).not.toHaveBeenCalled();
    for (const s of kvSpies) expect(s).not.toHaveBeenCalled();
    expect(dbSpy).not.toHaveBeenCalled();
    // DO storage stays empty after a full session (no data, no alarm).
    const p2 = await pair();
    p2.a.send("y"); await p2.b.nextMessage();
    await runDO(roomStub(p2.token), async (_i: any, state: DurableObjectState) => {
      expect((await state.storage.list()).size).toBe(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
    p2.a.ws.close(1000, "x"); p2.b.ws.close(1000, "x");
  });
});


// ---------------------------------------------------------------------------
// Fix round 1: canonical tokens, liveness, takeover, per-IP caps, hardening
// ---------------------------------------------------------------------------
function fakeTimers() {
  let now = 0;
  let nextId = 1;
  const items = new Map<number, { at: number; fn: () => void }>();
  return {
    setTimeout: (fn: () => void, ms: number) => { const id = nextId++; items.set(id, { at: now + ms, fn }); return id as any; },
    clearTimeout: (id: any) => { items.delete(id); },
    advance(ms: number) {
      const end = now + ms;
      for (;;) {
        let best: [number, { at: number; fn: () => void }] | null = null;
        for (const e of items) if (e[1].at <= end && (!best || e[1].at < best[1].at)) best = e;
        if (!best) break;
        items.delete(best[0]);
        now = best[1].at;
        best[1].fn();
      }
      now = end;
    },
  };
}
async function directConnect(timers: ReturnType<typeof fakeTimers>, ip = freshIp()): Promise<TestSocket> {
  const resp = await handleRendezvous(
    new Request("https://example.com/rv", { headers: { Upgrade: "websocket", "CF-Connecting-IP": ip } }),
    env as any, "/rv",
    { setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout, livenessMs: 90_000, firstFrameMs: 5_000, hardCapMs: 7_200_000 },
  );
  expect(resp.status).toBe(101);
  return new TestSocket(resp.webSocket!);
}

describe("M-1 canonical token encoding", () => {
  it("rejects non-canonical spellings of the same 32 bytes", async () => {
    const tok = randomToken();
    const nonce = await mine(tok, hourNow());
    const ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const last = ALPHA.indexOf(tok[tok.length - 1]);
    const claim = (t: string) => ({ v: 1, t, pow: { h: hourNow(), n: nonce } });
    expect(await verifyRendezvousClaim(claim(tok), Date.now())).toBe(tok);
    for (const flip of [1, 2, 3]) {
      const variant = tok.slice(0, -1) + ALPHA[last ^ flip];
      expect(await verifyRendezvousClaim(claim(variant), Date.now())).toBeNull();
    }
    expect(await verifyRendezvousClaim(claim(tok + "="), Date.now())).toBeNull();
  });
});

describe("I-2 liveness bridge (injected timers)", () => {
  it("pings keep the bridge alive; 90 s of silence closes it generically and peer gets left", async () => {
    const timers = fakeTimers();
    const token = randomToken();
    const a = await directConnect(timers);
    a.send(await hello(token));
    const b = await join(token);
    await a.waitFor(() => a.messages.length > 0);
    await b.waitFor(() => b.messages.length > 0);
    a.messages.length = 0; b.messages.length = 0;
    for (let i = 0; i < 4; i++) {
      timers.advance(60_000);
      a.send("ping");
      await a.waitFor(() => a.messages.length > i);
    }
    expect(a.closed).toBeNull();
    timers.advance(91_000);
    await a.waitFor(() => a.closed !== null);
    expectGenericClose(a);
    await b.waitFor(() => b.messages.some((m) => m === '{"t":"left"}'));
    b.ws.close(1000, "x");
  });
});

describe("I-2 DO eviction and takeover", () => {
  it("a stale socket (no frames, no pings > 90 s) is evicted by a joiner; the live one is not", async () => {
    const { a, b, token } = await pair();
    await runDO(roomStub(token), async (inst: any) => {
      const base = Date.now();
      inst.now = () => base + 100_000;
      const [w0] = inst.ctx.getWebSockets();
      inst.touch(w0); // w0 is live "now"; w1 stays stale
    });
    const c = await join(token);
    await c.waitFor(() => c.messages.length > 0);
    expect(JSON.parse(c.messages[0] as string)).toEqual({ t: "joined" });
    // Exactly one of a/b was evicted, the other survived and was told left then joined.
    await new Promise((r) => setTimeout(r, 200));
    const evicted = [a, b].filter((x) => x.closed !== null);
    const live = [a, b].filter((x) => x.closed === null);
    expect(evicted.length).toBe(1);
    expectGenericClose(evicted[0]);
    expect(live[0].messages.map((m) => JSON.parse(m as string).t)).toEqual(["left", "joined"]);
    await expectDoEmpty(token);
    live[0].ws.close(1000, "x"); c.ws.close(1000, "x");
  });

  it("when both sockets are live a third is rejected and nobody is evicted", async () => {
    const { a, b, token } = await pair();
    const c = await join(token);
    await c.waitFor(() => c.closed !== null);
    expectGenericClose(c);
    expect(a.closed).toBeNull(); expect(b.closed).toBeNull();
    a.ws.close(1000, "x"); b.ws.close(1000, "x");
  });

  it("same session id takes over the slot instantly: left then joined for the survivor, s never forwarded", async () => {
    const token = randomToken();
    const s1 = sid();
    const a = await join(token, freshIp(), s1);
    const b = await join(token, freshIp(), sid());
    await a.waitFor(() => a.messages.length > 0);
    await b.waitFor(() => b.messages.length > 0);
    a.messages.length = 0; b.messages.length = 0;
    const a2 = await join(token, freshIp(), s1);
    await a.waitFor(() => a.closed !== null);
    await a2.waitFor(() => a2.messages.length > 0);
    await b.waitFor(() => b.messages.length >= 2);
    expect(b.closed).toBeNull();
    expect(b.messages.map((m) => JSON.parse(m as string).t)).toEqual(["left", "joined"]);
    expect(JSON.parse(a2.messages[0] as string)).toEqual({ t: "joined" });
    expect(JSON.stringify([...a2.messages, ...b.messages])).not.toContain(s1);
    b.messages.length = 0;
    a2.send("hi");
    expect(await b.nextMessage()).toBe("hi");
    await expectDoEmpty(token);
    // N-2: the DO only ever sees a token-bound hash of s, never s itself.
    await runDO(roomStub(token), async (inst: any) => {
      for (const w of inst.ctx.getWebSockets()) {
        const att = w.deserializeAttachment();
        if (att?.s !== undefined) {
          expect(att.s).not.toBe(s1);
          expect(att.s).toMatch(/^[0-9a-f]{64}$/);
        }
      }
    });
    a2.ws.close(1000, "x"); b.ws.close(1000, "x");
  });

  it("a different session id does not take over", async () => {
    const token = randomToken();
    const a = await join(token, freshIp(), sid());
    const b = await join(token, freshIp(), sid());
    await a.waitFor(() => a.messages.length > 0);
    const c = await join(token, freshIp(), sid());
    await c.waitFor(() => c.closed !== null);
    expectGenericClose(c);
    expect(a.closed).toBeNull(); expect(b.closed).toBeNull();
    a.ws.close(1000, "x"); b.ws.close(1000, "x");
  });

  it("malformed session id is a generic failure", async () => {
    const token = randomToken();
    const s = await connect();
    s.send(await hello(token, { s: "tooShort" }));
    await s.waitFor(() => s.closed !== null);
    expectGenericClose(s);
  });
});

describe("I-4 per-IP caps", () => {
  it("more than 60 handshakes/min from one IP are closed generically", async () => {
    const ip = freshIp();
    for (let i = 0; i < 60; i++) {
      const s = await connect(ip);
      s.send("x");
      await s.waitFor(() => s.closed !== null);
    }
    // No first frame sent: without the cap this socket would stay open for 5 s.
    const last = await connect(ip);
    await last.waitFor(() => last.closed !== null, 1000);
    expectGenericClose(last);
  }, 30000);

  it("more than 8 concurrent unauthenticated sockets from one IP: the 9th is closed generically", async () => {
    const ip = freshIp();
    const open: TestSocket[] = [];
    for (let i = 0; i < 8; i++) open.push(await connect(ip));
    const ninth = await connect(ip);
    await ninth.waitFor(() => ninth.closed !== null);
    expectGenericClose(ninth);
    expect(open.every((o) => o.closed === null)).toBe(true);
    // once they finish the handshake window the slots free up
    open.forEach((o) => o.send("x"));
    await Promise.all(open.map((o) => o.waitFor(() => o.closed !== null)));
    const again = await connect(ip);
    await new Promise((r) => setTimeout(r, 100));
    expect(again.closed).toBeNull();
    again.send("x");
  });
});

describe("M-3 / M-4 hardening", () => {
  it("/rv/ice rejects a huge body generically", async () => {
    const r = await SELF.fetch("https://example.com/rv/ice", { method: "POST", body: "x".repeat(100_000), headers: { "CF-Connecting-IP": freshIp() } });
    expect(r.status).toBe(403);
    expect(await r.text()).toBe('{"error":"denied"}');
  });
  it("pre-upstream frame buffer is byte capped", async () => {
    const timers = fakeTimers();
    const token = randomToken();
    const a = await directConnect(timers);
    a.send(await hello(token));
    a.send("x".repeat(70_000));
    await a.waitFor(() => a.closed !== null);
    expectGenericClose(a);
  });
  it("literal 'ping' is auto-answered by the DO and never relayed", async () => {
    const { a, b } = await pair();
    a.send("ping");
    expect(await a.nextMessage()).toBe("pong");
    await new Promise((r) => setTimeout(r, 100));
    expect(b.messages.length).toBe(0);
    a.ws.close(1000, "x"); b.ws.close(1000, "x");
  });
});


describe("round 2", () => {
  it("N-1: text 'ping' through the Worker updates the auto-response timestamp, and a ping-only socket is not evicted", async () => {
    const { a, b, token } = await pair();
    await runDO(roomStub(token), async (inst: any) => { inst.staleMs = 400; });
    await new Promise((r) => setTimeout(r, 300));
    a.send("ping");
    await a.waitFor(() => a.messages.length > 0);
    await new Promise((r) => setTimeout(r, 250));
    a.send("ping");
    await a.waitFor(() => a.messages.length > 1);
    await runDO(roomStub(token), async (inst: any) => {
      const all = inst.ctx.getWebSockets();
      // getWebSockets() order is not accept order: find the socket that was pinged.
      const pinged = all.filter((w: any) => inst.ctx.getWebSocketAutoResponseTimestamp(w) !== null);
      expect(pinged.length).toBe(1);
      const [wa] = pinged;
      const ts = inst.ctx.getWebSocketAutoResponseTimestamp(wa);
      expect(ts).not.toBeNull();
      expect(ts.getTime()).toBeGreaterThan(wa.deserializeAttachment().last);
    });
    // b has been silent > staleMs, a only pinged (<= 250 ms ago)
    const c = await join(token);
    await c.waitFor(() => c.messages.length > 0);
    await new Promise((r) => setTimeout(r, 100));
    expect(b.closed).not.toBeNull();
    expectGenericClose(b);
    expect(a.closed).toBeNull();
    a.ws.close(1000, "x"); c.ws.close(1000, "x");
  });

  it("N-3: tables stay bounded under a flood of distinct IPs", async () => {
    rvTestHooks.maxEntries = 40;
    try {
      const timers = fakeTimers();
      for (let i = 0; i < 120; i++) {
        const sck = await directConnect(timers, `198.18.${Math.floor(i / 250)}.${i % 250}`);
        void sck;
      }
      const sz = rvTableSizes();
      expect(sz.attempts).toBeLessThanOrEqual(41);
      expect(sz.ipHandshakes).toBeLessThanOrEqual(41);
      expect(sz.ipUnauthOpen).toBeLessThanOrEqual(41);
      timers.advance(10_000);
    } finally { rvTestHooks.maxEntries = 20_000; }
  });

  it("N-3: IPv6 addresses in one /64 share the per-IP cap", async () => {
    const timers = fakeTimers();
    const open: TestSocket[] = [];
    for (let i = 0; i < 8; i++) open.push(await directConnect(timers, `2001:db8:1:2:${i}::${i + 1}`));
    const ninth = await directConnect(timers, "2001:db8:1:2:ffff:ffff:ffff:ffff");
    await ninth.waitFor(() => ninth.closed !== null);
    expectGenericClose(ninth);
    const other = await directConnect(timers, "2001:db8:1:3::1"); // different /64
    await new Promise((r) => setTimeout(r, 100));
    expect(other.closed).toBeNull();
    timers.advance(10_000);
  });

  it("N-4: positive control, KV/D1 spies and the list-diff do detect writes", async () => {
    const put = vi.spyOn(env.ROOMS as any, "put");
    await env.ROOMS.put("pc:test", "1");
    expect(put).toHaveBeenCalledTimes(1);
    await env.ROOMS.delete("pc:test");
    const prep = vi.spyOn(env.ACCOUNTS_DB as any, "prepare");
    env.ACCOUNTS_DB.prepare("SELECT 1");
    expect(prep).toHaveBeenCalledTimes(1);
    // A known-writing route changes the KV listing that the privacy test diffs.
    const before = (await env.ROOMS.list()).keys.length;
    const r = await SELF.fetch("https://example.com/room", { method: "POST", headers: { "X-API-Key": "test-api-key-12345", "CF-Connecting-IP": freshIp() } });
    expect(r.status).toBe(201);
    expect((await env.ROOMS.list()).keys.length).toBeGreaterThan(before);
  });
});


describe("round 3", () => {
  it("ipBucket: IPv4-mapped (dotted, hex, mixed case, zone) keys as the underlying IPv4", () => {
    const v4 = ipBucket("1.2.3.4");
    expect(v4).toBe("1.2.3.4");
    for (const f of ["::ffff:1.2.3.4", "::FFFF:1.2.3.4", "::ffff:0102:0304", "0:0:0:0:0:ffff:102:304", "::ffff:1.2.3.4%eth0", "64:ff9b::1.2.3.4", "64:ff9b::102:304"]) {
      expect(ipBucket(f)).toBe(v4);
    }
    expect(ipBucket("::ffff:1.2.3.5")).not.toBe(v4);
    expect(ipBucket("::ffff:5.6.7.8")).not.toBe(ipBucket("::ffff:1.2.3.4"));
  });
  it("ipBucket: plain IPv6 keeps /64 behaviour", () => {
    expect(ipBucket("2001:db8:1:2:aaaa::1")).toBe(ipBucket("2001:DB8:1:2:0:0:0:ffff"));
    expect(ipBucket("2001:db8:1:2::1")).not.toBe(ipBucket("2001:db8:1:3::1"));
    expect(ipBucket("2001:db8:1:2::1").startsWith("v6:")).toBe(true);
  });
  it("overflow evicts stale entries only: an active bucket survives", async () => {
    rvTestHooks.maxEntries = 40;
    const t0 = Date.now();
    try {
      const timers = fakeTimers();
      rvTestHooks.now = () => t0;
      for (let i = 0; i < 35; i++) {
        const sck = await directConnect(timers, `198.19.0.${i + 1}`);
        sck.send("x"); await sck.waitFor(() => sck.closed !== null);
      }
      rvTestHooks.now = () => t0 + 61_000;
      const x = "198.19.9.9";
      const open: TestSocket[] = [];
      for (let i = 0; i < 60; i++) {
        const sck = await directConnect(timers, x);
        sck.send("x"); await sck.waitFor(() => sck.closed !== null);
      }
      for (let i = 0; i < 8; i++) {
        const sck = await directConnect(timers, `198.19.1.${i + 1}`);
        sck.send("x"); await sck.waitFor(() => sck.closed !== null);
      }
      // X exhausted its 60 handshakes this window; the flood must not reset it.
      const ninth = await directConnect(timers, x);
      await ninth.waitFor(() => ninth.closed !== null, 1000);
      expectGenericClose(ninth);
      expect(open.every((o) => o.closed === null)).toBe(true);
      expect(rvTableSizes().ipHandshakes).toBeLessThanOrEqual(41);
      open.forEach((o) => o.ws.close(1000, "x"));
    } finally { rvTestHooks.maxEntries = 20_000; rvTestHooks.now = () => Date.now(); }
  });
});
