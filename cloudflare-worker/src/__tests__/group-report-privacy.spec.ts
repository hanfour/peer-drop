// Task 8: group reports (POST /v3/groups/:id/events/:seq/report) and the
// §3.2 privacy guards over a whole room lifecycle — what is logged, what the
// server stores (KV, D1, the room's own storage) and what any client ever
// receives (HTTP bodies and WebSocket frames).
//
// Setup and most calls go through SELF.fetch (the real index.ts dispatch).
// The calls that must exercise push sends or a failing D1 go through
// handleGroupRoute directly with a fake push sender / a D1 that throws on
// one statement (same harness shape as group-routes-content.spec.ts).
import { env, SELF, runInDurableObject } from "cloudflare:test";
import { describe, it, expect, beforeAll, vi } from "vitest";
import { applyMigrations } from "./d1";
import { TEST_TOKEN_SECRET } from "./testSecrets";
import {
  makeGroupAccount, makeAnonDevice, newGroupId, fakeMeta, bearer, asMember, createBody, createGroup,
  joinGroup, accountJoinBody, anonJoinBody, joinAsAccountOk, getGroup, leaveGroup, kickMember,
  signedWraps, fakePayload, postEvent, listEvents, getGroupMeta, putGroupMeta, rotateGroup, getKeys, putKeys,
  connectMember, createGroupOk,
} from "./groupHelpers";
import type { GroupAccount, AnonDevice, TestSocket } from "./groupHelpers";
import { authorizeGroupCaller } from "../index";
import type { Env } from "../index";
import { handleGroupRoute } from "../group";
import type { GroupRoom, GroupEvent } from "../groupRoom";
import type { PushDeps } from "../notes";
import { senderHash, ulid } from "../notes";
import type { sendAPNs } from "../apns";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

let devCounter = 0;
const nextDev = (tag: string) => `dev-grp-${tag}-${String(++devCounter).padStart(4, "0")}`;
const acct = (tag: string) => makeGroupAccount(nextDev(tag));
const anonDev = (tag: string) => makeAnonDevice(nextDev(tag));
const ANALYTICS_KEY = "test-analytics-key-67890";

const reportPath = (groupId: string, seq: number | string) => `/v3/groups/${groupId}/events/${seq}/report`;
const report = (h: Record<string, string>, groupId: string, seq: number | string, body: unknown) =>
  SELF.fetch(`https://example.com${reportPath(groupId, seq)}`, { method: "POST", headers: h, body: typeof body === "string" ? body : JSON.stringify(body) });

interface ReportRow { id: string; reporter_account_id: string | null; reporter_device_id: string | null; sender_hash: string | null; inbox_item_id: string | null; diary_id: string | null; diary_seq: number | null; group_id: string | null; group_seq: number | null; reason: string; excerpt: string | null; created_at: number }
const reportRow = (id: string) => env.ACCOUNTS_DB.prepare("SELECT * FROM reports WHERE id = ?1").bind(id).first<ReportRow>();

const msgBody = (opts: { epoch?: number; payloadCipher?: string } = {}) =>
  ({ eventId: ulid(), epoch: opts.epoch ?? 1, payloadCipher: opts.payloadCipher ?? fakePayload() });

async function setToken(deviceId: string, token: string) {
  await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: token, platform: "ios" }));
}

