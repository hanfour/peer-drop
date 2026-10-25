// Drives the /v3/groups* membership routes end-to-end (auth lanes, signature
// checks, D1 indexing, quotas, wiped-id tombstones). The room state machine
// itself is pinned down against the GroupRoom DO directly in group-room*.spec.ts.
import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { deviceToken } from "./accountHelpers";
import {
  makeGroupAccount, makeAnonDevice, newGroupId, newMemberId, fakeMeta,
  signMemberKey, signWrap, bearer, keyLane, asMember, createBody, createGroup, createGroupOk,
  joinGroup, accountJoinBody, anonJoinBody, joinAsAccountOk, listGroups, getGroup,
  leaveGroup, kickMember, closeGroup, resetGroupInvite,
} from "./groupHelpers";
import { rateLimitClass, authorizeGroupCaller } from "../index";
import type { Env } from "../index";
import { DO_ERROR_STATUS, fromDo, handleGroupRoute } from "../group";
import type { GroupRoom } from "../groupRoom";
import type { PushDeps } from "../notes";
import type { sendAPNs } from "../apns";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

let devCounter = 0;
const nextDev = (tag: string) => `dev-grp-${tag}-${String(++devCounter).padStart(4, "0")}`;
const acct = (tag: string) => makeGroupAccount(nextDev(tag));
const anonDev = (tag: string) => makeAnonDevice(nextDev(tag));

