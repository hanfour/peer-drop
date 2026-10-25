// Drives the GroupRoom Durable Object directly (bypassing the /v3/groups
// HTTP routes and D1) — same style as diary-room.spec.ts. This pins down the
// membership / invite state machine: init idempotency, the join check order,
// same-identity replacement (Ruling 12), and that nothing is written for an
// id that was never initialised.
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { ulid } from "../notes";
import { sha256Hex } from "../groupSig";
import type { GroupRoom, GroupMeta, GroupEvent, Caller, PublicMember, WrapRecord } from "../groupRoom";

const stubFor = (name: string) => env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(name));

/** Base64 of `n` identical bytes — right size, not cryptographically real. */
const b64 = (n: number, fill = 7) => btoa(String.fromCharCode(...new Uint8Array(n).fill(fill)));

const acct = (memberId: string, accountId: string, lane: Caller["lane"] = "bearer"): Caller =>
  ({ memberId, accountId, deviceId: `DEV-${accountId}`, lane });
const anon = (memberId: string, deviceId: string, lane: Caller["lane"] = "bearer"): Caller =>
  ({ memberId, accountId: null, deviceId, lane });

const post = (stub: DurableObjectStub, path: string, body: unknown) =>
  stub.fetch(`https://group${path}`, { method: "POST", body: JSON.stringify(body) });

async function initGroup(stub: DurableObjectStub, accountId: string, opts: { memberId?: string; joinPolicy?: string; inviteCode?: string } = {}) {
  const groupId = ulid();
  const memberId = opts.memberId ?? ulid();
  const r = await post(stub, "/init", {
    groupId,
    owner: { memberId, accountId, pubKey: b64(32), pubKeySig: b64(64) },
    ownerWrap: { wrapped: b64(92), sig: b64(64) },
    metaCipher: "METACIPHERSECRET",
    joinPolicy: opts.joinPolicy ?? "accountOnly",
    inviteCode: opts.inviteCode ?? "INVITE01",
  });
  const body = await r.clone().json() as Partial<GroupMeta>;
  return { r, groupId, ownerMemberId: memberId, inviteCode: body.inviteCode as string };
}

const accountMember = (memberId: string, accountId: string) =>
  ({ memberId, kind: "account", accountId, pubKey: b64(32, 1), pubKeySig: b64(64, 2) });
const anonMember = (memberId: string, deviceId: string) =>
  ({ memberId, kind: "anon", deviceId, pubKey: b64(32, 3) });

/** The authenticated caller a route would hand the DO for this member's join. */
function callerFor(member: unknown): Caller {
  const m = member as { memberId: string; kind: string; accountId?: string; deviceId?: string };
  return m.kind === "anon" ? anon(m.memberId, m.deviceId ?? "NODEVICE") : acct(m.memberId, m.accountId ?? "NOACCT01");
}
const joinBody = (inviteCode: string, member: unknown, dryRun?: boolean, caller: Caller = callerFor(member)) =>
  ({ caller, inviteCode, member, ...(dryRun === undefined ? {} : { dryRun }) });
const join = (stub: DurableObjectStub, inviteCode: string, member: unknown, dryRun?: boolean, caller?: Caller) =>
  post(stub, "/join", joinBody(inviteCode, member, dryRun, caller));
const view = (stub: DurableObjectStub, caller: Caller) => post(stub, "/view", { caller });

async function storageKeys(stub: DurableObjectStub): Promise<string[]> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list()).keys()]);
}

