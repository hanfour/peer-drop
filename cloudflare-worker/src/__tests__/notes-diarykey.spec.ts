// POST /v3/notes/:id kind="diaryKey" — the key-relay envelope from spec
// §3.3 step 2/3. HTTP-level tests drive the real route via SELF.fetch (auth
// pipeline included); the push-shape test calls handleNotesRoute directly
// with a fake `deps.push.send` (same pattern as notes-send.spec.ts's
// fanOutNotePush test) since APNS_KEY_P8 is unset in the shared test env
// and a real push would otherwise be a silent no-op we can't observe.
import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { makeAccount, bearer, fakeEnvelope, sendNote, getChallenge, solvePoW } from "./notesHelpers";
import { createDiaryOk, joinByLink } from "./diaryHelpers";
import { senderHash, handleNotesRoute } from "../notes";
import type { Env } from "../index";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

/** Full inbox item shape (id/kind/envelope/createdAt/readAt) — inboxOf() in notesHelpers only types id/envelope/readAt, so read the DO directly here. */
async function inboxItems(accountId: string): Promise<{ id: string; kind: string; envelope: string }[]> {
  const stub = env.ACCOUNT_INBOX.get(env.ACCOUNT_INBOX.idFromName(accountId));
  const { items } = await (await stub.fetch("https://inbox/items")).json() as { items: { id: string; kind: string; envelope: string }[] };
  return items;
}

describe("POST /v3/notes/:id kind=diaryKey", () => {
  it("403 not_member when the sender is not a current diary member (nothing stored)", async () => {
    const owner = await makeAccount("dev-dk-o1"), member = await makeAccount("dev-dk-m1"), outsider = await makeAccount("dev-dk-x1");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(member), diaryId, inviteCode);
    const r = await sendNote(bearer(outsider), member.accountId, fakeEnvelope(), { kind: "diaryKey", diaryId });
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "not_member" });
    expect(await inboxItems(member.accountId)).toEqual([]);
  });

  it("403 not_member when the recipient is not a current diary member", async () => {
    const owner = await makeAccount("dev-dk-o2"), outsider = await makeAccount("dev-dk-x2");
    const { diaryId } = await createDiaryOk(owner);
    const r = await sendNote(bearer(owner), outsider.accountId, fakeEnvelope(), { kind: "diaryKey", diaryId });
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "not_member" });
  });

  it("403 not_member for a diaryId nobody created (no DO ever created)", async () => {
    const owner = await makeAccount("dev-dk-o5"), member = await makeAccount("dev-dk-m5");
    const r = await sendNote(bearer(owner), member.accountId, fakeEnvelope(), { kind: "diaryKey", diaryId: "01ZZZZZZZZZZZZZZZZZZZZZZZZ" });
    expect(r.status).toBe(403);
    expect(await r.json()).toEqual({ error: "not_member" });
  });

  it("400 missing_fields for an absent or malformed diaryId", async () => {
    const owner = await makeAccount("dev-dk-o3"), member = await makeAccount("dev-dk-m3");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(member), diaryId, inviteCode);
    const noId = await sendNote(bearer(owner), member.accountId, fakeEnvelope(), { kind: "diaryKey" });
    expect(noId.status).toBe(400);
    expect(await noId.json()).toEqual({ error: "missing_fields" });
    const badId = await sendNote(bearer(owner), member.accountId, fakeEnvelope(), { kind: "diaryKey", diaryId: "not-26-chars" });
    expect(badId.status).toBe(400);
  });

  it("400 missing_fields for a kind outside note/diaryKey", async () => {
    const owner = await makeAccount("dev-dk-o6"), b = await makeAccount("dev-dk-b6");
    const r = await sendNote(bearer(owner), b.accountId, fakeEnvelope(), { kind: "bogus" });
    expect(r.status).toBe(400);
    expect(await r.json()).toEqual({ error: "missing_fields" });
  });

  it("member -> member relay: 201, inbox item kind is diaryKey", async () => {
    const owner = await makeAccount("dev-dk-o4"), member = await makeAccount("dev-dk-m4");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(member), diaryId, inviteCode);
    const r = await sendNote(bearer(owner), member.accountId, fakeEnvelope(), { kind: "diaryKey", diaryId });
    expect(r.status).toBe(201);
    const { id } = await r.json() as { id: string };
    const items = await inboxItems(member.accountId);
    expect(items.map((i) => i.id)).toEqual([id]);
    expect(items[0].kind).toBe("diaryKey");
  });

  it("the ordinary blocked-sender fake 201 still applies AFTER the membership check (member -> member, recipient has blocked sender)", async () => {
    const owner = await makeAccount("dev-dk-o7"), member = await makeAccount("dev-dk-m7");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(member), diaryId, inviteCode);
    const sh = await senderHash("test-token-secret-deterministic", owner.accountId);
    await env.ACCOUNTS_DB.prepare("INSERT INTO blocks (account_id, sender_hash, created_at) VALUES (?1, ?2, ?3)").bind(member.accountId, sh, Date.now()).run();
    const r = await sendNote(bearer(owner), member.accountId, fakeEnvelope(), { kind: "diaryKey", diaryId });
    expect(r.status).toBe(201); // fake 201 — not the not_member 403 (both ARE members; block check runs after)
    expect(await inboxItems(member.accountId)).toEqual([]); // ...and nothing was actually stored
  });
});

