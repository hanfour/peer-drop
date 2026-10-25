// Drives the GroupRoom Durable Object directly for the event log, retention
// pruning and the hibernating WebSocket fan-out (Task 3). Non-owner members
// get their current-epoch wrap written straight into storage, since
// /keys/put only lands in a later task.
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { ulid } from "../notes";
import { sha256Hex } from "../groupSig";
import type { GroupRoom, GroupMeta, GroupEvent, Caller } from "../groupRoom";

const stubFor = (name: string) => env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(name));

/** Base64 of `n` identical bytes — right size, not cryptographically real. */
const b64 = (n: number, fill = 7) => {
  let s = "";
  for (let i = 0; i < n; i++) s += String.fromCharCode(fill);
  return btoa(s);
};

const acct = (memberId: string, accountId: string, lane: Caller["lane"] = "bearer"): Caller =>
  ({ memberId, accountId, deviceId: `DEV-${accountId}`, lane });
const anon = (memberId: string, deviceId: string): Caller =>
  ({ memberId, accountId: null, deviceId, lane: "bearer" });

const post = (stub: DurableObjectStub, path: string, body: unknown) =>
  stub.fetch(`https://group${path}`, { method: "POST", body: JSON.stringify(body) });

async function initGroup(stub: DurableObjectStub, accountId: string, opts: { joinPolicy?: string; inviteCode?: string } = {}) {
  const memberId = ulid();
  const r = await post(stub, "/init", {
    groupId: ulid(),
    owner: { memberId, accountId, pubKey: b64(32), pubKeySig: b64(64) },
    ownerWrap: { wrapped: b64(92), sig: b64(64) },
    metaCipher: "METACIPHERSECRET",
    joinPolicy: opts.joinPolicy ?? "anonymousAllowed",
    inviteCode: opts.inviteCode ?? "INVITE01",
  });
  expect(r.status).toBe(201);
  return { owner: acct(memberId, accountId), inviteCode: opts.inviteCode ?? "INVITE01" };
}

async function joinAccount(stub: DurableObjectStub, code: string, accountId: string, opts: { keyed?: boolean } = {}): Promise<Caller> {
  const c = acct(ulid(), accountId);
  const r = await post(stub, "/join", { caller: c, inviteCode: code, member: { memberId: c.memberId, kind: "account", accountId, pubKey: b64(32, 1), pubKeySig: b64(64, 2) } });
  expect(r.status).toBe(201);
  if (opts.keyed !== false) await giveKey(stub, c.memberId);
  return c;
}

async function joinAnon(stub: DurableObjectStub, code: string, deviceId: string): Promise<Caller> {
  const c = anon(ulid(), deviceId);
  const r = await post(stub, "/join", { caller: c, inviteCode: code, member: { memberId: c.memberId, kind: "anon", deviceId, pubKey: b64(32, 3) } });
  expect(r.status).toBe(201);
  await giveKey(stub, c.memberId);
  return c;
}

/** Writes the epoch-1 wrap for `memberId` directly (stand-in for /keys/put). */
async function giveKey(stub: DurableObjectStub, memberId: string, epoch = 1) {
  await runInDurableObject(stub, async (_i: GroupRoom, state) => {
    await state.storage.put(`key:${String(epoch).padStart(10, "0")}:${memberId}`, { wrapped: b64(92), wrappedBy: "X", sig: b64(64), createdAt: Date.now() });
  });
}

const msgBody = (caller: Caller, opts: { eventId?: string; epoch?: number; payloadCipher?: unknown } = {}) =>
  ({ caller, eventId: opts.eventId ?? ulid(), epoch: opts.epoch ?? 1, payloadCipher: opts.payloadCipher ?? b64(40, 9) });
const msg = (stub: DurableObjectStub, caller: Caller, opts: Parameters<typeof msgBody>[1] = {}) =>
  post(stub, "/events/msg", msgBody(caller, opts));
const list = (stub: DurableObjectStub, caller: Caller, extra: Record<string, unknown> = {}) =>
  post(stub, "/events/list", { caller, ...extra });

const padSeq = (n: number) => String(n).padStart(12, "0");