describe("GroupRoom: init", () => {
  it("init creates epoch 1 with the owner keyed, idempotent for the same owner", async () => {
    const stub = stubFor("g-init-1");
    const before = Date.now();
    const { r, ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODEAAAA" });
    expect(r.status).toBe(201);
    const meta = await r.json() as GroupMeta;
    expect(meta).toMatchObject({
      ownerMemberId, joinPolicy: "accountOnly", discoverability: "private", state: "open",
      epoch: 1, seq: 0, firstSeq: 1, metaVersion: 1, rotationDue: false, inviteCode: "CODEAAAA",
    });
    expect(meta.members).toHaveLength(1);
    expect(meta.members[0]).toMatchObject({ memberId: ownerMemberId, kind: "account", accountId: "OWNERAC1", joinedEpoch: 1 });
    expect(meta.members[0].deviceId).toBeUndefined();

    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      const wrap = await state.storage.get<WrapRecord>(`key:0000000001:${ownerMemberId}`);
      expect(wrap).toMatchObject({ wrapped: b64(92), wrappedBy: ownerMemberId, sig: b64(64) });
      expect(await state.storage.get("metacipher")).toBe("METACIPHERSECRET");
      const alarm = await state.storage.getAlarm();
      expect(alarm).not.toBeNull();
      expect(alarm!).toBeGreaterThanOrEqual(before + 24 * 3600_000);
    });

    // Same owner re-sends (with a different invite code / cipher): 200, untouched.
    const again = await post(stub, "/init", {
      groupId: meta.groupId,
      owner: { memberId: ownerMemberId, accountId: "OWNERAC1", pubKey: b64(32), pubKeySig: b64(64) },
      ownerWrap: { wrapped: b64(92), sig: b64(64) },
      metaCipher: "OTHERXYZ", joinPolicy: "anonymousAllowed", inviteCode: "CODEBBBB",
    });
    expect(again.status).toBe(200);
    const meta2 = await again.json() as GroupMeta;
    expect(meta2.inviteCode).toBe("CODEAAAA");
    expect(meta2.metaVersion).toBe(1);
    expect(meta2.joinPolicy).toBe("accountOnly");
  });

  it("init by a different account is 409 group_exists", async () => {
    const stub = stubFor("g-init-2");
    await initGroup(stub, "OWNERAC1");
    const { r } = await initGroup(stub, "OTHERAC1");
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "group_exists" });
  });

  it("init rejects malformed bodies with 400 and writes nothing", async () => {
    const stub = stubFor("g-init-3");
    const r = await post(stub, "/init", { groupId: "nope", owner: {}, ownerWrap: {}, metaCipher: "", joinPolicy: "x" });
    expect(r.status).toBe(400);
    expect(await storageKeys(stub)).toEqual([]);
  });

  it("every non-init endpoint on an uninitialised id is 404 and leaves storage empty", async () => {
    const stub = stubFor("g-uninit");
    const c = acct(ulid(), "SOMEACC1");
    for (const [path, body] of [
      ["/view", { caller: c }],
      ["/join", joinBody("X", accountMember(c.memberId, "SOMEACC1"))],
      ["/close", { caller: c }],
      ["/invite/reset", { caller: c }],
    ] as const) {
      const r = await post(stub, path, body);
      expect(r.status, path).toBe(404);
    }
    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      expect((await state.storage.list()).size).toBe(0);
      expect(await state.storage.getAlarm()).toBeNull();
    });
  });
});

describe("GroupRoom: view", () => {
  it("view never carries deviceId or metaCipher and gives inviteCode only to the owner", async () => {
    const stub = stubFor("g-view-1");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { joinPolicy: "anonymousAllowed", inviteCode: "CODEVIEW" });
    const anonId = ulid();
    expect((await join(stub, "CODEVIEW", anonMember(anonId, "ANON-DEVICE-SECRET"))).status).toBe(201);

    const ownerView = await view(stub, acct(ownerMemberId, "OWNERAC1"));
    expect(ownerView.status).toBe(200);
    const ownerText = await ownerView.text();
    const ov = JSON.parse(ownerText) as { inviteCode?: string; members: PublicMember[]; epoch: number };
    expect(ov.inviteCode).toBe("CODEVIEW");
    expect(ov.members.map((m) => m.memberId)).toEqual([ownerMemberId, anonId]);
    expect(ov.members.find((m) => m.memberId === ownerMemberId)!.hasKey).toBe(true);
    expect(ov.members.find((m) => m.memberId === anonId)!.hasKey).toBe(false);

    const anonView = await view(stub, anon(anonId, "ANON-DEVICE-SECRET"));
    expect(anonView.status).toBe(200);
    const anonText = await anonView.text();
    expect((JSON.parse(anonText) as { inviteCode?: string }).inviteCode).toBeUndefined();

    for (const text of [ownerText, anonText]) {
      expect(text).not.toContain("deviceId");
      expect(text).not.toContain("ANON-DEVICE-SECRET");
      expect(text).not.toContain("DEV-OWNERAC1");
      expect(text).not.toContain("METACIPHERSECRET");
      expect(text).not.toContain("metaCipher");
    }
  });

  it("authorize: non-member is 403 not_member, wrong identity is 403, anon on the key lane is 401 bearer_required", async () => {
    const stub = stubFor("g-view-2");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { joinPolicy: "anonymousAllowed", inviteCode: "CODEAUTH" });
    const anonId = ulid();
    await join(stub, "CODEAUTH", anonMember(anonId, "ANONDEV1"));

    const notMember = await view(stub, acct(ulid(), "OWNERAC1"));
    expect(notMember.status).toBe(403);
    expect(await notMember.json()).toEqual({ error: "not_member" });
    // Right memberId, wrong account / wrong device → still not a member.
    expect((await view(stub, acct(ownerMemberId, "IMPOSTR1"))).status).toBe(403);
    expect((await view(stub, anon(anonId, "OTHERDEV"))).status).toBe(403);
    // An anonymous identity only exists on the Bearer lane (Ruling 5).
    const keyLane = await view(stub, anon(anonId, "ANONDEV1", "key"));
    expect(keyLane.status).toBe(401);
    expect(await keyLane.json()).toEqual({ error: "bearer_required" });
    // Account members may use either lane.
    expect((await view(stub, acct(ownerMemberId, "OWNERAC1", "key"))).status).toBe(200);
  });
});

