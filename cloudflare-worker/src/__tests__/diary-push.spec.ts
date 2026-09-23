// Diary event push fan-out (spec §4) + the sendAPNs background-push header
// unit test. Setup (accounts, diary create/join) goes through the real
// SELF.fetch routes — APNS_KEY_P8 is unset in the shared test env
// (vitest.config.ts), so fanOutPush short-circuits to a no-op there and
// setup calls can never leak a spurious push into a test's assertions.
// The action under test is driven by calling handleDiaryRoute directly
// with a fake `deps.push.send` (same pattern as notes-send.spec.ts's
// fanOutNotePush test) — the only way to observe what would be sent,
// since a real push is unobservable through the HTTP surface in this env.
import { env } from "cloudflare:test";
import { describe, it, expect, beforeAll, vi } from "vitest";
import { applyMigrations } from "./d1";
import { makeAccount, bearer } from "./notesHelpers";
import { createDiaryOk, joinByLink, fakeCipher } from "./diaryHelpers";
import type { TestAccount } from "./diaryHelpers";
import { handleDiaryRoute } from "../diary";
import { ulid } from "../notes";
import { sendAPNs } from "../apns";
import type { Env } from "../index";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

let devCounter = 0;
async function mkAccount(tag: string): Promise<TestAccount> {
  return makeAccount(`dev-dpush-${tag}-${String(++devCounter).padStart(4, "0")}`);
}

/** Register a push token for `a` so fanOutPush actually attempts a send. */
async function seedPush(a: TestAccount, token: string): Promise<void> {
  const deviceId = `${a.deviceId}-push`;
  await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, 'ios', 1)").bind(a.accountId, deviceId).run();
  await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: token, platform: "ios" }));
}

interface Call { accountId: string; payload: unknown; opts?: { topicOverride?: string; pushType?: string; priority?: number } }

/** A fake `deps.push` recording every send call, resolved back to a test account via a token->accountId map. */
function fakeDeps(tokenToAccount: Record<string, string>): { deps: { push: { send: typeof sendAPNs; topicFor: (p: string) => string } }; calls: Call[] } {
  const calls: Call[] = [];
  const send = (async (token: string, payload: unknown, _cfg: unknown, opts?: { topicOverride?: string; pushType?: string; priority?: number }) => {
    calls.push({ accountId: tokenToAccount[token] ?? token, payload, opts });
    return { ok: true, status: 200 };
  }) as unknown as typeof sendAPNs;
  return { deps: { push: { send, topicFor: () => "com.hanfour.peerdrop" } }, calls };
}