async function getMeta(stub: DurableObjectStub): Promise<GroupMeta> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => (await state.storage.get<GroupMeta>("meta"))!);
}
async function eventsOf(stub: DurableObjectStub): Promise<GroupEvent[]> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list<GroupEvent>({ prefix: "ev:" })).values()]);
}
/** Sets (or, with no argument, restores) the DO's clock seam. */
async function setClock(stub: DurableObjectStub, offsetMs?: number) {
  await runInDurableObject(stub, async (inst: GroupRoom) => {
    inst.now = offsetMs === undefined ? () => Date.now() : () => Date.now() + offsetMs;
  });
}

class TestSocket {
  messages: string[] = [];
  closed: { code: number; reason: string } | null = null;
  private waiters: (() => void)[] = [];
  constructor(public ws: WebSocket) {
    ws.accept();
    ws.addEventListener("message", (e) => { this.messages.push(e.data as string); this.wake(); });
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
  async nextMessage(): Promise<string> {
    await this.waitFor(() => this.messages.length > 0);
    return this.messages.shift()!;
  }
}

async function ticketFor(stub: DurableObjectStub, caller: Caller): Promise<string> {
  const r = await post(stub, "/ws-ticket", { caller });
  expect(r.status).toBe(200);
  const body = await r.json() as { ticket: string; expiresAt: number };
  expect(body.ticket).toMatch(/^[A-Za-z0-9_-]{43}$/);
  return body.ticket;
}
const upgrade = (stub: DurableObjectStub, ticket: string) =>
  stub.fetch(`https://group/ws?ticket=${encodeURIComponent(ticket)}`, { headers: { Upgrade: "websocket" } });
async function connect(stub: DurableObjectStub, caller: Caller): Promise<TestSocket> {
  const resp = await upgrade(stub, await ticketFor(stub, caller));
  expect(resp.status).toBe(101);
  return new TestSocket(resp.webSocket!);
}
const settle = () => new Promise((r) => setTimeout(r, 50));

describe("GroupRoom: msg", () => {
  it("msg is idempotent by eventId and appends one event", async () => {
    const stub = stubFor("ge-msg-idem");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const eventId = ulid();
    const r1 = await msg(stub, owner, { eventId, payloadCipher: b64(16, 5) });
    expect(r1.status).toBe(201);
    const b1 = await r1.json() as { seq: number; event: GroupEvent; recipients: unknown[] };
    expect(b1.seq).toBe(1);
    expect(b1.recipients).toEqual([]);
    expect(b1.event).toMatchObject({ seq: 1, eventId, type: "msg", authorMemberId: owner.memberId, epoch: 1, payloadCipher: b64(16, 5) });

    // Resend (even with a different payload) returns the original, untouched.
    const r2 = await msg(stub, owner, { eventId, payloadCipher: b64(16, 6) });
    expect(r2.status).toBe(200);
    const b2 = await r2.json() as { seq: number; event: GroupEvent; recipients: unknown[] };
    expect(b2).toEqual({ seq: 1, event: b1.event, recipients: [] });
    expect((await eventsOf(stub)).filter((e) => e.type === "msg")).toHaveLength(1);
    expect((await getMeta(stub)).seq).toBe(1);
  });

  it("an eventId already used by another member is 409 event_id_taken", async () => {
    const stub = stubFor("ge-msg-idem-other");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const eventId = ulid();
    expect((await msg(stub, owner, { eventId })).status).toBe(201);
    const r = await msg(stub, b, { eventId });
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "event_id_taken" });
  });

  it("msg with a stale epoch is 409 stale_epoch carrying the current epoch", async () => {
    const stub = stubFor("ge-msg-epoch");
    const { owner } = await initGroup(stub, "OWNERAC1");
    for (const epoch of [0, 2]) {
      const r = await msg(stub, owner, { epoch });
      expect(r.status).toBe(409);
      expect(await r.json()).toEqual({ error: "stale_epoch", epoch: 1 });
    }
    expect(await eventsOf(stub)).toHaveLength(0);
  });

