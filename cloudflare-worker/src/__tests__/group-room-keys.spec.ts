// Drives the GroupRoom Durable Object directly for key wraps, epoch rotation,
// metaCipher updates and member removal (Task 4): /keys/mine, /keys/put,
// /rotate, /meta, /meta-cipher, /leave, /kick and the shared removeMember
// path (wraps / tickets / sockets die with the member, ownership hand-over,
// the last leave wiping the room).
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { ulid } from "../notes";
import { sha256Hex } from "../groupSig";
import type { GroupRoom, GroupMeta, GroupEvent, Caller, PublicMember, WrapRecord } from "../groupRoom";

const stubFor = (name: string) => env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(name));

/** Base64 of `n` identical bytes — right size, not cryptographically real. */
const b64 = (n: number, fill = 7) => {
  let s = "";
  for (let i = 0; i < n; i++) s += String.fromCharCode(fill);
  return btoa(s);
};

const acct = (memberId: string, accountId: string, lane: Caller["lane"] = "bearer"): Caller =>
  ({ memberId, accountId, deviceId: `DEV-${accountId}`, lane });
const anon = (memberId: string, deviceId: string, accountId: string | null = null): Caller =>
  ({ memberId, accountId, deviceId, lane: "bearer" });

const post = (stub: DurableObjectStub, path: string, body: unknown) =>
  stub.fetch(`https://group${path}`, { method: "POST", body: JSON.stringify(body) });

async function initGroup(stub: DurableObjectStub, accountId: string, opts: { joinPolicy?: string } = {}) {
  const memberId = ulid();
  const r = await post(stub, "/init", {
    groupId: ulid(),
    owner: { memberId, accountId, pubKey: b64(32), pubKeySig: b64(64) },
    ownerWrap: { wrapped: b64(92), sig: b64(64) },
    metaCipher: "METACIPHERSECRET",
    joinPolicy: opts.joinPolicy ?? "anonymousAllowed",
    inviteCode: "INVITE01",
  });
  expect(r.status).toBe(201);
  return { owner: acct(memberId, accountId), inviteCode: "INVITE01" };
}

const accountJoinBody = (c: Caller, code: string) =>
  ({ caller: c, inviteCode: code, member: { memberId: c.memberId, kind: "account", accountId: c.accountId, pubKey: b64(32, 1), pubKeySig: b64(64, 2) } });
const anonJoinBody = (c: Caller, code: string) =>
  ({ caller: c, inviteCode: code, member: { memberId: c.memberId, kind: "anon", deviceId: c.deviceId, pubKey: b64(32, 3) } });

async function joinAccount(stub: DurableObjectStub, code: string, accountId: string, opts: { keyed?: boolean } = {}): Promise<Caller> {
  const c = acct(ulid(), accountId);
  const r = await post(stub, "/join", accountJoinBody(c, code));
  expect(r.status).toBe(201);
  if (opts.keyed) await giveKey(stub, c.memberId);
  return c;
}

async function joinAnon(stub: DurableObjectStub, code: string, deviceId: string, opts: { keyed?: boolean } = {}): Promise<Caller> {
  const c = anon(ulid(), deviceId);
  const r = await post(stub, "/join", anonJoinBody(c, code));
  expect(r.status).toBe(201);
  if (opts.keyed) await giveKey(stub, c.memberId);
  return c;
}

const keyKey = (epoch: number, memberId: string) => `key:${String(epoch).padStart(10, "0")}:${memberId}`;

/** Writes a wrap for `memberId` straight into storage (test shortcut). */
async function giveKey(stub: DurableObjectStub, memberId: string, epoch = 1) {
  await runInDurableObject(stub, async (_i: GroupRoom, state) => {
    await state.storage.put(keyKey(epoch, memberId), { wrapped: b64(92), wrappedBy: "X", sig: b64(64), createdAt: Date.now() });
  });
}

const wrapFor = (memberId: string, fill = 5) => ({ memberId, wrapped: b64(92, fill), sig: b64(64, fill) });
const putKeys = (stub: DurableObjectStub, caller: Caller, wraps: unknown[], epoch = 1) =>
  post(stub, "/keys/put", { caller, epoch, wraps });
const mine = (stub: DurableObjectStub, caller: Caller) => post(stub, "/keys/mine", { caller });
const rotateBody = (caller: Caller, memberIds: string[], opts: { epoch?: number; eventId?: string; metaCipher?: string } = {}) =>
  ({ caller, eventId: opts.eventId ?? ulid(), epoch: opts.epoch ?? 2, wraps: memberIds.map((id) => wrapFor(id, 8)), metaCipher: opts.metaCipher ?? b64(48, 4) });
const rotate = (stub: DurableObjectStub, caller: Caller, memberIds: string[], opts: Parameters<typeof rotateBody>[2] = {}) =>
  post(stub, "/rotate", rotateBody(caller, memberIds, opts));
const metaBody = (caller: Caller, extra: Record<string, unknown> = {}) =>
  ({ caller, eventId: ulid(), metaCipher: b64(32, 6), ...extra });