describe("GroupRoom: join", () => {
  it("join enforces code, closed, ban, full(50), member_id_taken in that order", async () => {
    const stub = stubFor("g-join-order");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODEJOIN" });

    // Ban (seeded directly — kick lands in a later task) beats a bad code.
    const bannedHash = await sha256Hex("acct:BANNEDA1");
    await runInDurableObject(stub, async (_i: GroupRoom, state) => { await state.storage.put(`ban:${bannedHash}`, 1); });
    const banned = await join(stub, "WRONGCOD", accountMember(ulid(), "BANNEDA1"));
    expect(banned.status).toBe(403);
    expect(await banned.json()).toEqual({ error: "banned" });

    const badCode = await join(stub, "WRONGCOD", accountMember(ulid(), "NEWACCT1"));
    expect(badCode.status).toBe(403);
    expect(await badCode.json()).toEqual({ error: "bad_code" });

    // memberId collision with a non-full room → member_id_taken.
    const taken = await join(stub, "CODEJOIN", accountMember(ownerMemberId, "NEWACCT1"));
    expect(taken.status).toBe(409);
    expect(await taken.json()).toEqual({ error: "member_id_taken" });

    // Fill to 50 (owner + 49).
    for (let i = 0; i < 49; i++) {
      const r = await join(stub, "CODEJOIN", accountMember(ulid(), `FILL${String(i).padStart(4, "0")}`));
      expect(r.status).toBe(201);
    }
    const full = await join(stub, "CODEJOIN", accountMember(ulid(), "LATEACC1"));
    expect(full.status).toBe(409);
    expect(await full.json()).toEqual({ error: "group_full_members" });
    // Full beats member_id_taken.
    const fullTaken = await join(stub, "CODEJOIN", accountMember(ownerMemberId, "LATEACC1"));
    expect(await fullTaken.json()).toEqual({ error: "group_full_members" });

    // Closed beats full; bad code still beats closed.
    expect((await post(stub, "/close", { caller: acct(ownerMemberId, "OWNERAC1") })).status).toBe(200);
    const closed = await join(stub, "CODEJOIN", accountMember(ulid(), "LATEACC1"));
    expect(closed.status).toBe(403);
    expect(await closed.json()).toEqual({ error: "group_closed" });
    expect(await (await join(stub, "WRONGCOD", accountMember(ulid(), "LATEACC1"))).json()).toEqual({ error: "bad_code" });
  });

  it("anonymous join into accountOnly is 403 account_required", async () => {
    const stub = stubFor("g-join-anon");
    await initGroup(stub, "OWNERAC1", { inviteCode: "CODEANON" });
    const r = await join(stub, "CODEANON", anonMember(ulid(), "ANONDEV1"));
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "account_required" });
  });

  it("join rejects members whose identity fields don't match their kind", async () => {
    const stub = stubFor("g-join-shape");
    await initGroup(stub, "OWNERAC1", { joinPolicy: "anonymousAllowed", inviteCode: "CODESHAP" });
    const before = await storageKeys(stub);
    for (const member of [
      { ...accountMember(ulid(), "NEWACCT1"), deviceId: "DEV1" }, // DO never stores an account member's device
      { ...anonMember(ulid(), "ANONDEV1"), accountId: "NEWACCT1" },
      { memberId: ulid(), kind: "anon", pubKey: b64(32) }, // anon without deviceId
      { ...accountMember("not-a-ulid", "NEWACCT1") },
      { ...accountMember(ulid(), "NEWACCT1"), pubKey: b64(31) },
      { ...accountMember(ulid(), "NEWACCT1"), kind: "robot" },
      { ...accountMember(ulid(), "NEWACCT1"), pubKey: b64(32).replace(/=+$/, "") }, // unpadded: not strict base64
      { ...accountMember(ulid(), "NEWACCT1"), pubKey: ` ${b64(32)}` }, // whitespace atob() would accept
      accountMember(ulid(), "A".repeat(65)), // accountId over the length cap
      anonMember(ulid(), "D".repeat(129)), // deviceId over the length cap
    ]) {
      const r = await join(stub, "CODESHAP", member);
      expect(r.status, JSON.stringify(member)).toBe(400);
      expect(await r.json()).toEqual({ error: "bad_request" });
    }
    expect(await storageKeys(stub)).toEqual(before);
  });

  it("rejoin with the same memberId is 200 added:false and writes no event", async () => {
    const stub = stubFor("g-join-rejoin");
    await initGroup(stub, "OWNERAC1", { inviteCode: "CODERJ01" });
    const memberId = ulid();
    const first = await join(stub, "CODERJ01", accountMember(memberId, "MEMBERA1"));
    expect(first.status).toBe(201);
    expect(await first.json()).toMatchObject({ added: true });
    const keysAfterFirst = await storageKeys(stub);
    expect(keysAfterFirst).toContain("ev:000000000001");
    // Even with a stale code: an existing member needs no fresh authorization.
    const again = await join(stub, "STALECOD", accountMember(memberId, "MEMBERA1"));
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ added: false });
    expect(await storageKeys(stub)).toEqual(keysAfterFirst);
    const ev = await runInDurableObject(stub, async (_i: GroupRoom, state) => state.storage.get<GroupEvent>("ev:000000000001"));
    expect(ev).toMatchObject({ seq: 1, type: "join", authorMemberId: memberId, epoch: 1, eventId: `srv:join:${memberId}:1` });
  });

  it("same account rejoining with a new memberId replaces the old member and keeps ownership", async () => {
    const stub = stubFor("g-join-replace");
    const { ownerMemberId: oldId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODERPL1" });
    const other = ulid();
    await join(stub, "CODERPL1", accountMember(other, "MEMBERA1")); // seq 1
    const newId = ulid();
    const r = await join(stub, "CODERPL1", accountMember(newId, "OWNERAC1"));
    expect(r.status).toBe(201);
    expect(await r.json()).toMatchObject({ added: true, replaced: true });

    const v = await view(stub, acct(newId, "OWNERAC1"));
    expect(v.status).toBe(200);
    const body = await v.json() as { ownerMemberId: string; members: PublicMember[]; rotationDue: boolean; seq: number; inviteCode?: string };
    expect(body.ownerMemberId).toBe(newId);
    expect(body.members.map((m) => m.memberId)).toEqual([other, newId]);
    expect(body.members.find((m) => m.memberId === newId)!.hasKey).toBe(false); // awaits a relay
    expect(body.rotationDue).toBe(false);
    expect(body.inviteCode).toBe("CODERPL1");
    expect(body.seq).toBe(3);

    await runInDurableObject(stub, async (_i: GroupRoom, state) => {
      const e2 = await state.storage.get<GroupEvent>("ev:000000000002");
      const e3 = await state.storage.get<GroupEvent>("ev:000000000003");
      expect(e2).toMatchObject({ type: "leave", authorMemberId: oldId, eventId: `srv:leave:${oldId}:2` });
      expect(e3).toMatchObject({ type: "join", authorMemberId: newId, ownerMemberId: newId, eventId: `srv:join:${newId}:3` });
      expect(await state.storage.get(`key:0000000001:${oldId}`)).toBeUndefined();
    });
    // The old device's memberId is gone.
    expect((await view(stub, acct(oldId, "OWNERAC1"))).status).toBe(403);
  });

  it("dryRun reports the verdict without writing", async () => {
    const stub = stubFor("g-join-dry");
    await initGroup(stub, "OWNERAC1", { inviteCode: "CODEDRY1" });
    const before = await storageKeys(stub);
    const ok = await join(stub, "CODEDRY1", accountMember(ulid(), "MEMBERA1"), true);
    expect(ok.status).toBe(201);
    expect(await ok.json()).toMatchObject({ added: true });
    const bad = await join(stub, "WRONGCOD", accountMember(ulid(), "MEMBERA1"), true);
    expect(bad.status).toBe(403);
    expect(await bad.json()).toEqual({ error: "bad_code" });
    expect(await storageKeys(stub)).toEqual(before);
  });
});