  it("a member without a current-epoch wrap is 403 awaiting_key", async () => {
    const stub = stubFor("ge-msg-await");
    const { inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: false });
    const r = await msg(stub, b);
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "awaiting_key" });
    // A wrap from an old epoch doesn't count either.
    await giveKey(stub, b.memberId, 0);
    expect((await msg(stub, b)).status).toBe(403);
    await giveKey(stub, b.memberId, 1);
    expect((await msg(stub, b)).status).toBe(201);
  });

  it("payload of exactly 8192 bytes passes and 8193 is 413", async () => {
    const stub = stubFor("ge-msg-size");
    const { owner } = await initGroup(stub, "OWNERAC1");
    expect((await msg(stub, owner, { payloadCipher: b64(8192) })).status).toBe(201);
    const r = await msg(stub, owner, { payloadCipher: b64(8193) });
    expect(r.status).toBe(413);
    expect(await r.json()).toEqual({ error: "too_large" });
  });

  it("bad payloads and event ids are 400 and write nothing", async () => {
    const stub = stubFor("ge-msg-bad");
    const { owner } = await initGroup(stub, "OWNERAC1");
    for (const payloadCipher of ["", "abc", " QUJD", "QUJD\n", 42]) {
      const r = await msg(stub, owner, { payloadCipher });
      expect(r.status, String(payloadCipher)).toBe(400);
      expect(await r.json()).toEqual({ error: "bad_payload" });
    }
    for (const eventId of ["srv:join:x", "short", ulid().toLowerCase()]) {
      const r = await msg(stub, owner, { eventId });
      expect(r.status, eventId).toBe(400);
      expect(await r.json()).toEqual({ error: "bad_event_id" });
    }
    expect((await post(stub, "/events/msg", { ...msgBody(owner), epoch: "1" })).status).toBe(400);
    expect(await eventsOf(stub)).toHaveLength(0);
  });

  it("non-members and impersonators are refused", async () => {
    const stub = stubFor("ge-msg-authz");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    expect((await msg(stub, acct(ulid(), "STRANGER"))).status).toBe(403);
    expect((await msg(stub, acct(owner.memberId, "OTHERACC"))).status).toBe(403);
    const a = await joinAnon(stub, inviteCode, "ANONDEV1");
    const keyLane = await msg(stub, { ...a, lane: "key" });
    expect(keyLane.status).toBe(401);
    expect(await keyLane.json()).toEqual({ error: "bearer_required" });
    expect((await msg(stub, a)).status).toBe(201);
  });

  it("31st msg within a minute from one member is 429", async () => {
    const stub = stubFor("ge-msg-rate");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    for (let i = 0; i < 30; i++) expect((await msg(stub, owner)).status).toBe(201);
    const r = await msg(stub, owner);
    expect(r.status).toBe(429);
    expect(await r.json()).toEqual({ error: "rate_limited" });
    // Per member: someone else still gets through.
    expect((await msg(stub, b)).status).toBe(201);
    // And the window slides.
    await setClock(stub, 61_000);
    expect((await msg(stub, owner)).status).toBe(201);
    await setClock(stub);
  });

  it("closed room refuses msg but still lists events", async () => {
    const stub = stubFor("ge-msg-closed");
    const { owner } = await initGroup(stub, "OWNERAC1");
    expect((await msg(stub, owner)).status).toBe(201);
    expect((await post(stub, "/close", { caller: owner })).status).toBe(200);
    const r = await msg(stub, owner);
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "group_closed" });
    const l = await list(stub, owner);
    expect(l.status).toBe(200);
    const body = await l.json() as { events: GroupEvent[]; firstSeq: number };
    expect(body.events.map((e) => e.type)).toEqual(["msg"]);
    expect(body.firstSeq).toBe(1);
  });

  it("uninitialised ids answer 404 on every new endpoint and stay empty", async () => {
    const stub = stubFor("ge-uninit");
    const c = acct(ulid(), "SOMEACC1");
    expect((await msg(stub, c)).status).toBe(404);
    expect((await list(stub, c)).status).toBe(404);
    expect((await post(stub, "/ws-ticket", { caller: c })).status).toBe(404);
    expect((await upgrade(stub, "A".repeat(43))).status).toBe(404);
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      expect((await state.storage.list()).size).toBe(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
  });
});

describe("GroupRoom: events list", () => {
  it("pages with limit / nextSince, clamps limit and rejects non-members", async () => {
    const stub = stubFor("ge-list-page");
    const { owner } = await initGroup(stub, "OWNERAC1");
    for (let i = 0; i < 5; i++) expect((await msg(stub, owner)).status).toBe(201);
    const p1 = await (await list(stub, owner, { limit: 2 })).json() as { events: GroupEvent[]; nextSince?: number; firstSeq: number };
    expect(p1.events.map((e) => e.seq)).toEqual([1, 2]);
    expect(p1.nextSince).toBe(2);
    const p3 = await (await list(stub, owner, { since: 4, limit: 2 })).json() as { events: GroupEvent[]; nextSince?: number };
    expect(p3.events.map((e) => e.seq)).toEqual([5]);
    expect(p3.nextSince).toBeUndefined();
    const p0 = await (await list(stub, owner, { limit: 0 })).json() as { events: GroupEvent[] };
    expect(p0.events).toHaveLength(1);
    expect((await list(stub, owner, { since: "x" })).status).toBe(400);
    expect((await list(stub, acct(ulid(), "STRANGER"))).status).toBe(403);
  });
});