const setMeta = (stub: DurableObjectStub, caller: Caller, extra: Record<string, unknown> = {}) =>
  post(stub, "/meta", metaBody(caller, extra));
const leave = (stub: DurableObjectStub, caller: Caller) => post(stub, "/leave", { caller });
const kick = (stub: DurableObjectStub, caller: Caller, targetMemberId: string) => post(stub, "/kick", { caller, targetMemberId });
const view = async (stub: DurableObjectStub, caller: Caller) =>
  await (await post(stub, "/view", { caller })).json() as { members: PublicMember[]; ownerMemberId: string | null; state: string; epoch: number; rotationDue: boolean; metaVersion: number; inviteCode?: string; joinPolicy: string };
const msg = (stub: DurableObjectStub, caller: Caller, opts: { epoch?: number; eventId?: string } = {}) =>
  post(stub, "/events/msg", { caller, eventId: opts.eventId ?? ulid(), epoch: opts.epoch ?? 1, payloadCipher: b64(40, 9) });

async function getMeta(stub: DurableObjectStub): Promise<GroupMeta> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => (await state.storage.get<GroupMeta>("meta"))!);
}
async function eventsOf(stub: DurableObjectStub): Promise<GroupEvent[]> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list<GroupEvent>({ prefix: "ev:" })).values()]);
}
async function storageKeys(stub: DurableObjectStub): Promise<string[]> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list()).keys()]);
}
const memberIdsOf = async (stub: DurableObjectStub) => (await getMeta(stub)).members.map((m) => m.memberId);

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
      if (left <= 0) throw new Error("timeout waiting; closed=" + JSON.stringify(this.closed));
      await new Promise<void>((res) => { this.waiters.push(res); setTimeout(res, Math.min(left, 50)); });
    }
  }
}
async function ticketFor(stub: DurableObjectStub, caller: Caller): Promise<string> {
  const r = await post(stub, "/ws-ticket", { caller });
  expect(r.status).toBe(200);
  return (await r.json() as { ticket: string }).ticket;
}
const upgrade = (stub: DurableObjectStub, ticket: string) =>
  stub.fetch(`https://group/ws?ticket=${encodeURIComponent(ticket)}`, { headers: { Upgrade: "websocket" } });
async function connect(stub: DurableObjectStub, caller: Caller): Promise<TestSocket> {
  const resp = await upgrade(stub, await ticketFor(stub, caller));
  expect(resp.status).toBe(101);
  return new TestSocket(resp.webSocket!);
}
const settle = () => new Promise((r) => setTimeout(r, 50));

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

describe("GroupRoom: key wraps", () => {
  it("a new member is awaiting key until a keyed account member relays a wrap", async () => {
    const stub = stubFor("gk-relay");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const before = await view(stub, owner);
    expect(before.members.find((m) => m.memberId === b.memberId)!.hasKey).toBe(false);
    expect((await msg(stub, b)).status).toBe(403);
    expect(await (await mine(stub, b)).json()).toEqual({ wraps: [] });

    const r = await putKeys(stub, owner, [wrapFor(b.memberId)]);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ written: [b.memberId], skipped: [] });
    const after = await view(stub, owner);
    expect(after.members.find((m) => m.memberId === b.memberId)!.hasKey).toBe(true);
    const m = await mine(stub, b);
    expect(m.status).toBe(200);
    expect(await m.json()).toEqual({ wraps: [{ epoch: 1, wrapped: b64(92, 5), wrappedBy: owner.memberId, sig: b64(64, 5) }] });
    expect((await msg(stub, b)).status).toBe(201);
  });

  it("relay is first-write-wins for members, owner may overwrite", async () => {
    const stub = stubFor("gk-fww");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const d = await joinAccount(stub, inviteCode, "MEMBERD1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1");
    expect(await (await putKeys(stub, b, [wrapFor(c.memberId, 1)])).json()).toEqual({ written: [c.memberId], skipped: [] });
    expect(await (await putKeys(stub, d, [wrapFor(c.memberId, 2)])).json()).toEqual({ written: [], skipped: [c.memberId] });
    let w = (await (await mine(stub, c)).json() as { wraps: { wrapped: string; wrappedBy: string }[] }).wraps;
    expect(w).toEqual([expect.objectContaining({ wrapped: b64(92, 1), wrappedBy: b.memberId })]);
    expect(await (await putKeys(stub, owner, [wrapFor(c.memberId, 3)])).json()).toEqual({ written: [c.memberId], skipped: [] });
    w = (await (await mine(stub, c)).json() as { wraps: { wrapped: string; wrappedBy: string }[] }).wraps;
    expect(w).toEqual([expect.objectContaining({ wrapped: b64(92, 3), wrappedBy: owner.memberId })]);
  });

  it("anonymous members cannot upload wraps (403 account_required)", async () => {
    const stub = stubFor("gk-anon-relay");
    const { inviteCode } = await initGroup(stub, "OWNERAC1");
    const a = await joinAnon(stub, inviteCode, "ANONDEV1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1");
    const r = await putKeys(stub, a, [wrapFor(c.memberId)]);
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "account_required" });
    expect(await storageKeys(stub)).not.toContain(keyKey(1, c.memberId));
  });

  it("an unkeyed member cannot relay (403 not_keyed)", async () => {
    const stub = stubFor("gk-unkeyed");
    const { inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const c = await joinAccount(stub, inviteCode, "MEMBERC1");
    const r = await putKeys(stub, b, [wrapFor(c.memberId)]);
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "not_keyed" });
    // Not even for itself.
    expect((await putKeys(stub, b, [wrapFor(b.memberId)])).status).toBe(403);
  });

  it("wraps for a non-member are 400 unknown_member and are not stored", async () => {
    const stub = stubFor("gk-unknown");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const ghost = ulid();
    const r = await putKeys(stub, owner, [wrapFor(b.memberId), wrapFor(ghost)]);
    expect(r.status).toBe(400);
    expect(await r.json()).toEqual({ error: "unknown_member" });
    const keys = await storageKeys(stub);
    expect(keys).not.toContain(keyKey(1, b.memberId));
    expect(keys).not.toContain(keyKey(1, ghost));
  });

  it("wrong epoch, wrong sizes and malformed bodies are refused without writes", async () => {
    const stub = stubFor("gk-bad");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const before = await storageKeys(stub);
    const stale = await putKeys(stub, owner, [wrapFor(b.memberId)], 2);
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({ error: "stale_epoch", epoch: 1 });
    for (const w of [{ ...wrapFor(b.memberId), wrapped: b64(91) }, { ...wrapFor(b.memberId), sig: b64(65) }, { ...wrapFor(b.memberId), wrapped: "not base64!" }]) {
      const r = await putKeys(stub, owner, [w]);
      expect(r.status).toBe(400);
      expect(await r.json()).toEqual({ error: "bad_wrap" });
    }
    for (const wraps of ["x", [wrapFor(b.memberId), wrapFor(b.memberId)], [{ memberId: "nope", wrapped: b64(92), sig: b64(64) }], [null]]) {
      expect((await putKeys(stub, owner, wraps as unknown[])).status).toBe(400);
    }
    // Non-members see 403 first, whatever the body's sizes.
    expect((await putKeys(stub, acct(ulid(), "STRANGER"), [{ ...wrapFor(b.memberId), wrapped: b64(91) }])).status).toBe(403);
    expect(await storageKeys(stub)).toEqual(before);
  });
});