describe("GroupRoom: owner-only actions", () => {
  it("close and invite/reset are owner-only (403 not_owner)", async () => {
    const stub = stubFor("g-owner-only");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODEOWN1" });
    const memberId = ulid();
    await join(stub, "CODEOWN1", accountMember(memberId, "MEMBERA1"));
    const memberCaller = acct(memberId, "MEMBERA1");

    for (const path of ["/close", "/invite/reset"]) {
      const r = await post(stub, path, { caller: memberCaller });
      expect(r.status, path).toBe(403);
      expect(await r.json()).toEqual({ error: "not_owner" });
    }
    // Strangers are not_member, not not_owner.
    expect(await (await post(stub, "/close", { caller: acct(ulid(), "STRANGR1") })).json()).toEqual({ error: "not_member" });

    const reset = await post(stub, "/invite/reset", { caller: acct(ownerMemberId, "OWNERAC1") });
    expect(reset.status).toBe(200);
    const { inviteCode, previousCode } = await reset.json() as { inviteCode: string; previousCode: string };
    expect(previousCode).toBe("CODEOWN1");
    expect(inviteCode).not.toBe("CODEOWN1");
    expect(inviteCode).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/);
    expect(await (await join(stub, "CODEOWN1", accountMember(ulid(), "MEMBERB1"))).json()).toEqual({ error: "bad_code" });
    expect((await join(stub, inviteCode, accountMember(ulid(), "MEMBERB1"))).status).toBe(201);

    const close = await post(stub, "/close", { caller: acct(ownerMemberId, "OWNERAC1") });
    expect(close.status).toBe(200);
    const v = await view(stub, memberCaller);
    expect((await v.json() as { state: string }).state).toBe("closed");
  });
});