describe("push shape: kind=note stays a NOTE_RECEIVED alert; kind=diaryKey is silent background priority 5", () => {
  it("asserts the exact payload/options handed to sendAPNs for each kind (fake send, direct handleNotesRoute call)", async () => {
    const owner = await makeAccount("dev-dk-push-o"), member = await makeAccount("dev-dk-push-m"), other = await makeAccount("dev-dk-push-other");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(member), diaryId, inviteCode);

    await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, 'dev-dk-push-m-dev', 'ios', 1)").bind(member.accountId).run();
    await env.V2_STORE.put("device:dev-dk-push-m-dev", JSON.stringify({ pushToken: "tok-member", platform: "ios" }));
    await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, 'dev-dk-push-other-dev', 'ios', 1)").bind(other.accountId).run();
    await env.V2_STORE.put("device:dev-dk-push-other-dev", JSON.stringify({ pushToken: "tok-other", platform: "ios" }));

    const calls: { token: string; payload: unknown; opts?: { topicOverride?: string; pushType?: string; priority?: number } }[] = [];
    const send = async (token: string, payload: unknown, _cfg: unknown, opts?: { topicOverride?: string; pushType?: string; priority?: number }) => { calls.push({ token, payload, opts }); return { ok: true, status: 200 }; };
    // Same spread-env rationale as notes-send.spec.ts's fanOutNotePush test — see its comment.
    const fakeEnv = { ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" } as unknown as Env;
    const deps = { push: { send, topicFor: () => "com.hanfour.peerdrop" } };

    const c1 = await getChallenge(bearer(owner));
    const envBytes1 = fakeEnvelope(21);
    const n1 = await solvePoW(c1, other.accountId, envBytes1);
    const req1 = new Request(`https://example.com/v3/notes/${other.accountId}`, { method: "POST", body: JSON.stringify({ envelope: envBytes1, pow: { challenge: c1, nonce: n1 } }) });
    const resp1 = await handleNotesRoute(req1, new URL(req1.url), `/v3/notes/${other.accountId}`, fakeEnv, { deviceId: "dx1", accountId: owner.accountId }, deps);
    expect(resp1?.status).toBe(201);
    const { id: noteId } = await resp1!.json() as { id: string };

    const c2 = await getChallenge(bearer(owner));
    const envBytes2 = fakeEnvelope(22);
    const n2 = await solvePoW(c2, member.accountId, envBytes2);
    const req2 = new Request(`https://example.com/v3/notes/${member.accountId}`, { method: "POST", body: JSON.stringify({ envelope: envBytes2, pow: { challenge: c2, nonce: n2 }, kind: "diaryKey", diaryId }) });
    const resp2 = await handleNotesRoute(req2, new URL(req2.url), `/v3/notes/${member.accountId}`, fakeEnv, { deviceId: "dx2", accountId: owner.accountId }, deps);
    expect(resp2?.status).toBe(201);
    await resp2!.json();

    expect(calls.length).toBe(2);
    const noteCall = calls.find((c) => c.token === "tok-other")!;
    expect(noteCall.payload).toEqual({ alert: { "loc-key": "NOTE_RECEIVED" }, sound: "default", customData: { type: "note", inboxItemId: noteId } });
    expect(noteCall.opts?.pushType).toBeUndefined();
    expect(noteCall.opts?.priority).toBeUndefined();

    const dkCall = calls.find((c) => c.token === "tok-member")!;
    expect(dkCall.payload).toEqual({ contentAvailable: true, customData: { type: "diaryKey" } });
    expect((dkCall.payload as Record<string, unknown>).alert).toBeUndefined();
    expect(dkCall.opts?.pushType).toBe("background");
    expect(dkCall.opts?.priority).toBe(5);
  });
});