describe("GroupRoom: rotate", () => {
  it("rotate requires epoch+1 and exactly the current member set", async () => {
    const stub = stubFor("gk-rotate");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const a = await joinAnon(stub, inviteCode, "ANONDEV1", { keyed: true });
    const all = [owner.memberId, b.memberId, a.memberId];
    for (const epoch of [1, 3]) {
      const r = await rotate(stub, owner, all, { epoch });
      expect(r.status).toBe(409);
      expect(await r.json()).toEqual({ error: "stale_epoch", epoch: 1 });
    }
    for (const ids of [[owner.memberId, b.memberId], [...all, ulid()]]) {
      const r = await rotate(stub, owner, ids);
      expect(r.status).toBe(409);
      const body = await r.json() as { error: string; memberIds: string[] };
      expect(body.error).toBe("members_changed");
      expect(new Set(body.memberIds)).toEqual(new Set(all));
    }
    const notOwner = await rotate(stub, b, all);
    expect(notOwner.status).toBe(403);
    expect(await notOwner.json()).toEqual({ error: "not_owner" });
    expect((await getMeta(stub)).epoch).toBe(1);

    const eventId = ulid();
    const ok = await rotate(stub, owner, all, { eventId, metaCipher: b64(48, 4) });
    expect(ok.status).toBe(201);
    const okBody = await ok.json() as { seq: number; epoch: number };
    expect(okBody.epoch).toBe(2);
    const meta = await getMeta(stub);
    expect(meta).toMatchObject({ epoch: 2, metaVersion: 2, rotationDue: false, seq: okBody.seq });
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      expect(await state.storage.get("metacipher")).toBe(b64(48, 4));
      for (const id of all) {
        expect(await state.storage.get<WrapRecord>(keyKey(2, id))).toMatchObject({ wrapped: b64(92, 8), wrappedBy: owner.memberId, sig: b64(64, 8) });
      }
    });
    const ev = (await eventsOf(stub)).find((e) => e.seq === okBody.seq)!;
    expect(ev).toMatchObject({ eventId, type: "meta", authorMemberId: owner.memberId, epoch: 2 });
    expect(ev.payloadCipher).toBeUndefined();

    // Idempotent by eventId.
    const again = await rotate(stub, owner, all, { eventId, epoch: 2 });
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ seq: okBody.seq, epoch: 2 });
    expect((await getMeta(stub)).epoch).toBe(2);

    // Old epoch posts are now stale; new ones go through.
    expect((await msg(stub, b, { epoch: 1 })).status).toBe(409);
    expect((await msg(stub, b, { epoch: 2 })).status).toBe(201);
    // keys/mine lists every epoch, ascending.
    const w = (await (await mine(stub, b)).json() as { wraps: { epoch: number }[] }).wraps;
    expect(w.map((x) => x.epoch)).toEqual([1, 2]);
  });

  it("rotate rejects a wrap set that no longer matches members", async () => {
    const stub = stubFor("gk-rotate-changed");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1", { keyed: true });
    const prepared = rotateBody(owner, [owner.memberId, b.memberId, c.memberId]);
    await joinAccount(stub, inviteCode, "MEMBERD1");
    const r = await post(stub, "/rotate", prepared);
    expect(r.status).toBe(409);
    const body = await r.json() as { error: string; memberIds: string[] };
    expect(body.error).toBe("members_changed");
    expect(body.memberIds).toHaveLength(4);
    expect((await getMeta(stub)).epoch).toBe(1);
    expect((await storageKeys(stub)).filter((k) => k.startsWith("key:0000000002"))).toEqual([]);
  });

  it("rotate on a closed room is 403 group_closed; bad wraps and oversized meta are refused", async () => {
    const stub = stubFor("gk-rotate-misc");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const ids = [owner.memberId, b.memberId];
    const bad = rotateBody(owner, ids);
    bad.wraps[1].wrapped = b64(91);
    const r1 = await post(stub, "/rotate", bad);
    expect(r1.status).toBe(400);
    expect(await r1.json()).toEqual({ error: "bad_wrap" });
    const big = await rotate(stub, owner, ids, { metaCipher: b64(409_601) });
    expect(big.status).toBe(413);
    expect(await big.json()).toEqual({ error: "too_large" });
    expect((await post(stub, "/close", { caller: owner })).status).toBe(200);
    const closed = await rotate(stub, owner, ids);
    expect(closed.status).toBe(403);
    expect(await closed.json()).toEqual({ error: "group_closed" });
    expect((await getMeta(stub)).epoch).toBe(1);
  });
});

