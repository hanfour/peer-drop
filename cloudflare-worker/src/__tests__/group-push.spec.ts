// Group push (Task 5): push.ts's pushToDevice / fanOutPush, groupPush.ts's
// deliverGroupPush, and the GroupRoom DO's push recipients — who a new msg
// should nudge (not the author, not anyone with a live socket, at most once
// a minute per recipient identity) and who /request-key should ask.
//
// APNs is never called: every send goes through a fake `deps.send` that
// records the token (same pattern as diary-push.spec.ts), and APNS_KEY_P8 is
// only made truthy through a spread copy of `env`.
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect, beforeAll, vi } from "vitest";
import { applyMigrations } from "./d1";
import { makeAccount } from "./notesHelpers";
import { ulid } from "../notes";
import type { PushDeps } from "../notes";
import { fanOutPush, pushToDevice } from "../push";
import type { PushPayload } from "../push";
import { deliverGroupPush } from "../groupPush";
import { GROUP_PUSH } from "../groupRoom";
import type { GroupRoom, Caller, PushRecipient } from "../groupRoom";
import type { sendAPNs } from "../apns";
import type { Env } from "../index";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

// ---- push.ts / groupPush.ts -------------------------------------------------

interface Call { token: string; payload: unknown; opts?: { topicOverride?: string; pushType?: string; priority?: number } }

function fakeDeps(opts: { fail?: boolean } = {}): { deps: PushDeps; calls: Call[] } {
  const calls: Call[] = [];
  const send = (async (token: string, payload: unknown, _cfg: unknown, o?: Call["opts"]) => {
    calls.push({ token, payload, opts: o });
    if (opts.fail) throw new Error("apns down");
    return { ok: true, status: 200 };
  }) as unknown as typeof sendAPNs;
  return { deps: { send, topicFor: (p: string) => `topic-${p}` }, calls };
}

function fakeEnv(): Env {
  return { ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" } as unknown as Env;
}

let devCounter = 0;
const nextDev = (tag: string) => `dev-gpush-${tag}-${String(++devCounter).padStart(4, "0")}`;

/** Binds an extra device with a push token to `accountId` (D1 + KV). */
async function seedDevice(accountId: string, token: string, platform = "ios"): Promise<string> {
  const deviceId = nextDev("extra");
  await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, ?3, 1)").bind(accountId, deviceId, platform).run();
  await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: token, platform }));
  return deviceId;
}

const msgPayload: PushPayload = { alert: { "loc-key": "GROUP_MESSAGE" }, data: { type: "groupMessage", groupId: "G" } };