const memberRows = async (groupId: string) =>
  (await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM group_members WHERE group_id = ?1").bind(groupId).first<{ n: number }>())!.n;
const inviteRows = async (groupId: string) =>
  (await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM group_invites WHERE group_id = ?1").bind(groupId).first<{ n: number }>())!.n;
const doKeys = async (groupId: string) =>
  runInDurableObject(env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(groupId)), async (_i: GroupRoom, state) => (await state.storage.list()).size);

async function anonJoinOk(d: { token: string }, groupId: string, inviteCode: string): Promise<string> {
  const body = anonJoinBody(inviteCode);
  const r = await joinGroup(bearer(d), groupId, body);
  if (r.status !== 201) throw new Error(`anonJoinOk: ${r.status} ${await r.text()}`);
  return body.memberId;
}

describe("/v3/groups routes", () => {
  it("routes on an unknown groupId are 404 and never wake a DO", async () => {
    const a = await acct("unknown");
    const groupId = newGroupId();
    const h = asMember(bearer(a), newMemberId());
    const results = await Promise.all([
      getGroup(h, groupId),
      joinGroup(bearer(a), groupId, await accountJoinBody(a, groupId, "ABCDEFGH")),
      leaveGroup(h, groupId),
      kickMember(h, groupId, newMemberId()),
      closeGroup(h, groupId),
      resetGroupInvite(h, groupId),
    ]);
    for (const r of results) {
      expect(r.status).toBe(404);
      expect(await r.json()).toEqual({ error: "not_found" });
    }
    expect((await SELF.fetch(`https://example.com/v3/groups/${groupId}/nope`, { headers: h })).status).toBe(404);
    expect(await doKeys(groupId)).toBe(0);
  });

  it("create validates ids, signatures and size, then indexes owner in D1", async () => {
    const a = await acct("create"), other = await acct("create-other");
    // invalid ids
    expect((await createGroup(bearer(a), { ...(await createBody(a)), groupId: "not-a-ulid" })).status).toBe(400);
    const badMember = await createGroup(bearer(a), { ...(await createBody(a)), memberId: "x" });
    expect(await badMember.json()).toEqual({ error: "invalid_id" });
    // missing fields
    expect(await (await createGroup(bearer(a), { groupId: newGroupId() })).json()).toEqual({ error: "missing_fields" });
    // pubKeySig over a different memberId
    const b1 = await createBody(a);
    b1.pubKeySig = await signMemberKey(a, b1.groupId, newMemberId(), b1.pubKey);
    const r1 = await createGroup(bearer(a), b1);
    expect(r1.status).toBe(400);
    expect(await r1.json()).toEqual({ error: "bad_sig" });
    // ownerWrap signed for the wrong epoch
    const b2 = await createBody(a);
    b2.ownerWrap.sig = await signWrap(a, b2.groupId, 2, b2.memberId, b2.memberId, b2.ownerWrap.wrapped);
    expect(await (await createGroup(bearer(a), b2)).json()).toEqual({ error: "bad_sig" });
    // a signature by ANOTHER account over the right bytes
    const b3 = await createBody(a);
    b3.pubKeySig = await signMemberKey({ ...other, accountId: a.accountId }, b3.groupId, b3.memberId, b3.pubKey);
    expect(await (await createGroup(bearer(a), b3)).json()).toEqual({ error: "bad_sig" });
    // body over 600 KB, and a metaCipher over 400 KB inside a smaller body
    expect((await createGroup(bearer(a), await createBody(a, { metaCipher: fakeMeta(460 * 1024) }))).status).toBe(413);
    const big = await createGroup(bearer(a), await createBody(a, { metaCipher: fakeMeta(400 * 1024 + 1) }));
    expect(big.status).toBe(413);
    expect(await big.json()).toEqual({ error: "too_large" });
    // nothing was indexed by any of the failures
    expect((await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM group_members WHERE account_id = ?1").bind(a.accountId).first<{ n: number }>())!.n).toBe(0);

    // exactly 400 KB passes
    const body = await createBody(a, { metaCipher: fakeMeta(400 * 1024) });
    const ok = await createGroup(bearer(a), body);
    expect(ok.status).toBe(201);
    const { groupId, inviteCode } = await ok.json() as { groupId: string; inviteCode: string };
    expect(groupId).toBe(body.groupId);
    expect(inviteCode).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/);
    expect(await memberRows(groupId)).toBe(1);
    expect(await inviteRows(groupId)).toBe(1);
    // idempotent resend by the same owner → 200 with the same code
    const again = await createGroup(bearer(a), body);
    expect(again.status).toBe(200);
    expect((await again.json() as { inviteCode: string }).inviteCode).toBe(inviteCode);
    // another account can't take the id
    const theirs = await createGroup(bearer(other), await createBody(other, { groupId }));
    expect(theirs.status).toBe(409);
    expect(await theirs.json()).toEqual({ error: "group_exists" });
    // listed for the owner
    const list = await (await listGroups(bearer(a))).json() as { groupId: string }[];
    expect(list.map((g) => g.groupId)).toEqual([groupId]);
  });

  it("create is capped at 20 memberships and 20 creates per day", async () => {
    const a = await acct("cap");
    const made: { groupId: string; memberId: string }[] = [];
    for (let i = 0; i < 20; i++) made.push(await createGroupOk(a));
    const r21 = await createGroup(bearer(a), await createBody(a));
    expect(r21.status).toBe(409);
    expect(await r21.json()).toEqual({ error: "group_limit" });
    expect((await leaveGroup(asMember(bearer(a), made[0].memberId), made[0].groupId)).status).toBe(204);
    const rLimited = await createGroup(bearer(a), await createBody(a));
    expect(rLimited.status).toBe(429);
    expect(await rLimited.json()).toEqual({ error: "rate_limited" });
  });

  it("account join verifies pubKeySig and indexes in D1; anon join writes nothing to D1", async () => {
    const owner = await acct("join-owner"), b = await acct("join-b");
    const { groupId, inviteCode, memberId: ownerMemberId } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });

    // forged signature (signed for another group)
    const forged = await accountJoinBody(b, newGroupId(), inviteCode);
    const rf = await joinGroup(bearer(b), groupId, forged);
    expect(rf.status).toBe(400);
    expect(await rf.json()).toEqual({ error: "bad_sig" });
    // account join without a signature
    expect(await (await joinGroup(bearer(b), groupId, { ...anonJoinBody(inviteCode), as: "account" })).json()).toEqual({ error: "missing_fields" });
    expect(await memberRows(groupId)).toBe(1);

    const anon = await anonDev("join-anon");
    const anonBody = anonJoinBody(inviteCode);
    const ra = await joinGroup(bearer(anon), groupId, anonBody);
    expect(ra.status).toBe(201);
    expect(await ra.json()).toEqual({ groupId, memberId: anonBody.memberId, epoch: 1, state: "open", ownerMemberId });
    expect(await memberRows(groupId)).toBe(1);
    // an anonymous join may not carry a pubKeySig
    expect((await joinGroup(bearer(await anonDev("join-anon2")), groupId, { ...anonJoinBody(inviteCode), pubKeySig: btoa("x".repeat(64)) })).status).toBe(400);

    // a valid account join, by link and (another account) by code, mangled
    const body = await accountJoinBody(b, groupId, inviteCode);
    const rb = await joinGroup(bearer(b), groupId, body);
    expect(rb.status).toBe(201);
    expect(await rb.json()).toEqual({ groupId, memberId: body.memberId, epoch: 1, state: "open", ownerMemberId });
    expect(await memberRows(groupId)).toBe(2);
    // idempotent resend
    expect((await joinGroup(bearer(b), groupId, body)).status).toBe(200);
    const c = await acct("join-c");
    const cBody = await accountJoinBody(c, groupId, `${inviteCode.slice(0, 4)}-${inviteCode.slice(4)}`.toLowerCase());
    const rc = await joinGroup(bearer(c), null, cBody);
    expect(rc.status).toBe(201);
    expect(await memberRows(groupId)).toBe(3);
    // the key lane works for account members (Ruling 19)
    const d = await acct("join-d");
    expect((await joinGroup(keyLane(d), groupId, await accountJoinBody(d, groupId, inviteCode))).status).toBe(201);
    expect(await memberRows(groupId)).toBe(4);
  });

  it("anonymous actions refuse the key lane", async () => {
    const owner = await acct("lane-owner");
    const { groupId, inviteCode } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
    const keyDev = { deviceId: nextDev("lane-key") };
    const r = await joinGroup(keyLane(keyDev), groupId, anonJoinBody(inviteCode));
    expect(r.status).toBe(401);
    expect(await r.json()).toEqual({ error: "bearer_required" });
    // code-only route too
    expect((await joinGroup(keyLane(keyDev), null, anonJoinBody(inviteCode))).status).toBe(401);

    const anon = await anonDev("lane-anon");
    const memberId = await anonJoinOk(anon, groupId, inviteCode);
    expect((await getGroup(asMember(bearer(anon), memberId), groupId)).status).toBe(200);
    const impersonate = asMember(keyLane(anon), memberId);
    const v = await getGroup(impersonate, groupId);
    expect(v.status).toBe(401);
    expect(await v.json()).toEqual({ error: "bearer_required" });
    expect((await leaveGroup(impersonate, groupId)).status).toBe(401);
    // still a member
    expect((await getGroup(asMember(bearer(anon), memberId), groupId)).status).toBe(200);
  });

  it("anonymous join into accountOnly is 403 account_required", async () => {
    const owner = await acct("acctonly");
    const { groupId, inviteCode } = await createGroupOk(owner);
    const r = await joinGroup(bearer(await anonDev("acctonly-anon")), groupId, anonJoinBody(inviteCode));
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "account_required" });
  });

  it("a device-only token cannot create or join as account (403 account_required)", async () => {
    const owner = await acct("devonly-owner");
    const { groupId, inviteCode } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
    const anon = await anonDev("devonly");
    const rc = await createGroup(bearer(anon), await createBody({ ...owner }));
    expect(rc.status).toBe(403);
    expect(await rc.json()).toEqual({ error: "account_required" });
    const rj = await joinGroup(bearer(anon), groupId, { ...(await accountJoinBody(owner, groupId, inviteCode)) });
    expect(rj.status).toBe(403);
    expect(await rj.json()).toEqual({ error: "account_required" });
    expect((await listGroups(bearer(anon))).status).toBe(403);
    expect((await SELF.fetch("https://example.com/v3/groups")).status).toBe(401);
  });

  it("wrong codes are rate limited at 10 per hour per caller", async () => {
    const owner = await acct("fail-owner");
    const { groupId } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
    const a = await acct("fail-a");
    for (let i = 0; i < 10; i++) {
      const r = await joinGroup(bearer(a), groupId, await accountJoinBody(a, groupId, i % 2 ? "ZZZZZZZZ" : "bad"));
      expect(r.status).toBe(403);
      expect(await r.json()).toEqual({ error: "bad_code" });
    }
    expect((await joinGroup(bearer(a), groupId, await accountJoinBody(a, groupId, "ZZZZZZZZ"))).status).toBe(429);
    // anonymous: counted by device hash, on the code-only route too
    const anon = await anonDev("fail-anon");
    for (let i = 0; i < 10; i++) expect((await joinGroup(bearer(anon), null, anonJoinBody("YYYYYYYY"))).status).toBe(403);
    expect((await joinGroup(bearer(anon), groupId, anonJoinBody("YYYYYYYY"))).status).toBe(429);
    // a different device is unaffected
    expect((await joinGroup(bearer(await anonDev("fail-anon2")), groupId, anonJoinBody("YYYYYYYY"))).status).toBe(403);
  });

  it("account cap is checked last so a full group still answers group_full_members", async () => {
    const owner = await acct("full-owner");
    const { groupId, inviteCode } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
    const capped = await acct("full-capped");
    for (let i = 0; i < 20; i++) await createGroupOk(capped);
    // not full yet: the cap answers
    const r1 = await joinGroup(bearer(capped), groupId, await accountJoinBody(capped, groupId, inviteCode));
    expect(r1.status).toBe(409);
    expect(await r1.json()).toEqual({ error: "group_limit" });
    for (let i = 0; i < 49; i++) await anonJoinOk(await anonDev(`full-${i}`), groupId, inviteCode);
    const r2 = await joinGroup(bearer(capped), groupId, await accountJoinBody(capped, groupId, inviteCode));
    expect(r2.status).toBe(409);
    expect(await r2.json()).toEqual({ error: "group_full_members" });
    expect(await memberRows(groupId)).toBe(1);
  });

  it("group view never carries metaCipher or deviceId", async () => {
    const owner = await acct("view-owner");
    const body = await createBody(owner, { joinPolicy: "anonymousAllowed", metaCipher: btoa("METACIPHER-SECRET-BYTES!") });
    expect((await createGroup(bearer(owner), body)).status).toBe(201);
    const { groupId } = body;
    const inviteCode = (await (await getGroup(asMember(bearer(owner), body.memberId), groupId)).json() as { inviteCode: string }).inviteCode;
    const anon = await anonDev("view-anon");
    const anonMember = await anonJoinOk(anon, groupId, inviteCode);
    for (const [h, isOwner] of [[asMember(bearer(owner), body.memberId), true], [asMember(bearer(anon), anonMember), false]] as const) {
      const r = await getGroup(h, groupId);
      expect(r.status).toBe(200);
      const text = await r.text();
      expect(text).not.toContain(body.metaCipher);
      expect(text).not.toContain("metaCipher");
      expect(text).not.toContain(owner.deviceId);
      expect(text).not.toContain(anon.deviceId);
      const v = JSON.parse(text) as { members: unknown[]; inviteCode?: string };
      expect(v.members).toHaveLength(2);
      expect(v.inviteCode !== undefined).toBe(isOwner);
    }
    // a non-member's claimed memberId is refused; a missing header is 400
    const stranger = await acct("view-stranger");
    expect((await getGroup(asMember(bearer(stranger), body.memberId), groupId)).status).toBe(403);
    const noHeader = await getGroup(bearer(owner), groupId);
    expect(noHeader.status).toBe(400);
    expect(await noHeader.json()).toEqual({ error: "missing_fields" });
  });

  it("leave by the last member deletes the invite row and the id becomes 404", async () => {
    const owner = await acct("leave-owner"), b = await acct("leave-b");
    const { groupId, inviteCode, memberId: ownerMember } = await createGroupOk(owner);
    const bMember = await joinAsAccountOk(b, groupId, inviteCode);
    expect(await memberRows(groupId)).toBe(2);
    // owner leaves: b inherits, owner's D1 row goes
    expect((await leaveGroup(asMember(bearer(owner), ownerMember), groupId)).status).toBe(204);
    expect(await memberRows(groupId)).toBe(1);
    const v = await (await getGroup(asMember(bearer(b), bMember), groupId)).json() as { ownerMemberId: string };
    expect(v.ownerMemberId).toBe(bMember);
    // leaving twice is idempotent
    expect((await leaveGroup(asMember(bearer(owner), ownerMember), groupId)).status).toBe(204);
    // last one out
    expect((await leaveGroup(asMember(bearer(b), bMember), groupId)).status).toBe(204);
    expect(await memberRows(groupId)).toBe(0);
    expect(await inviteRows(groupId)).toBe(0);
    expect(await doKeys(groupId)).toBe(0);
    expect((await getGroup(asMember(bearer(b), bMember), groupId)).status).toBe(404);
    expect((await joinGroup(bearer(b), groupId, await accountJoinBody(b, groupId, inviteCode))).status).toBe(404);
    expect((await joinGroup(bearer(b), null, await accountJoinBody(b, groupId, inviteCode))).status).toBe(403);
    // the wiped id can never be created again (Ruling 11)
    const re = await createGroup(bearer(owner), await createBody(owner, { groupId }));
    expect(re.status).toBe(409);
    expect(await re.json()).toEqual({ error: "group_exists" });
    expect(await doKeys(groupId)).toBe(0);
  });

  it("a wipe whose D1 cleanup was lost is finished on the next create or leave, never re-created", async () => {
    const owner = await acct("repair");
    const g1 = await createGroupOk(owner);
    const g2 = await createGroupOk(owner);
    // Simulate: the DO wiped itself but the route never got to tombstone / clean D1.
    for (const g of [g1, g2]) {
      await runInDurableObject(env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(g.groupId)), async (_i: GroupRoom, state) => { await state.storage.deleteAll(); });
    }
    const re = await createGroup(bearer(owner), await createBody(owner, { groupId: g1.groupId }));
    expect(re.status).toBe(409);
    expect(await doKeys(g1.groupId)).toBe(0);
    expect(await memberRows(g1.groupId)).toBe(0);
    expect(await inviteRows(g1.groupId)).toBe(0);
    expect((await leaveGroup(asMember(bearer(owner), g2.memberId), g2.groupId)).status).toBe(204);
    expect(await memberRows(g2.groupId)).toBe(0);
    expect(await inviteRows(g2.groupId)).toBe(0);
    expect((await createGroup(bearer(owner), await createBody(owner, { groupId: g2.groupId }))).status).toBe(409);
  });

  it("kick removes the kicked account's D1 row and bans rejoin", async () => {
    const owner = await acct("kick-owner"), b = await acct("kick-b");
    const { groupId, inviteCode, memberId: ownerMember } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
    const bMember = await joinAsAccountOk(b, groupId, inviteCode);
    // only the owner, never itself
    expect(await (await kickMember(asMember(bearer(b), bMember), groupId, ownerMember)).json()).toEqual({ error: "not_owner" });
    const self = await kickMember(asMember(bearer(owner), ownerMember), groupId, ownerMember);
    expect(self.status).toBe(400);
    expect(await self.json()).toEqual({ error: "kick_self" });
    expect((await kickMember(asMember(bearer(owner), ownerMember), groupId, "bad")).status).toBe(400);

    expect((await kickMember(asMember(bearer(owner), ownerMember), groupId, bMember)).status).toBe(204);
    expect(await memberRows(groupId)).toBe(1);
    expect(((await (await listGroups(bearer(b))).json()) as unknown[]).length).toBe(0);
    // rejoin as the account → banned
    const r1 = await joinGroup(bearer(b), groupId, await accountJoinBody(b, groupId, inviteCode));
    expect(r1.status).toBe(403);
    expect(await r1.json()).toEqual({ error: "banned" });
    // the same Bearer device, anonymously → still banned (caller carries the accountId)
    const r2 = await joinGroup(bearer(b), groupId, anonJoinBody(inviteCode));
    expect(r2.status).toBe(403);
    expect(await r2.json()).toEqual({ error: "banned" });
    // …also with an older, not-yet-account-scoped token for that device
    const r3 = await joinGroup(bearer({ token: await deviceToken(b.deviceId) }), groupId, anonJoinBody(inviteCode));
    expect(r3.status).toBe(403);
    expect(await r3.json()).toEqual({ error: "banned" });
  });

  it("close and invite/reset are owner-only and keep D1 in step", async () => {
    const owner = await acct("close-owner"), b = await acct("close-b");
    const { groupId, inviteCode, memberId: ownerMember } = await createGroupOk(owner);
    const bMember = await joinAsAccountOk(b, groupId, inviteCode);
    expect(await (await resetGroupInvite(asMember(bearer(b), bMember), groupId)).json()).toEqual({ error: "not_owner" });
    const rr = await resetGroupInvite(asMember(bearer(owner), ownerMember), groupId);
    expect(rr.status).toBe(200);
    const { inviteCode: fresh } = await rr.json() as { inviteCode: string };
    expect(fresh).not.toBe(inviteCode);
    const rows = (await env.ACCOUNTS_DB.prepare("SELECT invite_code FROM group_invites WHERE group_id = ?1").bind(groupId).all<{ invite_code: string }>()).results;
    expect(rows.map((r) => r.invite_code)).toEqual([fresh]);
    const c = await acct("close-c");
    expect((await joinGroup(bearer(c), null, await accountJoinBody(c, groupId, inviteCode))).status).toBe(403);
    expect((await joinGroup(bearer(c), groupId, await accountJoinBody(c, groupId, inviteCode))).status).toBe(403);

    expect((await closeGroup(asMember(bearer(b), bMember), groupId)).status).toBe(403);
    expect((await closeGroup(asMember(bearer(owner), ownerMember), groupId)).status).toBe(204);
    const rc = await joinGroup(bearer(c), groupId, await accountJoinBody(c, groupId, fresh));
    expect(rc.status).toBe(403);
    expect(await rc.json()).toEqual({ error: "group_closed" });
  });

  it("a new member triggers a silent key request to the keyed account members", async () => {
    const owner = await acct("push-owner"), b = await acct("push-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    await env.V2_STORE.put(`device:${owner.deviceId}`, JSON.stringify({ pushToken: "tok-owner", platform: "ios" }));
    await env.V2_STORE.put(`device:${b.deviceId}`, JSON.stringify({ pushToken: "tok-b", platform: "ios" }));
    const calls: { token: string; payload: Record<string, unknown> }[] = [];
    const send = (async (token: string, payload: Record<string, unknown>) => { calls.push({ token, payload }); return { ok: true, status: 200 }; }) as unknown as typeof sendAPNs;
    const push: PushDeps = { send, topicFor: () => "topic" };
    const fEnv = { ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" } as unknown as Env;
    const call = async () => {
      const body = await accountJoinBody(b, groupId, inviteCode);
      const req = new Request(`https://example.com/v3/groups/${groupId}/join`, { method: "POST", headers: bearer(b), body: JSON.stringify(body) });
      return handleGroupRoute(req, new URL(req.url), new URL(req.url).pathname, fEnv, { push, authorize: (r) => authorizeGroupCaller(r, fEnv) });
    };
    const first = await call();
    expect(first.status).toBe(201);
    expect(calls).toHaveLength(1);
    expect(calls[0].token).toBe("tok-owner");
    expect(calls[0].payload).toEqual({ contentAvailable: true, customData: { type: "groupKeyRequest", groupId } });
  });

  it("every DO error code maps to a stable non-500 status", async () => {
    const expected: Record<string, number> = {
      identity_mismatch: 403, bearer_required: 401, event_id_taken: 409, account_required: 403, not_keyed: 403,
      stale_epoch: 409, unknown_member: 400, bad_wrap: 400, members_changed: 409, kick_self: 400, not_owner: 403,
      group_closed: 403, too_large: 413, bad_event_id: 400, bad_request: 400, busy: 503, banned: 403,
      awaiting_key: 403, bad_code: 403, bad_payload: 400, denied: 403, group_exists: 409, group_full_members: 409,
      member_id_taken: 409, not_found: 404, not_member: 403, rate_limited: 429,
    };
    expect(DO_ERROR_STATUS).toEqual(expected);
    for (const [code, status] of Object.entries(expected)) {
      const r = await fromDo(new Response(JSON.stringify({ error: code, epoch: 7, memberIds: ["A"], secret: "x" }), { status: 418 }));
      expect(r.status).toBe(status);
      const body = await r.json() as Record<string, unknown>;
      expect(body.error).toBe(code);
      expect(body.secret).toBeUndefined();
      expect("epoch" in body).toBe(code === "stale_epoch");
      expect("memberIds" in body).toBe(code === "members_changed");
    }
    const unknown = await fromDo(new Response("oops", { status: 500 }));
    expect(unknown.status).toBe(502);
  });

  it("groups have their own rate-limit class", () => {
    expect(rateLimitClass("/v3/groups/X/events", "POST")).toBe("groups");
    expect(rateLimitClass("/v3/groups", "POST")).toBe("groups");
    expect(rateLimitClass("/v3/diaries", "POST")).toBe("v3");
    expect(rateLimitClass("/v3/groupsX", "GET")).toBe("v3");
  });

  it("an existing anonymous member can leave over Bearer and writes no D1", async () => {
    const owner = await acct("anonleave-owner");
    const { groupId, inviteCode } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
    const anon = await anonDev("anonleave");
    const m = await anonJoinOk(anon, groupId, inviteCode);
    expect((await leaveGroup(asMember(bearer(anon), m), groupId)).status).toBe(204);
    expect(await memberRows(groupId)).toBe(1);
    expect((await getGroup(asMember(bearer(anon), m), groupId)).status).toBe(403);
  });
});