describe("GroupRoom: retention", () => {
  it("events since a pruned range start at firstSeq", async () => {
    const stub = stubFor("ge-prune-5000");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const firstEventId = ulid();
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      const meta = (await state.storage.get<GroupMeta>("meta"))!;
      const now = Date.now();
      let batch: Record<string, unknown> = {};
      for (let seq = 1; seq <= 5003; seq++) {
        const eventId = seq === 1 ? firstEventId : ulid();
        batch[`ev:${padSeq(seq)}`] = { seq, eventId, type: "msg", authorMemberId: owner.memberId, epoch: 1, payloadCipher: "QUJD", createdAt: now };
        batch[`eid:${eventId}`] = seq;
        if (Object.keys(batch).length >= 120) { await state.storage.put(batch); batch = {}; }
      }
      await state.storage.put(batch);
      meta.seq = 5003;
      meta.firstSeq = 1;
      await state.storage.put("meta", meta);
    });
    const r = await msg(stub, owner);
    expect(r.status).toBe(201);
    expect((await r.json() as { seq: number }).seq).toBe(5004);
    const meta = await getMeta(stub);
    expect(meta.firstSeq).toBe(5004 - 5000 + 1);
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      for (let s = 1; s <= 4; s++) expect(await state.storage.get(`ev:${padSeq(s)}`)).toBeUndefined();
      expect(await state.storage.get(`eid:${firstEventId}`)).toBeUndefined();
      expect(await state.storage.get(`ev:${padSeq(5)}`)).toBeDefined();
      expect((await state.storage.list({ prefix: "ev:" })).size).toBe(5000);
    });
    const l = await (await list(stub, owner, { since: 0 })).json() as { events: GroupEvent[]; firstSeq: number; nextSince?: number };
    expect(l.firstSeq).toBe(5);
    expect(l.events[0].seq).toBe(5);
    expect(l.events).toHaveLength(100);
    expect(l.nextSince).toBe(104);
  });

  it("alarm prunes events older than 90 days and expired tickets", async () => {
    const stub = stubFor("ge-alarm");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const now = Date.now();
    const old = now - 91 * 86_400_000;
    const oldIds = [ulid(), ulid(), ulid()];
    await runInDurableObject(stub, async (inst: GroupRoom, state) => {
      const meta = (await state.storage.get<GroupMeta>("meta"))!;
      const w: Record<string, unknown> = {};
      for (let seq = 1; seq <= 5; seq++) {
        const eventId = seq <= 3 ? oldIds[seq - 1] : ulid();
        w[`ev:${padSeq(seq)}`] = { seq, eventId, type: "msg", authorMemberId: owner.memberId, epoch: seq <= 3 ? 1 : 2, payloadCipher: "QUJD", createdAt: seq <= 3 ? old : now - 86_400_000 };
        w[`eid:${eventId}`] = seq;
      }
      w["tkt:aaaa"] = { memberId: owner.memberId, exp: now - 1 };
      w["tkt:bbbb"] = { memberId: owner.memberId, exp: now + 30_000 };
      w["key:0000000002:M1"] = { wrapped: "x", wrappedBy: "x", sig: "x", createdAt: now };
      w["key:0000000003:M1"] = { wrapped: "x", wrappedBy: "x", sig: "x", createdAt: now };
      meta.seq = 5;
      meta.epoch = 3;
      w.meta = meta;
      await state.storage.put(w);
      inst.now = () => now;
      await inst.alarm();
      inst.now = () => Date.now();
      const after = (await state.storage.get<GroupMeta>("meta"))!;
      expect(after.firstSeq).toBe(4);
      expect(after.seq).toBe(5);
      const keys = [...(await state.storage.list()).keys()];
      for (let s = 1; s <= 3; s++) expect(keys).not.toContain(`ev:${padSeq(s)}`);
      for (const id of oldIds) expect(keys).not.toContain(`eid:${id}`);
      expect(keys).toContain(`ev:${padSeq(4)}`);
      expect(keys).not.toContain("tkt:aaaa");
      expect(keys).toContain("tkt:bbbb");
      // Epoch-1 wraps predate every retained event (oldest is epoch 2) → gone.
      expect(keys).not.toContain(`key:0000000001:${owner.memberId}`);
      expect(keys).toContain("key:0000000002:M1");
      expect(keys).toContain("key:0000000003:M1");
      const alarm = await state.storage.getAlarm();
      expect(alarm).toBe(now + 86_400_000);
    });
  });

  it("alarm prunes at most 1,000 per run and reschedules in a minute", async () => {
    const stub = stubFor("ge-alarm-batch");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const now = Date.now();
    await runInDurableObject(stub, async (inst: GroupRoom, state) => {
      const meta = (await state.storage.get<GroupMeta>("meta"))!;
      let batch: Record<string, unknown> = {};
      for (let seq = 1; seq <= 1005; seq++) {
        const eventId = ulid();
        batch[`ev:${padSeq(seq)}`] = { seq, eventId, type: "msg", authorMemberId: owner.memberId, epoch: 1, payloadCipher: "QUJD", createdAt: now - 100 * 86_400_000 };
        batch[`eid:${eventId}`] = seq;
        if (Object.keys(batch).length >= 120) { await state.storage.put(batch); batch = {}; }
      }
      await state.storage.put(batch);
      meta.seq = 1005;
      await state.storage.put("meta", meta);
      inst.now = () => now;
      await inst.alarm();
      expect((await state.storage.get<GroupMeta>("meta"))!.firstSeq).toBe(1001);
      expect(await state.storage.getAlarm()).toBe(now + 60_000);
      await inst.alarm();
      const after = (await state.storage.get<GroupMeta>("meta"))!;
      expect(after.firstSeq).toBe(1006);
      expect((await state.storage.list({ prefix: "ev:" })).size).toBe(0);
      expect((await state.storage.list({ prefix: "eid:" })).size).toBe(0);
      // Current-epoch wraps are kept even with no events left.
      expect(await state.storage.get(`key:0000000001:${owner.memberId}`)).toBeDefined();
      expect(await state.storage.getAlarm()).toBe(now + 86_400_000);
      inst.now = () => Date.now();
    });
    const l = await (await list(stub, owner)).json() as { events: GroupEvent[]; firstSeq: number };
    expect(l).toEqual({ events: [], firstSeq: 1006 });
  });
});