// Same spread-env rationale as notes-send.spec.ts's fanOutNotePush test:
// the spread copies real (functioning) bindings as own data properties, so
// D1/DO/KV all keep working while APNS_* becomes truthy for this call.
function fakeEnv(): Env {
  return { ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" } as unknown as Env;
}

async function callDiary(path: string, method: string, accountId: string, deps: { push: { send: typeof sendAPNs; topicFor: (p: string) => string } }, body?: unknown): Promise<Response> {
  const req = new Request(`https://example.com${path}`, { method, body: body !== undefined ? JSON.stringify(body) : undefined });
  const resp = await handleDiaryRoute(req, new URL(req.url), path, fakeEnv(), { deviceId: "dx", accountId }, deps);
  if (!resp) throw new Error(`handleDiaryRoute returned null for ${method} ${path}`);
  return resp;
}

describe("POST .../events push fan-out", () => {
  it("entry: DIARY_ENTRY to every other member, not the author", async () => {
    const owner = await mkAccount("entry-owner"), b = await mkAccount("entry-b"), c = await mkAccount("entry-c");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    await joinByLink(bearer(c), diaryId, inviteCode);
    await seedPush(owner, "tok-owner"); await seedPush(b, "tok-b"); await seedPush(c, "tok-c");

    const { deps, calls } = fakeDeps({ "tok-owner": owner.accountId, "tok-b": b.accountId, "tok-c": c.accountId });
    const r = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, deps, { eventId: ulid(), type: "entry", payloadCipher: fakeCipher() });
    expect(r.status).toBe(201);
    const { seq } = await r.json() as { seq: number };

    expect(calls.map((c) => c.accountId).sort()).toEqual([b.accountId, c.accountId].sort());
    for (const call of calls) {
      expect(call.payload).toEqual({ alert: { "loc-key": "DIARY_ENTRY" }, customData: { type: "diaryEntry", diaryId, seq } });
      expect(call.opts?.pushType).toBeUndefined();
    }
  });

  it("pass: DIARY_TURN only to the new holder", async () => {
    const owner = await mkAccount("pass-owner"), b = await mkAccount("pass-b"), c = await mkAccount("pass-c");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    await joinByLink(bearer(c), diaryId, inviteCode);
    await seedPush(owner, "tok-owner"); await seedPush(b, "tok-b"); await seedPush(c, "tok-c");

    const { deps, calls } = fakeDeps({ "tok-owner": owner.accountId, "tok-b": b.accountId, "tok-c": c.accountId });
    const r = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, deps, { eventId: ulid(), type: "pass" });
    expect(r.status).toBe(201);
    expect(calls.length).toBe(1);
    expect(calls[0].accountId).toBe(b.accountId); // holderIndex 0 -> 1
    expect(calls[0].payload).toEqual({ alert: { "loc-key": "DIARY_TURN" }, customData: { type: "diaryTurn", diaryId } });
  });

  it("skip: DIARY_TURN only to the new holder (owner skips someone else)", async () => {
    const owner = await mkAccount("skip-owner"), b = await mkAccount("skip-b"), c = await mkAccount("skip-c");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    await joinByLink(bearer(c), diaryId, inviteCode);
    await seedPush(owner, "tok-owner"); await seedPush(b, "tok-b"); await seedPush(c, "tok-c");

    const { deps: setupDeps } = fakeDeps({});
    await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, setupDeps, { eventId: ulid(), type: "pass" }); // holder: owner -> b

    const { deps, calls } = fakeDeps({ "tok-owner": owner.accountId, "tok-b": b.accountId, "tok-c": c.accountId });
    const r = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, deps, { eventId: ulid(), type: "skip" }); // owner skips holder b -> c
    expect(r.status).toBe(201);
    expect(calls.length).toBe(1);
    expect(calls[0].accountId).toBe(c.accountId);
    expect(calls[0].payload).toEqual({ alert: { "loc-key": "DIARY_TURN" }, customData: { type: "diaryTurn", diaryId } });
  });

  it("pass in a one-member diary: no DIARY_TURN, because the new holder is the actor", async () => {
    const solo = await mkAccount("solo-pass");
    const { diaryId } = await createDiaryOk(solo);
    await seedPush(solo, "tok-solo");

    const { deps, calls } = fakeDeps({ "tok-solo": solo.accountId });
    const r = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", solo.accountId, deps, { eventId: ulid(), type: "pass" });
    expect(r.status).toBe(201);
    expect(calls).toEqual([]);   // the turn came straight back to the only member
  });

  it("comment/like: DIARY_REACTION to the entry's author, never to self", async () => {
    const owner = await mkAccount("react-owner"), b = await mkAccount("react-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    await seedPush(owner, "tok-owner"); await seedPush(b, "tok-b");

    const { deps: setupDeps } = fakeDeps({});
    const entryResp = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, setupDeps, { eventId: ulid(), type: "entry", payloadCipher: fakeCipher() });
    const { seq: entrySeq } = await entryResp.json() as { seq: number };

    const { deps, calls } = fakeDeps({ "tok-owner": owner.accountId, "tok-b": b.accountId });

    const rComment = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", b.accountId, deps, { eventId: ulid(), type: "comment", refSeq: entrySeq, payloadCipher: fakeCipher() });
    expect(rComment.status).toBe(201);
    expect(calls.length).toBe(1);
    expect(calls[0].accountId).toBe(owner.accountId);
    expect(calls[0].payload).toEqual({ alert: { "loc-key": "DIARY_REACTION" }, customData: { type: "diaryReaction", diaryId, seq: entrySeq } });

    calls.length = 0;
    const rLike = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", b.accountId, deps, { eventId: ulid(), type: "like", refSeq: entrySeq });
    expect(rLike.status).toBe(201);
    expect(calls.length).toBe(1);
    expect(calls[0].accountId).toBe(owner.accountId);

    calls.length = 0;
    const rSelfComment = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, deps, { eventId: ulid(), type: "comment", refSeq: entrySeq, payloadCipher: fakeCipher() });
    expect(rSelfComment.status).toBe(201);
    expect(calls.length).toBe(0); // commenting on your own entry: no push
  });

  it("an idempotent resend (same eventId, or the same-person-same-entry like dedup) pushes nothing", async () => {
    const owner = await mkAccount("idem-owner"), b = await mkAccount("idem-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    await seedPush(b, "tok-b");

    const { deps, calls } = fakeDeps({ "tok-b": b.accountId });
    const eventId = ulid();
    const r1 = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, deps, { eventId, type: "entry", payloadCipher: fakeCipher() });
    expect(r1.status).toBe(201);
    expect(calls.length).toBe(1);

    calls.length = 0;
    const r2 = await callDiary(`/v3/diaries/${diaryId}/events`, "POST", owner.accountId, deps, { eventId, type: "entry", payloadCipher: fakeCipher() }); // exact-eventId replay
    expect(r2.status).toBe(200);
    expect(calls.length).toBe(0);
  });
});

