import { SELF, env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { makeAccount, bearer, keyLane, fakeEnvelope, getChallenge, solvePoW, sendNote, inboxOf } from "./notesHelpers";
import { fanOutNotePush, senderHash, NOTE_LIMITS } from "../notes";
import type { Env } from "../index";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

describe("GET /v3/pow/challenge", () => {
  it("issues a 32-byte base64 challenge and rate limits at 60/min per account", async () => {
    const a = await makeAccount("dev-note-pow-0001");
    const c = await getChallenge(bearer(a));
    expect(atob(c).length).toBe(32);
    await env.V2_STORE.put(`pow-quota:${a.accountId}:${Math.floor(Date.now() / 60_000)}`, String(NOTE_LIMITS.powChallengesPerMinute));
    expect((await SELF.fetch("https://example.com/v3/pow/challenge", { headers: bearer(a) })).status).toBe(429);
  });
});

describe("POST /v3/notes/:recipient", () => {
  it("delivers a note into the recipient's inbox (bearer sender)", async () => {
    const a = await makeAccount("dev-note-send-0001"), b = await makeAccount("dev-note-send-0002");
    const r = await sendNote(bearer(a), b.accountId);
    expect(r.status).toBe(201);
    const { id } = await r.json() as { id: string };
    expect(id).toMatch(/^[0-9A-Z]{26}$/);
    const inbox = await inboxOf(b);
    expect(inbox.items.map((i) => i.id)).toEqual([id]);
    expect(inbox.items[0].envelope).toBe(fakeEnvelope());
  });
  it("accepts the Mac key lane as sender and recipient handles in dashed/lowercase form", async () => {
    const mac = await makeAccount("dev-note-send-mac1", "macos"), b = await makeAccount("dev-note-send-0003");
    const dashed = `${b.accountId.slice(0, 4)}-${b.accountId.slice(4).toLowerCase()}`;
    expect((await sendNote(keyLane(mac), dashed)).status).toBe(201);
    expect((await inboxOf(b)).items.length).toBe(1);
  });
  it("rejects a wrong nonce, a reused challenge and a foreign challenge with bad_pow", async () => {
    const a = await makeAccount("dev-note-send-0004"), b = await makeAccount("dev-note-send-0005");
    const envl = fakeEnvelope(3);
    const challenge = await getChallenge(bearer(a));
    const bad = await SELF.fetch(`https://example.com/v3/notes/${b.accountId}`, { method: "POST", headers: bearer(a), body: JSON.stringify({ envelope: envl, pow: { challenge, nonce: 1 } }) });
    expect(bad.status).toBe(400);
    expect(await bad.json()).toEqual({ error: "bad_pow" });
    // The failed attempt consumed the challenge — a correct nonce for it is now rejected too.
    const nonce = await solvePoW(challenge, b.accountId, envl);
    const reused = await SELF.fetch(`https://example.com/v3/notes/${b.accountId}`, { method: "POST", headers: bearer(a), body: JSON.stringify({ envelope: envl, pow: { challenge, nonce } }) });
    expect(reused.status).toBe(400);
    // A challenge issued to B cannot be spent by A.
    const foreign = await getChallenge(bearer(b));
    const n2 = await solvePoW(foreign, b.accountId, envl);
    expect((await SELF.fetch(`https://example.com/v3/notes/${b.accountId}`, { method: "POST", headers: bearer(a), body: JSON.stringify({ envelope: envl, pow: { challenge: foreign, nonce: n2 } }) })).status).toBe(400);
  });
  it("validates the recipient, the envelope shape/size and the body", async () => {
    const a = await makeAccount("dev-note-send-0006"), b = await makeAccount("dev-note-send-0007");
    const c = await getChallenge(bearer(a));
    expect((await sendNote(bearer(a), "ZZZZZZZ9")).status).toBe(404);
    expect((await sendNote(bearer(a), "not-an-id")).status).toBe(404);
    const badEnv = btoa(JSON.stringify({ v: 1 }));
    const n = await solvePoW(c, b.accountId, badEnv);
    const r1 = await SELF.fetch(`https://example.com/v3/notes/${b.accountId}`, { method: "POST", headers: bearer(a), body: JSON.stringify({ envelope: badEnv, pow: { challenge: c, nonce: n } }) });
    expect(r1.status).toBe(400);
    expect(await r1.json()).toEqual({ error: "invalid_envelope" });
    const huge = fakeEnvelope(1, NOTE_LIMITS.envelopeMaxBytes);
    expect((await sendNote(bearer(a), b.accountId, huge)).status).toBe(413);
    const r3 = await SELF.fetch(`https://example.com/v3/notes/${b.accountId}`, { method: "POST", headers: bearer(a), body: "{}" });
    expect(r3.status).toBe(400);
    expect(await r3.json()).toEqual({ error: "missing_fields" });
  });
  it("silently drops a note from a blocked sender (201, nothing stored)", async () => {
    const a = await makeAccount("dev-note-send-0008"), b = await makeAccount("dev-note-send-0009");
    const sh = await senderHash("test-token-secret-deterministic", a.accountId);
    await env.ACCOUNTS_DB.prepare("INSERT INTO blocks (account_id, sender_hash, created_at) VALUES (?1, ?2, ?3)").bind(b.accountId, sh, Date.now()).run();
    const r = await sendNote(bearer(a), b.accountId);
    expect(r.status).toBe(201);
    expect(((await r.json()) as { id: string }).id).toMatch(/^[0-9A-Z]{26}$/);
    expect((await inboxOf(b)).items).toEqual([]);
  });
  it("enforces the per-sender and per-recipient daily quotas", async () => {
    const a = await makeAccount("dev-note-send-0010"), b = await makeAccount("dev-note-send-0011");
    const day = new Date().toISOString().slice(0, 10);
    await env.V2_STORE.put(`note-quota:s:${a.accountId}:${day}`, String(NOTE_LIMITS.perSenderPerDay));
    expect((await sendNote(bearer(a), b.accountId)).status).toBe(429);
    await env.V2_STORE.delete(`note-quota:s:${a.accountId}:${day}`);
    await env.V2_STORE.put(`note-quota:r:${b.accountId}:${day}`, String(NOTE_LIMITS.perRecipientPerDay));
    expect((await sendNote(bearer(a), b.accountId)).status).toBe(429);
  });
  it("returns inbox_full (507) when the recipient's inbox refuses", async () => {
    const a = await makeAccount("dev-note-send-0012"), b = await makeAccount("dev-note-send-0013");
    const { runInDurableObject } = await import("cloudflare:test");
    const stub = env.ACCOUNT_INBOX.get(env.ACCOUNT_INBOX.idFromName(b.accountId));
    await runInDurableObject(stub, async (_i, state) => {
      const entries: Record<string, unknown> = {};
      for (let i = 0; i < NOTE_LIMITS.inboxCap; i++) {
        const id = `0000000000${String(i).padStart(16, "0")}`.replace(/[^0-9A-Z]/g, "0");
        entries[`meta:${id}`] = { id, kind: "note", senderHash: "x", createdAt: i, readAt: null, expiresAt: 9e15 };
        if (Object.keys(entries).length >= 128) { await state.storage.put(entries); for (const k of Object.keys(entries)) delete entries[k]; }
      }
      if (Object.keys(entries).length) await state.storage.put(entries);
    });
    const r = await sendNote(bearer(a), b.accountId);
    expect(r.status).toBe(507);
    expect(await r.json()).toEqual({ error: "inbox_full" });
  });
});

describe("fanOutNotePush", () => {
  it("sends one push per device that has a token, with the platform topic, and none when APNs is unconfigured", async () => {
    const b = await makeAccount("dev-note-push-0001");
    await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, 'dev-note-push-mac1', 'macos', 1), (?1, 'dev-note-push-none', 'ios', 1)").bind(b.accountId).run();
    await env.V2_STORE.put("device:dev-note-push-0001", JSON.stringify({ pushToken: "tok-ios", platform: "ios" }));
    await env.V2_STORE.put("device:dev-note-push-mac1", JSON.stringify({ pushToken: "tok-mac", platform: "macos" }));
    const calls: { token: string; topic?: string; payload: unknown }[] = [];
    const send = async (token: string, payload: unknown, _cfg: unknown, opts?: { topicOverride?: string }) => { calls.push({ token, topic: opts?.topicOverride, payload }); return { ok: true, status: 200 }; };
    // `cloudflare:test`'s ambient `Cloudflare.Env` (env.d.ts) only declares
    // the non-secret bindings, so a spread copy structurally lacks the
    // secrets the local `Env` type (from index.ts) requires — a tsc error,
    // not a runtime one: the spread's `[[Get]]`/`[[DefineOwnProperty]]`
    // snapshot real binding values (D1Database/KVNamespace references
    // included) as fresh own data properties, so `fakeEnv.ACCOUNTS_DB` etc.
    // stay fully functional. Cast past the structural gap rather than
    // reaching for `Object.create(env)` — that prototype-delegates instead
    // of copying, and since these bindings are accessor-backed (not plain
    // data properties) in this vitest-pool-workers version, assigning
    // through a `Object.create(env)` child invokes the inherited setter and
    // mutates the SHARED `env`, leaking into later assertions/tests.
    const fakeEnv = { ...env, APNS_KEY_P8: "fake", APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_BUNDLE_ID: "com.hanfour.peerdrop" } as unknown as Env;
    const res = await fanOutNotePush(fakeEnv, b.accountId, "01ITEM0000000000000000000A", { send, topicFor: (p) => (p === "macos" ? "com.hanfour.peerdrop.mac" : "com.hanfour.peerdrop") });
    expect(res.attempted).toBe(2);
    expect(calls.map((c) => [c.token, c.topic]).sort()).toEqual([["tok-ios", "com.hanfour.peerdrop"], ["tok-mac", "com.hanfour.peerdrop.mac"]]);
    expect(calls[0].payload).toEqual({ alert: { "loc-key": "NOTE_RECEIVED" }, sound: "default", customData: { type: "note", inboxItemId: "01ITEM0000000000000000000A" } });
    const none = await fanOutNotePush(env as unknown as Env, b.accountId, "01ITEM0000000000000000000A", { send, topicFor: () => "x" });
    expect(none.attempted).toBe(0);
    expect(calls.length).toBe(2);
  });
});