describe("GroupRoom: join identity binding", () => {
  it("the joining member must be the authenticated caller", async () => {
    const stub = stubFor("g-join-impostor");
    await initGroup(stub, "OWNERAC1", { joinPolicy: "anonymousAllowed", inviteCode: "CODEIMP1" });
    const before = await storageKeys(stub);

    // Account identity asserted by someone authenticated as another account.
    const m1 = accountMember(ulid(), "VICTIMA1");
    const r1 = await join(stub, "CODEIMP1", m1, undefined, acct(m1.memberId, "ATTACKR1"));
    expect(r1.status).toBe(403);
    expect(await r1.json()).toEqual({ error: "identity_mismatch" });
    // Same on the key lane: the lane never lets a caller assert an account
    // it didn't authenticate as.
    expect((await join(stub, "CODEIMP1", m1, undefined, acct(m1.memberId, "ATTACKR1", "key"))).status).toBe(403);

    // Anonymous identity: deviceId must be the caller's own …
    const m2 = anonMember(ulid(), "VICTIMDV");
    expect(await (await join(stub, "CODEIMP1", m2, undefined, anon(m2.memberId, "ATTACKDV"))).json()).toEqual({ error: "identity_mismatch" });
    // … and only on the Bearer lane (Ruling 5), even when the ids match.
    const keyLane = await join(stub, "CODEIMP1", m2, undefined, anon(m2.memberId, "VICTIMDV", "key"));
    expect(keyLane.status).toBe(401);
    expect(await keyLane.json()).toEqual({ error: "bearer_required" });
    // An anonymous member can't be claimed by an account caller either.
    expect((await join(stub, "CODEIMP1", m2, undefined, acct(m2.memberId, "OWNERAC1"))).status).toBe(403);
    // The caller's memberId must be the one being joined.
    expect((await join(stub, "CODEIMP1", m2, undefined, anon(ulid(), "VICTIMDV"))).status).toBe(400);

    expect(await storageKeys(stub)).toEqual(before);

    // An account member may join over the key lane as itself.
    const m3 = accountMember(ulid(), "MACUSER1");
    expect((await join(stub, "CODEIMP1", m3, undefined, acct(m3.memberId, "MACUSER1", "key"))).status).toBe(201);
  });
});