describe("push.ts", () => {
  it("pushToDevice sends exactly one push with the device's platform topic", async () => {
    const deviceId = nextDev("solo");
    await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: "tok-solo", platform: "macos" }));
    const { deps, calls } = fakeDeps();
    expect(await pushToDevice(fakeEnv(), deviceId, null, msgPayload, deps)).toBe(true);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ token: "tok-solo", payload: { alert: { "loc-key": "GROUP_MESSAGE" }, customData: msgPayload.data }, opts: { topicOverride: "topic-macos" } });

    // Silent payload: background push type and priority 5.
    const silent = fakeDeps();
    expect(await pushToDevice(fakeEnv(), deviceId, null, { silent: true, data: { type: "x" } }, silent.deps)).toBe(true);
    expect(silent.calls[0]).toMatchObject({ payload: { contentAvailable: true, customData: { type: "x" } }, opts: { topicOverride: "topic-macos", pushType: "background", priority: 5 } });

    // Falls back to the given platform when the record carries none.
    const noPlat = nextDev("noplat");
    await env.V2_STORE.put(`device:${noPlat}`, JSON.stringify({ pushToken: "tok-np" }));
    const fb = fakeDeps();
    expect(await pushToDevice(fakeEnv(), noPlat, "ios", msgPayload, fb.deps)).toBe(true);
    expect(fb.calls[0].opts?.topicOverride).toBe("topic-ios");
  });

  it("pushToDevice attempts nothing without an APNs key, a record or a token, and never throws", async () => {
    const deviceId = nextDev("none");
    await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: "tok-none", platform: "ios" }));
    const { deps, calls } = fakeDeps();
    expect(await pushToDevice(env as unknown as Env, deviceId, null, msgPayload, deps)).toBe(false); // APNS_KEY_P8 unset
    expect(await pushToDevice(fakeEnv(), nextDev("missing"), null, msgPayload, deps)).toBe(false);
    const noTok = nextDev("notok");
    await env.V2_STORE.put(`device:${noTok}`, JSON.stringify({ platform: "ios" }));
    expect(await pushToDevice(fakeEnv(), noTok, null, msgPayload, deps)).toBe(false);
    const garbage = nextDev("garbage");
    await env.V2_STORE.put(`device:${garbage}`, "{not json");
    expect(await pushToDevice(fakeEnv(), garbage, null, msgPayload, deps)).toBe(false);
    expect(calls).toHaveLength(0);
    // A failing send still counts as attempted and does not throw.
    const failing = fakeDeps({ fail: true });
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(await pushToDevice(fakeEnv(), deviceId, null, msgPayload, failing.deps)).toBe(true);
    } finally { errSpy.mockRestore(); }
  });

  it("fanOutPush behaviour is unchanged", async () => {
    const a = await makeAccount(nextDev("fan"));
    await seedDevice(a.accountId, "tok-fan-1");
    await seedDevice(a.accountId, "tok-fan-2", "macos");
    const { deps, calls } = fakeDeps();
    expect(await fanOutPush(fakeEnv(), a.accountId, msgPayload, deps)).toEqual({ attempted: 2 });
    expect(calls.map((c) => c.token).sort()).toEqual(["tok-fan-1", "tok-fan-2"]);
    const byToken = Object.fromEntries(calls.map((c) => [c.token, c]));
    expect(byToken["tok-fan-1"].opts).toEqual({ topicOverride: "topic-ios" });
    expect(byToken["tok-fan-2"].opts).toEqual({ topicOverride: "topic-macos" });
    expect(byToken["tok-fan-1"].payload).toEqual({ alert: { "loc-key": "GROUP_MESSAGE" }, sound: undefined, customData: msgPayload.data });
    // No APNs key: nothing at all.
    const off = fakeDeps();
    expect(await fanOutPush(env as unknown as Env, a.accountId, msgPayload, off.deps)).toEqual({ attempted: 0 });
    expect(off.calls).toHaveLength(0);
  });

  it("fanOutPush failure log carries no device id or token", async () => {
    const a = await makeAccount(nextDev("fail"));
    const deviceId = await seedDevice(a.accountId, "tok-fail-SECRET");
    const { deps, calls } = fakeDeps({ fail: true });
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(await fanOutPush(fakeEnv(), a.accountId, msgPayload, deps)).toEqual({ attempted: 1 });
      expect(calls).toHaveLength(1);
      expect(errSpy).toHaveBeenCalled();
      const logged = JSON.stringify(errSpy.mock.calls);
      expect(logged).toContain("push failed");
      expect(logged).not.toContain(deviceId);
      expect(logged).not.toContain(a.deviceId);
      expect(logged).not.toContain("tok-fail-SECRET");
      expect(logged).not.toContain(a.accountId);
    } finally { errSpy.mockRestore(); }
  });

  it("deliverGroupPush reaches every device of an account member and only the stored device of an anon", async () => {
    const y = await makeAccount(nextDev("y"));
    await seedDevice(y.accountId, "tok-y1");
    await seedDevice(y.accountId, "tok-y2");
    // The anonymous member's device belongs to account Z, which has another device too.
    const z = await makeAccount(nextDev("z"));
    const anonDevice = await seedDevice(z.accountId, "tok-z-anon");
    await seedDevice(z.accountId, "tok-z-other");
    const { deps, calls } = fakeDeps();
    const recipients: PushRecipient[] = [{ kind: "account", accountId: y.accountId }, { kind: "device", deviceId: anonDevice }];
    expect(await deliverGroupPush(fakeEnv(), recipients, msgPayload, deps)).toBeUndefined();
    expect(calls.map((c) => c.token).sort()).toEqual(["tok-y1", "tok-y2", "tok-z-anon"]);

    // Swallows failures: a throwing send never rejects.
    const failing = fakeDeps({ fail: true });
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      await expect(deliverGroupPush(fakeEnv(), recipients, msgPayload, failing.deps)).resolves.toBeUndefined();
      expect(JSON.stringify(errSpy.mock.calls)).not.toContain(anonDevice);
    } finally { errSpy.mockRestore(); }
    // Empty list: no-op.
    const none = fakeDeps();
    await deliverGroupPush(fakeEnv(), [], msgPayload, none.deps);
    expect(none.calls).toHaveLength(0);
  });

  it("GROUP_PUSH payloads are fixed and carry no names or senders", () => {
    expect(GROUP_PUSH.message("G1")).toEqual({ alert: { "loc-key": "GROUP_MESSAGE" }, data: { type: "groupMessage", groupId: "G1" } });
    expect(GROUP_PUSH.keyRequest("G1")).toEqual({ silent: true, data: { type: "groupKeyRequest", groupId: "G1" } });
  });
});

