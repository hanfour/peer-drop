// Account-level settings (spec §4.5 / Task 7): GET/PUT /v3/account/settings
// and the note-push suppression in fanOutNotePush. The push sender is a spy
// passed to fanOutNotePush directly (a real APNs call is unobservable here).
import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeAll, vi, afterEach } from "vitest";
import { applyMigrations, applyMigrationFile } from "./d1";
import { makeAccount, bearer, keyLane, sendNote, inboxOf, getChallenge, solvePoW, fakeEnvelope } from "./notesHelpers";
import { createDiaryOk, joinByLink, fakeCipher } from "./diaryHelpers";
import { handleNotesRoute, fanOutNotePush, ulid } from "../notes";
import { handleDiaryRoute } from "../diary";
import type { Env } from "../index";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });
afterEach(() => { vi.restoreAllMocks(); });

const URL_ = "https://example.com/v3/account/settings";
const get = (headers: Record<string, string>) => SELF.fetch(URL_, { headers });
const put = (headers: Record<string, string>, body: unknown) =>
  SELF.fetch(URL_, { method: "PUT", headers, body: typeof body === "string" ? body : JSON.stringify(body) });

describe("GET/PUT /v3/account/settings", () => {
  it("defaults notePush to true when the account has no row", async () => {
    const a = await makeAccount("dev-aset-0001");
    const r = await get(bearer(a));
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ notePush: true });
  });

  it("PUT then GET round-trips, and flips back", async () => {
    const a = await makeAccount("dev-aset-0002");
    const r = await put(bearer(a), { notePush: false });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ notePush: false });
    expect(await (await get(bearer(a))).json()).toEqual({ notePush: false });
    expect(await (await put(bearer(a), { notePush: true })).json()).toEqual({ notePush: true });
    expect(await (await get(bearer(a))).json()).toEqual({ notePush: true });
  });

  it("requires account auth", async () => {
    expect((await SELF.fetch(URL_)).status).toBe(401);
    expect((await SELF.fetch(URL_, { method: "PUT", body: JSON.stringify({ notePush: false }) })).status).toBe(401);
    expect((await SELF.fetch(URL_, { headers: { Authorization: "Bearer not-a-token" } })).status).toBe(401);
  });

  it("key lane may read but not write (self-asserted device id)", async () => {
    const a = await makeAccount("dev-aset-0003", "macos");
    expect((await get(keyLane(a))).status).toBe(200);
    const r = await put(keyLane(a), { notePush: false });
    expect(r.status).toBe(401);
    expect(await r.json()).toEqual({ error: "bearer_required" });
    expect(await (await get(bearer(a))).json()).toEqual({ notePush: true });
  });

  it("rejects anything but exactly {notePush: boolean}", async () => {
    const a = await makeAccount("dev-aset-0004");
    for (const bad of [{ notePush: "false" }, { notePush: 0 }, { notePush: null }, {}, [], "null", "{not json", { notePush: false, extra: 1 }, { notePush: true, nickname: "x" }]) {
      const r = await put(bearer(a), bad);
      expect(r.status, JSON.stringify(bad)).toBe(400);
    }
    expect((await put(bearer(a), "x".repeat(5000))).status).toBe(413);
    // none of the rejected writes changed anything
    expect(await (await get(bearer(a))).json()).toEqual({ notePush: true });
  });

  it("is isolated per account", async () => {
    const a = await makeAccount("dev-aset-0005"), b = await makeAccount("dev-aset-0006");
    await put(bearer(a), { notePush: false });
    expect(await (await get(bearer(b))).json()).toEqual({ notePush: true });
    expect(await (await get(bearer(a))).json()).toEqual({ notePush: false });
  });

  it("rate limits writes per account without recording values", async () => {
    const a = await makeAccount("dev-aset-0007");
    const day = new Date().toISOString().slice(0, 10);
    await env.V2_STORE.put(`settings-quota:${a.accountId}:${day}`, "1000");
    expect((await put(bearer(a), { notePush: false })).status).toBe(429);
    expect(await (await get(bearer(a))).json()).toEqual({ notePush: true });
  });

  it("stores only the minimal columns (no timestamps / history / IP)", async () => {
    const cols = (await env.ACCOUNTS_DB.prepare("PRAGMA table_info(account_settings)").all<{ name: string }>()).results.map((c) => c.name).sort();
    expect(cols).toEqual(["account_id", "note_push"]);
  });

  it("does not log account ids or settings", async () => {
    const a = await makeAccount("dev-aset-0008");
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((m) => vi.spyOn(console, m).mockImplementation(() => {}));
    await put(bearer(a), { notePush: false });
    await get(bearer(a));
    await put(bearer(a), "garbage");
    for (const s of spies) expect(s).not.toHaveBeenCalled();
  });

  it("deleting the account removes its settings row", async () => {
    const a = await makeAccount("dev-aset-0009");
    await put(bearer(a), { notePush: false });
    expect((await SELF.fetch("https://example.com/v3/account", { method: "DELETE", headers: bearer(a) })).status).toBe(204);
    const row = await env.ACCOUNTS_DB.prepare("SELECT 1 AS x FROM account_settings WHERE account_id = ?1").bind(a.accountId).first();
    expect(row).toBeNull();
  });
});