describe("GroupRoom: more join paths", () => {
  it("replacement still works when the room is at 50 members", async () => {
    const stub = stubFor("g-join-replace-full");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODEFUL2" });
    for (let i = 0; i < 49; i++) await join(stub, "CODEFUL2", accountMember(ulid(), `FILL${String(i).padStart(4, "0")}`));
    const newId = ulid();
    const r = await join(stub, "CODEFUL2", accountMember(newId, "FILL0007"));
    expect(r.status).toBe(201);
    expect(await r.json()).toMatchObject({ replaced: true });
    const v = await (await view(stub, acct(ownerMemberId, "OWNERAC1"))).json() as { members: PublicMember[] };
    expect(v.members).toHaveLength(50);
    expect(v.members.filter((m) => m.accountId === "FILL0007").map((m) => m.memberId)).toEqual([newId]);
  });

  it("anonymous same-device rejoin with a new memberId replaces the old member", async () => {
    const stub = stubFor("g-join-anon-replace");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { joinPolicy: "anonymousAllowed", inviteCode: "CODEAR01" });
    const oldId = ulid();
    await join(stub, "CODEAR01", anonMember(oldId, "ANONDEV1"));
    const newId = ulid();
    const r = await join(stub, "CODEAR01", anonMember(newId, "ANONDEV1"));
    expect(r.status).toBe(201);
    expect(await r.json()).toMatchObject({ added: true, replaced: true });
    const v = await (await view(stub, acct(ownerMemberId, "OWNERAC1"))).json() as { members: PublicMember[]; rotationDue: boolean };
    expect(v.members.map((m) => m.memberId)).toEqual([ownerMemberId, newId]);
    expect(v.rotationDue).toBe(false);
    expect((await view(stub, anon(oldId, "ANONDEV1"))).status).toBe(403);
    // A different device is a different person: plain join, no replacement.
    const other = await join(stub, "CODEAR01", anonMember(ulid(), "ANONDEV2"));
    expect(await other.json()).toMatchObject({ added: true, replaced: false });
  });

  it("a banned anonymous device (dev: hash) cannot join", async () => {
    const stub = stubFor("g-join-anon-ban");
    await initGroup(stub, "OWNERAC1", { joinPolicy: "anonymousAllowed", inviteCode: "CODEAB01" });
    const h = await sha256Hex("dev:BANNEDDV");
    await runInDurableObject(stub, async (_i: GroupRoom, state) => { await state.storage.put(`ban:${h}`, 1); });
    const r = await join(stub, "CODEAB01", anonMember(ulid(), "BANNEDDV"));
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "banned" });
    // The account-namespace hash of the same string doesn't collide.
    expect((await join(stub, "CODEAB01", anonMember(ulid(), "OKDEVICE"))).status).toBe(201);
  });

  it("dryRun on a replacement writes nothing", async () => {
    const stub = stubFor("g-join-dry-replace");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODEDR02" });
    const before = await runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list()).entries()]);
    const r = await join(stub, "CODEDR02", accountMember(ulid(), "OWNERAC1"), true);
    expect(r.status).toBe(201);
    expect(await r.json()).toMatchObject({ added: true, replaced: true });
    const after = await runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list()).entries()]);
    expect(after).toEqual(before);
    expect((await view(stub, acct(ownerMemberId, "OWNERAC1"))).status).toBe(200);
  });

  it("the owner may close and reset the invite over the key lane (Ruling 19)", async () => {
    const stub = stubFor("g-owner-key-lane");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODEKL01" });
    const reset = await post(stub, "/invite/reset", { caller: acct(ownerMemberId, "OWNERAC1", "key") });
    expect(reset.status).toBe(200);
    expect(await reset.json()).toMatchObject({ previousCode: "CODEKL01" });
    const close = await post(stub, "/close", { caller: acct(ownerMemberId, "OWNERAC1", "key") });
    expect(close.status).toBe(200);
    expect(await close.json()).toEqual({ state: "closed" });
  });
});

/**
 * A request whose JSON body trickles in: the first chunk is sent right away,
 * the rest only when `finish()` is called. While the DO waits on the body its
 * input gate is open, so another request can run in between — exactly the
 * window a read-meta-then-read-body handler would lose writes in.
 */
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

async function eventsOf(stub: DurableObjectStub): Promise<GroupEvent[]> {
  return runInDurableObject(stub, async (_i: GroupRoom, state) => [...(await state.storage.list<GroupEvent>({ prefix: "ev:" })).values()]);
}