describe("join push fan-out", () => {
  it("pushes DIARY_JOIN to existing members, not the joiner; a re-join is idempotent and pushes nothing", async () => {
    const owner = await mkAccount("join-owner"), b = await mkAccount("join-b");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await seedPush(owner, "tok-owner"); await seedPush(b, "tok-b");

    const { deps, calls } = fakeDeps({ "tok-owner": owner.accountId, "tok-b": b.accountId });
    const r1 = await callDiary(`/v3/diaries/${diaryId}/join`, "POST", b.accountId, deps, { inviteCode });
    expect(r1.status).toBe(201);
    expect(calls.length).toBe(1);
    expect(calls[0].accountId).toBe(owner.accountId);
    expect(calls[0].payload).toEqual({ alert: { "loc-key": "DIARY_JOIN" }, customData: { type: "diaryJoin", diaryId, accountId: b.accountId } });

    calls.length = 0;
    const r2 = await callDiary(`/v3/diaries/${diaryId}/join`, "POST", b.accountId, deps, { inviteCode });
    expect(r2.status).toBe(200);
    expect(calls.length).toBe(0);
  });
});

describe("request-key push fan-out", () => {
  it("silent diaryKeyRequest to other members; the 7th call in the hour is 429 and sends nothing", async () => {
    const owner = await mkAccount("reqkey-owner"), b = await mkAccount("reqkey-b"), c = await mkAccount("reqkey-c");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    await joinByLink(bearer(c), diaryId, inviteCode);
    await seedPush(owner, "tok-owner"); await seedPush(c, "tok-c");

    const { deps, calls } = fakeDeps({ "tok-owner": owner.accountId, "tok-c": c.accountId });
    for (let i = 0; i < 6; i++) {
      calls.length = 0;
      const r = await callDiary(`/v3/diaries/${diaryId}/request-key`, "POST", b.accountId, deps);
      expect(r.status).toBe(204);
      expect(calls.map((c) => c.accountId).sort()).toEqual([owner.accountId, c.accountId].sort());
      for (const call of calls) {
        expect(call.payload).toEqual({ contentAvailable: true, customData: { type: "diaryKeyRequest", diaryId, accountId: b.accountId } });
        expect(call.opts?.pushType).toBe("background");
        expect(call.opts?.priority).toBe(5);
      }
    }
    calls.length = 0;
    const r7 = await callDiary(`/v3/diaries/${diaryId}/request-key`, "POST", b.accountId, deps);
    expect(r7.status).toBe(429);
    expect(calls.length).toBe(0);
  });

  it("a non-member gets 403 and no push is attempted", async () => {
    const owner = await mkAccount("reqkey-nm-owner"), outsider = await mkAccount("reqkey-nm-out");
    const { diaryId } = await createDiaryOk(owner);
    await seedPush(owner, "tok-owner");
    const { deps, calls } = fakeDeps({ "tok-owner": owner.accountId });
    const r = await callDiary(`/v3/diaries/${diaryId}/request-key`, "POST", outsider.accountId, deps);
    expect(r.status).toBe(403);
    expect(calls.length).toBe(0);
  });
});

describe("sendAPNs background push headers", () => {
  it("apns-push-type: background and apns-priority: 5 when requested; default alert push stays unaffected", async () => {
    const calls: { headers: Record<string, string> }[] = [];
    vi.stubGlobal("fetch", async (_url: string, init: { headers: Record<string, string> }) => {
      calls.push({ headers: init.headers });
      return new Response(null, { status: 200 });
    });
    try {
      const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
      const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey) as ArrayBuffer);
      const b64 = btoa(String.fromCharCode(...pkcs8));
      const pem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`;
      const config = { keyId: "k", teamId: "t", p8Key: pem, bundleId: "com.hanfour.peerdrop" };

      const bg = await sendAPNs("tok-bg", { contentAvailable: true, customData: { type: "diaryKey" } }, config, { pushType: "background", priority: 5 });
      expect(bg.ok).toBe(true);
      expect(calls[0].headers["apns-push-type"]).toBe("background");
      expect(calls[0].headers["apns-priority"]).toBe("5");

      await sendAPNs("tok-alert", { alert: { "loc-key": "X" } }, config);
      expect(calls[1].headers["apns-push-type"]).toBe("alert"); // unchanged default
      expect(calls[1].headers["apns-priority"]).toBeUndefined();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