describe("GroupRoom: kick and leave", () => {
  it("kicked member loses all wraps, gets no new epoch key, and is banned", async () => {
    const stub = stubFor("gk-kick");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1", { keyed: true });
    await giveKey(stub, b.memberId, 0);
    const r = await kick(stub, owner, b.memberId);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ removed: { kind: "account", accountId: "MEMBERB1" } });
    const keys = await storageKeys(stub);
    expect(keys.filter((k) => k.endsWith(`:${b.memberId}`))).toEqual([]);
    expect(keys).toContain(`ban:${await sha256Hex("acct:MEMBERB1")}`);
    const m = await mine(stub, b);
    expect(m.status).toBe(403);
    expect(await m.json()).toEqual({ error: "not_member" });
    const ev = (await eventsOf(stub)).at(-1)!;
    expect(ev).toMatchObject({ type: "kick", authorMemberId: owner.memberId, targetMemberId: b.memberId });

    expect((await rotate(stub, owner, [owner.memberId, c.memberId])).status).toBe(201);
    expect((await storageKeys(stub)).filter((k) => k.endsWith(`:${b.memberId}`))).toEqual([]);

    const same = await post(stub, "/join", accountJoinBody(b, inviteCode));
    expect(same.status).toBe(403);
    expect(await same.json()).toEqual({ error: "banned" });
    const fresh = await post(stub, "/join", accountJoinBody(acct(ulid(), "MEMBERB1"), inviteCode));
    expect(fresh.status).toBe(403);
    expect(await fresh.json()).toEqual({ error: "banned" });
  });

  it("kicking an anonymous member bans its device", async () => {
    const stub = stubFor("gk-kick-anon");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const a = await joinAnon(stub, inviteCode, "ANONDEV1", { keyed: true });
    expect(await (await kick(stub, owner, a.memberId)).json()).toEqual({ removed: { kind: "anon" } });
    expect(await storageKeys(stub)).toContain(`ban:${await sha256Hex("dev:ANONDEV1")}`);
    const again = await post(stub, "/join", anonJoinBody(anon(ulid(), "ANONDEV1"), inviteCode));
    expect(await again.json()).toEqual({ error: "banned" });
  });

  it("a kicked account cannot come back anonymously from the same device (and vice versa)", async () => {
    const stub = stubFor("gk-kick-bypass");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    expect((await kick(stub, owner, b.memberId)).status).toBe(200);
    // Same authenticated account (Bearer lane, its own device) posing as anonymous.
    const sneaky = await post(stub, "/join", anonJoinBody(anon(ulid(), b.deviceId, "MEMBERB1"), inviteCode));
    expect(sneaky.status).toBe(403);
    expect(await sneaky.json()).toEqual({ error: "banned" });

    // A kicked anonymous device signing in with an account on that device.
    const a = await joinAnon(stub, inviteCode, "ANONDEV9");
    expect((await kick(stub, owner, a.memberId)).status).toBe(200);
    const c: Caller = { memberId: ulid(), accountId: "NEWACCT9", deviceId: "ANONDEV9", lane: "bearer" };
    const back = await post(stub, "/join", accountJoinBody(c, inviteCode));
    expect(back.status).toBe(403);
    expect(await back.json()).toEqual({ error: "banned" });

    // Unrelated people still get in; an account and an anonymous identity
    // on one (unbanned) device can still coexist (Ruling 4).
    expect((await post(stub, "/join", anonJoinBody(anon(ulid(), "OKDEVICE", "OKACCT01"), inviteCode))).status).toBe(201);
    expect((await post(stub, "/join", accountJoinBody({ memberId: ulid(), accountId: "OKACCT01", deviceId: "OKDEVICE", lane: "bearer" }, inviteCode))).status).toBe(201);
  });

  it("kick is owner-only, can't target the owner, and is a no-op for non-members", async () => {
    const stub = stubFor("gk-kick-rules");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const c = await joinAccount(stub, inviteCode, "MEMBERC1");
    const notOwner = await kick(stub, b, c.memberId);
    expect(notOwner.status).toBe(403);
    expect(await notOwner.json()).toEqual({ error: "not_owner" });
    const self = await kick(stub, owner, owner.memberId);
    expect(self.status).toBe(400);
    expect(await self.json()).toEqual({ error: "kick_self" });
    const seq = (await getMeta(stub)).seq;
    const none = await kick(stub, owner, ulid());
    expect(none.status).toBe(200);
    expect(await none.json()).toEqual({ removed: null });
    expect((await getMeta(stub)).seq).toBe(seq);
    expect((await kick(stub, owner, "bad")).status).toBe(400);
  });

  it("leave and kick set rotationDue; rotate clears it", async () => {
    const stub = stubFor("gk-rotation-due");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1", { keyed: true });
    expect((await view(stub, owner)).rotationDue).toBe(false);
    const l = await leave(stub, c);
    expect(l.status).toBe(200);
    expect(await l.json()).toEqual({ remaining: 2, removed: { kind: "account", accountId: "MEMBERC1" } });
    expect((await view(stub, owner)).rotationDue).toBe(true);
    expect((await rotate(stub, owner, [owner.memberId, b.memberId])).status).toBe(201);
    expect((await view(stub, owner)).rotationDue).toBe(false);
    expect((await kick(stub, owner, b.memberId)).status).toBe(200);
    expect((await view(stub, owner)).rotationDue).toBe(true);
    const ev = (await eventsOf(stub)).find((e) => e.type === "leave")!;
    expect(ev).toMatchObject({ authorMemberId: c.memberId });
    expect(ev.ownerMemberId).toBeUndefined();
  });

  it("leave by a non-member is 200 with removed null", async () => {
    const stub = stubFor("gk-leave-none");
    await initGroup(stub, "OWNERAC1");
    const r = await leave(stub, acct(ulid(), "STRANGER"));
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ remaining: 1, removed: null });
    expect((await getMeta(stub)).seq).toBe(0);
  });

  it("owner leaving hands ownership to the earliest remaining account member", async () => {
    const stub = stubFor("gk-owner-leave");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const a = await joinAnon(stub, inviteCode, "ANONDEV1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    await joinAccount(stub, inviteCode, "MEMBERC1");
    const r = await leave(stub, owner);
    expect(await r.json()).toEqual({ remaining: 3, removed: { kind: "account", accountId: "OWNERAC1" } });
    const meta = await getMeta(stub);
    expect(meta.ownerMemberId).toBe(b.memberId);
    expect(meta.state).toBe("open");
    const ev = (await eventsOf(stub)).at(-1)!;
    expect(ev).toMatchObject({ type: "leave", authorMemberId: owner.memberId, ownerMemberId: b.memberId });
    expect((await view(stub, b)).inviteCode).toBe(inviteCode);
    expect((await view(stub, a)).inviteCode).toBeUndefined();
  });

  it("owner leaving with only anonymous members left closes the room", async () => {
    const stub = stubFor("gk-owner-leave-anon");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const a = await joinAnon(stub, inviteCode, "ANONDEV1", { keyed: true });
    expect((await msg(stub, a)).status).toBe(201);
    expect((await leave(stub, owner)).status).toBe(200);
    const meta = await getMeta(stub);
    expect(meta.ownerMemberId).toBeNull();
    expect(meta.state).toBe("closed");
    const l = await post(stub, "/events/list", { caller: a });
    expect(l.status).toBe(200);
    expect((await l.json() as { events: GroupEvent[] }).events.map((e) => e.type)).toEqual(["join", "msg", "leave"]);
    expect((await msg(stub, a)).status).toBe(403);
    expect(await (await leave(stub, a)).json()).toEqual({ remaining: 0, removed: { kind: "anon" } });
    expect(await storageKeys(stub)).toEqual([]);
  });

  it("last leave wipes the room including sockets and tickets", async () => {
    const stub = stubFor("gk-last-leave");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const s = await connect(stub, owner);
    const spare = await ticketFor(stub, owner);
    const r = await leave(stub, owner);
    expect(await r.json()).toEqual({ remaining: 0, removed: { kind: "account", accountId: "OWNERAC1" } });
    await s.waitFor(() => s.closed !== null);
    expect(s.closed).toEqual({ code: 4003, reason: "removed" });
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      expect((await state.storage.list()).size).toBe(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
    expect((await upgrade(stub, spare)).status).toBe(404);
    expect((await post(stub, "/view", { caller: owner })).status).toBe(404);
    expect((await leave(stub, owner)).status).toBe(404);
  });

  it("a removed member's sockets close 4003 and its tickets are deleted", async () => {
    const stub = stubFor("gk-kick-socket");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const s = await connect(stub, b);
    await ticketFor(stub, b);
    const ownerTicket = await ticketFor(stub, owner);
    expect((await kick(stub, owner, b.memberId)).status).toBe(200);
    await s.waitFor(() => s.closed !== null);
    expect(s.closed).toEqual({ code: 4003, reason: "removed" });
    const tickets = await runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list<{ memberId: string }>({ prefix: "tkt:" })).values()]);
    expect(tickets.map((t) => t.memberId)).toEqual([owner.memberId]);
    const ok = await upgrade(stub, ownerTicket);
    expect(ok.status).toBe(101);
    new TestSocket(ok.webSocket!).ws.close(1000, "x");
  });
});