describe("migration 0004", () => {
  it("can be applied again without error and keeps existing rows", async () => {
    const a = await makeAccount("dev-aset-0010");
    await put(bearer(a), { notePush: false });
    await applyMigrationFile(env.ACCOUNTS_DB, "0004_account_settings.sql");
    await applyMigrationFile(env.ACCOUNTS_DB, "0004_account_settings.sql");
    expect(await (await get(bearer(a))).json()).toEqual({ notePush: false });
  });
});

describe("fanOutNotePush honours the recipient's notePush setting", () => {
  async function seedDevice(accountId: string, deviceId: string, token: string) {
    await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, 'ios', 1)").bind(accountId, deviceId).run();
    await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: token, platform: "ios" }));
  }
  const fakeEnv = () => ({ ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" }) as unknown as Env;
  function spy() {
    const calls: unknown[] = [];
    const send = async (...args: unknown[]) => { calls.push(args); return { ok: true, status: 200 }; };
    return { calls, deps: { send: send as never, topicFor: () => "com.hanfour.peerdrop" } };
  }

  it("sends nothing at all (visual or silent) when notePush is false", async () => {
    const b = await makeAccount("dev-aset-push-0001");
    await seedDevice(b.accountId, "dev-aset-push-0001-d", "tok-1");
    await put(bearer(b), { notePush: false });
    const s = spy();
    expect(await fanOutNotePush(fakeEnv(), b.accountId, "01ITEM0000000000000000000A", s.deps)).toEqual({ attempted: 0 });
    expect(s.calls.length).toBe(0);
  });

  it("pushes as before with notePush true or no row", async () => {
    const noRow = await makeAccount("dev-aset-push-0002"), on = await makeAccount("dev-aset-push-0003");
    await seedDevice(noRow.accountId, "dev-aset-push-0002-d", "tok-2");
    await seedDevice(on.accountId, "dev-aset-push-0003-d", "tok-3");
    await put(bearer(on), { notePush: false });
    await put(bearer(on), { notePush: true });
    for (const acct of [noRow, on]) {
      const s = spy();
      expect((await fanOutNotePush(fakeEnv(), acct.accountId, "01ITEM0000000000000000000A", s.deps)).attempted).toBe(1);
      expect(s.calls.length).toBe(1);
    }
  });

  it("fails closed: an unreadable setting sends no push (the note is already stored)", async () => {
    const b = await makeAccount("dev-aset-push-0004");
    await seedDevice(b.accountId, "dev-aset-push-0004-d", "tok-4");
    const realDb = env.ACCOUNTS_DB;
    const flaky = { prepare(sql: string) { if (sql.includes("account_settings")) throw new Error("d1 down"); return realDb.prepare(sql); } };
    const s = spy();
    const res = await fanOutNotePush({ ...fakeEnv(), ACCOUNTS_DB: flaky } as unknown as Env, b.accountId, "01ITEM0000000000000000000A", s.deps);
    expect(res).toEqual({ attempted: 0 });
    expect(s.calls.length).toBe(0);
  });

  it("the note itself is still delivered and stored when push is off", async () => {
    const a = await makeAccount("dev-aset-push-0005"), b = await makeAccount("dev-aset-push-0006");
    await put(bearer(b), { notePush: false });
    const r = await sendNote(bearer(a), b.accountId);
    expect(r.status).toBe(201);
    const { id } = await r.json() as { id: string };
    expect((await inboxOf(b)).items.map((i) => i.id)).toEqual([id]);
  });
});