describe("GroupRoom: concurrency", () => {
  it("join vs join with a slow body: both land, seq strictly increasing, nothing overwritten", async () => {
    const stub = stubFor("g-race-join-join");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODERC01" });
    const slowMember = accountMember(ulid(), "SLOWACC1");
    const slow = slowPost(stub, "/join", joinBody("CODERC01", slowMember));
    await new Promise((r) => setTimeout(r, 50));
    const fastMember = accountMember(ulid(), "FASTACC1");
    expect((await join(stub, "CODERC01", fastMember)).status).toBe(201);
    await slow.finish();
    expect((await slow.response).status).toBe(201);

    const v = await (await view(stub, acct(ownerMemberId, "OWNERAC1"))).json() as { members: PublicMember[]; seq: number };
    expect(v.members.map((m) => m.memberId).sort()).toEqual([ownerMemberId, slowMember.memberId, fastMember.memberId].sort());
    expect(v.seq).toBe(2);
    const evs = await eventsOf(stub);
    expect(evs.map((e) => e.seq)).toEqual([1, 2]);
    expect(evs.map((e) => e.authorMemberId)).toEqual([fastMember.memberId, slowMember.memberId]);
  });

  it("close vs join: a slow close keeps a join that landed meanwhile; a slow join sees the close", async () => {
    const stub = stubFor("g-race-close-join");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODERC02" });
    const slowClose = slowPost(stub, "/close", { caller: acct(ownerMemberId, "OWNERAC1") });
    await new Promise((r) => setTimeout(r, 50));
    const m = accountMember(ulid(), "MEMBERA1");
    expect((await join(stub, "CODERC02", m)).status).toBe(201);
    await slowClose.finish();
    expect((await slowClose.response).status).toBe(200);
    const v = await (await view(stub, acct(ownerMemberId, "OWNERAC1"))).json() as { members: PublicMember[]; state: string; seq: number };
    expect(v.state).toBe("closed");
    expect(v.members.map((x) => x.memberId)).toEqual([ownerMemberId, m.memberId]);
    expect(v.seq).toBe(1);

    const stub2 = stubFor("g-race-join-close");
    const g2 = await initGroup(stub2, "OWNERAC1", { inviteCode: "CODERC03" });
    const slowJoin = slowPost(stub2, "/join", joinBody("CODERC03", accountMember(ulid(), "MEMBERA1")));
    await new Promise((r) => setTimeout(r, 50));
    expect((await post(stub2, "/close", { caller: acct(g2.ownerMemberId, "OWNERAC1") })).status).toBe(200);
    await slowJoin.finish();
    const jr = await slowJoin.response;
    expect(jr.status).toBe(403);
    expect(await jr.json()).toEqual({ error: "group_closed" });
    const v2 = await (await view(stub2, acct(g2.ownerMemberId, "OWNERAC1"))).json() as { members: PublicMember[]; state: string };
    expect(v2.state).toBe("closed");
    expect(v2.members).toHaveLength(1);
  });

  it("60 parallel joins: exactly 50 members, 49 × 201 and 11 × 409, consistent seq", async () => {
    const stub = stubFor("g-race-60");
    const { ownerMemberId } = await initGroup(stub, "OWNERAC1", { inviteCode: "CODERC60" });
    const members = Array.from({ length: 60 }, (_, i) => accountMember(ulid(), `PAR${String(i).padStart(5, "0")}`));
    const results = await Promise.all(members.map((m) => join(stub, "CODERC60", m)));
    const statuses = results.map((r) => r.status);
    expect(statuses.filter((s) => s === 201)).toHaveLength(49);
    expect(statuses.filter((s) => s === 409)).toHaveLength(11);
    const v = await (await view(stub, acct(ownerMemberId, "OWNERAC1"))).json() as { members: PublicMember[]; seq: number };
    expect(v.members).toHaveLength(50);
    expect(v.seq).toBe(49);
    const evs = await eventsOf(stub);
    expect(evs.map((e) => e.seq)).toEqual(Array.from({ length: 49 }, (_, i) => i + 1));
    expect(new Set(evs.map((e) => e.authorMemberId)).size).toBe(49);
    expect(evs.map((e) => e.authorMemberId).sort()).toEqual(v.members.map((m) => m.memberId).filter((id) => id !== ownerMemberId).sort());
  });
});
