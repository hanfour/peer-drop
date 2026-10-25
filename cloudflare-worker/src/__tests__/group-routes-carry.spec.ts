// Task 6 review carry-overs, fixed in Task 7: rejoin churn throttling, the
// fail-closed account lookup for group auth, and keeping the D1
// `group_members` index in step with the room after leave / kick / a
// Ruling-12 takeover.
import { env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { deviceToken } from "./accountHelpers";
import {
  makeGroupAccount, makeAnonDevice, bearer, keyLane, asMember, createGroupOk, joinGroup, accountJoinBody, anonJoinBody,
  joinAsAccountOk, getGroup, leaveGroup, kickMember, listGroups, requestKey,
} from "./groupHelpers";
import { authorizeGroupCaller } from "../index";
import type { Env } from "../index";
import { handleGroupRoute, reconcileAccountIndex } from "../group";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

let devCounter = 0;
const nextDev = (tag: string) => `dev-grx-${tag}-${String(++devCounter).padStart(4, "0")}`;
const acct = (tag: string) => makeGroupAccount(nextDev(tag));

const rowCount = async (accountId: string, groupId: string) =>
  (await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM group_members WHERE account_id = ?1 AND group_id = ?2").bind(accountId, groupId).first<{ n: number }>())!.n;
const insertRow = (accountId: string, groupId: string) =>
  env.ACCOUNTS_DB.prepare("INSERT OR IGNORE INTO group_members (account_id, group_id, joined_at) VALUES (?1, ?2, 1)").bind(accountId, groupId).run();
const deleteRow = (accountId: string, groupId: string) =>
  env.ACCOUNTS_DB.prepare("DELETE FROM group_members WHERE account_id = ?1 AND group_id = ?2").bind(accountId, groupId).run();
const accountMember = async (groupId: string, accountId: string) => {
  const stub = env.GROUP_ROOM.get(env.GROUP_ROOM.idFromName(groupId));
  return stub.fetch("https://group/account-member", { method: "POST", body: JSON.stringify({ accountId }) });
};

/** An env whose D1 throws on every statement (TOKEN_SECRET etc. still real). */
function brokenD1Env(): Env {
  const broken = { prepare() { throw new Error("D1 down"); }, batch() { throw new Error("D1 down"); } };
  return { ...env, ACCOUNTS_DB: broken } as unknown as Env;
}

describe("carry-over: rejoin churn", () => {
  it("joins into one room are capped at 6 an hour per identity, replacements included", async () => {
    const owner = await acct("churn-o"), b = await acct("churn-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    // 1 fresh join + 5 Ruling-12 takeovers
    for (let i = 0; i < 6; i++) await joinAsAccountOk(b, groupId, inviteCode);
    const r = await joinGroup(bearer(b), groupId, await accountJoinBody(b, groupId, inviteCode));
    expect(r.status).toBe(429);
    expect(await r.json()).toEqual({ error: "rate_limited" });
    // leave + fresh join counts the same
    const c = await acct("churn-c");
    for (let i = 0; i < 6; i++) {
      const m = await joinAsAccountOk(c, groupId, inviteCode);
      expect((await leaveGroup(asMember(bearer(c), m), groupId)).status).toBe(204);
    }
    expect((await joinGroup(bearer(c), groupId, await accountJoinBody(c, groupId, inviteCode))).status).toBe(429);
    // an idempotent resend of the current seat is not a join
    const d = await acct("churn-d");
    const body = await accountJoinBody(d, groupId, inviteCode);
    for (let i = 0; i < 8; i++) expect((await joinGroup(bearer(d), groupId, body)).status).toBe(i === 0 ? 201 : 200);
    // other rooms are unaffected
    const other = await createGroupOk(owner);
    expect((await joinGroup(bearer(b), other.groupId, await accountJoinBody(b, other.groupId, other.inviteCode))).status).toBe(201);
  });

  it("anonymous rejoins are capped the same way", async () => {
    const owner = await acct("churn-anon-o");
    const { groupId, inviteCode } = await createGroupOk(owner, { joinPolicy: "anonymousAllowed" });
    const anon = await makeAnonDevice(nextDev("churn-anon"));
    for (let i = 0; i < 6; i++) expect((await joinGroup(bearer(anon), groupId, anonJoinBody(inviteCode))).status).toBe(201);
    expect((await joinGroup(bearer(anon), groupId, anonJoinBody(inviteCode))).status).toBe(429);
  });

  it("key-request pushes are capped per identity, so new seats don't refill the budget", async () => {
    const owner = await acct("kr-o"), b = await acct("kr-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    const m1 = await joinAsAccountOk(b, groupId, inviteCode); // join-time request: 1
    for (let i = 0; i < 6; i++) expect((await requestKey(asMember(bearer(b), m1), groupId)).status).toBe(204); // 7
    expect((await requestKey(asMember(bearer(b), m1), groupId)).status).toBe(429); // the seat's 6
    const m2 = await joinAsAccountOk(b, groupId, inviteCode); // takeover, join-time request: 8
    for (let i = 0; i < 4; i++) expect((await requestKey(asMember(bearer(b), m2), groupId)).status).toBe(204); // 12
    const r = await requestKey(asMember(bearer(b), m2), groupId);
    expect(r.status).toBe(429);
    expect(await r.json()).toEqual({ error: "rate_limited" });
  });
});

describe("carry-over: group auth fails closed", () => {
  it("a default-scope token with D1 down is 503, never an account-less caller", async () => {
    const a = await acct("fc");
    const broken = brokenD1Env();
    const req = (h: Record<string, string>) => new Request("https://example.com/v3/groups/X", { headers: h });
    expect(await authorizeGroupCaller(req(bearer({ token: await deviceToken(a.deviceId) })), broken)).toBe("unavailable");
    expect(await authorizeGroupCaller(req(keyLane(a)), broken)).toBe("unavailable");
    // an account-scoped token needs no lookup
    expect(await authorizeGroupCaller(req(bearer(a)), broken)).toEqual({ deviceId: a.deviceId, accountId: a.accountId, lane: "bearer" });
    // with D1 up the same default-scope token resolves the account
    expect(await authorizeGroupCaller(req(bearer({ token: await deviceToken(a.deviceId) })), env as unknown as Env))
      .toEqual({ deviceId: a.deviceId, accountId: a.accountId, lane: "bearer" });
    // the route answers 503 unavailable
    const r0 = req(bearer({ token: await deviceToken(a.deviceId) }));
    const resp = await handleGroupRoute(r0, new URL(r0.url), "/v3/groups", broken, {
      push: { send: (async () => ({ ok: true, status: 200 })) as never, topicFor: () => "t" },
      authorize: (r) => authorizeGroupCaller(r, broken),
    });
    expect(resp.status).toBe(503);
    expect(await resp.json()).toEqual({ error: "unavailable" });
  });
});

describe("carry-over: D1 index follows the room", () => {
  it("the room answers whether an account still holds a seat", async () => {
    const owner = await acct("am-o"), b = await acct("am-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    expect(await (await accountMember(groupId, b.accountId)).json()).toEqual({ member: false });
    const m = await joinAsAccountOk(b, groupId, inviteCode);
    expect(await (await accountMember(groupId, b.accountId)).json()).toEqual({ member: true });
    await leaveGroup(asMember(bearer(b), m), groupId);
    expect(await (await accountMember(groupId, b.accountId)).json()).toEqual({ member: false });
    expect((await accountMember(groupId, "")).status).toBe(400);
  });

  it("a stale row left by a failed kick DELETE is dropped when the kicked account hears not_member", async () => {
    const owner = await acct("stale-o"), b = await acct("stale-b");
    const { groupId, inviteCode, memberId: ownerMember } = await createGroupOk(owner);
    const bMember = await joinAsAccountOk(b, groupId, inviteCode);
    expect((await kickMember(asMember(bearer(owner), ownerMember), groupId, bMember)).status).toBe(204);
    await insertRow(b.accountId, groupId); // the DELETE "failed"
    // the owner's retry can no longer name the account…
    expect((await kickMember(asMember(bearer(owner), ownerMember), groupId, bMember)).status).toBe(204);
    expect(await rowCount(b.accountId, groupId)).toBe(1);
    // …but the kicked account's next call repairs the index
    const r = await getGroup(asMember(bearer(b), bMember), groupId);
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "not_member" });
    expect(await rowCount(b.accountId, groupId)).toBe(0);
    expect(await (await listGroups(bearer(b))).json()).toEqual([]);
  });

  it("a Ruling-12 takeover's old device hearing not_member keeps the row", async () => {
    const owner = await acct("take-o"), b = await acct("take-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    const oldMember = await joinAsAccountOk(b, groupId, inviteCode);
    await joinAsAccountOk(b, groupId, inviteCode);
    expect((await getGroup(asMember(bearer(b), oldMember), groupId)).status).toBe(403);
    expect(await rowCount(b.accountId, groupId)).toBe(1);
    // and an old-seat leave is a no-op for the index too
    expect((await leaveGroup(asMember(bearer(b), oldMember), groupId)).status).toBe(204);
    expect(await rowCount(b.accountId, groupId)).toBe(1);
  });

  it("a takeover's old device hearing not_member asks the room first: no DELETE, joined_at kept", async () => {
    const owner = await acct("take2-o"), b = await acct("take2-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    const oldMember = await joinAsAccountOk(b, groupId, inviteCode);
    await joinAsAccountOk(b, groupId, inviteCode);
    await env.ACCOUNTS_DB.prepare("UPDATE group_members SET joined_at = 4242 WHERE account_id = ?1 AND group_id = ?2").bind(b.accountId, groupId).run();
    // Record every statement the route issues against D1.
    const sql: string[] = [];
    const real = env.ACCOUNTS_DB;
    const spyDb = new Proxy(real, {
      get(t, k) {
        if (k === "prepare") return (q: string) => { sql.push(q); return t.prepare(q); };
        const v = Reflect.get(t, k);
        return typeof v === "function" ? v.bind(t) : v;
      },
    });
    const spyEnv = { ...env, ACCOUNTS_DB: spyDb } as unknown as Env;
    const req = new Request(`https://example.com/v3/groups/${groupId}`, { headers: asMember(bearer(b), oldMember) });
    const resp = await handleGroupRoute(req, new URL(req.url), `/v3/groups/${groupId}`, spyEnv, {
      push: { send: (async () => ({ ok: true, status: 200 })) as never, topicFor: () => "t" },
      authorize: (r) => authorizeGroupCaller(r, spyEnv),
    });
    expect(resp.status).toBe(403);
    expect(await resp.json()).toEqual({ error: "not_member" });
    expect(sql.filter((q) => /^\s*(DELETE|INSERT)/i.test(q))).toEqual([]);
    const row = await env.ACCOUNTS_DB.prepare("SELECT joined_at FROM group_members WHERE account_id = ?1 AND group_id = ?2").bind(b.accountId, groupId).first<{ joined_at: number }>();
    expect(row?.joined_at).toBe(4242);
    expect(await (await listGroups(bearer(b))).json()).toEqual([{ groupId, joinedAt: 4242 }]);
  });

  it("reconcile puts a still-seated account's row back with its original joined_at", async () => {
    const owner = await acct("rcj-o"), b = await acct("rcj-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    await joinAsAccountOk(b, groupId, inviteCode);
    await env.ACCOUNTS_DB.prepare("UPDATE group_members SET joined_at = 777 WHERE account_id = ?1 AND group_id = ?2").bind(b.accountId, groupId).run();
    await reconcileAccountIndex(env as unknown as Env, groupId, b.accountId);
    const row = await env.ACCOUNTS_DB.prepare("SELECT joined_at FROM group_members WHERE account_id = ?1 AND group_id = ?2").bind(b.accountId, groupId).first<{ joined_at: number }>();
    expect(row?.joined_at).toBe(777);
  });

  it("a non-member leave drops a stale row", async () => {
    const owner = await acct("lv-o"), b = await acct("lv-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    const m = await joinAsAccountOk(b, groupId, inviteCode);
    expect((await leaveGroup(asMember(bearer(b), m), groupId)).status).toBe(204);
    await insertRow(b.accountId, groupId);
    expect((await leaveGroup(asMember(bearer(b), m), groupId)).status).toBe(204);
    expect(await rowCount(b.accountId, groupId)).toBe(0);
  });

  it("reconcile deletes first and puts the row back when the room still seats the account (join-after-leave race)", async () => {
    const owner = await acct("rc-o"), b = await acct("rc-b");
    const { groupId, inviteCode } = await createGroupOk(owner);
    await joinAsAccountOk(b, groupId, inviteCode);
    // a leave's late DELETE ran after a rejoin's INSERT: the row is gone though b is seated
    await deleteRow(b.accountId, groupId);
    await reconcileAccountIndex(env as unknown as Env, groupId, b.accountId);
    expect(await rowCount(b.accountId, groupId)).toBe(1);
    // not seated → the row goes
    const c = await acct("rc-c");
    await insertRow(c.accountId, groupId);
    await reconcileAccountIndex(env as unknown as Env, groupId, c.accountId);
    expect(await rowCount(c.accountId, groupId)).toBe(0);
  });
});