// ---- GroupRoom recipients -----------------------------------------------------

const stubFor = (name: string) => env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(name));
const b64 = (n: number, fill = 7) => {
  let s = "";
  for (let i = 0; i < n; i++) s += String.fromCharCode(fill);
  return btoa(s);
};
const acct = (memberId: string, accountId: string): Caller => ({ memberId, accountId, deviceId: `DEV-${accountId}`, lane: "bearer" });
const anon = (memberId: string, deviceId: string): Caller => ({ memberId, accountId: null, deviceId, lane: "bearer" });
const post = (stub: DurableObjectStub, path: string, body: unknown) =>
  stub.fetch(`https://group${path}`, { method: "POST", body: JSON.stringify(body) });

async function initGroup(stub: DurableObjectStub, accountId: string) {
  const memberId = ulid();
  const r = await post(stub, "/init", {
    groupId: ulid(),
    owner: { memberId, accountId, pubKey: b64(32), pubKeySig: b64(64) },
    ownerWrap: { wrapped: b64(92), sig: b64(64) },
    metaCipher: "METACIPHERSECRET",
    joinPolicy: "anonymousAllowed",
    inviteCode: "INVITE01",
  });
  expect(r.status).toBe(201);
  return acct(memberId, accountId);
}
async function giveKey(stub: DurableObjectStub, memberId: string, epoch = 1) {
  await runInDurableObject(stub, async (_i: GroupRoom, state) => {
    await state.storage.put(`key:${String(epoch).padStart(10, "0")}:${memberId}`, { wrapped: b64(92), wrappedBy: "X", sig: b64(64), createdAt: Date.now() });
  });
}
async function joinAccount(stub: DurableObjectStub, accountId: string, opts: { keyed?: boolean } = {}): Promise<Caller> {
  const c = acct(ulid(), accountId);
  const r = await post(stub, "/join", { caller: c, inviteCode: "INVITE01", member: { memberId: c.memberId, kind: "account", accountId, pubKey: b64(32, 1), pubKeySig: b64(64, 2) } });
  expect(r.status).toBe(201);
  if (opts.keyed !== false) await giveKey(stub, c.memberId);
  return c;
}
async function joinAnon(stub: DurableObjectStub, deviceId: string, opts: { keyed?: boolean } = {}): Promise<Caller> {
  const c = anon(ulid(), deviceId);
  const r = await post(stub, "/join", { caller: c, inviteCode: "INVITE01", member: { memberId: c.memberId, kind: "anon", deviceId, pubKey: b64(32, 3) } });
  expect(r.status).toBe(201);
  if (opts.keyed !== false) await giveKey(stub, c.memberId);
  return c;
}
async function send(stub: DurableObjectStub, caller: Caller, eventId = ulid()): Promise<{ status: number; recipients: PushRecipient[] }> {
  const r = await post(stub, "/events/msg", { caller, eventId, epoch: 1, payloadCipher: b64(40, 9) });
  const body = await r.json() as { recipients: PushRecipient[] };
  return { status: r.status, recipients: body.recipients };
}
async function setClock(stub: DurableObjectStub, offsetMs?: number) {
  await runInDurableObject(stub, async (inst: GroupRoom) => {
    inst.now = offsetMs === undefined ? () => Date.now() : () => Date.now() + offsetMs;
  });
}
async function connect(stub: DurableObjectStub, caller: Caller): Promise<WebSocket> {
  const t = await post(stub, "/ws-ticket", { caller });
  expect(t.status).toBe(200);
  const { ticket } = await t.json() as { ticket: string };
  const resp = await stub.fetch(`https://group/ws?ticket=${encodeURIComponent(ticket)}`, { headers: { Upgrade: "websocket" } });
  expect(resp.status).toBe(101);
  const ws = resp.webSocket!;
  ws.accept();
  return ws;
}
const sortR = (rs: PushRecipient[]) => [...rs].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
async function dump(stub: DurableObjectStub): Promise<string> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => JSON.stringify([...(await state.storage.list()).entries()]));
}