/** handleGroupRoute with a recording push sender (one token may throw) and optionally a D1 that throws on matching SQL. */
function harness(opts: { failToken?: string; failSql?: RegExp } = {}) {
  const sent: string[] = [];
  const pending: Promise<unknown>[] = [];
  const send = (async (token: string) => {
    if (token === opts.failToken) throw new Error(`push to ${token} failed`);
    sent.push(token);
    return { ok: true, status: 200 };
  }) as unknown as typeof sendAPNs;
  const realDb = env.ACCOUNTS_DB;
  const db = opts.failSql ? new Proxy(realDb, {
    get(t, k) {
      if (k === "prepare") return (q: string) => { if (opts.failSql!.test(q)) throw new Error("D1_ERROR: simulated write failure"); return t.prepare(q); };
      const v = Reflect.get(t, k);
      return typeof v === "function" ? v.bind(t) : v;
    },
  }) : realDb;
  const fEnv = { ...env, ACCOUNTS_DB: db, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" } as unknown as Env;
  const push: PushDeps = { send, topicFor: () => "topic" };
  const deps = { push, authorize: (r: Request) => authorizeGroupCaller(r, fEnv), waitUntil: (p: Promise<unknown>) => { pending.push(p); } };
  const call = (method: string, path: string, headers: Record<string, string>, body?: unknown) => {
    const req = new Request(`https://example.com${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    return handleGroupRoute(req, new URL(req.url), path, fEnv, deps);
  };
  const flush = async () => { while (pending.length) await Promise.all(pending.splice(0)); };
  return { sent, call, flush };
}

/** Owner A + account member B + anonymous member C, all keyed at epoch 1. */
async function basicRoom(tag: string) {
  const a = await acct(`${tag}-a`), b = await acct(`${tag}-b`), c = await anonDev(`${tag}-c`);
  const { groupId, inviteCode, memberId: aMember } = await createGroupOk(a, { joinPolicy: "anonymousAllowed" });
  const bMember = await joinAsAccountOk(b, groupId, inviteCode);
  const cBody = anonJoinBody(inviteCode);
  expect((await joinGroup(bearer(c), groupId, cBody)).status).toBe(201);
  const ah = asMember(bearer(a), aMember);
  expect((await putKeys(ah, groupId, { epoch: 1, wraps: await signedWraps(a, groupId, 1, aMember, [bMember, cBody.memberId]) })).status).toBe(200);
  return { groupId, inviteCode, a, aMember, ah, b, bMember, bh: asMember(bearer(b), bMember), c, cMember: cBody.memberId, ch: asMember(bearer(c), cBody.memberId) };
}
const postOk = async (h: Record<string, string>, groupId: string, epoch = 1): Promise<number> => {
  const r = await postEvent(h, groupId, msgBody({ epoch }));
  expect(r.status).toBe(201);
  return (await r.json() as { seq: number }).seq;
};
const eventsOf = async (h: Record<string, string>, groupId: string): Promise<GroupEvent[]> =>
  (await (await listEvents(h, groupId, "?limit=500")).json() as { events: GroupEvent[] }).events;

describe("group reports", () => {
  it("an account member's report writes reporter_account_id and the author's senderHash", async () => {
    const r = await basicRoom("rep-acct");
    const aSeq = await postOk(r.ah, r.groupId);
    const cSeq = await postOk(r.ch, r.groupId);
    // reporting an account author
    const resp = await report(r.bh, r.groupId, aSeq, { reason: "harassment", excerpt: "那則訊息的內容" });
    expect(resp.status).toBe(201);
    const { id } = await resp.json() as { id: string };
    expect(Object.keys(await (await report(r.bh, r.groupId, aSeq, { reason: "spam" })).json() as object)).toEqual(["id"]);
    const row = (await reportRow(id))!;
    expect(row).toMatchObject({
      reporter_account_id: r.b.accountId, reporter_device_id: null, sender_hash: await senderHash(TEST_TOKEN_SECRET, r.a.accountId),
      inbox_item_id: null, diary_id: null, diary_seq: null, group_id: r.groupId, group_seq: aSeq, reason: "harassment", excerpt: "那則訊息的內容",
    });
    // reporting an anonymous author: keyed hash of "anon:" + its deviceId (Ruling 18)
    const rc = await report(r.bh, r.groupId, cSeq, { reason: "spam" });
    expect(rc.status).toBe(201);
    const cRow = (await reportRow((await rc.json() as { id: string }).id))!;
    expect(cRow.sender_hash).toBe(await senderHash(TEST_TOKEN_SECRET, `anon:${r.c.deviceId}`));
    expect(cRow.sender_hash).not.toBe(await senderHash(TEST_TOKEN_SECRET, r.c.deviceId));
    expect(cRow.excerpt).toBeNull();
    // a meta event is reportable too (its author is the owner)
    const metaResp = await putGroupMeta(r.ah, r.groupId, { eventId: ulid(), metaCipher: fakeMeta(64) });
    expect(metaResp.status).toBe(201);
    const metaSeq = (await metaResp.json() as { seq: number }).seq;
    const rm = await report(r.bh, r.groupId, metaSeq, { reason: "other" });
    expect(rm.status).toBe(201);
    expect((await reportRow((await rm.json() as { id: string }).id))!.sender_hash).toBe(await senderHash(TEST_TOKEN_SECRET, r.a.accountId));
    // an author who has left: NULL sender_hash
    const d = await acct("rep-acct-d");
    const dMember = await joinAsAccountOk(d, r.groupId, r.inviteCode);
    const dh = asMember(bearer(d), dMember);
    expect((await putKeys(r.ah, r.groupId, { epoch: 1, wraps: await signedWraps(r.a, r.groupId, 1, r.aMember, [dMember]) })).status).toBe(200);
    const dSeq = await postOk(dh, r.groupId);
    expect((await leaveGroup(dh, r.groupId)).status).toBe(204);
    const rd = await report(r.bh, r.groupId, dSeq, { reason: "spam" });
    expect(rd.status).toBe(201);
    expect((await reportRow((await rd.json() as { id: string }).id))!.sender_hash).toBeNull();
  });

  it("an anonymous member's report writes reporter_device_id and NULL reporter_account_id", async () => {
    const r = await basicRoom("rep-anon");
    const aSeq = await postOk(r.ah, r.groupId);
    const resp = await report(r.ch, r.groupId, aSeq, { reason: "spam", excerpt: "x" });
    expect(resp.status).toBe(201);
    const row = (await reportRow((await resp.json() as { id: string }).id))!;
    expect(row).toMatchObject({ reporter_account_id: null, reporter_device_id: r.c.deviceId, group_id: r.groupId, group_seq: aSeq, sender_hash: await senderHash(TEST_TOKEN_SECRET, r.a.accountId) });
    // a signed-in device acting as an ANONYMOUS member still reports as that anonymous identity
    const e = await acct("rep-anon-e");
    const eBody = anonJoinBody(r.inviteCode);
    expect((await joinGroup(bearer(e), r.groupId, eBody)).status).toBe(201);
    const re = await report(asMember(bearer(e), eBody.memberId), r.groupId, aSeq, { reason: "other" });
    expect(re.status).toBe(201);
    expect((await reportRow((await re.json() as { id: string }).id))!).toMatchObject({ reporter_account_id: null, reporter_device_id: e.deviceId });
  });

  it("join/leave/kick events are 400 not_reportable; pruned seq is 404", async () => {
    const r = await basicRoom("rep-type");
    const d = await acct("rep-type-d");
    const dMember = await joinAsAccountOk(d, r.groupId, r.inviteCode);
    expect((await kickMember(r.ah, r.groupId, dMember)).status).toBe(204);
    const f = await acct("rep-type-f");
    const fMember = await joinAsAccountOk(f, r.groupId, r.inviteCode);
    expect((await leaveGroup(asMember(bearer(f), fMember), r.groupId)).status).toBe(204);
    const events = await eventsOf(r.bh, r.groupId);
    for (const type of ["join", "leave", "kick"] as const) {
      const ev = events.find((e) => e.type === type)!;
      expect(ev).toBeTruthy();
      const resp = await report(r.bh, r.groupId, ev.seq, { reason: "spam" });
      expect(resp.status).toBe(400);
      expect(await resp.json()).toEqual({ error: "not_reportable" });
    }
    // a seq that was never written, and one whose event was pruned
    const last = events[events.length - 1].seq;
    expect((await report(r.bh, r.groupId, last + 100, { reason: "spam" })).status).toBe(404);
    const okSeq = await postOk(r.ah, r.groupId);
    const seq = await postOk(r.ah, r.groupId);
    const stub = env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(r.groupId));
    await runInDurableObject(stub, async (_i: GroupRoom, state) => { await state.storage.delete(`ev:${String(seq).padStart(12, "0")}`); });
    const pruned = await report(r.bh, r.groupId, seq, { reason: "spam" });
    expect(pruned.status).toBe(404);
    expect(await pruned.json()).toEqual({ error: "not_found" });
    // a non-member (with a real member's id) is refused; bad bodies are refused before anything else
    const stranger = await acct("rep-type-x");
    const sr = await report(asMember(bearer(stranger), r.bMember), r.groupId, okSeq, { reason: "spam" });
    expect(sr.status).toBe(403);
    expect(await sr.json()).toEqual({ error: "not_member" });
    expect(await (await report(r.bh, r.groupId, okSeq, { reason: "nope" })).json()).toEqual({ error: "invalid_report" });
    expect((await report(r.bh, r.groupId, okSeq, { reason: "spam", excerpt: "字".repeat(1001) })).status).toBe(400);
    expect((await report(r.bh, r.groupId, okSeq, { reason: "spam", excerpt: 5 })).status).toBe(400);
    expect((await report(r.bh, r.groupId, okSeq, { reason: "spam", excerpt: "字".repeat(1000) })).status).toBe(201);
    expect((await report(r.bh, r.groupId, okSeq, JSON.stringify({ reason: "spam", pad: "x".repeat(9000) }))).status).toBe(413);
    // unknown room → 404 without a member lookup
    expect((await report(r.bh, newGroupId(), 1, { reason: "spam" })).status).toBe(404);
    // no member header → 400
    expect((await report(bearer(r.b), r.groupId, okSeq, { reason: "spam" })).status).toBe(400);
  });

  it("reports are limited to 20 per day per reporter identity", async () => {
    const r = await basicRoom("rep-quota");
    const seq = await postOk(r.ah, r.groupId);
    for (let i = 0; i < 20; i++) expect((await report(r.bh, r.groupId, seq, { reason: "spam" })).status).toBe(201);
    const over = await report(r.bh, r.groupId, seq, { reason: "spam" });
    expect(over.status).toBe(429);
    expect(await over.json()).toEqual({ error: "rate_limited" });
    // the anonymous member has its own budget, keyed by its device hash
    for (let i = 0; i < 20; i++) expect((await report(r.ch, r.groupId, seq, { reason: "spam" })).status).toBe(201);
    expect((await report(r.ch, r.groupId, seq, { reason: "spam" })).status).toBe(429);
    // the account quota is the same bucket as diary / notes reports (per account per day)
    const keys = (await env.V2_STORE.list({ prefix: "report-quota:" })).keys.map((k) => k.name);
    expect(keys.some((k) => k.startsWith(`report-quota:${r.b.accountId}:`))).toBe(true);
    expect(keys.some((k) => k.startsWith("report-quota:dev:") && !k.includes(r.c.deviceId))).toBe(true);
  });
});

// ---- the whole-lifecycle privacy flow ----------------------------------------

interface FlowResult {
  logs: string[];
  /** every body a CLIENT received (not the operator's admin view) */
  bodies: string[];
  frames: string[];
  /** values that must never be logged */
  secrets: string[];
  /** device ids and push / bearer tokens: never in any client response, frame or log */
  deviceSecrets: string[];
  accountDeviceIds: string[];
  anonDeviceId: string;
  groupId: string;
  storageDump: [string, unknown][];
  adminBody: string;
  a: GroupAccount; b: GroupAccount; c: AnonDevice;
  bMember: string; cMember: string;
  views: Record<string, unknown>[];
  eventLists: GroupEvent[][];
  keyLists: unknown[];
  sentTokens: string[];
  bDeviceIds: string[];
  bTokens: string[];
}

async function runFlow(tag: string): Promise<FlowResult> {
  const logs: string[] = [];
  const spies = (["log", "info", "warn", "error", "debug"] as const).map((m) =>
    vi.spyOn(console, m).mockImplementation((...args: unknown[]) => {
      logs.push(args.map((x) => { try { return typeof x === "string" ? x : `${String(x)} ${JSON.stringify(x)}`; } catch { return String(x); } }).join(" "));
    }));
  const bodies: string[] = [];
  const rec = async (p: Promise<Response>): Promise<Response> => {
    const r = await p;
    if (r.status !== 101) bodies.push(await r.clone().text());
    return r;
  };
  try {
    const a = await acct(`${tag}-a`), b = await acct(`${tag}-b`), c = await anonDev(`${tag}-c`);
    // B is signed in on 3 devices, each with a push token; A and C have one each.
    const bDeviceIds = [b.deviceId, `${b.deviceId}-2`, `${b.deviceId}-3`];
    const bTokens = bDeviceIds.map((_, i) => `tok-${tag}-b${i + 1}`);
    for (const extra of bDeviceIds.slice(1)) {
      await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, 'ios', 1)").bind(b.accountId, extra).run();
    }
    for (let i = 0; i < 3; i++) await setToken(bDeviceIds[i], bTokens[i]);
    await setToken(a.deviceId, `tok-${tag}-a`);
    await setToken(c.deviceId, `tok-${tag}-c`);

    // create
    const cb = await createBody(a, { joinPolicy: "anonymousAllowed", metaCipher: fakeMeta(80) });
    const created = await rec(createGroup(bearer(a), cb));
    expect(created.status).toBe(201);
    const { inviteCode } = await created.json() as { inviteCode: string };
    const groupId = cb.groupId, aMember = cb.memberId;
    const ah = asMember(bearer(a), aMember);

    // account + anonymous join (B by code, C by link)
    const bj = await accountJoinBody(b, groupId, inviteCode);
    expect((await rec(joinGroup(bearer(b), null, bj))).status).toBe(201);
    const bMember = bj.memberId, bh = asMember(bearer(b), bMember);
    const cj = anonJoinBody(inviteCode);
    expect((await rec(joinGroup(bearer(c), groupId, cj))).status).toBe(201);
    const cMember = cj.memberId, ch = asMember(bearer(c), cMember);

    // key relay (epoch 1)
    const wraps1 = await signedWraps(a, groupId, 1, aMember, [bMember, cMember]);
    expect((await rec(putKeys(ah, groupId, { epoch: 1, wraps: wraps1 }))).status).toBe(200);

    // A posts while nobody is connected: pushes to B's 3 devices + C, one send throws
    const h = harness({ failToken: bTokens[1] });
    const p1 = fakePayload(48);
    const r1 = await rec(h.call("POST", `/v3/groups/${groupId}/events`, ah, { eventId: ulid(), epoch: 1, payloadCipher: p1 }));
    expect(r1.status).toBe(201);
    await h.flush();
    expect(new Set(h.sent)).toEqual(new Set([bTokens[0], bTokens[2], `tok-${tag}-c`]));

    // websockets for B and C (ticket flow)
    const bSock: TestSocket = await connectMember(bh, groupId);
    const cSock: TestSocket = await connectMember(ch, groupId);

    // C posts, A updates the settings, A rotates to epoch 2
    const p2 = fakePayload(56);
    const r2 = await rec(postEvent(ch, groupId, { eventId: ulid(), epoch: 1, payloadCipher: p2 }));
    expect(r2.status).toBe(201);
    const cSeq = (await r2.json() as { seq: number }).seq;
    const meta2 = fakeMeta(96);
    expect((await rec(putGroupMeta(ah, groupId, { eventId: ulid(), metaCipher: meta2 }))).status).toBe(201);
    const wraps2 = await signedWraps(a, groupId, 2, aMember, [aMember, bMember, cMember]);
    const meta3 = fakeMeta(112);
    expect((await rec(rotateGroup(ah, groupId, { eventId: ulid(), epoch: 2, wraps: wraps2, metaCipher: meta3 }))).status).toBe(201);
    const p3 = fakePayload(64);
    const r3 = await rec(postEvent(bh, groupId, { eventId: ulid(), epoch: 2, payloadCipher: p3 }));
    expect(r3.status).toBe(201);
    await bSock.waitFor(() => bSock.messages.length >= 3);
    await cSock.waitFor(() => cSock.messages.length >= 4);

    // reads every member does
    const views: Record<string, unknown>[] = [];
    const eventLists: GroupEvent[][] = [];
    const keyLists: unknown[] = [];
    for (const mh of [ah, bh, ch]) {
      views.push(await (await rec(getGroup(mh, groupId))).json() as Record<string, unknown>);
      eventLists.push((await (await rec(listEvents(mh, groupId))).json() as { events: GroupEvent[] }).events);
      keyLists.push(await (await rec(getKeys(mh, groupId))).json());
      await rec(getGroupMeta(mh, groupId));
    }
    expect(eventLists[2].some((e) => e.payloadCipher === p3)).toBe(true);

    // reports: B reports C's message, C reports A's — with excerpts
    const ex1 = `excerpt-${tag}-1 這段是解密後的摘要`;
    const ex2 = `excerpt-${tag}-2 another excerpt`;
    expect((await rec(report(bh, groupId, cSeq, { reason: "harassment", excerpt: ex1 }))).status).toBe(201);
    expect((await rec(report(ch, groupId, (await r1.clone().json() as { seq: number }).seq, { reason: "spam", excerpt: ex2 }))).status).toBe(201);
    // …and one whose D1 INSERT fails (console.error path)
    const ex3 = `excerpt-${tag}-3 lost`;
    const hf = harness({ failSql: /^INSERT INTO reports/ });
    const failed = await rec(hf.call("POST", reportPath(groupId, cSeq), bh, { reason: "other", excerpt: ex3 }));
    expect(failed.status).toBe(500);

    // the room's own storage, while it is fully populated
    const stub = env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(groupId));
    const storageDump = await runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list())] as [string, unknown][]);

    // the operator's view (not a client response)
    const admin = await SELF.fetch(`https://example.com/v3/admin/reports?since=0&limit=100`, { headers: { "X-API-Key": ANALYTICS_KEY } });
    expect(admin.status).toBe(200);
    const adminBody = await admin.text();

    // kick C, B leaves, A is the last one out (wipe)
    expect((await rec(kickMember(ah, groupId, cMember))).status).toBe(204);
    await cSock.waitFor(() => cSock.closed !== null);
    expect((await rec(leaveGroup(bh, groupId))).status).toBe(204);
    await bSock.waitFor(() => bSock.closed !== null);
    expect((await rec(leaveGroup(ah, groupId))).status).toBe(204);
    expect((await rec(getGroup(ah, groupId))).status).toBe(404);

    const accountDeviceIds = [a.deviceId, ...bDeviceIds];
    const tokens = [...bTokens, `tok-${tag}-a`, `tok-${tag}-c`, a.token, b.token, c.token];
    const deviceSecrets = [...accountDeviceIds, c.deviceId, ...tokens];
    const secrets = [
      p1, p2, p3, cb.metaCipher, meta2, meta3,
      cb.pubKey, cb.pubKeySig, cb.ownerWrap.wrapped, cb.ownerWrap.sig, bj.pubKey!, bj.pubKeySig!, cj.pubKey!,
      ...[...wraps1, ...wraps2].flatMap((w) => [w.wrapped, w.sig]),
      ...deviceSecrets, a.accountId, b.accountId, inviteCode, ex1, ex2, ex3,
    ];
    return {
      logs, bodies, frames: [...bSock.messages, ...cSock.messages], secrets, deviceSecrets, accountDeviceIds, anonDeviceId: c.deviceId,
      groupId, storageDump, adminBody, a, b, c, bMember, cMember, views, eventLists, keyLists, sentTokens: h.sent, bDeviceIds, bTokens,
    };
  } finally {
    for (const s of spies) s.mockRestore();
  }
}

const PUBLIC_MEMBER_KEYS = new Set(["memberId", "kind", "accountId", "joinedAt", "pubKey", "pubKeySig", "hasKey"]);
const EVENT_KEYS = new Set(["seq", "eventId", "type", "authorMemberId", "epoch", "payloadCipher", "targetMemberId", "ownerMemberId", "metaVersion", "rotated", "createdAt"]);

describe("group privacy over a full room lifecycle", () => {
  let flow: FlowResult;
  beforeAll(async () => { flow = await runFlow("pv"); });

  it("no plaintext, cipher, key, deviceId, accountId, inviteCode or excerpt is ever logged", () => {
    // the forced D1 failure and push failure did log (so the spy saw output)…
    expect(flow.logs.some((l) => l.includes("group report: D1 write failed"))).toBe(true);
    expect(flow.logs.some((l) => l.includes("push"))).toBe(true);
    // …and nothing logged carries any of the flow's sensitive values
    for (const line of flow.logs) for (const s of flow.secrets) expect(line.includes(s), `log line leaks a secret: ${line}`).toBe(false);
  });

  it("push fan-out to a multi-device account reveals no device ids or tokens to members", () => {
    // the push really went to B's devices
    expect(flow.sentTokens).toEqual(expect.arrayContaining([flow.bTokens[0], flow.bTokens[2]]));
    const bSecrets = [...flow.bDeviceIds, ...flow.bTokens];
    const seen = [
      ...flow.views.map((v) => JSON.stringify(v)), ...flow.eventLists.map((e) => JSON.stringify(e)),
      ...flow.keyLists.map((k) => JSON.stringify(k)), ...flow.frames,
    ];
    for (const s of seen) for (const x of bSecrets) expect(s.includes(x)).toBe(false);
    for (const v of flow.views) {
      for (const m of v.members as Record<string, unknown>[]) {
        const keys = Object.keys(m);
        for (const k of keys) expect(PUBLIC_MEMBER_KEYS.has(k), `unexpected member key ${k}`).toBe(true);
        expect(keys).toEqual(expect.arrayContaining(["memberId", "kind", "joinedAt", "pubKey", "hasKey"]));
        if (m.kind === "account") expect(keys).toEqual(expect.arrayContaining(["accountId", "pubKeySig"]));
        else expect(keys.includes("accountId") || keys.includes("pubKeySig")).toBe(false);
      }
      expect("metaCipher" in v).toBe(false);
    }
    // only the owner's view carries the invite code
    expect(flow.views.map((v) => "inviteCode" in v)).toEqual([true, false, false]);
    for (const list of flow.eventLists) for (const e of list) for (const k of Object.keys(e)) expect(EVENT_KEYS.has(k), `unexpected event key ${k}`).toBe(true);
    for (const f of flow.frames) {
      const parsed = JSON.parse(f) as { t: string; e: GroupEvent };
      expect(Object.keys(parsed).sort()).toEqual(["e", "t"]);
      expect(parsed.t).toBe("ev");
      for (const k of Object.keys(parsed.e)) expect(EVENT_KEYS.has(k)).toBe(true);
    }
  });

  it("no response body or websocket frame ever contains a deviceId or push token", () => {
    expect(flow.bodies.length).toBeGreaterThan(20);
    expect(flow.frames.length).toBeGreaterThan(5);
    for (const body of [...flow.bodies, ...flow.frames]) {
      for (const s of flow.deviceSecrets) expect(body.includes(s), `client output leaks a device id / token: ${body.slice(0, 200)}`).toBe(false);
    }
  });

  it("no KV key or value carries a raw anonymous deviceId, and no wslog entry mentions a groupId", async () => {
    for (const ns of [env.V2_STORE, env.ROOMS, env.METRICS] as KVNamespace[]) {
      let cursor: string | undefined;
      do {
        const page = await ns.list({ cursor });
        for (const k of page.keys) {
          // `device:<id>` is the pre-existing device registry (push token), written by /v2 registration, not by group code.
          if (k.name === `device:${flow.anonDeviceId}`) continue;
          expect(k.name.includes(flow.anonDeviceId), `KV key ${k.name}`).toBe(false);
          const val = (await ns.get(k.name)) ?? "";
          expect(val.includes(flow.anonDeviceId), `KV value of ${k.name}`).toBe(false);
          if (k.name.startsWith("wslog:")) expect(val.includes(flow.groupId) || k.name.includes(flow.groupId)).toBe(false);
        }
        cursor = page.list_complete ? undefined : page.cursor;
      } while (cursor);
    }
  });

  it("the room's storage holds no account device id or token, and the anonymous deviceId only in meta", () => {
    expect(flow.storageDump.length).toBeGreaterThan(5);
    const tokens = flow.deviceSecrets.filter((s) => !flow.accountDeviceIds.includes(s) && s !== flow.anonDeviceId);
    for (const [k, v] of flow.storageDump) {
      const text = `${k} ${JSON.stringify(v)}`;
      for (const s of [...flow.accountDeviceIds, ...tokens]) expect(text.includes(s), `storage ${k}`).toBe(false);
      if (k !== "meta") expect(text.includes(flow.anonDeviceId), `storage ${k}`).toBe(false);
      expect(text.includes("excerpt-pv")).toBe(false);
    }
  });

  it("D1 keeps anonymous members out of the group index; reports name only the reporter's own identity", async () => {
    const gm = (await env.ACCOUNTS_DB.prepare("SELECT * FROM group_members").all()).results;
    const gi = (await env.ACCOUNTS_DB.prepare("SELECT * FROM group_invites").all()).results;
    expect(JSON.stringify([...gm, ...gi]).includes(flow.anonDeviceId)).toBe(false);
    const rows = (await env.ACCOUNTS_DB.prepare("SELECT * FROM reports WHERE group_id = ?1 ORDER BY created_at").bind(flow.groupId).all<ReportRow>()).results;
    expect(rows).toHaveLength(2);
    const byB = rows.find((r) => r.reporter_account_id === flow.b.accountId)!;
    const byC = rows.find((r) => r.reporter_device_id === flow.anonDeviceId)!;
    expect(byB.reporter_device_id).toBeNull();
    expect(byC.reporter_account_id).toBeNull();
    expect(byB.sender_hash).toBe(await senderHash(TEST_TOKEN_SECRET, `anon:${flow.anonDeviceId}`));
    expect(byC.sender_hash).toBe(await senderHash(TEST_TOKEN_SECRET, flow.a.accountId));
    for (const r of rows) expect(r.sender_hash).toMatch(/^[0-9a-f]{64}$/);
    for (const s of [...flow.accountDeviceIds, ...flow.bTokens]) expect(JSON.stringify(rows).includes(s)).toBe(false);
  });

  it("the admin reports output carries the documented fields and no account device id or token", () => {
    const { reports } = JSON.parse(flow.adminBody) as { reports: Record<string, unknown>[] };
    const mine = reports.filter((r) => r.groupId === flow.groupId);
    expect(mine).toHaveLength(2);
    for (const r of mine) {
      expect(Object.keys(r).sort()).toEqual(["createdAt", "diaryId", "diarySeq", "excerpt", "groupId", "groupSeq", "id", "inboxItemId", "reason", "reporterAccountId", "reporterDeviceId", "senderHash"]);
    }
    for (const s of [...flow.accountDeviceIds, ...flow.bTokens]) expect(flow.adminBody.includes(s)).toBe(false);
  });
});