describe("GroupRoom: meta", () => {
  it("meta size boundary", async () => {
    const stub = stubFor("gk-meta-size");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const ok = await setMeta(stub, owner, { metaCipher: b64(409_600, 3) });
    expect(ok.status).toBe(201);
    const body = await ok.json() as { seq: number; metaVersion: number };
    expect(body.metaVersion).toBe(2);
    const big = await setMeta(stub, owner, { metaCipher: b64(409_601) });
    expect(big.status).toBe(413);
    expect(await big.json()).toEqual({ error: "too_large" });
    const mc = await post(stub, "/meta-cipher", { caller: owner });
    expect(await mc.json()).toEqual({ metaCipher: b64(409_600, 3), metaVersion: 2 });
    const ev = (await eventsOf(stub)).find((e) => e.seq === body.seq)!;
    expect(ev).toMatchObject({ type: "meta", authorMemberId: owner.memberId, epoch: 1 });
    expect(ev.payloadCipher).toBeUndefined();
  });

  it("meta is owner-only, open-only, idempotent and may change joinPolicy", async () => {
    const stub = stubFor("gk-meta-rules");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const notOwner = await setMeta(stub, b);
    expect(notOwner.status).toBe(403);
    expect(await notOwner.json()).toEqual({ error: "not_owner" });
    // Any member may read it.
    expect(await (await post(stub, "/meta-cipher", { caller: b })).json()).toEqual({ metaCipher: "METACIPHERSECRET", metaVersion: 1 });
    expect((await post(stub, "/meta-cipher", { caller: acct(ulid(), "STRANGER") })).status).toBe(403);

    const body = metaBody(owner, { joinPolicy: "accountOnly" });
    const r1 = await post(stub, "/meta", body);
    expect(r1.status).toBe(201);
    const b1 = await r1.json() as { seq: number; metaVersion: number };
    const r2 = await post(stub, "/meta", body);
    expect(r2.status).toBe(200);
    expect((await r2.json() as { seq: number }).seq).toBe(b1.seq);
    expect((await getMeta(stub)).metaVersion).toBe(2);
    expect((await view(stub, owner)).joinPolicy).toBe("accountOnly");
    expect((await setMeta(stub, owner, { joinPolicy: "public" })).status).toBe(400);
    expect((await setMeta(stub, owner, { metaCipher: "!!" })).status).toBe(400);

    expect((await post(stub, "/close", { caller: owner })).status).toBe(200);
    const closed = await setMeta(stub, owner);
    expect(closed.status).toBe(403);
    expect(await closed.json()).toEqual({ error: "group_closed" });
    // A lost-response retry after close still gets its original answer.
    expect((await post(stub, "/meta", body)).status).toBe(200);
  });

  it("switching to accountOnly with removeAnonymous kicks every anon without banning", async () => {
    const stub = stubFor("gk-meta-remove-anon");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const a1 = await joinAnon(stub, inviteCode, "ANONDEV1", { keyed: true });
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const a2 = await joinAnon(stub, inviteCode, "ANONDEV2", { keyed: true });
    const s = await connect(stub, a1);

    for (const extra of [{ removeAnonymous: true }, { removeAnonymous: true, joinPolicy: "anonymousAllowed" }, { removeAnonymous: "yes", joinPolicy: "accountOnly" }]) {
      const r = await setMeta(stub, owner, extra);
      expect(r.status).toBe(400);
      expect(await r.json()).toEqual({ error: "bad_request" });
    }
    expect((await getMeta(stub)).members).toHaveLength(4);

    const r = await setMeta(stub, owner, { joinPolicy: "accountOnly", removeAnonymous: true });
    expect(r.status).toBe(201);
    const { seq } = await r.json() as { seq: number };
    const meta = await getMeta(stub);
    expect(meta.members.map((m) => m.memberId)).toEqual([owner.memberId, b.memberId]);
    expect(meta).toMatchObject({ joinPolicy: "accountOnly", rotationDue: true, metaVersion: 2 });
    const evs = await eventsOf(stub);
    expect(evs.find((e) => e.seq === seq)).toMatchObject({ type: "meta" });
    const kicks = evs.filter((e) => e.type === "kick");
    expect(kicks.map((e) => e.targetMemberId).sort()).toEqual([a1.memberId, a2.memberId].sort());
    for (const k of kicks) expect(k.authorMemberId).toBe(owner.memberId);
    const keys = await storageKeys(stub);
    expect(keys.filter((k) => k.startsWith("ban:"))).toEqual([]);
    expect(keys.filter((k) => k.endsWith(`:${a1.memberId}`) || k.endsWith(`:${a2.memberId}`))).toEqual([]);
    await s.waitFor(() => s.closed !== null);
    expect(s.closed).toEqual({ code: 4003, reason: "removed" });

    // Not banned: once anonymous joins are allowed again they may come back.
    expect((await setMeta(stub, owner, { joinPolicy: "anonymousAllowed" })).status).toBe(201);
    expect((await post(stub, "/join", anonJoinBody(anon(ulid(), "ANONDEV1"), inviteCode))).status).toBe(201);
  });
});