describe("GroupRoom: websocket", () => {
  it("ws ticket is single-use and expires after 60s", async () => {
    const stub = stubFor("ge-ws-ticket");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const t1 = await ticketFor(stub, owner);
    const ok = await upgrade(stub, t1);
    expect(ok.status).toBe(101);
    new TestSocket(ok.webSocket!).ws.close(1000, "x");
    const again = await upgrade(stub, t1);
    expect(again.status).toBe(403);
    expect(await again.json()).toEqual({ error: "denied" });

    const t2 = await ticketFor(stub, owner);
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      // Stored only as a hash.
      const keys = [...(await state.storage.list({ prefix: "tkt:" })).keys()];
      expect(keys).toEqual([`tkt:${await sha256Hex(t2)}`]);
    });
    await setClock(stub, 61_000);
    expect((await upgrade(stub, t2)).status).toBe(403);
    await setClock(stub);
    expect((await upgrade(stub, "garbage")).status).toBe(403);
    expect((await stub.fetch(`https://group/ws?ticket=${t2}`)).status).toBe(400);
    expect((await post(stub, "/ws-ticket", { caller: acct(ulid(), "STRANGER") })).status).toBe(403);
  });

  it("accepting a socket pulls the alarm in to its 2h cap", async () => {
    const stub = stubFor("ge-ws-alarm");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const before = Date.now();
    const s = await connect(stub, owner);
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      const alarm = (await state.storage.getAlarm())!;
      expect(alarm).toBeGreaterThanOrEqual(before + 2 * 3600_000);
      expect(alarm).toBeLessThanOrEqual(Date.now() + 2 * 3600_000);
    });
    s.ws.close(1000, "x");
  });

  it("a broadcast reaches every connected member and carries no deviceId", async () => {
    const stub = stubFor("ge-ws-broadcast");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAnon(stub, inviteCode, "ANON-DEVICE-SECRET");
    const sa = await connect(stub, owner);
    const sb = await connect(stub, b);
    const r = await msg(stub, b, { payloadCipher: b64(24, 4) });
    expect(r.status).toBe(201);
    const { seq } = await r.json() as { seq: number };
    for (const s of [sa, sb]) {
      const raw = await s.nextMessage();
      expect(raw).not.toContain("deviceId");
      expect(raw).not.toContain("ANON-DEVICE-SECRET");
      expect(JSON.parse(raw)).toEqual({ t: "ev", e: expect.objectContaining({ seq, type: "msg", authorMemberId: b.memberId, epoch: 1, payloadCipher: b64(24, 4) }) });
    }
    // Join events fan out too.
    await joinAccount(stub, inviteCode, "MEMBERC1");
    const j = JSON.parse(await sa.nextMessage()) as { t: string; e: GroupEvent };
    expect(j.e.type).toBe("join");
    sa.ws.close(1000, "x"); sb.ws.close(1000, "x");
  });

  it("third socket for one member replaces the oldest", async () => {
    const stub = stubFor("ge-ws-third");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const s1 = await connect(stub, owner);
    const s2 = await connect(stub, owner);
    const s3 = await connect(stub, owner);
    await s1.waitFor(() => s1.closed !== null);
    expect(s1.closed).toEqual({ code: 4000, reason: "replaced" });
    expect((await msg(stub, owner)).status).toBe(201);
    await s2.nextMessage();
    await s3.nextMessage();
    expect(s2.closed).toBeNull();
    expect(s3.closed).toBeNull();
    s2.ws.close(1000, "x"); s3.ws.close(1000, "x");
  });

  it("sockets past 2h are closed 4001 on the next broadcast", async () => {
    const stub = stubFor("ge-ws-2h");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const sa = await connect(stub, owner);
    await setClock(stub, 2 * 3600_000 + 1000);
    const sb = await connect(stub, b); // fresh under the shifted clock
    expect((await msg(stub, owner)).status).toBe(201);
    await sa.waitFor(() => sa.closed !== null);
    expect(sa.closed).toEqual({ code: 4001, reason: "expired" });
    expect(sa.messages).toEqual([]);
    expect(JSON.parse(await sb.nextMessage()).t).toBe("ev");
    await setClock(stub);
    sb.ws.close(1000, "x");
  });

  it("alarm closes sockets past 2h", async () => {
    const stub = stubFor("ge-ws-alarm-close");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const s = await connect(stub, owner);
    await runInDurableObject(stub, async (inst: GroupRoom) => {
      inst.now = () => Date.now() + 2 * 3600_000 + 1000;
      await inst.alarm();
      inst.now = () => Date.now();
    });
    await s.waitFor(() => s.closed !== null);
    expect(s.closed).toEqual({ code: 4001, reason: "expired" });
  });

  it("isConnected is false once a socket has been silent for more than 90s", async () => {
    const stub = stubFor("ge-ws-connected");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const s = await connect(stub, owner);
    await runInDurableObject(stub, async (inst: GroupRoom) => {
      expect(inst.isConnected(owner.memberId)).toBe(true);
      expect(inst.isConnected(b.memberId)).toBe(false);
      inst.now = () => Date.now() + 89_000;
      expect(inst.isConnected(owner.memberId)).toBe(true);
      inst.now = () => Date.now() + 91_000;
      expect(inst.isConnected(owner.memberId)).toBe(false);
      inst.now = () => Date.now();
    });
    // A "ping" (auto-answered) counts as being heard from.
    s.ws.send("ping");
    await s.waitFor(() => s.messages.includes("pong"));
    // Any other frame is ignored (not parsed) but also refreshes `last`.
    s.ws.send("{\"t\":\"junk\"}");
    await settle();
    await runInDurableObject(stub, async (inst: GroupRoom) => {
      inst.now = () => Date.now() + 89_000;
      expect(inst.isConnected(owner.memberId)).toBe(true);
      inst.now = () => Date.now();
    });
    s.ws.close(1000, "x");
  });

  it("a replaced member's sockets are closed 4003 and its unused tickets are refused", async () => {
    const stub = stubFor("ge-ws-replaced");
    const { inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const sb = await connect(stub, b);
    const spare = await ticketFor(stub, b);
    // Same account re-joins from a new device with a new memberId (Ruling 12).
    await joinAccount(stub, inviteCode, "MEMBERB1");
    await sb.waitFor(() => sb.closed !== null);
    expect(sb.closed).toEqual({ code: 4003, reason: "removed" });
    expect((await upgrade(stub, spare)).status).toBe(403);
  });
});

