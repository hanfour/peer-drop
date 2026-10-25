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

const join = (stub: DurableObjectStub, inviteCode: string, member: unknown, dryRun?: boolean) =>
  post(stub, "/join", { inviteCode, member, ...(dryRun === undefined ? {} : { dryRun }) });
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
      ["/join", { inviteCode: "X", member: accountMember(ulid(), "SOMEACC1") }],
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