describe("GroupRoom: Task 3 carry-overs", () => {
  it("an author's msg retry after close still gets its original answer", async () => {
    const stub = stubFor("gk-msg-replay-closed");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const eventId = ulid();
    const r1 = await msg(stub, owner, { eventId });
    expect(r1.status).toBe(201);
    const { seq } = await r1.json() as { seq: number };
    expect((await post(stub, "/close", { caller: owner })).status).toBe(200);
    const r2 = await msg(stub, owner, { eventId });
    expect(r2.status).toBe(200);
    expect((await r2.json() as { seq: number }).seq).toBe(seq);
    expect((await msg(stub, owner)).status).toBe(403);
  });

  it("a socket is closed by an alarm firing exactly at its 2h cap", async () => {
    const stub = stubFor("gk-ws-exact-cap");
    const { owner } = await initGroup(stub, "OWNERAC1");
    const t0 = Date.now();
    await runInDurableObject(stub, async (inst: GroupRoom) => { inst.now = () => t0; });
    const s = await connect(stub, owner);
    await runInDurableObject(stub, async (inst: GroupRoom) => {
      inst.now = () => t0 + 2 * 3600_000;
      await inst.alarm();
      inst.now = () => Date.now();
    });
    await s.waitFor(() => s.closed !== null);
    expect(s.closed).toEqual({ code: 4001, reason: "expired" });
  });
});