describe("route-level push behaviour with notePush=false", () => {
  const fakeEnv = () => ({ ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" }) as unknown as Env;
  async function seedDevice(accountId: string, deviceId: string, token: string) {
    await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, 'ios', 1)").bind(accountId, deviceId).run();
    await env.V2_STORE.put(`device:${deviceId}`, JSON.stringify({ pushToken: token, platform: "ios" }));
  }
  function spy() {
    const calls: unknown[][] = [];
    const send = async (...args: unknown[]) => { calls.push(args); return { ok: true, status: 200 }; };
    return { calls, deps: { push: { send: send as never, topicFor: () => "com.hanfour.peerdrop" } } };
  }
  async function postNote(sender: { accountId: string; token: string; deviceId: string }, recipientId: string, deps: ReturnType<typeof spy>["deps"], extra: Record<string, unknown> = {}) {
    const headers = { Authorization: `Bearer ${sender.token}`, "Content-Type": "application/json" };
    const envelope = fakeEnvelope();
    const challenge = await getChallenge(headers);
    const nonce = await solvePoW(challenge, recipientId, envelope);
    const path = `/v3/notes/${recipientId}`;
    const req = new Request(`https://example.com${path}`, { method: "POST", headers, body: JSON.stringify({ envelope, pow: { challenge, nonce }, ...extra }) });
    const resp = await handleNotesRoute(req, new URL(req.url), path, fakeEnv(), { deviceId: sender.deviceId, accountId: sender.accountId }, deps);
    if (!resp) throw new Error("null route");
    return resp;
  }

  it("POST /v3/notes to a notePush=false recipient: stored, zero sends", async () => {
    const a = await makeAccount("dev-aset-rt-0001"), b = await makeAccount("dev-aset-rt-0002");
    await seedDevice(b.accountId, "dev-aset-rt-0002-d", "tok-b");
    await put(bearer(b), { notePush: false });
    const s = spy();
    expect((await postNote(a, b.accountId, s.deps)).status).toBe(201);
    expect(s.calls.length).toBe(0);
    expect((await inboxOf(b)).items.length).toBe(1);
  });

  it("control: the same POST to a notePush=true recipient does send", async () => {
    const a = await makeAccount("dev-aset-rt-0003"), b = await makeAccount("dev-aset-rt-0004");
    await seedDevice(b.accountId, "dev-aset-rt-0004-d", "tok-b2");
    const s = spy();
    expect((await postNote(a, b.accountId, s.deps)).status).toBe(201);
    expect(s.calls.length).toBe(1);
  });

  it("diaryKey relay still sends its silent push when notePush=false", async () => {
    const owner = await makeAccount("dev-aset-rt-0005"), member = await makeAccount("dev-aset-rt-0006");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(member), diaryId, inviteCode);
    await seedDevice(member.accountId, "dev-aset-rt-0006-d", "tok-m");
    await put(bearer(member), { notePush: false });
    const s = spy();
    expect((await postNote(owner, member.accountId, s.deps, { kind: "diaryKey", diaryId })).status).toBe(201);
    expect(s.calls.length).toBe(1);
    expect(s.calls[0][1]).toEqual({ contentAvailable: true, customData: { type: "diaryKey" } });
  });

  it("diary event pushes still go out when notePush=false", async () => {
    const owner = await makeAccount("dev-aset-rt-0007"), b = await makeAccount("dev-aset-rt-0008");
    const { diaryId, inviteCode } = await createDiaryOk(owner);
    await joinByLink(bearer(b), diaryId, inviteCode);
    await seedDevice(b.accountId, "dev-aset-rt-0008-d", "tok-b3");
    await put(bearer(b), { notePush: false });
    const s = spy();
    const path = `/v3/diaries/${diaryId}/events`;
    const req = new Request(`https://example.com${path}`, { method: "POST", body: JSON.stringify({ eventId: ulid(), type: "entry", payloadCipher: fakeCipher() }) });
    const resp = await handleDiaryRoute(req, new URL(req.url), path, fakeEnv(), { deviceId: "dx", accountId: owner.accountId }, s.deps);
    expect(resp?.status).toBe(201);
    expect(s.calls.length).toBe(1);
  });
});