describe("GroupRoom: push recipients", () => {
  it("recipients exclude the author and any member with a live socket on any device", async () => {
    const stub = stubFor("gp-online");
    const owner = await initGroup(stub, "OWNERP01");
    const a = await joinAccount(stub, "ACCTP0A1");
    const b = await joinAccount(stub, "ACCTP0B1");
    const n = await joinAnon(stub, "ANONDEV-P01");
    const m = await joinAnon(stub, "ANONDEV-P02");
    const wsB = await connect(stub, b);
    const wsM = await connect(stub, m);

    const r = await send(stub, owner);
    expect(r.status).toBe(201);
    expect(sortR(r.recipients)).toEqual(sortR([{ kind: "account", accountId: "ACCTP0A1" }, { kind: "device", deviceId: "ANONDEV-P01" }]));
    // An account recipient never carries a deviceId.
    for (const x of r.recipients) if (x.kind === "account") expect(Object.keys(x).sort()).toEqual(["accountId", "kind"]);

    // An anonymous author is excluded too; the owner (offline) is now a recipient.
    const r2 = await send(stub, n);
    expect(r2.recipients).toEqual([{ kind: "account", accountId: "OWNERP01" }]); // a throttled from the first post
    // A socket that went quiet for > 90 s no longer counts as online.
    await setClock(stub, 91_000);
    const r3 = await send(stub, a);
    expect(sortR(r3.recipients)).toEqual(sortR([
      { kind: "account", accountId: "OWNERP01" }, { kind: "account", accountId: "ACCTP0B1" },
      { kind: "device", deviceId: "ANONDEV-P01" }, { kind: "device", deviceId: "ANONDEV-P02" },
    ]));
    await setClock(stub);
    wsB.close(); wsM.close();
  });

  it("recipients throttle per recipient identity within 60s and survive a device move", async () => {
    const stub = stubFor("gp-throttle");
    const owner = await initGroup(stub, "OWNERP02");
    const a = await joinAccount(stub, "ACCTP2A1");
    const n = await joinAnon(stub, "ANONDEV-P21");
    const all = [{ kind: "account", accountId: "ACCTP2A1" }, { kind: "device", deviceId: "ANONDEV-P21" }];

    expect(sortR((await send(stub, owner)).recipients)).toEqual(sortR(all as PushRecipient[]));
    expect((await send(stub, owner)).recipients).toEqual([]);

    // Same account and same anonymous device rejoin with new memberIds
    // (Ruling 12): the throttle follows the identity, not the memberId.
    const a2 = acct(ulid(), "ACCTP2A1");
    expect((await post(stub, "/join", { caller: a2, inviteCode: "INVITE01", member: { memberId: a2.memberId, kind: "account", accountId: "ACCTP2A1", pubKey: b64(32, 1), pubKeySig: b64(64, 2) } })).status).toBe(201);
    const n2 = anon(ulid(), "ANONDEV-P21");
    expect((await post(stub, "/join", { caller: n2, inviteCode: "INVITE01", member: { memberId: n2.memberId, kind: "anon", deviceId: "ANONDEV-P21", pubKey: b64(32, 3) } })).status).toBe(201);
    expect((await send(stub, owner)).recipients).toEqual([]);

    await setClock(stub, 59_000);
    expect((await send(stub, owner)).recipients).toEqual([]);
    await setClock(stub, 60_000);
    expect(sortR((await send(stub, owner)).recipients)).toEqual(sortR(all as PushRecipient[]));
    // The fresh stamp throttles again.
    expect((await send(stub, owner)).recipients).toEqual([]);
    await setClock(stub);
    void a; void n;
  });

  it("leaving or being kicked drops the identity's throttle stamp", async () => {
    const stub = stubFor("gp-throttle-remove");
    const owner = await initGroup(stub, "OWNERP03");
    const a = await joinAccount(stub, "ACCTP3A1");
    const n = await joinAnon(stub, "ANONDEV-P31");
    expect((await send(stub, owner)).recipients).toHaveLength(2);
    const keysBefore = await runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list({ prefix: "push:" })).keys()]);
    expect(keysBefore).toHaveLength(2);
    expect((await post(stub, "/leave", { caller: a })).status).toBe(200);
    expect((await post(stub, "/kick", { caller: owner, targetMemberId: n.memberId })).status).toBe(200);
    const keysAfter = await runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list({ prefix: "push:" })).keys()]);
    expect(keysAfter).toEqual([]);
    // Rejoining (the account was only leaving, not kicked) is pushed at once.
    await joinAccount(stub, "ACCTP3A1");
    expect((await send(stub, owner)).recipients).toEqual([{ kind: "account", accountId: "ACCTP3A1" }]);
  });

  it("parallel posts push each recipient at most once per window", async () => {
    const stub = stubFor("gp-parallel");
    const owner = await initGroup(stub, "OWNERP04");
    const a = await joinAccount(stub, "ACCTP4A1");
    await joinAccount(stub, "ACCTP4C1");
    await joinAnon(stub, "ANONDEV-P41");
    const results = await Promise.all([
      ...Array.from({ length: 6 }, () => send(stub, owner)),
      ...Array.from({ length: 6 }, () => send(stub, a)),
    ]);
    for (const r of results) expect(r.status).toBe(201);
    const counts = new Map<string, number>();
    for (const r of results) for (const x of r.recipients) {
      const k = JSON.stringify(x);
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    expect(counts.get(JSON.stringify({ kind: "account", accountId: "ACCTP4C1" }))).toBe(1);
    expect(counts.get(JSON.stringify({ kind: "device", deviceId: "ANONDEV-P41" }))).toBe(1);
    expect(counts.get(JSON.stringify({ kind: "account", accountId: "OWNERP04" }))).toBe(1);
    expect(counts.get(JSON.stringify({ kind: "account", accountId: "ACCTP4A1" }))).toBe(1);
  });

  it("a replayed eventId returns recipients []", async () => {
    const stub = stubFor("gp-replay");
    const owner = await initGroup(stub, "OWNERP05");
    await joinAccount(stub, "ACCTP5A1");
    const eventId = ulid();
    const first = await send(stub, owner, eventId);
    expect(first.status).toBe(201);
    expect(first.recipients).toEqual([{ kind: "account", accountId: "ACCTP5A1" }]);
    await setClock(stub, 120_000); // even outside the throttle window
    const again = await send(stub, owner, eventId);
    expect(again).toEqual({ status: 200, recipients: [] });
    await setClock(stub);
  });

  it("request-key targets only keyed account members other than the caller", async () => {
    const stub = stubFor("gp-request-key");
    const owner = await initGroup(stub, "OWNERP06");
    const a = await joinAccount(stub, "ACCTP6A1");
    const b = await joinAccount(stub, "ACCTP6B1", { keyed: false });
    const n = await joinAnon(stub, "ANONDEV-P61"); // keyed, but anonymous: can't relay
    const wsA = await connect(stub, a); // online members are still asked (not throttled or filtered)

    const rb = await post(stub, "/request-key", { caller: b });
    expect(rb.status).toBe(200);
    const body = await rb.json() as { recipients: PushRecipient[] };
    expect(sortR(body.recipients)).toEqual(sortR([{ kind: "account", accountId: "OWNERP06" }, { kind: "account", accountId: "ACCTP6A1" }]));
    // Repeating it is not throttled here (the route rate-limits it).
    expect(sortR((await (await post(stub, "/request-key", { caller: b })).json() as { recipients: PushRecipient[] }).recipients)).toHaveLength(2);

    expect((await (await post(stub, "/request-key", { caller: a })).json() as { recipients: PushRecipient[] }).recipients).toEqual([{ kind: "account", accountId: "OWNERP06" }]);
    expect(sortR((await (await post(stub, "/request-key", { caller: n })).json() as { recipients: PushRecipient[] }).recipients))
      .toEqual(sortR([{ kind: "account", accountId: "OWNERP06" }, { kind: "account", accountId: "ACCTP6A1" }]));
    // Only the current epoch's wrap counts.
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      const meta = (await state.storage.get<{ epoch: number }>("meta"))!;
      await state.storage.put("meta", { ...meta, epoch: 2 });
    });
    await giveKey(stub, a.memberId, 2);
    expect((await (await post(stub, "/request-key", { caller: b })).json() as { recipients: PushRecipient[] }).recipients).toEqual([{ kind: "account", accountId: "ACCTP6A1" }]);

    // Non-members and bad bodies.
    expect((await post(stub, "/request-key", { caller: acct(ulid(), "STRANGER") })).status).toBe(403);
    expect((await post(stub, "/request-key", { caller: { ...n, lane: "key" } })).status).toBe(401);
    expect((await post(stub, "/request-key", {})).status).toBe(400);
    wsA.close();
  });

  it("request-key on an uninitialised room is 404 with zero writes", async () => {
    const stub = stubFor("gp-request-key-404");
    const r = await post(stub, "/request-key", { caller: acct(ulid(), "NOBODY01") });
    expect(r.status).toBe(404);
    expect(await dump(stub)).toBe("[]");
    const m = await post(stub, "/events/msg", { caller: acct(ulid(), "NOBODY01"), eventId: ulid(), epoch: 1, payloadCipher: b64(40) });
    expect(m.status).toBe(404);
    expect(await dump(stub)).toBe("[]");
  });

  it("DO storage never holds an account member's deviceId or push token", async () => {
    const stub = stubFor("gp-storage-privacy");
    const owner = await initGroup(stub, "OWNERP07");
    const a = await joinAccount(stub, "ACCTP7A1");
    const n = await joinAnon(stub, "ANONDEV-P71");
    await send(stub, owner);
    await send(stub, a);
    await send(stub, n);
    const ws = await connect(stub, a);
    await post(stub, "/request-key", { caller: a });
    const all = await dump(stub);
    for (const c of [owner, a]) expect(all).not.toContain(c.deviceId);
    expect(all).not.toContain("tok-");
    expect(all).not.toMatch(/pushToken/i);
    // The throttle key for the anonymous member is a hash, not the raw deviceId.
    const pushKeys = await runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list({ prefix: "push:" })).keys()]);
    expect(pushKeys.sort()).toEqual(expect.arrayContaining(["push:acct:ACCTP7A1", "push:acct:OWNERP07"]));
    const devKey = pushKeys.find((k) => k.startsWith("push:dev:"))!;
    expect(devKey).toMatch(/^push:dev:[0-9a-f]{64}$/);
    expect(devKey).not.toContain("ANONDEV-P71");
    // And no response leaks the anonymous deviceId except as a push recipient.
    const v = await (await post(stub, "/view", { caller: a })).text();
    expect(v).not.toContain("ANONDEV-P71");
    expect(v).not.toMatch(/devHash|pushKey/);
    ws.close();
  });
});
