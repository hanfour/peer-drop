// Drives the /v3/groups* content routes (Task 7): events, key relay,
// rotation, metaCipher, WebSocket tickets/upgrade and the push wiring.
// Setup goes through SELF.fetch (APNS_KEY_P8 is unset in the test env, so
// those calls never push). The calls whose pushes are under test go through
// handleGroupRoute directly with a fake `deps.push.send` and a recording
// `waitUntil` (same pattern as diary-push.spec.ts).
import { env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import {
  makeGroupAccount, makeAnonDevice, newGroupId, newMemberId, fakeMeta, fakeWrap, signWrap,
  bearer, asMember, createGroupOk, joinGroup, anonJoinBody, joinAsAccountOk, getGroup, leaveGroup, kickMember, closeGroup,
  signedWraps, fakePayload, postEvent, listEvents, getGroupMeta, putGroupMeta, rotateGroup, getKeys, putKeys,
  wsTicket, wsUpgrade, connectMember,
} from "./groupHelpers";
import type { GroupAccount, AnonDevice } from "./groupHelpers";
import { authorizeGroupCaller } from "../index";
import type { Env } from "../index";
import { handleGroupRoute } from "../group";
import { deliverGroupPush, GROUP_PUSH_CONCURRENCY } from "../groupPush";
import { GROUP_PUSH } from "../groupRoom";
import type { PushRecipient } from "../groupRoom";
import type { PushDeps } from "../notes";
import type { sendAPNs } from "../apns";
import { ulid } from "../notes";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

let devCounter = 0;
const nextDev = (tag: string) => `dev-grc-${tag}-${String(++devCounter).padStart(4, "0")}`;
const acct = (tag: string) => makeGroupAccount(nextDev(tag));
const anonDev = (tag: string) => makeAnonDevice(nextDev(tag));

const fakeEnv = (): Env => ({ ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" }) as unknown as Env;

interface SendCall { token: string; payload: Record<string, unknown>; opts?: { pushType?: string; priority?: number } }

/** handleGroupRoute with a recording push sender and a recording waitUntil. */
function harness(opts: { failSend?: boolean } = {}) {
  const calls: SendCall[] = [];
  const pending: Promise<unknown>[] = [];
  const send = (async (token: string, payload: Record<string, unknown>, _cfg: unknown, o?: SendCall["opts"]) => {
    if (opts.failSend) throw new Error(`boom https://api.push.apple.com/3/device/${token}`);
    calls.push({ token, payload, opts: o });
    return { ok: true, status: 200 };
  }) as unknown as typeof sendAPNs;
  const fEnv = fakeEnv();
  const push: PushDeps = { send, topicFor: () => "topic" };
  const deps = { push, authorize: (r: Request) => authorizeGroupCaller(r, fEnv), waitUntil: (p: Promise<unknown>) => { pending.push(p); } };
  const call = (method: string, path: string, headers: Record<string, string>, body?: unknown) => {
    const req = new Request(`https://example.com${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    return handleGroupRoute(req, new URL(req.url), path, fEnv, deps);
  };
  const flush = async () => { while (pending.length) await Promise.all(pending.splice(0)); };
  return { calls, call, flush, pending };
}

async function setToken(deviceId: string, token: string) {
  await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: token, platform: "ios" }));
}

interface Room {
  groupId: string; inviteCode: string;
  owner: GroupAccount; ownerMember: string; oh: Record<string, string>;
  b: GroupAccount; bMember: string; bh: Record<string, string>;
  c: AnonDevice; cMember: string; ch: Record<string, string>;
}

/**
 * Owner + account member B (two devices with push tokens) + anonymous member
 * C (one token); the owner relays the epoch-1 key to B and C over PUT /keys.
 */
async function room(tag: string): Promise<Room> {
  const owner = await acct(`${tag}-o`), b = await acct(`${tag}-b`), c = await anonDev(`${tag}-c`);
  const { groupId, inviteCode, memberId: ownerMember } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
  const bMember = await joinAsAccountOk(b, groupId, inviteCode);
  const cBody = anonJoinBody(inviteCode);
  const rc = await joinGroup(bearer(c), groupId, cBody);
  expect(rc.status).toBe(201);
  const oh = asMember(bearer(owner), ownerMember);
  const relay = await putKeys(oh, groupId, { epoch: 1, wraps: await signedWraps(owner, groupId, 1, ownerMember, [bMember, cBody.memberId]) });
  expect(relay.status).toBe(200);
  expect(await relay.json()).toEqual({ written: [bMember, cBody.memberId], skipped: [] });
  await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, 'ios', 1)").bind(b.accountId, `${b.deviceId}-2`).run();
  await setToken(owner.deviceId, `tok-${tag}-owner`);
  await setToken(b.deviceId, `tok-${tag}-b1`);
  await setToken(`${b.deviceId}-2`, `tok-${tag}-b2`);
  await setToken(c.deviceId, `tok-${tag}-c`);
  return {
    groupId, inviteCode, owner, ownerMember, oh,
    b, bMember, bh: asMember(bearer(b), bMember),
    c, cMember: cBody.memberId, ch: asMember(bearer(c), cBody.memberId),
  };
}

const msgBody = (opts: { eventId?: string; epoch?: number; payloadCipher?: string } = {}) =>
  ({ eventId: opts.eventId ?? ulid(), epoch: opts.epoch ?? 1, payloadCipher: opts.payloadCipher ?? fakePayload() });
const epochOf = async (h: Record<string, string>, groupId: string) => ((await (await getGroup(h, groupId)).json()) as { epoch: number }).epoch;

describe("/v3/groups content routes", () => {
  it("post msg returns only {seq} and pushes to every device of an offline account member", async () => {
    const r = await room("post");
    const h = harness();
    const eventId = ulid();
    const resp = await h.call("POST", `/v3/groups/${r.groupId}/events`, r.oh, msgBody({ eventId }));
    expect(resp.status).toBe(201);
    const body = await resp.json() as Record<string, unknown>;
    expect(Object.keys(body)).toEqual(["seq"]);
    expect(typeof body.seq).toBe("number");
    await h.flush();
    expect(h.calls.map((c) => c.token).sort()).toEqual(["tok-post-b1", "tok-post-b2", "tok-post-c"]);
    for (const c of h.calls) {
      expect(c.payload).toEqual({ alert: { "loc-key": "GROUP_MESSAGE" }, customData: { type: "groupMessage", groupId: r.groupId } });
      expect(c.opts?.pushType).toBeUndefined();
    }
    // A resend is the same seq, 200, and pushes nobody.
    const again = await h.call("POST", `/v3/groups/${r.groupId}/events`, r.oh, msgBody({ eventId }));
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ seq: body.seq });
    await h.flush();
    expect(h.calls).toHaveLength(3);
  });

  it("push failures never fail the post, and nothing about the token is logged", async () => {
    const r = await room("pfail");
    const h = harness({ failSend: true });
    const logged: string[] = [];
    const orig = console.error;
    console.error = (...args: unknown[]) => { logged.push(args.map(String).join(" ")); };
    try {
      const resp = await h.call("POST", `/v3/groups/${r.groupId}/events`, r.oh, msgBody());
      expect(resp.status).toBe(201);
      await h.flush();
    } finally {
      console.error = orig;
    }
    expect(logged.length).toBeGreaterThan(0);
    for (const l of logged) {
      expect(l).not.toContain("tok-pfail");
      expect(l).not.toContain("api.push.apple.com");
      expect(l).not.toContain(r.c.deviceId);
    }
  });

  it("post validates its body before anything else", async () => {
    const r = await room("postval");
    const big = await postEvent(r.oh, r.groupId, { ...msgBody(), payloadCipher: fakeMeta(13 * 1024) });
    expect(big.status).toBe(413);
    expect(await big.json()).toEqual({ error: "too_large" });
    expect(await (await postEvent(r.oh, r.groupId, { eventId: ulid() })).json()).toEqual({ error: "missing_fields" });
    // a payload over 8 KB inside a small enough body: the room's own 413
    const p9 = await postEvent(r.oh, r.groupId, msgBody({ payloadCipher: fakeMeta(9 * 1024) }));
    expect(p9.status).toBe(413);
    // stale epoch carries the current one
    const st = await postEvent(r.oh, r.groupId, msgBody({ epoch: 3 }));
    expect(st.status).toBe(409);
    expect(await st.json()).toEqual({ error: "stale_epoch", epoch: 1 });
    // unknown group → 404
    expect((await postEvent(r.oh, newGroupId(), msgBody())).status).toBe(404);
  });

  it("a connected member gets the event over the websocket and no push", async () => {
    const r = await room("ws");
    const sock = await connectMember(r.bh, r.groupId);
    const h = harness();
    const payloadCipher = fakePayload(24);
    const resp = await h.call("POST", `/v3/groups/${r.groupId}/events`, r.oh, msgBody({ payloadCipher }));
    expect(resp.status).toBe(201);
    const { seq } = await resp.json() as { seq: number };
    await h.flush();
    await sock.waitFor(() => sock.messages.some((m) => (JSON.parse(m) as { e: { seq: number } }).e.seq === seq));
    const frame = sock.messages.map((m) => JSON.parse(m) as { t: string; e: Record<string, unknown> }).find((f) => f.e.seq === seq)!;
    expect(frame.t).toBe("ev");
    expect(frame.e).toMatchObject({ seq, type: "msg", authorMemberId: r.ownerMember, payloadCipher });
    for (const m of sock.messages) {
      expect(m).not.toContain(r.c.deviceId);
      expect(m).not.toContain(r.owner.deviceId);
    }
    expect(h.calls.map((c) => c.token)).toEqual(["tok-ws-c"]);
    sock.ws.close();
  });

  it("events GET pages with since/limit and validates the query", async () => {
    const r = await room("list");
    const seqs: number[] = [];
    for (let i = 0; i < 3; i++) seqs.push(((await (await postEvent(r.oh, r.groupId, msgBody())).json()) as { seq: number }).seq);
    const all = await listEvents(r.bh, r.groupId);
    expect(all.status).toBe(200);
    const page = await all.json() as { events: { seq: number; type: string }[]; firstSeq: number };
    expect(page.firstSeq).toBe(1);
    expect(page.events.filter((e) => e.type === "msg").map((e) => e.seq)).toEqual(seqs);
    const p2 = await (await listEvents(r.bh, r.groupId, `?since=${seqs[0]}&limit=1`)).json() as { events: { seq: number }[]; nextSince?: number };
    expect(p2.events.map((e) => e.seq)).toEqual([seqs[1]]);
    expect(p2.nextSince).toBe(seqs[1]);
    for (const qs of ["?since=-1", "?limit=abc", "?since=1.5"]) {
      const bad = await listEvents(r.bh, r.groupId, qs);
      expect(bad.status).toBe(400);
      expect(await bad.json()).toEqual({ error: "bad_request" });
    }
    expect((await listEvents(asMember(bearer(r.b), newMemberId()), r.groupId)).status).toBe(403);
    const text = await (await listEvents(r.ch, r.groupId)).text();
    expect(text).not.toContain(r.c.deviceId);
  });

  it("meta GET for members, PUT for the owner only", async () => {
    const r = await room("meta");
    const g = await getGroupMeta(r.ch, r.groupId);
    expect(g.status).toBe(200);
    const m1 = await g.json() as { metaCipher: string; metaVersion: number };
    expect(m1.metaVersion).toBe(1);
    expect(typeof m1.metaCipher).toBe("string");
    const metaCipher = fakeMeta(64);
    const notOwner = await putGroupMeta(r.bh, r.groupId, { eventId: ulid(), metaCipher });
    expect(notOwner.status).toBe(403);
    expect(await notOwner.json()).toEqual({ error: "not_owner" });
    const ok = await putGroupMeta(r.oh, r.groupId, { eventId: ulid(), metaCipher });
    expect(ok.status).toBe(201);
    const okBody = await ok.json() as Record<string, unknown>;
    expect(Object.keys(okBody).sort()).toEqual(["metaVersion", "seq"]);
    expect(okBody.metaVersion).toBe(2);
    expect(await (await getGroupMeta(r.bh, r.groupId)).json()).toEqual({ metaCipher, metaVersion: 2 });
    expect((await putGroupMeta(r.oh, r.groupId, { eventId: ulid(), metaCipher: fakeMeta(610 * 1024) })).status).toBe(413);
    expect((await putGroupMeta(r.oh, r.groupId, { eventId: ulid(), metaCipher: fakeMeta(400 * 1024 + 1) })).status).toBe(413);
    expect(await (await putGroupMeta(r.oh, r.groupId, { eventId: ulid() })).json()).toEqual({ error: "missing_fields" });
  });

  it("rotate verifies every wrap signature (400 bad_sig on one bad sig, epoch unchanged)", async () => {
    const r = await room("rot");
    const targets = [r.ownerMember, r.bMember, r.cMember];
    const good = await signedWraps(r.owner, r.groupId, 2, r.ownerMember, targets);
    const bad = [
      // one wrap signed as if B had wrapped it
      good.map((w, i) => (i === 2 ? { ...w, sig: "" } : w)),
      // one wrap signed by another account's key over the right bytes
      [...good.slice(0, 2), (await signedWraps(r.b, r.groupId, 2, r.ownerMember, [r.cMember]))[0]],
      // one wrap signed for the wrong epoch
      [...good.slice(0, 2), (await signedWraps(r.owner, r.groupId, 3, r.ownerMember, [r.cMember]))[0]],
    ];
    bad[0][2] = { ...good[2], sig: await signWrap(r.owner, r.groupId, 2, r.cMember, r.bMember, good[2].wrapped) };
    for (const wraps of bad) {
      const resp = await rotateGroup(r.oh, r.groupId, { eventId: ulid(), epoch: 2, wraps, metaCipher: fakeMeta() });
      expect(resp.status).toBe(400);
      expect(await resp.json()).toEqual({ error: "bad_sig" });
      expect(await epochOf(r.oh, r.groupId)).toBe(1);
    }
    // a malformed wrap is bad_wrap, an epoch out of range bad_request
    expect(await (await rotateGroup(r.oh, r.groupId, { eventId: ulid(), epoch: 2, wraps: [{ ...good[0], wrapped: "AAAA" }], metaCipher: fakeMeta() })).json()).toEqual({ error: "bad_wrap" });
    expect((await rotateGroup(r.oh, r.groupId, { eventId: ulid(), epoch: 2 ** 32 + 2, wraps: good, metaCipher: fakeMeta() })).status).toBe(400);
    // a non-owner with its own valid signatures is refused by the room
    const bWraps = await signedWraps(r.b, r.groupId, 2, r.bMember, targets);
    expect(await (await rotateGroup(r.bh, r.groupId, { eventId: ulid(), epoch: 2, wraps: bWraps, metaCipher: fakeMeta() })).json()).toEqual({ error: "not_owner" });
    // missing a member → members_changed with the current ids
    const mc = await rotateGroup(r.oh, r.groupId, { eventId: ulid(), epoch: 2, wraps: good.slice(0, 2), metaCipher: fakeMeta() });
    expect(mc.status).toBe(409);
    expect(((await mc.json()) as { memberIds: string[] }).memberIds.sort()).toEqual([...targets].sort());

    const eventId = ulid();
    const ok = await rotateGroup(r.oh, r.groupId, { eventId, epoch: 2, wraps: good, metaCipher: fakeMeta() });
    expect(ok.status).toBe(201);
    const okBody = await ok.json() as { seq: number; epoch: number };
    expect(Object.keys(okBody).sort()).toEqual(["epoch", "seq"]);
    expect(okBody.epoch).toBe(2);
    expect(await epochOf(r.oh, r.groupId)).toBe(2);
    // replay
    const again = await rotateGroup(r.oh, r.groupId, { eventId, epoch: 2, wraps: good, metaCipher: fakeMeta() });
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual(okBody);
    // C now holds an epoch-2 wrap by the owner
    const keys = await (await getKeys(r.ch, r.groupId)).json() as { wraps: { epoch: number; wrappedBy: string }[] };
    expect(keys.wraps.map((w) => [w.epoch, w.wrappedBy])).toEqual([[1, r.ownerMember], [2, r.ownerMember]]);
  });

  it("key relay over HTTP verifies the relayer's signature", async () => {
    const r = await room("relay");
    const d = await acct("relay-d");
    const dMember = await joinAsAccountOk(d, r.groupId, r.inviteCode);
    const dh = asMember(bearer(d), dMember);
    const awaiting = await postEvent(dh, r.groupId, msgBody());
    expect(awaiting.status).toBe(403);
    expect(await awaiting.json()).toEqual({ error: "awaiting_key" });

    const wrapped = fakeWrap();
    const forgeries = [
      await signWrap(r.owner, r.groupId, 1, dMember, r.bMember, wrapped), // someone else's key
      await signWrap(r.b, r.groupId, 1, dMember, r.ownerMember, wrapped), // wrong wrapper id
      await signWrap(r.b, r.groupId, 1, r.cMember, r.bMember, wrapped),   // wrong target
    ];
    for (const sig of forgeries) {
      const resp = await putKeys(r.bh, r.groupId, { epoch: 1, wraps: [{ memberId: dMember, wrapped, sig }] });
      expect(resp.status).toBe(400);
      expect(await resp.json()).toEqual({ error: "bad_sig" });
    }
    expect(await (await getKeys(dh, r.groupId)).json()).toEqual({ wraps: [] });
    // anonymous members can't relay at all (Ruling 7)
    const anonRelay = await putKeys(r.ch, r.groupId, { epoch: 1, wraps: [{ memberId: dMember, wrapped, sig: forgeries[0] }] });
    expect(anonRelay.status).toBe(403);
    expect(await anonRelay.json()).toEqual({ error: "account_required" });
    // too large / malformed
    expect((await putKeys(r.bh, r.groupId, { epoch: 1, wraps: [], pad: "x".repeat(33 * 1024) })).status).toBe(413);
    expect(await (await putKeys(r.bh, r.groupId, { epoch: 1 })).json()).toEqual({ error: "missing_fields" });

    const sig = await signWrap(r.b, r.groupId, 1, dMember, r.bMember, wrapped);
    const ok = await putKeys(r.bh, r.groupId, { epoch: 1, wraps: [{ memberId: dMember, wrapped, sig }] });
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ written: [dMember], skipped: [] });
    expect(await (await getKeys(dh, r.groupId)).json()).toEqual({ wraps: [{ epoch: 1, wrapped, wrappedBy: r.bMember, sig }] });
    expect((await postEvent(dh, r.groupId, msgBody())).status).toBe(201);
  });

  it("request-key sends a silent push and is limited to 6 per hour", async () => {
    const r = await room("rk");
    const d = await acct("rk-d");
    const dMember = await joinAsAccountOk(d, r.groupId, r.inviteCode);
    const dh = asMember(bearer(d), dMember);
    const h = harness();
    for (let i = 0; i < 6; i++) {
      const resp = await h.call("POST", `/v3/groups/${r.groupId}/request-key`, dh);
      expect(resp.status).toBe(204);
    }
    await h.flush();
    // the keyed ACCOUNT members (owner, B on both devices) — never the anonymous C
    expect(new Set(h.calls.map((c) => c.token))).toEqual(new Set(["tok-rk-owner", "tok-rk-b1", "tok-rk-b2"]));
    expect(h.calls).toHaveLength(18);
    for (const c of h.calls) {
      expect(c.payload).toEqual({ contentAvailable: true, customData: { type: "groupKeyRequest", groupId: r.groupId } });
      expect(c.opts).toMatchObject({ pushType: "background", priority: 5 });
    }
    const limited = await h.call("POST", `/v3/groups/${r.groupId}/request-key`, dh);
    expect(limited.status).toBe(429);
    expect(await limited.json()).toEqual({ error: "rate_limited" });
    await h.flush();
    expect(h.calls).toHaveLength(18);
    // a non-member's claim doesn't spend the member's budget
    const stranger = await acct("rk-x");
    const sr = await h.call("POST", `/v3/groups/${r.groupId}/request-key`, asMember(bearer(stranger), r.bMember));
    expect(sr.status).toBe(403);
  });

  it("ws upgrade ignores Authorization and forged internal fields; only the ticket counts", async () => {
    const r = await room("wsauth");
    const t = await wsTicket(r.bh, r.groupId);
    expect(t.status).toBe(200);
    const tb = await t.json() as { ticket: string; expiresInSeconds: number };
    expect(Object.keys(tb).sort()).toEqual(["expiresInSeconds", "ticket"]);
    expect(tb.expiresInSeconds).toBe(60);

    const noTicket = await wsUpgrade(r.groupId, null);
    expect(noTicket.status).toBe(403);
    expect(await noTicket.json()).toEqual({ error: "denied" });
    const bearerOnly = await wsUpgrade(r.groupId, null, { ...r.bh, Upgrade: "websocket" });
    expect(bearerOnly.status).toBe(403);
    expect((await wsUpgrade(r.groupId, "forged", { ...r.bh, Upgrade: "websocket", "X-Group-Member-Id": r.bMember })).status).toBe(403);
    expect((await wsUpgrade(r.groupId, "A".repeat(65))).status).toBe(403);
    // not an upgrade → 400, and the ticket isn't spent by it
    const plain = await wsUpgrade(r.groupId, tb.ticket, {});
    expect(plain.status).toBe(400);
    // the ticket for this room doesn't open another one
    const other = await room("wsauth2");
    expect((await wsUpgrade(other.groupId, tb.ticket)).status).toBe(403);
    // unknown room → 404
    expect((await wsUpgrade(newGroupId(), tb.ticket)).status).toBe(404);
    // …but here it does, once
    const ok = await wsUpgrade(r.groupId, tb.ticket, { Upgrade: "WebSocket" });
    expect(ok.status).toBe(101);
    ok.webSocket!.accept();
    ok.webSocket!.close();
    expect((await wsUpgrade(r.groupId, tb.ticket)).status).toBe(403);
    // a ticket needs a member
    expect((await wsTicket(asMember(bearer(r.owner), r.bMember), r.groupId)).status).toBe(403);
  });

  it("closed room: events GET and leave still work; post/meta/rotate are 403 group_closed", async () => {
    const r = await room("closed");
    expect((await postEvent(r.bh, r.groupId, msgBody())).status).toBe(201);
    expect((await closeGroup(r.oh, r.groupId)).status).toBe(204);
    const list = await listEvents(r.bh, r.groupId);
    expect(list.status).toBe(200);
    expect(((await list.json()) as { events: unknown[] }).events.length).toBeGreaterThan(0);
    expect(await (await postEvent(r.bh, r.groupId, msgBody())).json()).toEqual({ error: "group_closed" });
    expect(await (await putGroupMeta(r.oh, r.groupId, { eventId: ulid(), metaCipher: fakeMeta() })).json()).toEqual({ error: "group_closed" });
    const wraps = await signedWraps(r.owner, r.groupId, 2, r.ownerMember, [r.ownerMember, r.bMember, r.cMember]);
    const rot = await rotateGroup(r.oh, r.groupId, { eventId: ulid(), epoch: 2, wraps, metaCipher: fakeMeta() });
    expect(rot.status).toBe(403);
    expect(await rot.json()).toEqual({ error: "group_closed" });
    expect((await leaveGroup(r.bh, r.groupId)).status).toBe(204);
    expect((await listEvents(r.bh, r.groupId)).status).toBe(403);
  });

  it("a kicked member's open socket closes 4003 and its ticket stops working", async () => {
    const r = await room("kick");
    const sock = await connectMember(r.bh, r.groupId);
    const spare = await (await wsTicket(r.bh, r.groupId)).json() as { ticket: string };
    expect((await kickMember(r.oh, r.groupId, r.bMember)).status).toBe(204);
    await sock.waitFor(() => sock.closed !== null);
    expect(sock.closed).toEqual({ code: 4003, reason: "removed" });
    expect((await wsUpgrade(r.groupId, spare.ticket)).status).toBe(403);
    const t = await wsTicket(r.bh, r.groupId);
    expect(t.status).toBe(403);
    expect(await t.json()).toEqual({ error: "not_member" });
  });

  it("deliverGroupPush runs at most GROUP_PUSH_CONCURRENCY sends at a time", async () => {
    expect(GROUP_PUSH_CONCURRENCY).toBeLessThanOrEqual(8);
    const recipients: PushRecipient[] = [];
    for (let i = 0; i < 49; i++) {
      const deviceId = nextDev(`conc-${i}`);
      await setToken(deviceId, `tok-conc-${i}`);
      recipients.push({ kind: "device", deviceId });
    }
    let inFlight = 0, peak = 0;
    const sent: string[] = [];
    const send = (async (token: string) => {
      inFlight++; peak = Math.max(peak, inFlight);
      await new Promise((res) => setTimeout(res, 5));
      inFlight--; sent.push(token);
      if (token === "tok-conc-3") throw new Error("one fails");
      return { ok: true, status: 200 };
    }) as unknown as typeof sendAPNs;
    await deliverGroupPush(fakeEnv(), recipients, GROUP_PUSH.message("G"), { send, topicFor: () => "topic" });
    expect(sent).toHaveLength(49);
    expect(peak).toBeLessThanOrEqual(GROUP_PUSH_CONCURRENCY);
    expect(peak).toBeGreaterThan(1);
  });
});