describe("GroupRoom: msg concurrency", () => {
  it("parallel posts from two members: every one lands, seq strictly increasing, nothing overwritten", async () => {
    const stub = stubFor("ge-race-parallel");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const base = (await getMeta(stub)).seq;
    const bodies = Array.from({ length: 40 }, (_, i) => msgBody(i % 2 ? b : owner));
    const rs = await Promise.all(bodies.map((body) => post(stub, "/events/msg", body)));
    expect(rs.map((r) => r.status)).toEqual(Array(40).fill(201));
    const seqs = await Promise.all(rs.map(async (r) => (await r.json() as { seq: number }).seq));
    expect(new Set(seqs).size).toBe(40);
    expect([...seqs].sort((x, y) => x - y)).toEqual(Array.from({ length: 40 }, (_, i) => base + 1 + i));
    const evs = (await eventsOf(stub)).filter((e) => e.type === "msg");
    expect(evs).toHaveLength(40);
    expect(evs.map((e) => e.seq)).toEqual([...evs.map((e) => e.seq)].sort((x, y) => x - y));
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      for (let i = 0; i < 40; i++) {
        expect(await state.storage.get(`eid:${bodies[i].eventId}`)).toBe(seqs[i]);
        expect((await state.storage.get<GroupEvent>(`ev:${padSeq(seqs[i])}`))!.eventId).toBe(bodies[i].eventId);
      }
    });
    expect((await getMeta(stub)).seq).toBe(base + 40);
  });

  it("parallel retries of one eventId yield one event and the same seq", async () => {
    const stub = stubFor("ge-race-retry");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const body = msgBody(owner);
    const rs = await Promise.all(Array.from({ length: 6 }, () => post(stub, "/events/msg", body)));
    const statuses = rs.map((r) => r.status).sort();
    expect(statuses).toEqual([200, 200, 200, 200, 200, 201]);
    const seqs = await Promise.all(rs.map(async (r) => (await r.json() as { seq: number }).seq));
    expect(new Set(seqs)).toEqual(new Set([1]));
    expect(await eventsOf(stub)).toHaveLength(1);
  });

  it("a slow-body msg and a fast one both land with distinct seqs", async () => {
    const stub = stubFor("ge-race-slow");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const slowBody = msgBody(owner);
    const slow = slowPost(stub, "/events/msg", slowBody);
    await settle();
    const fast = await msg(stub, b);
    expect(fast.status).toBe(201);
    await slow.finish();
    const sr = await slow.response;
    expect(sr.status).toBe(201);
    const fs = (await fast.json() as { seq: number }).seq;
    const ss = (await sr.json() as { seq: number }).seq;
    expect(ss).toBe(fs + 1);
    const evs = (await eventsOf(stub)).filter((e) => e.type === "msg");
    expect(evs.map((e) => e.seq)).toEqual([fs, ss]);
    expect(evs[1].eventId).toBe(slowBody.eventId);
  });

  it("a burst of 35 parallel posts from one member admits exactly 30", async () => {
    const stub = stubFor("ge-race-rate");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const rs = await Promise.all(Array.from({ length: 35 }, () => msg(stub, owner)));
    const statuses = rs.map((r) => r.status);
    expect(statuses.filter((s) => s === 201)).toHaveLength(30);
    expect(statuses.filter((s) => s === 429)).toHaveLength(5);
    expect(await eventsOf(stub)).toHaveLength(30);
  });

  it("a slow-body msg sees a close that committed while it was reading", async () => {
    const stub = stubFor("ge-race-close");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const slow = slowPost(stub, "/events/msg", msgBody(owner));
    await settle();
    expect((await post(stub, "/close", { caller: owner })).status).toBe(200);
    await slow.finish();
    expect((await slow.response).status).toBe(403);
    expect((await getMeta(stub)).state).toBe("closed");
    expect(await eventsOf(stub)).toHaveLength(0);
  });
});

/** A POST whose JSON body trickles in (see group-room.spec.ts). */
function slowPost(stub: DurableObjectStub, path: string, body: unknown) {
  const text = JSON.stringify(body);
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const enc = new TextEncoder();
  void writer.write(enc.encode(text.slice(0, 5)));
  const response = stub.fetch(`https://group${path}`, { method: "POST", body: readable });
  return {
    response,
    finish: async () => { await writer.write(enc.encode(text.slice(5))); await writer.close(); },
  };
}