describe("GroupRoom: removal and rotation concurrency", () => {
  it("a slow-body rotate loses to a join that committed meanwhile", async () => {
    const stub = stubFor("gk-race-rotate-join");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const slow = slowPost(stub, "/rotate", rotateBody(owner, [owner.memberId, b.memberId]));
    await settle();
    await joinAccount(stub, inviteCode, "MEMBERC1");
    await slow.finish();
    const r = await slow.response;
    expect(r.status).toBe(409);
    expect((await r.json() as { memberIds: string[] }).memberIds).toHaveLength(3);
    expect((await getMeta(stub)).epoch).toBe(1);
  });

  it("a slow-body rotate loses to a leave that committed meanwhile", async () => {
    const stub = stubFor("gk-race-rotate-leave");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1", { keyed: true });
    const slow = slowPost(stub, "/rotate", rotateBody(owner, [owner.memberId, b.memberId, c.memberId]));
    await settle();
    expect((await leave(stub, c)).status).toBe(200);
    await slow.finish();
    const r = await slow.response;
    expect(r.status).toBe(409);
    expect(new Set((await r.json() as { memberIds: string[] }).memberIds)).toEqual(new Set([owner.memberId, b.memberId]));
    const meta = await getMeta(stub);
    expect(meta.epoch).toBe(1);
    expect(meta.rotationDue).toBe(true);
    expect(await storageKeys(stub)).not.toContain(keyKey(2, c.memberId));
  });

  it("two rotations to the same epoch: exactly one wins", async () => {
    const stub = stubFor("gk-race-double-rotate");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const ids = [owner.memberId, b.memberId];
    const rs = await Promise.all([rotate(stub, owner, ids), rotate(stub, owner, ids), rotate(stub, owner, ids)]);
    expect(rs.map((r) => r.status).sort()).toEqual([201, 409, 409]);
    const meta = await getMeta(stub);
    expect(meta.epoch).toBe(2);
    expect(meta.metaVersion).toBe(2);
    expect((await eventsOf(stub)).filter((e) => e.type === "meta")).toHaveLength(1);

    // Same eventId in parallel: one write, the rest replay it.
    const body = rotateBody(owner, ids, { epoch: 3 });
    const same = await Promise.all([0, 1, 2].map(() => post(stub, "/rotate", body)));
    expect(same.map((r) => r.status).sort()).toEqual([200, 200, 201]);
    expect((await getMeta(stub)).epoch).toBe(3);
    expect((await eventsOf(stub)).filter((e) => e.type === "meta")).toHaveLength(2);
  });

  it("a slow-body msg from a member kicked meanwhile is refused", async () => {
    const stub = stubFor("gk-race-kick-msg");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const slow = slowPost(stub, "/events/msg", { caller: b, eventId: ulid(), epoch: 1, payloadCipher: b64(40) });
    await settle();
    expect((await kick(stub, owner, b.memberId)).status).toBe(200);
    await slow.finish();
    const r = await slow.response;
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "not_member" });
    expect((await eventsOf(stub)).filter((e) => e.type === "msg")).toHaveLength(0);
  });

  it("a slow-body relay for a member kicked meanwhile stores nothing", async () => {
    const stub = stubFor("gk-race-kick-put");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1");
    const slow = slowPost(stub, "/keys/put", { caller: b, epoch: 1, wraps: [wrapFor(c.memberId)] });
    await settle();
    expect((await kick(stub, owner, c.memberId)).status).toBe(200);
    await slow.finish();
    const r = await slow.response;
    expect(r.status).toBe(400);
    expect(await r.json()).toEqual({ error: "unknown_member" });
    expect((await storageKeys(stub)).filter((k) => k.endsWith(`:${c.memberId}`))).toEqual([]);
  });

  it("a slow-body relay after a rotation is stale", async () => {
    const stub = stubFor("gk-race-rotate-put");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1", { keyed: true });
    const c = await joinAccount(stub, inviteCode, "MEMBERC1");
    const slow = slowPost(stub, "/keys/put", { caller: b, epoch: 1, wraps: [wrapFor(c.memberId)] });
    await settle();
    expect((await rotate(stub, owner, [owner.memberId, b.memberId, c.memberId])).status).toBe(201);
    await slow.finish();
    const r = await slow.response;
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "stale_epoch", epoch: 2 });
    expect(await storageKeys(stub)).not.toContain(keyKey(1, c.memberId));
  });

  it("parallel kicks of one member remove it once", async () => {
    const stub = stubFor("gk-race-double-kick");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const rs = await Promise.all([0, 1, 2].map(() => kick(stub, owner, b.memberId)));
    const bodies = await Promise.all(rs.map((r) => r.json() as Promise<{ removed: unknown }>));
    expect(bodies.filter((x) => x.removed !== null)).toHaveLength(1);
    expect((await eventsOf(stub)).filter((e) => e.type === "kick")).toHaveLength(1);
    expect(await memberIdsOf(stub)).toEqual([owner.memberId]);
  });

  it("a kick racing the target's replacement join removes whoever holds the memberId", async () => {
    const stub = stubFor("gk-race-kick-join");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const slow = slowPost(stub, "/kick", { caller: owner, targetMemberId: b.memberId });
    await settle();
    await joinAccount(stub, inviteCode, "MEMBERB1"); // B's new device replaces b
    await slow.finish();
    expect(await (await slow.response).json()).toEqual({ removed: null });
    expect(await memberIdsOf(stub)).toHaveLength(2);
  });

  it("parallel leaves of the last two members wipe the room", async () => {
    const stub = stubFor("gk-race-last-leaves");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    const b = await joinAccount(stub, inviteCode, "MEMBERB1");
    const rs = await Promise.all([leave(stub, owner), leave(stub, b)]);
    const remaining = (await Promise.all(rs.map((r) => r.json() as Promise<{ remaining: number }>))).map((x) => x.remaining).sort();
    expect(remaining).toEqual([0, 1]);
    expect(await storageKeys(stub)).toEqual([]);
  });

  it("a slow-body removeAnonymous also removes an anon who joined meanwhile", async () => {
    const stub = stubFor("gk-race-remove-anon");
    const { owner, inviteCode } = await initGroup(stub, "OWNERAC1");
    await joinAnon(stub, inviteCode, "ANONDEV1");
    const slow = slowPost(stub, "/meta", metaBody(owner, { joinPolicy: "accountOnly", removeAnonymous: true }));
    await settle();
    await joinAnon(stub, inviteCode, "ANONDEV2");
    await slow.finish();
    expect((await slow.response).status).toBe(201);
    expect(await memberIdsOf(stub)).toEqual([owner.memberId]);
    expect((await eventsOf(stub)).filter((e) => e.type === "kick")).toHaveLength(2);
  });

  it("uninitialised ids answer 404 on every new endpoint and stay empty", async () => {
    const stub = stubFor("gk-uninit");
    const c = acct(ulid(), "SOMEACC1");
    const calls: [string, unknown][] = [
      ["/keys/mine", { caller: c }],
      ["/keys/put", { caller: c, epoch: 1, wraps: [wrapFor(ulid())] }],
      ["/rotate", rotateBody(c, [c.memberId])],
      ["/meta", metaBody(c)],
      ["/meta-cipher", { caller: c }],
      ["/leave", { caller: c }],
      ["/kick", { caller: c, targetMemberId: ulid() }],
    ];
    for (const [path, body] of calls) expect((await post(stub, path, body)).status, path).toBe(404);
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      expect((await state.storage.list()).size).toBe(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
  });
});
